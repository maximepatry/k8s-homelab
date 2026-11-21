# Explicit local backend (same default path as before: terraform.tfstate in
# this directory), so the self-hosted CI runner can point its own checkout at
# the operator's state file with:
#   terraform init -backend-config="path=$HOMELAB_TFSTATE"
# Without this, a fresh CI checkout plans against an empty state and tries to
# re-create Cilium/ArgoCD. After pulling this change, run `terraform init`
# once in your checkout (no state migration - same file).
terraform {
  backend "local" {}
}
