# Experience Notes: Proxmox + Talos Linux + Kubernetes

Findings from building and testing a full Proxmox -> Talos -> K8s stack (Feb 2026).
These are hard-won lessons — every item below was discovered through actual deployment failures.

---

## Talos Linux

### Immutable OS constraints

- No SSH, no shell, no package manager. All management via `talosctl`.
- Cannot tune kernel parameters at runtime (sysctl, scheduler, etc.).
- Extensions must be baked into the factory image URL — `machine.install.extensions` is deprecated in Talos 1.9.x+.
- Required extensions for Longhorn: `iscsi-tools`, `util-linux-tools`.
- Factory image generator: https://factory.talos.dev/

### Disk partitioning

- Talos uses fixed partitions: STATE + EPHEMERAL.
- EPHEMERAL grows automatically on **reboot** after disk resize, NOT on the fly.
- Minimum boot disk: 12 GB comfortable, 8 GB causes DiskPressure under full stack.
- Recommended: 20-25 GB boot disk.

### Kubelet serving certificates

- Talos enables kubelet serving cert rotation.
- Kubernetes does NOT auto-approve `kubernetes.io/kubelet-serving` CSRs (only `kubernetes.io/kubelet-client`).
- Without approval: `kubectl logs`, `kubectl exec`, `kubectl port-forward` all fail with TLS errors. Longhorn driver-deployer also fails.
- Must approve CSRs after bootstrap and periodically when certs rotate.

### Cilium as CNI

- Talos default CNI is Flannel. To use Cilium, must disable default CNI in Talos machine config.
- Talos machine config: set `cluster.network.cni.name: none`.
- **Post-bootstrap Helm install works perfectly** (preferred over inline manifests):
  - After `talosctl bootstrap`, K8s API is reachable even though nodes are `NotReady` (no CNI yet).
  - `helm upgrade --install cilium` succeeds immediately post-bootstrap.
  - Nodes become `Ready` ~2 minutes after Cilium deploys.
  - Much simpler than the 1600-line inline manifest approach — clean, maintainable, upgradeable.
- Old approach (inline manifests) is NOT recommended — hard to maintain and upgrade.

### DHCP and networking

- Talos nocloud VMs do NOT send DHCP hostnames.
- dnsmasq hostname-based reservations fail silently — VMs get random IPs.
- Fix: assign deterministic MAC addresses to VMs and use MAC-based DHCP leases.
- **Hostname conflict (Talos v1.12.4)**: When dnsmasq sends a hostname via DHCP, `talosctl apply-config` rejects configs containing `machine.network.hostname`. Omit hostname from config patches entirely; let dnsmasq handle it.

### Virtual IP (VIP) for control plane

- Talos has built-in VIP support — no external load balancer needed.
- Config: `machine.network.interfaces[].vip.ip` on control plane nodes only.
- Talos handles leader election internally; VIP is assigned to one CP node at a time using gratuitous ARP.
- **CRITICAL: `interface: eth0` does NOT work with VIP**. Talos maps `eth0` to the physical interface (e.g., `ens18`) for address assignment, but the VIP operator looks for link `eth0` which never comes up as a physical link. VIP silently fails to activate.
- **Fix: Use `deviceSelector: { physical: true }` instead of `interface: eth0`**. This resolves to the actual physical interface name and the VIP operator gets the correct link.
- VIP address should be on the same subnet as node IPs but outside DHCP range and outside node IP range.
- VIP only activates after etcd is healthy and the K8s API server is running.
- `guestAgent` is NOT a valid Talos `machine.features` field — it's a Proxmox VM setting. Including it in Talos config patches causes `talosctl gen config` to fail with "unknown keys".

### Factory installer image for extensions (CRITICAL)

- The factory ISO boots with extensions from the schematic, but when Talos installs to disk, `machine.install.image` defaults to stock `ghcr.io/siderolabs/installer` which has NO extensions.
- **Fix**: Set `machine.install.image: factory.talos.dev/installer/<schematic_id>:<version>` in per-node config patches.
- **Verified working**: All 3 nodes show extensions loaded after deploy with factory installer image:
  - `iscsi-tools` v0.2.0, `util-linux-tools` 2.41.2, `qemu-guest-agent` 10.2.0
  - `qm agent <vmid> ping` succeeds on all 3 VMs (guest agent communicating with Proxmox).

### Deprecated fields (Talos 1.9.2+)

- `machine.install.extensions` — use factory image URL instead.

---

## Kubernetes 1.32

### PodSecurity enforcement

- K8s 1.32 enforces PodSecurity standards by default.
- Namespaces running workloads needing `hostPath`, `privileged`, `hostNetwork`, or capabilities like `SYS_NICE`/`NET_ADMIN` must be labeled BEFORE deploying pods:
  ```
  pod-security.kubernetes.io/enforce=privileged
  pod-security.kubernetes.io/audit=privileged
  pod-security.kubernetes.io/warn=privileged
  ```
- Affected namespaces: `longhorn-system`, `monitoring`, `logging`, app namespace (for ScyllaDB SYS_NICE).

### ServiceMonitor CRD ordering

- Charts that create ServiceMonitor resources (ingress-nginx, cert-manager) fail if Prometheus/VM CRDs aren't installed yet.
- Either deploy monitoring first, or set `serviceMonitor.enabled: false` in those charts.

---

## Longhorn on Talos

- Requires `csi.kubeletRootDir: /var/lib/kubelet` (Talos kubelet runs as container, auto-detection fails).
- Requires Talos extensions: `iscsi-tools` + `util-linux-tools`.
- Heaviest infrastructure component: 1.2-2.2 GB RAM at idle.
- Longhorn online PVC expansion works (tested: 512Mi -> 2Gi while pod running).

---

## ScyllaDB on Talos

- `scylla_io_setup` requires minimum 10 GB free disk on data volume.
- Production mode enforces kernel tuning checks (swappiness, zone_reclaim, nomerges, I/O scheduler) — Talos cannot satisfy these.
- **`developerMode: true` is required on Talos** unless using ScyllaDB node-tuning DaemonSet.
- Bug: setting `developerMode: true` in ScyllaCluster spec may NOT propagate to StatefulSet if operator can't reconcile (chicken-and-egg with unhealthy pod). On fresh deploy with developerMode set before first pod starts, it works.

---

## CloudNativePG (PostgreSQL)

- `spec.monitoring.enablePodMonitor` deprecated in newer versions — omit it.
- WAL parameters (`max_wal_size`) must fit within WAL volume size.
- Right-sized for ~5k IoT devices: CPU 250m/1000m, RAM 512Mi/2Gi, 10Gi data + 2Gi WAL.

---

## RabbitMQ

- Duplicate port names in override cause pod startup failure (e.g., `web-stomp` auto-exposed by plugin).
- `mqtt.subscription_ttl` removed in RabbitMQ 3.13 — use `mqtt.max_session_expiry_interval_seconds`.
- Install operator via kubectl manifest (official method), not Helm.

---

## Monitoring Stack

### Talos compatibility (applies to both kube-prometheus-stack AND victoria-metrics-k8s-stack)

These scrapers must be disabled — Talos doesn't expose their metrics endpoints:

- `kubeControllerManager.enabled: false`
- `kubeScheduler.enabled: false`
- `kubeProxy.enabled: false`
- `kubeEtcd.enabled: false`

### VictoriaMetrics vs Prometheus

- Replaced kube-prometheus-stack with victoria-metrics-k8s-stack for lower resource usage.
- VM stack uses its own CRDs (VMSingle, VMAgent, VMAlert) but includes prometheus-operator CRD converter.
- Grafana service name: `victoria-metrics-stack-grafana`.
- VMSingle mode (single-server) is appropriate up to ~5k devices. VMCluster for larger.

### Loki for log aggregation

- SingleBinary mode with filesystem storage (Longhorn PVC) — no MinIO/S3 needed at small scale.
- All non-SingleBinary component replicas must be set to 0 explicitly.
- `replication_factor: 1` required for single-replica filesystem.
- Grafana Alloy (successor to Promtail) as DaemonSet needs privileged namespace label.
- Promtail is in maintenance mode — use Grafana Alloy instead.
- Retention enforced by compactor — `compactor.retention_enabled: true` + `limits_config.retention_period`.

---

## Proxmox

### LVM-thin disk format

- `qm set --scsi0 local-lvm:8G` fails — LVM-thin expects bare number (e.g., `8`), not `8G`.
- LVM-thin is thin-provisioned: 650 GB virtual may only use 25-30 GB physically.

### Networking

- Must create internal bridge (vmbr1) with NAT for VM network.
- Port forwarding via iptables rules on Proxmox host.
- dnsmasq for DHCP on internal bridge.

### Stale lock files

- If Terraform/Ansible/API tasks die mid-operation, lock files at `/var/lock/qemu-server/lock-<vmid>.conf` must be manually removed before VMs can be destroyed or modified.

### Boot order: ISO vs disk (CRITICAL)

- VMs must boot from ISO (`order=ide2;scsi0`) for initial Talos install, but **after Talos installs to disk**, boot order must switch to disk-first (`order=scsi0`) and the ISO should be detached.
- If the ISO stays first in boot order and the host suspends/resumes (or VMs reboot for any reason), Talos boots from ISO again and halts with: `"Talos already installed to disk but booted from another media and talos.halt_if_installed kernel parameter is set"`.
- The cluster will NOT come back up until boot order is fixed and VMs are force-stopped + restarted.
- **Fix**: After Talos applies config and reboots to disk, run `qm set <vmid> --boot order=scsi0 --ide2 none,media=cdrom` on each VM.
- Ansible automation: add this as a post-install step in the `talos_cluster` role, after waiting for nodes to reboot.

---

## Ansible (Infrastructure as Code)

### Why Ansible over Terraform

- Terraform `stop_on_destroy` with Talos VMs is dangerously slow — ACPI shutdown doesn't work well. VMs take 5+ minutes, Terraform locks get stuck.
- Ansible's `force: true` on stop + `purge: true` on destroy is much cleaner and faster.
- Ansible handles imperative steps (talosctl, helm) naturally as shell tasks. Terraform required ugly `null_resource` + `local-exec` workarounds.
- Full deploy: ~5 minutes from `ansible-playbook site.yml` to all nodes Ready with Cilium.

### Proxmox API modules (delegate_to: localhost)

- `community.proxmox.proxmox_kvm` and `proxmox_template` use REST API, not SSH.
- They require `proxmoxer` Python library on the machine executing them.
- Must use `delegate_to: localhost` because `proxmoxer` is installed locally (via `pipx inject` into ansible-core venv), not on the Proxmox host.
- All `talosctl`/`kubectl`/`helm` commands run on the Proxmox host via SSH (VMs on internal vmbr1 network, not reachable from laptop).

### ISO download filename mismatch

- `community.proxmox.proxmox_template` with `content_type: iso` and `url:` downloads ISOs using the URL's filename (e.g., `nocloud-amd64.iso`), not a custom name.
- Fix: use `ansible.builtin.get_url` on the Proxmox host directly to control the destination filename.

### Ansible installation (pipx)

- `pipx install ansible-core` then `pipx inject ansible-core proxmoxer requests requests-toolbelt`.
- Collection: `community.proxmox:1.5.0` via `ansible-galaxy collection install`.
- `stdout_callback = yaml` requires `community.general` — use `default` callback to avoid the dependency.

### Secrets handling

- `secrets.yaml` is generated once via `talosctl gen secrets` and reused across deploys (idempotent — skipped if exists).
- Talos configs are regenerated from secrets + patches every run (idempotent — same secrets produce same certs).
- Must check both local AND remote for existing secrets — they may exist on Proxmox from a prior run but not locally.

### talosconfig empty endpoints

- `talosctl gen config` produces a talosconfig with `endpoints: []` — talosctl commands fail with "failed to determine endpoints" unless `-e` is specified every time.
- Fix: after generating talosconfig, run `talosctl config endpoint <VIP_or_CP_IP>` and `talosctl config nodes <CP_IPs>` to set defaults.
- During Ansible deploy, bootstrap/apply commands specify `--endpoints` explicitly, so the empty endpoints only affect post-deploy usage.

---

## Resource Sizing (validated for ~5k IoT devices)

### VM sizing

| Node   | vCPU | RAM  | Boot disk | Longhorn disk |
| ------ | ---- | ---- | --------- | ------------- |
| CP     | 2    | 4 GB | 20 GB     | -             |
| Worker | 4    | 8 GB | 20 GB     | 20 GB (test)  |

Production target: Worker Longhorn disk 80 GB.

### Application sizing

| Component  | CPU req/limit | RAM req/limit | Storage             |
| ---------- | ------------- | ------------- | ------------------- |
| PostgreSQL | 250m/1000m    | 512Mi/2Gi     | 10Gi data + 2Gi WAL |
| ScyllaDB   | 250m/1000m    | 512Mi/1Gi     | 20Gi                |
| RabbitMQ   | 200m/1000m    | 512Mi/1Gi     | 10Gi                |
| VMSingle   | 100m/500m     | 512Mi/1Gi     | 5Gi                 |
| Loki       | 100m/500m     | 256Mi/512Mi   | 10Gi                |

### Real production workload reference (8-core/32GB host)

- Java (Spring Boot app): 1,728 MB RAM, 0.74% host CPU
- ScyllaDB: ~537 MB RAM total
- etcd: 146 MB, kubelet: 92 MB
- Total cluster idle: ~4.5-8.8 GB RAM

---

## Cluster resilience

- Cluster survived host hibernation/resume without issues — all pods recovered automatically.

---

## Deployment timing

- Full deploy (`ansible-playbook site.yml`): ~5 minutes to all 3 nodes Ready with Cilium running.
- ~31 Ansible tasks, ~17 changed on fresh deploy.
- Cilium install to all nodes Ready: ~2 minutes.
- Talos v1.12.4, Kubernetes v1.35.0, Cilium v1.17.3.
