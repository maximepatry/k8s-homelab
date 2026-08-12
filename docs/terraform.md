# Terraform — Cluster Bootstrap

Terraform does **not** provision the hosts (they're bare-metal, provisioned via PXE/kickstart — see
`bare-metal/`) or install Kubernetes (Ansible's job — see `docs/ansible.md`). Its job is narrow and
one-time per cluster: install ArgoCD onto the freshly-kubeadm'd cluster and apply the `AppProject`s and
root Applications, then get out of the way. Everything after that is owned by ArgoCD/GitOps.

## Prerequisites

- `ansible-playbook playbooks/bootstrap.yml` has already run and produced `clusters/homelab/kubeconfig`
  (Terraform's `kubernetes`/`helm`/`kubectl` providers all read this file).
- Terraform >= 1.5.

## Running

```bash
cd terraform/cluster-bootstrap
terraform init
terraform apply
```

All variables have working defaults (see `variables.tf`) — you only need a `terraform.tfvars` if
overriding one, e.g. a different repo URL or branch.

| Variable | Default | Description |
|----------|---------|-------------|
| `kubeconfig_path` | `../../clusters/homelab/kubeconfig` | Path to the admin kubeconfig Ansible fetched |
| `repo_url` | `https://github.com/maximepatry/k8s-homelab` | Git repo ArgoCD syncs from |
| `target_revision` | `main` | Branch ArgoCD tracks for all root Applications |
| `argocd_chart_version` | `7.7.*` | `argo-cd` Helm chart version (argoproj Helm repo) |

## What it does

1. `helm_release.argocd` — installs the `argo-cd` chart into a new `argocd` namespace.
2. Applies `clusters/homelab/bootstrap/{projects,infra-root,apps-prod,apps-stage}.yml` via the
   `alekc/kubectl` provider's `kubectl_manifest` resource (needed over the plain `kubernetes` provider
   because these are custom `AppProject`/`Application` CRDs that don't exist until step 1 lands —
   `kubectl_manifest` tolerates that; `kubernetes_manifest` doesn't). Multi-document files (`projects.yml`
   has two `AppProject`s) are split via `data.kubectl_file_documents` and applied as separate resources.

From there, `infra-root` picks up everything under `clusters/homelab/infrastructure/` (Cilium, MetalLB,
ingress-nginx, cert-manager, Longhorn), and `apps-prod`/`apps-stage` pick up `apps/prod/` and `apps/stage/`
— all managed by ArgoCD going forward, not Terraform. See `docs/argocd-gitops.md`.

## Retrieving the ArgoCD admin password

```bash
terraform output -raw argocd_admin_password_command | bash
# or directly:
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
```

## Re-running

Both the manifest apply and the Helm release are idempotent — rerunning `terraform apply` after the
cluster already has ArgoCD installed is a no-op (or picks up a version bump if you changed
`argocd_chart_version`). This module doesn't need to run again after the first bootstrap unless you're
changing ArgoCD's own version/config or the root Application definitions themselves — day-to-day
infrastructure/app changes go through git + ArgoCD, not Terraform.

## Rebuilding from scratch

If you ever need to fully reset (see `docs/day2-operations.md`), `terraform destroy` removes ArgoCD and
the bootstrap manifests but does **not** touch anything ArgoCD deployed independently (Cilium, MetalLB,
etc. stay running, now unmanaged) — clean those up via `helm uninstall`/`kubectl delete` first if you
actually want a clean slate, or just re-run `terraform apply` to let ArgoCD reconcile everything again.
