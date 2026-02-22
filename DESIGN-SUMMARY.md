# Talos-on-Proxmox GitOps Platform - Design Summary

## Scope

- One-command Ansible deployment of a Talos Kubernetes cluster on Proxmox.
- Three layers:
  - Layer 1: VMs + Talos bootstrap + Cilium.
  - Layer 2: ArgoCD GitOps platform.
  - Layer 3: Application CI/CD + DB claims.
- Initial target: single Proxmox node; scale to 3+ nodes later (no Proxmox HA).
- Network: vmbr1 with 10.10.0.0/24, Talos API VIP 10.10.0.100.
- VMs are created from ISO, not from templates.
- WireGuard mesh between Proxmox hosts (manual).

## Pinned Versions

- Talos: v1.12.4
- Kubernetes: v1.35.1
- Cilium: v1.19.1
- Argo CD: v3.3.2
- Longhorn: v1.11.0 (with longhorn-manager and longhorn-instance-manager v1.11.0-hotfix-1)
- Traefik Helm: v39.0.2 (Traefik v3.6.8)
- VictoriaMetrics k8s-stack: 0.71.1 (VM v1.136.0)
- Grafana: v12.2.0
- Loki: v6.26.0
- cert-manager: v1.19.3
- CloudNativePG: v1.28.1
- Scylla Operator: v1.20.0
- RabbitMQ Cluster Operator: v2.19.1
- kube-vip: v1.0.4
- Docker Registry chart: twuni/docker-registry v3.0.0

## Layer 1 - Proxmox to Talos (Ansible)

- Ensure vmbr1 and dnsmasq DHCP with MAC-based leases.
- Create VMs from Talos ISO; attach disks on local-lvm.
- Talos configuration:
  - cluster.network.cni.name: none
  - kube-vip static pod for VIP 10.10.0.100
  - No hostname patch (DHCP handles names)
- Bootstrap control plane, fetch kubeconfig.
- Install Cilium with Helm from Proxmox host.

## Layer 2 - GitOps Platform (ArgoCD Root App)

Order to avoid CRD/PodSecurity issues:

1) Namespaces + PodSecurity labels
2) cert-manager (OVH DNS-01)
3) Longhorn
4) VictoriaMetrics + Grafana
5) Loki + Alloy
6) Traefik (HTTP + TCP entrypoints)
7) CloudNativePG
8) Scylla Operator
9) RabbitMQ Operator
10) Docker Registry
11) Baseline NetworkPolicies

## Layer 3 - Apps

- App-of-apps per environment (cluster-gitops/dev, cluster-gitops/prod).
- Java/Spring app with DB claims.
- Uses in-cluster registry between build and deploy.

## cert-manager DNS-01 (OVH)

- ClusterIssuer uses OVH DNS-01 for wildcard certs.
- OVH API credentials stored as a Secret in cert-manager namespace.
- Traefik consumes cert-manager-issued certs for HTTP and TCP routes.

## Repository Layout

```
/infra/ansible/
  site.yml
  destroy.yml
  inventory/
  roles/
    proxmox_vms/
    talos_cluster/
    cilium/
    argocd_bootstrap/

/cluster-gitops/
  /dev/...
  /prod/...

/apps/
  /dev/...
  /prod/...
```
