output "master_public_ip" {
  description = "Elastic IP attached to the control-plane node (stable across stop/start)"
  value       = aws_eip.master.public_ip
}

output "master_private_ip" {
  description = "Private IP of the control-plane node"
  value       = aws_instance.master.private_ip
}

output "worker_public_ips" {
  description = "Public IPs of the worker nodes"
  value       = aws_instance.worker[*].public_ip
}

output "worker_private_ips" {
  description = "Private IPs of the worker nodes"
  value       = aws_instance.worker[*].private_ip
}

output "talosconfig_path" {
  description = "Path to the generated talosconfig file (write-only, 0600)"
  value       = local_sensitive_file.talosconfig.filename
}

output "kubeconfig_path" {
  description = "Path to the generated kubeconfig file (write-only, 0600)"
  value       = local_sensitive_file.kubeconfig.filename
}

output "oidc_provider_arn" {
  description = "ARN of the IAM OIDC provider fronting the cluster's service-account tokens"
  value       = aws_iam_openid_connect_provider.irsa_oidc_provider.arn
}

output "ebs_csi_role_arn" {
  description = "IRSA role ARN for the EBS CSI driver (annotate its ServiceAccount with eks.amazonaws.com/role-arn)"
  value       = aws_iam_role.ebs_csi.arn
}

output "aws_lbc_role_arn" {
  description = "IRSA role ARN for the AWS Load Balancer Controller"
  value       = aws_iam_role.aws_lbc.arn
}

output "velero_role_arn" {
  description = "IRSA role ARN for Velero"
  value       = aws_iam_role.velero.arn
}

output "velero_bucket_name" {
  description = "S3 bucket holding Velero backups"
  value       = aws_s3_bucket.velero.bucket
}

output "vpc_id" {
  description = "VPC id (needed by the AWS Load Balancer Controller Helm values)"
  value       = aws_vpc.main_vpc.id
}
