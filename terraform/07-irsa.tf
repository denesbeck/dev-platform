resource "aws_iam_openid_connect_provider" "irsa_oidc_provider" {
  depends_on = [aws_s3_object.jwks, aws_s3_object.openid_configuration]

  url = local.oidc_issuer

  client_id_list = [
    "sts.amazonaws.com",
  ]
}

locals {
  oidc_provider_identifier = replace(local.oidc_issuer, "https://", "")
}

# docs: https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document
data "aws_iam_policy_document" "ebs_csi_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.irsa_oidc_provider.arn]
    }

    # sub = subject – who the token is about
    # the ServiceAccount the pod runs as -> this token belongs to the EBS CSI controller
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider_identifier}:sub"
      # k8s standard format: system:serviceaccount:<namespace>:<serviceaccount-name>
      values = ["system:serviceaccount:kube-system:ebs-csi-controller-sa"]
    }

    # aud = audience – who the token is for
    # sts.amazonaws.com -> this token was created to be presented to AWS STS
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider_identifier}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ebs_csi" {
  name = "dev-platform-ebs-csi"
  # .json is the rendered JSON document, see: https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document
  assume_role_policy = data.aws_iam_policy_document.ebs_csi_assume.json
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

data "aws_iam_policy_document" "aws_lbc_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.irsa_oidc_provider.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider_identifier}:sub"
      values   = ["system:serviceaccount:kube-system:aws-load-balancer-controller"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider_identifier}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "aws_lbc" {
  name               = "dev-platform-aws-lbc"
  assume_role_policy = data.aws_iam_policy_document.aws_lbc_assume.json
}

resource "aws_iam_policy" "aws_lbc" {
  name   = "dev-platform-aws-lbc"
  policy = file("${path.module}/policies/aws-lbc-iam-policy.json")
}

resource "aws_iam_role_policy_attachment" "aws_lbc" {
  role       = aws_iam_role.aws_lbc.name
  policy_arn = aws_iam_policy.aws_lbc.arn
}

data "aws_iam_policy_document" "velero_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.irsa_oidc_provider.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider_identifier}:sub"
      values   = ["system:serviceaccount:velero:velero-server"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider_identifier}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "velero" {
  name               = "dev-platform-velero"
  assume_role_policy = data.aws_iam_policy_document.velero_assume.json
}

data "aws_iam_policy_document" "velero" {
  statement { # EC2 snapshots
    effect = "Allow"
    actions = ["ec2:DescribeVolumes", "ec2:DescribeSnapshots", "ec2:CreateTags",
    "ec2:CreateVolume", "ec2:CreateSnapshot", "ec2:DeleteSnapshot"]
    resources = ["*"]
  }
  statement { # object ops on the bucket contents
    effect = "Allow"
    actions = ["s3:GetObject", "s3:DeleteObject", "s3:PutObject",
    "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"]
    resources = ["${aws_s3_bucket.velero.arn}/*"]
  }
  statement { # list the bucket
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.velero.arn]
  }
}

resource "aws_iam_policy" "velero" {
  name   = "dev-platform-velero"
  policy = data.aws_iam_policy_document.velero.json
}
