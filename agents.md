# AI Agent Reference — fluodata-infrastructure

This document is the single source of truth for AI agents operating on this repository.
It covers repository architecture, operational workflows, and hard-won deployment lessons.

---

## Repository Overview

This repository manages a Kubernetes platform for the FluoData/FluoCare IoT monitoring
application. It has two layers:

1. **Ansible** — provisions clusters (Talos Linux on OVH VPS or Proxmox VMs), installs
   Cilium CNI, and bootstraps ArgoCD. Handles all day-0 tasks requiring direct machine access.

2. **ArgoCD + GitOps** — manages all application workloads and infrastructure components
   declaratively after cluster bootstrap. Syncs from this git repository continuously.

### Live cluster

- **`vps-ovh-test1`** — 3-node OVH VPS cluster, all nodes are combined controlplane+worker.
  ArgoCD is running and managing the full stack.

---

## Directory Structure

```
fluodata-infrastructure/
├── ansible/
│   ├── vps-deploy-rescue.yml       # VPS step 1: write Talos to disk (rescue mode)
│   ├── vps-deploy.yml              # VPS step 2: bootstrap + Cilium + ArgoCD
│   ├── vps-argocd.yml              # ArgoCD-only install/upgrade
│   ├── proxmox-deploy.yml          # Proxmox: full deploy
│   ├── proxmox-destroy.yml
│   ├── vps-destroy.yml
│   ├── tasks/
│   │   ├── load-config.yml         # Resolve path, SOPS-decrypt + load config.yml
│   │   ├── validate-vps.yml        # Check VPS fields, add rescue hosts
│   │   └── validate-proxmox.yml    # Check Proxmox fields, add_host
│   └── roles/
│       ├── talos_generate/         # Generate secrets, patches, machine configs
│       ├── talos_bootstrap_vps/    # Apply configs, bootstrap, kubeconfig (VPS)
│       ├── talos_bootstrap_proxmox/# Apply configs, bootstrap, kubeconfig (Proxmox)
│       ├── talos_install/          # Write Talos image to disk (rescue mode)
│       ├── proxmox_vms/            # Create/start Proxmox VMs
│       ├── proxmox_dnsmasq/        # dnsmasq DHCP config
│       ├── proxmox_post_install/   # Fix boot order after Talos install
│       ├── cilium/                 # Helm install Cilium
│       ├── kubelet_cert_approver/  # Auto-approve kubelet serving cert CSRs
│       └── argocd/                 # Install ArgoCD + KSOPS, create root Application
│
├── environments/
│   ├── vps-example/config.yml      # Template — copy for new VPS env
│   └── proxmox-example/config.yml  # Template — copy for new Proxmox env
│   # Real envs gitignored (secrets + generated files). Exception:
│   # vps-ovh-test1/ is committed with config.yml SOPS-encrypted.
│
├── kubernetes/                     # GitOps manifests (ArgoCD watches this entire tree)
│   ├── base/argocd/                # ArgoCD Helm values; KSOPS init-container config
│   │   └── values.yaml             # Referenced by ansible/roles/argocd at install time
│   ├── base/<app>/                 # Shared Kustomize bases (mqtt, namespaces, wireguard, etc.)
│   ├── overlays/
│   │   └── vps-ovh-test1/          # Per-cluster Kustomize overlays
│   │       ├── dynhost-failover/
│   │       ├── postgresql/
│   │       └── scylladb/
│   └── clusters/
│       └── vps-ovh-test1/          # 17 Application CRs — ArgoCD watches this directory
│           ├── apps.yaml           # Root Application (self-referencing app-of-apps)
│           └── *.yaml              # One file per managed component
│
├── .sops.yaml                      # SOPS encryption rules (do not modify keys without re-encrypting)
└── .gitignore
```

### How Applications are structured

Each file in `kubernetes/clusters/vps-ovh-test1/` is an ArgoCD Application CR. Applications source from one of two places:

1. **This git repo** — points to `kubernetes/base/<app>` or `kubernetes/overlays/vps-ovh-test1/<app>` (Kustomize manifests)
2. **External Helm chart repo** — cert-manager, VictoriaMetrics, Traefik, Loki, Alloy, CNPG operator, Scylla operator, etc.

Live examples:
```
apps.yaml           → path: kubernetes/clusters/vps-ovh-test1     (self-referencing root)
namespaces.yaml     → path: kubernetes/base/namespaces
mqtt.yaml           → path: kubernetes/base/mqtt
postgresql.yaml     → path: kubernetes/overlays/vps-ovh-test1/postgresql
cert-manager.yaml   → repoURL: https://charts.jetstack.io          (Helm chart, no git path)
victoria-metrics.yaml → repoURL: https://victoriametrics.github.io/helm-charts/
traefik.yaml        → repoURL: https://traefik.github.io/charts
```

---

## What Ansible Manages vs What ArgoCD Manages

| Component | Managed by | Why |
|-----------|------------|-----|
| VM/VPS lifecycle | Ansible | Requires host-level access |
| Talos OS | Ansible | Machine-level config |
| Cilium CNI (initial install) | Ansible | Needed before ArgoCD pods can schedule |
| kubelet-cert-approver (initial) | Ansible | Needed before ArgoCD pods start properly |
| ArgoCD (initial install) | Ansible | Bootstrap — cannot install itself |
| Application workloads | ArgoCD | GitOps — push to git, auto-synced |
| Kubernetes Secrets | ArgoCD + KSOPS | Encrypted in git, decrypted in-cluster |
| Ingress, cert-manager, monitoring | ArgoCD | Standard Kubernetes components |
| Cilium upgrades + config | ArgoCD | After initial bootstrap, ArgoCD takes over |

---

## GitOps Workflow

### Critical: what ArgoCD watches

`ansible/roles/argocd/templates/root-app.yaml.j2` hardcodes:
```
path: kubernetes/clusters/{{ _argocd_cluster_dir }}
```

For `vps-ovh-test1`, ArgoCD watches `kubernetes/clusters/vps-ovh-test1/`. Every `.yaml`
file there is applied as an ArgoCD Application. **Do not delete or rename this directory.**

`ansible/roles/argocd/tasks/main.yml` also references `kubernetes/base/argocd/values.yaml`
at install time. **Do not delete or move that file.**

### How the app-of-apps pattern works

The root Application (`apps.yaml`) is self-referencing — it watches
`kubernetes/clusters/vps-ovh-test1/`, which contains itself plus all other Application CRs.
ArgoCD applies every `.yaml` in that directory as an Application object.

Each Application then independently syncs its own source (either a git path or a Helm chart
repo) to the cluster.

```
kubernetes/clusters/vps-ovh-test1/
  apps.yaml             ← root; watches this same directory
  namespaces.yaml       ← Application → kubernetes/base/namespaces (Kustomize, this repo)
  mqtt.yaml             ← Application → kubernetes/base/mqtt (Kustomize, this repo)
  postgresql.yaml       ← Application → kubernetes/overlays/vps-ovh-test1/postgresql (Kustomize)
  cert-manager.yaml     ← Application → https://charts.jetstack.io (Helm chart)
  victoria-metrics.yaml ← Application → https://victoriametrics.github.io/helm-charts/
  traefik.yaml          ← Application → https://traefik.github.io/charts
  ...
```

### Adding a new application (git-backed Kustomize)

1. Add manifests under `kubernetes/base/<app-name>/` (shared) or
   `kubernetes/overlays/vps-ovh-test1/<app-name>/` (cluster-specific):

```
kubernetes/base/my-app/
  kustomization.yaml
  deployment.yaml
  service.yaml
```

2. Add an ArgoCD Application CR to `kubernetes/clusters/vps-ovh-test1/my-app.yaml`:

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
    path: kubernetes/base/my-app
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

3. Commit and push. ArgoCD picks it up automatically (no restart needed).

### Adding a new application (Helm chart)

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: my-chart
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://charts.example.com
    chart: my-chart
    targetRevision: "1.2.3"
    helm:
      valuesObject:
        replicaCount: 1
  destination:
    server: https://kubernetes.default.svc
    namespace: my-chart
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

---

## Secret Management (SOPS + age + KSOPS)

### Overview

- **age** — asymmetric encryption tool. Public key in `.sops.yaml` (safe to commit).
  Private key at `~/.config/sops/age/keys.txt` (never commit; back up to password manager).
- **SOPS** — encrypts specific fields in YAML files, leaving structure readable.
- **KSOPS** — kustomize plugin that calls SOPS during ArgoCD manifest rendering.
  Installed as an init container in ArgoCD's repo-server pod (configured in
  `kubernetes/base/argocd/values.yaml`). Uses the age key from the `sops-age` K8s Secret.

### What gets encrypted

| File pattern | Encrypted fields | Why |
|---|---|---|
| `environments/*/config.yml` | `rescue_ssh_pass`, `password`, `*_secret` | SSH passwords, API tokens |
| `kubernetes/**/*secret*.yaml` | `data`, `stringData` | Kubernetes Secret values |

### Setup on a new machine

```bash
mkdir -p ~/.config/sops/age
# Copy the age private key (from password manager or existing machine) to:
# ~/.config/sops/age/keys.txt
```

### Daily workflow

```bash
# Edit an encrypted file (decrypts → opens $EDITOR → re-encrypts)
sops environments/vps-ovh-test1/config.yml

# Encrypt a new file in-place
sops --encrypt --in-place environments/vps-newenv/config.yml

# View without modifying
sops --decrypt environments/vps-ovh-test1/config.yml
```

### Adding encrypted Kubernetes secrets for ArgoCD

1. Create the Secret manifest:

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

2. Encrypt it:

```bash
sops --encrypt --in-place kubernetes/base/my-app/secret.yaml
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
```

5. Commit and push. ArgoCD decrypts in-cluster using KSOPS + the age key.

### Rotating the age key

```bash
# 1. Generate new key
age-keygen -o ~/.config/sops/age/keys.txt

# 2. Update public key in .sops.yaml

# 3. Re-encrypt all files
find environments -name config.yml -exec sops updatekeys {} \;
find kubernetes -name '*secret*' -exec sops updatekeys {} \;

# 4. Update the in-cluster sops-age Secret
cd ansible
ansible-playbook vps-argocd.yml -e env=../environments/vps-ovh-test1

# 5. Commit and push
```

### Ansible SOPS integration

`tasks/load-config.yml` automatically detects and decrypts SOPS-encrypted `config.yml`
files. Run playbooks normally — no extra flags needed:

```bash
ansible-playbook vps-deploy.yml -e env=../environments/vps-ovh-test1
# Works whether config.yml is encrypted or plaintext
```

The `sops` binary must be in PATH on the machine running Ansible.

---

## Backup and Recovery

### What to back up

1. **Age private key** (`~/.config/sops/age/keys.txt`) — without it, no encrypted file
   can be decrypted. Store in a password manager.
2. **Git repository** — contains everything else.
3. **Environment folders** (real envs) — contain `kubeconfig`, `talosconfig`, `secrets.yaml`.
   These are gitignored (except SOPS-encrypted ones). Sync to encrypted cloud storage.

### Recovering on a new machine

1. Clone the repo
2. Place age private key at `~/.config/sops/age/keys.txt`
3. Install: `ansible`, `talosctl`, `kubectl`, `helm`, `sops`, `age`
4. Run the deploy playbook — everything is reconstructed from config

---

## Deployment Lessons (Hard-Won)

### Talos Linux

- **Immutable OS** — no SSH, no shell, no package manager. All management via `talosctl`.
- **Extensions must be in factory image URL** — `machine.install.image` must be set to
  `factory.talos.dev/installer/<schematic_id>:<version>`. Without it, Talos installs
  to disk using the stock installer with no extensions.
- **`machine.install.extensions` is deprecated** in Talos 1.9.x+ — use factory image URL.
- **Factory image generator**: https://factory.talos.dev/
- **Current schematic includes**: `iscsi-tools`, `util-linux-tools`, `qemu-guest-agent`.
  `iscsi_tcp` and `dm_thin_pool` kernel modules are loaded via Talos machine config patches.
  These are Longhorn prerequisites kept loaded in anticipation of future use — Longhorn is
  not currently deployed (see storage decision below).
- **`guestAgent` is not a Talos field** — it's a Proxmox VM setting. Including it in Talos
  config patches causes `talosctl gen config` to fail with "unknown keys".

### Kubelet serving certificates

- Talos enables `rotate-server-certificates: true` by default.
- Kubernetes auto-approves only `kubernetes.io/kubelet-client` CSRs, NOT
  `kubernetes.io/kubelet-serving` CSRs.
- Without a CSR approver: `kubectl logs`, `kubectl exec`, `kubectl port-forward` all fail
  with TLS errors when certs rotate.
- **Fix**: deploy `kubelet-serving-cert-approver` (done by Ansible at bootstrap, then
  managed by ArgoCD). Note: image tag has no `v` prefix (e.g., `0.10.3` not `v0.10.3`).

### Cilium as CNI

- Set `cluster.network.cni.name: none` in Talos machine config to disable default CNI.
- Post-bootstrap Helm install is the correct approach. K8s API is reachable right after
  `talosctl bootstrap` even with nodes in `NotReady` state (no CNI yet).
- Nodes become `Ready` ~2 minutes after Cilium deploys.
- Do not use inline manifests (1600+ lines, hard to maintain).

### Virtual IP (Proxmox / VIP environments)

- `interface: eth0` does NOT work with Talos VIP. Talos maps `eth0` to the physical
  interface for address assignment, but the VIP operator looks for link `eth0` which
  never comes up as a physical link — VIP silently fails.
- **Fix**: use `deviceSelector: { physical: true }` instead.
- VIP only activates after etcd is healthy and the K8s API server is running.

### VPS rescue mode (OVH)

- The only viable Talos install path on OVH VPS — custom ISO boot is not supported.
- OVH rescue mode uses **password-based SSH**, not key-based. `rescue_ssh_pass` per-node.
- **Rebooting from rescue mode re-enters rescue** unless the boot mode is first switched
  to local/normal in the OVH Manager dashboard. This is why deploy is split into two
  separate playbooks with a manual step between them.

### OVH /32 point-to-point routing

- OVH VPS IPs are /32. The gateway is on a different subnet.
- Requires adding a direct host route to the gateway before setting the default route.
- Handled conditionally in the node patch template.

### Apply-config idempotency

- `talosctl apply-config --insecure` only works in maintenance mode (before bootstrap).
- Configured nodes require `--talosconfig` auth.
- Bootstrap roles auto-detect mode and use the appropriate method.

### talosconfig empty endpoints

- `talosctl gen config` produces a talosconfig with `endpoints: []`.
- Fix: after generating, run `talosctl config endpoint <VIP_or_CP_IP>` and
  `talosctl config nodes <CP_IPs>`. Ansible does this automatically.

### DHCP and hostnames (Proxmox)

- Talos nocloud VMs do NOT send DHCP hostnames.
- Use MAC-based DHCP reservations in dnsmasq, not hostname-based.
- **Hostname conflict (Talos v1.12.4)**: when dnsmasq sends a hostname via DHCP,
  `talosctl apply-config` rejects configs containing `machine.network.hostname`.
  Omit hostname from config patches entirely.

### Proxmox boot order (CRITICAL)

- VMs must boot from ISO for initial Talos install, but after install the boot order
  must switch to disk-first and the ISO must be detached.
- If the ISO stays first and VMs reboot for any reason, Talos boots from ISO again
  and halts: `"Talos already installed to disk but booted from another media"`.
  The cluster will NOT come back up until boot order is fixed.
- Fix: `qm set <vmid> --boot order=scsi0 --ide2 none,media=cdrom` on each VM.
  Handled by the `proxmox_post_install` role.

### Proxmox LVM-thin disk format

- `qm set --scsi0 local-lvm:8G` fails — LVM-thin expects bare number, not `8G`.

### Disk sizing

- Minimum boot disk: 12 GB. 8 GB causes DiskPressure under full stack.
- Recommended: 20-25 GB. EPHEMERAL partition grows on reboot after disk resize.

---

## Kubernetes / Application Lessons

### PodSecurity (Kubernetes 1.32+)

Namespaces running privileged workloads must be labeled BEFORE deploying pods:

```yaml
pod-security.kubernetes.io/enforce: privileged
pod-security.kubernetes.io/audit: privileged
pod-security.kubernetes.io/warn: privileged
```

Affected: `monitoring`, `logging`, and any namespace with
`hostPath`, `privileged`, `hostNetwork`, or capabilities like `SYS_NICE`/`NET_ADMIN`.

### Monitoring stack (Talos compatibility)

These scrapers must be disabled — Talos doesn't expose their endpoints:

```yaml
kubeControllerManager:
  enabled: false
kubeScheduler:
  enabled: false
kubeProxy:
  enabled: false
kubeEtcd:
  enabled: false
```

Applies to both `kube-prometheus-stack` and `victoria-metrics-k8s-stack`.

### VictoriaMetrics

- Replaced kube-prometheus-stack for lower resource usage.
- Uses its own CRDs (VMSingle, VMAgent, VMAlert) with prometheus-operator CRD converter.
- VMSingle mode is appropriate up to ~5k devices.

### Loki

- SingleBinary mode with filesystem storage (`local-path` PVC) — no MinIO/S3 needed.
- `replication_factor: 1` required for single-replica.
- All non-SingleBinary component replicas must be set to 0 explicitly.
- Grafana Alloy (successor to Promtail) as DaemonSet — needs privileged namespace label.

### ServiceMonitor CRD ordering

- Charts that create ServiceMonitor resources (ingress-nginx, cert-manager) fail if
  Prometheus/VM CRDs aren't installed yet.
- Either deploy monitoring first (sync wave), or set `serviceMonitor.enabled: false`.

### Storage decision — why Longhorn is not deployed

All stateful workloads use `local-path` storage (node-local SSDs):

- **PostgreSQL (CNPG)** — 3-replica cluster; replication handled at the database layer
- **ScyllaDB** — clustered; replication handled at the database layer
- **RabbitMQ** — clustered; replication handled at the message broker layer
- **VictoriaMetrics, Loki** — monitoring data; node-local is acceptable

Deploying Longhorn on top of these would result in ~9x replication (3 app replicas × 3
Longhorn replicas), wasting disk and RAM (Longhorn idles at 1.2–2.2 GB RAM).

`iscsi_tcp` and `dm_thin_pool` kernel modules are pre-loaded in the Talos machine config,
and `iscsi-tools` + `util-linux-tools` are in the factory schematic, so Longhorn can be
added later without reprovisioning nodes if a non-self-replicating stateful workload appears.

### ScyllaDB on Talos

- `developerMode: true` is required — Talos cannot satisfy kernel tuning checks.
- `scylla_io_setup` requires minimum 10 GB free disk on data volume.

### CloudNativePG

- `spec.monitoring.enablePodMonitor` deprecated in newer versions — omit it.
- Right-sized for ~5k IoT devices: CPU 250m/1000m, RAM 512Mi/2Gi, 10Gi data + 2Gi WAL.

### RabbitMQ

- Duplicate port names in override cause pod startup failure.
- `mqtt.subscription_ttl` removed in RabbitMQ 3.13 — use `mqtt.max_session_expiry_interval_seconds`.
- Install operator via kubectl manifest (official method), not Helm.

---

## Resource Sizing (validated for ~5k IoT devices)

### VM sizing

| Node | vCPU | RAM | Boot disk |
|------|------|-----|-----------|
| CP / worker (VPS, combined) | 3 vCPU | 8 GB | 80 GB |

### Application sizing

| Component | CPU req/limit | RAM req/limit | Storage |
|-----------|--------------|--------------|---------|
| PostgreSQL | 250m/1000m | 512Mi/2Gi | 10Gi data + 2Gi WAL |
| ScyllaDB | 250m/1000m | 512Mi/1Gi | 20Gi |
| RabbitMQ | 200m/1000m | 512Mi/1Gi | 10Gi |
| VMSingle | 100m/500m | 512Mi/1Gi | 5Gi |
| Loki | 100m/500m | 256Mi/512Mi | 10Gi |

### Deployment timing

- Full VPS deploy (rescue → bootstrap → Cilium → ArgoCD): ~5 minutes
- Cilium install to all nodes Ready: ~2 minutes
- Versions in use: Talos v1.12.4, Kubernetes v1.35.0, Cilium v1.17.3
