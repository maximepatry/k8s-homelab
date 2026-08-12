# k8s-homelab

A self-hosted Kubernetes cluster running on bare-metal mini PCs, managed entirely with Infrastructure as Code.

## Hardware

Actual fleet, polled live from each host (`lscpu`, `free -h`, `lsblk`, `dmidecode`) on 2026-08-11 - not
the original VM-template sizing:

| Host | IP | Board / model | CPU | RAM | Disk | NIC |
|------|----|----------------|-----|-----|------|-----|
| `host1` | 10.10.10.10 | Beelink SER-family (board `SER32001`) | AMD Ryzen 7 6800H - 8c/16t, up to 4.79 GHz | 32 GB | 1 TB NVMe (Samsung 970 EVO Plus) | 1 GbE (`eno1`), disabled onboard Wi-Fi (`wlp3s0`) |
| `host2` | 10.10.10.20 | Beelink Mini S-family (board `MINIS13001`) | Intel N150 - 4c/4t, up to 3.6 GHz | 16 GB | 512 GB SATA SSD | 1 GbE (`enp1s0`) |
| `host3` | 10.10.10.30 | generic OEM board (BIOS `5.19`) | AMD Ryzen 7 5800H - 8c/16t, up to 3.2 GHz | 32 GB | 512 GB NVMe SSD | `enp2s0` negotiated at only **100 Mb/s** (see note below), disabled onboard Wi-Fi (`wlp3s0`) |

Notes:
- **host1 and host3 are the two powerful nodes** (both 8c/16t AMD Ryzen mobile chips, 32 GB RAM), not
  `host3` alone - host1's CPU (6800H) is newer/faster than host3's (5800H) and its disk is 2x the size.
  `host2` (Intel N150, 4 threads, 16 GB) is clearly the lightest node. This corrects earlier internal notes
  that assumed host3 was "the beefiest" - it's mid-pack, not top.
- `host3`'s NIC is linking at 100 Mb/s instead of the expected 1 Gb/s - worth checking the cable/switch
  port before relying on it for anything storage- or throughput-sensitive (e.g. Longhorn replication).
- None of the three hosts have a second physical disk - each is a single-disk machine with one LVM volume
  group (`autopart --type=lvm --nohome` from the kickstart), root (70 GB) + swap, and several hundred GB of
  **unallocated free space in the VG** on every host. Any per-node storage (e.g. Longhorn) needs to come
  from a new LV carved out of that free space, not a dedicated `/dev/sdX` device.
- All three run Rocky Linux 9.8 "Blue Onyx", kernel `5.14.0-687.36.1.el9_8.x86_64`.

> This table used to describe the original Proxmox + VM template target (`n150-cp` control plane,
> `ser5-worker-1/2` workers at 10/28 vCPU/GB each). That design was abandoned - actual current fleet is 3
> bare-metal Rocky Linux 9 hosts (host1/host2/host3), no hypervisor anywhere - see the Note below.

## Stack

| Layer | Technology |
|-------|-----------|
| Hypervisor | none - bare-metal |
| OS | Rocky Linux 9 (kickstart, bare-metal) |
| Container runtime | containerd |
| Kubernetes | kubeadm 1.31 |
| CNI | Cilium (eBPF) |
| Load balancer | MetalLB (L2) |
| Ingress | ingress-nginx |
| Storage | Longhorn (LVM-carved LVs, no dedicated disk) |
| TLS | cert-manager |
| Monitoring | kube-prometheus-stack (Prometheus, Grafana, Alertmanager) |
| GitOps | ArgoCD (app-of-apps, prod/stage split via AppProjects) |
| IaC | Terraform (one-time ArgoCD bootstrap) + Ansible (OS + kubeadm) |
| Jumpbox | Mac laptop, WireGuard tunnel into the provisioning LAN |

## Repository Layout

```
.
├── bare-metal/                  # PXE provisioning via a GL.iNet Opal (Rocky kickstart, all 3 hosts)
│   ├── router/                  # GL.iNet Opal config (dnsmasq DHCP/TFTP/iPXE + WireGuard mgmt tunnel)
│   └── kickstart/                # Rocky Linux 9 kickstarts, one per host
├── terraform/cluster-bootstrap/  # One-time: installs ArgoCD + AppProjects/root Applications
├── ansible/                      # Bootstrap OS and kubeadm on host1/host2/host3
│   ├── inventory/
│   ├── group_vars/ + host_vars/
│   ├── playbooks/
│   └── roles/                    # common, storage, containerd, kubeadm, control-plane, worker
├── clusters/homelab/
│   ├── bootstrap/                 # AppProjects (prod/stage) + infra-root/apps-prod/apps-stage roots
│   └── infrastructure/           # ArgoCD Application manifests (cilium, metallb, …) - cluster-wide
├── apps/
│   ├── prod/                     # ArgoCD Applications for prod workloads (project: prod)
│   └── stage/                    # ArgoCD Applications for stage workloads (project: stage)
└── docs/                         # Detailed runbooks
```

This repo was originally scaffolded for Proxmox VE + Terraform-provisioned VMs. That was abandoned in
favor of the layout above - see `bare-metal/README.md` for the full story on why (Proxmox's netboot
installer proved more fragile than Rocky/Anaconda's kickstart path on this hardware).

## Getting Started

Provisioning goes through four stages: PXE/kickstart → WireGuard jumpbox tunnel → Ansible → Terraform → ArgoCD.

### 1. Bare-metal provisioning (PXE + kickstart)

Already done for host1/host2/host3 - see [`bare-metal/README.md`](bare-metal/README.md) if adding a new
host or re-provisioning one.

### 2. Jumpbox network access (WireGuard)

The hosts live on an isolated LAN (`10.10.10.0/24`, see Network below). From a Mac on the home network,
bring up the WireGuard tunnel first:

```bash
sudo wg-quick up ~/.wireguard-homelab/mac-jumpbox.conf
```

See [`bare-metal/README.md`](bare-metal/README.md), "Tunnel WireGuard pour le jumpbox", for initial setup.

### 3. Ansible — bootstrap Kubernetes

```bash
cd ansible
# Verify SSH connectivity
ansible -i inventory/hosts.yml all -m ping

# Bootstrap the full cluster
ansible-playbook -i inventory/hosts.yml playbooks/bootstrap.yml
```

This carves Longhorn storage, installs containerd/kubeadm, initializes the control plane (host1), and
joins the workers (host2, host3). See [`docs/ansible.md`](docs/ansible.md) for details.

### 4. Terraform — install ArgoCD

```bash
cd terraform/cluster-bootstrap
terraform init
terraform apply
```

Installs ArgoCD and applies the `prod`/`stage` `AppProject`s and root Applications. See
[`docs/terraform.md`](docs/terraform.md).

### 5. ArgoCD takes over

ArgoCD automatically deploys Cilium, MetalLB, Longhorn, cert-manager, and ingress-nginx, then your
workloads under `apps/prod/` and `apps/stage/`.

> Sync Cilium first and wait for nodes to be `Ready` before the rest converges - see
> [`docs/argocd-gitops.md`](docs/argocd-gitops.md) for the full bootstrap flow and day-2 operations.

## Network

```
Home LAN: 192.168.2.0/24 -- Opal WAN side (DHCP)
                │
                │  WireGuard (wg_mgmt, udp/51821) - jumpbox management access
                ▼
Provisioning/production LAN: 10.10.10.0/24
  Opal (gateway/DHCP/TFTP/PXE): 10.10.10.1
  host1 (control-plane): 10.10.10.10
  host2 (worker):        10.10.10.20
  host3 (worker):        10.10.10.30
  MetalLB pool:           10.10.10.250-253

Ingress path:
  LAN → MetalLB IP (L2 ARP) → ingress-nginx → Pods
                                    (eBPF observed by Cilium/Hubble)
```

See [`docs/networking.md`](docs/networking.md) for MetalLB IP pool and Cilium configuration, and
[`bare-metal/README.md`](bare-metal/README.md) for the WireGuard tunnel and PXE network setup.

## Documentation

| Doc | Contents |
|-----|----------|
| [`bare-metal/README.md`](bare-metal/README.md) | PXE/kickstart provisioning and the WireGuard jumpbox tunnel, via the GL.iNet Opal |
| [`docs/architecture.md`](docs/architecture.md) | Full architecture diagrams |
| [`docs/cluster-admin.md`](docs/cluster-admin.md) | How to connect and administer the cluster (kubectl, SSH, ArgoCD) |
| [`docs/terraform.md`](docs/terraform.md) | Terraform cluster-bootstrap module reference |
| [`docs/ansible.md`](docs/ansible.md) | Ansible roles and playbook details |
| [`docs/argocd-gitops.md`](docs/argocd-gitops.md) | GitOps workflow, ArgoCD usage, prod/stage split |
| [`docs/networking.md`](docs/networking.md) | CNI, MetalLB, and ingress setup |
| [`docs/storage.md`](docs/storage.md) | Longhorn storage configuration |
| [`docs/monitoring.md`](docs/monitoring.md) | Prometheus/Grafana access, dashboards, what's not scraped yet |
| [`docs/day2-operations.md`](docs/day2-operations.md) | Upgrades, backups, common ops |
| [`docs/ci-cd.md`](docs/ci-cd.md) | GitHub Actions workflows and self-hosted runner setup |
