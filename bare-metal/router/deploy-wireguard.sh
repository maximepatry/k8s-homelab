#!/usr/bin/env bash
# Deploie/actualise le tunnel WireGuard de management (wg_mgmt) sur l'Opal,
# pour que le jumpbox (MacBook) puisse atteindre 10.10.10.0/24 depuis le
# reseau domestique sans etre branche sur le LAN isole de l'Opal.
# Lance depuis le MacBook : ./deploy-wireguard.sh <opal-ip> <mac-wg-public-key>
#
# Prerequis :
#   - Acces SSH a l'Opal (root@<opal-ip>) via une cle deja autorisee. Le
#     firmware de ce GL-SFT1200 (dropbear 2017.75, target siflower) n'a PAS
#     de support Ed25519 - il faut une cle RSA (voir bare-metal/README.md,
#     section "Tunnel WireGuard pour le jumpbox").
#   - wireguard-tools installe localement (brew install wireguard-tools)
#     pour generer la paire de cles du Mac AVANT de lancer ce script :
#       mkdir -p ~/.wireguard-homelab && chmod 700 ~/.wireguard-homelab
#       wg genkey | tee ~/.wireguard-homelab/mac-jumpbox.key | wg pubkey \
#         > ~/.wireguard-homelab/mac-jumpbox.pub
#     La cle privee du Mac ne quitte jamais cette machine et n'est jamais
#     commit (voir .gitignore : *.key).

set -euo pipefail

OPAL_IP="${1:?Usage: ./deploy-wireguard.sh <opal-ip> <mac-wg-public-key>}"
MAC_PUBKEY="${2:?Usage: ./deploy-wireguard.sh <opal-ip> <mac-wg-public-key>}"

# Meme contournement que deploy-opal.sh : dropbear sur ce firmware n'offre
# que ssh-rsa comme host key, rejete par defaut par les clients OpenSSH recents.
SSH_OPTS=(-o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa)

echo "==> Sauvegarde de la config network/firewall actuelle sur l'Opal..."
ssh "${SSH_OPTS[@]}" root@"$OPAL_IP" "
  mkdir -p /root/backup
  uci export network  > /root/backup/network.uci.bak
  uci export firewall > /root/backup/firewall.uci.bak
"

echo "==> Generation de la paire de cles WireGuard de l'Opal si absente (cle privee jamais exportee)..."
ssh "${SSH_OPTS[@]}" root@"$OPAL_IP" "
  mkdir -p /etc/wireguard
  [ -f /etc/wireguard/wg_mgmt_private.key ] || wg genkey > /etc/wireguard/wg_mgmt_private.key
  chmod 600 /etc/wireguard/wg_mgmt_private.key
  wg pubkey < /etc/wireguard/wg_mgmt_private.key > /etc/wireguard/wg_mgmt_public.key
"

echo "==> Application de l'interface wg_mgmt + peer Mac + zone firewall via UCI..."
ssh "${SSH_OPTS[@]}" root@"$OPAL_IP" "
set -e
WG_PRIV=\$(cat /etc/wireguard/wg_mgmt_private.key)

# --- network: interface wg_mgmt (serveur) ---
uci set network.wg_mgmt=interface
uci set network.wg_mgmt.proto='wireguard'
uci set network.wg_mgmt.private_key=\"\$WG_PRIV\"
uci set network.wg_mgmt.listen_port='51821'
uci -q delete network.wg_mgmt.addresses || true
uci add_list network.wg_mgmt.addresses='10.10.11.1/24'

# --- network: peer pour le Mac ---
uci set network.wg_mgmt_mac=wireguard_wg_mgmt
uci set network.wg_mgmt_mac.description='mac-jumpbox'
uci set network.wg_mgmt_mac.public_key='$MAC_PUBKEY'
uci -q delete network.wg_mgmt_mac.allowed_ips || true
uci add_list network.wg_mgmt_mac.allowed_ips='10.10.11.2/32'
uci set network.wg_mgmt_mac.route_allowed_ips='1'
uci set network.wg_mgmt_mac.persistent_keepalive='25'
uci commit network

# --- firewall: zone wg_mgmt, forwarding vers lan, ouverture WAN du port ---
uci set firewall.wg_mgmt_zone=zone
uci set firewall.wg_mgmt_zone.name='wg_mgmt'
uci -q delete firewall.wg_mgmt_zone.network || true
uci add_list firewall.wg_mgmt_zone.network='wg_mgmt'
uci set firewall.wg_mgmt_zone.input='ACCEPT'
uci set firewall.wg_mgmt_zone.output='ACCEPT'
uci set firewall.wg_mgmt_zone.forward='REJECT'

uci set firewall.wg_mgmt_fwd=forwarding
uci set firewall.wg_mgmt_fwd.src='wg_mgmt'
uci set firewall.wg_mgmt_fwd.dest='lan'

uci set firewall.wg_mgmt_allow=rule
uci set firewall.wg_mgmt_allow.name='Allow-WireGuard-mgmt'
uci set firewall.wg_mgmt_allow.src='wan'
uci set firewall.wg_mgmt_allow.proto='udp'
uci set firewall.wg_mgmt_allow.dest_port='51821'
uci set firewall.wg_mgmt_allow.target='ACCEPT'
uci commit firewall
"

echo "==> Rechargement network + firewall..."
ssh "${SSH_OPTS[@]}" root@"$OPAL_IP" "/etc/init.d/network reload && sleep 2 && /etc/init.d/firewall reload"

echo
echo "Termine. Cle publique WireGuard de l'Opal (a mettre dans Peer.PublicKey"
echo "du fichier de config cote Mac, voir bare-metal/README.md) :"
ssh "${SSH_OPTS[@]}" root@"$OPAL_IP" "cat /etc/wireguard/wg_mgmt_public.key"
