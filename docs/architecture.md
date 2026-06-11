# Architecture

## Physical Layer

```
┌─────────────────────────────────────────────────────────────────┐
│ LAN  192.168.1.0/24          Gateway: 192.168.1.1               │
│                                                                  │
│  ┌──────────────────┐  ┌─────────────────┐  ┌────────────────┐  │
│  │  Intel N150      │  │ AMD Ryzen 5500U │  │ AMD Ryzen 5500U│  │
│  │  15 GB RAM       │  │ 32 GB RAM       │  │ 32 GB RAM      │  │
│  │  SATA SSD        │  │ SATA SSD        │  │ SATA SSD       │  │
│  │  192.168.1.10    │  │ 192.168.1.11    │  │ 192.168.1.12   │  │
│  │                  │  │                 │  │                │  │
│  │  [Proxmox VE]    │  │ [Proxmox VE]    │  │ [Proxmox VE]   │  │
│  └──────────────────┘  └─────────────────┘  └────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

> Update the Proxmox host IPs above to match your actual network once known.

## VM / Kubernetes Layer

```
┌─────────────────────────────────────────────────────────────────────┐
│                                                                      │
│  ┌────────────────────┐   ┌──────────────────┐  ┌────────────────┐  │
│  │ n150-cp            │   │ ser5-worker-1    │  │ ser5-worker-2  │  │
│  │ 192.168.1.101      │   │ 192.168.1.102    │  │ 192.168.1.103  │  │
│  │ 3 vCPU / 10 GB     │   │ 10 vCPU / 28 GB  │  │ 10 vCPU / 28GB │  │
│  │                    │   │                  │  │                │  │
│  │ control-plane      │   │ /dev/sda  OS     │  │ /dev/sda  OS   │  │
│  │ etcd               │   │ /dev/sdb  Longhorn│  │ /dev/sdb Longhorn│ │
│  │ API server         │   │                  │  │                │  │
│  └────────────────────┘   └──────────────────┘  └────────────────┘  │
└─────────────────────────────────────────────────────────────────────┘
```

## Software Stack

```
┌─────────────────────────────────────────────────────────────────┐
│  GitOps (ArgoCD)                                                 │
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
│  Ubuntu 24.04 LTS (cloud-init)                                   │
├─────────────────────────────────────────────────────────────────┤
│  Proxmox VE                                                      │
└─────────────────────────────────────────────────────────────────┘
```

## Network Flow (ingress)

```
Internet / LAN
     │
     ▼
MetalLB IP (L2 ARP)
     │
     ▼
ingress-nginx (LoadBalancer Service)
     │
     ▼
Ingress rules → Services → Pods
     │
   (all pod traffic observed by Hubble / Cilium eBPF)
```

## IaC Pipeline

```
Terraform ──► Proxmox VMs
                  │
              Ansible ──► OS config + kubeadm bootstrap
                               │
                           ArgoCD ──► Cilium, MetalLB, Longhorn,
                                      cert-manager, ingress-nginx,
                                      ...apps
```
