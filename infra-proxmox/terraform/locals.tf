# ============================================================
# Locals
# ============================================================
locals {
  kubeconfig_path = "${path.module}/kubeconfig"

  all_nodes = concat(
    [for n in var.controlplane_nodes : merge(n, { role = "controlplane", longhorn_disk = 0 })],
    [for n in var.worker_nodes : merge(n, { role = "worker" })]
  )

  # Flatten for Talos config apply
  cp_ips     = [for n in var.controlplane_nodes : n.ip]
  worker_ips = [for n in var.worker_nodes : n.ip]
}
