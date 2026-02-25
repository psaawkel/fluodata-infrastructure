terraform {
  required_version = ">= 1.5"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = ">= 0.70.0"
    }
    talos = {
      source  = "siderolabs/talos"
      version = ">= 0.7.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.14"
    }
  }
}

provider "proxmox" {
  endpoint  = var.proxmox_api_url
  api_token = "${var.proxmox_api_token_id}=${var.proxmox_api_token_secret}"
  insecure  = var.proxmox_tls_insecure

  ssh {
    agent = false
  }
}

# Helm provider used only for data.helm_template (Cilium manifest rendering).
# No real cluster connection needed - helm_template is a local operation.
provider "helm" {}
