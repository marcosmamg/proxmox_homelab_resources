#!/bin/bash
# Settings for the VM you are about to build. Edit, then run the scripts in order.

VMID="100"
VMNAME="debian-vm"

# Sizing. Leave the host at least 4-8 GB of RAM and a couple of threads.
CORES="8"
MEMORY="12288"          # MiB
DISK_GB="150"

# Where the guest disk and the ISO live.
DISK_STORAGE="local-lvm"
ISO_STORAGE="local"
BRIDGE="vmbr0"

# ISO to install from. Pick a mirror that is actually fast from your location -
# 00-get-iso.sh measures them for you.
ISO_NAME="debian-13.7.0-amd64-netinst.iso"
ISO_MIRRORS=(
  "https://mirrors.ocf.berkeley.edu/debian-cd/current/amd64/iso-cd"
  "https://mirror.us.leaseweb.net/debian-cd/current/amd64/iso-cd"
  "https://cdimage.debian.org/debian-cd/current/amd64/iso-cd"
)
ISO_TORRENT="https://cdimage.debian.org/debian-cd/current/amd64/bt-cd/${ISO_NAME}.torrent"

ISO_DIR="/var/lib/vz/template/iso"
