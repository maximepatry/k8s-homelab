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

## Self-hosted runner setup (on the jumpbox)

The runner needs to run somewhere with a path into `10.10.10.0/24` — that's the Mac jumpbox, over the
WireGuard tunnel from `bare-metal/README.md` ("Tunnel WireGuard pour le jumpbox"). Bring the tunnel up
before the runner needs to reach anything (it does not manage the tunnel itself).

1. On GitHub: repo → **Settings → Actions → Runners → New self-hosted runner**, pick macOS/ARM64. Copy the
   `./config.sh --url ... --token ...` command it gives you (the token is single-use, generated per
   registration — don't reuse an old one from these docs).
2. On the Mac:
   ```bash
   mkdir -p ~/actions-runner && cd ~/actions-runner
   # paste the download + config.sh commands from step 1
   ```
3. When prompted for labels, add `homelab` (the workflows target `[self-hosted, homelab]` specifically —
   the default `self-hosted` label alone isn't enough).
4. Run it as a background service so it survives reboots/logout:
   ```bash
   ./svc.sh install
   ./svc.sh start
   ```
5. Make sure the runner's environment has what the jobs need on `PATH`: `terraform`, `ansible-playbook`,
   `ansible-lint`, `kubectl`, `jq`. The runner inherits whatever shell environment it was installed under
   — if you installed these via Homebrew under your normal user, a launchd-managed service may not pick up
   `/opt/homebrew/bin` unless it's on the system `PATH`; verify with a workflow run rather than assuming.

## Kubeconfig on the runner

`terraform/cluster-bootstrap`'s providers and `deploy.yml`'s `argocd-verify` job both read
`clusters/homelab/kubeconfig` from the runner's own checkout (workspace-relative, not `~/.kube/config`) —
it's produced once by `ansible-playbook playbooks/bootstrap.yml` (the control-plane role fetches it) and
persists on the runner's disk across workflow runs, since the self-hosted runner isn't ephemeral like a
GitHub-hosted one. The very first `plan.yml`/`deploy.yml` run before any manual bootstrap has happened will
fail for lack of this file — that's expected, not a bug; run the initial bootstrap by hand once (see
`docs/ansible.md`, `docs/terraform.md`) before relying on the pipeline for it.
