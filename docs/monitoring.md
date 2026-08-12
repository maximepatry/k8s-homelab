# Monitoring — Prometheus & Grafana

Installed via the `prometheus-community/kube-prometheus-stack` Helm chart
(`clusters/homelab/infrastructure/monitoring.yml`) — Prometheus, Grafana, Alertmanager,
node-exporter, kube-state-metrics, and the Prometheus Operator, all in the `monitoring` namespace.

## Installing/upgrading the CRDs (one-time, manual)

The chart's `monitoring.yml` Application sets `helm.skipCrds: true` — ArgoCD never installs or manages
these CRDs itself. Confirmed on this cluster: the Prometheus/Alertmanager/etc. CRDs are large enough that
client-side apply's `kubectl.kubernetes.io/last-applied-configuration` annotation exceeds Kubernetes'
262144-byte limit, and neither ArgoCD's `ServerSideApply=true` nor `Replace=true` sync options actually
avoid this for CRD resources specifically in this ArgoCD version (v2.13.4) — a plain
`kubectl apply --server-side` on the exact same CRD works fine, so it's an ArgoCD limitation, not a real
size problem.

Install/update them by rendering the chart locally and applying with real server-side apply:

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update prometheus-community
helm template monitoring prometheus-community/kube-prometheus-stack \
  --version 88.* --include-crds --namespace monitoring \
  | kubectl apply --server-side -f -
```

Re-run this after bumping the chart's `targetRevision` in `monitoring.yml` to a version with CRD schema
changes — otherwise Prometheus/Alertmanager Custom Resources may fail validation against a stale CRD.

## Accessing Grafana

Two ways:

**Ingress** (no VPN/port-forward needed once set up): `http://grafana.homelab.local`. Add an `/etc/hosts`
entry pointing it at the ingress-nginx LoadBalancer IP first:
```bash
kubectl -n ingress-nginx get svc ingress-nginx-controller   # note the EXTERNAL-IP, e.g. 10.10.10.250
echo "10.10.10.250 grafana.homelab.local" | sudo tee -a /etc/hosts
```
No TLS — there's no cert-manager `ClusterIssuer` configured yet (see `docs/networking.md`), this is plain
HTTP on the isolated LAN.

**Port-forward** (works immediately, no DNS setup):
```bash
kubectl -n monitoring port-forward svc/monitoring-grafana 3000:80
```
Open http://localhost:3000.

### Login

Username `admin`. The chart auto-generates a random password into a Secret rather than this being a
plaintext value in a public repo:
```bash
kubectl -n monitoring get secret monitoring-grafana -o jsonpath='{.data.admin-password}' | base64 -d && echo
```

## Accessing Prometheus directly

```bash
kubectl -n monitoring port-forward svc/monitoring-kube-prometheus-prometheus 9090:9090
```
Open http://localhost:9090 — useful for testing PromQL queries directly, or checking **Status → Targets**
to see what's actually being scraped.

## The "Homelab Overview" dashboard

`clusters/homelab/infrastructure/monitoring/dashboard-configmap.yml` ships a custom dashboard (auto-loaded
by Grafana's sidecar — any ConfigMap labeled `grafana_dashboard: "1"` in any namespace gets picked up,
that's a kube-prometheus-stack default, not something configured specially here). Find it in Grafana under
**Dashboards → Homelab Overview**, or directly navigate to `/d/homelab-overview`.

Panels: nodes Ready, running/not-ready pod counts, active namespaces, PVCs bound, CPU/memory/disk usage
per node (host1/host2/host3), network throughput per node, running pods per namespace, PVC usage. Built
entirely on node-exporter + kube-state-metrics + kubelet metrics, which are scraped by default — no extra
ServiceMonitors needed for this dashboard specifically.

The chart also ships its own large set of default dashboards (Kubernetes / Compute Resources / Cluster,
Nodes, Pods, Namespaces; Node Exporter / Nodes; etc.) — browse **Dashboards** in Grafana for the full list.
Those are more detailed/drill-down views; "Homelab Overview" is the single-pane summary.

## What's NOT being scraped yet

Deliberately out of scope for the initial install — add a `ServiceMonitor` for these later if wanted:

- **Cilium/Hubble metrics** — Cilium was installed without its Prometheus metrics endpoints enabled
  (`clusters/homelab/infrastructure/cilium.yml` doesn't set `prometheus.enabled`/`hubble.metrics.enabled`).
- **ArgoCD metrics** — the `ArgoCD Apps OutOfSync` panel on the Homelab Overview dashboard will show no
  data until a ServiceMonitor exists for `argocd-metrics`/`argocd-server-metrics` (ArgoCD exposes
  Prometheus metrics by default, just nothing is scraping them yet).
- **Longhorn metrics** — Longhorn exposes its own volume/replica health metrics
  (`longhorn_volume_robustness`, etc.) but the Longhorn Helm release wasn't installed with its
  ServiceMonitor enabled. The current dashboard uses kubelet's generic `kubelet_volume_stats_*` PVC
  metrics instead, which work out of the box but are less detailed than Longhorn's own.

## Why the admission webhook is routed through cert-manager, not a Job

kube-prometheus-stack's default TLS cert generation for the Prometheus Operator's admission webhook uses a
Helm PreSync hook Job (`kube-webhook-certgen`) — the exact same pattern that got `ingress-nginx` stuck in a
fast-reconcile loop on this cluster's first bootstrap (see `docs/cluster-admin.md`, "Forcing a stuck
sync"). Since cert-manager is already running here, `monitoring.yml` sets
`prometheusOperator.admissionWebhooks.certManager.enabled: true` to sidestep the Job-based path entirely
before it could cause the same problem.

## Alertmanager

Installed with default rules/receivers (i.e. none configured — alerts fire into Alertmanager's UI but
nothing is set up to actually notify anyone, no Slack/email/etc.). Access via:
```bash
kubectl -n monitoring port-forward svc/monitoring-kube-prometheus-alertmanager 9093:9093
```
Configuring real notification receivers is a follow-up, not done here.
