#!/bin/bash
# Read-only. Confirms the host can reach the internet, resolve names, and
# validate package signatures BEFORE any network changes are made.
set -uo pipefail
cd "$(dirname "$0")" && . ./config.sh

fail=0
hr(){ echo; echo "=== $1 ==="; }
ok(){ echo "  OK    $1"; }
bad(){ echo "  FAIL  $1"; fail=1; }

hr "gateway"
ping -c2 -W2 "$GATEWAY" >/dev/null 2>&1 && ok "gateway $GATEWAY reachable" || bad "gateway $GATEWAY unreachable"

hr "internet by IP"
ping -c2 -W2 "$DNS1" >/dev/null 2>&1 && ok "$DNS1 reachable" || bad "no internet by IP"

hr "dns"
grep ^nameserver /etc/resolv.conf || bad "no nameservers configured"
getent hosts deb.debian.org >/dev/null 2>&1 && ok "resolution works" || bad "cannot resolve deb.debian.org"
for ns in $(awk '/^nameserver/{print $2}' /etc/resolv.conf); do
  if command -v dig >/dev/null; then
    dig +short +time=2 +tries=1 deb.debian.org "@$ns" >/dev/null 2>&1 \
      && ok "resolver $ns answers" || bad "resolver $ns does NOT answer (set DNS to $DNS1 in System -> DNS)"
  fi
done

hr "clock"
timedatectl | grep -E 'Universal time|synchronized|NTP service'
if timedatectl show -p NTPSynchronized --value | grep -q yes; then
  ok "clock synchronized"
else
  bad "clock NOT synchronized - apt will reject 'not live until' signatures"
  command -v chronyc >/dev/null && chronyc sources -v | tail -n +9
fi

hr "wireless hardware"
command -v rfkill >/dev/null && rfkill list || echo "  (install rfkill)"
ip link show "$IFACE" >/dev/null 2>&1 && ok "$IFACE present" || bad "$IFACE not found - check 'ip -br a' and fix IFACE in config.sh"
dmesg 2>/dev/null | grep -i 'regulatory.db' | tail -2

hr "apt"
apt-get update -qq 2>&1 | grep -Ei 'err|401|not signed' && bad "apt errors above" || ok "apt update clean"

hr "result"
[ $fail -eq 0 ] && echo "PREFLIGHT PASS - safe to continue" || echo "PREFLIGHT FAIL - fix the items above first"
exit $fail
