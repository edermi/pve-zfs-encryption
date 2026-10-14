#!/bin/bash
# Sets up SSH unlock for an encrypted rpool/ROOT on Proxmox VE: dropbear in the
# initramfs, listening on a static IP, where login runs zfsunlock and nothing
# else. Run it on the host as root, after your SSH key is in
# /root/.ssh/authorized_keys. Safe to re-run, e.g. after adding keys.
#
#   PORT=2222 BRIDGE=vmbr0 bash remote-unlock.sh
set -euo pipefail

PORT=${PORT:-2222}
BRIDGE=${BRIDGE:-vmbr0}

step() { echo; echo "==> $*"; }

# Drops any ip=... from a kernel command line and appends the new one.
with_ip() {
  local keep=() args a
  read -ra args <<< "$1"
  for a in "${args[@]}"; do [[ $a == ip=* ]] || keep+=("$a"); done
  echo "${keep[*]:+${keep[*]} }$IPARG"
}

step "Installing dropbear-initramfs"
# Before the repos are switched to no-subscription, the enterprise repo 401s.
apt-get update -qq || true
apt-get install -y -qq --no-install-recommends dropbear-initramfs

step "Copying root's authorized_keys into the initramfs"
if ! grep -qE '^([^#[:blank:]].* )?(ssh-|ecdsa-|sk-)' /root/.ssh/authorized_keys; then
  echo "No SSH key in /root/.ssh/authorized_keys. Add yours first (ssh-copy-id)." >&2
  exit 1
fi
install -m 600 /root/.ssh/authorized_keys /etc/dropbear/initramfs/authorized_keys

step "Configuring dropbear: port $PORT, login runs zfsunlock only"
conf=/etc/dropbear/initramfs/dropbear.conf
sed -i '/^DROPBEAR_OPTIONS=/d' "$conf"
echo "DROPBEAR_OPTIONS=\"-I 180 -j -k -s -p $PORT -c zfsunlock\"" >> "$conf"

# PVE 9 pins NIC names (nic0, ...) with .link files in a directory that
# doesn't make it into the initramfs. Without them the NIC has its kernel
# name there and ip= points at an interface that doesn't exist.
step "Copying NIC name pinning into the initramfs"
if compgen -G '/usr/local/lib/systemd/network/*.link' > /dev/null; then
  mkdir -p /etc/systemd/network
  cp -v /usr/local/lib/systemd/network/*.link /etc/systemd/network/
else
  echo "No pinned NIC names, nothing to copy."
fi

step "Building the ip= kernel parameter from $BRIDGE"
NIC=$(ls "/sys/class/net/$BRIDGE/brif" | grep -Ev '^(tap|veth|fwpr|fwln)' | head -1)
GW=$(ip -4 route show default | awk '{print $3; exit}')
ADDR=$(ip -4 -o addr show "$BRIDGE" | awk '{print $4; exit}')
P=${ADDR#*/}
M=$(( (0xffffffff << (32 - P)) & 0xffffffff ))
MASK=$((M >> 24 & 255)).$((M >> 16 & 255)).$((M >> 8 & 255)).$((M & 255))
IPARG="ip=${ADDR%/*}::$GW:$MASK:$(hostname):$NIC:off"
echo "$IPARG"

# Both bootloaders get it; the one that isn't in use ignores its file.
if [ -f /etc/kernel/cmdline ]; then
  with_ip "$(cat /etc/kernel/cmdline)" > /etc/kernel/cmdline.new
  mv /etc/kernel/cmdline.new /etc/kernel/cmdline
fi
if [ -f /etc/default/grub ]; then
  grub=$(. /etc/default/grub; echo "${GRUB_CMDLINE_LINUX:-}")
  sed -i "s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"$(with_ip "$grub")\"|" /etc/default/grub
fi

step "Rebuilding the initramfs and syncing the boot partitions"
update-initramfs -u -k all
proxmox-boot-tool refresh

step "Check: must list zfsunlock, dropbear and (if pinned) your .link file"
lsinitramfs "/boot/initrd.img-$(uname -r)" | grep -E 'zfsunlock|bin/dropbear|\.link$'

echo
echo "Done. Reboot, then unlock with: ssh -p $PORT root@${ADDR%/*}"
