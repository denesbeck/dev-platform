# M3: the root Application (App-of-Apps). Terraform creates exactly one Argo CD
# object; everything else in the platform is a child of this app, discovered
# from argocd/apps/ in this repo.
#
# Why a local chart instead of kubernetes_manifest: kubernetes_manifest fetches
# the resource's OpenAPI schema from the API server during *plan*, so a fresh
# `terraform apply` against a cluster that does not exist yet (or that has no
# argoproj.io CRDs) fails before it can create anything. helm_release does all
# its work at apply time, so it survives cold bootstraps.

resource "helm_release" "argocd_root_app" {
  name      = "argocd-root-app"
  chart     = "${path.module}/charts/argocd-root-app"
  namespace = kubernetes_namespace.argocd.metadata[0].name

  # The argoproj.io CRDs ship with the Argo CD release.
  depends_on = [helm_release.argocd]

  values = [
    yamlencode({
      name           = "root"
      namespace      = kubernetes_namespace.argocd.metadata[0].name
      repoURL        = var.git_repo_url
      targetRevision = var.git_target_revision
      path           = "argocd/apps"
    })
  ]
}
