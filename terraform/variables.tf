# Bare version, no leading "v" — the "v" is added at each use site
# ("talos-v${var.talos_version}*" for the AMI filter, "v${var.talos_version}"
# for the machine config). Setting "v1.12" here yields "talos-vv1.12*", which
# matches no AMI and fails with a confusing lookup error instead.
variable "talos_version" {
  type        = string
  default     = "1.12"
  description = "Talos version, without the leading v (e.g. 1.12)"

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+", var.talos_version))
    error_message = "talos_version must start with a bare MAJOR.MINOR, e.g. 1.12 (no leading v)."
  }
}

variable "kubernetes_version" {
  type        = string
  default     = "1.34.1"
  description = "Kubernetes version, without the leading v (e.g. 1.34.1)"

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.kubernetes_version))
    error_message = "kubernetes_version must be a bare MAJOR.MINOR.PATCH, e.g. 1.34.1 (no leading v)."
  }
}

# The age *private* key (AGE-SECRET-KEY-1...) whose public half is in .sops.yaml.
# Argo CD's repo-server needs it to decrypt *.enc.yaml at render time.
#
# Pass it via terraform.tfvars (gitignored) or TF_VAR_sops_age_key. Note that
# Terraform stores variable values in terraform.tfstate — which is why the state
# file is gitignored too. Anyone with the state file has this key.
variable "sops_age_key" {
  type        = string
  sensitive   = true
  description = "age private key used by Argo CD repo-server to decrypt SOPS-encrypted manifests"
}

# HTTPS, not the SSH remote: the repo is public, so Argo CD clones it without
# credentials. Switch to git@ and register an SSH key in Argo CD if it ever
# goes private.
variable "git_repo_url" {
  type        = string
  default     = "https://github.com/denesbeck/dev-platform.git"
  description = "Git repository Argo CD reconciles the platform from"
}

variable "git_target_revision" {
  type        = string
  default     = "main"
  description = "Branch, tag or commit the root Application tracks"
}

# Nightly stop/start schedules (03-scheduler.tf). Set false for a cold
# from-scratch build so the 21:00 stop can't fire mid-bootstrap; set it back to
# true once the cluster is up.
variable "enable_scheduler" {
  type        = bool
  default     = true
  description = "Create the nightly EC2 stop/start schedules"
}
