# Ansible — Cluster Bootstrap

Ansible configures the OS and bootstraps Kubernetes on the three bare-metal Rocky Linux 9 hosts. It is
idempotent — safe to rerun. Run from the jumpbox, over the WireGuard tunnel into `10.10.10.0/24`
(`bare-metal/README.md`, "Tunnel WireGuard pour le jumpbox").

## Prerequisites

```bash
pip install ansible
ansible-galaxy collection install -r ansible/requirements.yml   # ansible.posix + community.general
```

SSH access as `foo` (kickstart-created user, root login locked) with `~/.ssh/id_ed25519_homelab` — both
already set as defaults in `ansible/ansible.cfg`.

## Inventory

`ansible/inventory/hosts.yml` defines the three nodes:

```
control_plane:    host2 (10.10.10.20)
workers:          host1 (10.10.10.10)
                  host3 (10.10.10.30)
tailscale_router: host1 (independent of the k8s role)
```

host2 (Intel N150, 4c/4t, 16 GB) is the lightest node, so it's a **dedicated** control-plane: it keeps the
standard kubeadm `NoSchedule` taint, and host1/host3 (both 8c/16t Ryzen, 32 GB) run the workloads. See the
top-level README's hardware table. (The cluster originally ran with host1 as an untainted control-plane;
that was changed by a rebuild because kubeadm can't move a control-plane that was initialized without
`--control-plane-endpoint`.)

## Configuration

Key variables in `ansible/group_vars/all.yml`:

| Variable | Default | Description |
|----------|---------|-------------|
| `kubernetes_version` | `1.31` | Minor version for the kubeadm/kubelet/kubectl repo |
| `pod_cidr` | `10.244.0.0/16` | Pod network range |
| `service_cidr` | `10.96.0.0/12` | Service network range |
| `kube_proxy_enabled` | `false` | Cilium replaces kube-proxy |
| `ansible_user` | `foo` | Kickstart-created user; root login is locked |
| `control_plane_endpoint_name` | `k8s-api.lab.local` | Stable API server name passed to `kubeadm init --control-plane-endpoint` |
| `control_plane_endpoint_port` | `6443` | API server port |
| `control_plane_ip` | derived | `ansible_host` of the first host in the `control_plane` group — never hardcoded |

**API endpoint.** Every node gets `<control_plane_ip> k8s-api.lab.local` in `/etc/hosts` (common role) —
there's no real DNS for `lab.local`. Certs, node kubeconfigs and the join command all reference that name,
so the control-plane can later be moved by joining a new one and repointing the name, without a rebuild.
Places that use the **IP** instead, and must be updated by hand if the control-plane moves:

- Cilium `k8sServiceHost` — `terraform/cluster-bootstrap/main.tf` and
  `clusters/homelab/infrastructure/cilium.yml` (both must agree; kept as an IP so CNI bootstrap doesn't
  depend on name resolution inside pods)
- `clusters/homelab/kubeconfig` on the Mac — Ansible rewrites its `server:` to
  `https://<control_plane_ip>:6443` on every run (the IP is in the API cert's SANs), so the Mac needs **no**
  `/etc/hosts` entry. If you copy `admin.conf` by hand instead, either rewrite the `server:` line the same
  way or add `10.10.10.20 k8s-api.lab.local` to the Mac's `/etc/hosts`.

There's no `--cluster-name` flag on `kubeadm init` (it's a `ClusterConfiguration` field, only settable via
a full `--config` file) — not worth introducing one just to name the cluster "homelab" cosmetically.

Per-host `longhorn_lv_size_gb` in `ansible/host_vars/{host1,host2,host3}.yml` — sized from each host's real
free LVM space (see `docs/storage.md`).

## Running the Full Bootstrap

```bash
cd ansible
ansible-playbook playbooks/bootstrap.yml
```

Execution order:
1. **common** (all nodes) — swap off, kernel modules, sysctl, open-iscsi, `/etc/hosts` entry for
   `k8s-api.lab.local`
2. **storage** (all nodes) — carve an LV from free VG space, mount at `/var/lib/longhorn`
3. **containerd** (all nodes) — install, configure `SystemdCgroup=true`
4. **kubeadm** (all nodes) — install kubelet/kubeadm/kubectl, hold versions, pin kubelet `--node-ip` to
   the LAN IP (`/etc/sysconfig/kubelet`)
5. **control-plane** (host2) — `kubeadm init --control-plane-endpoint=k8s-api.lab.local:6443`, keep the
   control-plane `NoSchedule` taint, write kubeconfig to `clusters/homelab/kubeconfig`
6. **worker** (host1, host3) — `kubeadm join`

## After Bootstrap

The kubeconfig is written to `clusters/homelab/kubeconfig` (gitignored — it's a live cluster-admin
credential, this repo is public). Use it locally:

```bash
export KUBECONFIG=$(pwd)/clusters/homelab/kubeconfig
kubectl get nodes
```

Nodes will show `NotReady` until Cilium is deployed via ArgoCD (no CNI yet) — see `docs/terraform.md` for
the next step (installing ArgoCD).

## Running Individual Roles

```bash
# Only run the storage role
ansible-playbook playbooks/bootstrap.yml --tags storage

# Only run on workers
ansible-playbook playbooks/bootstrap.yml --limit workers

# Dry run
ansible-playbook playbooks/bootstrap.yml --check
```

## Connectivity Check

Before running the playbook, verify Ansible can reach all nodes:

```bash
ansible all -m ping
```

## Key Role Details

### common
- Disables swap permanently (removes from `/etc/fstab`, masks `swap.target` for zram)
- Loads `overlay` and `br_netfilter` kernel modules and persists them
- Sets `net.ipv4.ip_forward=1` and `bridge-nf-call-iptables=1`
- Installs `iscsi-initiator-utils` and `nfs-utils` — required by Longhorn
- **Disables firewalld** — Cilium manages packet filtering via eBPF; firewalld conflicts with it
- **Sets SELinux to permissive** — enforcing mode blocks several kubelet and container operations; permissive logs violations without blocking, useful for learning what would break

### storage
- None of the three hosts have a second disk — each is single-disk (`autopart --type=lvm --nohome` from
  the kickstart) with substantial free space left in its LVM volume group after root+swap
- Carves an LV (`lv_longhorn`, sized per-host in `ansible/host_vars/`) out of that free space, formats
  XFS, mounts at `/var/lib/longhorn`

### containerd
- Adds Docker CE's `centos` yum repo (provides `containerd.io` for Rocky Linux)
- Generates default config then patches `SystemdCgroup = true`
- **Do not regenerate the config manually** — this setting will revert to `false` and kubelet will refuse to start

### control-plane
- Runs `kubeadm init --control-plane-endpoint=k8s-api.lab.local:6443 --apiserver-advertise-address=<host IP>
  --apiserver-cert-extra-sans=k8s-api.lab.local,<host IP> --skip-phases=addon/kube-proxy` (plus
  `kubeadm_init_extra_args` from `group_vars/control_plane.yml`)
- `kube-proxy` is intentionally skipped — Cilium handles service routing via eBPF
- **Keeps** the control-plane `NoSchedule` taint (re-applies it if someone removed it) — host2 is the
  weakest node, workloads belong on host1/host3. Cilium, metallb-speaker and node-exporter DaemonSets
  tolerate it; Longhorn's don't, so host2's Longhorn LV is idle
- Generates a join token and stores it as a fact for the worker play
- Writes `/etc/kubernetes/admin.conf` to your local `clusters/homelab/kubeconfig`, with `server:` rewritten
  to the control-plane IP

### worker
- Runs the join command generated by the control-plane play
- Labels the node with `node-role.kubernetes.io/worker=worker`

## Upgrading Kubernetes

See `docs/day2-operations.md` for the full upgrade procedure.
