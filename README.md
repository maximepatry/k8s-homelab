# k8s-homelab

A self-hosted Kubernetes cluster running on bare-metal mini PCs, managed entirely with Infrastructure as Code.

## Hardware

| Node | Host | CPU | RAM | Role |
|------|------|-----|-----|------|
| `n150-cp` | Intel N150 | 3 vCPU | 10 GB | Control plane |
| `ser5-worker-1` | AMD Ryzen 5500U | 10 vCPU | 28 GB | Worker |
| `ser5-worker-2` | AMD Ryzen 5500U | 10 vCPU | 28 GB | Worker |

Each machine runs **Proxmox VE** as the hypervisor. Kubernetes runs inside VMs provisioned from a **Rocky Linux 9** cloud-init template.

## Stack

| Layer | Technology |
|-------|-----------|
| Hypervisor | Proxmox VE |
| OS | Rocky Linux 9 (cloud-init) |
| Container runtime | containerd |
| Kubernetes | kubeadm 1.31 |
| CNI | Cilium (eBPF) |
| Load balancer | MetalLB (L2) |
| Ingress | ingress-nginx |
| Storage | Longhorn |
| TLS | cert-manager |
| GitOps | ArgoCD (app-of-apps) |
| IaC | Terraform + Ansible |

## Repository Layout

```
.
├── terraform/proxmox/      # Provision VMs on Proxmox
├── ansible/                # Bootstrap OS and kubeadm
│   ├── inventory/
│   ├── group_vars/
│   ├── playbooks/
│   └── roles/              # common, containerd, kubeadm, control-plane, worker
├── clusters/homelab/
│   ├── bootstrap/          # ArgoCD install + app-of-apps root Application
│   └── infrastructure/     # ArgoCD Application manifests (cilium, metallb, …)
├── apps/                   # User workloads (ArgoCD Applications)
├── monitoring/             # Observability stack
└── docs/                   # Detailed runbooks
```

## Getting Started

Provisioning goes through three stages: Proxmox → Terraform → Ansible → ArgoCD.

### 1. Proxmox

Follow [`docs/proxmox-setup.md`](docs/proxmox-setup.md) to:
- Install Proxmox VE on each node
- Create the Terraform API user
- Build the Rocky Linux 9 cloud-init template on each node

### 2. Terraform — provision VMs

```bash
cd terraform/proxmox
cp terraform.tfvars.example terraform.tfvars
# Fill in your Proxmox endpoints, credentials, and SSH key
terraform init
terraform apply
```

See [`docs/terraform.md`](docs/terraform.md) for variable reference.

### 3. Ansible — bootstrap Kubernetes

```bash
cd ansible
# Verify SSH connectivity
ansible -i inventory/hosts.yml all -m ping

# Bootstrap the full cluster
ansible-playbook -i inventory/hosts.yml playbooks/bootstrap.yml
```

This installs containerd, kubeadm, initialises the control plane, and joins the workers.

See [`docs/ansible.md`](docs/ansible.md) for details.

### 4. ArgoCD — GitOps bootstrap

```bash
export KUBECONFIG=clusters/homelab/kubeconfig

# Install ArgoCD
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl -n argocd wait --for=condition=available deploy/argocd-server --timeout=120s

# Set your repo URL in the file, then apply
kubectl apply -f clusters/homelab/bootstrap/app-of-apps.yml
```

ArgoCD will automatically deploy Cilium, MetalLB, Longhorn, cert-manager, and ingress-nginx.

> Sync Cilium first and wait for nodes to be `Ready` before syncing the remaining apps.

See [`docs/argocd-gitops.md`](docs/argocd-gitops.md) for the full bootstrap flow and day-2 operations.

## Network

```
LAN: 192.168.1.0/24

Proxmox hosts:  .10 / .11 / .12
K8s VMs:        .101 (cp) / .102 (worker-1) / .103 (worker-2)

Ingress path:
  LAN → MetalLB IP (L2 ARP) → ingress-nginx → Pods
                                    (eBPF observed by Cilium/Hubble)
```

See [`docs/networking.md`](docs/networking.md) for MetalLB IP pool and Cilium configuration.

## Documentation

| Doc | Contents |
|-----|----------|
| [`docs/architecture.md`](docs/architecture.md) | Full architecture diagrams |
| [`docs/proxmox-setup.md`](docs/proxmox-setup.md) | Manual Proxmox prep steps |
| [`docs/terraform.md`](docs/terraform.md) | Terraform variable reference |
| [`docs/ansible.md`](docs/ansible.md) | Ansible roles and playbook details |
| [`docs/argocd-gitops.md`](docs/argocd-gitops.md) | GitOps workflow and ArgoCD usage |
| [`docs/networking.md`](docs/networking.md) | CNI, MetalLB, and ingress setup |
| [`docs/storage.md`](docs/storage.md) | Longhorn storage configuration |
| [`docs/day2-operations.md`](docs/day2-operations.md) | Upgrades, backups, common ops |
