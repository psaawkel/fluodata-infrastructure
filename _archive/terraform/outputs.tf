output "kubeconfig_path" {
  description = "Path to the generated kubeconfig file"
  value       = "${path.module}/kubeconfig"
}

output "talosconfig_path" {
  description = "Path to the generated talosconfig file"
  value       = local_file.talosconfig.filename
}

output "controlplane_ips" {
  description = "Control plane node IPs"
  value       = local.cp_ips
}

output "worker_ips" {
  description = "Worker node IPs"
  value       = local.worker_ips
}

output "cluster_endpoint" {
  description = "Kubernetes API endpoint"
  value       = var.cluster_endpoint
}
