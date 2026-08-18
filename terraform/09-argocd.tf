# M3: the Argo CD "seed". This is the last thing Terraform installs onto the
# cluster — from here on, Argo CD reconciles the platform from Git and Terraform
# stays out of the way (see 10-argocd-root-app.tf).
#
# Argo CD self-manages after the seed: argocd/platform/argocd/ holds the same
# chart + values, so the root app adopts this release on its first sync. Keep
# the chart version here and in argocd/platform/argocd/Chart.yaml identical,
# otherwise the first sync shows drift and Argo CD immediately upgrades itself.
#
# Footprint note: 3 x t3a.medium (4 GiB each) is not much, so dex and
# notifications are disabled and every component carries explicit requests and
# limits. The ApplicationSet controller has no enable flag in this chart and is
# always installed, so it is capped rather than switched off.

locals {
  argocd_namespace     = "argocd"
  argocd_chart_version = "10.3.3" # Argo CD v3.5.1
  sops_version         = "v3.13.3"

  # repo-server reads the key from this path; the Secret is mounted here.
  sops_age_key_dir = "/home/argocd/.config/sops/age"
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
    name      = "argocd-sops-age-key"
    namespace = kubernetes_namespace.argocd.metadata[0].name
  }

  # "keys.txt" matches the SOPS_AGE_KEY_FILE convention used locally (M0).
  data = {
    "keys.txt" = var.sops_age_key
  }

  type = "Opaque"
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

  values = [
    yamlencode({
      crds = {
        install = true
        # Survive a `helm uninstall` so Applications aren't cascade-deleted by
        # an accidental teardown of the release.
        keep = true
      }

      # No SSO and no notifications yet; both cost memory we don't have.
      dex = {
        enabled = false
      }
      notifications = {
        enabled = false
      }

      # The chart has no applicationSet.enabled flag — the controller is always
      # installed — so cap it instead of trying to switch it off. Nothing uses
      # ApplicationSets yet; this is idle overhead until something does.
      applicationSet = {
        resources = {
          requests = { cpu = "25m", memory = "64Mi" }
          limits   = { memory = "192Mi" }
        }
      }

      configs = {
        params = {
          # Serve plaintext HTTP. TLS terminates at ingress-nginx in M4; until
          # then reach the UI with `kubectl port-forward`.
          "server.insecure" = true
        }
      }

      controller = {
        resources = {
          requests = { cpu = "100m", memory = "256Mi" }
          limits   = { memory = "1Gi" }
        }
      }

      server = {
        resources = {
          requests = { cpu = "50m", memory = "128Mi" }
          limits   = { memory = "512Mi" }
        }
      }

      redis = {
        resources = {
          requests = { cpu = "50m", memory = "64Mi" }
          limits   = { memory = "256Mi" }
        }
      }

      # SOPS wiring: an init container drops the static sops binary onto a
      # shared emptyDir, which is then mounted into repo-server's PATH. The age
      # key arrives from the Secret above via SOPS_AGE_KEY_FILE.
      #
      # This makes `sops` available to repo-server; the plugin that *calls* it
      # (helm-secrets or a CMP) gets wired up in M4, when the first encrypted
      # secret — the Cloudflare API token — actually needs decrypting.
      repoServer = {
        resources = {
          requests = { cpu = "100m", memory = "256Mi" }
          limits   = { memory = "1Gi" }
        }

        initContainers = [
          {
            name    = "install-sops"
            image   = "alpine:3.22"
            command = ["sh", "-c"]
            args = [
              "wget -qO /custom-tools/sops https://github.com/getsops/sops/releases/download/${local.sops_version}/sops-${local.sops_version}.linux.amd64 && chmod +x /custom-tools/sops",
            ]
            volumeMounts = [
              { name = "custom-tools", mountPath = "/custom-tools" },
            ]
            # Mirrors repoServer.containerSecurityContext from the chart
            # defaults; the emptyDir stays writable regardless.
            securityContext = {
              runAsNonRoot             = true
              runAsUser                = 999
              readOnlyRootFilesystem   = true
              allowPrivilegeEscalation = false
              seccompProfile           = { type = "RuntimeDefault" }
              capabilities             = { drop = ["ALL"] }
            }
          },
        ]

        volumes = [
          { name = "custom-tools", emptyDir = {} },
          {
            name = "sops-age-key"
            secret = {
              secretName  = kubernetes_secret.sops_age_key.metadata[0].name
              defaultMode = 292 # 0444
            }
          },
        ]

        volumeMounts = [
          {
            name = "custom-tools"
            # subPath so we graft a single file into an existing directory
            # instead of shadowing all of /usr/local/bin.
            mountPath = "/usr/local/bin/sops"
            subPath   = "sops"
          },
          {
            name      = "sops-age-key"
            mountPath = local.sops_age_key_dir
            readOnly  = true
          },
        ]

        env = [
          {
            name  = "SOPS_AGE_KEY_FILE"
            value = "${local.sops_age_key_dir}/keys.txt"
          },
        ]
      }
    })
  ]
}
