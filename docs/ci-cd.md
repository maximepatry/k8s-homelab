# CI/CD

Three GitHub Actions workflows (`.github/workflows/`):

| Workflow | Trigger | Runs on | What it does |
|----------|---------|---------|---------------|
| `validate.yml` | every push/PR | `ubuntu-latest` (hosted) | `terraform fmt`/`validate` (no backend, no cluster access needed), `ansible-lint`, `yamllint` |
| `plan.yml` | PR/push touching `terraform/**` or `ansible/**` | `[self-hosted, homelab]` | `terraform plan` against the real cluster, `ansible-playbook --check --diff` |
| `deploy.yml` | manual (`workflow_dispatch`) | `[self-hosted, homelab]` | `terraform apply`, `ansible-playbook`, waits for ArgoCD to sync/heal |

`validate.yml` needs no LAN access (hosted runner is fine). `plan.yml` and `deploy.yml` need to actually
reach the hosts and the cluster API (`10.10.10.0/24`), so they require a **self-hosted runner** — there's
no GitHub-hosted alternative for a private homelab network.

## Self-hosted runner setup (on the Mac jumpbox)

The runner has to run somewhere with a path into `10.10.10.0/24` and that **survives a cluster rebuild** —
that's the Mac jumpbox (on the Opal LAN, or over the WireGuard tunnel from `bare-metal/README.md`,
"Tunnel WireGuard pour le jumpbox"). Never put it on host1/2/3: they get reset/rebooted during rebuilds.

### Security first (public repo)

This repo is public and the runner holds SSH keys to every node plus a cluster-admin kubeconfig. Two
guards, both required:

1. `plan.yml` jobs only run for pushes and for PRs whose head branch is in this repo
   (`github.event.pull_request.head.repo.full_name == github.repository`) — fork PRs never reach the
   runner. Keep that `if:` on any new job that targets `[self-hosted, homelab]`.
2. Repo → **Settings → Actions → General → "Approval for running fork pull request workflows"** set to
   **Require approval for all external contributors** (defense in depth for any future workflow).

Also: workflows take inputs via `env:`, never `${{ }}`-interpolated into `run:` scripts.

### Install

1. Get a registration token (single-use, expires after 1h):
   `gh api -X POST repos/maximepatry/k8s-homelab/actions/runners/registration-token -q .token`
   (or repo → **Settings → Actions → Runners → New self-hosted runner**, macOS/ARM64).
2. On the Mac:
   ```bash
   mkdir -p ~/actions-runner && cd ~/actions-runner
   curl -fsSLO https://github.com/actions/runner/releases/download/v<VER>/actions-runner-osx-arm64-<VER>.tar.gz
   tar xzf actions-runner-osx-arm64-<VER>.tar.gz
   ./config.sh --unattended --url https://github.com/maximepatry/k8s-homelab --token <TOKEN> \
     --name mac-jumpbox --labels homelab --work _work
   ```
   The `homelab` label is required — the workflows target `[self-hosted, homelab]`.
3. Create `~/actions-runner/.env` (read by the runner at start, one `KEY=value` per line, no quotes):
   ```
   PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
   HOMELAB_TFSTATE=/Users/<you>/projects/k8s-homelab/terraform/cluster-bootstrap/terraform.tfstate
   HOMELAB_KUBECONFIG=/Users/<you>/projects/k8s-homelab/clusters/homelab/kubeconfig
   ```
4. Run it as a launchd service (a LaunchAgent: runs as your user, so it uses your `~/.ssh` keys, and
   only while you're logged in):
   ```bash
   ./svc.sh install && ./svc.sh start
   ./svc.sh status
   ```

Tools the jobs need on that `PATH`: `terraform`, `ansible-playbook` (Homebrew `ansible` bundles
`ansible.posix`/`community.general`), `kubectl`, `jq`.

## State and kubeconfig on the runner

Both live in **your** checkout, not the runner's — the runner's checkout under `~/actions-runner/_work`
is throwaway:

- **Terraform state** is local (`terraform/cluster-bootstrap/terraform.tfstate`, gitignored).
  `backend.tf` declares an explicit `local` backend so CI can run
  `terraform init -backend-config="path=$HOMELAB_TFSTATE"` and share that one file (local-backend locking
  prevents a CI run and a manual `terraform apply` from writing at once). Without it, CI would plan
  against an empty state and try to re-create Cilium/ArgoCD.
- **kubeconfig**: Terraform and `kubectl` read `$HOMELAB_KUBECONFIG` directly. Ansible jobs copy it into
  the checkout first (the control-plane role writes `clusters/homelab/kubeconfig`), and `deploy.yml`
  copies it back if the playbook rewrote it (e.g. after a cluster rebuild).
- Ansible steps run with `working-directory: ansible` so `ansible/ansible.cfg` (become, SSH key, roles
  path) is actually loaded — it's only read from the current directory.
- Plan and Deploy share a `concurrency: homelab-cluster` group, so they never run against the cluster at
  the same time.

The very first run needs an existing cluster and kubeconfig — bootstrap by hand once (see
`docs/ansible.md`, `docs/terraform.md`) before relying on the pipeline.
