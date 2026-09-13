#!/bin/bash
# Read-only. The numbers that actually predict storage trouble on a Proxmox
# host: root filling up, and thin pools filling up.
set -uo pipefail

warn=0
hr(){ echo; echo "=== $1 ==="; }

hr "root filesystem"
df -h / | tail -1
ROOTPCT=$(df --output=pcent / | tail -1 | tr -dc '0-9')
if   [ "$ROOTPCT" -ge 90 ]; then echo "  CRITICAL: / at ${ROOTPCT}% - Proxmox services will misbehave"; warn=1
elif [ "$ROOTPCT" -ge 80 ]; then echo "  WARN: / at ${ROOTPCT}%"; warn=1
else echo "  OK: / at ${ROOTPCT}%"; fi

hr "biggest consumers of /"
du -xh --max-depth=2 / 2>/dev/null | sort -rh | head -8

hr "thin pools"
# A thin pool that hits 100% - data OR metadata - fails writes and can corrupt
# guest filesystems. Watch both percentages.
if lvs --noheadings -o lv_attr 2>/dev/null | grep -q '^ *t'; then
  lvs -o lv_name,vg_name,lv_size,data_percent,metadata_percent
  while read -r name dpct mpct; do
    [ -z "${dpct:-}" ] && continue
    d=${dpct%%.*}; m=${mpct%%.*}
    if [ "${d:-0}" -ge 90 ] || [ "${m:-0}" -ge 90 ]; then
      echo "  CRITICAL: pool $name data=${dpct}% meta=${mpct}%"; warn=1
    elif [ "${d:-0}" -ge 80 ] || [ "${m:-0}" -ge 80 ]; then
      echo "  WARN: pool $name data=${dpct}% meta=${mpct}%"; warn=1
    else
      echo "  OK: pool $name data=${dpct}% meta=${mpct}%"
    fi
  done < <(lvs --noheadings -o lv_name,data_percent,metadata_percent --select 'lv_attr=~^t' 2>/dev/null)
else
  echo "  no thin pools"
fi

hr "overcommitment"
# Provisioned guest disk space vs. what the pool physically has.
for vg in $(vgs --noheadings -o vg_name 2>/dev/null | tr -d ' '); do
  POOL=$(lvs --noheadings -o lv_name --select "lv_attr=~^t && vg_name=$vg" 2>/dev/null | tr -d ' ' | head -1)
  [ -z "$POOL" ] && continue
  PSIZE=$(lvs --noheadings -o lv_size --units g --nosuffix "$vg/$POOL" 2>/dev/null | tr -d ' ')
  ALLOC=$(lvs --noheadings -o lv_size --units g --nosuffix --select "pool_lv=$POOL" 2>/dev/null | tr -d ' ' | paste -sd+ | bc 2>/dev/null)
  echo "  pool $vg/$POOL: ${PSIZE}G physical, ${ALLOC:-0}G provisioned to guests"
  echo "  (provisioned may exceed physical - that is thin provisioning working as intended)"
done

hr "proxmox storages"
pvesm status

hr "disk health"
for d in $(lsblk -dno NAME,TYPE | awk '$2=="disk"{print $1}'); do
  H=$(smartctl -H "/dev/$d" 2>/dev/null | grep -iE 'overall-health|SMART Health' | sed 's/.*: *//')
  printf '  %-14s %s\n' "/dev/$d" "${H:-unknown}"
  smartctl -A "/dev/$d" 2>/dev/null | grep -iE 'Reallocated_Sector|Current_Pending|Offline_Uncorrect|Media_Wearout|Percentage Used' | sed 's/^/      /'
done

hr "result"
[ $warn -eq 0 ] && echo "  no storage warnings" || echo "  see warnings above"
exit $warn
