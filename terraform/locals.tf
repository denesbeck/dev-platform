locals {
  oidc_bucket   = "dev-platform-oidc-${data.aws_caller_identity.current.account_id}"
  oidc_issuer   = "https://${local.oidc_bucket}.s3.${data.aws_region.current.region}.amazonaws.com"
  velero_bucket = "dev-platform-velero-${data.aws_caller_identity.current.account_id}"
}
