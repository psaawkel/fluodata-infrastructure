# FluoData Infrastructure - Unified Multi-Platform Design

**Version:** 3.0 (Ansible-based, multi-platform)  
**Status:** Proxmox working, OVH planned  
**Date:** 2026-02-24

---

## 1. Core Goal

**One command to deploy a bare Talos cluster on either platform:**

```bash
# Proxmox (dev/staging)
cd ansible
ansible-playbook -i environments/proxmox/hosts.yml environments/proxmox/site.yml

# OVH VPS (production)
cd ansible
ansible-playbook -i environments/ovh/hosts.yml environments/ovh/site.yml
```

**One command to tear it down:**
```bash
ansible-playbook -i environments/proxmox/hosts.yml environments/proxmox/destroy.yml
ansible-playbook -i environments/ovh/hosts.yml environments/ovh/destroy.yml
```

---

## 2. Design Decisions

| Decision | Rationale |
|----------|-----------|
| **Ansible over Terraform** | Terraform's `stop_on_destroy` with Talos VMs is dangerously slow (5+ min ACPI timeout). Ansible handles VM lifecycle, imperative bootstrap steps (talosctl, helm), and teardown cleanly. |
| **Unified repo, two environments** | Common roles (`talos_bootstrap`, `cilium`) shared across platforms. Platform-specific roles (`proxmox_vms`, `talos_install`) only where needed. |
| **No shell scripts** | All automation lives in Ansible roles. |
| **Cilium via Helm** (not inline manifest) | Post-bootstrap `helm install` is simpler than embedding 1600+ lines of YAML in Talos config. Nodes are `NotReady` until Cilium deploys — this is expected. |
| **No `machine.network.hostname`** | dnsmasq assigns hostnames via DHCP (Proxmox). Talos auto-generates (OVH). Talos v1.12.4 rejects configs if DHCP already set hostname. |
| **`deviceSelector: { physical: true }`** | Replaces `interface: eth0` for VIP and network config. Works across both QEMU and bare metal. |
| **Factory installer image** | Required for extensions persistence (iscsi-tools, util-linux-tools, qemu-guest-agent). |

---

## 3. Architecture

### 3.1 Proxmox (dev/staging)

```
ansible-playbook -i environments/proxmox/hosts.yml environments/proxmox/site.yml
    │
    ├── Role: proxmox_vms          (Proxmox-only)
    │   ├── Download Talos ISO (get_url on Proxmox host)
    │   ├── Create VMs (proxmox_kvm → REST API from localhost)
    │   └── Start VMs
    │
    ├── Role: talos_bootstrap      (COMMON)
    │   ├── Generate secrets (talosctl on Proxmox host)
    │   ├── Generate config patches (Jinja2 templates)
    │   ├── Generate configs from secrets + patches
    │   ├── Apply configs to each node
    │   ├── Bootstrap etcd
    │   └── Fetch kubeconfig
    │
    ├── Role: proxmox_post_install (Proxmox-only)
    │   └── Switch boot order to disk-first, detach ISO
    │
    └── Role: cilium               (COMMON)
        ├── helm install Cilium
        └── Wait for all nodes Ready
```

### 3.2 OVH VPS (production)

```
ansible-playbook -i environments/ovh/hosts.yml environments/ovh/site.yml
    │
    ├── Play 1 — hosts: rescue_mode
    │   └── Role: talos_install    (OVH-only)
    │       ├── Download Talos metal RAW image
    │       ├── dd image to /dev/sda
    │       └── Reboot into Talos
    │
    └── Play 2 — hosts: localhost
        ├── Role: talos_bootstrap  (COMMON, talosctl_delegate_to: localhost)
        │   ├── Generate secrets (talosctl locally)
        │   ├── Generate config patches
        │   ├── Apply configs via public IPs
        │   ├── Bootstrap etcd
        │   └── Save kubeconfig locally
        │
        └── Role: cilium           (COMMON, talosctl_delegate_to: localhost)
            ├── helm install Cilium
            └── Wait for all nodes Ready
```

---

## 4. Repository Structure

```
fluodata-infrastructure/
├── ansible/
│   ├── ansible.cfg
│   ├── environments/
│   │   ├── proxmox/
│   │   │   ├── hosts.yml              # Proxmox host (192.168.122.70)
│   │   │   ├── group_vars/all.yml     # Proxmox vars, node defs, network
│   │   │   ├── site.yml               # proxmox_vms → talos_bootstrap → proxmox_post_install → cilium
│   │   │   └── destroy.yml            # Stop + destroy VMs
│   │   └── ovh/
│   │       ├── hosts.yml              # VPS nodes (rescue mode) + localhost
│   │       ├── group_vars/all.yml     # OVH vars, public IPs, vRack
│   │       ├── site.yml               # talos_install → talos_bootstrap → cilium
│   │       └── destroy.yml            # talosctl reset
│   └── roles/
│       ├── proxmox_vms/               # Proxmox-only: create/start VMs
│       ├── proxmox_post_install/      # Proxmox-only: boot order fix
│       ├── talos_install/             # OVH-only: dd image in rescue mode
│       ├── talos_bootstrap/           # COMMON: secrets, configs, apply, bootstrap
│       └── cilium/                    # COMMON: helm install Cilium
│
├── talos/                             # Generated files (secrets, kubeconfig, talosconfig)
├── _archive/terraform/                # Legacy Terraform code
├── DESIGN.md                          # This file
├── EXPERIENCE.md                      # Hard-won deployment lessons
├── REQUIREMENTS.md                    # Original requirements
└── .gitignore
```

---

## 5. Platform Parameterization

Common roles (`talos_bootstrap`, `cilium`) work across platforms via these variables:

| Variable | Proxmox | OVH | Purpose |
|----------|---------|-----|---------|
| `talosctl_delegate_to` | *undefined* (runs on inventory host) | `"localhost"` (runs locally) | Where talosctl/kubectl/helm execute |
| `talos_work_dir` | `/tmp/talos-deploy` (on Proxmox host) | `../../talos` (local) | Where talosctl operates |
| `talos_local_dir` | `../../talos` (local) | `../../talos` (local) | Where secrets/kubeconfig are persisted |
| `talos_install_disk` | `/dev/sda` | `/dev/sda` or `/dev/vda` | Target disk for Talos install |
| `cluster_vip` | `10.10.0.5` | *undefined* (no VIP on OVH) | Virtual IP for HA API access |

---

## 6. Platforms

### 6.1 Proxmox (dev/staging)

- **Network**: 10.10.0.0/24 on vmbr1 (internal)
- **DHCP**: dnsmasq on vmbr1 with MAC-based leases + hostnames
- **Gateway/DNS**: 10.10.0.1 (Proxmox host)
- **talosctl runs on**: Proxmox host (VMs unreachable from laptop)
- **Nodes**: 1 CP + 2 workers (separate roles)

| Node     | VMID | IP         | vCPU | RAM   | Boot | Longhorn |
|----------|------|------------|------|-------|------|----------|
| cp-0     | 110  | 10.10.0.10 | 2    | 4 GB  | 20G  | -        |
| worker-0 | 120  | 10.10.0.20 | 4    | 8 GB  | 20G  | 20G      |
| worker-1 | 121  | 10.10.0.21 | 4    | 8 GB  | 20G  | 20G      |

### 6.2 OVH VPS (production)

- **Network**: Public IPs (OVH-assigned) + vRack private subnet
- **No VIP**: OVH doesn't support gratuitous ARP on public IPs
- **Firewall**: OVH network firewall (mandatory — Talos has no host firewall)
- **talosctl runs on**: Laptop/CI (nodes have public IPs)
- **Nodes**: 3x combined CP+worker (8 vCPU, 24 GB RAM, 200 GB NVMe each)
- **Install method**: Rescue mode + `dd` (no custom ISO upload on VPS)
- **Cost**: ~50 PLN/month per VPS

---

## 7. Security (OVH)

Talos has **no host firewall** (no iptables/nftables). All listening ports are reachable on public IPs.

**Required OVH firewall rules:**
- Allow TCP 50000 (Talos API) — mTLS, but should be IP-restricted
- Allow TCP 6443 (K8s API) — mTLS, but should be IP-restricted
- Allow UDP (WireGuard port) — silent without valid key
- Block everything else inbound

**Admin access**: WireGuard pod running in cluster, UDP port silent without valid key.

---

## 8. Key Lessons (see EXPERIENCE.md for details)

1. **Boot order fix (Proxmox)** — After Talos installs to disk, switch boot to `scsi0` and detach ISO. Otherwise host suspend/resume causes ISO boot + halt.
2. **Cilium post-bootstrap via Helm** — simpler than inline manifests
3. **No hostname in Talos patches** — DHCP/Talos hostname conflict
4. **Factory image with extensions** — iscsi-tools, util-linux-tools for Longhorn; qemu-guest-agent for Proxmox
5. **Secrets idempotency** — check both local and remote before generating
6. **talosconfig empty endpoints** — `talosctl gen config` produces empty endpoints; must run `talosctl config endpoint` after
7. **OVH VPS vs Public Cloud** — Public Cloud supports ISO upload but costs 16x more. VPS with rescue mode + `dd` is the viable path.

---

## 9. Future: GitOps (ArgoCD) Scope

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

## 10. Open Questions

1. **Secrets**: Same repo with SOPS, or separate?
2. **CI/CD**: Manual `ansible-playbook` or GitHub Actions?
3. **OVH VIP alternative**: Use DNS round-robin or load balancer for K8s API HA?
4. **vRack config**: How to configure private networking between VPS nodes?
