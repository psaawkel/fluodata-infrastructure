# ============================================================
# Argo CD bootstrap installation
# ============================================================
# Installs Argo CD via Helm, then creates a root Application
# that points to cluster-gitops/bootstrap/ in this repo.
# From this point on, Argo CD manages everything declaratively.

# --- Approve pending kubelet-serving CSRs ---
# Talos generates these but K8s doesn't auto-approve them.
resource "null_resource" "approve_csrs" {
  provisioner "local-exec" {
    command = <<-EOT
      export KUBECONFIG="${local.kubeconfig_path}"
      for i in 1 2 3; do
        sleep 10
        PENDING=$(kubectl get csr -o jsonpath='{range .items[?(@.status.conditions==null)]}{.metadata.name}{" "}{end}' 2>/dev/null || true)
        if [ -n "$PENDING" ]; then
          echo "Approving CSRs: $PENDING"
          kubectl certificate approve $PENDING || true
        fi
      done
    EOT
  }

  depends_on = [data.talos_cluster_health.this, local_file.kubeconfig]
}

# --- Create privileged namespaces ---
# PodSecurity in K8s 1.32 blocks privileged workloads without namespace labels.
resource "null_resource" "privileged_namespaces" {
  provisioner "local-exec" {
    command = <<-EOT
      export KUBECONFIG="${local.kubeconfig_path}"
      for NS in argocd longhorn-system monitoring logging fluodata; do
        kubectl create namespace $NS --dry-run=client -o yaml | kubectl apply -f -
        kubectl label namespace $NS \
          pod-security.kubernetes.io/enforce=privileged \
          pod-security.kubernetes.io/audit=privileged \
          pod-security.kubernetes.io/warn=privileged \
          --overwrite
      done
    EOT
  }

  depends_on = [null_resource.approve_csrs]
}

# --- Install Argo CD ---
resource "helm_release" "argocd" {
  name             = "argocd"
  namespace        = "argocd"
  create_namespace = false # Already created above with privileged labels
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = var.argocd_version
  wait             = true
  timeout          = 600

  # Minimal config — Argo CD manages itself after bootstrap
  set {
    name  = "server.service.type"
    value = "ClusterIP"
  }

  set {
    name  = "configs.params.server\\.insecure"
    value = "true" # TLS terminated at ingress
  }

  # --- SOPS + age decryption via KSOPS kustomize plugin ---

  # Environment: tell SOPS where the age key file is
  set {
    name  = "repoServer.env[0].name"
    value = "SOPS_AGE_KEY_FILE"
  }

  set {
    name  = "repoServer.env[0].value"
    value = "/app/config/age/keys.txt"
  }

  # Environment: XDG_CONFIG_HOME for kustomize plugin discovery
  set {
    name  = "repoServer.env[1].name"
    value = "XDG_CONFIG_HOME"
  }

  set {
    name  = "repoServer.env[1].value"
    value = "/home/argocd/.config"
  }

  # Volume: mount the age private key from a Kubernetes secret
  set {
    name  = "repoServer.volumes[0].name"
    value = "sops-age"
  }

  set {
    name  = "repoServer.volumes[0].secret.secretName"
    value = "sops-age-key"
  }

  set {
    name  = "repoServer.volumeMounts[0].name"
    value = "sops-age"
  }

  set {
    name  = "repoServer.volumeMounts[0].mountPath"
    value = "/app/config/age"
  }

  # Volume: shared custom-tools for KSOPS binary
  set {
    name  = "repoServer.volumes[1].name"
    value = "custom-tools"
  }

  set {
    name  = "repoServer.volumes[1].emptyDir"
    value = ""
  }

  set {
    name  = "repoServer.volumeMounts[1].name"
    value = "custom-tools"
  }

  set {
    name  = "repoServer.volumeMounts[1].mountPath"
    value = "/usr/local/bin/ksops"
  }

  set {
    name  = "repoServer.volumeMounts[1].subPath"
    value = "ksops"
  }

  # Init container: install KSOPS binary into shared volume
  set {
    name  = "repoServer.initContainers[0].name"
    value = "install-ksops"
  }

  set {
    name  = "repoServer.initContainers[0].image"
    value = "viaductoss/ksops:v4.3.2"
  }

  set {
    name  = "repoServer.initContainers[0].command[0]"
    value = "/bin/sh"
  }

  set {
    name  = "repoServer.initContainers[0].args[0]"
    value = "-c"
  }

  set {
    name  = "repoServer.initContainers[0].args[1]"
    value = "cp /usr/local/bin/ksops /custom-tools/ksops && cp /usr/local/bin/kustomize /custom-tools/kustomize"
  }

  set {
    name  = "repoServer.initContainers[0].volumeMounts[0].name"
    value = "custom-tools"
  }

  set {
    name  = "repoServer.initContainers[0].volumeMounts[0].mountPath"
    value = "/custom-tools"
  }

  # Configure kustomize to use KSOPS as an exec plugin
  set {
    name  = "configs.cm.kustomize\\.buildOptions"
    value = "--enable-alpha-plugins --enable-exec"
  }

  depends_on = [null_resource.privileged_namespaces]
}

# --- Create SOPS age key secret ---
# This secret holds the age private key used by Argo CD repo-server
# to decrypt SOPS-encrypted secrets in the Git repo.
resource "null_resource" "sops_age_key_secret" {
  count = var.sops_age_key_file != "" ? 1 : 0

  provisioner "local-exec" {
    command = <<-EOT
      export KUBECONFIG="${local.kubeconfig_path}"
      kubectl create secret generic sops-age-key \
        --namespace argocd \
        --from-file=keys.txt=${var.sops_age_key_file} \
        --dry-run=client -o yaml | kubectl apply -f -
    EOT
  }

  depends_on = [null_resource.privileged_namespaces]
}

# --- Create root Application (App-of-Apps) ---
resource "null_resource" "argocd_root_app" {
  provisioner "local-exec" {
    command = <<-EOT
      export KUBECONFIG="${local.kubeconfig_path}"
      kubectl apply -f - <<'YAML'
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: ${var.gitops_repo_url}
    targetRevision: ${var.gitops_target_revision}
    path: ${var.gitops_repo_path}
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
YAML
    EOT
  }

  depends_on = [helm_release.argocd]
}
