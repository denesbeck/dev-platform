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
