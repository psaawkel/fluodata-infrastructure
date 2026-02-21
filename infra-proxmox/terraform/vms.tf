# =============================================================================
# Download Talos ISO to Proxmox storage
# =============================================================================

resource "proxmox_virtual_environment_download_file" "talos_iso" {
  content_type = "iso"
  datastore_id = var.talos_iso_storage
  node_name    = var.proxmox_node
  file_name    = "talos-${var.talos_version}.iso"
  url          = var.talos_iso_url
  overwrite    = false
}

# =============================================================================
# Control Plane VMs
# =============================================================================

resource "proxmox_virtual_environment_vm" "controlplane" {
  for_each = { for idx, n in var.controlplane_nodes : n.name => n }

  name      = each.value.name
  node_name = var.proxmox_node
  vm_id     = each.value.vmid
  tags      = ["talos", "controlplane", "terraform"]

  machine       = "q35"
  scsi_hardware = "virtio-scsi-single"
  bios          = "seabios"

  on_boot         = true
  stop_on_destroy = true

  # Talos has no QEMU agent
  agent {
    enabled = false
  }

  cpu {
    cores = each.value.cores
    type  = "x86-64-v2-AES"
  }

  memory {
    dedicated = each.value.memory
  }

  # Boot disk
  disk {
    datastore_id = var.vm_disk_storage
    interface    = "scsi0"
    size         = each.value.disk_size
    discard      = "on"
    iothread     = true
    file_format  = "raw"
  }

  # Talos ISO as CD-ROM
  cdrom {
    file_id   = proxmox_virtual_environment_download_file.talos_iso.id
    interface = "ide2"
  }

  # Network on internal bridge with deterministic MAC
  network_device {
    bridge      = var.vm_bridge
    mac_address = each.value.mac
    model       = "virtio"
  }

  operating_system {
    type = "l26"
  }

  # Boot from ISO first (for initial Talos install), then disk
  boot_order = ["ide2", "scsi0"]

  # Serial console for Talos
  serial_device {}

  lifecycle {
    ignore_changes = [
      boot_order,
      cdrom,
    ]
  }
}

# =============================================================================
# Worker VMs
# =============================================================================

resource "proxmox_virtual_environment_vm" "worker" {
  for_each = { for idx, n in var.worker_nodes : n.name => n }

  name      = each.value.name
  node_name = var.proxmox_node
  vm_id     = each.value.vmid
  tags      = ["talos", "worker", "terraform"]

  machine       = "q35"
  scsi_hardware = "virtio-scsi-single"
  bios          = "seabios"

  on_boot         = true
  stop_on_destroy = true

  agent {
    enabled = false
  }

  cpu {
    cores = each.value.cores
    type  = "x86-64-v2-AES"
  }

  memory {
    dedicated = each.value.memory
  }

  # Boot disk
  disk {
    datastore_id = var.vm_disk_storage
    interface    = "scsi0"
    size         = each.value.disk_size
    discard      = "on"
    iothread     = true
    file_format  = "raw"
  }

  # Longhorn data disk (only if size > 0)
  dynamic "disk" {
    for_each = each.value.longhorn_disk > 0 ? [1] : []
    content {
      datastore_id = var.vm_disk_storage
      interface    = "scsi1"
      size         = each.value.longhorn_disk
      discard      = "on"
      iothread     = true
      file_format  = "raw"
    }
  }

  # Talos ISO as CD-ROM
  cdrom {
    file_id   = proxmox_virtual_environment_download_file.talos_iso.id
    interface = "ide2"
  }

  network_device {
    bridge      = var.vm_bridge
    mac_address = each.value.mac
    model       = "virtio"
  }

  operating_system {
    type = "l26"
  }

  # Boot from ISO first (for initial Talos install), then disk
  boot_order = ["ide2", "scsi0"]

  serial_device {}

  lifecycle {
    ignore_changes = [
      boot_order,
      cdrom,
    ]
  }
}
