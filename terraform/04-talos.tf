# Bootstraps Talos onto the EC2 instances declared in 01-compute.tf using the
# siderolabs/talos provider. Replaces the manual `talosctl` runbook flow.
#
# Every call from your laptop into the cluster uses the endpoint/node split:
#   endpoint = master EIP   (what this machine dials over the internet)
#   node     = private IP   (what talosd proxies the RPC to over the VPC)
# This avoids the AWS EIP-hairpin black hole. See docs/aws-eip-hairpin.md.

# Pinned to match the Talos AMI selected in 01-compute.tf (talos-v1.12*).
# Bump both lines together when upgrading.
locals {
  talos_version      = "v1.12"
  kubernetes_version = "v1.34.1"
}

resource "talos_machine_secrets" "this" {
  talos_version = local.talos_version
}

data "talos_machine_configuration" "controlplane" {
  cluster_name       = "dev-platform"
  machine_type       = "controlplane"
  cluster_endpoint   = "https://${aws_instance.master.private_ip}:6443"
  machine_secrets    = talos_machine_secrets.this.machine_secrets
  talos_version      = local.talos_version
  kubernetes_version = local.kubernetes_version

  config_patches = [
    yamlencode({
      machine = {
        certSANs = [
          aws_eip.master.public_ip,
          aws_instance.master.private_ip,
        ]
      }
      cluster = {
        apiServer = {
          certSANs = [
            aws_eip.master.public_ip,
            aws_instance.master.private_ip,
          ]
        }
      }
    })
  ]
}

data "talos_machine_configuration" "worker" {
  cluster_name       = "dev-platform"
  machine_type       = "worker"
  cluster_endpoint   = "https://${aws_instance.master.private_ip}:6443"
  machine_secrets    = talos_machine_secrets.this.machine_secrets
  talos_version      = local.talos_version
  kubernetes_version = local.kubernetes_version
}

data "talos_client_configuration" "this" {
  cluster_name         = "dev-platform"
  client_configuration = talos_machine_secrets.this.client_configuration

  endpoints = [aws_eip.master.public_ip]
  nodes = concat(
    [aws_instance.master.private_ip],
    aws_instance.worker[*].private_ip,
  )
}

resource "talos_machine_configuration_apply" "controlplane" {
  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.controlplane.machine_configuration

  # Force a reboot to transition cleanly from maintenance to configured mode.
  # `auto` was observed to leave Talos 1.12.8 stuck in maintenance stage with
  # config persisted but no services started — see docs/aws-eip-hairpin.md notes.
  apply_mode = "reboot"

  endpoint = aws_eip.master.public_ip
  node     = aws_instance.master.private_ip

  depends_on = [aws_eip_association.master]
}

resource "talos_machine_configuration_apply" "worker" {
  count = length(aws_instance.worker)

  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.worker.machine_configuration

  apply_mode = "reboot"

  # In maintenance mode the Talos API does NOT honor the endpoint→node proxy
  # semantic — that's an mTLS-only feature. Every apply call lands at whatever
  # `endpoint` is set to, with `node` ignored. So the first apply to each
  # worker must dial the worker directly on its own public IP. Once configured,
  # day-2 talosctl calls can route through the master via mTLS as usual.
  endpoint = aws_instance.worker[count.index].public_ip
  node     = aws_instance.worker[count.index].private_ip
}

resource "talos_machine_bootstrap" "this" {
  depends_on = [talos_machine_configuration_apply.controlplane]

  client_configuration = talos_machine_secrets.this.client_configuration
  endpoint             = aws_eip.master.public_ip
  node                 = aws_instance.master.private_ip
}

data "talos_cluster_health" "this" {
  depends_on = [
    talos_machine_configuration_apply.controlplane,
    talos_machine_configuration_apply.worker,
    talos_machine_bootstrap.this,
  ]

  client_configuration = talos_machine_secrets.this.client_configuration
  control_plane_nodes  = [aws_instance.master.private_ip]
  worker_nodes         = aws_instance.worker[*].private_ip
  endpoints            = [aws_eip.master.public_ip]

  # The k8s portion of this check hits cluster_endpoint (the master's private
  # IP) directly, which Terraform on the laptop can't reach. Talos-level health
  # (etcd, apid, kubelet, boot) is sufficient as a gate; we verify k8s itself
  # with `kubectl get nodes` after the kubeconfig is written.
  skip_kubernetes_checks = true
}

resource "talos_cluster_kubeconfig" "this" {
  depends_on = [data.talos_cluster_health.this]

  client_configuration = talos_machine_secrets.this.client_configuration
  endpoint             = aws_eip.master.public_ip
  node                 = aws_instance.master.private_ip
}

resource "local_sensitive_file" "talosconfig" {
  content         = data.talos_client_configuration.this.talos_config
  filename        = "${path.module}/../talos/talosconfig"
  file_permission = "0600"
}

resource "local_sensitive_file" "kubeconfig" {
  # The cluster's internal endpoint is the master's private IP (so intra-cluster
  # traffic doesn't hairpin through the EIP). Rewrite to the public EIP for
  # laptop use; the cert SAN list covers both IPs.
  content = replace(
    talos_cluster_kubeconfig.this.kubeconfig_raw,
    "https://${aws_instance.master.private_ip}:6443",
    "https://${aws_eip.master.public_ip}:6443",
  )
  filename        = "${path.module}/../kubeconfig"
  file_permission = "0600"
}
