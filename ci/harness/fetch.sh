#!/usr/bin/env bash
# Materialize the public inputs of the macOS 27 kernel build in this checkout: no developer machine, no bundle.
#
#   ci/harness/fetch.sh
#
# Puts everything where the existing k27 scripts already look for it:
#   sources/xnu-12377            apple-oss-distributions/xnu @ xnu-12377.121.6 + patches/xnu-12377 (git am)
#   out/x12377/xnu-m             symlink to the patched tree (the kext builders include osfmk from here)
#   out/x12377/kdk               KDK headers (only when KDK_URL/KDK_SHA256 are given)
#   out/x12377/storage-abi/include  IOStorageFamily headers + an empty TargetConditionals.h
#   out/harness/{libplatform,libdispatch,availability}  pinned apple-oss sources
#   out/harness/unixnu           none24smu/UniXNU @ ios26: ArmDTPlatform/ArmCpu sources, patches, kdk-headers.py
#
# Environment: XNU_BASE (default ac9718f, the xnu-12377.121.6 tag), UNIXNU_REF (default 68c5134), KDK_URL, KDK_SHA256.
set -euo pipefail
cd "$(dirname "$0")/../.."
ROOT=$PWD
OUT=${K27_HARNESS_OUT:-$PWD/out/harness}
X=$ROOT/out/x12377
XNU_BASE=${XNU_BASE:-ac9718fb1af618d5ce8678d0dc6e8a58f252216f}
UNIXNU_REF=${UNIXNU_REF:-68c513467bb6c44106c053c410582c1d14f96dd7}
mkdir -p "$OUT" "$X/build/xnu" "$X/storage-abi/include" "$ROOT/out/tmp"
export TMPDIR=${TMPDIR:-$ROOT/out/tmp}

clone() {  # clone URL REF DIR [--submodules]
  local url=$1 ref=$2 dir=$3 sub=${4:-}
  if [ ! -d "$dir/.git" ]; then
    git clone --filter=blob:none --no-checkout "$url" "$dir"
  fi
  if ! git -C "$dir" cat-file -e "$ref^{commit}" 2>/dev/null; then
    git -C "$dir" fetch --depth 1 origin "$ref"
  fi
  git -C "$dir" checkout -q --detach "$ref"
  if [ "$sub" = --submodules ]; then
    git -C "$dir" submodule update --init --recursive --depth 1 drivers/ArmCpu drivers/ArmDTPlatform
  fi
}

echo "== xnu-12377 ($XNU_BASE) + patches/xnu-12377"
if [ ! -d "$ROOT/sources/xnu-12377/.git" ]; then
  git clone --filter=blob:none --no-checkout https://github.com/apple-oss-distributions/xnu.git "$ROOT/sources/xnu-12377"
fi
TREE=$ROOT/sources/xnu-12377
if ! git -C "$TREE" cat-file -e "$XNU_BASE^{commit}" 2>/dev/null; then
  git -C "$TREE" fetch --depth 1 origin "$XNU_BASE" || \
    git -C "$TREE" fetch --depth 1 origin tag xnu-12377.121.6
fi
if [ ! -f "$TREE/.k27-patched" ]; then
  git -C "$TREE" checkout -q --detach "$XNU_BASE"
  git -C "$TREE" reset -q --hard "$XNU_BASE"
  git -C "$TREE" clean -qffdx
  for patch in "$ROOT"/patches/xnu-12377/*.patch; do
    git -C "$TREE" -c user.name=ci -c user.email=ci@localhost am --no-gpg-sign --quiet "$patch"
  done
  printf '%s\n' "$(git -C "$TREE" rev-parse HEAD)" > "$TREE/.k27-patched"
fi
[ "$(cat "$TREE/.k27-patched")" = "$(git -C "$TREE" rev-parse HEAD)" ] || {
  echo "sources/xnu-12377 is not at the recorded k27 commit" >&2; exit 1; }

echo "== pinned apple-oss sources"
clone https://github.com/apple-oss-distributions/libplatform.git libplatform-316.100.10 "$OUT/libplatform"
clone https://github.com/apple-oss-distributions/libdispatch.git libdispatch-1477.100.9 "$OUT/libdispatch"
clone https://github.com/apple-oss-distributions/AvailabilityVersions.git AvailabilityVersions-141.1 "$OUT/availability"
clone https://github.com/apple-oss-distributions/IOStorageFamily.git IOStorageFamily-337.100.1 "$OUT/IOStorageFamily" || \
  clone https://github.com/apple-oss-distributions/IOStorageFamily.git main "$OUT/IOStorageFamily"

echo "== UniXNU harness sources (none24smu/UniXNU @ ios26)"
clone https://github.com/none24smu/UniXNU.git "$UNIXNU_REF" "$OUT/unixnu" --submodules

echo "== edk2-gunyah (GunyahPkg + DarwinBoot) and the derived GunyahBootPkg"
clone https://github.com/Droid-VM/edk2-gunyah.git droidvm "$OUT/edk2-gunyah"
git -C "$OUT/edk2-gunyah" submodule update --init --recursive --depth 1 edk2
ln -sfn "$OUT/edk2-gunyah/edk2" "$ROOT/sources/edk2"
ln -sfn "$OUT/edk2-gunyah/GunyahPkg" "$ROOT/sources/GunyahPkg"
python3 "$ROOT/ci/darwinboot/make-gunyah-boot.py" "$OUT/edk2-gunyah" "$ROOT/sources/GunyahBootPkg"

echo "== paths the k27 kext builders expect"
ln -sfn "$TREE" "$X/xnu-m"
# The public IOStorageFamily checkout keeps its headers flat (IOBlockStorageDevice.h at the root); the kext includes
# them as <IOKit/storage/...>, so lay them out that way.
mkdir -p "$X/storage-abi/include/IOKit/storage"
cp "$OUT/IOStorageFamily"/*.h "$X/storage-abi/include/IOKit/storage/"
: > "$X/storage-abi/include/TargetConditionals.h"

if [ -n "${KDK_URL:-}" ]; then
  echo "== KDK headers"
  python3 "$OUT/unixnu/scripts/kdk-headers.py" --url "$KDK_URL" --sha256 "${KDK_SHA256:?KDK_SHA256 is required with KDK_URL}" \
    --cache "$ROOT/out/tmp/kdk" "$X/kdk"
else
  # KDK 25F84 (macOS 26.5.2 / xnu-12377.122.8): the public KdkSupportPkg asset. Xcode 27's SDK does not ship the
  # CoreEntitlements/TrustCache/CodeSignature kernel headers that patches/xnu-12377 removed the stubs for.
  echo "== KDK headers (Kernel_Debug_Kit_26.5.2_build_25F84.dmg)"
  python3 "$OUT/unixnu/scripts/kdk-headers.py" \
    --url https://github.com/dortania/KdkSupportPkg/releases/download/25F84/Kernel_Debug_Kit_26.5.2_build_25F84.dmg \
    --sha256 faef4393becf65c88a2791770904909babf1826d23d2ea478bf878a6417851ab \
    --cache "$ROOT/out/tmp/kdk" "$X/kdk"
fi

git -C "$TREE" log --oneline -1
echo "fetch: done (patched tree at $TREE)"
