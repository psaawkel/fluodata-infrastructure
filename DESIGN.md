# FluoData Infrastructure — Unified Multi-Platform Design

**Version:** 3.1 (Ansible-based, multi-platform, env-folder pattern)  
**Status:** Proxmox working (pre-refactor test pending), VPS planned  
**Date:** 2026-02-24

---

## 1. Core Goal

**One config file per environment. All infra + access files in one folder.**

```bash
# New environment: copy example, fill one config file, deploy
cp -r environments/proxmox-example/ environments/proxmox-homelab/
vim environments/proxmox-homelab/config.yml

cd ansible
ansible-playbook proxmox-deploy.yml -e env=../environments/proxmox-homelab
ansible-playbook proxmox-destroy.yml -e env=../environments/proxmox-homelab
```

After deploy, the env folder contains everything:
```
environments/proxmox-homelab/
├── config.yml          # Your settings (the only file you edit)
├── secrets.yaml        # Talos cluster secrets (generated once)
├── talosconfig         # Talos admin access
├── kubeconfig          # Kubernetes admin access
├── controlplane.yaml   # Generated Talos CP config
├── worker.yaml         # Generated Talos worker config
├── patch-*.yaml        # Generated node patches
```

---

## 2. Design Decisions

| Decision | Rationale |
|----------|-----------|
| **Single config file** | One `config.yml` per environment. No hunting across hosts.yml, group_vars, playbooks. |
| **Env folder = state folder** | All generated files (secrets, kubeconfig, talosconfig, patches) live in the env folder. Your entire cluster state in one place. |
| **Gitignored env folders** | Real env folders (`proxmox-*`, `vps-*`) are gitignored. Only `*-example/` are committed. Sync real folders to a secure cloud backup. |
| **Ansible over Terraform** | Terraform's `stop_on_destroy` with Talos VMs is dangerously slow (5+ min ACPI timeout). Ansible handles the imperative flow cleanly. |
| **Split playbooks per platform** | `proxmox-deploy.yml`, `vps-deploy.yml`, `proxmox-destroy.yml`, `vps-destroy.yml`. No platform checks inside playbooks — clean linear flow. Playbook validates `platform` field matches and fails early if wrong. |
| **Extracted validations** | Common config loading (`tasks/load-config.yml`) and per-platform validation (`tasks/validate-proxmox.yml`, `tasks/validate-vps.yml`) are in reusable task files. |
| **Merged plays by host** | Plays targeting the same host are merged into a single play with multiple roles. No unnecessary play boundaries. |
| **VPS not OVH** | Platform is `vps`, not `ovh` — not tied to a specific provider. Works with any VPS that supports rescue mode boot. |
| **Cilium via Helm** | Post-bootstrap `helm install` is simpler than embedding 1600+ lines of YAML in Talos config. |
| **No `machine.network.hostname`** | dnsmasq handles it (Proxmox) or Talos auto-generates (VPS). |
| **`deviceSelector: { physical: true }`** | Works across QEMU and bare metal. |

---

## 3. Repository Structure

```
fluodata-infrastructure/
├── ansible/
│   ├── ansible.cfg
│   ├── proxmox-deploy.yml          # Proxmox deploy
│   ├── proxmox-destroy.yml         # Proxmox destroy
│   ├── vps-deploy.yml              # VPS deploy
│   ├── vps-destroy.yml             # VPS destroy
│   ├── tasks/
│   │   ├── load-config.yml         # Common: resolve path, load config.yml
│   │   ├── validate-proxmox.yml    # Proxmox: check fields, set vars, add_host
│   │   └── validate-vps.yml        # VPS: check fields, set vars, add rescue hosts
│   └── roles/
│       ├── proxmox_vms/            # Proxmox-only: create/start VMs
│       ├── proxmox_post_install/   # Proxmox-only: boot order fix
│       ├── talos_install/          # VPS-only: dd image in rescue mode
│       ├── talos_bootstrap/        # COMMON: secrets, configs, apply, bootstrap
│       └── cilium/                 # COMMON: helm install Cilium
│
├── environments/
│   ├── proxmox-example/            # Committed — copy for new Proxmox env
│   │   └── config.yml
│   └── vps-example/                # Committed — copy for new VPS env
│       └── config.yml
│
│   # Real envs are GITIGNORED (contain secrets + generated files):
│   # environments/proxmox-homelab/
│   # environments/vps-prod/
│
├── _archive/terraform/             # Legacy Terraform code
├── infra-proxmox/                  # Old working Ansible (reference, to be removed)
├── DESIGN.md, EXPERIENCE.md, REQUIREMENTS.md
└── .gitignore
```

---

## 4. Config File Schema

### Proxmox (`environments/proxmox-example/config.yml`)

```yaml
platform: proxmox

# Proxmox connection
proxmox_host: 192.168.122.70
proxmox_node: pve
proxmox_api_user: root@pam
proxmox_api_token_id: terraform
proxmox_api_token_secret: REPLACE_ME
proxmox_ssh_host: 192.168.122.70
proxmox_ssh_user: root

# Talos + cluster
talos_version: v1.12.4
talos_schematic_id: e187c9b...
cluster_name: fluodata
cluster_vip: 10.10.0.5

# Network + nodes + Cilium
vm_gateway: 10.10.0.1
controlplane_nodes: [...]
worker_nodes: [...]
cilium_version: "1.17.3"
```

### VPS (`environments/vps-example/config.yml`)

```yaml
platform: vps

# Talos + cluster (no VIP on VPS)
talos_version: v1.12.4
talos_schematic_id: e187c9b...
cluster_name: fluodata

# Network + nodes (public IPs)
vm_gateway: REPLACE_WITH_GATEWAY
controlplane_nodes:
  - name: node-0
    ip: REPLACE_WITH_PUBLIC_IP
worker_nodes: []             # All nodes are combined CP+worker
cilium_version: "1.17.3"
```

---

## 5. How It Works

### Proxmox Flow

```
proxmox-deploy.yml -e env=../environments/proxmox-homelab
    │
    ├── Play 1: localhost
    │   ├── load-config.yml → resolve path, load config.yml
    │   └── validate-proxmox.yml → check fields, set vars, add Proxmox host
    │
    └── Play 2: proxmox_hosts (single play, 4 roles)
        ├── proxmox_vms        → Download ISO, create VMs, start VMs
        ├── talos_bootstrap    → Secrets → patches → configs → apply → bootstrap → kubeconfig
        ├── proxmox_post_install → Switch boot order to disk, detach ISO
        └── cilium             → Install Cilium, wait for nodes Ready
```

### VPS Flow

```
vps-deploy.yml -e env=../environments/vps-prod
    │
    ├── Play 1: localhost
    │   ├── load-config.yml → resolve path, load config.yml
    │   └── validate-vps.yml → check fields, set vars, add rescue hosts
    │
    ├── Play 2: rescue_mode
    │   └── talos_install    → dd Talos image → reboot
    │
    └── Play 3: localhost (single play, 2 roles)
        ├── talos_bootstrap  → Secrets → patches → configs → apply → bootstrap → kubeconfig
        └── cilium           → Install Cilium, wait for nodes Ready
```

---

## 6. Security

### Env folders
- Gitignored (`environments/proxmox-*/`, `environments/vps-*/` except `*-example/`)
- Contain secrets, kubeconfig, talosconfig — treat as sensitive
- **Backup**: Sync to encrypted cloud storage (e.g., age-encrypted tarball to S3/Backblaze)

### VPS network
- Talos has NO host firewall — provider network firewall is mandatory
- Ports 50000 (Talos API) and 6443 (K8s API) are mTLS but should be IP-restricted
- WireGuard pod for admin VPN access

---

## 7. Key Lessons (see EXPERIENCE.md)

1. **Boot order fix (Proxmox)** — Switch to `scsi0` after install, detach ISO
2. **Cilium post-bootstrap via Helm** — not inline manifests
3. **No hostname in Talos patches** — DHCP/hostname conflict
4. **Factory image with extensions** — iscsi-tools, util-linux-tools, qemu-guest-agent
5. **Secrets idempotency** — check before generating, reuse across deploys
6. **talosconfig empty endpoints** — must run `talosctl config endpoint` after gen
7. **VPS rescue mode** — only viable install path (custom ISO not supported)

---

## 8. Future

- **GitOps (ArgoCD)** — manages apps after cluster bootstrap
- **Secure backup** — age-encrypted env folder sync to cloud
- **CI/CD** — GitHub Actions for automated deploys
- **VPS firewall automation** — via provider API
