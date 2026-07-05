resource "aws_s3_bucket" "velero" {
  bucket = local.velero_bucket

  tags = {
    Name = "dev-platform"
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "velero_versioning" {
  bucket = aws_s3_bucket.velero.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "velero_lifecycle_config" {
  depends_on = [aws_s3_bucket_versioning.velero_versioning]

  bucket = aws_s3_bucket.velero.id
  rule {
    id     = "velero_exp_rule"
    status = "Enabled"

    filter {}

    expiration {
      days = 30
    }
    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
}
