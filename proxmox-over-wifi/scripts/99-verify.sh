#!/bin/bash
# Read-only end-to-end check. Run any time, especially after a reboot.
set -uo pipefail
cd "$(dirname "$0")" && . ./config.sh

pass=0; fail=0
hr(){ echo; echo "=== $1 ==="; }
ok(){ echo "  OK    $1"; pass=$((pass+1)); }
bad(){ echo "  FAIL  $1"; fail=$((fail+1)); }

hr "wifi association"
iw dev "$IFACE" link 2>/dev/null | grep -E 'Connected|SSID|freq|signal|bitrate' || true
if wpa_cli -i "$IFACE" status 2>/dev/null | grep -q 'wpa_state=COMPLETED'; then
  ok "wpa_state=COMPLETED"
else
  bad "not associated"
fi
systemctl is-enabled "wpa_supplicant@${IFACE}" 2>/dev/null | grep -q enabled \
  && ok "wpa_supplicant@${IFACE} enabled at boot" \
  || bad "wpa_supplicant@${IFACE} NOT enabled - host will not come back after reboot"

# Power save on this driver can cost 10x+ throughput.
PS=$(iw dev "$IFACE" get power_save 2>/dev/null | awk '{print $3}')
[ "$PS" = "off" ] && ok "power save off" || bad "power save is '$PS' - expect badly degraded throughput"
systemctl is-enabled "wifi-powersave-off@${IFACE}" 2>/dev/null | grep -q enabled \
  && ok "power-save-off unit enabled at boot" \
  || bad "power-save-off unit NOT enabled - it will come back on after reboot"
systemctl is-enabled ensure-default-route 2>/dev/null | grep -q enabled \
  && ok "ensure-default-route enabled at boot" \
  || bad "ensure-default-route NOT enabled - a slow association can leave you with no route"

hr "interfaces"
ip -br a
ip -br a show "$IFACE" | grep -q ' UP ' && ok "$IFACE up" || bad "$IFACE down"

hr "routing"
ip route
ip route get 1.1.1.1 | grep -q "dev ${IFACE}" \
  && ok "default route on $IFACE" || bad "default route NOT on $IFACE"

hr "ethernet"
if [ "$(cat /sys/class/net/${ETH_IFACE}/operstate 2>/dev/null)" = "up" ]; then
  echo "  note: $ETH_IFACE still up (cable plugged) - Wi-Fi path not fully proven"
else
  ok "$ETH_IFACE down (cable out)"
fi

hr "connectivity"
ping -c2 -W2 "$GATEWAY" >/dev/null 2>&1 && ok "gateway" || bad "gateway"
ping -c2 -W2 1.1.1.1    >/dev/null 2>&1 && ok "internet" || bad "internet"
getent hosts deb.debian.org >/dev/null 2>&1 && ok "dns" || bad "dns"

hr "nat for guests"
[ "$(sysctl -n net.ipv4.ip_forward)" = "1" ] && ok "ip_forward=1" || bad "ip_forward disabled"
iptables -t nat -S POSTROUTING | grep -q "${VM_SUBNET}.*${IFACE}.*MASQUERADE" \
  && ok "MASQUERADE rule present" || bad "MASQUERADE rule MISSING"

hr "dhcp for guests"
systemctl is-active dnsmasq >/dev/null && ok "dnsmasq running" || bad "dnsmasq not running"
if ss -lnup | grep -q "${VM_GW}:53"; then ok "dns bound to ${VM_GW}"; else bad "dns not bound to ${VM_GW}"; fi
if ss -lnup | grep -qE "${HOST_IP}:53"; then
  bad "dnsmasq is listening on ${HOST_IP}:53 - open resolver on your LAN"
else
  ok "not exposed on LAN"
fi
echo "  leases:"; cat /var/lib/misc/dnsmasq.leases 2>/dev/null | sed 's/^/    /' || echo "    (none yet)"

hr "clock"
timedatectl | grep -E 'Universal time|synchronized'
timedatectl show -p NTPSynchronized --value | grep -q yes && ok "clock synced" || bad "clock not synced"

hr "repos"
grep -rhE '^(URIs|Components):' /etc/apt/sources.list.d/*.sources 2>/dev/null | paste - -
grep -rqs 'enterprise.proxmox.com' /etc/apt/sources.list.d/*.sources \
  && bad "enterprise repo still enabled (401 without a subscription)" \
  || ok "no enterprise repos"

hr "web ui"
ss -lnt | grep -q ':8006' && ok "pveproxy listening on 8006" || bad "pveproxy not listening"

hr "result"
echo "  passed: $pass   failed: $fail"
[ $fail -eq 0 ] && echo "  ALL CHECKS PASS" || echo "  see failures above"
exit $((fail > 0))
