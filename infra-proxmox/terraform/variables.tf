# ============================================================
# Terraform variables for Proxmox + Talos VM provisioning
# ============================================================

# --- Proxmox connection ---
variable "proxmox_api_url" {
  description = "Proxmox API URL (e.g., https://192.168.1.100:8006/api2/json)"
  type        = string
}

variable "proxmox_api_token_id" {
  description = "Proxmox API token ID (e.g., root@pam!terraform)"
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

# --- Talos ---
variable "talos_version" {
  description = "Talos Linux version"
  type        = string
  default     = "1.9.2"
}

variable "talos_iso_url" {
  description = "Talos ISO URL (factory image with extensions). Generate at https://factory.talos.dev/"
  type        = string
  # Default includes iscsi-tools + util-linux-tools for Longhorn
  default = "https://factory.talos.dev/image/08e3e7e1efef4a7e26573e80b17a0e0eea65085e43610e7048773b0b54e1db28/v1.9.2/nocloud-amd64.iso"
}

variable "talos_iso_storage" {
  description = "Proxmox storage pool for the ISO"
  type        = string
  default     = "local"
}

variable "cluster_name" {
  description = "Kubernetes cluster name"
  type        = string
  default     = "fluodata"
}

variable "cluster_endpoint" {
  description = "Kubernetes API endpoint (control plane IP)"
  type        = string
  default     = "https://10.10.0.10:6443"
}

# --- Networking ---
variable "vm_bridge" {
  description = "Proxmox bridge for VM network"
  type        = string
  default     = "vmbr1"
}

variable "vm_gateway" {
  description = "Default gateway for VM network"
  type        = string
  default     = "10.10.0.1"
}

variable "vm_nameservers" {
  description = "DNS servers for VMs"
  type        = list(string)
  default     = ["10.10.0.1", "1.1.1.1"]
}

# --- VM definitions ---
variable "controlplane_nodes" {
  description = "Control plane node definitions"
  type = list(object({
    name      = string
    vmid      = number
    ip        = string
    mac       = string
    cores     = number
    memory    = number # MB
    disk_size = number # GB
  }))
  default = [
    {
      name      = "talos-cp-1"
      vmid      = 100
      ip        = "10.10.0.10"
      mac       = "BC:24:11:00:01:10"
      cores     = 2
      memory    = 8192
      disk_size = 20
    }
  ]
}

variable "worker_nodes" {
  description = "Worker node definitions"
  type = list(object({
    name          = string
    vmid          = number
    ip            = string
    mac           = string
    cores         = number
    memory        = number # MB
    disk_size     = number # GB
    longhorn_disk = number # GB, 0 = no Longhorn disk
  }))
  default = [
    {
      name          = "talos-worker-1"
      vmid          = 110
      ip            = "10.10.0.20"
      mac           = "BC:24:11:00:01:20"
      cores         = 4
      memory        = 12288
      disk_size     = 20
      longhorn_disk = 80
    },
    {
      name          = "talos-worker-2"
      vmid          = 111
      ip            = "10.10.0.21"
      mac           = "BC:24:11:00:01:21"
      cores         = 4
      memory        = 12288
      disk_size     = 20
      longhorn_disk = 80
    }
  ]
}

variable "vm_storage" {
  description = "Proxmox storage pool for VM disks"
  type        = string
  default     = "local-lvm"
}

# --- Cilium ---
variable "cilium_version" {
  description = "Cilium version for inline manifests"
  type        = string
  default     = "1.17.0"
}

# --- Argo CD ---
variable "argocd_version" {
  description = "Argo CD Helm chart version"
  type        = string
  default     = "7.8.0"
}

variable "gitops_repo_url" {
  description = "Git repository URL for Argo CD to watch (this repo)"
  type        = string
}

variable "gitops_repo_path" {
  description = "Path within the repo for the root app"
  type        = string
  default     = "cluster-gitops/bootstrap"
}

variable "gitops_target_revision" {
  description = "Git branch/tag for Argo CD to track"
  type        = string
  default     = "master"
}

# --- SOPS + age ---
variable "sops_age_key_file" {
  description = "Path to the age private key file for SOPS decryption. Generate with: age-keygen -o age.key"
  type        = string
  default     = ""
}
