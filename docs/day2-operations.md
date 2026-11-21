# Day 2 Operations

All commands below assume you're on the jumpbox with the WireGuard tunnel up (`bare-metal/README.md`) and
`cd`'d into `ansible/` or the repo root as noted.

## Upgrading Kubernetes

Kubernetes supports upgrading one minor version at a time (e.g., 1.31 → 1.32).

### 1. Update the target version

In `ansible/group_vars/all.yml`:
```yaml
kubernetes_version: "1.32"
```

### 2. Upgrade the control plane (host2)

```bash
ssh -i ~/.ssh/id_ed25519_homelab foo@10.10.10.20

# Update the repo to the new minor version (already done via group_vars + Ansible)
# Or manually edit /etc/yum.repos.d/kubernetes.repo baseurl to v1.32

# Upgrade kubeadm
sudo dnf install -y --disableexcludes=kubernetes kubeadm-1.32.*
sudo dnf versionlock delete kubeadm
sudo dnf versionlock add kubeadm

# Verify
kubeadm version

# Plan the upgrade
sudo kubeadm upgrade plan

# Apply
sudo kubeadm upgrade apply v1.32.x

# Upgrade kubelet and kubectl
sudo dnf install -y --disableexcludes=kubernetes kubelet-1.32.* kubectl-1.32.*
sudo dnf versionlock delete kubelet kubectl
sudo dnf versionlock add kubelet kubectl
sudo systemctl daemon-reload
sudo systemctl restart kubelet
```

### 3. Upgrade each worker (one at a time)

```bash
# From your local machine — drain the node
kubectl drain host1.lab.local --ignore-daemonsets --delete-emptydir-data

# SSH into the worker
ssh -i ~/.ssh/id_ed25519_homelab foo@10.10.10.10
sudo dnf install -y --disableexcludes=kubernetes kubeadm-1.32.* kubelet-1.32.* kubectl-1.32.*
sudo dnf versionlock delete kubeadm kubelet kubectl
sudo dnf versionlock add kubeadm kubelet kubectl
sudo kubeadm upgrade node
sudo systemctl daemon-reload
sudo systemctl restart kubelet

# From local — uncordon
kubectl uncordon host1.lab.local
```

Repeat for `host3` (10.10.10.30). host1 is also the Tailscale subnet router — draining it doesn't touch
Tailscale (a host service, not a pod), but rebooting it drops remote access via Tailscale until it's back.

---

## Rotating Kubernetes Certificates

Certificates created by kubeadm expire after 1 year. Check expiry:

```bash
ssh -i ~/.ssh/id_ed25519_homelab foo@10.10.10.20
sudo kubeadm certs check-expiration
```

Renew all certs:
```bash
sudo kubeadm certs renew all
sudo systemctl restart kubelet

# Regenerate kubeconfig (new cert embedded)
sudo cp /etc/kubernetes/admin.conf /etc/kubernetes/admin.conf.bak
sudo kubeadm kubeconfig user --client-name admin > /tmp/admin.conf
sudo mv /tmp/admin.conf /etc/kubernetes/admin.conf
```

Then re-fetch the kubeconfig locally. The control-plane role does this and rewrites `server:` from
`k8s-api.lab.local` to the control-plane IP (the Mac has no `/etc/hosts` entry for the name):
```bash
cd ansible && ansible-playbook playbooks/bootstrap.yml --tags control-plane
```
A plain `scp` of `admin.conf` also works, but then fix the `server:` line by hand
(`https://10.10.10.20:6443`) or add `10.10.10.20 k8s-api.lab.local` to the Mac's `/etc/hosts`.

---

## Adding a Worker Node

There's no VM layer to provision through Terraform anymore — a new node means new physical hardware:

1. Add the host to `bare-metal/hosts.csv`, `bare-metal/router/dnsmasq-provisioning.conf`, and
   `bare-metal/router/boot.ipxe` (MAC/IP, kept in sync manually — see `bare-metal/README.md`), plus a new
   `bare-metal/kickstart/ks-hostN.cfg`. Redeploy with `./bare-metal/router/deploy-opal.sh 10.10.10.1` and
   PXE-boot the new machine.
2. Add it to `ansible/inventory/hosts.yml` (under `workers`) and a matching `ansible/host_vars/hostN.yml`
   (poll real hardware first — `lsblk`/`vgs` — don't guess the Longhorn LV size).
3. Run Ansible against the new node only:
   ```bash
   ansible-playbook playbooks/bootstrap.yml --limit hostN
   ```
4. The worker role generates a fresh join token and joins the node automatically.

---

## Removing a Worker Node

```bash
# Drain
kubectl drain host3 --ignore-daemonsets --delete-emptydir-data --force

# Delete from cluster
kubectl delete node host3
```

There's no `terraform destroy` step — the physical machine keeps existing, it's just no longer in the
cluster. If it's leaving the fleet entirely, remove its entries from `bare-metal/hosts.csv`,
`dnsmasq-provisioning.conf`, `boot.ipxe`, and `ansible/inventory/hosts.yml` (see `bare-metal/README.md`'s
comment-vs-delete convention for the PXE dispatch entries).

Longhorn will rebuild replicas on the remaining nodes after removal.

---

## Rebooting a Node

Always drain before rebooting to avoid disruption:

```bash
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data
ssh -i ~/.ssh/id_ed25519_homelab foo@<host-ip> sudo reboot
# Wait for node to come back
kubectl uncordon <node>
```

Verify the host's boot order still prioritizes the local disk before rebooting anything with PXE enabled
— `bare-metal/README.md` documents the host2 reinstall-loop incident this caused once already.

---

## Backing Up etcd

kubeadm clusters store all cluster state in etcd on the control plane (host2).

```bash
ssh -i ~/.ssh/id_ed25519_homelab foo@10.10.10.20

sudo ETCDCTL_API=3 etcdctl snapshot save /tmp/etcd-backup-$(date +%Y%m%d).db \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key

# Verify
sudo ETCDCTL_API=3 etcdctl snapshot status /tmp/etcd-backup-$(date +%Y%m%d).db --write-out=table
```

Copy the snapshot off the node:
```bash
scp -i ~/.ssh/id_ed25519_homelab foo@10.10.10.20:/tmp/etcd-backup-$(date +%Y%m%d).db ./backups/
```

---

## Rebuilding the Cluster from Scratch

There's no VM layer to tear down/recreate — "from scratch" means re-running kubeadm on the same hosts:

```bash
# Reset kubeadm state on every host (control plane first, then workers)
ssh -i ~/.ssh/id_ed25519_homelab foo@10.10.10.20 sudo kubeadm reset -f   # host2, control-plane
ssh -i ~/.ssh/id_ed25519_homelab foo@10.10.10.10 sudo kubeadm reset -f   # host1, worker
ssh -i ~/.ssh/id_ed25519_homelab foo@10.10.10.30 sudo kubeadm reset -f   # host3, worker

# Re-bootstrap
cd ansible
ansible-playbook playbooks/bootstrap.yml

# Re-install ArgoCD + reapply the bootstrap manifests
cd ../terraform/cluster-bootstrap
terraform apply
```

If you actually want to wipe a host back to bare Rocky (not just reset kubeadm), that goes through
`bare-metal/` — re-enable its PXE dispatch (see the comment-vs-delete convention in
`bare-metal/README.md`) and reboot it into PXE. This wipes the disk, so only do this deliberately.

---

## Checking Node Resource Usage

```bash
kubectl top nodes
kubectl top pods -A --sort-by=memory
```

Requires metrics-server. Install via ArgoCD if not present:

```yaml
# clusters/homelab/infrastructure/metrics-server.yml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: metrics-server
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://kubernetes-sigs.github.io/metrics-server
    chart: metrics-server
    targetRevision: "3.12.*"
    helm:
      valuesObject:
        args:
          - --kubelet-insecure-tls   # needed for kubeadm clusters without proper kubelet TLS
  destination:
    server: https://kubernetes.default.svc
    namespace: kube-system
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```
