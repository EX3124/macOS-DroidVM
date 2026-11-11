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
mkdir -p "$OUT"
export TMPDIR=${TMPDIR:-$ROOT/out/tmp}; mkdir -p "$TMPDIR"

profile=$(ls "$ROOT"/configs/macos-"$TAG"-*.json 2>/dev/null | head -1)
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
    MEMBER=$(grep -E 'kernelcache\.release\.vma2$' "$OUT/members.txt" | awk '{print $3}' | head -1)
    [ -n "$MEMBER" ] || { echo "fetch-kernelcache: kernelcache.release.vma2 not in the IPSW" >&2; exit 1; }
    echo "member: $MEMBER"
    python3 "$ROOT/scripts/ipsw-member.py" "$URL" get "$MEMBER" "$OUT/kc27.im4p"
  fi
  python3 -m pyimg4 im4p extract -i "$OUT/kc27.im4p" -o "$OUT/kc27.bin"
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
