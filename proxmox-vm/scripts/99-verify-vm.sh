#!/bin/bash
# Read-only. Checks the VM's config, whether it got a lease, and what is
# published to the LAN on its behalf.
set -uo pipefail
cd "$(dirname "$0")" && . ./config.sh

hr(){ echo; echo "=== $1 ==="; }

hr "host virtualization"
grep -qE '^flags.*\b(vmx|svm)\b' /proc/cpuinfo && echo "  OK   VT-x/AMD-V enabled" || echo "  FAIL VT-x/AMD-V off in BIOS"
lsmod | grep -q kvm && echo "  OK   kvm module loaded" || echo "  FAIL kvm not loaded"

hr "vm config"
qm config "$VMID" 2>/dev/null || { echo "  VM $VMID does not exist"; exit 1; }

hr "vm state"
qm status "$VMID"

hr "settings worth confirming"
cfg=$(qm config "$VMID")
chk(){ echo "$cfg" | grep -q "$1" && echo "  OK   $2" || echo "  WARN $2"; }
chk 'cpu: host'             'cpu=host (guest sees real CPU flags)'
chk 'balloon: 0'            'ballooning off (JVMs and databases dislike it)'
chk 'scsihw: virtio-scsi-single' 'virtio-scsi-single'
chk 'discard=on'            'discard on (frees thin-pool blocks)'
chk 'ssd=1'                 'ssd emulation (guest picks the right scheduler)'
chk 'iothread=1'            'iothread'
chk 'agent: 1'              'qemu guest agent enabled'
chk 'onboot: 1'             'starts at boot'

hr "guest address"
qm agent "$VMID" network-get-interfaces 2>/dev/null \
  | grep -E '"ip-address"' | head -5 \
  || echo "  (guest agent not responding - install qemu-guest-agent inside the VM)"
echo "  dhcp leases:"; cat /var/lib/misc/dnsmasq.leases 2>/dev/null | sed 's/^/    /' || echo "    none"

hr "published ports"
iptables -t nat -S PREROUTING | grep DNAT || echo "  none"

hr "host headroom"
free -h | head -2
echo "  VM is configured for ${MEMORY} MiB"
