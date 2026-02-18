# ============================================================
# Proxmox VM provisioning
# ============================================================
# Downloads the Talos ISO and creates VMs for control plane + workers.

# --- Download Talos ISO to Proxmox ---
resource "proxmox_virtual_environment_download_file" "talos_iso" {
  content_type = "iso"
  datastore_id = var.talos_iso_storage
  node_name    = var.proxmox_node
  url          = var.talos_iso_url
  file_name    = "talos-${var.talos_version}-nocloud-amd64.iso"
  overwrite    = false
}

# --- Control plane VMs ---
resource "proxmox_virtual_environment_vm" "controlplane" {
  for_each = { for idx, n in var.controlplane_nodes : n.name => n }

  name      = each.value.name
  node_name = var.proxmox_node
  vm_id     = each.value.vmid

  machine       = "q35"
  scsi_hardware = "virtio-scsi-single"
  bios          = "seabios"
  started       = true

  cpu {
    cores = each.value.cores
    type  = "x86-64-v2-AES"
  }

  memory {
    dedicated = each.value.memory
  }

  cdrom {
    file_id = proxmox_virtual_environment_download_file.talos_iso.id
  }

  disk {
    datastore_id = var.vm_storage
    interface    = "scsi0"
    size         = each.value.disk_size
    file_format  = "raw"
    iothread     = true
    discard      = "on"
  }

  network_device {
    bridge      = var.vm_bridge
    mac_address = each.value.mac
    model       = "virtio"
  }

  operating_system {
    type = "l26"
  }

  agent {
    enabled = false
  }

  lifecycle {
    ignore_changes = [cdrom]
  }
}

# --- Worker VMs ---
resource "proxmox_virtual_environment_vm" "worker" {
  for_each = { for idx, n in var.worker_nodes : n.name => n }

  name      = each.value.name
  node_name = var.proxmox_node
  vm_id     = each.value.vmid

  machine       = "q35"
  scsi_hardware = "virtio-scsi-single"
  bios          = "seabios"
  started       = true

  cpu {
    cores = each.value.cores
    type  = "x86-64-v2-AES"
  }

  memory {
    dedicated = each.value.memory
  }

  cdrom {
    file_id = proxmox_virtual_environment_download_file.talos_iso.id
  }

  # Boot disk
  disk {
    datastore_id = var.vm_storage
    interface    = "scsi0"
    size         = each.value.disk_size
    file_format  = "raw"
    iothread     = true
    discard      = "on"
  }

  # Longhorn data disk (if specified)
  dynamic "disk" {
    for_each = each.value.longhorn_disk > 0 ? [1] : []
    content {
      datastore_id = var.vm_storage
      interface    = "scsi1"
      size         = each.value.longhorn_disk
      file_format  = "raw"
      iothread     = true
      discard      = "on"
    }
  }

  network_device {
    bridge      = var.vm_bridge
    mac_address = each.value.mac
    model       = "virtio"
  }

  operating_system {
    type = "l26"
  }

  agent {
    enabled = false
  }

  lifecycle {
    ignore_changes = [cdrom]
  }
}
