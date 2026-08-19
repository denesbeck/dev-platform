# dev-platform

Self-hosted Internal Developer Platform on AWS — single Git repository, end-to-end IaC, GitOps reconciliation.

## Target architecture

```text
AWS EC2 (1 × on-demand master + 2 × spot workers)
  └── Talos Linux
      └── Kubernetes
          ├── Cilium · NGINX Ingress · cert-manager · external-dns · EBS CSI
          ├── Argo CD · OneDev · Backstage
          ├── Prometheus · Grafana · Loki · Tempo · Alertmanager
          ├── Kyverno · Trivy · Falco · IRSA
          └── Velero → S3
```

Stack rationale and per-decision write-ups live in `docs/`.

## Status

**One `terraform apply` from cold to a working Cilium-backed cluster.** Today:

- [x] VPC, public subnet, IGW, route table, RT association
- [x] Security group for cluster nodes (Talos API + kube-apiserver from operator CIDR; full intra-cluster; egress all)
- [x] EC2 definitions — 1 on-demand master + 2 spot workers on a Talos AMI (resolved from `var.talos_version`)
- [x] Clean `terraform destroy` — workers' spot requests cancelled before termination (no relaunch), and instances ordered after the route table so the IGW attaches before nodes and detaches without hanging
- [x] Talos machine configs + cluster bootstrap, declarative via the `siderolabs/talos` provider
- [x] **M0** — repo scaffold (`argocd/`, `policies/`, CI workflows), SOPS + age for committed secrets
- [x] **M1** — Cilium 1.16.5 replaces Flannel; kube-proxy replaced by eBPF; Hubble + relay + UI enabled
- [x] **M2** — IRSA + AWS prereqs (self-hosted OIDC on S3, IAM roles for EBS CSI / LBC / Velero, VPC tags, Velero S3) — verified end-to-end (`scripts/verify-m2.sh`)
- [x] **M3** — Argo CD seed + App-of-Apps root — Argo CD 3.5.1 seeded by Terraform, root app reconciling from Git, SOPS decryption working in repo-server (`scripts/verify-m3.sh`)
- [ ] **M4** — Cluster foundation (ingress-nginx, cert-manager, external-dns, EBS CSI)
- [ ] **M5** — Observability (Prometheus, Grafana, Loki, Tempo)
- [ ] **M6** — Security (Kyverno, Trivy, Falco)
- [ ] **M7** — Backup + workloads (Velero, OneDev, Backstage)

## Quick start

### Prerequisites

- Terraform `>= 1.6`
- AWS credentials with VPC + EC2 permissions
- `talosctl`, `kubectl` (for using the cluster after Terraform brings it up)

The Talos AMI is resolved automatically via a `data "aws_ami"` lookup for the latest Sidero Labs `talos-v<version>*` release matching your region and `x86_64`. Talos and Kubernetes versions come from `var.talos_version` and `var.kubernetes_version` in `terraform/variables.tf` — `talos_version` drives both the AMI filter and the machine config, so the image and the node config cannot drift apart. Give both as bare versions (`1.12`, not `v1.12`); the leading `v` is added at each use site and a validation block rejects it.

### Configure

Create `terraform/terraform.tfvars` (gitignored):

```hcl
operator_cidr = "X.X.X.X/32"   # your laptop's public IP

# M3+: the age private key whose public half is in .sops.yaml. Argo CD's
# repo-server needs it to decrypt *.enc.yaml when rendering manifests.
#   sops_age_key = "AGE-SECRET-KEY-1..."
# Prefer keeping it out of the file entirely:
#   export TF_VAR_sops_age_key="$(cat "$SOPS_AGE_KEY_FILE")"
```

Terraform records variable values in `terraform.tfstate`, so the age key lands in the state file — which is why both `*.tfvars` and `*.tfstate` are gitignored.

Region defaults to `eu-central-1` (`eu-central-1a` for the subnet). Edit `terraform/providers.tf` and `terraform/00-network.tf` if you're using a different region.

### Apply

```sh
cd terraform/
terraform init
terraform plan
terraform apply
```

One apply takes you from nothing to a working cluster: VPC + 3 EC2 instances + Talos machine configs applied + etcd bootstrapped + `kubeconfig` and `talosconfig` written to disk. Cold time ~8 minutes.

**Starting a cold build in the evening?** The nightly stop fires at 21:00 Europe/Berlin and will power the nodes off mid-bootstrap, failing the apply part-built. Disable the schedules for the build and turn them back on afterwards:

```sh
terraform apply -var enable_scheduler=false
# once the cluster is up and verified:
terraform apply          # default enable_scheduler=true recreates the schedules
```

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

### Argo CD (M3)

Terraform installs Argo CD and exactly one Argo CD object — the `root` Application. Everything after that is reconciled from `argocd/apps/` in this repo, so Terraform's involvement with the cluster ends here.

```sh
scripts/verify-m3.sh

kubectl -n argocd port-forward svc/argocd-server 8080:80   # http://localhost:8080
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

The server runs with `server.insecure=true` and is reached over plain HTTP via port-forward; TLS moves to ingress-nginx in M4.

One app ships in this milestone: `argocd`, which **adopts** the Helm release Terraform seeded rather than installing a second copy.

Argo CD's configuration is declared once, in the chart it self-manages from:

| File | Holds | Read by |
|------|-------|---------|
| `argocd/platform/argocd/values.yaml` | chart values | Argo CD (from Git) **and** `terraform/09-argocd.tf` (from disk) |
| `argocd/platform/argocd/Chart.yaml` | chart version | same |

Terraform's only transformation is stripping the `argo-cd:` subchart wrapper, so the seeded release and the adopted one match by construction — there is no second copy to keep in sync (verified: 44/44 rendered resources match).

| Wave | App | Adopts |
|-----:|-----|--------|
| -1 | `argocd` | the Helm release seeded by `terraform/09-argocd.tf` |

**Cilium is deliberately not managed by Argo CD.** A cold bootstrap has to install the CNI before Argo CD can schedule a single pod, so Terraform owns `helm_release.cilium` permanently (`terraform/05-cilium.tf`). Do **not** run `terraform state rm helm_release.cilium` — `05-cilium.tf` still declares the resource, so the next apply would try to create a Helm release name that already exists and fail. One owner, no handover.

Later milestones add their own file to `argocd/apps/` at the wave the [implementation plan](#roadmap) assigns (ebs-csi/LBC at 1, ingress-nginx at 2, cert-manager/external-dns at 3, and so on).

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
│   ├── 03-scheduler.tf    # nightly stop/start via EventBridge Scheduler (var.enable_scheduler)
│   ├── 04-talos.tf        # Talos: secrets, machine configs, apply, bootstrap, kubeconfig, wait_for_apiserver
│   ├── 05-cilium.tf       # Cilium Helm release (kube-proxy replacement, Hubble UI)
│   ├── 06-s3.tf           # S3 bucket hosting the self-hosted OIDC discovery docs (M2)
│   ├── 07-irsa.tf         # OIDC provider + IAM roles for EBS CSI / LBC / Velero (M2)
│   ├── 08-velero-bucket.tf # Velero backup bucket, versioned + lifecycle (M2)
│   ├── 09-argocd.tf       # Argo CD Helm seed + SOPS age key Secret (M3); values read from argocd/platform/argocd/
│   ├── 10-argocd-root-app.tf # App-of-Apps root Application (M3)
│   ├── charts/argocd-root-app/ # one-Application local chart used by the above
│   └── outputs.tf         # node IPs + kubeconfig/talosconfig paths
├── scripts/
│   ├── verify-m2.sh       # end-to-end IRSA + AWS prereq verification
│   └── verify-m3.sh       # Argo CD seed, root app, SOPS tooling, Cilium handover
├── argocd/                # App-of-Apps tree (populated per milestone)
│   ├── apps/              # child Applications, sync-wave ordered
│   │   └── argocd.yaml    # wave -1: Argo CD self-management
│   ├── platform/          # cluster services (argocd/ so far)
│   │   └── argocd/        # single source of truth for Argo CD's chart + values
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
5. **IRSA + AWS prereqs** (M2) — done (self-hosted OIDC discovery on S3, IAM roles for EBS CSI / LBC / Velero, VPC tags, Velero S3 bucket)
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
- The "Terraform allow-all-egress trap"
