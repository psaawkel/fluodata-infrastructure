# =============================================================================
# Talos Machine Secrets
# =============================================================================

resource "talos_machine_secrets" "this" {
  talos_version = var.talos_version
}

# =============================================================================
# Talos Client Configuration
# =============================================================================

data "talos_client_configuration" "this" {
  cluster_name         = var.cluster_name
  client_configuration = talos_machine_secrets.this.client_configuration
  endpoints            = local.cp_ips
  nodes                = concat(local.cp_ips, local.worker_ips)
}

# =============================================================================
# Cilium Inline Manifest (required before any pods can schedule)
# =============================================================================

data "helm_template" "cilium" {
  name         = "cilium"
  namespace    = "kube-system"
  repository   = "https://helm.cilium.io/"
  chart        = "cilium"
  version      = var.cilium_version
  kube_version = "1.32.0"

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

  set {
    name  = "k8sServiceHost"
    value = "localhost"
  }

  set {
    name  = "k8sServicePort"
    value = "7445"
  }
}

# =============================================================================
# Per-Node Machine Configurations (Control Plane)
# Each node gets its own fully-patched config including hostname, static IP, etc.
# =============================================================================

data "talos_machine_configuration" "controlplane" {
  for_each = { for n in var.controlplane_nodes : n.name => n }

  cluster_name     = var.cluster_name
  cluster_endpoint = var.cluster_endpoint
  machine_type     = "controlplane"
  machine_secrets  = talos_machine_secrets.this.machine_secrets
  talos_version    = var.talos_version

  config_patches = [
    # Disable default CNI (we use Cilium)
    yamlencode({
      cluster = {
        network = {
          cni = {
            name = "none"
          }
        }
        proxy = {
          disabled = true
        }
        # Cilium inline manifest
        inlineManifests = [
          {
            name     = "cilium"
            contents = data.helm_template.cilium.manifest
          }
        ]
      }
    }),
    # Allow scheduling on control plane (Phase 1: limited resources)
    yamlencode({
      cluster = {
        allowSchedulingOnControlPlanes = true
      }
    }),
    # NTP servers
    yamlencode({
      machine = {
        time = {
          servers = [
            "time.cloudflare.com",
            "pool.ntp.org"
          ]
        }
      }
    }),
    # Kernel modules for Longhorn
    yamlencode({
      machine = {
        kernel = {
          modules = [
            { name = "iscsi_tcp" },
            { name = "dm_thin_pool" }
          ]
        }
      }
    }),
    # Kubelet configuration
    yamlencode({
      machine = {
        kubelet = {
          extraArgs = {
            "rotate-server-certificates" = "true"
          }
        }
      }
    }),
    # Network sysctls
    yamlencode({
      machine = {
        sysctls = {
          "net.core.somaxconn"          = "65535"
          "net.core.netdev_max_backlog" = "4096"
        }
      }
    }),
    # etcd advertised subnets
    yamlencode({
      cluster = {
        etcd = {
          advertisedSubnets = [
            "${var.vm_gateway}/24"
          ]
        }
      }
    }),
    # Per-node: hostname
    yamlencode({
      machine = {
        network = {
          hostname = each.value.name
        }
      }
    }),
    # Per-node: static IP
    yamlencode({
      machine = {
        network = {
          interfaces = [
            {
              interface = "eth0"
              addresses = ["${each.value.ip}/${var.vm_subnet_mask}"]
              routes = [
                {
                  network = "0.0.0.0/0"
                  gateway = var.vm_gateway
                }
              ]
            }
          ]
          nameservers = var.vm_nameservers
        }
      }
    }),
    # Per-node: install disk
    yamlencode({
      machine = {
        install = {
          disk = "/dev/sda"
        }
      }
    }),
  ]
}

# =============================================================================
# Per-Node Machine Configurations (Workers)
# =============================================================================

data "talos_machine_configuration" "worker" {
  for_each = { for n in var.worker_nodes : n.name => n }

  cluster_name     = var.cluster_name
  cluster_endpoint = var.cluster_endpoint
  machine_type     = "worker"
  machine_secrets  = talos_machine_secrets.this.machine_secrets
  talos_version    = var.talos_version

  config_patches = [
    # Disable default CNI and proxy
    yamlencode({
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
    }),
    # NTP servers
    yamlencode({
      machine = {
        time = {
          servers = [
            "time.cloudflare.com",
            "pool.ntp.org"
          ]
        }
      }
    }),
    # Kernel modules for Longhorn
    yamlencode({
      machine = {
        kernel = {
          modules = [
            { name = "iscsi_tcp" },
            { name = "dm_thin_pool" }
          ]
        }
      }
    }),
    # Kubelet configuration
    yamlencode({
      machine = {
        kubelet = {
          extraArgs = {
            "rotate-server-certificates" = "true"
          }
        }
      }
    }),
    # Worker node label
    yamlencode({
      machine = {
        nodeLabels = {
          "node-role.kubernetes.io/worker" = ""
        }
      }
    }),
    # Network sysctls
    yamlencode({
      machine = {
        sysctls = {
          "net.core.somaxconn"          = "65535"
          "net.core.netdev_max_backlog" = "4096"
        }
      }
    }),
    # Per-node: hostname
    yamlencode({
      machine = {
        network = {
          hostname = each.value.name
        }
      }
    }),
    # Per-node: static IP
    yamlencode({
      machine = {
        network = {
          interfaces = [
            {
              interface = "eth0"
              addresses = ["${each.value.ip}/${var.vm_subnet_mask}"]
              routes = [
                {
                  network = "0.0.0.0/0"
                  gateway = var.vm_gateway
                }
              ]
            }
          ]
          nameservers = var.vm_nameservers
        }
      }
    }),
    # Per-node: install disk
    yamlencode({
      machine = {
        install = {
          disk = "/dev/sda"
        }
      }
    }),
    # Per-node: Longhorn disk mount (if present)
    each.value.longhorn_disk > 0 ? yamlencode({
      machine = {
        disks = [
          {
            device = "/dev/sdb"
            partitions = [
              {
                mountpoint = "/var/lib/longhorn"
              }
            ]
          }
        ]
        kubelet = {
          extraMounts = [
            {
              destination = "/var/lib/longhorn"
              type        = "bind"
              source      = "/var/lib/longhorn"
              options     = ["bind", "rshared", "rw"]
            }
          ]
        }
      }
    }) : yamlencode({}),
  ]
}

# =============================================================================
# Wait for VMs to boot into Talos maintenance mode
# Runs from Proxmox host via SSH (VMs are on vmbr1, only reachable from there)
# =============================================================================

resource "terraform_data" "wait_for_vms" {
  depends_on = [
    proxmox_virtual_environment_vm.controlplane,
    proxmox_virtual_environment_vm.worker,
  ]

  # Re-trigger if VMs change
  input = {
    cp_ids     = [for k, v in proxmox_virtual_environment_vm.controlplane : v.id]
    worker_ids = [for k, v in proxmox_virtual_environment_vm.worker : v.id]
  }

  provisioner "local-exec" {
    command = <<-EOT
      echo "Waiting for Talos VMs to reach maintenance mode..."
      ssh -o StrictHostKeyChecking=no root@${var.proxmox_ssh_host} 'bash -s' <<'SSHEOF'
        for ip in ${join(" ", concat(local.cp_ips, local.worker_ips))}; do
          echo "Waiting for $ip on port 50000 (Talos API)..."
          for i in $(seq 1 90); do
            if timeout 3 bash -c "echo > /dev/tcp/$ip/50000" 2>/dev/null; then
              echo "$ip is ready (Talos API responding)"
              break
            fi
            if [ "$i" -eq 90 ]; then
              echo "ERROR: Timeout waiting for $ip after 450s"
              exit 1
            fi
            sleep 5
          done
        done
        echo "All VMs are in Talos maintenance mode"
      SSHEOF
    EOT
  }
}

# =============================================================================
# Apply Machine Configuration via SSH to Proxmox
# Writes configs locally, SCPs to Proxmox, runs talosctl apply-config there
# =============================================================================

resource "terraform_data" "apply_config_controlplane" {
  for_each = { for n in var.controlplane_nodes : n.name => n }

  depends_on = [terraform_data.wait_for_vms]

  # Re-trigger if machine config changes
  input = data.talos_machine_configuration.controlplane[each.key].machine_configuration

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail

      # Write machine config to temp file
      TMPFILE=$(mktemp /tmp/talos-${each.value.name}-XXXXXX.yaml)
      cat > "$TMPFILE" <<'CONFIGEOF'
      ${data.talos_machine_configuration.controlplane[each.key].machine_configuration}
      CONFIGEOF

      # SCP config to Proxmox
      scp -o StrictHostKeyChecking=no "$TMPFILE" root@${var.proxmox_ssh_host}:/tmp/talos-${each.value.name}.yaml

      # Apply config from Proxmox (which can reach the VM on vmbr1)
      ssh -o StrictHostKeyChecking=no root@${var.proxmox_ssh_host} \
        "talosctl apply-config --insecure --nodes ${each.value.ip} --endpoints ${each.value.ip} --file /tmp/talos-${each.value.name}.yaml && rm -f /tmp/talos-${each.value.name}.yaml"

      rm -f "$TMPFILE"
      echo "${each.value.name} (${each.value.ip}): config applied successfully"
    EOT
  }
}

resource "terraform_data" "apply_config_worker" {
  for_each = { for n in var.worker_nodes : n.name => n }

  depends_on = [terraform_data.wait_for_vms]

  # Re-trigger if machine config changes
  input = data.talos_machine_configuration.worker[each.key].machine_configuration

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail

      # Write machine config to temp file
      TMPFILE=$(mktemp /tmp/talos-${each.value.name}-XXXXXX.yaml)
      cat > "$TMPFILE" <<'CONFIGEOF'
      ${data.talos_machine_configuration.worker[each.key].machine_configuration}
      CONFIGEOF

      # SCP config to Proxmox
      scp -o StrictHostKeyChecking=no "$TMPFILE" root@${var.proxmox_ssh_host}:/tmp/talos-${each.value.name}.yaml

      # Apply config from Proxmox (which can reach the VM on vmbr1)
      ssh -o StrictHostKeyChecking=no root@${var.proxmox_ssh_host} \
        "talosctl apply-config --insecure --nodes ${each.value.ip} --endpoints ${each.value.ip} --file /tmp/talos-${each.value.name}.yaml && rm -f /tmp/talos-${each.value.name}.yaml"

      rm -f "$TMPFILE"
      echo "${each.value.name} (${each.value.ip}): config applied successfully"
    EOT
  }
}

# =============================================================================
# Wait for nodes to reboot and come up with applied config
# After config apply, Talos installs to disk and reboots
# =============================================================================

resource "terraform_data" "wait_for_nodes_ready" {
  depends_on = [
    terraform_data.apply_config_controlplane,
    terraform_data.apply_config_worker,
  ]

  input = {
    cp_configs     = [for k, v in terraform_data.apply_config_controlplane : v.id]
    worker_configs = [for k, v in terraform_data.apply_config_worker : v.id]
  }

  provisioner "local-exec" {
    command = <<-EOT
      echo "Waiting for nodes to reboot and start Talos API on port 50000..."
      ssh -o StrictHostKeyChecking=no root@${var.proxmox_ssh_host} 'bash -s' <<'SSHEOF'
        # After apply-config, VMs install to disk and reboot. Wait for them to come back.
        sleep 15
        for ip in ${join(" ", concat(local.cp_ips, local.worker_ips))}; do
          echo "Waiting for $ip to come back after reboot..."
          for i in $(seq 1 120); do
            if timeout 3 bash -c "echo > /dev/tcp/$ip/50000" 2>/dev/null; then
              echo "$ip is back (Talos API responding)"
              break
            fi
            if [ "$i" -eq 120 ]; then
              echo "ERROR: Timeout waiting for $ip after reboot (600s)"
              exit 1
            fi
            sleep 5
          done
        done
        echo "All nodes are back after config apply"
      SSHEOF
    EOT
  }
}

# =============================================================================
# Bootstrap the Cluster (only on first control plane)
# Copies talosconfig to Proxmox, runs talosctl bootstrap from there
# =============================================================================

resource "terraform_data" "bootstrap" {
  depends_on = [terraform_data.wait_for_nodes_ready]

  # Only run once — keyed on machine secrets
  input = talos_machine_secrets.this.machine_secrets.cluster.id

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail

      # Write talosconfig to temp file
      TMPFILE=$(mktemp /tmp/talosconfig-XXXXXX)
      cat > "$TMPFILE" <<'CONFIGEOF'
      ${data.talos_client_configuration.this.talos_config}
      CONFIGEOF

      # SCP talosconfig to Proxmox
      scp -o StrictHostKeyChecking=no "$TMPFILE" root@${var.proxmox_ssh_host}:/tmp/talosconfig

      # Bootstrap from Proxmox
      ssh -o StrictHostKeyChecking=no root@${var.proxmox_ssh_host} \
        "talosctl bootstrap --talosconfig /tmp/talosconfig --nodes ${var.controlplane_nodes[0].ip} --endpoints ${var.controlplane_nodes[0].ip}"

      rm -f "$TMPFILE"
      echo "Cluster bootstrap initiated on ${var.controlplane_nodes[0].ip}"
    EOT
  }
}

# =============================================================================
# Retrieve kubeconfig via SSH to Proxmox
# =============================================================================

resource "terraform_data" "retrieve_kubeconfig" {
  depends_on = [terraform_data.bootstrap]

  input = terraform_data.bootstrap.id

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail

      echo "Waiting for Kubernetes API to be ready..."
      ssh -o StrictHostKeyChecking=no root@${var.proxmox_ssh_host} 'bash -s' <<'SSHEOF'
        # Wait for the API server to be reachable
        for i in $(seq 1 60); do
          if timeout 3 bash -c "echo > /dev/tcp/${var.controlplane_nodes[0].ip}/6443" 2>/dev/null; then
            echo "Kubernetes API is reachable"
            break
          fi
          if [ "$i" -eq 60 ]; then
            echo "ERROR: Timeout waiting for Kubernetes API"
            exit 1
          fi
          sleep 5
        done

        # Generate kubeconfig
        talosctl kubeconfig /tmp/kubeconfig \
          --talosconfig /tmp/talosconfig \
          --nodes ${var.controlplane_nodes[0].ip} \
          --endpoints ${var.controlplane_nodes[0].ip} \
          --force
      SSHEOF

      # SCP kubeconfig back to local machine
      scp -o StrictHostKeyChecking=no root@${var.proxmox_ssh_host}:/tmp/kubeconfig ${path.module}/kubeconfig
      chmod 600 ${path.module}/kubeconfig

      echo "Kubeconfig saved to ${path.module}/kubeconfig"
    EOT
  }
}

# =============================================================================
# Wait for cluster health — run kubectl from Proxmox
# =============================================================================

resource "terraform_data" "cluster_health" {
  depends_on = [terraform_data.retrieve_kubeconfig]

  input = terraform_data.retrieve_kubeconfig.id

  provisioner "local-exec" {
    command = <<-EOT
      echo "Waiting for cluster to become healthy..."
      ssh -o StrictHostKeyChecking=no root@${var.proxmox_ssh_host} 'bash -s' <<'SSHEOF'
        export KUBECONFIG=/tmp/kubeconfig

        for i in $(seq 1 60); do
          READY_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | grep -c " Ready " || true)
          TOTAL_EXPECTED=${length(concat(local.cp_ips, local.worker_ips))}
          echo "Nodes ready: $READY_COUNT/$TOTAL_EXPECTED (attempt $i/60)"
          if [ "$READY_COUNT" -ge "$TOTAL_EXPECTED" ]; then
            echo "All nodes are Ready!"
            kubectl get nodes
            exit 0
          fi
          sleep 10
        done

        echo "WARNING: Not all nodes are Ready yet, but cluster is bootstrapped."
        kubectl get nodes 2>/dev/null || true
        exit 0
      SSHEOF
    EOT
  }
}

# =============================================================================
# Write talosconfig to local file
# =============================================================================

resource "local_file" "talosconfig" {
  content         = data.talos_client_configuration.this.talos_config
  filename        = "${path.module}/talosconfig"
  file_permission = "0600"
}
