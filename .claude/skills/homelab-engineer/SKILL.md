---
name: homelab-engineer
description: >
  Ground truth on this repo's actual homelab infrastructure, plus how to work
  in it with senior cloud/DevOps-engineer rigor. Use this skill for ANY task
  touching the k8s-homelab repo: bare-metal provisioning, PXE/kickstart/iPXE
  changes, the GL.iNet Opal router config, host inventory or IP/MAC changes,
  SSH access to host1/host2/host3, Ansible/Terraform/ArgoCD work, or any
  question about "the homelab," "the hosts," "the cluster," or "the Opal."
  Trigger even if the user doesn't name a file — e.g. "add a new node,"
  "why won't host2 boot," "update the kickstart," "point Ansible at the
  hosts," "wipe and reinstall X," "deploy an app," "prod vs stage." This
  skill has the current, correct state — a real running k8s cluster as of
  2026-08-11, not the original Proxmox+VM template.
---

# Homelab engineer

## Role

Operate as a senior cloud/DevOps engineer working in this specific repo, not
a generic assistant. That means:

- **Verify before you assert.** Don't guess IPs, MACs, or host state from
  memory — `bare-metal/hosts.csv` is the single source of truth for the
  inventory. If something in the repo looks inconsistent with what's below,
  say so explicitly rather than silently picking one.
- **Treat production hosts as production.** These are real machines with
  real disks. `rootpw --lock` + key-only SSH + wheel NOPASSWD sudo is the
  standing security posture — don't propose password auth, root login, or
  loosening sudo as a "quick fix."
- **Respect the PXE reinstall hazard.** `boot.ipxe` has no "already
  installed" guard — anything that PXE-boots and matches a MAC in the
  dispatch table gets wiped and reinstalled via kickstart. Before touching
  `boot.ipxe`, `dnsmasq-provisioning.conf`, or a host's boot order, check
  whether that host is already provisioned (see inventory below) and warn
  the user if a change could trigger an unintended reinstall. See
  `bare-metal/README.md` for the comment-vs-delete convention used once a
  host is confirmed installed.
- **Prefer changes that go through the repo, not one-off SSH sessions.**
  This is an IaC-managed homelab: kickstart files, dnsmasq config, and
  `deploy-opal.sh` are the source of truth for the Opal and the hosts, not
  whatever's live on the router right now. If you SSH in to fix something
  ad hoc, also update the corresponding file in the repo and redeploy, or
  flag clearly that you didn't.
- **Flag stale docs instead of trusting them.** This repo was originally
  scaffolded as a Proxmox VE + Terraform + kubeadm template. That design was
  abandoned in favor of bare-metal Rocky Linux 9 (see "History" below). The
  top-level `README.md` and `docs/` have been corrected to reflect this
  (real hardware, real IPs, real topology) — the two Proxmox-era command
  files that used to describe the old architecture were deleted, not
  updated. If a doc still mentions Proxmox, `192.168.1.x`, or `rocky`/
  `ubuntu` as the SSH user outside of historical "here's what changed"
  context, it's stale — fix it or flag it, don't trust it.
- **ArgoCD syncs from the GitHub remote, not local files.** Any change
  under `clusters/homelab/` or `apps/` does nothing until it's committed
  *and pushed* to `main` — editing locally and expecting the cluster to
  react is a common mistake here (bit during the initial bootstrap: two
  Applications failed and Cilium briefly ran with stale values because
  nothing had been pushed yet).

## Current infrastructure (ground truth)

### Fleet

Three bare-metal mini PCs, **all running Rocky Linux 9** installed via PXE +
kickstart. No hypervisor anywhere.

| Host  | IP           | MAC               | Notes |
|-------|--------------|-------------------|-------|
| host1 | 10.10.10.10  | 78:55:36:02:de:9e | Kubernetes control-plane (untainted, also schedulable). Strongest node — Ryzen 7 6800H, 32GB, 1TB NVMe — see README hardware table, polled live 2026-08-11. |
| host2 | 10.10.10.20  | e8:ff:1e:d8:a0:d0 | Kubernetes worker. First host provisioned; PXE dispatch commented out in `boot.ipxe` post-install. Intel N150, 16GB — lightest node. |
| host3 | 10.10.10.30  | 00:16:96:ee:1e:4d | Kubernetes worker. Ryzen 7 5800H, 32GB — mid-pack, not "the beefiest" (that was a wrong assumption before hardware was actually polled; host1 is stronger). NIC currently links at only 100 Mb/s — check the cable/switch port before relying on this node for anything throughput-sensitive. |

kubelet registers each node under its OS hostname (`hostN.lab.local`, from the kickstart), not the bare
`hostN` — `kubectl get nodes` shows `host1.lab.local` etc., and any `kubectl label`/`taint` command needs
the `.lab.local` suffix.

Source of truth: `bare-metal/hosts.csv`. If you change an IP or MAC, update
that file, the matching `dhcp-host` line in
`bare-metal/router/dnsmasq-provisioning.conf`, and the matching `iseq` block
in `bare-metal/router/boot.ipxe` together — they have to stay in sync
manually, nothing enforces it.

### Access

- SSH user: `foo`. Root login is locked (`rootpw --lock`). Key-only auth,
  no password fallback.
- Default key: `~/.ssh/id_ed25519_homelab`. If a plain `ssh foo@<host>`
  prompts for a password, it's almost always the client not picking up this
  non-default key name — use `-i ~/.ssh/id_ed25519_homelab` or add an SSH
  config `Host` block, don't assume the host is misconfigured.
- Passwordless sudo via `/etc/sudoers.d/wheel-nopasswd` (`%wheel ALL=(ALL)
  NOPASSWD: ALL`), set in each kickstart's `%post`.
- Hostnames are `hostN.lab.local`; there's no working DNS for these outside
  the provisioning subnet, use the IPs.

### Network

- Provisioning/production LAN: `10.10.10.0/24`.
- Gateway / DHCP+TFTP+PXE server: `10.10.10.1` — a GL.iNet Opal (GL-SFT1200)
  travel router repurposed as an isolated provisioning appliance. Its WAN
  side uplinks to the home network for internet access during installs.
  Admin/LuCI-equivalent access and the deploy script both go through this
  IP.
- This is a deliberately isolated subnet, not the user's main home LAN. A
  WireGuard tunnel (`wg_mgmt` interface on the Opal, UDP port 51821 —
  deliberately different from GL.iNet's own unused native WireGuard-server
  feature on port 51820) now bridges the Mac jumpbox into `10.10.10.0/24`
  from the home LAN — see `bare-metal/README.md`, "Tunnel WireGuard pour le
  jumpbox". The Opal's dropbear SSH server has no Ed25519 support (confirmed
  by testing — only RSA works for admin SSH to the Opal itself, separate
  from the Ed25519 key used for the Rocky hosts).

### Provisioning pipeline (bare-metal/)

```
bare-metal/
├── hosts.csv                          # hostname/MAC/IP source of truth
├── router/
│   ├── dnsmasq-provisioning.conf      # DHCP reservations + iPXE chainload
│   ├── boot.ipxe                      # MAC → kickstart dispatch
│   └── deploy-opal.sh                 # pushes config to the Opal over SSH
├── kickstart/
│   ├── ks-host1.cfg
│   ├── ks-host2.cfg
│   └── ks-host3.cfg
└── README.md                          # full write-up, read this for detail
```

Flow: host PXE-boots → Opal's dnsmasq recognizes its MAC and chainloads
iPXE → iPXE (`boot.ipxe`) matches the MAC and fetches the matching kernel/
initrd from the official Rocky mirror plus that host's kickstart from
`raw.githubusercontent.com` (repo must stay **public** — Anaconda has no
way to auth) → Anaconda partitions, sets hostname/static IP, installs
packages, runs `%post`.

Two things that bite people working on this pipeline:

1. **UEFI vs BIOS PXE binaries.** All three hosts are UEFI. The Opal serves
   `snponly.efi` (saved locally as `ipxe.efi`), not `undionly.kpxe` — the
   BIOS-legacy binary downloads fine over TFTP on UEFI firmware but silently
   fails to execute, which looks like "PXE just doesn't do anything."
2. **dnsmasq confdir is tmpfs.** On this firmware, `/tmp/dnsmasq.d` is
   wiped on every reboot. The real config lives in
   `/etc/dnsmasq.d/provisioning.conf` and gets re-mirrored into
   `/tmp/dnsmasq.d` by an `/etc/rc.local` hook. Any manual edit on the
   router that isn't also made in the repo (and redeployed via
   `deploy-opal.sh`) will disappear on next reboot.

Redeploying after any change to `router/*`: `./bare-metal/router/deploy-opal.sh 10.10.10.1`.

Full narrative and troubleshooting history: `bare-metal/README.md`.

### Kubernetes cluster — built and running (as of 2026-08-11)

`terraform/proxmox/` is gone (deleted, replaced by `terraform/cluster-bootstrap/` — see below).
`ansible/inventory/hosts.yml` points at the real bare-metal IPs. The cluster is live:

- kubeadm 1.31, host1 = control-plane (untainted/schedulable — it's the strongest node, not just an etcd
  appliance), host2 + host3 = workers. `ansible-playbook playbooks/bootstrap.yml` is fully idempotent —
  safe to rerun, 0 changes expected on a healthy cluster.
- Cilium is installed **twice, deliberately**: once via `terraform/cluster-bootstrap`'s
  `helm_release.cilium` (bootstrap-only, breaks the chicken-and-egg problem where ArgoCD's own pods can't
  schedule without a CNI — Cilium's agent DaemonSet uses `hostNetwork: true` so it alone can start before
  any CNI exists), and then ArgoCD adopts/reconciles the same Helm release going forward via
  `clusters/homelab/infrastructure/cilium.yml`. Don't "clean up" the Terraform `helm_release.cilium`
  resource thinking it's redundant with ArgoCD's Application — removing it would `helm uninstall` Cilium
  out from under the cluster.
- ArgoCD, once past that bootstrap step, owns everything else: `clusters/homelab/infrastructure/`
  (MetalLB + `metallb-pool` IPAddressPool, cert-manager, ingress-nginx, Longhorn) and `apps/prod`/
  `apps/stage` (empty scaffolds — no real workloads deployed yet).
- **ArgoCD only syncs from the actual GitHub remote (`main`), never a local working copy** — this bit
  during the initial bootstrap (apps-prod/apps-stage failed with "app path does not exist", Cilium ran
  briefly with a stale `k8sServiceHost` value) until everything was committed and pushed. Any future
  change to `clusters/homelab/` or `apps/` needs to reach GitHub before ArgoCD will act on it — editing
  local files alone does nothing.
- Longhorn storage: no host has a second disk (see hardware table) — an Ansible `storage` role role
  (`ansible/roles/storage/`) carves an LV out of each host's free LVM space and mounts it at
  `/var/lib/longhorn` before Kubernetes/Longhorn ever sees it.

If the cluster ever looks broken/missing, verify against real state (`kubectl get nodes`,
`kubectl -n argocd get applications`) before assuming — don't trust this note's timestamp blindly for
anything time-sensitive (node health, sync status, chart versions).

### History (why bare-metal, not Proxmox)

The repo was originally templated for Proxmox VE on every node with K8s
running in VMs. That was tried on host1/host3; the Proxmox auto-installer's
netboot path (large initrd, needed local USB staging on the Opal, more
failure modes) proved more fragile than Rocky/Anaconda's kickstart path.
All three hosts were consolidated onto bare-metal Rocky Linux 9 instead —
simpler, and the PXE pipeline above is fully IaC-driven with no local
staging on the Opal's 128MB flash. Media-server use cases were also dropped;
current intent is a Kubernetes learning environment for certification
study. A later idea to swap Rocky for Talos OS was considered and shelved
("on reste sur Rocky pour le moment") — if it resurfaces, use the real
topology below (host1 as control-plane), not an assumption.

## Working conventions

- Repo: `github.com/maximepatry/k8s-homelab`, public (required for
  `raw.githubusercontent.com` kickstart fetches — don't suggest making it
  private without calling out that this breaks provisioning).
- Primary language for docs/comments in `bare-metal/` is French — match it
  when editing files there unless told otherwise.
- When you change host-facing config (kickstart, dnsmasq, boot.ipxe),
  always name the exact host(s) affected and whether a redeploy or reinstall
  is required — never leave that implicit.
