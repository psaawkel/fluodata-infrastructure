locals {
  all_nodes = concat(
    [for n in var.controlplane_nodes : {
      name      = n.name
      vmid      = n.vmid
      ip        = n.ip
      mac       = n.mac
      cores     = n.cores
      memory    = n.memory
      disk_size = n.disk_size
      role      = "controlplane"
    }],
    [for n in var.worker_nodes : {
      name      = n.name
      vmid      = n.vmid
      ip        = n.ip
      mac       = n.mac
      cores     = n.cores
      memory    = n.memory
      disk_size = n.disk_size
      role      = "worker"
    }]
  )

  cp_ips     = [for n in var.controlplane_nodes : n.ip]
  worker_ips = [for n in var.worker_nodes : n.ip]
}
