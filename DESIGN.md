# FluoData Infrastructure - Talos on Proxmox IaC Design

**Version:** 2.0 (Ansible-based)  
**Status:** Implemented and working  
**Date:** 2026-02-22

---

## 1. Core Goal

**One command to deploy a bare Talos cluster on Proxmox:**
```bash
ansible-playbook site.yml
```

**One command to tear it down:**
```bash
ansible-playbook destroy.yml
```

---

## 2. Design Decisions

| Decision | Rationale |
|----------|-----------|
| **Ansible over Terraform** | Terraform's `stop_on_destroy` with Talos VMs is dangerously slow (5+ min ACPI timeout). Ansible handles VM lifecycle, imperative bootstrap steps (talosctl, helm), and teardown cleanly. |
| **No shell scripts** | All automation lives in Ansible roles. No `init-cluster.sh` or `add-worker.sh`. |
| **Cilium via Helm** (not inline manifest) | Post-bootstrap `helm install` is simpler and more maintainable than embedding 1600+ lines of YAML in Talos config. Nodes are `NotReady` until Cilium deploys — this is expected. |
| **No `machine.network.hostname`** | dnsmasq assigns hostnames via DHCP (MAC-based). Talos v1.12.4 rejects configs with hostname if DHCP already set one. |
| **Proxmox API modules on localhost** | `community.proxmox.proxmox_kvm` uses REST API + `proxmoxer` library. Runs on controller with `delegate_to: localhost`. |
| **talosctl/helm on Proxmox host** | VMs are on internal vmbr1 (10.10.0.0/24), not reachable from laptop. All cluster commands run on Proxmox via SSH. |

---

## 3. Architecture

```
┌─────────────────────────────────────────────┐
│     ansible-playbook site.yml               │
│     (infra-proxmox/ansible/)                │
└─────────────────────────────────────────────┘
        │
        ├── Role: proxmox_vms
        │   ├── Download Talos ISO (get_url on Proxmox host)
        │   ├── Create VMs (proxmox_kvm → REST API from localhost)
        │   └── Start VMs
        │
        ├── Role: talos_cluster
        │   ├── Generate secrets (talosctl on Proxmox host)
        │   ├── Generate config patches (Jinja2 templates)
        │   ├── Generate configs from secrets + patches
        │   ├── Apply configs to each node
        │   ├── Bootstrap control plane
        │   └── Fetch kubeconfig
        │
        └── Role: cilium
            ├── helm repo add + helm upgrade --install (on Proxmox host)
            └── Wait for all nodes Ready
                    │
                    ▼
            Cluster is RUNNING
            (ArgoCD manages apps later)
```

---

## 4. Repository Structure

```
fluodata-infrastructure/
├── EXPERIENCE.md              # Hard-won deployment lessons
├── DESIGN.md                  # This file
├── REQUIREMENTS.md            # Requirements spec
│
├── infra-proxmox/
│   ├── ansible/               # Active deployment
│   │   ├── ansible.cfg
│   │   ├── site.yml           # Full deploy playbook
│   │   ├── destroy.yml        # Teardown playbook
│   │   ├── inventory/
│   │   │   ├── hosts.yml
│   │   │   └── group_vars/
│   │   │       └── all.yml    # All config in one place
│   │   └── roles/
│   │       ├── proxmox_vms/
│   │       ├── talos_cluster/
│   │       └── cilium/
│   │
│   ├── talos/                 # Generated files (by Ansible)
│   │   ├── secrets.yaml       # Cluster secrets (reusable)
│   │   ├── talosconfig
│   │   └── kubeconfig
│   │
│   └── terraform/             # Legacy (kept for reference)
│
└── cluster-gitops/            # (future) ArgoCD apps
```

---

## 5. Ansible Scope

### 5.1 What Ansible Does

1. **Create VMs** on Proxmox
   - Control plane + worker nodes
   - Deterministic MAC addresses for DHCP
   - Boot + Longhorn disks (workers only)

2. **Generate Talos configs**
   - Cluster secrets (generated once, reused)
   - Config patches via Jinja2 templates (per-role + per-node)
   - No hostname in patches (dnsmasq handles it)

3. **Bootstrap cluster**
   - Apply configs to all nodes
   - Bootstrap control plane etcd
   - Fetch kubeconfig

4. **Install Cilium** via Helm
   - Post-bootstrap (nodes NotReady until CNI deploys)
   - Wait for all nodes Ready

### 5.2 What Ansible Does NOT Do

- **Kubernetes workloads** — that's ArgoCD's job
- **Proxmox host setup** — assumed pre-configured (dnsmasq, bridges, tools)
- **WireGuard** — manual or separate automation

---

## 6. Network

- **Internal network**: 10.10.0.0/24 (Proxmox vmbr1)
- **DHCP**: dnsmasq on vmbr1 with MAC-based leases + hostnames
- **Gateway/DNS**: 10.10.0.1 (Proxmox host)
- **Public ports** (via port forwarding): 80, 443, 1883, 8883

---

## 7. Node Definitions

| Node     | VMID | IP         | vCPU | RAM   | Boot | Longhorn |
|----------|------|------------|------|-------|------|----------|
| cp-0     | 110  | 10.10.0.10 | 2    | 4 GB  | 20G  | -        |
| worker-0 | 120  | 10.10.0.20 | 4    | 8 GB  | 20G  | 20G      |
| worker-1 | 121  | 10.10.0.21 | 4    | 8 GB  | 20G  | 20G      |

---

## 8. Deployment Flow

```bash
# From infra-proxmox/ansible/ directory:

# Deploy everything (~5 minutes)
ansible-playbook site.yml

# Tear down (stop + destroy VMs)
ansible-playbook destroy.yml
```

### Prerequisites on Proxmox host:
- dnsmasq configured on vmbr1 with MAC-based DHCP + hostnames
- `talosctl`, `kubectl`, `helm` installed
- SSH key auth from laptop

### Prerequisites on laptop:
- `ansible-core` via pipx with `proxmoxer`, `requests`, `requests-toolbelt` injected
- `community.proxmox` collection installed

---

## 9. Key Lessons (see EXPERIENCE.md for full details)

1. **Cilium post-bootstrap via Helm** — simpler than inline manifests
2. **No hostname in Talos patches** — dnsmasq DHCP conflict with Talos v1.12.4
3. **Proxmox API modules on localhost** — `delegate_to: localhost` for proxmoxer
4. **talosctl/helm on Proxmox host** — VMs not reachable from laptop
5. **Factory image with extensions** — iscsi-tools, util-linux-tools for Longhorn
6. **Secrets idempotency** — check both local and remote before generating

---

## 10. Future: GitOps (ArgoCD) Scope

| App | Purpose |
|-----|---------|
| **Cilium** | CNI (managed by ArgoCD after initial Helm install) |
| **Longhorn** | Storage |
| **Traefik** | Ingress + TLS |
| **VictoriaMetrics** | Monitoring |
| **Loki** | Logs |
| **CloudNativePG** | PostgreSQL |
| **RabbitMQ** | MQTT broker |

---

## 11. Open Questions

1. **Secrets**: Same repo with SOPS, or separate?
2. **CI/CD**: Manual `ansible-playbook` or GitHub Actions?
3. **Multi-host**: How to handle multiple Proxmox hosts (Phase 3)?
