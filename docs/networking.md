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

The Helm chart installs the MetalLB controller and speaker but does **not** create an IP pool. You must apply these manually after Helm deploys MetalLB:

```yaml
# infrastructure/metallb/ip-address-pool.yml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: homelab-pool
  namespace: metallb-system
spec:
  addresses:
    - 192.168.1.200-192.168.1.220   # adjust to a free range on your LAN
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

```bash
kubectl apply -f infrastructure/metallb/ip-address-pool.yml
```

### Verifying

```bash
kubectl get ipaddresspool,l2advertisement -n metallb-system
kubectl get svc -A | grep LoadBalancer
```

If a `LoadBalancer` service is stuck in `<pending>`, `IPAddressPool` is missing or has no free IPs.

### IP range planning

Pick a range outside your router's DHCP range to avoid conflicts. Example with a typical home router DHCP pool of `192.168.1.2–192.168.1.150`:

```
MetalLB pool: 192.168.1.200–192.168.1.220
```

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
    cert-manager.io/cluster-issuer: letsencrypt-prod
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

cert-manager automates TLS certificate provisioning.

### ClusterIssuers

After cert-manager is deployed, create issuers. For a homelab, two options:

**Self-signed CA (works offline, no public domain needed):**
```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned
spec:
  selfSigned: {}
```

**Let's Encrypt (requires a public domain + DNS challenge or port 80 open):**
```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: your@email.com
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
      - http01:
          ingress:
            class: nginx
```

```bash
# Verify issuer is Ready
kubectl get clusterissuer
kubectl describe certificate my-app-tls -n my-namespace
```
