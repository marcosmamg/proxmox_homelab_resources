#!/bin/bash
# Publishes one port of a NATed guest on the host's LAN address, and persists
# the rule so it survives a reboot.
#   ./02-expose-port.sh 80 10.10.10.50 80
#   ./02-expose-port.sh 8080 10.10.10.50 3000
set -euo pipefail
cd "$(dirname "$0")" && . ./config.sh

HOST_PORT="${1:-}"; GUEST_IP="${2:-}"; GUEST_PORT="${3:-$HOST_PORT}"
PROTO="${4:-tcp}"
[ -n "$HOST_PORT" ] && [ -n "$GUEST_IP" ] || {
  echo "usage: $0 <host-port> <guest-ip> [guest-port] [tcp|udp]"; exit 1; }

WAN=$(ip route show default | awk '{print $5; exit}')
[ -n "$WAN" ] || { echo "ERROR: no default route"; exit 1; }

if ss -lnt "sport = :${HOST_PORT}" | grep -q LISTEN; then
  echo "WARNING: something on the host already listens on ${HOST_PORT}"
  echo "         (8006 is the Proxmox UI - do not take that one)"
fi

RULE="PREROUTING -i ${WAN} -p ${PROTO} --dport ${HOST_PORT} -j DNAT --to ${GUEST_IP}:${GUEST_PORT}"
iptables -t nat -C ${RULE} 2>/dev/null && { echo "rule already present"; exit 0; }
iptables -t nat -A ${RULE}

# Guests reaching the host's own LAN IP need the reply to come back through NAT.
HAIRPIN="POSTROUTING -d ${GUEST_IP} -p ${PROTO} --dport ${GUEST_PORT} -j MASQUERADE"
iptables -t nat -C ${HAIRPIN} 2>/dev/null || iptables -t nat -A ${HAIRPIN}

mkdir -p /etc/iptables
iptables-save > /etc/iptables/rules.v4

cat > /etc/systemd/system/restore-portforwards.service <<UNIT
[Unit]
Description=Restore NAT port forwards
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'iptables-restore -n < /etc/iptables/rules.v4'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable restore-portforwards >/dev/null 2>&1 || true

echo "published ${HOST_PORT}/${PROTO} -> ${GUEST_IP}:${GUEST_PORT} via ${WAN}"
iptables -t nat -S PREROUTING | grep "${HOST_PORT}"
