# Architecture

## Physical layer

```
┌──────────────────────────────────────────────────────────────────────────┐
│ Home LAN (192.168.2.0/24)                                                │
│                                                                           │
│              ┌───────────────────────────┐                              │
│              │  GL.iNet Opal (GL-SFT1200) │◄── WireGuard (wg_mgmt, udp/51821)
│              │  WAN: 192.168.2.x (DHCP)   │    from the Mac jumpbox, for
│              └─────────────┬─────────────┘    off-LAN management access
│                             │
└─────────────────────────────┼───────────────────────────────────────────┘
                               │ isolated provisioning/production LAN
┌──────────────────────────────┼───────────────────────────────────────────┐
│ 10.10.10.0/24 (Opal = 10.10.10.1, gateway/DHCP/TFTP/PXE)                 │
│                                                                           │
│  ┌───────────────────┐   ┌───────────────────┐   ┌───────────────────┐  │
│  │ host1              │   │ host2             │   │ host3             │  │
│  │ 10.10.10.10         │   │ 10.10.10.20       │   │ 10.10.10.30       │  │
│  │ Ryzen 7 6800H, 32GB │   │ Intel N150, 16GB  │   │ Ryzen 7 5800H, 32GB│  │
│  │ 1TB NVMe            │   │ 512GB SATA SSD    │   │ 512GB NVMe         │  │
│  │ Rocky Linux 9       │   │ Rocky Linux 9     │   │ Rocky Linux 9      │  │
│  └───────────────────┘   └───────────────────┘   └───────────────────┘  │
└───────────────────────────────────────────────────────────────────────────┘
```

No hypervisor anywhere — each host runs Rocky Linux 9 directly, installed via PXE + kickstart through the
Opal (see `bare-metal/README.md`). Bare-metal hardware specs above are polled live (`bare-metal/README.md`
/ top-level `README.md`), not the original VM-template sizing.

## Kubernetes layer

```
┌──────────────────────────────────────────────────────────────────────────┐
│  API endpoint: k8s-api.lab.local:6443 (/etc/hosts on each node → host2)  │
│                                                                          │
│  ┌──────────────────────┐ ┌──────────────────────┐ ┌──────────────────────┐ │
│  │ host1                │ │ host2                │ │ host3                │ │
│  │ 10.10.10.10          │ │ 10.10.10.20          │ │ 10.10.10.30          │ │
│  │                      │ │                      │ │                      │ │
│  │ worker               │ │ control-plane        │ │ worker               │ │
│  │ (+ Tailscale subnet  │ │ etcd, API server     │ │                      │ │
│  │  router)             │ │ tainted NoSchedule:  │ │                      │ │
│  │                      │ │ system DaemonSets    │ │                      │ │
│  │                      │ │ only                 │ │                      │ │
│  │ LV lv_longhorn 800GB │ │ LV lv_longhorn 380GB │ │ LV lv_longhorn 380GB │ │
│  │ /var/lib/longhorn    │ │ (idle - no Longhorn  │ │ /var/lib/longhorn    │ │
│  │                      │ │  pods on host2)      │ │                      │ │
│  └──────────────────────┘ └──────────────────────┘ └──────────────────────┘ │
└──────────────────────────────────────────────────────────────────────────┘
```

host2 is the control-plane because it's the **lightest** node (Intel N150, 4c/4t, 16 GB): it keeps the
standard kubeadm `NoSchedule` taint, so the two 8c/16t Ryzen nodes (host1, host3) get all the workloads.
The cluster originally ran with host1 as an untainted control-plane; it was rebuilt because a kubeadm
control-plane initialized without `--control-plane-endpoint` can't be moved in place. It now uses the
stable name `k8s-api.lab.local` (see `docs/ansible.md`, "API endpoint"), so a future move doesn't need
another rebuild. See the top-level README's hardware table for the full picture, including host3's
USB NIC (its onboard port is faulty).

Every host is single-disk (no dedicated Longhorn disk) — the `storage` Ansible role carves an LV out of
each host's otherwise-unallocated LVM free space (`ansible/roles/storage/`) instead.

## Software stack

```
┌─────────────────────────────────────────────────────────────────┐
│  GitOps (ArgoCD) - prod/stage split via AppProjects/namespaces  │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────────────┐   │
│  │  Cilium  │ │ MetalLB  │ │ Longhorn │ │ cert-manager     │   │
│  │  (CNI +  │ │  (L2 LB) │ │(storage) │ │ ingress-nginx    │   │
│  │  eBPF)   │ │          │ │          │ │                  │   │
│  └──────────┘ └──────────┘ └──────────┘ └──────────────────┘   │
├─────────────────────────────────────────────────────────────────┤
│  Kubernetes (kubeadm 1.31)                                       │
├─────────────────────────────────────────────────────────────────┤
│  containerd  │  kubelet  │  etcd  │  kube-apiserver             │
├─────────────────────────────────────────────────────────────────┤
│  Rocky Linux 9 (kickstart, bare-metal)                           │
└─────────────────────────────────────────────────────────────────┘
```

## Network flow (ingress)

```
Internet / LAN
     │
     ▼
MetalLB IP (L2 ARP, 10.10.10.250-253)
     │
     ▼
ingress-nginx (LoadBalancer Service)
     │
     ▼
Ingress rules → Services → Pods
     │
   (all pod traffic observed by Hubble / Cilium eBPF)
```

## IaC pipeline

```
bare-metal/ (PXE + kickstart) ──► Rocky Linux 9 on host1/host2/host3
                                        │
                                    Ansible ──► OS config + kubeadm bootstrap
                                        │        (run from the jumpbox, over
                                        │         the WireGuard tunnel)
                                    Terraform ──► installs ArgoCD + AppProjects/
                                        │         root Applications (one-time)
                                    ArgoCD ──► Cilium, MetalLB, Longhorn,
                                               cert-manager, ingress-nginx,
                                               apps/prod, apps/stage
```

Terraform's role is deliberately narrow here — see `docs/terraform.md` for why there's no VM-provisioning
step (there's no hypervisor to provision against).
