# fluodata-infrastructure

Kubernetes platform for the FluoData/FluoCare IoT monitoring application. Clusters are provisioned by Ansible (Talos Linux on VPS or Proxmox), then managed declaratively by ArgoCD from this git repository.

## Architecture

```
Ansible provisions:
  Talos Linux cluster (VPS or Proxmox VMs)
    └── Cilium (CNI)
    └── ArgoCD (GitOps controller)

ArgoCD then manages everything else:
    ├── Traefik / ingress-nginx + cert-manager (TLS)
    ├── VictoriaMetrics + Grafana (monitoring)
    ├── Loki + Alloy (logging)
    ├── CloudNativePG (PostgreSQL operator)
    ├── RabbitMQ (message broker + MQTT)
    └── ScyllaDB (time-series storage)
    # Note: all stateful apps use local-path storage; Longhorn is not deployed
    # (app-layer replication makes distributed storage redundant)
```

## Repository Structure

```
├── ansible/                        # Cluster provisioning
│   ├── vps-deploy-rescue.yml       # VPS step 1: write Talos to disk (rescue mode)
│   ├── vps-deploy.yml              # VPS step 2: bootstrap + Cilium + ArgoCD
│   ├── vps-argocd.yml              # ArgoCD-only install/upgrade
│   ├── proxmox-deploy.yml          # Proxmox: full deploy
│   └── roles/                      # talos_generate, cilium, argocd, etc.
│
├── environments/
│   ├── vps-example/config.yml      # Copy this for a new VPS environment
│   └── proxmox-example/config.yml  # Copy this for a new Proxmox environment
│   # Real envs: gitignored (contain secrets) or SOPS-encrypted
│
├── kubernetes/                     # GitOps manifests (ArgoCD watches this)
│   ├── base/argocd/                # ArgoCD Helm values + KSOPS config
│   ├── base/<app>/                 # Shared Kustomize bases per app
│   ├── overlays/vps-ovh-test1/    # Per-cluster Kustomize overlays
│   └── clusters/vps-ovh-test1/    # Live cluster — 17 ArgoCD Application CRs
│
├── .sops.yaml                      # SOPS encryption rules
└── agents.md                       # AI agent reference (architecture, lessons, workflows)
```

## Prerequisites

- [`ansible`](https://docs.ansible.com/) with `community.proxmox` collection (for Proxmox)
- [`talosctl`](https://www.talos.dev/latest/talos-guides/install/talosctl/)
- [`kubectl`](https://kubernetes.io/docs/tasks/tools/)
- [`helm`](https://helm.sh/)
- [`sops`](https://github.com/getsops/sops) >= 3.8
- [`age`](https://github.com/FiloSottile/age) (for SOPS encryption)
- Age private key at `~/.config/sops/age/keys.txt`

## Quick Start

### New VPS environment

```bash
# 1. Create environment
cp -r environments/vps-example environments/vps-prod
vim environments/vps-prod/config.yml       # Fill in IPs, tokens, schematic ID
sops --encrypt --in-place environments/vps-prod/config.yml

# 2. Step 1: Write Talos to disk (nodes must be in rescue mode)
cd ansible
ansible-playbook vps-deploy-rescue.yml -e env=../environments/vps-prod

# 3. Manual step: switch VPS boot mode from rescue → local, then reboot
#    (OVH: Manager → Bare Metal Cloud → VPS → Boot → Local Boot → Apply → Reboot)

# 4. Step 2: Bootstrap cluster
ansible-playbook vps-deploy.yml -e env=../environments/vps-prod
```

Total deploy time: ~5 minutes to all nodes Ready with Cilium and ArgoCD running.

### New Proxmox environment

```bash
cp -r environments/proxmox-example environments/proxmox-homelab
vim environments/proxmox-homelab/config.yml

cd ansible
ansible-playbook proxmox-deploy.yml -e env=../environments/proxmox-homelab
```

### Accessing the cluster

```bash
# kubeconfig is written to environments/<name>/kubeconfig
export KUBECONFIG=environments/vps-ovh-test1/kubeconfig

# Access ArgoCD UI
kubectl port-forward svc/argocd-server -n argocd 8080:443
# Open https://localhost:8080  |  Username: admin
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d
```

## Secret Management (SOPS + age)

Secrets are encrypted with SOPS using an age key and stored in git. ArgoCD decrypts them at sync time via the KSOPS kustomize plugin.

```bash
# Edit an encrypted file
sops environments/vps-ovh-test1/config.yml

# Encrypt a new Kubernetes secret for ArgoCD
sops --encrypt --in-place kubernetes/base/my-app/secret.yaml

# View without modifying
sops --decrypt environments/vps-ovh-test1/config.yml
```

See `agents.md` for detailed SOPS/KSOPS workflow and the full architecture reference.

## Adding an Application to GitOps

1. Add manifests under `kubernetes/base/<app-name>/` (or `kubernetes/overlays/<env>/<app-name>/` for env-specific config), **or** use an external Helm chart repo directly
2. Add an ArgoCD Application CR to `kubernetes/clusters/<cluster-name>/<app-name>.yaml`
3. Commit and push — ArgoCD auto-syncs

See `agents.md` for a full Application CR template and encrypted secret workflow.

## Live Environments

| Environment | Type | Nodes | Status |
|---|---|---|---|
| `vps-ovh-test1` | OVH VPS | 3 × combined CP+worker | Live |
| `proxmox-local-vm` | Proxmox | - | Dev/test |
| `proxmox-local-vm2` | Proxmox | - | Dev/test |
