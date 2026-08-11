# k8s-homelab

A self-hosted Kubernetes cluster running on bare-metal mini PCs, managed entirely with Infrastructure as Code.

## Hardware

| Node | Host | CPU | RAM | Role |
|------|------|-----|-----|------|
| `n150-cp` | Intel N150 | 3 vCPU | 10 GB | Control plane |
| `ser5-worker-1` | AMD Ryzen 5500U | 10 vCPU | 28 GB | Worker |
| `ser5-worker-2` | AMD Ryzen 5500U | 10 vCPU | 28 GB | Worker |

> Table above is the original template target (Proxmox + VMs). Actual
> current fleet is 3 bare-metal Rocky Linux 9 hosts (host1/host2/host3),
> no hypervisor anywhere - see the Note below.

## Stack

| Layer | Technology |
|-------|-----------|
| Hypervisor | ~~Proxmox VE~~ none - bare-metal (see Note below) |
| OS | Rocky Linux 9 (kickstart, bare-metal) |
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
├── bare-metal/             # PXE provisioning via a GL.iNet Opal (Rocky kickstart, all 3 hosts)
│   ├── router/             # GL.iNet Opal config (dnsmasq DHCP/TFTP + iPXE chainload)
│   └── kickstart/          # Rocky Linux 9 kickstarts, one per host
├── terraform/proxmox/      # Provision VMs on Proxmox (currently unused - see Note)
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

> **Note**: this repo's stack was designed for Proxmox VE on every node with
> K8s running in VMs (Terraform provisions the VMs, Ansible bootstraps
> kubeadm inside them). The actual fleet ended up fully bare-metal instead -
> `host1`, `host2`, `host3` all run Rocky Linux 9 directly, provisioned via
> [`bare-metal/`](bare-metal/) (PXE + kickstart through a GL.iNet Opal, no
> hypervisor, no VMs). We tried Proxmox on host1/host3 first but the
> Proxmox auto-installer's netboot path (huge initrd, needs local USB
> staging on the Opal, more failure modes) turned out more fragile than
> Rocky/Anaconda's - see `bare-metal/README.md` for the full story.
>
> Practical consequence: `terraform/proxmox/` is currently unused - there's
> no Proxmox host left to provision VMs on. `ansible/` still applies in
> spirit (containerd + kubeadm bootstrap), but its `inventory/hosts.yml`
> and any Proxmox-specific assumptions need to point at the 3 bare-metal
> IPs (`10.10.10.10/20/30` on the provisioning subnet, or wherever they
> end up on the main LAN) instead of VM IPs. Not yet done.

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
| [`bare-metal/README.md`](bare-metal/README.md) | PXE/kickstart provisioning for bare-metal nodes via the GL.iNet Opal |
| [`docs/architecture.md`](docs/architecture.md) | Full architecture diagrams |
| [`docs/proxmox-setup.md`](docs/proxmox-setup.md) | Manual Proxmox prep steps |
| [`docs/terraform.md`](docs/terraform.md) | Terraform variable reference |
| [`docs/ansible.md`](docs/ansible.md) | Ansible roles and playbook details |
| [`docs/argocd-gitops.md`](docs/argocd-gitops.md) | GitOps workflow and ArgoCD usage |
| [`docs/networking.md`](docs/networking.md) | CNI, MetalLB, and ingress setup |
| [`docs/storage.md`](docs/storage.md) | Longhorn storage configuration |
| [`docs/day2-operations.md`](docs/day2-operations.md) | Upgrades, backups, common ops |
