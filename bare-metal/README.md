# bare-metal-hmlab

Provisioning automatisé du homelab sur mini PC, via un GL.iNet Opal
(GL-SFT1200) en réseau de provisioning isolé, sans clé USB.

Fleet actuelle : **host1, host2, host3 - tous en Rocky Linux 9**, via
kickstart. Simplifié depuis une approche mixte Proxmox/Rocky qui s'est
avérée plus fragile (installeur Proxmox plus gros, dépendance à une clé
USB sur l'Opal, etc.) - Rocky/Anaconda est plus simple et plus fiable à
netbooter.

## Comment ça marche

1. L'Opal est reconfiguré en routeur isolé (LAN `10.10.10.0/24`, WAN uplinké
   vers le réseau domestique pour l'accès internet pendant l'install).
2. Le host boote en PXE (à activer dans son BIOS/UEFI).
3. `dnsmasq` sur l'Opal reconnaît chaque mini PC par adresse MAC
   (réservations statiques dans `router/dnsmasq-provisioning.conf`,
   source de vérité : `hosts.csv`) et chaîne vers iPXE.
4. iPXE (`router/boot.ipxe`) route par MAC vers le bon kickstart, puis va
   chercher le kernel/initrd Rocky et le kickstart directement en HTTPS
   (mirror officiel Rocky + ce repo GitHub) - rien de volumineux stocké
   sur les 128MB de flash de l'Opal, aucune clé USB nécessaire.
5. Anaconda installe selon le kickstart correspondant : partitionnement,
   hostname, IP statique, paquets, post-install.

## Après une install réussie : retirer le host du dispatch PXE

Le boot PXE lui-même ne redéclenche pas une réinstall à chaque reboot — un
firmware normal essaie le disque local en premier et ne retombe sur le
réseau que si le disque ne fournit aucun bootloader valide (ou si tu forces
un boot réseau ponctuel, ex. `efibootmgr -n`). Mais `boot.ipxe` n'a aucune
protection "skip si déjà installé" : si un host retombe un jour sur PXE
(ordre de boot mal configuré, disque en panne, etc.), il se refait wiper
sans prévenir. C'est exactement ce qui est arrivé à host2 (boucle
install/reboot/reinstall) avant qu'on corrige son ordre de boot BIOS.

Une fois qu'un host est confirmé opérationnel, retire son entrée du
pipeline. Deux options :

- **Supprimer** la ligne `dhcp-host=...` et le bloc `iseq .../:hostX` -
  plus propre si le host part pour de bon.
- **Commenter** (`#` devant la ligne `dhcp-host=...` dans
  `dnsmasq-provisioning.conf`, et devant la ligne
  `iseq ${mac} ... && goto hostX ||` dans `boot.ipxe`) - recommandé si tu
  comptes réactiver plus tard : ça évite de retaper/retrouver la MAC, tu
  décommentes juste la ligne. Le bloc `:hostX` (kernel/initrd/boot) peut
  rester tel quel dans les deux cas - une fois que rien ne saute dessus
  (`goto hostX`), il est inerte. C'est l'approche utilisée pour host2 en ce
  moment (déjà installé, dispatch commenté dans `boot.ipxe` uniquement -
  sa réservation `dhcp-host` reste active puisque c'est juste une IP pin,
  pas un déclencheur PXE).

Dans les deux cas, relance `./router/deploy-opal.sh <ip-de-l-opal>` pour
pousser le changement. Le host tombera alors dans le cas `:unknown` (shell
iPXE, pas d'install) s'il retente un PXE boot par accident.

## Structure

- `hosts.csv` - mapping hostname / MAC / IP pour les 3 hosts
- `router/dnsmasq-provisioning.conf` - DHCP + réservations + chainload iPXE
- `router/boot.ipxe` - menu de boot iPXE, dispatch par MAC
- `router/deploy-opal.sh` - déploie la config sur l'Opal via SSH
- `kickstart/ks-host{1,2,3}.cfg` - un kickstart Rocky par host

## À faire avant de lancer

- Remplacer la clé SSH placeholder dans chaque `kickstart/ks-hostX.cfg`
  si tu changes de clé (actuellement déjà remplie avec la clé utilisée
  pour host2)
- Reconfigurer le LAN de l'Opal en `10.10.10.1/24` (LuCI ou `uci`) - fait
- Activer le boot PXE dans le BIOS/UEFI de chaque host, et vérifier que le
  disque local reste prioritaire dans l'ordre de boot une fois l'install
  terminée (sinon boucle de réinstall - voir section précédente)

## Déploiement

```
./router/deploy-opal.sh <ip-de-l-opal>
```

Le script vérifie l'espace disque libre sur l'Opal, installe `dnsmasq-full`
si besoin, récupère le binaire iPXE (`snponly.efi`, build UEFI natif - voir
note ci-dessous), et pousse la config + `boot.ipxe`.

**Note UEFI vs BIOS legacy** : tous les hosts ici bootent en UEFI pur
(confirmé via leurs entrées `efibootmgr` type `UEFI: PXE IPv4 ...`). On
sert donc `snponly.efi` (build iPXE natif UEFI, réutilise le driver réseau
déjà initialisé par le firmware) plutôt que `undionly.kpxe` (BIOS legacy) -
ce dernier se télécharge très bien par TFTP mais un firmware UEFI ne peut
pas l'exécuter, et retombe silencieusement sur l'entrée de boot suivante
sans afficher d'erreur. C'est ce qui a fait perdre pas mal de temps sur le
debug de host3 au départ.

**Note firmware dnsmasq** : sur ce GL-SFT1200, `confdir` est réglé sur
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
