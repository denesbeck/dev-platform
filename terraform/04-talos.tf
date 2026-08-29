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
  talos_version      = "v${var.talos_version}"
  kubernetes_version = "v${var.kubernetes_version}"
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
          # IRSA: make the cluster a usable OIDC provider for AWS STS.
          # extraArgs is a map (key => value), and keys have NO leading "--".
          extraArgs = {
            # Stamps this URL as the `iss` claim in SA tokens and as `issuer`
            # in the served discovery doc. Must equal local.oidc_issuer used by
            # 06-s3.tf and the OIDC provider, byte for byte.
            service-account-issuer = local.oidc_issuer
            # Sets `jwks_uri` in the discovery doc to where 06-s3.tf uploads the
            # keys (bucket key "openid/v1/jwks"). Explicit so we don't rely on
            # the apiserver's <issuer>/openid/v1/jwks default.
            service-account-jwks-uri = "${local.oidc_issuer}/openid/v1/jwks"
            # api-audiences DEFAULTS to service-account-issuer once that is set,
            # which would reject pod tokens requesting aud=sts.amazonaws.com.
            # Include both: sts (for IRSA) and the issuer (for in-cluster tokens).
            api-audiences = "sts.amazonaws.com,${local.oidc_issuer}"
          }
        }
        # Disable Flannel (default) and kube-proxy — Cilium replaces both.
        # Must be set before bootstrap; swapping CNI on a live cluster is unsafe.
        network = {
          cni = {
            name = "none"
          }
        }
        proxy = {
          disabled = true
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

  config_patches = [
    yamlencode({
      cluster = {
        network = {
          cni = {
            name = "none"
          }
        }
        proxy = {
          disabled = true
        }
      }
    })
  ]
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

# Waits for kube-apiserver to start serving HTTPS via the EIP. The
# talos_cluster_health gate above sets skip_kubernetes_checks=true (its k8s
# probe targets the private cluster_endpoint, unreachable from a laptop), so
# it returns OK while the apiserver static pod is still starting. Any
# Terraform resource that connects through the kubernetes/helm providers
# (Cilium, future Argo CD) must wait on this.
#
# 200 and 401 both count as "up": apiserver runs with --anonymous-auth=false,
# so an unauthenticated /livez returns 401 — a valid TLS handshake against a
# live API server, which is exactly what we need before clients connect.
resource "null_resource" "wait_for_apiserver" {
  depends_on = [
    talos_cluster_kubeconfig.this,
    data.talos_cluster_health.this,
    # The probe below (and every kubernetes/helm resource downstream of this
    # one) reaches the cluster through these ingress rules. Declaring that here
    # also fixes destroy ordering: destroy runs in reverse, so the rules stay
    # open until everything cluster-side has been torn down — without this edge
    # they get revoked in the first wave and helm uninstalls die with
    # "cluster unreachable ... :6443: i/o timeout".
    aws_vpc_security_group_ingress_rule.kube_api,
    aws_vpc_security_group_ingress_rule.talos_api,
  ]

  triggers = {
    cluster_id = talos_machine_secrets.this.id
    eip        = aws_eip.master.public_ip
  }

  provisioner "local-exec" {
    interpreter = ["/bin/sh", "-c"]
    command     = <<-EOT
      for i in $(seq 1 60); do
        code=$(curl -ks -o /dev/null -w '%%{http_code}' --max-time 5 https://${aws_eip.master.public_ip}:6443/livez || echo 000)
        if [ "$code" = "200" ] || [ "$code" = "401" ]; then
          echo "kube-apiserver responding (HTTP $code) after $i attempts"
          exit 0
        fi
        echo "attempt $i/60: kube-apiserver not ready (HTTP $code), retrying in 5s"
        sleep 5
      done
      echo "timed out waiting for kube-apiserver at https://${aws_eip.master.public_ip}:6443" >&2
      exit 1
    EOT
  }
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
