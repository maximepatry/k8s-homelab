# bare-metal-hmlab

Provisioning automatisé du homelab sur mini PC, via un GL.iNet Opal
(GL-SFT1200) en réseau de provisioning isolé, sans clé USB.

Fleet actuelle :

- **host1** - Proxmox, hors pipeline (voir "Hosts exclus" plus bas) - installé
  manuellement avant ce projet
- **host2** - Rocky Linux 9, provisionné via kickstart (ce pipeline)
- **host3** - Proxmox VE (Ryzen 7 5800H / 32 Go - media server + sandbox k8s
  pour certif), provisionné via l'auto-installer officiel Proxmox (voir
  "Proxmox (host3)" plus bas)

## Comment ça marche

1. L'Opal est reconfiguré en routeur isolé (LAN `10.10.10.0/24`, WAN uplinké
   vers le réseau domestique pour l'accès internet pendant l'install).
2. host2 et host3 bootent en PXE (à activer une fois dans chaque BIOS/UEFI).
3. `dnsmasq` sur l'Opal reconnaît chaque mini PC par adresse MAC
   (réservations statiques dans `router/dnsmasq-provisioning.conf`,
   source de vérité : `hosts.csv`) et chaîne vers iPXE.
4. iPXE (`router/boot.ipxe`) route par MAC :
   - **host2** → kernel/initrd Rocky + kickstart, servis en HTTPS depuis le
     mirror officiel Rocky et ce repo GitHub - rien de volumineux stocké sur
     les 128MB de flash de l'Opal.
   - **host3** → kernel/initrd Proxmox, générés localement et servis depuis
     une clé USB branchée sur l'Opal (trop gros pour la flash interne).
5. L'installeur (Anaconda pour Rocky, l'auto-installer Proxmox pour host3)
   fait le partitionnement, hostname, IP statique, etc. selon le
   kickstart/answer file correspondant.

## Hosts exclus du pipeline

**host1 (Proxmox)** n'a volontairement aucune entrée dans `hosts.csv`,
`router/dnsmasq-provisioning.conf` ni `router/boot.ipxe`. S'il tente un
PXE boot par accident, il tombe dans le cas `:unknown` de `boot.ipxe`
(shell iPXE, pas d'install) au lieu de se faire écraser. Si tu veux plus
tard lui donner quand même une IP fixe sur ce subnet sans le brancher au
pipeline kickstart, ajoute juste une ligne `dhcp-host=...` dans
`dnsmasq-provisioning.conf` - pas de case correspondante dans `boot.ipxe`.

## Après une install réussie : retirer le host du dispatch PXE

Le boot PXE lui-même ne redéclenche pas une réinstall à chaque reboot — un
firmware normal essaie le disque local en premier et ne retombe sur le
réseau que si le disque ne fournit aucun bootloader valide (ou si tu forces
un boot réseau ponctuel, ex. `efibootmgr -n`). Mais `boot.ipxe` n'a aucune
protection "skip si déjà installé" : si un host retombe un jour sur PXE
(ordre de boot mal configuré, disque en panne, etc.), il se refait wiper
sans prévenir.

Une fois qu'un host (host2, host3, ...) est confirmé opérationnel, retire
son entrée du pipeline - même traitement que host1. Deux options :

- **Supprimer** la ligne `dhcp-host=...` et le bloc `iseq .../:hostX` -
  plus propre si le host part pour de bon.
- **Commenter** (`#` devant la ligne `dhcp-host=...`, et devant la ligne
  `iseq ${mac} ... && goto hostX ||` dans `boot.ipxe`) - recommandé si tu
  comptes réactiver plus tard : ça évite de retaper/retrouver la MAC, tu
  décommentes juste les deux lignes. Le bloc `:hostX` (kernel/initrd/boot)
  peut rester tel quel dans les deux cas - une fois que rien ne saute
  dessus (`goto hostX`), il est inerte.

  Exemple dans `boot.ipxe` :
  ```
  # iseq ${mac} e8:ff:1e:d8:a0:d0 && goto host2 ||
  iseq ${mac} 00:16:96:ee:1e:4d && goto host3 ||
  goto unknown
  ```

Dans les deux cas, relance `./router/deploy-opal.sh <ip-de-l-opal>` pour
pousser le changement. Le host tombera alors dans le cas `:unknown` (shell
iPXE, pas d'install) s'il retente un PXE boot par accident.

## Proxmox (host3)

Contrairement à Rocky, Proxmox ne publie pas de vmlinuz/initrd netboot
prêts à l'emploi - il faut les générer soi-même à partir de l'ISO officiel
avec `proxmox-auto-install-assistant`, via un conteneur Debian (OrbStack
sur le Mac).

Proxmox VE est en 9.x depuis un moment, basé sur **Debian 13 "Trixie"**
(pas Bookworm/8.x) - télécharge la dernière ISO depuis
[proxmox.com/downloads](https://www.proxmox.com/en/downloads/proxmox-virtual-environment/)
et dépose-la dans `bare-metal/proxmox/netboot/` avant de lancer le
conteneur (c'est ce dossier qui est monté sur `/work`) :

```bash
cd bare-metal/proxmox
mkdir -p netboot   # gitignored - c'est là que l'ISO téléchargée doit aller
# --platform linux/amd64 est nécessaire sur Mac Apple Silicon - Proxmox ne
# publie ses paquets qu'en amd64, pas en arm64 (OrbStack émule via Rosetta).
docker run -it --rm --platform linux/amd64 -v "$(pwd)/netboot":/work debian:trixie bash

# --- dans le conteneur ---
apt update && apt install -y wget gnupg
wget https://enterprise.proxmox.com/debian/proxmox-release-trixie.gpg -O /usr/share/keyrings/proxmox-release-trixie.gpg
echo "deb [signed-by=/usr/share/keyrings/proxmox-release-trixie.gpg] http://download.proxmox.com/debian/pve trixie pve-no-subscription" > /etc/apt/sources.list.d/pve-install-repo.list
apt update && apt install -y proxmox-auto-install-assistant

cd /work
ls   # confirme le nom exact de l'ISO téléchargée avant de continuer
proxmox-auto-install-assistant prepare-iso proxmox-ve_9.x-y.iso \
  --fetch-from http \
  --url https://raw.githubusercontent.com/maximepatry/k8s-homelab/main/bare-metal/proxmox/answer-host3.toml \
  --output proxmox-ve-auto.iso

# `--pxe` n'est pas dispo sur toutes les versions du paquet - on extrait
# vmlinuz/initrd.img directement de l'ISO modifiée à la place, ça marche
# peu importe la version.
apt install -y libarchive-tools
bsdtar -xf proxmox-ve-auto.iso -C /work boot/linux26 boot/initrd.img
mv /work/boot/linux26 /work/vmlinuz
mv /work/boot/initrd.img /work/initrd.img
rmdir /work/boot
```

Remplace `proxmox-ve_9.x-y.iso` par le nom réel du fichier téléchargé
(vérifié via `ls` ci-dessus). `--url` pointe vers GitHub où
`answer-host3.toml` doit déjà être accessible en HTTPS au moment du netboot
(donc poussé sur `main` avant de tester host3, même si tu génères l'ISO
avant) - le contenu du fichier au moment du `prepare-iso` n'a pas besoin
d'être exact, seule l'URL est embarquée.

Ça produit `vmlinuz` + `initrd.img` directement dans
`bare-metal/proxmox/netboot/` sur le Mac (grâce au volume monté). L'URL de
l'answer file est embarquée dans l'initrd à ce moment-là (pas passée au
boot comme `inst.ks=` pour Rocky) - donc un answer file différent par host
Proxmox veut dire un initrd différent par host.

Avant de lancer :
1. Remplis `proxmox/answer-host3.toml` : hash de mot de passe root
   (`openssl passwd -6`, jamais le mot de passe en clair), ta clé SSH
   publique, et `disk_list` - fait (`nvme0n1`, confirmé via `lsblk` depuis
   Omarchy encore installé sur host3).
2. Génère `vmlinuz`/`initrd.img` comme ci-dessus.
3. Formate une clé USB en exFAT depuis le Mac (Disk Utility - pas d'ext4
   natif sur macOS, et exFAT évite la limite 4GB de FAT32) et copie les
   deux fichiers dessus directement - pas de transfert réseau pour ces
   gros fichiers.
4. Branche cette clé dans le port USB de l'Opal, puis lance
   `./router/deploy-opal.sh <ip-de-l-opal>` - le script installe le
   support USB/exFAT sur l'Opal (`kmod-usb-storage`, `kmod-fs-exfat`,
   `block-mount`), monte la clé sur `/www/proxmox` (persistant via
   `fstab`/uci), et vérifie que les deux fichiers y sont.
5. Active le PXE boot sur host3 - `boot.ipxe` route déjà sa MAC vers
   `http://10.10.10.1/proxmox/vmlinuz` + `proxmox-start-auto-installer`.

## Structure

- `hosts.csv` - mapping hostname / MAC / IP pour host2 et host3
- `router/dnsmasq-provisioning.conf` - DHCP + réservations + chainload iPXE
- `router/boot.ipxe` - menu de boot iPXE, dispatch par MAC
- `router/deploy-opal.sh` - déploie la config + (si présents) les fichiers
  netboot Proxmox sur l'Opal via SSH
- `kickstart/ks-host2.cfg` - kickstart Rocky pour host2
- `proxmox/answer-host3.toml` - answer file Proxmox pour host3
- `proxmox/netboot/` - `vmlinuz`/`initrd.img` générés localement (gitignored)

## À faire avant de lancer

- Ce dossier vit dans le repo `k8s-homelab` (sous `bare-metal/`, pas à la
  racine) - `router/boot.ipxe` pointe vers
  `raw.githubusercontent.com/maximepatry/k8s-homelab/main/bare-metal/...` -
  fait.
- Remplacer la clé SSH placeholder dans `kickstart/ks-host2.cfg` et dans
  `proxmox/answer-host3.toml`
- Remplir `disk_list` dans `proxmox/answer-host3.toml` (voir section
  Proxmox ci-dessus)
- Reconfigurer le LAN de l'Opal en `10.10.10.1/24` (LuCI ou `uci`) - fait
- Activer le boot PXE dans le BIOS/UEFI de host2 et host3

## Déploiement

```
./router/deploy-opal.sh <ip-de-l-opal>
```

Le script vérifie l'espace disque libre sur l'Opal, installe `dnsmasq-full`
si besoin, récupère le binaire iPXE, et pousse la config + `boot.ipxe`.

**Note firmware** : sur ce GL-SFT1200, `confdir` est réglé sur
`/tmp/dnsmasq.d` (tmpfs, effacé à chaque reboot). Le script garde donc la
copie de référence dans `/etc/dnsmasq.d/provisioning.conf` (persistant) et
la remiroir dans `/tmp/dnsmasq.d` à chaque démarrage via un hook
`/etc/rc.local`. Si tu modifies `dnsmasq-provisioning.conf` plus tard,
relance simplement `deploy-opal.sh` pour repousser la mise à jour.

`scp` ne fonctionne pas sur ce firmware (pas de serveur SFTP) - le script
utilise `ssh ... "cat > fichier" < local` à la place.

## Mise à jour de WireGuard sur l'Opal

Deux voies concrètes :

1. **Firmware officiel** : GL.iNet publie régulièrement des mises à jour
   pour le SFT1200 (dl.gl-inet.com/router/sft1200) incluant des correctifs
   liés à WireGuard - à vérifier/appliquer en premier, c'est le chemin le
   plus simple.
2. **SDK GL.iNet** (github.com/gl-inet/sdk) : le SFT1200/SF1200 utilise la
   target `siflower-1806`. Ça permet de recompiler `wireguard-tools` /
   `kmod-wireguard` contre le kernel exact de l'Opal et d'installer le
   `.ipk` résultant via `opkg` - un `opkg upgrade` simple ne suffit pas ici
   car le module kernel doit matcher l'ABI du kernel en place.

À noter : le protocole WireGuard lui-même n'a pas eu de rupture de
compatibilité depuis sa sortie - un module plus ancien reste tout à fait
interopérable avec des pairs récents. Mettre à jour apporte surtout des
correctifs de sécurité et des améliorations d'outillage, pas de la
connectivité en plus.
