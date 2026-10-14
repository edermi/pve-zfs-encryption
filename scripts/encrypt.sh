#!/bin/bash
# Encrypts a fresh Proxmox VE ZFS install. Run it in the installer's debug
# shell "after installation", before the installed system boots for the first
# time, and only if the installer reported success.
#
#   rpool/ROOT                     passphrase, asked at every boot
#   rpool/data, rpool/var-lib-vz   random keyfile /.data.key on the encrypted root
#
# Run it from a file (bash encrypt.sh), not piped into bash: zfs reads the
# passphrase from stdin.
set -euo pipefail
cd /

step() { echo; echo "==> $*"; }

step "Importing rpool under /mnt"
modprobe zfs
zpool import -f -N -R /mnt rpool
trap 'echo; echo "==> Exporting rpool"; zpool export rpool' EXIT
if [ "$(zfs get -H -o value encryption rpool/ROOT)" != off ]; then
  echo "rpool/ROOT is already encrypted, nothing to do." >&2
  exit 1
fi

# send -R carries pve-1's own properties (acltype, mountpoint); everything
# else is inherited from rpool.
step "Copying the OS (rpool/ROOT) aside"
zfs snapshot -r rpool/ROOT@copy
zfs send -R rpool/ROOT@copy | zfs receive -u rpool/copyroot
zfs list -o name,used rpool/ROOT/pve-1 rpool/copyroot/pve-1

step "Recreating rpool/ROOT encrypted"
zfs destroy -r rpool/ROOT
echo "Choose the passphrase you'll type at every boot:"
until zfs create -u -o encryption=aes-256-gcm -o keyformat=passphrase rpool/ROOT; do
  echo "Try again (at least 8 characters)."
done

step "Copying the OS back into the encrypted rpool/ROOT"
zfs send -R rpool/copyroot/pve-1@copy | zfs receive -u -o encryption=on rpool/ROOT/pve-1
zfs destroy -r rpool/copyroot
zfs destroy rpool/ROOT/pve-1@copy
zpool set bootfs=rpool/ROOT/pve-1 rpool

# /mnt is the root fs here, so the keyfile sits at /mnt/... until keylocation
# is pointed at its real path.
step "Recreating rpool/data and rpool/var-lib-vz with a keyfile"
zfs mount rpool/ROOT/pve-1
dd if=/dev/urandom bs=32 count=1 of=/mnt/.data.key status=none
chmod 400 /mnt/.data.key
zfs destroy rpool/data
zfs destroy rpool/var-lib-vz
zfs create -u -o encryption=aes-256-gcm -o keyformat=raw -o keylocation=file:///mnt/.data.key rpool/data
zfs create -u -o encryption=aes-256-gcm -o keyformat=raw -o keylocation=file:///mnt/.data.key -o mountpoint=/var/lib/vz rpool/var-lib-vz
zfs set keylocation=file:///.data.key rpool/data rpool/var-lib-vz

# load-key -a skips rpool/ROOT, whose key the initramfs has already loaded.
step "Installing zfs-load-key.service (loads the keyfile keys at boot)"
cat > /mnt/etc/systemd/system/zfs-load-key.service <<'EOF'
[Unit]
Description=Load ZFS encryption keys from keyfiles
DefaultDependencies=no
After=zfs-import.target
Before=zfs-mount.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/zfs load-key -a

[Install]
WantedBy=zfs-mount.service
EOF
mkdir -p /mnt/etc/systemd/system/zfs-mount.service.wants
ln -sf /etc/systemd/system/zfs-load-key.service /mnt/etc/systemd/system/zfs-mount.service.wants/

step "Result"
zfs get -r -t filesystem encryption,keystatus,encryptionroot rpool
echo
echo "Done. Back up /.data.key (base64 /.data.key) after the first boot."
echo "Remove the USB stick and reboot."
