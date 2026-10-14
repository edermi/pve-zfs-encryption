# pve-zfs-encryption

Proxmox VE on a ZFS root with native encryption, and SSH unlock at boot.
The PVE installer can't create an encrypted pool, so this encrypts a fresh
install right after the installer finishes, before its first boot.

| Dataset | Key | Unlocked by |
|---|---|---|
| `rpool/ROOT` (the OS) | passphrase | you, at boot: console or `ssh -p 2222 root@<host>` |
| `rpool/data`, `rpool/var-lib-vz` (guests) | random keyfile `/.data.key` on the encrypted root | `zfs-load-key.service`, once root is unlocked |

Tested with PVE 9 on UEFI (systemd-boot), single disk.

## 1. Encrypt: `scripts/encrypt.sh`

1. Boot the PVE ISO in **Advanced Options → Debug Mode**. Check that
   `ls /sys/firmware/efi` lists files: a stick booted in legacy mode installs
   a bootloader that UEFI-only firmware can't boot.
2. Install as usual (ZFS). Use a throwaway root password; its hash is
   written before encryption.
3. After the installer reports **success**, debug mode drops you into a
   shell with the network up. Download the script and run the file
   (the installer has `wget`, not `curl`):

   ```
   wget -O /tmp/encrypt.sh https://raw.githubusercontent.com/edermi/pve-zfs-encryption/main/scripts/encrypt.sh
   bash /tmp/encrypt.sh
   ```

   Don't pipe it into bash: `zfs` reads the new passphrase from stdin.
4. Reboot, type the passphrase at the console. Then back up the data key
   (`base64 /.data.key`), set the real root password, regenerate the SSH
   host keys and `zpool trim rpool`.

What stays unencrypted: the ESP (kernel and initrd), pool metadata
(dataset and snapshot names, sizes, properties; that's native ZFS
encryption) and the blocks the installer wrote before the swap. They're
freed, not overwritten, which is why step 4 replaces the secrets in them
and trims.

## 2. SSH unlock

Dropbear in the initramfs on port 2222, on the host's own IP. Logging in
runs `zfsunlock` and nothing else, so a key only gets you to the passphrase
prompt. The key list mirrors `/root/.ssh/authorized_keys`.

**Ansible** (collection `edermi.pve_zfs_encryption`, role `remote_unlock`):

```yaml
# requirements.yml
collections:
  - name: https://github.com/edermi/pve-zfs-encryption.git
    type: git
    version: v1.0.0
```

```yaml
- hosts: pve_encrypted
  roles:
    - edermi.pve_zfs_encryption.remote_unlock
```

Run it regularly: it re-copies the keys when they change and rebuilds the
initramfs only then. Variables: `remote_unlock_port` (2222),
`remote_unlock_bridge` (`vmbr0`), `remote_unlock_authorized_keys_file`.

**Shell**: `scripts/remote-unlock.sh` on the host, after your key is in
root's `authorized_keys`. Safe to re-run.

Then reboot and run `ssh -p 2222 root@<host>`.

### Traps

- **`nic0` in the boot image.** PVE 9 pins NIC names with `.link` files in
  `/usr/local/lib/systemd/network`, which isn't copied into the initramfs.
  There the NIC keeps its kernel name (`eno1` etc.), `ip=...:nic0:off`
  matches nothing and dropbear never gets an address. Both the role and the
  script copy the files to `/etc/systemd/network`.
- **Empty `authorized_keys`.** If root has no key yet, the initramfs gets
  none ("Invalid authorized_keys file"). The role and the script refuse to
  run in that case.
- **The initramfs has no VPN.** From outside the LAN, jump through a host
  on it: `ssh -J somehost -p 2222 root@<host>`.

## Backups

`zfs send` of an encrypted dataset with properties (`-p`/`-R`) needs
`-w` (raw): the copy stays encrypted on the target and restoring it needs
`/.data.key`. TrueNAS sends raw when "Include Dataset Properties" is set.
PVE storage replication doesn't work with encrypted datasets.
