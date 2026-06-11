# Proxmox Setup

Terraform cannot install Proxmox. These steps are manual and must be done once on each node before running `terraform apply`.

## 1. Install Proxmox VE

Download the Proxmox VE ISO from https://www.proxmox.com/en/downloads and flash it to a USB drive.

Boot each mini PC from USB and run the installer. Recommended settings:

- Filesystem: `ext4` (simpler) or `zfs` (snapshot support, uses more RAM — avoid on N150 with 15 GB)
- Hostname: `n150.homelab`, `ser5-1.homelab`, `ser5-2.homelab`
- Static IP: `192.168.1.10`, `192.168.1.11`, `192.168.1.12` (Proxmox host IPs, separate from VM IPs)
- DNS: your router IP

After install, access each node at `https://<host-ip>:8006`.

## 2. Create the Terraform API User

Run this on **one** Proxmox node (the API is cluster-wide if you set up a cluster, or per-node if standalone):

```bash
# SSH into Proxmox host
ssh root@192.168.1.10

# Create role with required permissions
pveum role add TerraformProv -privs "Datastore.AllocateSpace Datastore.Audit Pool.Allocate Sys.Audit Sys.Console Sys.Modify VM.Allocate VM.Audit VM.Clone VM.Config.CDROM VM.Config.Cloudinit VM.Config.CPU VM.Config.Disk VM.Config.HWType VM.Config.Memory VM.Config.Network VM.Config.Options VM.Migrate VM.Monitor VM.PowerMgmt SDN.Use"

# Create user
pveum user add terraform@pve --password changeme

# Assign role to user (root level = all nodes)
pveum aclmod / -user terraform@pve -role TerraformProv
```

Use this user + password in `terraform.tfvars`.

## 3. Create the Ubuntu Cloud-Init Template

Terraform clones VMs from a template. This template must exist on **each Proxmox node** that will host a VM (all three nodes in this setup).

Run on each Proxmox host:

```bash
# Download Ubuntu 24.04 cloud image
wget https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img

# Install qemu-guest-agent and cloud-init tooling into the image
apt install -y libguestfs-tools
virt-customize -a noble-server-cloudimg-amd64.img --install qemu-guest-agent,curl

# Create VM that will become the template (ID 9000, adjust if taken)
qm create 9000 \
  --name ubuntu-2404-cloud \
  --memory 2048 \
  --cores 2 \
  --net0 virtio,bridge=vmbr0 \
  --agent enabled=1

# Import the cloud image as disk
qm importdisk 9000 noble-server-cloudimg-amd64.img local-lvm

# Attach disk and configure boot
qm set 9000 \
  --scsihw virtio-scsi-pci \
  --scsi0 local-lvm:vm-9000-disk-0,discard=on,ssd=1 \
  --boot order=scsi0 \
  --ide2 local-lvm:cloudinit \
  --serial0 socket \
  --vga serial0 \
  --ipconfig0 ip=dhcp

# Add template tag (used by Terraform data source to find it)
qm set 9000 --tags template

# Convert to template (irreversible)
qm template 9000
```

Verify with: `qm list` — VM 9000 should show as template.

## 4. (Optional) Proxmox Cluster

If you want live migration between nodes and a single API endpoint, form a cluster before creating any VMs:

```bash
# On n150 (first node):
pvecm create homelab-cluster

# On each SER5:
pvecm add 192.168.1.10
```

With a cluster, `proxmox_endpoint` in Terraform can point to any node — they share state. Without a cluster, you must point Terraform at each node separately (the current `variables.tf` handles this via `proxmox_node` per VM).

## 5. Network Bridge

Proxmox creates `vmbr0` by default, bridged to the physical NIC. VMs attached to `vmbr0` appear directly on your LAN — this is correct for MetalLB L2 mode.

Verify on each host:
```bash
ip addr show vmbr0
```

Should show your Proxmox host IP on the LAN subnet.
