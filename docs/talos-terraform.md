# Talos bootstrap via the Terraform provider

Preferred way to bring up the cluster. One `terraform apply` does everything from EC2 to a working `kubeconfig`. Replaces the manual `talosctl` flow in [talos-bootstrap.md](./talos-bootstrap.md) (kept as a fallback).

---

## What it does

`terraform/04-talos.tf` declares the cluster as Terraform resources using the [`siderolabs/talos`](https://registry.terraform.io/providers/siderolabs/talos/latest) provider. The dependency graph:

```
aws_vpc / aws_subnet / aws_security_group
        │
        ▼
aws_instance.master, .worker (boot into maintenance mode)
        │
        ▼
talos_machine_secrets                       ← generates cluster PKI (lives in state)
        │
        ├─▶ data.talos_machine_configuration["controlplane" | "worker"]
        │       │
        │       ▼
        │   talos_machine_configuration_apply["master", "worker"[*]]
        │       │
        │       ▼
        │   talos_machine_bootstrap          ← one-shot etcd init
        │       │
        │       ▼
        │   data.talos_cluster_health        ← blocks until healthy
        │       │
        │       ▼
        │   talos_cluster_kubeconfig         ← fetches kubeconfig
        │
        └─▶ data.talos_client_configuration  ← builds talosconfig

local_sensitive_file.talosconfig → talos/talosconfig
local_sensitive_file.kubeconfig  → ./kubeconfig
```

Every cluster-bound resource (`apply`, `bootstrap`, `kubeconfig`, `cluster_health`) is configured with:

- `endpoint = aws_eip.master.public_ip` — what *your laptop* dials
- `node     = aws_instance.<role>.private_ip` — what *talosd* proxies the RPC to

That split is what dodges the AWS EIP-hairpin black hole — see [aws-eip-hairpin.md](./aws-eip-hairpin.md) for why.

---

## Prerequisites

- `terraform >= 1.6`, `aws` CLI with SSO logged in (`aws sso login --profile cloudgoat-lab`), `AWS_PROFILE` exported
- `terraform/terraform.tfvars` has a current `operator_cidr = "<your-public-IP>/32"` — residential ISPs rotate, double-check before applying
- `talosctl` and `kubectl` installed locally (only used post-apply for interacting with the cluster — the provider doesn't need them at apply time)

---

## Apply

From the repo root:

```sh
cd terraform
terraform init      # pulls siderolabs/talos and hashicorp/local on first run
terraform apply
```

Cold apply takes ~5–8 minutes:

1. AWS resources come up (~30s).
2. Provider waits for `talosd` on each node (~60–90s while the AMI boots).
3. Configs applied; nodes reboot into "configured" state (~60s).
4. `talos_machine_bootstrap` initializes etcd on the master.
5. `data.talos_cluster_health` blocks until kube-apiserver + kubelet are up on all three nodes (~60–120s).
6. `kubeconfig` and `talosconfig` written to disk.

When it finishes:

```sh
export TALOSCONFIG="$(terraform output -raw talosconfig_path)"
export KUBECONFIG="$(terraform output -raw kubeconfig_path)"

# `talosctl health` refuses to run when the talosconfig has multiple default
# `nodes` (which ours does — all three private IPs). Two things to pass:
#  -n <ONE>                          where to send the command (single dispatch node)
#  --control-plane-nodes / --worker-nodes   which nodes to check
MASTER=$(terraform output -raw master_private_ip)
WORKERS=$(terraform output -json worker_private_ips | jq -r 'join(",")')
talosctl -n "$MASTER" health --control-plane-nodes "$MASTER" --worker-nodes "$WORKERS"

kubectl get nodes    # three nodes, Ready (Talos ships Flannel as the default CNI)
```

---

## Day-2 operations

### Re-applying after a config change

Edit `04-talos.tf` (e.g. tweak `config_patches`), then `terraform apply`. The provider diffs the rendered machine config; for changes that require a reboot it does a rolling apply.

### Rotating the operator IP

Update `terraform/terraform.tfvars`:

```sh
echo "operator_cidr = \"$(curl -s https://api.ipify.org)/32\"" > terraform.tfvars
terraform apply
```

Only the SG rule changes; nothing in the cluster moves.

### Destroying

```sh
terraform destroy
```

Tears down everything: cluster, EC2, EIP, SG, VPC. The PKI in state simply disappears. The local `talos/talosconfig` and `kubeconfig` files are left on disk (Terraform doesn't delete files written by `local_sensitive_file`); remove them manually if you want a clean slate.

---

## What lives where (secrets)

The provider stores cluster PKI — including the OS CA private key and etcd CA private key — in Terraform state. Right now state is local at `terraform/terraform.tfstate` (gitignored). Implications:

- **Don't commit state.** Already handled by `.gitignore`.
- **If you ever switch to a remote backend** (S3, Terraform Cloud, etc.), make sure it's encrypted at rest and access is locked down. Anyone with read access to state can talk to the cluster as root.
- The manual flow stored secrets in `talos/controlplane.yaml`. The provider flow moves that storage into state. Same blast radius locally; different operational consideration if state moves off the laptop.

---

## Switching from the manual flow

If you already have a cluster up from the manual `talosctl` runbook, the cleanest path is destroy + recreate:

```sh
# 1. Tear the existing cluster down (the talosctl-generated files are stale anyway)
cd terraform
terraform destroy

# 2. Remove the leftover manually-generated configs (provider will regenerate)
rm -f ../talos/{controlplane,worker}.yaml ../talos/talosconfig ../kubeconfig

# 3. terraform.tf adds the new providers — pull them
terraform init -upgrade

# 4. Bring everything up
terraform apply
```

Trying to "import" the existing cluster into the provider (so it doesn't get recreated) is possible (`terraform import talos_machine_secrets.this <path-to-secrets.yaml>`) but fragile, and only worth it if the running cluster has irreplaceable state. For a fresh dev cluster with no workloads, destroy + recreate is faster and produces a known-clean result.

---

## Troubleshooting

- **`talos_machine_configuration_apply` times out connecting to a node**: same EIP-hairpin pitfall as the manual flow. Double-check that `endpoint = aws_eip.master.public_ip` and `node = aws_instance.<role>.private_ip` — they must be different IPs. See [aws-eip-hairpin.md](./aws-eip-hairpin.md).
- **First apply fails with "no route to host" or "connection refused"**: the EC2 instance is still booting. Re-run `terraform apply` — the next run picks up where the last left off.
- **`terraform apply` shows AWS credential errors**: SSO session expired. `aws sso login --profile cloudgoat-lab`, ensure `AWS_PROFILE=cloudgoat-lab` is exported, retry.
- **Operator IP rotated mid-apply**: SG ingress rule still references the old CIDR. Update `terraform.tfvars` and re-apply. The talos resources will resume once the SG converges.
- **For anything else**, the manual runbook's [troubleshooting section](./talos-bootstrap.md#troubleshooting) is still the canonical reference — the underlying failure modes are the same; only the orchestration changed.
