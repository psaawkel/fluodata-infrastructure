# ============================================================
# Outputs
# ============================================================

output "kubeconfig_path" {
  description = "Path to the generated kubeconfig file"
  value       = local.kubeconfig_path
}

output "talosconfig_path" {
  description = "Path to the generated talosconfig file"
  value       = "${path.module}/talosconfig"
}

output "controlplane_ips" {
  description = "Control plane node IPs"
  value       = local.cp_ips
}

output "worker_ips" {
  description = "Worker node IPs"
  value       = local.worker_ips
}

output "argocd_initial_password" {
  description = "Retrieve Argo CD initial admin password"
  value       = "kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
}
