# Day 2 Operations

## Upgrading Kubernetes

Kubernetes supports upgrading one minor version at a time (e.g., 1.31 → 1.32).

### 1. Update the target version

In `ansible/group_vars/all.yml`:
```yaml
kubernetes_version: "1.32"
```

### 2. Upgrade the control plane

```bash
# SSH into control plane
ssh ubuntu@192.168.1.101

# Upgrade kubeadm
sudo apt-get update
sudo apt-get install -y kubeadm=1.32.*
sudo apt-mark hold kubeadm

# Verify
kubeadm version

# Plan the upgrade
sudo kubeadm upgrade plan

# Apply
sudo kubeadm upgrade apply v1.32.x

# Upgrade kubelet and kubectl
sudo apt-get install -y kubelet=1.32.* kubectl=1.32.*
sudo apt-mark hold kubelet kubectl
sudo systemctl daemon-reload
sudo systemctl restart kubelet
```

### 3. Upgrade each worker (one at a time)

```bash
# From your local machine — drain the node
kubectl drain ser5-worker-1 --ignore-daemonsets --delete-emptydir-data

# SSH into worker
ssh ubuntu@192.168.1.102
sudo apt-get update
sudo apt-get install -y kubeadm=1.32.* kubelet=1.32.* kubectl=1.32.*
sudo apt-mark hold kubeadm kubelet kubectl
sudo kubeadm upgrade node
sudo systemctl daemon-reload
sudo systemctl restart kubelet

# From local — uncordon
kubectl uncordon ser5-worker-1
```

Repeat for `ser5-worker-2`.

---

## Rotating Kubernetes Certificates

Certificates created by kubeadm expire after 1 year. Check expiry:

```bash
ssh ubuntu@192.168.1.101
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

Then re-fetch the kubeconfig locally:
```bash
scp ubuntu@192.168.1.101:/etc/kubernetes/admin.conf clusters/homelab/kubeconfig
```

---

## Adding a Worker Node

1. Provision a new VM via Terraform (add an entry to the `nodes` variable)
2. Run Ansible against the new node only:
   ```bash
   ansible-playbook playbooks/bootstrap.yml --limit <new-node-name>
   ```
3. The worker role generates a fresh join token and joins the node automatically

---

## Removing a Worker Node

```bash
# Drain
kubectl drain ser5-worker-2 --ignore-daemonsets --delete-emptydir-data --force

# Delete from cluster
kubectl delete node ser5-worker-2

# Destroy the VM
cd terraform/proxmox
terraform destroy -target module.worker[\"ser5-worker-2\"]
```

Longhorn will rebuild replicas on the remaining nodes after removal.

---

## Rebooting a Node

Always drain before rebooting to avoid disruption:

```bash
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data
ssh ubuntu@<node-ip> sudo reboot
# Wait for node to come back
kubectl uncordon <node>
```

---

## Backing Up etcd

kubeadm clusters store all cluster state in etcd on the control plane.

```bash
ssh ubuntu@192.168.1.101

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
scp ubuntu@192.168.1.101:/tmp/etcd-backup-$(date +%Y%m%d).db ./backups/
```

---

## Rebuilding the Cluster from Scratch

```bash
# Destroy VMs
cd terraform/proxmox && terraform destroy

# Re-provision
terraform apply

# Re-bootstrap
cd ../../ansible
ansible-playbook playbooks/bootstrap.yml

# Re-apply ArgoCD
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl apply -f clusters/homelab/bootstrap/app-of-apps.yml
```

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
