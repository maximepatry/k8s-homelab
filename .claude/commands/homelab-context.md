You are troubleshooting a Kubernetes homelab. Read this entire document before taking any action.

---

## Cluster Overview

Single control-plane kubeadm cluster running on Proxmox VMs. Three physical machines, each running Proxmox VE as the hypervisor. Cilium replaces kube-proxy entirely.

---

## Physical Hardware

| Host | CPU | RAM | Role |
|------|-----|-----|------|
| n150 | Intel N150 (4 E-cores) | 15 GB | Proxmox host → control-plane VM |
| ser5-1 | AMD Ryzen 5 5500U (6c/12t) | 32 GB | Proxmox host → worker VM |
| ser5-2 | AMD Ryzen 5 5500U (6c/12t) | 32 GB | Proxmox host → worker VM |

Storage: SATA SSD on each SER5. Workers each have two virtual disks:
- `/dev/sda` — OS (60 GB, thin LVM)
- `/dev/sdb` — Longhorn data (raw, unformatted, ~400 GB, managed by Longhorn directly)

---

## VM / Kubernetes Node Layout

| Node name | IP | Kubernetes role |
|-----------|-----|----------------|
| n150-cp | 192.168.1.101 | control-plane |
| ser5-worker-1 | 192.168.1.102 | worker |
| ser5-worker-2 | 192.168.1.103 | worker |

Gateway: `192.168.1.1`. SSH user: `rocky`. kubeconfig is fetched to `clusters/homelab/kubeconfig` by Ansible.

---

## Stack Components

| Component | Namespace | How deployed | Purpose |
|-----------|-----------|-------------|---------|
| kubeadm | — | Ansible | Cluster bootstrap |
| Cilium 1.16.x | kube-system | ArgoCD / Helm | CNI + kube-proxy replacement + NetworkPolicy |
| Hubble | kube-system | Cilium subchart | Network observability UI |
| MetalLB 0.14.x | metallb-system | ArgoCD / Helm | L2 LoadBalancer for bare-metal |
| Longhorn 1.7.x | longhorn-system | ArgoCD / Helm | Distributed block storage, replica count 2 |
| cert-manager v1.16.x | cert-manager | ArgoCD / Helm | TLS certificate management |
| ingress-nginx 4.11.x | ingress-nginx | ArgoCD / Helm | Ingress controller, gets MetalLB IP |
| ArgoCD | argocd | Manual bootstrap | GitOps, manages all the above via app-of-apps |

Pod CIDR: `10.244.0.0/16`. Service CIDR: `10.96.0.0/12`.

---

## Repository Structure

```
k8s-homelab/
├── terraform/proxmox/          # Proxmox VM provisioning (bpg/proxmox ~0.66)
│   └── modules/{control-plane,worker}/
├── ansible/
│   ├── inventory/hosts.yml     # static IPs for all 3 nodes
│   ├── group_vars/
│   │   ├── all.yml             # k8s version, CIDRs, cluster name
│   │   ├── control_plane.yml
│   │   └── workers.yml         # longhorn_data_disk: /dev/sdb
│   ├── roles/
│   │   ├── common/             # swap off, kernel modules (overlay, br_netfilter), sysctl, open-iscsi
│   │   ├── containerd/         # containerd with SystemdCgroup=true
│   │   ├── kubeadm/            # install + hold kubelet/kubeadm/kubectl
│   │   ├── control-plane/      # kubeadm init --skip-phases=addon/kube-proxy
│   │   └── worker/             # kubeadm join
│   └── playbooks/bootstrap.yml # single entrypoint: common → control-plane → workers
├── clusters/homelab/
│   ├── bootstrap/
│   │   ├── argocd-install.yml  # applied manually once
│   │   └── app-of-apps.yml     # root ArgoCD Application, points at clusters/homelab/infrastructure/
│   ├── infrastructure/         # ArgoCD Application manifests (one per component above)
│   └── kubeconfig              # fetched by Ansible, gitignored
└── .gitignore                  # secrets/, *.key, *.tfstate, kubeconfig
```

---

## Known Quirks and Gotchas

**N150 and etcd latency**
The N150 has efficiency-only cores with lower single-thread IPC. If you see etcd leader elections, slow API responses, or `context deadline exceeded` from the control plane, suspect I/O latency on the control-plane VM's disk before anything else. Check with `etcdctl endpoint health` and `etcdctl endpoint status`.

**Cilium replaces kube-proxy**
`kubeadm init` was run with `--skip-phases=addon/kube-proxy`. There is no kube-proxy DaemonSet. Service routing is handled entirely by Cilium eBPF. If services are unreachable, do not look for kube-proxy — check `cilium status` and Hubble flows instead.

**Longhorn data disk is raw**
`/dev/sdb` on each worker is never formatted or mounted by the OS. Longhorn manages it directly. If Longhorn reports a disk as unavailable, check that the VM still has the second virtual disk attached in Proxmox, not that it's mounted in the OS.

**MetalLB L2 mode**
MetalLB is in L2 mode. You need to configure an `IPAddressPool` and `L2Advertisement` CR after install (not done by Helm values). If LoadBalancer services are stuck in `<pending>`, check these CRs first: `kubectl get ipaddresspool,l2advertisement -n metallb-system`.

**ArgoCD app-of-apps sync order**
Cilium must be healthy before other components that need pod networking. If a fresh cluster has everything OutOfSync, apply/sync Cilium first, wait for nodes to be Ready, then sync the rest.

**containerd SystemdCgroup**
The Ansible role patches `SystemdCgroup = true` in `/etc/containerd/config.toml`. If you ever manually reinstall containerd and regenerate the config, this setting will revert to `false` and kubelet will fail to start with a cgroup driver mismatch.

**SELinux is permissive, not disabled**
Rocky Linux 9 ships with SELinux enforcing. The Ansible `common` role sets it to `permissive`. This logs violations without blocking — useful for seeing what would break. Do not set it to `disabled` (requires reboot and relabeling); `permissive` is the right homelab setting.

**firewalld is disabled**
Rocky Linux 9 enables firewalld by default. It conflicts with Cilium's eBPF packet processing. Ansible disables and stops it on all nodes. If you see dropped packets or unreachable services, verify `systemctl status firewalld` is inactive before blaming Cilium.

**Package manager is dnf, not apt**
All package operations use `dnf`. Kubernetes packages are pinned via `dnf versionlock` (not `apt-mark hold`). containerd comes from Docker CE's centos yum repo.

---

## Troubleshooting Cheatsheet

### Cluster access
```bash
export KUBECONFIG=clusters/homelab/kubeconfig
kubectl get nodes -o wide
```

### Node-level SSH
```bash
ssh rocky@192.168.1.101   # control-plane
ssh rocky@192.168.1.102   # worker-1
ssh rocky@192.168.1.103   # worker-2
```

### Cilium
```bash
cilium status
cilium connectivity test
hubble observe --follow
kubectl -n kube-system exec ds/cilium -- cilium-dbg status
```

### etcd (run on control-plane node)
```bash
etcdctl --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/peer.crt \
  --key=/etc/kubernetes/pki/etcd/peer.key \
  endpoint health
```

### Longhorn
```bash
kubectl -n longhorn-system get nodes.longhorn.io
kubectl -n longhorn-system get volumes
# UI available via port-forward:
kubectl -n longhorn-system port-forward svc/longhorn-frontend 8080:80
```

### ArgoCD
```bash
kubectl -n argocd get applications
kubectl -n argocd port-forward svc/argocd-server 8080:443
# Get initial admin password:
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
```

### MetalLB
```bash
kubectl get ipaddresspool,l2advertisement -n metallb-system
kubectl get svc -A | grep LoadBalancer
```

### Rerun Ansible (idempotent)
```bash
cd ansible
ansible-playbook playbooks/bootstrap.yml
# Single role only:
ansible-playbook playbooks/bootstrap.yml --tags containerd
```

### Terraform
```bash
cd terraform/proxmox
terraform plan
terraform apply
```

---

## Deployment Sequence (fresh cluster)

1. `terraform apply` — VMs created on Proxmox
2. `ansible-playbook ansible/playbooks/bootstrap.yml` — OS + kubeadm bootstrap, kubeconfig written to `clusters/homelab/kubeconfig`
3. `kubectl apply -f clusters/homelab/bootstrap/argocd-install.yml` — namespace + ArgoCD install
4. Wait for ArgoCD pods Ready
5. `kubectl apply -f clusters/homelab/bootstrap/app-of-apps.yml` — triggers GitOps sync of all infrastructure
6. Sync Cilium first, wait for nodes Ready, then sync remaining apps
7. Create MetalLB `IPAddressPool` and `L2Advertisement` CRs for your LAN subnet
