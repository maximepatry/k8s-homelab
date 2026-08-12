# apps/

User workloads, as ArgoCD `Application` manifests - one file per app-of-apps
directory (`apps/prod/`, `apps/stage/`), synced by the `apps-prod`/
`apps-stage` root Applications (`clusters/homelab/bootstrap/`).

No workloads exist yet - each directory currently only has a `namespace.yml`
creating its target namespace.

When adding a workload, drop an `Application` manifest here (not raw
Deployment/Service manifests directly - keep those in the workload's own
repo/path and reference them from the Application's `source`). It **must**
set the matching project so the `prod`/`stage` `AppProject`s
(`clusters/homelab/bootstrap/projects.yml`) actually enforce isolation:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: my-app
  namespace: argocd
spec:
  project: prod          # or: stage - must match the directory
  source:
    repoURL: ...
    targetRevision: main
    path: ...
  destination:
    server: https://kubernetes.default.svc
    namespace: prod       # or: stage - AppProject rejects anything else
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

Both `apps-prod` and `apps-stage` currently track `targetRevision: main` -
same branch, different path. If a promotion workflow is wanted later
(stage tracking a `develop` branch, promoted to `main` for prod), that's a
one-line change to `targetRevision` in `clusters/homelab/bootstrap/apps-stage.yml`,
not a restructure.
