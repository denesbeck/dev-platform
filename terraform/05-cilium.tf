# Installs Cilium onto the bare cluster after Talos bootstrap. Replaces Flannel
# (disabled in 04-talos.tf) and kube-proxy. Must run on an empty cluster — once
# workloads exist, swapping CNI is unsafe.
#
# Talos-specific values:
#   - kubeProxyReplacement: Cilium handles service routing in eBPF
#   - k8sServiceHost/Port: Talos exposes a localhost API proxy on :7445, so
#     cilium-agent on each node can reach the API without a working CNI
#   - cgroup overrides: Talos mounts cgroup2 at /sys/fs/cgroup directly
#   - ipam.mode = kubernetes: pod CIDRs come from the node spec, not Cilium
#     cluster pool (simpler, matches what kube-controller-manager allocates)
#
# This resource gets adopted by Argo CD in M3. After adoption, run
# `terraform state rm helm_release.cilium` so Terraform and Argo CD don't fight.

resource "helm_release" "cilium" {
  name             = "cilium"
  repository       = "https://helm.cilium.io/"
  chart            = "cilium"
  version          = "1.16.5"
  namespace        = "kube-system"
  create_namespace = false

  # Cluster must be healthy and kubeconfig written before Helm can connect.
  depends_on = [
    talos_cluster_kubeconfig.this,
    data.talos_cluster_health.this,
  ]

  values = [
    yamlencode({
      kubeProxyReplacement = true

      k8sServiceHost = "localhost"
      k8sServicePort = "7445"

      cgroup = {
        autoMount = {
          enabled = false
        }
        hostRoot = "/sys/fs/cgroup"
      }

      ipam = {
        mode = "kubernetes"
      }

      # Security context required for eBPF on Talos
      securityContext = {
        capabilities = {
          ciliumAgent      = ["CHOWN", "KILL", "NET_ADMIN", "NET_RAW", "IPC_LOCK", "SYS_ADMIN", "SYS_RESOURCE", "DAC_OVERRIDE", "FOWNER", "SETGID", "SETUID"]
          cleanCiliumState = ["NET_ADMIN", "SYS_ADMIN", "SYS_RESOURCE"]
        }
      }

      hubble = {
        enabled = true
        relay = {
          enabled = true
        }
        ui = {
          enabled = true
        }
      }
    })
  ]
}
