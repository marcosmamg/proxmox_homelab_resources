#!/bin/bash
# Fixes the two things that silently break apt on a fresh Proxmox install:
# a router that does not answer DNS, and a clock that drifted because chrony
# could not resolve its NTP pool at boot.
set -euo pipefail
cd "$(dirname "$0")" && . ./config.sh

echo "== DNS =="
cp /etc/resolv.conf /etc/resolv.conf.bak.$(date +%s) 2>/dev/null || true
search=$(awk '/^search/{print $2; exit}' /etc/resolv.conf 2>/dev/null || true)
{ [ -n "${search:-}" ] && echo "search $search"; echo "nameserver $DNS1"; echo "nameserver $DNS2"; } > /etc/resolv.conf
getent hosts deb.debian.org >/dev/null && echo "  resolution OK" || { echo "  resolution still failing"; exit 1; }

echo "== NTP =="
apt-get install -y -qq chrony >/dev/null 2>&1 || true
# chrony drops its pool entries if DNS was dead at boot; a restart re-resolves them.
systemctl restart chrony
for i in $(seq 1 15); do
  chronyc sources 2>/dev/null | grep -q '^\^' && break
  sleep 1
done
chronyc sources -v | tail -n +9
chronyc makestep >/dev/null && echo "  stepped clock"
sleep 2
hwclock --systohc && echo "  RTC written"
timedatectl | grep -E 'Universal time|synchronized'

echo
echo "NOTE: make this permanent in the UI at System -> DNS, or /etc/resolv.conf"
echo "      gets rewritten. Set DNS server 1 = $DNS1, server 2 = $DNS2."
