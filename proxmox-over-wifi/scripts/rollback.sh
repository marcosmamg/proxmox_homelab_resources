#!/bin/bash
# Restores the pre-cutover Ethernet networking. Plug the cable back in first.
set -euo pipefail
cd "$(dirname "$0")" && . ./config.sh

[ -f /etc/network/interfaces.pre-cutover ] \
  || { echo "no /etc/network/interfaces.pre-cutover to restore"; exit 1; }

cp /etc/network/interfaces /etc/network/interfaces.failed.$(date +%s)
cp /etc/network/interfaces.pre-cutover /etc/network/interfaces
systemctl stop dnsmasq 2>/dev/null || true
ifreload -a
sleep 3
ip -br a
ip route get 1.1.1.1
echo "rolled back - plug the Ethernet cable back in if you have not"
