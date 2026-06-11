# Homelab DevOps Pipelines

You are helping with CI/CD for a Kubernetes homelab IaC repository. Read this entire document before taking action.

---

## Pipeline Overview

Three GitHub Actions workflows live in `.github/workflows/`:

| Workflow | Trigger | Runner | Purpose |
|----------|---------|--------|---------|
| `validate.yml` | Every push / PR | `ubuntu-latest` | Lint and validate — no cluster access needed |
| `plan.yml` | PR or push to main touching `terraform/**` or `ansible/**` | `self-hosted, homelab` | Show what would change; posts Terraform plan to PR as a comment |
| `deploy.yml` | Manual (`workflow_dispatch`) | `self-hosted, homelab` | Actually applies changes; verifies ArgoCD sync at the end |

**ArgoCD handles its own rolling updates.** Once `deploy.yml` (or a direct push to main) lands, ArgoCD detects the diff within ~3 min and rolls out changed manifests automatically. The `argocd-verify` step in `deploy.yml` waits for that convergence before marking the run green.

---

## What Each Pipeline Checks

### validate.yml (no runner setup needed)

- **terraform**: `fmt -check` → `init -backend=false` → `validate`
- **ansible**: `ansible-lint ansible/` using profile `basic` (see `.ansible-lint`)
- **yaml**: `yamllint -c .yamllint.yml clusters/ ansible/`

These run on GitHub-hosted runners and require no secrets or LAN access.

### plan.yml (requires self-hosted runner)

- **terraform-plan**: `terraform init` + `terraform plan`. On a PR, posts the plan output as a collapsible comment (updates the existing comment on re-push). Uploads `tfplan` as a 1-day artifact.
- **ansible-check**: `ansible-playbook --check --diff` — shows what Ansible would change without touching the nodes.

Required GitHub secrets: `PROXMOX_ENDPOINT`, `PROXMOX_PASSWORD`, `SSH_PUBLIC_KEY`.

### deploy.yml (requires self-hosted runner)

Inputs:
- **target**: `terraform` | `ansible` | `all`
- **ansible_tags**: limit to specific roles, e.g. `containerd`
- **dry_run**: `true` runs plan/check only

Job order: `terraform-apply` → `ansible-run` → `argocd-verify`. If a job is skipped (wrong target), downstream jobs proceed normally.

The `argocd-verify` step polls `kubectl -n argocd get applications` for up to 5 minutes waiting for all apps (excluding `app-of-apps`) to be `Synced` and `Healthy`.

---

## Self-Hosted Runner Setup

The runner must run on a machine with LAN access to Proxmox (`192.168.1.10–12`) and SSH access to k8s nodes (`192.168.1.101–103`). The simplest place is the control-plane node itself (`n150-cp`).

### Install runner on n150-cp (one time)

```bash
ssh rocky@192.168.1.101

# Create a dedicated user
sudo useradd -m -s /bin/bash github-runner
sudo usermod -aG wheel github-runner     # needs sudo for ansible become

# Switch to the runner user
sudo -iu github-runner

# Download the runner package (get the current URL from GitHub repo → Settings → Actions → Runners → New self-hosted runner)
mkdir actions-runner && cd actions-runner
curl -o actions-runner-linux-x64.tar.gz -L https://github.com/actions/runner/releases/download/v2.x.y/actions-runner-linux-x64-2.x.y.tar.gz
tar xzf actions-runner-linux-x64.tar.gz

# Configure (replace TOKEN with the registration token from GitHub)
./config.sh --url https://github.com/YOUR_USERNAME/k8s-homelab \
            --token TOKEN \
            --labels homelab \
            --name n150-cp \
            --unattended

# Install as systemd service
sudo ./svc.sh install github-runner
sudo ./svc.sh start
```

### Runner dependencies

```bash
sudo dnf install -y git ansible terraform    # or install terraform from hashicorp repo
pip3 install ansible-core ansible-lint yamllint
```

The runner needs:
- `~/.ssh/id_ed25519` — SSH key matching the VMs (used by Ansible)
- `~/.kube/config` — kubeconfig for the cluster (Ansible writes this to `clusters/homelab/kubeconfig` but the runner reads from its home)
- `~/.terraformrc` or env vars if you use a private Terraform registry

### Passwordless sudo for Ansible

```bash
echo "github-runner ALL=(ALL) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/github-runner
```

---

## GitHub Secrets

Go to **Repo → Settings → Secrets and variables → Actions** and add:

| Secret | Value |
|--------|-------|
| `PROXMOX_ENDPOINT` | `https://192.168.1.10:8006` |
| `PROXMOX_PASSWORD` | The `terraform@pve` user password |
| `SSH_PUBLIC_KEY` | Contents of the SSH public key injected into VMs |

---

## Adding Validation for a New Component

### New Terraform module
Nothing needed — `terraform validate` picks it up automatically.

### New Ansible role
Nothing needed — `ansible-lint ansible/` lints the whole `ansible/` tree. Add tasks to `ansible/playbooks/bootstrap.yml` and they'll be checked.

### New cluster manifest (ArgoCD Application or raw YAML)
Drop it under `clusters/homelab/infrastructure/` or `clusters/homelab/apps/`. `yamllint` will catch YAML syntax errors automatically. If it's a CRD type (like an `Application`), yamllint covers syntax; schema validation against the CRD is not done in CI (requires a live cluster or the CRD schema file).

---

## Triggering a Deploy

Via GitHub UI: **Actions → Deploy → Run workflow**

Via `gh` CLI:

```bash
# Deploy everything (Terraform + Ansible + ArgoCD verify)
gh workflow run deploy.yml -f target=all -f dry_run=false

# Terraform only
gh workflow run deploy.yml -f target=terraform -f dry_run=false

# Ansible, only the containerd role
gh workflow run deploy.yml -f target=ansible -f ansible_tags=containerd -f dry_run=false

# Dry-run preview with no changes
gh workflow run deploy.yml -f target=all -f dry_run=true
```

---

## Common Failures

### validate / terraform fmt fails
Run `terraform -chdir=terraform/proxmox fmt -recursive` locally, commit the formatted files.

### validate / ansible-lint fails
Run `ansible-lint ansible/` locally. Common issues:
- Missing `changed_when` on `command:` tasks → add `changed_when: false` or use the appropriate module
- Deprecated module name → update to `ansible.builtin.dnf` etc. (or keep `profile: basic` in `.ansible-lint` which skips this)

### plan / runner not picking up jobs
Check the runner is online: `sudo systemctl status actions.runner.*`
Restart: `sudo systemctl restart actions.runner.*`

### plan / terraform plan fails with auth error
Verify `PROXMOX_ENDPOINT` and `PROXMOX_PASSWORD` secrets are set. The endpoint must be reachable from the runner (`curl -k https://192.168.1.10:8006`).

### deploy / argocd-verify times out
1. Check `kubectl -n argocd get applications` manually.
2. If an app is `OutOfSync`, check `kubectl -n argocd app diff <name>`.
3. Cilium must sync and be Healthy before other apps can come up — if Cilium is stuck, investigate it first (see homelab-context for Cilium troubleshooting).

### deploy / ansible-run fails on unreachable node
SSH to the node manually: `ssh rocky@192.168.1.10x`. If the VM is down, check Proxmox. If it's up but SSH fails, verify the runner's SSH key is still injected into the VM (`~/.ssh/authorized_keys` for user `rocky`).

---

## ARGUMENTS

$ARGUMENTS
