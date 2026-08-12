variable "kubeconfig_path" {
  description = "Path to the admin kubeconfig fetched by the Ansible control-plane role"
  type        = string
  default     = "../../clusters/homelab/kubeconfig"
}

variable "repo_url" {
  description = "Git repo ArgoCD syncs from"
  type        = string
  default     = "https://github.com/maximepatry/k8s-homelab"
}

variable "target_revision" {
  description = "Branch ArgoCD tracks for all root Applications"
  type        = string
  default     = "main"
}

variable "argocd_chart_version" {
  description = "argo-cd Helm chart version (argoproj Helm repo)"
  type        = string
  default     = "7.7.*"
}
