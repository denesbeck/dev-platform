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

Early stage. **VPC + compute scaffolding defined in Terraform; not yet applied.** Today:

- [x] VPC, public subnet, IGW, route table, RT association
- [x] Security group for cluster nodes (Talos API + kube-apiserver from operator CIDR; full intra-cluster; egress all)
- [x] EC2 definitions — 1 on-demand master + 2 spot workers on a Talos AMI
- [ ] Talos machine configs + cluster bootstrap
- [ ] Argo CD seed + App-of-Apps root
- [ ] Cluster foundation (Cilium, ingress-nginx, cert-manager, …)
- [ ] Platform services (OneDev, observability, security)
- [ ] First hosted app (Vaultwarden)

## Quick start

### Prerequisites

- Terraform `>= 1.6`
- AWS credentials with VPC + EC2 permissions
- `talosctl`, `kubectl` (for the post-apply cluster bootstrap)

The Talos AMI is resolved automatically via a `data "aws_ami"` lookup for the latest Sidero Labs `talos-v*` release matching your region and `x86_64`.

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

Brings up the VPC and 3 EC2 instances. Talos boots in **maintenance mode** — machine config is applied separately via `talosctl` once the instances are reachable.

Read the node IPs:

```sh
terraform output
```

Master IP is stable (Elastic IP); worker IPs change on each start.

## Repository layout

```text
dev-platform/
├── README.md              # this file
├── docs/                  # write-ups documenting design decisions
├── terraform/             # AWS infra
│   ├── providers.tf       # provider config + default tags
│   ├── 00-network.tf      # VPC, subnet, IGW, route table
│   ├── 01-compute.tf      # EC2 (master + workers)
│   ├── 02-security-groups.tf
│   ├── 03-scheduler.tf    # nightly stop/start via EventBridge Scheduler
│   └── outputs.tf         # node IPs surfaced via `terraform output`
└── talos/                 # Talos machine configs (TBD)
```

Planned: `argocd/` (App-of-Apps manifests), `policies/` (Kyverno), `.github/` (CI gates).

## Roadmap

1. **Network + compute** — done
2. **Talos bootstrap** — generate machine configs, apply, fetch kubeconfig
3. **GitOps seed** — install Argo CD via Terraform, point it at this repo
4. **Cluster foundation** — Cilium, NGINX Ingress, cert-manager, external-dns, EBS CSI, AWS LB Controller
5. **Platform services** — OneDev, observability stack, security tooling
6. **First app** — Vaultwarden, end-to-end TLS + DNS + storage + backup

## Cost

Cluster runs on small EC2 instances — roughly $50/month if left running 24/7, far less when `terraform destroy` is the norm between sessions. EBS volumes and S3 (for Velero backups, once that's in place) carry small standing costs even after the EC2s are destroyed.

**Nightly shutdown:** EventBridge Scheduler stops all three nodes at 21:00 Europe/Berlin and starts them again at 05:00 — an 8-hour daily gap, ~33% compute savings. Spot workers run as `persistent` so they can be stopped/started by the API. The master holds an Elastic IP (~$1.22/month for the nightly stopped hours; free while running) so its public IP is stable across stop/start; worker IPs still rotate on each start.

## Documentation

Each significant decision lands in `docs/`. Planned write-ups:

- The design pivot from bare metal to AWS spot
- NGINX Ingress vs AWS NLB (L4 vs L7)
- Stateful pods on a spot fleet
- IRSA in practice
- App-of-Apps with Argo CD
- Velero to S3 — disaster recovery drills
- Vaultwarden, the full path
- The "Terraform allow-all-egress trap"
