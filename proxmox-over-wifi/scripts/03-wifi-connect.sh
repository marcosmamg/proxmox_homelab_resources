#!/bin/bash
# Associates the Wi-Fi card. Does NOT touch routing, so it is safe to run
# while you are still connected over Ethernet.
set -euo pipefail
cd "$(dirname "$0")" && . ./config.sh

apt-get install -y -qq wpasupplicant wireless-regdb iw rfkill >/dev/null

command -v rfkill >/dev/null && rfkill unblock wifi || true

read -rsp "Wi-Fi password for ${SSID}: " PSK; echo
[ ${#PSK} -ge 8 ] || { echo "PSK must be 8-63 characters"; exit 1; }

[ -f "$WPA_CONF" ] && cp "$WPA_CONF" "${WPA_CONF}.bak.$(date +%s)"
{
  echo "ctrl_interface=/run/wpa_supplicant"
  echo "update_config=1"
  echo "country=${COUNTRY}"
  echo
  wpa_passphrase "$SSID" "$PSK"
} > "$WPA_CONF"
# wpa_passphrase echoes the plaintext password as a comment; the hash is enough.
sed -i '/^[[:space:]]*#psk=/d' "$WPA_CONF"
chmod 600 "$WPA_CONF"
unset PSK

# The hashed key is what actually authenticates; a commented-out psk means
# wpa_supplicant starts and then silently never associates.
grep -qE '^[[:space:]]*psk=[0-9a-f]{64}$' "$WPA_CONF" \
  || { echo "ERROR: no psk hash in $WPA_CONF"; exit 1; }

systemctl enable "wpa_supplicant@${IFACE}" >/dev/null 2>&1 || true
systemctl restart "wpa_supplicant@${IFACE}"
ip link set "$IFACE" up

echo "waiting for association..."
for i in $(seq 1 25); do
  iw dev "$IFACE" link 2>/dev/null | grep -q '^Connected' && break
  sleep 1
done

if iw dev "$IFACE" link | grep -q '^Connected'; then
  iw dev "$IFACE" link | grep -E 'Connected|SSID|freq|signal|bitrate'
  echo "ASSOCIATED"
else
  echo "NOT ASSOCIATED - diagnose with:"
  echo "  journalctl -u wpa_supplicant@${IFACE} -n 40 --no-pager"
  echo "  iw dev ${IFACE} scan | grep -i 'SSID:' | sort -u"
  exit 1
fi
