#!/bin/bash
# DESTRUCTIVE. Wipes a disk, formats it ext4, mounts it, and registers it as
# Proxmox Directory storage. Requires the disk's by-id path so you cannot
# typo your way onto the wrong device.
#
#   ./add-directory-storage.sh /dev/disk/by-id/ata-XXXX media
set -euo pipefail

DISK="${1:-}"
NAME="${2:-}"
CONTENT="${3:-backup,iso,vztmpl}"
MOUNT="/mnt/pve/${NAME}"

usage(){ echo "usage: $0 /dev/disk/by-id/<disk> <storage-name> [content-types]"; exit 1; }
[ -n "$DISK" ] && [ -n "$NAME" ] || usage
[[ "$DISK" == /dev/disk/by-id/* ]] || { echo "ERROR: pass the /dev/disk/by-id/ path, not /dev/sdX"; usage; }
[ -b "$DISK" ] || { echo "ERROR: $DISK is not a block device"; exit 1; }
[[ "$NAME" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || { echo "ERROR: bad storage name"; exit 1; }

REAL=$(readlink -f "$DISK")

# Refuse to touch anything currently in use.
if lsblk -no MOUNTPOINT "$REAL" | grep -q . ; then
  echo "ERROR: $REAL has mounted partitions:"; lsblk "$REAL"; exit 1
fi
if pvs 2>/dev/null | grep -q "$REAL"; then
  echo "ERROR: $REAL is an LVM physical volume. Refusing."; exit 1
fi
if pvesm status 2>/dev/null | grep -q "^${NAME} "; then
  echo "ERROR: storage '${NAME}' already exists"; exit 1
fi

echo "About to DESTROY all data on:"
lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MODEL "$REAL"
echo
echo "  device:  $REAL  ($DISK)"
echo "  storage: $NAME at $MOUNT"
echo "  content: $CONTENT"
echo
read -rp "Type the storage name '${NAME}' to confirm: " CONFIRM
[ "$CONFIRM" = "$NAME" ] || { echo "aborted"; exit 1; }

wipefs -a "$REAL"
sgdisk -Z "$REAL"
sgdisk -n1:0:0 -t1:8300 -c1:"$NAME" "$REAL"
partprobe "$REAL"
sleep 2

PART="${DISK}-part1"
[ -b "$PART" ] || PART=$(lsblk -lno PATH,TYPE "$REAL" | awk '$2=="part"{print $1; exit}')
[ -b "$PART" ] || { echo "ERROR: no partition appeared"; exit 1; }

# -m 0: skip ext4's 5% root reserve (~200GB on 4TB) - pointless on a data disk.
# -T largefile: fewer inodes, for disks holding big files. Drop it for many small ones.
mkfs.ext4 -F -L "$NAME" -m 0 -T largefile "$PART"

mkdir -p "$MOUNT"
UUID=$(blkid -s UUID -o value "$PART")
grep -q "$UUID" /etc/fstab || echo "UUID=$UUID $MOUNT ext4 defaults,nofail 0 2" >> /etc/fstab
mount -a
mountpoint -q "$MOUNT" || { echo "ERROR: $MOUNT did not mount"; exit 1; }

pvesm add dir "$NAME" --path "$MOUNT" --content "$CONTENT"

echo
df -h "$MOUNT"
pvesm status
echo
echo "DONE. '$NAME' is mounted at $MOUNT and registered with Proxmox."
