# ArgoCD & GitOps

All infrastructure after the initial cluster bootstrap is managed by ArgoCD using the app-of-apps pattern.
The git repository is the source of truth — do not make changes directly with `helm install` or
`kubectl apply` for managed components.

ArgoCD itself is installed by Terraform (`terraform/cluster-bootstrap/`, see `docs/terraform.md`), not
manually — that's a one-time step, not something you repeat here.

## App-of-Apps Pattern

Three independent root Applications, not one — infra is cluster-wide (single instance), while user
workloads are split prod/stage for isolation:

```
infra-root (Application, project: default)
  └── clusters/homelab/infrastructure/
        ├── cilium.yml         → Application
        ├── metallb.yml        → Application
        ├── metallb-pool.yml   → Application (IPAddressPool/L2Advertisement, sync-wave 1)
        ├── longhorn.yml       → Application
        ├── cert-manager.yml   → Application
        └── ingress-nginx.yml  → Application

apps-prod (Application, project: default)
  └── apps/prod/                → Namespace "prod" + your prod workloads (project: prod)

apps-stage (Application, project: default)
  └── apps/stage/               → Namespace "stage" + your stage workloads (project: stage)
```

The root Applications themselves stay in the `default` project (they're just bootstrap plumbing that
creates other `Application` resources) — the prod/stage **isolation** is enforced by the `prod`/`stage`
`AppProject`s (`clusters/homelab/bootstrap/projects.yml`), which restrict destination namespaces. Any
workload `Application` you add under `apps/prod/` or `apps/stage/` must declare the matching `project:` for
that restriction to apply — see `apps/README.md`.

ArgoCD polls git every ~3 minutes by default; any Application manifest added to a watched directory is
automatically picked up and synced.

## Accessing ArgoCD

```bash
# Port-forward
kubectl -n argocd port-forward svc/argocd-server 8080:443

# Get the initial admin password (also: terraform output argocd_admin_password_command)
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d && echo

# Login (CLI)
argocd login localhost:8080 --username admin --insecure
```

Open https://localhost:8080 in your browser.

After first login, change the admin password and delete the bootstrap secret:
```bash
argocd account update-password
kubectl -n argocd delete secret argocd-initial-admin-secret
```

## Sync Order on a Fresh Cluster

Cilium must be healthy before other pods can communicate. On first sync:

```bash
# Sync Cilium first
argocd app sync cilium
# Wait for nodes to become Ready
kubectl get nodes -w
# Then sync everything else
argocd app sync -l app.kubernetes.io/instance=infra-root
```

Or via UI: sync `cilium` → wait → sync all others. `metallb-pool` is annotated with a later ArgoCD
sync-wave than `metallb`, so it retries automatically until MetalLB's CRDs exist — no manual ordering
needed there.

## Adding a New Infrastructure Component

1. Create an Application manifest in `clusters/homelab/infrastructure/<component>.yml`
2. Commit and push — ArgoCD detects the new Application within ~3 minutes (default poll interval)

Example Application manifest:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: my-component
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://helm.example.com
    chart: my-chart
    targetRevision: "1.2.*"
    helm:
      valuesObject:
        key: value
  destination:
    server: https://kubernetes.default.svc
    namespace: my-namespace
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

## Adding a Workload (prod or stage)

Add an Application manifest under `apps/prod/` or `apps/stage/` — see `apps/README.md` for the required
`project:`/`destination.namespace` fields that make the `AppProject` isolation actually apply.

Both `apps-prod` and `apps-stage` currently track `targetRevision: main` (same branch, different path). If
you want a promotion workflow later (stage tracking a `develop` branch, promoted to `main` for prod),
that's a one-line change to `apps-stage.yml`, not a restructure.

## Upgrading a Component

Update `targetRevision` in the relevant Application manifest, commit, push. ArgoCD will detect the drift
and sync automatically (if `automated` is set) or prompt you to sync manually.

To pin a specific chart version during troubleshooting, change `"1.2.*"` to `"1.2.3"`.

## Useful CLI Commands

```bash
# List all applications and sync status
argocd app list

# Check a specific app
argocd app get cilium

# Force sync (ignore automated policy)
argocd app sync cilium

# View sync history
argocd app history cilium

# Rollback to a previous sync
argocd app rollback cilium <revision-id>

# Diff what would change
argocd app diff cilium
```
