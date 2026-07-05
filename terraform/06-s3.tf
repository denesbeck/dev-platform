resource "aws_s3_bucket" "dev_platform_oidc_bucket" {
  bucket = local.oidc_bucket

  tags = {
    Name = "dev-platform"
  }
}

resource "aws_s3_bucket_public_access_block" "dev_platform_public_access_block" {
  bucket = aws_s3_bucket.dev_platform_oidc_bucket.id

  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

data "aws_iam_policy_document" "dev_platform_policy_doc" {
  statement {
    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = [
      "s3:GetObject",
    ]

    resources = [
      "${aws_s3_bucket.dev_platform_oidc_bucket.arn}/*",
    ]
  }
}

resource "aws_s3_bucket_policy" "dev_platform_bucket_policy" {
  depends_on = [aws_s3_bucket_public_access_block.dev_platform_public_access_block]

  bucket = aws_s3_bucket.dev_platform_oidc_bucket.id
  policy = data.aws_iam_policy_document.dev_platform_policy_doc.json
}

resource "null_resource" "extract_jwks" {
  depends_on = [
    talos_cluster_kubeconfig.this,
    data.talos_cluster_health.this,
    local_sensitive_file.kubeconfig,
  ]

  triggers = {
    cluster_id = talos_machine_secrets.this.id
    eip        = aws_eip.master.public_ip
  }

  provisioner "local-exec" {
    interpreter = ["/bin/sh", "-c"]
    command     = <<-EOT
      export KUBECONFIG="${path.module}/../kubeconfig"
      # Retry: installing Cilium (kube-proxy replacement) briefly restarts the
      # kube-apiserver static pod as the CNI initializes, so a single-shot
      # `kubectl get --raw` here can hit "connection refused". Same reason
      # wait_for_apiserver in 04-talos.tf loops.
      for i in $(seq 1 30); do
        if kubectl get --raw /openid/v1/jwks > "${path.module}/jwks.json" 2>/dev/null \
          && kubectl get --raw /.well-known/openid-configuration > "${path.module}/openid-configuration.json" 2>/dev/null; then
          echo "fetched OIDC discovery + JWKS after $i attempt(s)"
          exit 0
        fi
        echo "attempt $i/30: apiserver not serving OIDC yet, retrying in 5s"
        sleep 5
      done
      echo "timed out fetching OIDC discovery/JWKS from kube-apiserver" >&2
      exit 1
    EOT
  }
}

# etag omitted: files don't exist at plan time (created by extract_jwks at apply).
resource "aws_s3_object" "jwks" {
  depends_on = [null_resource.extract_jwks]

  bucket = aws_s3_bucket.dev_platform_oidc_bucket.id
  key    = "openid/v1/jwks"
  source = "${path.module}/jwks.json"
}

resource "aws_s3_object" "openid_configuration" {
  depends_on = [null_resource.extract_jwks]

  bucket = aws_s3_bucket.dev_platform_oidc_bucket.id
  key    = ".well-known/openid-configuration"
  source = "${path.module}/openid-configuration.json"
}
