# dev-platform

Self-hosted Internal Developer Platform on AWS — single Git repository, end-to-end IaC, GitOps reconciliation.

## Target architecture

```text
AWS EC2 (1 × on-demand master + 2 × spot workers)
  └── Talos Linux
      └── Kubernetes
          ├── Cilium · NGINX Ingress · cert-manager · external-dns · EBS CSI
          ├── Argo CD · OneDev · Coolify
          ├── Prometheus · Grafana · Loki · Tempo · Alertmanager
          ├── Kyverno · Trivy · Falco · IRSA
          └── Velero → S3
```

First hosted application: **Vaultwarden** (self-hosted password manager). Stack rationale and per-decision write-ups live in `docs/`.

## Status

**One `terraform apply` from cold to a working Cilium-backed cluster.** Today:

- [x] VPC, public subnet, IGW, route table, RT association
- [x] Security group for cluster nodes (Talos API + kube-apiserver from operator CIDR; full intra-cluster; egress all)
- [x] EC2 definitions — 1 on-demand master + 2 spot workers on a Talos AMI (pinned to `talos-v1.12*`)
- [x] Clean `terraform destroy` — workers' spot requests cancelled before termination (no relaunch), and instances ordered after the route table so the IGW attaches before nodes and detaches without hanging
- [x] Talos machine configs + cluster bootstrap, declarative via the `siderolabs/talos` provider
- [x] **M0** — repo scaffold (`argocd/`, `policies/`, CI workflows), SOPS + age for committed secrets
- [x] **M1** — Cilium 1.16.5 replaces Flannel; kube-proxy replaced by eBPF; Hubble + relay + UI enabled
- [ ] **M2** — IRSA + AWS prereqs (OIDC, IAM roles for EBS CSI / LBC / Velero, VPC tags, Velero S3)
- [ ] **M3** — Argo CD seed + App-of-Apps root
- [ ] **M4** — Cluster foundation (ingress-nginx, cert-manager, external-dns, EBS CSI)
- [ ] **M5** — Observability (Prometheus, Grafana, Loki, Tempo)
- [ ] **M6** — Security (Kyverno, Trivy, Falco)
- [ ] **M7** — Backup + workloads (Velero, OneDev, Backstage)

## Quick start

### Prerequisites

- Terraform `>= 1.6`
- AWS credentials with VPC + EC2 permissions
- `talosctl`, `kubectl` (for using the cluster after Terraform brings it up)

The Talos AMI is resolved automatically via a `data "aws_ami"` lookup for the latest Sidero Labs `talos-v1.12*` release matching your region and `x86_64`. Talos and Kubernetes versions are pinned together in `terraform/04-talos.tf` (`locals { talos_version, kubernetes_version }`); bump all three lines together when upgrading.

### Configure

Create `terraform/terraform.tfvars` (gitignored):

```hcl
operator_cidr = "X.X.X.X/32"   # your laptop's public IP
```

Region defaults to `eu-central-1` (`eu-central-1a` for the subnet). Edit `terraform/providers.tf` and `terraform/00-network.tf` if you're using a different region.

### Apply

```sh
cd terraform/
terraform init
terraform plan
terraform apply
```

One apply takes you from nothing to a working cluster: VPC + 3 EC2 instances + Talos machine configs applied + etcd bootstrapped + `kubeconfig` and `talosconfig` written to disk. Cold time ~8 minutes.

### Use the cluster

```sh
export TALOSCONFIG="$(terraform output -raw talosconfig_path)"
export KUBECONFIG="$(terraform output -raw kubeconfig_path)"

kubectl get nodes
# NAME             STATUS   ROLES           AGE   VERSION
# ip-10-10-X-X     Ready    <none>          1m    v1.34.1
# ip-10-10-X-X     Ready    control-plane   1m    v1.34.1
# ip-10-10-X-X     Ready    <none>          1m    v1.34.1
```

Nodes are `Ready` once Cilium is up. Flannel is disabled at the Talos layer (`cluster.network.cni.name = "none"`) and kube-proxy is replaced by Cilium's eBPF datapath (`cluster.proxy.disabled = true`); Terraform installs Cilium via Helm immediately after bootstrap, gated by a `null_resource.wait_for_apiserver` that polls `https://<master-eip>:6443/livez` until the apiserver is serving.

Read the node IPs separately if you need them:

```sh
terraform output
```

Master public IP is stable (Elastic IP); worker public IPs change on each start.

See [`docs/talos-terraform.md`](./docs/talos-terraform.md) for the full provider-driven workflow, day-2 operations, and tradeoffs. The manual `talosctl` runbook is preserved as a fallback in [`docs/talos-bootstrap.md`](./docs/talos-bootstrap.md).

## Repository layout

```text
dev-platform/
├── README.md              # this file
├── docs/
│   ├── talos-terraform.md   # preferred bootstrap path (the provider)
│   ├── talos-bootstrap.md   # manual talosctl runbook (fallback / reference)
│   └── aws-eip-hairpin.md   # technical explainer for the AWS NAT model and the endpoint/node split
├── terraform/             # AWS infra + Talos provider + Cilium Helm
│   ├── providers.tf       # AWS + siderolabs/talos + hashicorp/local + kubernetes + helm + null
│   ├── 00-network.tf      # VPC, subnet, IGW, route table
│   ├── 01-compute.tf      # EC2 (master + workers) + cancel_worker_spot_request hook + IGW-ordering depends_on
│   ├── 02-security-groups.tf
│   ├── 03-scheduler.tf    # nightly stop/start via EventBridge Scheduler
│   ├── 04-talos.tf        # Talos: secrets, machine configs, apply, bootstrap, kubeconfig, wait_for_apiserver
│   ├── 05-cilium.tf       # Cilium Helm release (kube-proxy replacement, Hubble UI)
│   └── outputs.tf         # node IPs + kubeconfig/talosconfig paths
├── argocd/                # App-of-Apps tree (scaffolded; populated in M3+)
│   ├── apps/              # root applications, sync-wave ordered
│   ├── platform/          # cluster services
│   └── applications/      # workloads
├── policies/              # Kyverno ClusterPolicies (M6)
├── .github/workflows/     # CI gates
│   ├── terraform.yml      # fmt + validate + tfsec
│   ├── helm-lint.yml      # helm lint + kubeconform
│   └── manifests.yml      # kubeconform on raw YAML + kyverno-test
├── .sops.yaml             # SOPS rules: *.enc.yaml encrypted with age
└── talos/                 # Terraform writes talosconfig here (gitignored)
```

## Roadmap

1. **Network + compute** — done
2. **Talos bootstrap** — done (declarative, via `siderolabs/talos` provider)
3. **Repo scaffold + SOPS + CI** (M0) — done
4. **Cilium CNI swap** (M1) — done (Cilium 1.16.5, kube-proxy replaced by eBPF, Hubble UI)
5. **IRSA + AWS prereqs** (M2) — OIDC discovery on S3, IAM roles for EBS CSI / LBC / Velero, VPC tags, Velero S3 bucket
6. **Argo CD seed + App-of-Apps** (M3) — Terraform installs Argo CD; Argo CD reconciles everything from here on
7. **Cluster foundation** (M4) — ingress-nginx, cert-manager, external-dns, EBS CSI, AWS LB Controller
8. **Observability** (M5) — Prometheus, Grafana, Loki, Tempo, Alertmanager
9. **Security tooling** (M6) — Kyverno, Trivy, Falco
10. **Backup + workloads** (M7) — Velero, OneDev, Backstage

## Cost

Cluster runs on small EC2 instances — roughly $50/month if left running 24/7, far less when `terraform destroy` is the norm between sessions. EBS volumes and S3 (for Velero backups, once that's in place) carry small standing costs even after the EC2s are destroyed.

**Nightly shutdown:** EventBridge Scheduler stops all three nodes at 21:00 Europe/Berlin and starts them again at 05:00 — an 8-hour daily gap, ~33% compute savings. Spot workers run as `persistent` so they can be stopped/started by the API. The master holds an Elastic IP (~$1.22/month for the nightly stopped hours; free while running) so its public IP is stable across stop/start; worker IPs still rotate on each start.

Persistent spot has two sharp edges for `terraform destroy`, both handled in `terraform/01-compute.tf`:

- **Relaunch:** a persistent spot request survives instance termination and re-launches the worker — which would then hold a public IP and trap the IGW detach. A `null_resource.cancel_worker_spot_request` runs `aws ec2 cancel-spot-instance-requests` via destroy-time `local-exec` before each worker is terminated, so AWS doesn't bring it back.
- **Detach ordering:** the IGW can't detach while any node still holds a public IP. The master and workers `depends_on` the route-table association, so on destroy the nodes (and their public IPs) are gone before the gateway detaches — no `DependencyViolation` retry storm. The same edge fixes create ordering: the IGW attaches before any node launches and before the EIP association (otherwise `Gateway.NotAttached`).

Normal operation (auto-resume after spot interruption, nightly stop/start) is unaffected.

## Documentation

Each significant decision lands in `docs/`.

Already written:

- [`talos-terraform.md`](./docs/talos-terraform.md) — preferred bootstrap path using the `siderolabs/talos` provider; includes day-2 ops and the destroy/recreate flow
- [`talos-bootstrap.md`](./docs/talos-bootstrap.md) — manual `talosctl` runbook, kept as a fallback and as the educational reference for what the provider does under the hood
- [`aws-eip-hairpin.md`](./docs/aws-eip-hairpin.md) — why EIPs are unreachable from inside the VPC, why `talosctl`'s endpoint/node split exists, and the reproducible diagnostic that confirms the failure mode

Planned:

- The design pivot from bare metal to AWS spot
- NGINX Ingress vs AWS NLB (L4 vs L7)
- Stateful pods on a spot fleet
- IRSA in practice
- App-of-Apps with Argo CD
- Velero to S3 — disaster recovery drills
- Vaultwarden, the full path
- The "Terraform allow-all-egress trap"
