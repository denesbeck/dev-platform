# Talos bootstrap runbook

End-to-end steps to bring a freshly-applied `terraform apply` from "three EC2 instances booted into Talos maintenance mode" to "a working Kubernetes cluster with a `kubeconfig` on your laptop."

Assumes:

- `terraform apply` succeeded; you have `master_public_ip` and `worker_public_ips` from `terraform output`.
- Your operator IP is current in `terraform.tfvars` (residential ISPs rotate — re-check before starting).
- `talosctl` and `kubectl` are installed locally.

---

## 0. Sanity checks before you start

```sh
# AWS SSO session not expired
aws sts get-caller-identity --profile cloudgoat-lab

# Your current public IP matches operator_cidr in terraform.tfvars
curl -s https://api.ipify.org; echo
grep operator_cidr terraform/terraform.tfvars

# TCP reachability to the master's Talos API
nc -vz <MASTER_IP> 50000
```

If `nc` doesn't say "succeeded", fix that first — every step below assumes the SG lets you through.

---

## 1. Generate machine configs

From the repo root:

```sh
cd talos/

MASTER_IP=<MASTER_IP>

talosctl gen config dev-platform "https://${MASTER_IP}:6443" \
  --additional-sans "${MASTER_IP}"
```

`--additional-sans` adds the public EIP to the apiserver and Talos API certs. Without it, every `kubectl` call from your laptop fails cert verification.

Outputs three files (all gitignored):

- `controlplane.yaml` — applied to the master
- `worker.yaml` — applied to both workers
- `talosconfig` — your client cert for `talosctl`

---

## 2. Point `talosctl` at the new config

**Order matters.** `TALOSCONFIG` must be exported *before* any `talosctl config ...` subcommand, or it writes to `~/.talos/config` (default) and the next steps fail with "no context is set".

`endpoint` and `node` are **not** the same thing and **must not** be the same value on AWS:

- `endpoint` is what your laptop dials → **public EIP**.
- `node` is what the endpoint proxies the RPC to → **private IP**.

Setting `node` to the public EIP makes the master try to dial its own EIP from inside the VPC, which AWS black-holes (the "EIP hairpin" problem). See [aws-eip-hairpin.md](./aws-eip-hairpin.md) for the full explanation and a reproducible diagnostic.

```sh
export TALOSCONFIG="$PWD/talosconfig"

MASTER_PRIVATE_IP=$(cd ../terraform && terraform output -raw master_private_ip)

talosctl config endpoint "${MASTER_IP}"           # public EIP — laptop dials this
talosctl config node     "${MASTER_PRIVATE_IP}"   # private IP — endpoint proxies to this

talosctl config info   # verify endpoints/nodes are populated and DIFFERENT
```

Add `export TALOSCONFIG=...` to your shell rc or a `.envrc` if you don't want to repeat it.

---

## 3. Apply machine configs (maintenance mode → configured)

Nodes boot into **maintenance mode**: API on `:50000`, no identity, accepts `--insecure` once.

```sh
WORKER1_IP=<WORKER1_IP>
WORKER2_IP=<WORKER2_IP>

talosctl apply-config --insecure -n "${MASTER_IP}"  -f controlplane.yaml
talosctl apply-config --insecure -n "${WORKER1_IP}" -f worker.yaml
talosctl apply-config --insecure -n "${WORKER2_IP}" -f worker.yaml
```

Each node reboots into "configured" state in ~30–60s. From here on, the production mTLS API is enforced — `--insecure` will be rejected with `tls: certificate required`. That rejection means the node is configured, not broken.

Watch boot progress (optional):

```sh
talosctl --insecure -n "${MASTER_IP}" dmesg --follow
```

---

## 4. Bootstrap etcd (master only, exactly once)

After the master finishes rebooting:

```sh
talosctl version   # confirms mTLS works end-to-end before bootstrap
talosctl bootstrap
```

`bootstrap` initialises a new etcd cluster on the master. **Run it once, on the master only.** Running it twice or on a worker creates a split-brain etcd.

Wait ~30–60s for etcd → kube-apiserver → kubelet to come up:

```sh
talosctl health
```

---

## 5. Fetch kubeconfig

```sh
talosctl kubeconfig ../kubeconfig
export KUBECONFIG="$(cd .. && pwd)/kubeconfig"

kubectl get nodes
```

Three nodes appear, status `NotReady` until a CNI is installed. That's the next chapter (Cilium).

---

## Troubleshooting

### `nc -vz <IP> 50000` times out

Security group is blocking. Almost always: your public IP changed.

```sh
echo "operator_cidr = \"$(curl -s https://api.ipify.org)/32\"" > terraform/terraform.tfvars
cd terraform && terraform apply
```

### `talosctl bootstrap` → `i/o timeout dialing :50000`, but `nc` succeeds

TCP works, gRPC doesn't → almost always one of:

- **`node` set to the public EIP (AWS EIP hairpin).** The most common cause on this stack. `talosctl config info` shows the same IP for both endpoint and node. The master receives the call on its EIP, then tries to forward to itself by dialing the EIP from inside the VPC — AWS drops it. Fix: set `node` to the private IP (see step 2). Full diagnosis in [aws-eip-hairpin.md](./aws-eip-hairpin.md).
- **`TALOSCONFIG` was not set** when `talosctl config endpoint/node` ran. `talosctl config info` will show empty endpoints. Re-export and re-run those subcommands.
- **HTTPS proxy env var.** Go's gRPC client honors `HTTPS_PROXY`/`HTTP_PROXY`; `nc` and `openssl` don't. Check `env | grep -i proxy` and either `unset` them or `export NO_PROXY=<MASTER_IP>,$NO_PROXY`.
- **SAN missing public IP.** Inspect with:
  ```sh
  echo | openssl s_client -connect <MASTER_IP>:50000 -showcerts 2>/dev/null \
    | openssl x509 -text -noout | grep -A3 "Subject Alternative Name"
  ```
  Should list `IP Address:<MASTER_IP>`. If missing, regen configs with `--additional-sans` (step 1) and re-apply. On an already-configured node this requires the mTLS API to work — chicken-and-egg. Easiest escape: `talosctl reset --graceful=false --reboot` to drop back to maintenance mode, then redo steps 1–4.

### `apply-config --insecure` returns `tls: certificate required`

Node is already configured (not in maintenance mode). Either skip the apply step (if intentional) or reset the node first:

```sh
talosctl reset --graceful=false --reboot -n <NODE_IP>
```

### `terraform apply` shows AWS credential errors

SSO session expired. `aws sso login --profile cloudgoat-lab`, then make sure `AWS_PROFILE=cloudgoat-lab` is exported in the shell running terraform.

---

## Tearing it down

```sh
cd terraform
terraform destroy
rm -f ../talos/{controlplane,worker}.yaml ../talos/talosconfig ../kubeconfig
```

Talos machine configs contain cluster secrets — don't keep stale copies once the cluster is gone.
