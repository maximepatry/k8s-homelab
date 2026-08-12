output "argocd_namespace" {
  value = helm_release.argocd.namespace
}

output "argocd_admin_password_command" {
  description = "Run this to retrieve the ArgoCD-generated initial admin password"
  value       = "kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
}
