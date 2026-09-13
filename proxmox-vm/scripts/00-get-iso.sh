#!/bin/bash
# Downloads an installer ISO and verifies it. Never resumes across mirrors -
# that silently produces a corrupt file of the wrong size.
#   ./00-get-iso.sh            download (multi-mirror) + verify
#   ./00-get-iso.sh --race     just measure mirror speeds
#   ./00-get-iso.sh --torrent  download via BitTorrent (verifies every chunk)
set -uo pipefail
cd "$(dirname "$0")" && . ./config.sh

race(){
  echo "measuring mirrors (10MB sample each)..."
  for m in "${ISO_MIRRORS[@]}"; do
    printf '  %-45s ' "$(echo "$m" | cut -d/ -f3)"
    curl -s -o /dev/null -r 0-10000000 -w '%{speed_download} B/s\n' --max-time 20 \
      "${m}/${ISO_NAME}" 2>/dev/null || echo "unreachable"
  done
}

verify(){
  cd "$ISO_DIR" || exit 1
  curl -sO "${ISO_MIRRORS[0]}/SHA256SUMS" || { echo "could not fetch SHA256SUMS"; return 1; }
  if sha256sum -c SHA256SUMS 2>/dev/null | grep -q "^${ISO_NAME}: OK$"; then
    echo "CHECKSUM OK - $(ls -lh "$ISO_NAME" | awk '{print $5}')"
    return 0
  fi
  echo "CHECKSUM FAILED - do not boot this image"
  ls -lh "$ISO_NAME" 2>/dev/null
  return 1
}

case "${1:-}" in
  --race)    race; exit 0 ;;
  --verify)  verify; exit $? ;;
esac

mkdir -p "$ISO_DIR"
command -v aria2c >/dev/null || apt-get install -y -qq aria2

if [ "${1:-}" = "--torrent" ]; then
  # Torrents hash-check every chunk, so a corrupt result is not possible.
  aria2c --seed-time=0 -d "$ISO_DIR" "$ISO_TORRENT"
else
  # A partial file from a different mirror cannot be resumed safely. Start clean.
  rm -f "${ISO_DIR}/${ISO_NAME}"
  urls=(); for m in "${ISO_MIRRORS[@]}"; do urls+=("${m}/${ISO_NAME}"); done
  # -x: connections per host, -s: total splits. Pulls from all mirrors at once.
  aria2c -x 4 -s 8 -k 1M -d "$ISO_DIR" -o "$ISO_NAME" "${urls[@]}"
fi

verify
