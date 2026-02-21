# Proxmox connection
proxmox_api_url          = "https://192.168.122.70:8006"
proxmox_api_token_id     = "root@pam!terraform"
proxmox_api_token_secret = "b5cdc654-9794-4cf2-9011-1590f1c15de3"
proxmox_tls_insecure     = true
proxmox_node             = "pve"
proxmox_ssh_host         = "192.168.122.70"

# Talos
talos_version     = "v1.9.2"
talos_iso_url     = "https://factory.talos.dev/image/613e1592b2da41ae5e265e8789429f22e121aab91cb4deb6bc3c0b6262961245/v1.9.2/nocloud-amd64.iso"
talos_iso_storage = "local"

# Cluster
cluster_name     = "fluodata"
cluster_endpoint = "https://10.10.0.10:6443"

# Networking
vm_bridge       = "vmbr1"
vm_gateway      = "10.10.0.1"
vm_nameservers  = ["10.10.0.1", "1.1.1.1"]
vm_subnet_mask  = 24
vm_disk_storage = "local-lvm"

# Cilium
cilium_version = "1.17.0"

# Phase 1: 1 CP + 2 Workers
controlplane_nodes = [
  {
    name      = "cp-0"
    vmid      = 110
    ip        = "10.10.0.10"
    mac       = "BC:24:11:01:01:01"
    cores     = 2
    memory    = 6144
    disk_size = 20
  },
]

worker_nodes = [
  {
    name          = "worker-0"
    vmid          = 120
    ip            = "10.10.0.20"
    mac           = "BC:24:11:02:01:01"
    cores         = 4
    memory        = 8192
    disk_size     = 20
    longhorn_disk = 80
  },
  {
    name          = "worker-1"
    vmid          = 121
    ip            = "10.10.0.21"
    mac           = "BC:24:11:02:01:02"
    cores         = 4
    memory        = 8192
    disk_size     = 20
    longhorn_disk = 80
  },
]
