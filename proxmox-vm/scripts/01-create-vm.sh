#!/bin/bash
# Creates a VM with the settings the Proxmox wizard does NOT default to.
set -euo pipefail
cd "$(dirname "$0")" && . ./config.sh

grep -qE '^flags.*\b(vmx|svm)\b' /proc/cpuinfo \
  || { echo "ERROR: hardware virtualization is off. Enable Intel VT-x / AMD-V in the BIOS."; exit 1; }

qm status "$VMID" >/dev/null 2>&1 && { echo "ERROR: VM $VMID already exists"; exit 1; }
[ -f "${ISO_DIR}/${ISO_NAME}" ] || { echo "ERROR: ${ISO_DIR}/${ISO_NAME} not found - run 00-get-iso.sh"; exit 1; }
./00-get-iso.sh --verify || { echo "ERROR: ISO failed checksum"; exit 1; }

qm create "$VMID" \
  --name "$VMNAME" \
  --ostype l26 \
  --machine q35 \
  --bios ovmf \
  --efidisk0 "${DISK_STORAGE}:1,efitype=4m,pre-enrolled-keys=1" \
  --cpu host --sockets 1 --cores "$CORES" \
  --memory "$MEMORY" --balloon 0 \
  --scsihw virtio-scsi-single \
  --scsi0 "${DISK_STORAGE}:${DISK_GB},discard=on,ssd=1,iothread=1" \
  --ide2 "${ISO_STORAGE}:iso/${ISO_NAME},media=cdrom" \
  --net0 "virtio,bridge=${BRIDGE}" \
  --agent enabled=1 \
  --onboot 1 \
  --boot order='ide2;scsi0'

qm config "$VMID"
echo
echo "Created. Start it and open the console:"
echo "  qm start $VMID"
echo
echo "After the OS is installed, boot from disk instead of the installer:"
echo "  qm set $VMID --boot order='scsi0;ide2'"
echo "  qm set $VMID --ide2 none,media=cdrom"
