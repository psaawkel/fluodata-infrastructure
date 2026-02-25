# fluodata-infrastructure

Fully declarative, GitOps-managed Kubernetes platform for the FluoData/FluoCare IoT monitoring application. Runs on Proxmox + Talos Linux + Kubernetes with Argo CD managing all cluster state after bootstrap.

## Architecture

```
Proxmox VE (hypervisor)
  └── Talos Linux VMs (immutable Kubernetes OS)
       └── Kubernetes cluster
            ├── Cilium (CNI + L2 LoadBalancer + Hubble)
            ├── Longhorn (distributed storage)
            ├── Argo CD (GitOps controller)
            ├── kubelet-csr-approver (auto-approves Talos CSRs)
            ├── Ingress NGINX + cert-manager (TLS)
            ├── VictoriaMetrics + Grafana (monitoring)
            ├── Loki + Alloy (logging)
            ├── CloudNativePG (PostgreSQL operator)
            ├── RabbitMQ (message broker + MQTT)
            └── ScyllaDB (time-series storage)
```

## Repository Structure

```
├── infra-proxmox/              # Imperative bootstrap (Terraform)
│   ├── terraform/              # VM provisioning, Talos config, Argo CD install
│   │   ├── providers.tf
│   │   ├── variables.tf
│   │   ├── locals.tf
│   │   ├── vms.tf             # Proxmox VM resources
│   │   ├── talos.tf           # Talos machine config + Cilium inline
│   │   ├── argocd.tf          # Argo CD Helm + root Application + SOPS
│   │   ├── outputs.tf
│   │   └── terraform.tfvars.example
│   └── talos/patches/          # Talos machine config patches
│       ├── common.yaml
│       ├── controlplane.yaml
│       └── worker.yaml
│
├── cluster-gitops/             # Declarative GitOps (Argo CD manages)
│   ├── bootstrap/              # Root App-of-Apps entry point
│   │   └── kustomization.yaml
│   ├── projects/               # Argo CD AppProjects
│   │   ├── infrastructure.yaml
│   │   └── apps.yaml
│   ├── infrastructure/         # Platform components
│   │   ├── namespaces/         # Privileged namespace definitions
│   │   ├── network-policies/   # Default-deny + allow-list policies
│   │   ├── cilium/             # CNI + L2 announcements + IP pools
│   │   ├── csr-approver/       # Auto-approves kubelet-serving CSRs
│   │   ├── longhorn/           # Distributed storage
│   │   ├── ingress-nginx/      # Ingress controller
│   │   ├── cert-manager/       # TLS certificates + Let's Encrypt
│   │   └── monitoring/         # VictoriaMetrics, Loki, Alloy
│   └── apps/                   # Application components
│       ├── secrets/            # SOPS-encrypted secrets (KSOPS)
│       ├── postgresql/         # CloudNativePG operator + cluster
│       ├── rabbitmq/           # RabbitMQ operator + cluster + MQTT
│       └── scylladb/           # ScyllaDB operator + cluster
│
├── REQUIREMENTS.md             # Full project specification
├── EXPERIENCE.md               # Lessons learned from deployment
└── .sops.yaml                  # SOPS encryption config
```

## Prerequisites

- [Terraform](https://www.terraform.io/) >= 1.5
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [talosctl](https://www.talos.dev/latest/talos-guides/install/talosctl/)
- [age](https://github.com/FiloSottile/age) (for SOPS secret encryption)
- [sops](https://github.com/getsops/sops) >= 3.8
- Proxmox VE host with API token configured

## Quick Start

### 1. Generate age keypair for SOPS

```bash
# Generate keypair
age-keygen -o age.key

# Note the public key from the output (starts with age1...)
# Add it to .sops.yaml
```

### 2. Configure Terraform

```bash
cd infra-proxmox/terraform
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your values:
#   - Proxmox API connection
#   - Git repo URL
#   - age key file path
#   - Node IPs and MACs
```

### 3. Configure DHCP

Talos VMs don't send DHCP hostnames. Set up MAC-based DHCP reservations on your router/dnsmasq for the MAC addresses defined in `terraform.tfvars`.

### 4. Deploy

```bash
cd infra-proxmox/terraform
terraform init
terraform plan
terraform apply
```

This will:

1. Create Proxmox VMs with Talos Linux
2. Generate and apply Talos machine configs (with Cilium as inline CNI)
3. Bootstrap the Kubernetes cluster
4. Approve kubelet-serving CSRs (initial batch)
5. Create privileged namespaces
6. Create the SOPS age key secret
7. Install Argo CD via Helm (with KSOPS plugin)
8. Create the root Application pointing to `cluster-gitops/bootstrap/`

Argo CD then takes over and deploys everything else via GitOps, including the `kubelet-csr-approver` which handles ongoing CSR approvals automatically.

### 5. Access the cluster

```bash
# kubeconfig is written to infra-proxmox/terraform/kubeconfig
export KUBECONFIG=$(pwd)/infra-proxmox/terraform/kubeconfig

# Get Argo CD initial admin password
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d

# Port-forward to Argo CD UI
kubectl port-forward svc/argocd-server -n argocd 8080:443
# Open https://localhost:8080
```

## Secrets Management (SOPS + age + KSOPS)

Secrets are encrypted with SOPS using age keys and stored in Git. Argo CD decrypts them at sync time using the KSOPS kustomize plugin.

### Encrypting a new secret

```bash
# 1. Create cleartext secret YAML
cat > /tmp/my-secret.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: my-secret
  namespace: fluodata
type: Opaque
stringData:
  key: value
EOF

# 2. Encrypt with SOPS (uses .sops.yaml config for age public key)
sops --encrypt /tmp/my-secret.yaml > cluster-gitops/apps/secrets/my-secret.sops.yaml

# 3. Clean up cleartext
rm /tmp/my-secret.yaml

# 4. Add to ksops-generator.yaml files list
# 5. Commit and push — Argo CD decrypts automatically
```

### Editing an encrypted secret

```bash
# SOPS opens the file in your $EDITOR, decrypted
sops cluster-gitops/apps/secrets/pg-credentials.sops.yaml
```

### Initial setup for PostgreSQL

Before first deployment, encrypt the PostgreSQL credentials:

```bash
# Edit the template with your actual password
sops cluster-gitops/apps/secrets/pg-credentials.sops.yaml
# This will encrypt the file in-place using the age key from .sops.yaml
```

## Sync Wave Order

Argo CD deploys components in this order via sync wave annotations:

| Wave | Components                                                                     |
| ---- | ------------------------------------------------------------------------------ |
| -3   | Namespaces (PodSecurity labels), NetworkPolicies                               |
| -2   | Cilium (CNI takeover), kubelet-csr-approver                                    |
| -1   | Cilium config (IP pools), Longhorn (storage)                                   |
| 0    | Ingress NGINX, cert-manager, VictoriaMetrics, Loki, Alloy                      |
| 1    | cert-manager ClusterIssuers, Operators (CNPG, RabbitMQ, ScyllaDB), app secrets |
| 2    | Database/broker instances (PostgreSQL, RabbitMQ, ScyllaDB clusters)            |

## Cluster Topology

### Phase 1 -- Local Laptop

| Node      | vCPU | RAM   | Boot  | Longhorn |
| --------- | ---- | ----- | ----- | -------- |
| CP        | 2    | 8 GB  | 20 GB | -        |
| Worker x2 | 4    | 12 GB | 20 GB | 80 GB    |

Total: 10 vCPU, 32 GB RAM

### Phase 2 -- Single OVH Dedicated

Same topology, 1-2 workers. Longhorn replicas = 1.

### Phase 3 -- Multi-Host HA

3 CPs + workers across physical hosts. Longhorn replicas = failure domains. Requires WireGuard for inter-host communication.

## NetworkPolicies

All namespaces implement default-deny ingress with explicit allow rules:

- **Intra-namespace**: Pods within the same namespace can communicate
- **Ingress controller**: ingress-nginx can reach app pods
- **Monitoring**: VMAgent can scrape metrics from all namespaces
- **MQTT**: External traffic allowed to RabbitMQ MQTT port (1883)
- **Logging**: Grafana (monitoring) can query Loki (logging)

## Key Design Decisions

1. **Cilium via Talos inline manifests** -- CNI must exist before Argo CD pods schedule (chicken-and-egg). Argo CD takes over Cilium management afterward. Version must match between `talos.tf` and `cilium/application.yaml`.
2. **Cilium L2 replaces MetalLB** -- `CiliumLoadBalancerIPPool` + `CiliumL2AnnouncementPolicy` handle LoadBalancer IPs natively.
3. **SOPS + age + KSOPS** -- Simpler than SealedSecrets (no in-cluster controller needed for encryption). KSOPS runs as a kustomize exec plugin in Argo CD's repo-server.
4. **VictoriaMetrics over Prometheus** -- Lower resource usage, compatible with PromQL and ServiceMonitor CRDs.
5. **Grafana Alloy over Promtail** -- Promtail is in maintenance mode; Alloy is its actively-developed successor.
6. **kubelet-csr-approver** -- Talos generates kubelet-serving CSRs that K8s won't auto-approve. Without this, `kubectl logs/exec` and Longhorn break when certs rotate.
7. **ScyllaDB developerMode** -- Required on Talos (immutable OS cannot satisfy kernel tuning).

## Important Notes

- **DHCP**: Talos doesn't send hostnames -- use MAC-based DHCP reservations
- **PodSecurity**: K8s 1.32 enforces PodSecurity; namespaces need `privileged` labels before deploying workloads
- **Talos extensions**: `iscsi-tools` + `util-linux-tools` must be baked into the factory image URL
- **Monitoring scrapers**: `kubeControllerManager`, `kubeScheduler`, `kubeProxy`, `kubeEtcd` disabled (Talos doesn't expose them)
- **Cilium version coupling**: The version in `infra-proxmox/terraform/variables.tf` (inline manifests) must match `cluster-gitops/infrastructure/cilium/application.yaml` (Argo CD)

See [EXPERIENCE.md](EXPERIENCE.md) for comprehensive deployment lessons.

## TODO

- [x] Replace `YOUR_ORG` in all `repoURL` fields with actual GitHub org
- [x] Replace `CHANGEME@example.com` in cert-manager ClusterIssuers with actual email
- [x] Encrypt `pg-credentials.sops.yaml` with actual password
- [x] Update `.sops.yaml` with actual age public key
- [ ] WireGuard host-level configuration (Phase 3)
- [ ] Validate Helm chart versions against latest stable releases
