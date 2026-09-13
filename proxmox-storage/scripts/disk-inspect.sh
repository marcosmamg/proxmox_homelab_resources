#!/bin/bash
# Read-only. Shows every disk, how it is partitioned, what Proxmox thinks it
# has, and where the space actually went. Run before changing anything.
set -uo pipefail

hr(){ echo; echo "=== $1 ==="; }

hr "block devices"
lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINT,MODEL

hr "stable device names"
# /dev/sdX can change between boots; these never do.
ls -l /dev/disk/by-id/ 2>/dev/null | grep -vE 'part[0-9]|dm-|lvm-pv' | awk '{print $9, $10, $11}'

hr "partition tables"
for d in $(lsblk -dno NAME,TYPE | awk '$2=="disk"{print $1}'); do
  echo "--- /dev/$d"
  sgdisk -p "/dev/$d" 2>/dev/null | grep -E 'Disk /|Model|Number|^ +[0-9]' || fdisk -l "/dev/$d" 2>/dev/null | tail -5
done

hr "lvm"
pvs 2>/dev/null
vgs 2>/dev/null
lvs -o lv_name,vg_name,lv_size,data_percent,metadata_percent 2>/dev/null

hr "filesystems"
df -hT -x tmpfs -x devtmpfs -x overlay

hr "proxmox storage"
pvesm status
echo
cat /etc/pve/storage.cfg

hr "smart health"
for d in $(lsblk -dno NAME,TYPE | awk '$2=="disk"{print $1}'); do
  printf '%-12s ' "/dev/$d"
  smartctl -H "/dev/$d" 2>/dev/null | grep -iE 'overall-health|SMART Health' || echo "(smartctl not installed?)"
done

hr "unmounted / unused disks"
for d in $(lsblk -dno NAME,TYPE | awk '$2=="disk"{print $1}'); do
  if ! lsblk -no MOUNTPOINT "/dev/$d" | grep -q . && ! pvs 2>/dev/null | grep -q "/dev/$d"; then
    echo "  /dev/$d appears unused - candidate for new storage"
  fi
done
