# GitOps with ArgoCD + SOPS

This document explains how GitOps and secret management work in this repository.

## Overview

The repository serves two purposes:

1. **Infrastructure provisioning** (Ansible) — bootstraps Kubernetes clusters on VPS or Proxmox
2. **Application delivery** (ArgoCD) — continuously syncs Kubernetes manifests from git to cluster

Ansible handles the "day-0" tasks that require a cluster to exist (VM creation, Talos install,
CNI bootstrap). Once the cluster is running, ArgoCD takes over and manages everything else
declaratively from git.

Secrets are encrypted with SOPS + age and stored directly in git. No external vault service
is needed.

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│  Git Repository (single source of truth)                 │
│                                                          │
│  ansible/          → Infrastructure provisioning         │
│  environments/     → Per-env config (SOPS-encrypted)     │
│  kubernetes/       → GitOps manifests (ArgoCD watches)   │
│  .sops.yaml        → Encryption rules                   │
└────────────┬─────────────────────────┬───────────────────┘
             │                         │
    Ansible provisions          ArgoCD syncs
    cluster + ArgoCD            manifests to cluster
             │                         │
             ▼                         ▼
┌────────────────────────────────────────────────────────┐
│  Kubernetes Cluster                                    │
│                                                        │
│  argocd namespace    → ArgoCD + KSOPS (decrypts sops)  │
│  kube-system         → Cilium CNI (Ansible-managed)    │
│  app namespaces      → Your workloads (ArgoCD-managed) │
└────────────────────────────────────────────────────────┘
```

## Directory structure

```
fluodata-infrastructure/
├── ansible/                        # Infrastructure provisioning
│   ├── roles/
│   │   ├── argocd/                 # Installs ArgoCD + KSOPS via Helm
│   │   ├── cilium/                 # Installs Cilium CNI
│   │   ├── talos_generate/         # Generates Talos configs
│   │   ├── talos_bootstrap_vps/    # Bootstraps cluster (VPS)
│   │   └── ...
│   ├── vps-deploy.yml              # Full VPS deploy (includes ArgoCD)
│   ├── vps-argocd.yml              # ArgoCD-only install/upgrade
│   └── proxmox-deploy.yml          # Full Proxmox deploy (includes ArgoCD)
│
├── environments/                   # Per-environment config
│   ├── vps-example/config.yml      # Example (plaintext, committed)
│   ├── proxmox-example/config.yml  # Example (plaintext, committed)
│   └── vps-ovh-test1/config.yml    # Real env (SOPS-encrypted, committed)
│
├── kubernetes/                     # GitOps root
│   ├── base/                       # Shared Kustomize bases
│   │   └── argocd/                 # ArgoCD Helm values
│   ├── overlays/                   # Per-environment overrides
│   │   ├── production/
│   │   ├── qa/
│   │   └── local/
│   └── clusters/                   # Per-cluster ArgoCD config
│       ├── vps-prod/apps.yaml      # Root Application (app-of-apps)
│       └── vps-example/apps.yaml   # Example
│
├── .sops.yaml                      # SOPS encryption rules
└── .gitignore
```

## Secret management with SOPS + age

### What is age?

Age is a simple, modern encryption tool. It uses a keypair:
- **Public key** — used to encrypt. Stored in `.sops.yaml`, safe to commit.
- **Private key** — used to decrypt. Stored locally at `~/.config/sops/age/keys.txt`. Never committed.

### What is SOPS?

SOPS (Secrets OPerationS) encrypts specific fields in YAML/JSON files, leaving the
structure and non-sensitive fields readable. It uses `.sops.yaml` rules to determine
which fields to encrypt.

### Setup (one-time per machine)

If you're setting up on a new machine, you need the age private key. Get it from
your existing machine or password manager:

```bash
mkdir -p ~/.config/sops/age
# Copy your private key to:
# ~/.config/sops/age/keys.txt
```

To generate a NEW key (only for a new project, this re-encrypts everything):

```bash
age-keygen -o ~/.config/sops/age/keys.txt
# Update the public key in .sops.yaml
# Re-encrypt all files with: sops updatekeys <file>
```

### Daily workflow

**Editing an encrypted file:**

```bash
# Option 1: Use sops to edit (decrypts → opens editor → re-encrypts)
sops environments/vps-ovh-test1/config.yml

# Option 2: Decrypt in-place, edit, re-encrypt
sops --decrypt --in-place environments/vps-ovh-test1/config.yml
vim environments/vps-ovh-test1/config.yml
sops --encrypt --in-place environments/vps-ovh-test1/config.yml
```

**Encrypting a new file:**

```bash
sops --encrypt --in-place environments/vps-newenv/config.yml
```

**Viewing encrypted content without modifying:**

```bash
sops --decrypt environments/vps-ovh-test1/config.yml
```

### What gets encrypted

The rules in `.sops.yaml` control this:

| File pattern | Encrypted fields | Why |
|---|---|---|
| `environments/*/config.yml` | `rescue_ssh_pass`, `password`, `token`, `secret` | SSH passwords, API tokens |
| `kubernetes/**/*secret*.yaml` | `data`, `stringData` | Kubernetes Secret values |

Everything else (node IPs, cluster names, role definitions) stays in plaintext for readability.

### Ansible integration

The `load-config.yml` task automatically detects SOPS-encrypted config files and decrypts
them transparently. You run playbooks exactly the same way — no extra flags needed:

```bash
ansible-playbook vps-deploy.yml -e env=../environments/vps-ovh-test1
# Works whether config.yml is encrypted or plaintext
```

The `sops` binary must be available in PATH on the machine running Ansible.

## ArgoCD

### What ArgoCD does

ArgoCD watches this git repository and automatically syncs Kubernetes manifests to the
cluster. When you push a change to `kubernetes/`, ArgoCD detects the diff and applies it.

### How it's installed

Ansible installs ArgoCD via Helm as part of the deploy playbooks. The `argocd` role:

1. Creates the `argocd` namespace
2. Stores your age private key as a Kubernetes Secret (for KSOPS in-cluster decryption)
3. Installs the ArgoCD Helm chart with KSOPS integration
4. Creates a root Application that watches `kubernetes/clusters/<env-name>/`

### Accessing the dashboard

After deployment, ArgoCD prints connection info. To access the UI:

```bash
# Port-forward (recommended — no ingress needed)
kubectl port-forward svc/argocd-server -n argocd 8080:443 \
  --kubeconfig environments/vps-ovh-test1/kubeconfig

# Open https://localhost:8080
# Username: admin
# Password: (printed by Ansible, or retrieve with:)
kubectl get secret argocd-initial-admin-secret -n argocd \
  -o jsonpath='{.data.password}' --kubeconfig environments/vps-ovh-test1/kubeconfig | base64 -d
```

### App-of-apps pattern

ArgoCD uses the "app of apps" pattern. The root Application watches
`kubernetes/clusters/<env-name>/` and creates child Applications defined there.

Each child Application points to a component's overlay for the specific environment:

```
Root Application (apps.yaml)
  └── watches kubernetes/clusters/vps-prod/
        ├── cert-manager.yaml    → Application pointing to kubernetes/overlays/production/cert-manager/
        ├── longhorn.yaml        → Application pointing to kubernetes/overlays/production/longhorn/
        └── myapp.yaml           → Application pointing to kubernetes/overlays/production/myapp/
```

### Adding a new application to GitOps

1. Create the base manifests in `kubernetes/base/<app-name>/`
2. Create environment overlays in `kubernetes/overlays/<env>/<app-name>/`
3. Add an Application resource in `kubernetes/clusters/<cluster-name>/`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: my-app
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: git@github.com:psaawkel/fluodata-infrastructure.git
    targetRevision: HEAD
    path: kubernetes/overlays/production/my-app
  destination:
    server: https://kubernetes.default.svc
    namespace: my-app
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

4. Commit and push. ArgoCD picks it up automatically.

### Adding encrypted secrets to GitOps

1. Create a Kubernetes Secret manifest:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: my-app-credentials
  namespace: my-app
type: Opaque
stringData:
  DB_PASSWORD: supersecret
  API_KEY: my-api-key
```

2. Encrypt it with SOPS:

```bash
sops --encrypt --in-place kubernetes/overlays/production/my-app/secret.yaml
```

3. Create a KSOPS generator in the same directory:

```yaml
# secret-generator.yaml
apiVersion: viaduct.ai/v1
kind: ksops
metadata:
  name: my-app-secrets
  annotations:
    config.kubernetes.io/function: |
      exec:
        path: ksops
files:
  - secret.yaml
```

4. Reference the generator in `kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
generators:
  - secret-generator.yaml
resources:
  - deployment.yaml
  - service.yaml
```

5. Commit and push. ArgoCD decrypts the secret in-cluster using KSOPS + the age key.

### KSOPS — how in-cluster decryption works

ArgoCD's repo-server pod has KSOPS installed as a kustomize plugin (via init container).
The age private key is mounted from the `sops-age` Kubernetes Secret. When ArgoCD renders
manifests, kustomize calls KSOPS, which uses the age key to decrypt SOPS-encrypted files.

This means:
- Encrypted secrets are stored in git (safe)
- Only the cluster can decrypt them (age key is in-cluster)
- ArgoCD handles decryption transparently during sync

## Multi-environment strategy

Each environment gets:
- An Ansible environment folder (`environments/<name>/config.yml`)
- A Kubernetes cluster folder (`kubernetes/clusters/<name>/`)
- A set of overlays (`kubernetes/overlays/<env-type>/`)

Multiple clusters can share the same overlay (e.g., two production clusters both use
`overlays/production/`), or each can have its own overlay for different configurations.

### Adding a new environment

1. Copy an example environment:
   ```bash
   cp -r environments/vps-example environments/vps-newenv
   vim environments/vps-newenv/config.yml   # Fill in values
   sops --encrypt --in-place environments/vps-newenv/config.yml
   ```

2. Create the cluster folder:
   ```bash
   cp -r kubernetes/clusters/vps-example kubernetes/clusters/vps-newenv
   # Edit apps.yaml — update repoURL and path
   ```

3. Deploy:
   ```bash
   cd ansible
   ansible-playbook vps-deploy.yml -e env=../environments/vps-newenv
   ```

## What Ansible manages vs what ArgoCD manages

| Component | Managed by | Why |
|---|---|---|
| VM/VPS lifecycle | Ansible | Requires host-level access |
| Talos OS | Ansible | Machine-level config |
| Cilium CNI | Ansible (initial install) | Cluster needs CNI before ArgoCD can run |
| kubelet-cert-approver | Ansible (initial install) | Needed before ArgoCD pods can start properly |
| ArgoCD itself | Ansible (initial install) | Bootstrap — after that ArgoCD can self-manage |
| Application workloads | ArgoCD | GitOps — push to git, auto-synced |
| Kubernetes Secrets | ArgoCD + KSOPS | Encrypted in git, decrypted in-cluster |
| Ingress, cert-manager, etc. | ArgoCD | Standard Kubernetes components |

Future migration: Cilium and cert-approver can be moved to ArgoCD management once the
initial bootstrap pattern is proven. Ansible would only install them the first time,
then ArgoCD takes over for upgrades and config changes.

## Backup and recovery

### What to back up

1. **Age private key** (`~/.config/sops/age/keys.txt`) — without this, encrypted files
   cannot be decrypted. Store in a password manager or secure offline storage.

2. **Git repository** — contains everything else. Push to remote regularly.

### Recovering on a new machine

1. Clone the repo
2. Place the age private key at `~/.config/sops/age/keys.txt`
3. Install tools: `ansible`, `talosctl`, `kubectl`, `helm`, `sops`, `age`
4. Run the deploy playbook — everything is reconstructed from config

### Rotating the age key

If the age key is compromised:

1. Generate a new key: `age-keygen -o ~/.config/sops/age/keys.txt`
2. Update the public key in `.sops.yaml`
3. Re-encrypt all files:
   ```bash
   find environments -name config.yml -exec sops updatekeys {} \;
   find kubernetes -name '*secret*' -exec sops updatekeys {} \;
   ```
4. Update the in-cluster `sops-age` Secret:
   ```bash
   cd ansible
   ansible-playbook vps-argocd.yml -e env=../environments/vps-ovh-test1
   ```
5. Commit and push
