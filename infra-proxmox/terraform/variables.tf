# --- Proxmox connection ---

variable "proxmox_api_url" {
  description = "Proxmox API URL (e.g. https://192.168.1.100:8006)"
  type        = string
}

variable "proxmox_api_token_id" {
  description = "Proxmox API token ID (e.g. root@pam!terraform)"
  type        = string
}

variable "proxmox_api_token_secret" {
  description = "Proxmox API token secret"
  type        = string
  sensitive   = true
}

variable "proxmox_tls_insecure" {
  description = "Skip TLS verification for Proxmox API"
  type        = bool
  default     = true
}

variable "proxmox_node" {
  description = "Proxmox node name"
  type        = string
  default     = "pve"
}

variable "proxmox_ssh_host" {
  description = "Proxmox host IP/hostname for SSH access (used to run talosctl from Proxmox)"
  type        = string
}

# --- Talos ---

variable "talos_version" {
  description = "Talos Linux version"
  type        = string
  default     = "v1.9.2"
}

variable "talos_iso_url" {
  description = "Talos factory ISO URL (with extensions baked in). Generate at https://factory.talos.dev/"
  type        = string
}

variable "talos_iso_storage" {
  description = "Proxmox storage for Talos ISO"
  type        = string
  default     = "local"
}

# --- Cluster ---

variable "cluster_name" {
  description = "Kubernetes cluster name"
  type        = string
  default     = "fluodata"
}

variable "cluster_endpoint" {
  description = "Kubernetes API endpoint (https://<cp-ip>:6443)"
  type        = string
}

# --- Networking ---

variable "vm_bridge" {
  description = "Proxmox bridge for VM network"
  type        = string
  default     = "vmbr1"
}

variable "vm_gateway" {
  description = "Gateway for VM network"
  type        = string
  default     = "10.10.0.1"
}

variable "vm_nameservers" {
  description = "DNS nameservers for VMs"
  type        = list(string)
  default     = ["10.10.0.1", "1.1.1.1"]
}

variable "vm_subnet_mask" {
  description = "Subnet mask in CIDR bits"
  type        = number
  default     = 24
}

# --- VM storage ---

variable "vm_disk_storage" {
  description = "Proxmox storage for VM disks"
  type        = string
  default     = "local-lvm"
}

# --- Control plane nodes ---

variable "controlplane_nodes" {
  description = "Control plane node definitions"
  type = list(object({
    name      = string
    vmid      = number
    ip        = string
    mac       = string
    cores     = optional(number, 2)
    memory    = optional(number, 6144)
    disk_size = optional(number, 20)
  }))
}

# --- Worker nodes ---

variable "worker_nodes" {
  description = "Worker node definitions"
  type = list(object({
    name          = string
    vmid          = number
    ip            = string
    mac           = string
    cores         = optional(number, 4)
    memory        = optional(number, 8192)
    disk_size     = optional(number, 20)
    longhorn_disk = optional(number, 0)
  }))
}

# --- Cilium ---

variable "cilium_version" {
  description = "Cilium Helm chart version"
  type        = string
  default     = "1.17.0"
}
