# FluoData Infrastructure - Talos on Proxmox IaC Design

**Version:** 1.1 (Simplified per feedback)  
**Status:** Draft for Discussion  
**Date:** 2026-02-19

---

## 1. Core Goal

**One command to deploy a bare Talos cluster on Proxmox:**
```bash
terraform -chdir=infra-proxmox apply
```

---

## 2. What's Removed (Not Needed)

| Removed | Reason |
|---------|--------|
| **MetalLB** | Traefik can use hostNetwork directly |
| **cert-manager** | Traefik has built-in Let's Encrypt (ACME) |
| **Ansible** | Replaced with pure Terraform |
| **Multiple layers** | Just Terraform + ArgoCD |

---

## 3. Simplified Architecture

```
┌─────────────────────────────────────────────┐
│         terraform apply                     │
│    (infra-proxmox/)                        │
└─────────────────────────────────────────────┘
        │
        ├── Proxmox VMs (Telmate provider)
        ├── Talos configs + bootstrap
        └── ArgoCD install (Helm)
                │
                ▼
        ArgoCD manages cluster apps
        (Cilium, Longhorn, Traefik, etc.)
```

---

## 4. Repository Structure

```
fluodata-infrastructure/
├── infra-proxmox/              # ⭐ One-command deploy
│   ├── main.tf                 # All-in-one or split modules
│   ├── variables.tf            # proxmox_url, token, node, etc.
│   ├── terraform.tfvars        # cluster config
│   └── ...
│
├── cluster-gitops/             # ArgoCD apps
│   ├── app-of-apps.yaml
│   ├── cilium.yaml
│   ├── longhorn.yaml
│   ├── traefik.yaml            # Includes TLS
│   ├── victoria-metrics.yaml
│   ├── loki.yaml
│   └── database/               # cloudnativepg, rabbitmq
│
└── docs/
    └── DESIGN.md
```

---

## 5. Terraform Scope

### 5.1 What Terraform Does

1. **Create VMs** on Proxmox
   - Control plane node(s)
   - Worker node(s)
   - Network config (MAC addresses for DHCP)

2. **Generate Talos configs**
   - Cluster endpoint, secrets
   - Kubelet cert approver (EXPERIENCE.md lesson)
   - Cilium as inline manifest (EXPERIENCE.md lesson)

3. **Bootstrap cluster**
   - Wait for nodes to boot
   - Apply configs
   - Bootstrap Talos

4. **Install ArgoCD**
   - Helm chart via `helm_release`
   - Create initial App-of-Apps Application

### 5.2 What Terraform Does NOT Do

- **Any Kubernetes workloads** - that's ArgoCD's job
- **WireGuard** - manual or separate Terraform state
- **Proxmox host setup** - assumed pre-configured

---

## 6. GitOps (ArgoCD) Scope

Only what's needed:

| App | Purpose |
|-----|---------|
| **Cilium** | CNI (installed via Talos inline manifest first) |
| **Longhorn** | Storage |
| **Traefik** | Ingress + TLS (ACME/Let's Encrypt built-in) |
| **VictoriaMetrics** | Monitoring |
| **Loki** | Logs |
| **CloudNativePG** | PostgreSQL |
| **RabbitMQ** | MQTT broker |

---

## 7. Network

- **Internal network**: 10.20.0.0/24 (Proxmox vmbr1)
- **Public ports** (via port forwarding):
  - 80, 443 → Traefik
  - 1883, 8883 → RabbitMQ (MQTT)
- **Management**: WireGuard VPN (not managed by this repo)

---

## 8. Deployment Flow

```bash
# 1. Set env vars (Proxmox token)
export PROXMOX_API_URL="https://proxmox:8006/api2/json"
export PROXMOX_API_TOKEN_ID="terraform@pam!deployer"
export PROXMOX_API_TOKEN_SECRET="uuid..."

# 2. One command
cd infra-proxmox
terraform init
terraform apply

# 3. Get kubeconfig (Terraform output or from Talos)
export KUBECONFIG=$(terraform output -raw kubeconfig)

# 4. Access ArgoCD
kubectl port-forward svc/argocd-server -n argocd 8080:443
# Password: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
```

---

## 9. Key Lessons from EXPERIENCE.md Integrated

1. **Cilium embedded in Talos** - Not applied via ArgoCD (chicken-and-egg)
2. **Kubelet cert approver** - Auto-approves serving certs
3. **PodSecurity labels** - For Longhorn, monitoring namespaces
4. **Factory image** - For Talos extensions (iscsi-tools, util-linux-tools)
5. **VictoriaMetrics** - Lower resource than Prometheus

---

## 10. Open Questions

1. **Database**: Need all of CloudNativePG + ScyllaDB + RabbitMQ? Or simplify?
2. **Secrets**: Same repo with SOPS, or separate?
3. **Terraform state**: Local OK for laptop, remote for production?
4. **CI/CD**: Manual `terraform apply` or GitHub Actions?

---

## 11. Next Steps

Please tell me:
1. Is this simpler approach acceptable?
2. What components from section 6 do you actually need?
3. Any other simplifications?

Then I'll implement the actual code.
