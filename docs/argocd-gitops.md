# ArgoCD & GitOps

All infrastructure after the initial cluster bootstrap is managed by ArgoCD using the app-of-apps pattern. The git repository is the source of truth — do not make changes directly with `helm install` or `kubectl apply` for managed components.

## App-of-Apps Pattern

```
app-of-apps (Application)
  └── clusters/homelab/infrastructure/
        ├── cilium.yml         → Application
        ├── metallb.yml        → Application
        ├── longhorn.yml       → Application
        ├── cert-manager.yml   → Application
        └── ingress-nginx.yml  → Application
```

The root `app-of-apps` Application watches `clusters/homelab/infrastructure/` in git. Any Application manifest added to that directory is automatically picked up and synced.

## Initial Bootstrap (once)

After `ansible-playbook bootstrap.yml` completes:

```bash
export KUBECONFIG=clusters/homelab/kubeconfig

# Install ArgoCD
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Wait for ArgoCD to be ready
kubectl -n argocd wait --for=condition=available deploy/argocd-server --timeout=120s

# Apply the app-of-apps (update the repoURL in the file first)
kubectl apply -f clusters/homelab/bootstrap/app-of-apps.yml
```

**Before applying `app-of-apps.yml`**, set your GitHub repo URL in the file:
```yaml
source:
  repoURL: https://github.com/YOUR_USERNAME/k8s-homelab
```

## Accessing ArgoCD

```bash
# Port-forward
kubectl -n argocd port-forward svc/argocd-server 8080:443

# Get the initial admin password
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
argocd app sync -l app.kubernetes.io/instance=app-of-apps
```

Or via UI: sync `cilium` → wait → sync all others.

## Adding a New Infrastructure Component

1. Create a Helm values file in `infrastructure/<component>/values.yml` if needed
2. Create an Application manifest in `clusters/homelab/infrastructure/<component>.yml`
3. Commit and push — ArgoCD detects the new Application within ~3 minutes (default poll interval)

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

## Adding an Application (user workload)

Add Application manifests under `clusters/homelab/apps/` and create a second app-of-apps pointing at that directory, or add it to the existing infrastructure app-of-apps.

## Upgrading a Component

Update `targetRevision` in the relevant Application manifest, commit, push. ArgoCD will detect the drift and sync automatically (if `automated` is set) or prompt you to sync manually.

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
