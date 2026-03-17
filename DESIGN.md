# FluoData Infrastructure — Design

**Version:** 5.0 (Ansible + ArgoCD, multi-platform)
**Status:** VPS (OVH 3-node) tested and running in production. Proxmox tested (pre-refactor, re-test pending).
**Date:** 2026-03-17

---

## 1. Core Goal

**One config file per environment. All infra + access files in one folder.**

```bash
# New environment: copy example, fill one config file, deploy
cp -r environments/vps-example/ environments/vps-prod/
vim environments/vps-prod/config.yml
sops --encrypt --in-place environments/vps-prod/config.yml

cd ansible
ansible-playbook vps-deploy-rescue.yml -e env=../environments/vps-prod  # Step 1: write Talos to disk
# --- Manual: switch VPS boot mode to local, reboot (provider dashboard) ---
ansible-playbook vps-deploy.yml -e env=../environments/vps-prod          # Step 2: bootstrap cluster
```

After deploy, the env folder contains everything:

```
environments/vps-prod/
├── config.yml          # Your settings (SOPS-encrypted)
├── secrets.yaml        # Talos cluster secrets (generated once)
├── talosconfig         # Talos admin access
├── kubeconfig          # Kubernetes admin access
├── controlplane.yaml   # Generated Talos CP config
├── worker.yaml         # Generated Talos worker config
└── patch-*.yaml        # Generated node patches
```

---

## 2. Architecture

The repository has two layers of responsibility:

**Layer 1 — Cluster provisioning (Ansible)**
Ansible handles all day-0 tasks that require direct machine access: writing Talos to disk, bootstrapping the cluster, installing Cilium CNI, and installing ArgoCD. Once the cluster is running, Ansible's job is done (except for upgrades).

**Layer 2 — Application delivery (ArgoCD + GitOps)**
ArgoCD continuously syncs Kubernetes manifests from git to the cluster. All application workloads, secrets, and infrastructure components (ingress, monitoring, databases) are managed declaratively from git.

```
┌─────────────────────────────────────────────────────┐
│  Git repository (single source of truth)            │
│                                                     │
│  ansible/        → cluster provisioning             │
│  environments/   → per-env config (SOPS-encrypted)  │
│  kubernetes/     → ArgoCD Application CRs + manifests│
│  .sops.yaml      → encryption rules                 │
└──────────┬──────────────────────┬───────────────────┘
           │                      │
  Ansible provisions       ArgoCD syncs
  cluster + ArgoCD         manifests to cluster
           │                      │
           ▼                      ▼
┌──────────────────────────────────────────────────┐
│  Kubernetes cluster                              │
│                                                  │
│  kube-system     → Cilium CNI (Ansible install)  │
│  argocd          → ArgoCD + KSOPS                │
│  *               → workloads (ArgoCD-managed)    │
└──────────────────────────────────────────────────┘
```

---

## 3. Repository Structure

```
fluodata-infrastructure/
├── ansible/
│   ├── ansible.cfg
│   ├── proxmox-deploy.yml          # Proxmox: full deploy
│   ├── proxmox-destroy.yml         # Proxmox: destroy cluster
│   ├── vps-deploy-rescue.yml       # VPS step 1: write Talos to disk (rescue mode)
│   ├── vps-deploy.yml              # VPS step 2: bootstrap + Cilium + ArgoCD
│   ├── vps-argocd.yml              # ArgoCD-only install/upgrade
│   ├── vps-destroy.yml             # VPS: destroy cluster
│   ├── tasks/
│   │   ├── load-config.yml         # Resolve path, load + SOPS-decrypt config.yml
│   │   ├── validate-proxmox.yml    # Check Proxmox fields, add_host
│   │   └── validate-vps.yml        # Check VPS fields, add rescue hosts
│   └── roles/
│       ├── talos_generate/         # Generate secrets, patches, machine configs
│       ├── talos_bootstrap_proxmox/# Apply configs, bootstrap, kubeconfig (Proxmox)
│       ├── talos_bootstrap_vps/    # Apply configs, bootstrap, kubeconfig (VPS)
│       ├── talos_install/          # Write Talos image to disk (rescue mode)
│       ├── proxmox_vms/            # Create/start Proxmox VMs
│       ├── proxmox_dnsmasq/        # dnsmasq DHCP config
│       ├── proxmox_post_install/   # Fix boot order after Talos install
│       ├── cilium/                 # Helm install Cilium
│       ├── kubelet_cert_approver/  # Auto-approve kubelet serving cert CSRs
│       └── argocd/                 # Install ArgoCD + KSOPS, create root Application
│
├── environments/
│   ├── proxmox-example/config.yml  # Committed — copy for new Proxmox env
│   └── vps-example/config.yml      # Committed — copy for new VPS env
│   # Real envs are GITIGNORED (contain secrets + generated files):
│   # environments/proxmox-homelab/
│   # environments/vps-ovh-test1/   ← live cluster (SOPS-encrypted, committed)
│
├── kubernetes/                     # GitOps manifests (ArgoCD watches this)
│   ├── base/argocd/                # ArgoCD Helm values (KSOPS config)
│   ├── base/<app>/                 # Shared Kustomize bases per app
│   ├── overlays/
│   │   └── vps-ovh-test1/          # Per-cluster Kustomize overlays
│   └── clusters/
│       └── vps-ovh-test1/          # Live cluster: 17 ArgoCD Application CRs
│           ├── apps.yaml           # Root Application (self-referencing app-of-apps)
│           └── *.yaml              # One Application CR per managed component
│
├── .sops.yaml                      # SOPS encryption rules
└── .gitignore
```

---

## 4. Design Decisions

| Decision | Rationale |
|----------|-----------|
| **Single config file** | One `config.yml` per environment. No hunting across hosts.yml, group_vars, playbooks. |
| **Env folder = state folder** | All generated files (secrets, kubeconfig, talosconfig, patches) live in the env folder. Entire cluster state in one place. |
| **Real env folders gitignored** | `proxmox-*/`, `vps-*/` are gitignored (except `*-example/`). Exception: `vps-ovh-test1/` is committed SOPS-encrypted because it contains only encrypted config.yml. |
| **Ansible over Terraform** | Terraform's `stop_on_destroy` with Talos VMs is dangerously slow (5+ min ACPI timeout). Ansible handles imperative flow cleanly with `force: true`. |
| **Two-step VPS deploy** | Rebooting from rescue mode re-enters rescue unless boot mode is first switched in the provider dashboard. `vps-deploy-rescue.yml` writes Talos to disk; manual reboot; `vps-deploy.yml` bootstraps. |
| **Cilium via Helm post-bootstrap** | Post-bootstrap `helm install` is simpler than embedding 1600+ lines of YAML in Talos config. K8s API is reachable before nodes are Ready. |
| **ArgoCD app-of-apps** | `kubernetes/clusters/<env>/` holds all ArgoCD Application CRs. Each Application sources from `kubernetes/base/<app>`, `kubernetes/overlays/<env>/<app>`, or an external Helm chart repo. Everything in one tree. |
| **SOPS + age + KSOPS** | Secrets encrypted in git. No external vault needed. ArgoCD decrypts in-cluster via KSOPS kustomize plugin. Simpler than SealedSecrets. |
| **`deviceSelector: { physical: true }`** | Works across QEMU and bare metal. `interface: eth0` silently breaks VIP on Talos. |
| **`kubelet-serving-cert-approver`** | `rotate-server-certificates: true` causes kubelet to request serving certs via CSR. K8s only auto-approves client CSRs. Without this controller, `kubectl logs/exec/port-forward` fail with TLS errors when certs rotate. |
| **VPS not OVH** | Platform is `vps`, not `ovh` — not tied to a specific provider. Works with any VPS that supports rescue mode boot. |

---

## 5. How It Works

### VPS Deploy Flow

```
STEP 1: Write Talos to disk (rescue mode, one-time)

vps-deploy-rescue.yml -e env=../environments/vps-prod
    ├── Play 1: localhost
    │   ├── load-config.yml   → resolve path, SOPS-decrypt config.yml, load
    │   ├── validate-vps.yml  → check fields, set vars, add rescue hosts
    │   └── talos_generate    → secrets, patches, machine configs → env_dir
    ├── Play 2: rescue_mode
    │   └── talos_install     → dd Talos image to disk
    └── Play 3: localhost
        └── Print next steps (switch boot mode, reboot)

--- Manual: switch VPS to normal boot + reboot (provider dashboard) ---

STEP 2: Bootstrap cluster

vps-deploy.yml -e env=../environments/vps-prod
    └── Play 1: localhost
        ├── load-config.yml       → SOPS-decrypt, load
        ├── validate-vps.yml      → check fields
        ├── talos_generate        → idempotent (same secrets → same configs)
        ├── talos_bootstrap_vps   → wait for Talos API → apply → bootstrap → kubeconfig
        ├── cilium                → Helm install, wait for nodes Ready
        ├── kubelet_cert_approver → deploy cert approver controller
        └── argocd                → install ArgoCD + KSOPS, create root Application
```

### Proxmox Deploy Flow

```
proxmox-deploy.yml -e env=../environments/proxmox-homelab
    ├── Play 1: localhost
    │   ├── load-config.yml         → resolve path, load config.yml
    │   ├── validate-proxmox.yml    → check fields, add Proxmox host
    │   └── talos_generate          → secrets, patches, machine configs
    └── Play 2: proxmox_hosts
        ├── proxmox_dnsmasq         → configure DHCP reservations
        ├── proxmox_vms             → download ISO, create VMs, start
        ├── talos_bootstrap_proxmox → apply configs, bootstrap, kubeconfig
        ├── proxmox_post_install    → switch boot order, detach ISO
        ├── cilium                  → Helm install, wait for nodes Ready
        ├── kubelet_cert_approver   → deploy cert approver controller
        └── argocd                  → install ArgoCD + KSOPS, create root Application
```

### GitOps Flow (post-bootstrap)

```
Developer pushes to git
    └── ArgoCD detects diff (polls or webhook)
        └── Renders manifests (kustomize + KSOPS decrypts secrets)
            └── Applies to cluster (automated prune + self-heal)
```

ArgoCD root Application watches `kubernetes/clusters/<env-name>/`. Each file there is an
ArgoCD Application CR. Applications point to either:
- A path in `kubernetes/base/<app>` or `kubernetes/overlays/<env>/<app>` (Kustomize, git-backed)
- An external Helm chart repository (cert-manager, VictoriaMetrics, Traefik, Loki, etc.)

To add a new workload: add an Application CR in `kubernetes/clusters/<env>/` and (if
git-backed) add the manifests under `kubernetes/base/` or `kubernetes/overlays/<env>/`.

---

## 6. Config File Schema

### VPS (`environments/vps-example/config.yml`)

```yaml
platform: vps

talos_version: v1.12.4
talos_schematic_id: <factory-schematic-id>
cluster_name: fluodata

vm_gateway: REPLACE_WITH_GATEWAY
controlplane_nodes:
  - name: node-0
    ip: REPLACE_WITH_PUBLIC_IP
    rescue_ssh_host: REPLACE_WITH_RESCUE_IP
    rescue_ssh_pass: REPLACE_ME       # SOPS-encrypted
worker_nodes: []                      # All nodes are combined CP+worker
cilium_version: "1.17.3"
argocd_repo_url: git@github.com:org/fluodata-infrastructure.git
```

### Proxmox (`environments/proxmox-example/config.yml`)

```yaml
platform: proxmox

proxmox_host: 192.168.122.70
proxmox_node: pve
proxmox_api_user: root@pam
proxmox_api_token_id: ansible
proxmox_api_token_secret: REPLACE_ME  # SOPS-encrypted
proxmox_ssh_host: 192.168.122.70
proxmox_ssh_user: root

talos_version: v1.12.4
talos_schematic_id: <factory-schematic-id>
cluster_name: fluodata
cluster_vip: 10.10.0.5

vm_gateway: 10.10.0.1
controlplane_nodes: [...]
worker_nodes: [...]
cilium_version: "1.17.3"
argocd_repo_url: git@github.com:org/fluodata-infrastructure.git
```

---

## 7. Security

### Env folders
- Gitignored (`environments/proxmox-*/`, `environments/vps-*/` except `*-example/` and SOPS-encrypted real envs)
- Contain secrets, kubeconfig, talosconfig — treat as highly sensitive
- **Backup**: sync to encrypted cloud storage (age-encrypted tarball to S3/Backblaze)

### Secret management (SOPS + age)
- `environments/*/config.yml` — only sensitive fields encrypted (`rescue_ssh_pass`, `password`, `*_secret`)
- `kubernetes/**/*secret*.yaml` — `data` and `stringData` fields encrypted
- Age private key lives at `~/.config/sops/age/keys.txt` — never committed, back up to password manager
- In-cluster: age private key stored as `sops-age` Kubernetes Secret; KSOPS plugin uses it to decrypt during ArgoCD sync

### VPS network
- Talos has no host firewall — provider network firewall is mandatory
- Ports 50000 (Talos API) and 6443 (K8s API) are mTLS but should be IP-restricted at the firewall
- WireGuard for admin VPN access to internal cluster services

---

## 8. Sync Wave Order (ArgoCD)

Components deploy in this order via `argocd.argoproj.io/sync-wave` annotations:

| Wave | Components |
|------|------------|
| -3   | Namespaces (PodSecurity labels), NetworkPolicies |
| -2   | Cilium (CNI), kubelet-csr-approver |
| -1   | Cilium config (IP pools, L2) |
|  0   | Ingress, cert-manager, VictoriaMetrics, Loki, Alloy |
|  1   | cert-manager ClusterIssuers, operators (CNPG, RabbitMQ, ScyllaDB), app secrets |
|  2   | Database/broker instances (PostgreSQL, RabbitMQ, ScyllaDB) |

---

## 9. What Ansible Manages vs What ArgoCD Manages

| Component | Managed by | Why |
|-----------|------------|-----|
| VM/VPS lifecycle | Ansible | Requires host-level access |
| Talos OS | Ansible | Machine-level config |
| Cilium CNI (initial install) | Ansible | Cluster needs CNI before ArgoCD can run |
| kubelet-cert-approver (initial) | Ansible | Needed before ArgoCD pods start properly |
| ArgoCD (initial install) | Ansible | Bootstrap — ArgoCD cannot install itself |
| Application workloads | ArgoCD | GitOps — push to git, auto-synced |
| Kubernetes Secrets | ArgoCD + KSOPS | Encrypted in git, decrypted in-cluster |
| Ingress, cert-manager, monitoring | ArgoCD | Standard Kubernetes components |
| Cilium upgrades + config | ArgoCD | After initial bootstrap, ArgoCD takes over |
