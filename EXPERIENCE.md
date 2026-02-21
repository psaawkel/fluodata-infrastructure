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
- Cilium must be running BEFORE any pods can schedule (chicken-and-egg with Argo CD).
- Approach: embed Cilium manifests in Talos inline manifests, Argo CD takes over management later.
- Talos machine config: set `cluster.network.cni.name: none` and provide Cilium via `cluster.inlineManifests`.

### DHCP and networking

- Talos nocloud VMs do NOT send DHCP hostnames.
- dnsmasq hostname-based reservations fail silently — VMs get random IPs.
- Fix: assign deterministic MAC addresses to VMs and use MAC-based DHCP leases.

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

---

## Resource Sizing (validated for ~5k IoT devices)

### VM sizing

| Node   | vCPU | RAM  | Boot disk | Longhorn disk |
| ------ | ---- | ---- | --------- | ------------- |
| CP     | 2    | 6 GB | 20 GB     | -             |
| Worker | 4    | 8 GB | 20 GB     | 80 GB         |

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
