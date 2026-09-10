# Installing a New Component on the Cluster

Step-by-step walkthrough for adding a new component (infra piece or user-facing app) to this cluster.
Everything here goes through GitOps — there is no `helm install` or `kubectl apply` for anything ArgoCD is
meant to own. See `docs/argocd-gitops.md` for the reference on the app-of-apps structure this builds on.

This walks through the decisions in order, then works a full real example (deploying
[Homepage](https://gethomepage.dev)) end to end.

## 1. Infrastructure or workload?

- **Infrastructure** (cluster-wide, one instance, shared by everything — CNI, ingress controller, storage,
  monitoring, …): Application manifest goes in `clusters/homelab/infrastructure/<name>.yml`, synced by the
  `infra-root` root Application. `project: default`.
- **Workload** (an app you run and use — a dashboard, a self-hosted service, …): Application manifest goes
  in `apps/prod/<name>.yml` or `apps/stage/<name>.yml`, synced by `apps-prod`/`apps-stage`. `project: prod`
  or `project: stage` respectively — this is what makes the `AppProject` in
  `clusters/homelab/bootstrap/projects.yml` actually enforce that a prod app can't land in the stage
  namespace or vice versa. See `apps/README.md`.

Homepage is a workload — it's not shared cluster infrastructure, it's a thing you look at. It goes under
`apps/prod/`.

## 2. Helm chart, or raw manifests?

Check whether the component publishes a Helm chart first — it's the least to maintain. If it does, the
Application's `source` points straight at the chart repo (see `monitoring.yml` or `ingress-nginx.yml` for
examples: `repoURL` is the Helm repo, `chart` + `targetRevision` pin what's installed, `helm.valuesObject`
holds overrides).

If there's no chart — Homepage's case, it ships plain Kubernetes manifests in its docs, no chart — the
manifests need to live somewhere ArgoCD can point `source.path` at. Don't inline them into the Application
file itself under `apps/prod/`; give them their own directory instead:

```
apps/prod/
├── homepage.yml            # the Application resource — project, destination, source.path below
└── homepage/                # what source.path points at — the actual manifests
    ├── rbac.yaml
    ├── configmap.yaml
    ├── deployment.yaml
    ├── service.yaml
    └── ingress.yaml
```

The Application's `source.repoURL` is this repo itself (`https://github.com/maximepatry/k8s-homelab`),
`source.path` is `apps/prod/homepage`. ArgoCD syncs whatever's in that directory as plain manifests — no
Helm, no Kustomize needed for something this small.

## 3. Namespace, RBAC, and the AppProject whitelist

- The namespace (`prod` or `stage`) already exists — created once by `apps/prod/namespace.yml` /
  `apps/stage/namespace.yml`. Don't add `syncOptions: [CreateNamespace=true]` for a namespace something
  else already owns.
- If the component needs **cluster-scoped resources** (a `ClusterRole`, a `CustomResourceDefinition`, …),
  check `clusterResourceWhitelist` in the matching `AppProject`
  (`clusters/homelab/bootstrap/projects.yml`) first. By default `prod`/`stage` only whitelist `Namespace` —
  anything else gets blocked/pruned silently. Homepage needed this: its Kubernetes-cluster widget reads
  pods/nodes/ingresses across every namespace, which requires a `ClusterRole`/`ClusterRoleBinding`, so
  `projects.yml` now explicitly whitelists those two kinds for the `prod` project (with a comment explaining
  why — don't widen this further than a specific component actually needs).

## 4. Exposing it (ingress + DNS)

Reuse the existing `ingress-nginx` LoadBalancer rather than requesting a new IP — see `docs/networking.md`,
"Exposing an application". Pick a `*.homelab.local` hostname, add an `Ingress` pointing
`ingressClassName: nginx` at the component's `Service`, and once it's live add the hostname to
`/etc/hosts` (or your router's DNS) pointing at the ingress-nginx external IP:

```bash
kubectl -n ingress-nginx get svc ingress-nginx-controller   # note the EXTERNAL-IP
echo "10.10.10.250 homepage.homelab.local" | sudo tee -a /etc/hosts
```

No TLS by default — there's no cert-manager `ClusterIssuer` configured on this cluster yet (see
`docs/networking.md`), same as Grafana. Plain HTTP is fine on this isolated LAN.

## 5. Push it — nothing happens until it's on GitHub

Commit and push to `main`. ArgoCD only reacts to the actual GitHub remote, never your local working copy —
editing files and stopping there does nothing (this has bitten this repo before, see
`docs/argocd-gitops.md`). It polls every ~3 minutes by default, or force it immediately:

```bash
argocd app sync homepage
# or, without the CLI logged in:
kubectl -n argocd patch application homepage --type merge -p '{"operation":{"sync":{}}}'
```

## 6. Verify

```bash
kubectl -n argocd get application homepage        # Synced / Healthy?
kubectl -n prod get pods,svc,ingress -l app.kubernetes.io/name=homepage
kubectl -n prod logs deploy/homepage
```

If the Application is stuck `OutOfSync` on a resource kind you didn't expect, it's almost always the
`AppProject` whitelist from step 3 — `kubectl -n argocd describe application homepage` shows exactly which
resource ArgoCD refused to apply.

## Worked example: Homepage

[Homepage](https://github.com/gethomepage/homepage) is a self-hosted dashboard/start page. No official Helm
chart, so this follows the raw-manifest path above:

- `apps/prod/homepage.yml` — the Application (`project: prod`, `source.path: apps/prod/homepage`)
- `apps/prod/homepage/rbac.yaml` — `ServiceAccount` + token `Secret` + cluster-wide `ClusterRole`/
  `ClusterRoleBinding` (read-only: namespaces, pods, nodes, ingresses, metrics) so the `kubernetes.yaml`
  widget (`mode: cluster`) can show live cluster stats
- `apps/prod/homepage/configmap.yaml` — Homepage's own config format (`settings.yaml`, `services.yaml`,
  `bookmarks.yaml`, `widgets.yaml`, …), one ConfigMap key per file, mounted via `subPath`
- `apps/prod/homepage/deployment.yaml` — single replica, `ghcr.io/gethomepage/homepage:v2.3.0` pinned (not
  `:latest` — same convention as every Helm-based Application here pinning `targetRevision`), runs as
  non-root UID 1000, no persistent storage needed (fully stateless, config comes from the ConfigMap)
- `apps/prod/homepage/service.yaml` — `ClusterIP`, port 3000
- `apps/prod/homepage/ingress.yaml` — `homepage.homelab.local`, no TLS (matches Grafana's setup)

To customize what it shows, edit `apps/prod/homepage/configmap.yaml` (`services.yaml`/`bookmarks.yaml`),
commit, push — no image rebuild needed, it's just a ConfigMap.

Once synced and `/etc/hosts` is updated (step 4 above), open `http://homepage.homelab.local`.
