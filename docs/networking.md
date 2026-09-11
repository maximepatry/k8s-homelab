# Networking

## Cilium (CNI)

Cilium replaces both the CNI plugin and kube-proxy. It uses eBPF for packet processing instead of iptables.

### Why kube-proxy is absent

`kubeadm init` was run with `--skip-phases=addon/kube-proxy`. There is **no kube-proxy DaemonSet** in this cluster. If you look for it you won't find it — this is expected.

Cilium is deployed with `kubeProxyReplacement: true`, which activates its full service routing stack. All `ClusterIP`, `NodePort`, and `LoadBalancer` traffic is handled by Cilium's eBPF programs.

### Hubble (observability)

Hubble is enabled and provides network flow visibility:

```bash
# CLI (install hubble CLI: https://docs.cilium.io/en/stable/observability/hubble/setup/)
hubble observe --follow
hubble observe --namespace my-namespace
hubble observe --pod my-pod --verdict DROPPED

# UI (port-forward)
kubectl -n kube-system port-forward svc/hubble-ui 12000:80
# Open http://localhost:12000
```

### Checking Cilium health

```bash
# Summary
cilium status

# Full connectivity test (creates test pods, verifies pod-to-pod, pod-to-svc, etc.)
cilium connectivity test

# From inside a Cilium pod
kubectl -n kube-system exec ds/cilium -- cilium-dbg status
kubectl -n kube-system exec ds/cilium -- cilium-dbg endpoint list
```

### Network Policies

Cilium enforces standard Kubernetes `NetworkPolicy` resources and its own extended `CiliumNetworkPolicy` CRD, which supports L7 policies (HTTP, gRPC, DNS).

---

## MetalLB (LoadBalancer)

MetalLB runs in **L2 mode**, which means it responds to ARP requests for LoadBalancer IPs on behalf of the cluster. No BGP router is needed.

### Required post-Helm CRs

The Helm chart installs the MetalLB controller and speaker but does **not** create an IP pool by itself.
`clusters/homelab/infrastructure/metallb-pool.yml` (a separate ArgoCD Application, synced one wave after
`metallb.yml` so the CRDs exist first) applies:

```yaml
# clusters/homelab/infrastructure/metallb-pool/ip-address-pool.yml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: homelab-pool
  namespace: metallb-system
spec:
  addresses:
    - 10.10.10.250-10.10.10.253
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: homelab-l2
  namespace: metallb-system
spec:
  ipAddressPools:
    - homelab-pool
```

This is applied automatically by ArgoCD (see `docs/argocd-gitops.md`), not manually.

### Verifying

```bash
kubectl get ipaddresspool,l2advertisement -n metallb-system
kubectl get svc -A | grep LoadBalancer
```

If a `LoadBalancer` service is stuck in `<pending>`, `IPAddressPool` is missing or has no free IPs.

### IP range planning

Pick a range outside the Opal's DHCP pool to avoid conflicts. The Opal's DHCP range is
`10.10.10.2-249` (`bare-metal/router/dnsmasq-provisioning.conf`), so the MetalLB pool uses the tail end
outside it:

```
MetalLB pool: 10.10.10.250-10.10.10.253
```

Only 4 addresses — plenty for a homelab's worth of LoadBalancer services (ingress-nginx being the main
one), but if you outgrow it, shrinking the Opal's DHCP range (`10.10.10.2-249` → e.g. `10.10.10.2-199`)
via its LAN settings frees up more room at the top for MetalLB.

---

## Ingress (ingress-nginx)

ingress-nginx gets a `LoadBalancer` IP from MetalLB. All HTTP/HTTPS traffic enters the cluster through this single IP.

```bash
# Get the assigned IP
kubectl -n ingress-nginx get svc ingress-nginx-controller
```

### Exposing an application

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: my-app
  annotations:
    cert-manager.io/cluster-issuer: homelab-ca   # see "cert-manager" below
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - my-app.homelab.local
      secretName: my-app-tls
  rules:
    - host: my-app.homelab.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: my-app
                port:
                  number: 80
```

### Local DNS

For `.homelab.local` domains to resolve on your LAN, either:
- Add entries to your router's DNS (preferred)
- Add entries to `/etc/hosts` on each client machine
- Run a local DNS resolver (Pi-hole, AdGuard Home, CoreDNS outside the cluster)

---

## cert-manager

cert-manager automates TLS certificate provisioning. `*.homelab.local` isn't a real, delegated domain, so
Let's Encrypt is off the table — no HTTP-01 (nothing on the public internet can reach these hosts) and no
DNS-01 (no real DNS zone to put a challenge TXT record in). This cluster uses a **private internal CA**
instead, set up via `clusters/homelab/infrastructure/cert-manager-ca.yml` (Application) and
`clusters/homelab/infrastructure/cert-manager-ca/ca.yml` (the actual resources):

1. `homelab-ca-bootstrap` — a throwaway `selfSigned` `ClusterIssuer`, exists only to sign the next step
2. `homelab-ca` — a `Certificate` with `isCA: true`, signed by the bootstrap issuer; its key/cert land in
   the `homelab-ca-secret` Secret (`cert-manager` namespace), 10-year lifetime
3. `homelab-ca` — the real `ClusterIssuer` every Ingress uses, backed by that CA secret:
   ```yaml
   apiVersion: cert-manager.io/v1
   kind: ClusterIssuer
   metadata:
     name: homelab-ca
   spec:
     ca:
       secretName: homelab-ca-secret
   ```

Any Ingress with `cert-manager.io/cluster-issuer: homelab-ca` plus a `tls:` block (see "Exposing an
application" above) gets a leaf certificate signed by this root automatically — cert-manager handles
renewal, nothing to do manually per-app. Grafana (`clusters/homelab/infrastructure/monitoring.yml`) and
Homepage (`apps/prod/homepage/ingress.yaml`) are both wired to it already.

### Trusting the homelab CA

Without importing the root, browsers still show "not private"/"not trusted" — the cert chain is valid,
your device just doesn't know this root yet. One-time fix per device:

```bash
kubectl -n cert-manager get secret homelab-ca-secret -o jsonpath='{.data.ca\.crt}' | base64 -d > homelab-ca.crt

# macOS: add to the login keychain and trust it for SSL
security add-trusted-cert -d -r trustRoot -k ~/Library/Keychains/login.keychain-db homelab-ca.crt
```

(On iOS/Android, AirDrop or otherwise transfer `homelab-ca.crt` and install it as a trusted root via
Settings — exact steps vary by OS version.) Do this once per device you browse `*.homelab.local` from;
every current and future service behind `homelab-ca` is then trusted, no per-site exception needed.

```bash
# Verify issuer is Ready, and a specific cert has actually been issued
kubectl get clusterissuer
kubectl describe certificate homepage-tls -n prod
```
