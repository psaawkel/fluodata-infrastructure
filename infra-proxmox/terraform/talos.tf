# ============================================================
# Talos cluster bootstrap
# ============================================================
# Generates secrets, machine configs, applies them, and bootstraps
# the Kubernetes cluster with Cilium as CNI via inline manifests.

# --- Generate cluster secrets (CA keys, etc.) ---
resource "talos_machine_secrets" "this" {}

# --- Read Talos patch files ---
data "local_file" "patch_common" {
  filename = "${path.module}/../talos/patches/common.yaml"
}

data "local_file" "patch_controlplane" {
  filename = "${path.module}/../talos/patches/controlplane.yaml"
}

data "local_file" "patch_worker" {
  filename = "${path.module}/../talos/patches/worker.yaml"
}

# --- Generate Cilium inline manifest ---
# Cilium must be installed before any pods can schedule (CNI chicken-and-egg).
# We render the Cilium Helm chart to YAML and embed it in Talos machine config.
#
# IMPORTANT: var.cilium_version here MUST match targetRevision in
# cluster-gitops/infrastructure/cilium/application.yaml.
# After Argo CD takes over Cilium management, a version mismatch causes
# a perpetual fight between Talos inline manifests and Argo CD.
data "helm_template" "cilium" {
  name       = "cilium"
  namespace  = "kube-system"
  repository = "https://helm.cilium.io/"
  chart      = "cilium"
  version    = var.cilium_version

  set {
    name  = "ipam.mode"
    value = "kubernetes"
  }

  set {
    name  = "kubeProxyReplacement"
    value = "true"
  }

  set {
    name  = "securityContext.capabilities.ciliumAgent"
    value = "{CHOWN,KILL,NET_ADMIN,NET_RAW,IPC_LOCK,SYS_ADMIN,SYS_RESOURCE,DAC_OVERRIDE,FOWNER,SETGID,SETUID}"
  }

  set {
    name  = "securityContext.capabilities.cleanCiliumState"
    value = "{NET_ADMIN,SYS_ADMIN,SYS_RESOURCE}"
  }

  set {
    name  = "cgroup.autoMount.enabled"
    value = "false"
  }

  set {
    name  = "cgroup.hostRoot"
    value = "/sys/fs/cgroup"
  }

  # L2 announcements for LoadBalancer services (replaces MetalLB)
  set {
    name  = "l2announcements.enabled"
    value = "true"
  }

  set {
    name  = "externalIPs.enabled"
    value = "true"
  }

  # Hubble for observability
  set {
    name  = "hubble.relay.enabled"
    value = "true"
  }

  set {
    name  = "hubble.ui.enabled"
    value = "true"
  }
}

# --- Generate machine configuration for control plane ---
data "talos_machine_configuration" "controlplane" {
  for_each = { for n in var.controlplane_nodes : n.name => n }

  cluster_name     = var.cluster_name
  cluster_endpoint = var.cluster_endpoint
  machine_type     = "controlplane"
  machine_secrets  = talos_machine_secrets.this.machine_secrets

  config_patches = [
    data.local_file.patch_common.content,
    data.local_file.patch_controlplane.content,
    yamlencode({
      machine = {
        network = {
          hostname = each.value.name
          interfaces = [{
            interface = "eth0"
            addresses = ["${each.value.ip}/24"]
            routes = [{
              network = "0.0.0.0/0"
              gateway = var.vm_gateway
            }]
          }]
          nameservers = var.vm_nameservers
        }
      }
      cluster = {
        network = {
          cni = {
            name = "none" # Disable default Flannel, Cilium is inline
          }
        }
        proxy = {
          disabled = true # Cilium replaces kube-proxy
        }
        inlineManifests = [{
          name     = "cilium"
          contents = data.helm_template.cilium.manifest
        }]
      }
    })
  ]
}

# --- Generate machine configuration for workers ---
data "talos_machine_configuration" "worker" {
  for_each = { for n in var.worker_nodes : n.name => n }

  cluster_name     = var.cluster_name
  cluster_endpoint = var.cluster_endpoint
  machine_type     = "worker"
  machine_secrets  = talos_machine_secrets.this.machine_secrets

  config_patches = [
    data.local_file.patch_common.content,
    data.local_file.patch_worker.content,
    yamlencode({
      machine = {
        network = {
          hostname = each.value.name
          interfaces = [{
            interface = "eth0"
            addresses = ["${each.value.ip}/24"]
            routes = [{
              network = "0.0.0.0/0"
              gateway = var.vm_gateway
            }]
          }]
          nameservers = var.vm_nameservers
        }
        disks = each.value.longhorn_disk > 0 ? [{
          device = "/dev/sdb"
          partitions = [{
            mountpoint = "/var/lib/longhorn"
          }]
        }] : []
      }
      cluster = {
        network = {
          cni = {
            name = "none"
          }
        }
        proxy = {
          disabled = true
        }
      }
    })
  ]
}

# --- Apply machine configuration to control plane nodes ---
resource "talos_machine_configuration_apply" "controlplane" {
  for_each = { for n in var.controlplane_nodes : n.name => n }

  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.controlplane[each.key].machine_configuration
  node                        = each.value.ip

  depends_on = [proxmox_virtual_environment_vm.controlplane]
}

# --- Apply machine configuration to worker nodes ---
resource "talos_machine_configuration_apply" "worker" {
  for_each = { for n in var.worker_nodes : n.name => n }

  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.worker[each.key].machine_configuration
  node                        = each.value.ip

  depends_on = [proxmox_virtual_environment_vm.worker]
}

# --- Bootstrap the cluster (runs on first CP node only) ---
resource "talos_machine_bootstrap" "this" {
  client_configuration = talos_machine_secrets.this.client_configuration
  node                 = var.controlplane_nodes[0].ip

  depends_on = [talos_machine_configuration_apply.controlplane]
}

# --- Retrieve kubeconfig ---
data "talos_cluster_kubeconfig" "this" {
  client_configuration = talos_machine_secrets.this.client_configuration
  node                 = var.controlplane_nodes[0].ip

  depends_on = [talos_machine_bootstrap.this]
}

# --- Wait for cluster health ---
data "talos_cluster_health" "this" {
  client_configuration = talos_machine_secrets.this.client_configuration
  control_plane_nodes  = local.cp_ips
  worker_nodes         = local.worker_ips
  endpoints            = local.cp_ips

  timeouts = {
    read = "10m"
  }

  depends_on = [
    talos_machine_configuration_apply.controlplane,
    talos_machine_configuration_apply.worker,
    talos_machine_bootstrap.this,
  ]
}

# --- Write kubeconfig to file ---
resource "local_file" "kubeconfig" {
  content  = data.talos_cluster_kubeconfig.this.kubeconfig_raw
  filename = local.kubeconfig_path

  depends_on = [data.talos_cluster_health.this]
}

# --- Write talosconfig for manual talosctl usage ---
resource "local_file" "talosconfig" {
  content  = data.talos_client_configuration.this.talos_config
  filename = "${path.module}/talosconfig"
}

data "talos_client_configuration" "this" {
  cluster_name         = var.cluster_name
  client_configuration = talos_machine_secrets.this.client_configuration
  endpoints            = local.cp_ips
  nodes                = concat(local.cp_ips, local.worker_ips)
}
