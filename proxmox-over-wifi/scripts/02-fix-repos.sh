#!/bin/bash
# Swaps the subscription-only enterprise repos for the no-subscription ones.
# Without a subscription the enterprise repos return 401 and apt refuses to update.
set -euo pipefail

echo "== before =="
grep -rhE '^(URIs|Components):' /etc/apt/sources.list.d/*.sources 2>/dev/null | paste - -

for f in /etc/apt/sources.list.d/*.sources; do
  [ -e "$f" ] || continue
  if grep -q 'enterprise.proxmox.com/debian/pve' "$f"; then
    cp "$f" "$f.bak.$(date +%s)"
    sed -i 's|enterprise.proxmox.com/debian/pve|download.proxmox.com/debian/pve|; s|^Components: pve-enterprise|Components: pve-no-subscription|' "$f"
    echo "  switched pve -> no-subscription"
  fi
  if grep -q 'enterprise.proxmox.com/debian/ceph' "$f"; then
    cp "$f" "$f.bak.$(date +%s)"
    sed -i 's|enterprise.proxmox.com/debian/ceph|download.proxmox.com/debian/ceph|; s|^Components: enterprise|Components: no-subscription|' "$f"
    echo "  switched ceph -> no-subscription"
  fi
done

# Legacy .list files, if this host was upgraded from an older release.
for f in /etc/apt/sources.list.d/*.list; do
  [ -e "$f" ] || continue
  grep -q 'enterprise.proxmox.com' "$f" && { cp "$f" "$f.bak.$(date +%s)"; sed -i 's/^/#/' "$f"; echo "  commented out $f"; }
done

echo "== after =="
grep -rhE '^(URIs|Components):' /etc/apt/sources.list.d/*.sources 2>/dev/null | paste - -
apt-get update
