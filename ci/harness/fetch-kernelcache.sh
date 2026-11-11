#!/usr/bin/env bash
# Fetch the macOS 27 kernelcache out of the pinned IPSW with HTTP ranges (no 20 GB download) and decode its IM4P.
#
#   ci/harness/fetch-kernelcache.sh
#
# Output: out/kc/kc27.bin — the MH_FILESET kernelcache k27/kc-build27.py borrows the kept kexts from.
# Requires: python3, the `pyimg4` package (installed by the workflow), configs/macos-<tag>-*.json.
set -euo pipefail
cd "$(dirname "$0")/../.."
ROOT=$PWD
TAG=${MACOS_TAG:-27.2}
OUT=$ROOT/out/kc
PY=${K27_PYTHON:-python3}     # the workflow puts pyimg4 in a venv; everything else is stdlib
mkdir -p "$OUT"
export TMPDIR=${TMPDIR:-$ROOT/out/tmp}; mkdir -p "$TMPDIR"

profile=$(set -- "$ROOT"/configs/macos-"$TAG"-*.json; [ -f "$1" ] && printf '%s\n' "$1")
[ -n "$profile" ] || { echo "fetch-kernelcache: no configs/macos-$TAG-*.json" >&2; exit 1; }
URL=$(python3 - "$profile" <<'PY'
import json, sys
print(json.load(open(sys.argv[1]))['ipsw']['url'])
PY
)
echo "IPSW: $URL"

if [ ! -s "$OUT/kc27.bin" ]; then
  if [ ! -s "$OUT/kc27.im4p" ]; then
    python3 "$ROOT/scripts/ipsw-member.py" "$URL" list | tee "$OUT/members.txt" >/dev/null
    # The member name follows the restore device: 27.2 (Mac17,10) ships kernelcache.release.mac17j, 27.0.1
    # (VirtualMac2,1) ships kernelcache.release.vma2. Prefer vma2 when present, else take the one kernelcache member.
    MEMBER=$(awk '$3 ~ /^kernelcache\.release\./ {m[$3] = 1; if ($3 ~ /vma2$/) v = $3} END {
                      if (v != "") { print v } else { for (k in m) { print k; break } } }' "$OUT/members.txt")
    [ -n "$MEMBER" ] || { echo "fetch-kernelcache: kernelcache.release.vma2 not in the IPSW" >&2; exit 1; }
    echo "member: $MEMBER"
    python3 "$ROOT/scripts/ipsw-member.py" "$URL" get "$MEMBER" "$OUT/kc27.im4p"
  fi
  "$PY" -m pyimg4 im4p extract -i "$OUT/kc27.im4p" -o "$OUT/kc27.bin"
fi
python3 - "$OUT/kc27.bin" <<'PY'
import struct, sys
from pathlib import Path
path = Path(sys.argv[1]); data = path.read_bytes()
magic, = struct.unpack_from('<I', data, 0)
if magic != 0xfeedfacf:
    raise SystemExit(f'{path}: not a Mach-O ({magic:#x})')
print(f'{path}: {len(data)} bytes, MH_FILESET kernelcache')
PY
