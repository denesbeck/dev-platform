# M3: the Argo CD "seed". This is the last thing Terraform installs onto the
# cluster — from here on, Argo CD reconciles the platform from Git and Terraform
# stays out of the way (see 10-argocd-root-app.tf).
#
# Argo CD self-manages after the seed, and there is exactly one copy of its
# configuration — not in this file:
#
#   argocd/platform/argocd/values.yaml  → chart values
#   argocd/platform/argocd/Chart.yaml   → chart version
#
# Terraform reads both off disk, so a cold bootstrap installs precisely what
# Argo CD will later find in Git and adopt, and the first sync is a no-op by
# construction rather than by remembering to edit two files. Change Argo CD's
# configuration THERE; this file only decides when the release is installed and
# what it depends on.

locals {
  argocd_namespace = "argocd"

  # The self-managed chart that argocd/apps/argocd.yaml points Argo CD at.
  argocd_chart_dir = "${path.module}/../argocd/platform/argocd"

  # Helm nests a subchart's values under the dependency name; helm_release wants
  # them un-nested, so unwrap that one key. Nothing else is transformed — the
  # values go to Helm exactly as written in the file.
  argocd_values = yamldecode(file("${local.argocd_chart_dir}/values.yaml"))["argo-cd"]

  argocd_chart_version = one([
    for dep in yamldecode(file("${local.argocd_chart_dir}/Chart.yaml")).dependencies :
    dep.version if dep.name == "argo-cd"
  ])

  # Terraform owns the age key Secret (below), but the values file is what
  # mounts it, so read the name from there instead of repeating it.
  sops_secret_name = one([
    for vol in local.argocd_values.repoServer.volumes :
    vol.secret.secretName if vol.name == "sops-age-key"
  ])
}

resource "kubernetes_namespace" "argocd" {
  metadata {
    name = local.argocd_namespace
  }

  depends_on = [null_resource.wait_for_apiserver]
}

# The age private key, mounted into repo-server so `sops -d` works during
# manifest rendering. Not managed by Argo CD itself — it is a bootstrap
# dependency, and putting it in Git (even encrypted with itself) is circular.
resource "kubernetes_secret" "sops_age_key" {
  metadata {
    name      = local.sops_secret_name
    namespace = kubernetes_namespace.argocd.metadata[0].name
  }

  # "keys.txt" matches the SOPS_AGE_KEY_FILE convention used locally (M0) and
  # the mount path set in the values file.
  data = {
    "keys.txt" = var.sops_age_key
  }

  type = "Opaque"

  # Without this, a values file that stopped mounting the key fails much later
  # with an empty-name error from the API server.
  lifecycle {
    precondition {
      condition     = local.sops_secret_name != null
      error_message = "argocd/platform/argocd/values.yaml must declare a repoServer volume named \"sops-age-key\" with secret.secretName — that is the name this Secret is created under."
    }
  }
}

resource "helm_release" "argocd" {
  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = local.argocd_chart_version
  namespace  = kubernetes_namespace.argocd.metadata[0].name

  # CRDs land before the root Application in 10-argocd-root-app.tf tries to
  # create an argoproj.io/v1alpha1 object.
  create_namespace = false
  wait             = true
  timeout          = 900

  depends_on = [
    null_resource.wait_for_apiserver,
    kubernetes_secret.sops_age_key,
    # Without the CNI, Argo CD's pods sit in ContainerCreating with no IP and
    # only recover once Cilium lands. wait=true would eventually absorb that,
    # but it turns a 2m rollout into a race against the 900s timeout.
    helm_release.cilium,
  ]

  values = [yamlencode(local.argocd_values)]

  lifecycle {
    precondition {
      condition     = local.argocd_chart_version != null
      error_message = "argocd/platform/argocd/Chart.yaml must list an \"argo-cd\" dependency — its version is the chart version seeded here."
    }
  }
}
