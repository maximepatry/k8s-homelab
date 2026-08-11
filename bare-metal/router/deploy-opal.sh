#!/usr/bin/env bash
# Deploys the provisioning config (dnsmasq + iPXE) onto the GL.iNet Opal.
# Run from your MacBook: ./deploy-opal.sh <opal-ip>
#
# Prerequisites:
#   - SSH access to the Opal (root@<opal-ip>), password or key auth already set up
#   - Opal's LAN already reconfigured to the isolated provisioning subnet
#     (e.g. 10.10.10.1/24) - see router/dnsmasq-provisioning.conf

set -euo pipefail

OPAL_IP="${1:?Usage: ./deploy-opal.sh <opal-ip>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# dropbear (OpenWrt's SSH server) on this firmware only offers ssh-rsa as a
# host key, which recent OpenSSH clients (macOS included) reject by default.
SSH_OPTS=(-o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa)

echo "==> Checking free space on Opal (128MB flash total - keep an eye on this)..."
ssh "${SSH_OPTS[@]}" root@"$OPAL_IP" "df -h /overlay"

# Confirmed on this firmware: dhcp.@dnsmasq[0].confdir = /tmp/dnsmasq.d,
# which is tmpfs (RAM) - anything dropped there is wiped on reboot. So we
# keep the real copy in /etc (persistent, survives reboot) and mirror it
# into /tmp/dnsmasq.d ourselves, both now and via an /etc/rc.local hook so
# it's restored automatically after every power cycle.
CONFDIR_PERSIST="/etc/dnsmasq.d"
CONFDIR_LIVE="/tmp/dnsmasq.d"

echo "==> Installing dnsmasq-full (adds TFTP support) if not already present..."
ssh "${SSH_OPTS[@]}" root@"$OPAL_IP" "opkg update && opkg install dnsmasq-full || true"

echo "==> Fetching the iPXE boot binary (snponly.efi, ~1MB - UEFI x86_64 targets)..."
# snponly.efi (not ipxe.efi) - reuses the UEFI firmware's own NIC driver
# (Simple Network Protocol) instead of iPXE's bundled native drivers,
# which is the more reliable choice when we don't know if iPXE has a
# native driver for this exact NIC (Realtek PCIe GBE here).
ssh "${SSH_OPTS[@]}" root@"$OPAL_IP" "mkdir -p /www/ipxe && \
  wget -O /www/ipxe/ipxe.efi http://boot.ipxe.org/x86_64-efi/snponly.efi"

echo "==> Uploading boot.ipxe (persistent, served by uhttpd from /www)..."
ssh "${SSH_OPTS[@]}" root@"$OPAL_IP" "mkdir -p /www && cat > /www/boot.ipxe" < "$SCRIPT_DIR/boot.ipxe"

echo "==> Uploading dnsmasq config to a persistent location ($CONFDIR_PERSIST)..."
ssh "${SSH_OPTS[@]}" root@"$OPAL_IP" "mkdir -p $CONFDIR_PERSIST && cat > $CONFDIR_PERSIST/provisioning.conf" < "$SCRIPT_DIR/dnsmasq-provisioning.conf"

echo "==> Mirroring into $CONFDIR_LIVE and making that survive reboots via rc.local..."
ssh "${SSH_OPTS[@]}" root@"$OPAL_IP" "
  mkdir -p $CONFDIR_LIVE
  cp $CONFDIR_PERSIST/provisioning.conf $CONFDIR_LIVE/provisioning.conf
  grep -q provisioning.conf /etc/rc.local || sed -i \"/^exit 0/i mkdir -p $CONFDIR_LIVE; cp $CONFDIR_PERSIST/provisioning.conf $CONFDIR_LIVE/provisioning.conf; /etc/init.d/dnsmasq restart\" /etc/rc.local
"

echo "==> Restarting dnsmasq..."
ssh "${SSH_OPTS[@]}" root@"$OPAL_IP" "/etc/init.d/dnsmasq restart"

echo "Done. Enable PXE boot in each mini PC's BIOS/UEFI and power it on -"
echo "it should chainload iPXE, then fetch its kickstart from GitHub and"
echo "the Rocky mirror directly. No local file staging needed on the Opal."
