#!/bin/bash
# Moves the uplink to Wi-Fi and turns vmbr0 into a NAT-only bridge for guests.
# RUN THIS AT THE PHYSICAL CONSOLE. It rewrites routing.
set -euo pipefail
cd "$(dirname "$0")" && . ./config.sh

iw dev "$IFACE" link 2>/dev/null | grep -q '^Connected' \
  || { echo "ERROR: $IFACE is not associated. Run 03-wifi-connect.sh first."; exit 1; }

cp /etc/network/interfaces /etc/network/interfaces.pre-cutover
echo "  backup: /etc/network/interfaces.pre-cutover"

echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-nat.conf
sysctl -q -p /etc/sysctl.d/99-nat.conf

# Proxmox's web UI parser is strict: no inline comments, no stray blank lines.
cat > /etc/network/interfaces <<CONF
auto lo
iface lo inet loopback

iface ${ETH_IFACE} inet manual

auto ${IFACE}
iface ${IFACE} inet static
        address ${HOST_IP}/${HOST_CIDR}
        gateway ${GATEWAY}

auto vmbr0
iface vmbr0 inet static
        address ${VM_GW}/${VM_SUBNET#*/}
        bridge-ports none
        bridge-stp off
        bridge-fd 0
        post-up   iptables -t nat -A POSTROUTING -s ${VM_SUBNET} -o ${IFACE} -j MASQUERADE
        post-down iptables -t nat -D POSTROUTING -s ${VM_SUBNET} -o ${IFACE} -j MASQUERADE

source /etc/network/interfaces.d/*
CONF
chmod 644 /etc/network/interfaces

apt-get install -y -qq dnsmasq >/dev/null
# bind-dynamic, not bind-interfaces: vmbr0 has no carrier until a guest attaches,
# and listen-address keeps :53 off the LAN-facing Wi-Fi address.
cat > /etc/dnsmasq.d/vmbr0.conf <<DNSCONF
interface=vmbr0
bind-dynamic
listen-address=${VM_GW}
no-dhcp-interface=${IFACE}
dhcp-range=${VM_DHCP_START},${VM_DHCP_END},12h
dhcp-option=option:router,${VM_GW}
dhcp-option=option:dns-server,${DNS1},${DNS2}
DNSCONF
systemctl restart dnsmasq

ifreload -a
sleep 3
ip -br a
ip route get 1.1.1.1

echo
if ip route get 1.1.1.1 | grep -q "dev ${IFACE}"; then
  echo "CUTOVER OK - default route is on ${IFACE}. Safe to unplug Ethernet."
else
  echo "CUTOVER FAILED - roll back with ./rollback.sh"
  exit 1
fi
