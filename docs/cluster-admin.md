# Cluster Admin Guide

How to actually connect to and operate the homelab cluster day-to-day. For specific maintenance
procedures (upgrades, backups, node add/remove) see `docs/day2-operations.md`; for GitOps workflow see
`docs/argocd-gitops.md`.

## Prerequisites: network access

The cluster lives on the isolated `10.10.10.0/24` LAN behind the GL.iNet Opal. From the jumpbox (Mac),
you need one of:

- **On the Opal's own LAN** (physically connected or on its Wi-Fi) — nothing else needed.
- **On the home network** — bring up the WireGuard tunnel first:
  ```bash
  sudo wg-quick up ~/.wireguard-homelab/mac-jumpbox.conf
  ```
  See `bare-metal/README.md`, "Tunnel WireGuard pour le jumpbox", for initial setup if this doesn't exist
  yet. Tear down with `sudo wg-quick down ~/.wireguard-homelab/mac-jumpbox.conf` when done.

Verify either way with `ping 10.10.10.1` (the Opal) before troubleshooting anything else.

## Connecting with kubectl

The admin kubeconfig is fetched to `clusters/homelab/kubeconfig` by Ansible's control-plane role (gitignored
— it's a live cluster-admin credential, never commit it). Point `KUBECONFIG` at it:

```bash
export KUBECONFIG=/path/to/k8s-homelab/clusters/homelab/kubeconfig
kubectl get nodes
```

Or merge it into your default `~/.kube/config` if you prefer not to export the var every session:
```bash
KUBECONFIG=~/.kube/config:/path/to/k8s-homelab/clusters/homelab/kubeconfig kubectl config view --flatten > /tmp/merged && mv /tmp/merged ~/.kube/config
kubectl config use-context kubernetes-admin@kubernetes
```

If this file is missing or you suspect it's stale (e.g. after `kubeadm certs renew`), re-fetch it — see
`docs/ansible.md` or `docs/day2-operations.md` ("Rotating Kubernetes Certificates").

Note: `kubectl get nodes` shows `host1.lab.local` / `host2.lab.local` / `host3.lab.local` — the OS
hostname kubelet registers under, not the bare `host1`/`host2`/`host3` used elsewhere in this repo
(Ansible inventory, `hosts.csv`). Any `kubectl label`/`taint`/`describe node` command needs the
`.lab.local` suffix.

## SSH to the hosts directly

```bash
ssh -i ~/.ssh/id_ed25519_homelab foo@10.10.10.10   # host1, control-plane
ssh -i ~/.ssh/id_ed25519_homelab foo@10.10.10.20   # host2, worker
ssh -i ~/.ssh/id_ed25519_homelab foo@10.10.10.30   # host3, worker
```

`foo` is the kickstart-created user (root login is locked, key-only auth, passwordless sudo via
`%wheel`). Add an SSH config `Host` block if typing the key path every time is annoying:

```
Host host1 host2 host3
  User foo
  IdentityFile ~/.ssh/id_ed25519_homelab
```

Prefer fixing things through the repo (Ansible/manifests) and redeploying over ad hoc SSH changes — see
the homelab-engineer skill's "Prefer changes that go through the repo" guidance. If you do SSH in to fix
something urgently, also update the corresponding file and redeploy, or note clearly that you didn't.

The Opal itself (router) is separate: `ssh -i ~/.ssh/id_rsa_opal root@10.10.10.1` — note this is a
**different key** than the one used for the hosts. The Opal's dropbear SSH server has no Ed25519 support,
only RSA.

## ArgoCD

### UI

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:443
```
Open https://localhost:8080. Username `admin`, password:
```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d && echo
```
(Also available as `terraform -chdir=terraform/cluster-bootstrap output -raw argocd_admin_password_command`.)
Change the password and delete this secret after first login — see `docs/argocd-gitops.md`.

### CLI

Two ways to use the `argocd` CLI (`brew install argocd`):

1. **Against the port-forward above**: `argocd login localhost:8080 --username admin --insecure`
2. **`--core` mode** — talks directly to the K8s API using your current kubectl context, no port-forward
   or login needed. Simpler for one-off admin commands:
   ```bash
   kubectl config set-context --current --namespace=argocd   # argocd CLI --core expects this
   argocd app list --core
   argocd app get cilium --core
   argocd app sync ingress-nginx --core
   ```

### Forcing a stuck sync

Applications occasionally get stuck mid-sync (a Helm hook Job that hasn't been observed as complete yet,
a resource-cache hiccup after the controller was recently restarted, etc.) — this happened during initial
bootstrap with `ingress-nginx` and `longhorn`'s pre-install hook Jobs. Before intervening, check whether
it's just legitimately still running (`argocd app get <name> --core` shows the current operation phase/
message) — repeatedly cancelling and re-triggering a sync that's mid-hook can itself cause thrashing
(observed first-hand: interrupting `ingress-nginx`'s admission-webhook Job before it could finish kept
resetting it into a create/delete loop). If it's genuinely stuck (no progress for several minutes, message
unchanged):

```bash
argocd app terminate-op <name> --core
argocd app sync <name> --core --timeout 240
```

If that doesn't help, a controller restart clears any stale in-memory resource cache:
```bash
kubectl -n argocd rollout restart statefulset/argocd-application-controller
```

## Quick health check

```bash
kubectl get nodes                                    # all should be Ready
kubectl -n argocd get applications                    # all should be Synced/Healthy
kubectl -n kube-system get pods -l k8s-app=cilium      # 1/1 Running on every node
cilium status --brief 2>/dev/null || kubectl -n kube-system exec ds/cilium -- cilium-dbg status --brief
kubectl -n metallb-system get ipaddresspool,l2advertisement
kubectl -n longhorn-system get nodes.longhorn.io
kubectl get svc -A | grep LoadBalancer                 # should have IPs from 10.10.10.250-253, not <pending>
kubectl -n monitoring get pods                          # Prometheus/Grafana/Alertmanager, all Running
```

## Monitoring

Prometheus + Grafana (`kube-prometheus-stack`) — see `docs/monitoring.md` for access (Ingress vs
port-forward, admin password retrieval) and the custom "Homelab Overview" dashboard.

## Prod / stage namespaces

Two namespaces, isolated via ArgoCD `AppProject`s (`clusters/homelab/bootstrap/projects.yml`) — an
Application in the `stage` project cannot deploy into `prod` or vice versa:

```bash
kubectl get ns prod stage
kubectl -n argocd get appprojects
kubectl -n prod get all
kubectl -n stage get all
```

Deploying a workload goes through `apps/prod/` or `apps/stage/` in git, not `kubectl apply` directly — see
`apps/README.md` and `docs/argocd-gitops.md`.
