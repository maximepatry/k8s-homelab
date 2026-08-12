# Cilium goes first, outside GitOps, to break a real chicken-and-egg
# problem: ArgoCD's own pods use normal pod networking and can't schedule
# without a CNI, but this repo's design has ArgoCD install the CNI. Cilium's
# agent DaemonSet runs with hostNetwork: true, so it - uniquely - can start
# before any CNI exists. Once nodes are Ready, ArgoCD schedules fine.
#
# Values here must match clusters/homelab/infrastructure/cilium.yml -
# ArgoCD adopts/reconciles this same Helm release once infra-root syncs, so
# this is a one-time bootstrap install, not an ongoing Terraform-managed
# resource (day-2 Cilium changes go through the ArgoCD Application, not here).
resource "helm_release" "cilium" {
  name       = "cilium"
  repository = "https://helm.cilium.io"
  chart      = "cilium"
  version    = "1.16.*"
  namespace  = "kube-system"

  set {
    name  = "kubeProxyReplacement"
    value = "true"
  }
  set {
    name  = "k8sServiceHost"
    value = "10.10.10.10" # host1, the control-plane
  }
  set {
    name  = "k8sServicePort"
    value = "6443"
  }
  set {
    name  = "hubble.enabled"
    value = "true"
  }
  set {
    name  = "hubble.relay.enabled"
    value = "true"
  }
  set {
    name  = "hubble.ui.enabled"
    value = "true"
  }
}

resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = var.argocd_chart_version
  namespace        = "argocd"
  create_namespace = true

  depends_on = [helm_release.cilium]
}

# The bootstrap manifests (AppProjects + root Applications) already carry
# the real repo URL/branch (fixed in clusters/homelab/bootstrap/*.yml) - no
# templating needed here, which keeps them directly kubectl-applyable too
# as a manual fallback (see docs/argocd-gitops.md).
locals {
  bootstrap_manifest_files = [
    "${path.module}/../../clusters/homelab/bootstrap/projects.yml",
    "${path.module}/../../clusters/homelab/bootstrap/infra-root.yml",
    "${path.module}/../../clusters/homelab/bootstrap/apps-prod.yml",
    "${path.module}/../../clusters/homelab/bootstrap/apps-stage.yml",
  ]
}

data "kubectl_file_documents" "bootstrap" {
  for_each = toset(local.bootstrap_manifest_files)
  content  = file(each.value)
}

locals {
  # Flatten {file => {documents}} into a single map keyed by "file#index" so
  # multi-document files (projects.yml has two AppProjects) each become
  # their own kubectl_manifest resource.
  bootstrap_manifests = merge([
    for f, doc in data.kubectl_file_documents.bootstrap : {
      for idx, manifest in doc.documents : "${f}#${idx}" => manifest
    }
  ]...)
}

resource "kubectl_manifest" "bootstrap" {
  for_each   = local.bootstrap_manifests
  yaml_body  = each.value
  depends_on = [helm_release.argocd]
}
