# Terraform — VM Provisioning

Terraform provisions the three VMs on Proxmox using the `bpg/proxmox` provider. It does not install the OS or Kubernetes — that is Ansible's job.

## Prerequisites

- Proxmox VE installed on all three nodes
- Ubuntu 24.04 cloud-init template created on each node (see `proxmox-setup.md`)
- Terraform CLI >= 1.5 installed locally

## Configuration

Copy the example vars file and fill in your values:

```bash
cd terraform/proxmox
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars`:

```hcl
proxmox_endpoint     = "https://192.168.1.10:8006"   # any Proxmox node
proxmox_username     = "terraform@pve"
proxmox_password     = "your-password"
proxmox_tls_insecure = true                           # self-signed cert
ssh_public_key       = "ssh-ed25519 AAAA..."          # your public key
vm_template          = "ubuntu-2404-cloud"
```

`terraform.tfvars` is gitignored — never commit it.

## VM Definitions

VM sizing lives in `variables.tf` under the `nodes` variable. Defaults:

| VM | Proxmox node | vCPU | RAM | OS disk | Data disk |
|----|-------------|------|-----|---------|-----------|
| n150-cp | n150 | 3 | 10 GB | 40 GB | — |
| ser5-worker-1 | ser5-1 | 10 | 28 GB | 60 GB | 400 GB |
| ser5-worker-2 | ser5-2 | 10 | 28 GB | 60 GB | 400 GB |

The worker data disk (`/dev/sdb`) is raw and unformatted — Longhorn manages it directly.

## Running

```bash
cd terraform/proxmox

terraform init
terraform plan
terraform apply
```

`apply` takes 3–5 minutes per VM (clone + boot).

## Outputs

```bash
terraform output control_plane_ips
terraform output worker_ips
```

These match the static IPs configured in the `nodes` variable and the Ansible inventory.

## Destroying

```bash
terraform destroy
```

This deletes the VMs and their disks from Proxmox. The Proxmox hosts and template are unaffected.

## Updating VM Resources

Edit the relevant values in the `nodes` variable in `variables.tf`, then `terraform apply`. Proxmox will hot-add CPU/RAM if supported; disk resizes require a guest reboot.

## State

Terraform state is local (`terraform.tfstate`). It is gitignored. For a shared setup, configure a remote backend (S3, Terraform Cloud, or an HTTP backend on your NAS).
