1. Objective
Build a fully declarative, GitOps-managed Kubernetes platform that:
Runs initially on Proxmox (local laptop VM).
Migrates later to OVH dedicated servers.
Supports horizontal scaling (additional physical hosts).
Avoids SaaS dependencies.
Exposes only required public ports.
Uses Infrastructure as Code (Terraform + GitOps).
Minimizes imperative scripting.

2. Repository Structure
- folder: infra-proxmox
Responsible for:
Proxmox VM provisioning (Terraform).
Talos configuration generation and application.
Kubernetes bootstrap.
Argo CD bootstrap installation.
WireGuard host configuration (if automated).
Scope:
VM lifecycle.
Talos lifecycle.
Initial cluster bootstrap.

- folder: cluster-gitops
Managed by Argo CD.
Responsible for:
CNI installation.
Storage installation.
Monitoring stack.
Ingress.
Network policies.
Storage classes.
Operators.
Applications.
Secrets management.
Root App pattern required.

3. Core Stack
Virtualization
Proxmox VE
OS
Talos Linux
Orchestration
Kubernetes
GitOps
Argo CD
CNI
Cilium
Storage
Longhorn
Monitoring
VictoriaMetrics
Grafana
Grafana Loki
Database Operator
CloudNativePG
ScyllaOperator
RabbitMq
VPN
WireGuard (host-level, not Kubernetes-level)

4. Networking Requirements
No public SSH, No public Proxmox UI. (on production phase, on test phase it's ok)
No public Kubernetes API.
All management access via WireGuard.
Public ports allowed:
80
443
1883
8883
Mail ports (Postfix)
Ingress controller required.
TLS via cert-manager.
Let’s Encrypt integration.

5. Cluster Topology
Phase 1 – Local (Laptop)
1 Control Plane VM.
2 Worker VMs.
Longhorn replica = 1.
Phase 2 – Single Dedicated
1 Control Plane.
1–2 Workers.
Longhorn replica = 1.
Phase 3 – Multi-Dedicated HA
3 Control Planes.
≥1 Worker per physical host.
Longhorn replica = number of physical failure domains.
Topology-aware scheduling required.

6. Security Requirements

Kubernetes NetworkPolicies enabled.
Secrets managed via SOPS or SealedSecrets.
etcd snapshots enabled.
Longhorn backups configurable.
No NodePort public exposure.

7. Infrastructure as Code

Terraform must:
Create VMs.
Apply Talos configs.
Bootstrap cluster.
Install Argo CD.

No:
Manual kubectl workflows.
Bash-heavy automation.
Manual post-install steps.
All cluster state must be declarative and Git-managed.

8. Migration Requirements
Must support:
Moving from local Proxmox VM to dedicated server.
Adding new physical hosts.
Scaling control plane (1 → 3).
Increasing Longhorn replicas.
Draining nodes without rebuild.
No cluster reinstallation required for scaling.

9. Non-Goals
No Proxmox clustering across WAN.
No Ceph.
No service mesh initially.
No SaaS VPN solutions.
No imperative infrastructure management.