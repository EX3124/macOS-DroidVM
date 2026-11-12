#!/usr/bin/env bash
# Build the k27 kernel (xnu-12377 + patches/xnu-12377, arm64e, 4 KiB, macOS target, kc27 segment layout) on a macOS
# runner with Xcode's toolchain. Inputs come from ci/harness/fetch.sh; no developer tree, no bundle.
#
#   ci/harness/build-kernel.sh
#
# Output: out/k27/kernel-k27.macho, and the compile records the kext builders read from
# out/x12377/build/xnu/k27-obj.
#
# Why two make passes: the ArmDTPlatform/ArmCpu archives are compiled with the flags of a kernel compile record, so
# one pass has to exist first. The first pass links with empty stand-ins (it may fail at the link, which is fine); the
# second links with the real archives and the kc27 -segaddr list.
set -euo pipefail
cd "$(dirname "$0")/../.."
ROOT=$PWD
X=$ROOT/out/x12377
TREE=$ROOT/sources/xnu-12377
OUT=$ROOT/out/harness
OBJ=$X/build/xnu/k27-obj
FAKE=$X/fakeroot
KDK=$X/kdk
JOBS=${JOBS:-$(sysctl -n hw.ncpu)}
export TMPDIR=${TMPDIR:-$ROOT/out/tmp}
mkdir -p "$TMPDIR" "$OBJ" "$FAKE" "$X/k27" "$ROOT/out/k27"
SDK=$(xcrun --sdk iphoneos --show-sdk-path)

log() { printf '\n== %s\n' "$*"; }
fail() { echo "build-kernel: $*" >&2; exit 1; }
# macOS ar refuses to create an archive without members ("ar: no archive members specified"); the force-loaded
# stand-ins (headers-only KDK KernelSupport, first-pass platform archives) need one empty arm64e object.
make_stub_archive() {
  local archive=$1 object=$OUT/stub.o
  if [ ! -f "$object" ]; then
    printf 'int k27_stub_symbol;\n' > "$OUT/stub.c"
    xcrun clang -target arm64e-apple-ios26.0 -c "$OUT/stub.c" -o "$object"
  fi
  xcrun ar rcs "$archive" "$object"
}
[ -d "$TREE" ] || fail "missing sources/xnu-12377 (run ci/harness/fetch.sh)"
[ -f "$TREE/.k27-patched" ] || fail "sources/xnu-12377 is not the patched k27 tree"
[ -d "$OUT/unixnu/scripts" ] || fail "missing out/harness/unixnu (run ci/harness/fetch.sh)"
xcrun -f clang >/dev/null || fail "no Xcode toolchain"
log "Xcode: $(xcodebuild -version | head -1), SDK: $SDK"

# --------------------------------------------------------------------------------------------------- fakeroot headers
log "fakeroot (libplatform, libdispatch, AvailabilityVersions)"
mkdir -p "$FAKE/usr/local/include/kernel" "$OBJ/EXPORT_HDRS/libsa" "$FAKE/usr/local/lib/kernel"
ditto "$SDK/usr/include/TargetConditionals.h" "$FAKE/usr/local/include/kernel/TargetConditionals.h" 2>/dev/null || true
cp "$SDK/SDKSettings.plist" "$FAKE/SDKSettings.plist" 2>/dev/null || log "warning: no $SDK/SDKSettings.plist"
ditto "$OUT/libplatform/include" "$FAKE/usr/local/include"
ditto "$OUT/libplatform/private" "$FAKE/usr/local/include"
ditto "$OUT/libplatform/private/platform" \
  "$FAKE/System/Library/Frameworks/Kernel.framework/Versions/A/PrivateHeaders/platform"
python3 - "$OUT/libdispatch" "$FAKE" <<'PY'
import subprocess, sys
from pathlib import Path
source, fake = Path(sys.argv[1]), Path(sys.argv[2])
output = fake / 'usr/local/include/os'
output.mkdir(parents=True, exist_ok=True)
for header in (source / 'os').glob('*.h'):
    result = subprocess.run(['unifdef', '-DKERNEL=1', '-DOS_FIREHOSE_SPI=1',
                             '-DOS_VOUCHER_ACTIVITY_SPI_TYPES=1', '-UOS_VOUCHER_ACTIVITY_SPI', str(header)],
                            capture_output=True)
    if result.returncode not in (0, 1):
        raise SystemExit(result.stderr.decode())
    (output / header.name).write_bytes(result.stdout)
PY
if [ ! -x "$FAKE/usr/local/libexec/availability.pl" ]; then
  make -C "$OUT/availability" install -j"$JOBS" \
    OBJROOT="$OUT/availability/build" SYMROOT="$OUT/availability/build" DSTROOT="$FAKE" \
    CMAKE="$(command -v cmake)" NINJA="$(command -v ninja)" >/dev/null
fi
export XNU_AVAILABILITY_PL=$FAKE/usr/local/libexec/availability.pl

log "installhdrs"
make -C "$TREE" installhdrs SDKROOT=macosx ARCH_CONFIGS=ARM64 MACHINE_CONFIGS=BCM2837 KERNEL_CONFIGS=DEVELOPMENT \
  RC_DARWIN_KERNEL_VERSION="${XNU_DARWIN:-25.5.0}" RC_ProjectSourceVersion="${XNU_VERSION:-12377.121.6}" \
  MAKEJOBS=-j"$JOBS" OBJROOT="$OBJ" SYMROOT="$OUT/sym" DSTROOT="$FAKE" >/dev/null

log "firehose (libdispatch's libfirehose_kernel target)"
# The UniXNU recipe builds libfirehose_kernel with libdispatch's own Xcode project against the fakeroot. The project
# is copied so its xcconfig can be pointed at out/x12377/fakeroot; the EXTERNAL_HEADERS it wants are the kernel's.
WORK=$OUT/libdispatch-work
if [ ! -d "$WORK" ]; then cp -R "$OUT/libdispatch" "$WORK"; fi
ln -sfn "$TREE" "$OUT/xnu-work"
python3 - "$WORK" <<'PY'
import sys
from pathlib import Path
path = Path(sys.argv[1]) / 'xcodeconfig/libfirehose_kernel.xcconfig'
text = path.read_text()
text = text.replace('$(SDKROOT)/System/Library/Frameworks/Kernel.framework',
                    '$(FAKEROOT_DIR)/System/Library/Frameworks/Kernel.framework')
text = text.replace('$(SDKROOT)/usr/local/include', '$(FAKEROOT_DIR)/usr/local/include')
lines = text.splitlines()
extra = ' $(SDKROOT)/usr/include $(FAKEROOT_DIR)/usr/local/include $(PROJECT_DIR)/../xnu-work/EXTERNAL_HEADERS'
for index, line in enumerate(lines):
    if line.startswith('HEADER_SEARCH_PATHS =') and 'xnu-work/EXTERNAL_HEADERS' not in line:
        lines[index] = line + extra
path.write_text('\n'.join(lines) + '\n')
PY
xcrun xcodebuild install -project "$WORK/libdispatch.xcodeproj" -target libfirehose_kernel \
  -configuration Release -sdk iphoneos -jobs "$JOBS" \
  ARCHS=arm64e VALID_ARCHS=arm64e ONLY_ACTIVE_ARCH=NO IPHONEOS_DEPLOYMENT_TARGET=26.0 \
  CODE_SIGNING_ALLOWED=NO GCC_TREAT_WARNINGS_AS_ERRORS=NO \
  OBJROOT="$OUT/firehose/obj" SYMROOT="$OUT/firehose/sym" DSTROOT="$FAKE" FAKEROOT_DIR="$FAKE"
if [ -f "$FAKE/usr/local/lib/kernel/liblibfirehose_kernel.a" ]; then
  mv "$FAKE/usr/local/lib/kernel/liblibfirehose_kernel.a" "$FAKE/usr/local/lib/kernel/libfirehose_kernel.a"
fi
[ -s "$FAKE/usr/local/lib/kernel/libfirehose_kernel.a" ] || fail "libfirehose_kernel.a was not built"

# ------------------------------------------------------------------------------------------------------- KDK headers
# The patches delete xnu's stub CoreEntitlements/TrustCache headers: the real ones come from a KDK. The makefile
# force-loads $(KDKROOT)/System/Library/KernelSupport/libBCM2837.os.DEVELOPMENT.a whenever KDKROOT is set, so a
# headers-only KDK gets an empty archive; KDKROOT itself is mandatory (an empty one would name /System/...).
KDK_FLAGS=()
mkdir -p "$KDK/System/Library/KernelSupport"
[ -f "$KDK/System/Library/KernelSupport/libBCM2837.os.DEVELOPMENT.a" ] || \
  make_stub_archive "$KDK/System/Library/KernelSupport/libBCM2837.os.DEVELOPMENT.a"
if [ -d "$KDK/System/Library/Frameworks/Kernel.framework/Versions/A/PrivateHeaders" ]; then
  KDK_FLAGS=(-I"$KDK/System/Library/Frameworks/Kernel.framework/Versions/A/PrivateHeaders"
             -I"$KDK/System/Library/KernelSupport")
else
  log "warning: no KDK headers at $KDK (Xcode SDK may supply them; set KDK_URL to fetch a KDK)"
fi

# The kernel VA here is 39-bit (T1SZ_BOOT 25, the 4 KiB/BCM2837 geometry). arm64e macOS assumes 41 significant
# pointer bits, which would need 25 + 1 + 41 <= 64; narrow every definition to 38.
for f in $(grep -rl 'VM_KERNEL_POINTER_SIGNIFICANT_BITS' "$TREE" 2>/dev/null); do
  if grep -qE 'VM_KERNEL_POINTER_SIGNIFICANT_BITS[[:space:]]+41' "$f"; then
    perl -pi -e 's/(VM_KERNEL_POINTER_SIGNIFICANT_BITS\s+)41/${1}38/' "$f"
    log "narrowed pointer bits in $f"
  fi
done

# The kc27 segment list has no makefile hook in xnu; append one (idempotent).
if ! grep -q 'XNU_KC_SEGADDRS' "$TREE/makedefs/MakeInc.def"; then
  cat >> "$TREE/makedefs/MakeInc.def" <<'EOF'

# k27: segment addresses of the kernel inside the macOS 27 kernel collection (k27/segaddrs.sh).
ifneq ($(XNU_KC_SEGADDRS),)
LDFLAGS_KERNEL_GEN += $(XNU_KC_SEGADDRS)
endif
EOF
fi

# ----------------------------------------------------------------------------------------------- first pass (records)
log "first pass: compile records (link may fail)"
mkdir -p "$X/un/build/platform-12377-arm64e/ArmDTPlatform" "$X/un/build/platform-12377-arm64e/ArmCpu"
for component in ArmDTPlatform ArmCpu; do
  [ -f "$X/un/build/platform-12377-arm64e/$component/lib$component.a" ] || \
    make_stub_archive "$X/un/build/platform-12377-arm64e/$component/lib$component.a"
done
CFLAGS_EXTRA="-DXNU_NATIVE_CS_HASH_CACHE=1 -DXNU_NATIVE_RAM_BLOCK=1 -DXNU_OWNER_CACHE_MOUNT=1 \
-DXNU_OWNER_BOOT_MANIFEST=1 -DXNU_OWNER_CACHE_STARTUP=1 ${KDK_FLAGS[*]:-} \
-Wno-error=missing-designated-field-initializers -Wno-reserved-identifier -Wno-pre-c11-compat \
-Wno-missing-designated-field-initializers -Wno-suggest-override -Wno-unnecessary-virtual-specifier"
MAKE=(make -C "$TREE" build SDKROOT="$FAKE" ARCH_CONFIGS=ARM64 MACHINE_CONFIGS=BCM2837 KERNEL_CONFIGS=DEVELOPMENT
  ARCH_STRING_FOR_CURRENT_MACHINE_CONFIG=arm64e LARGE_MEMORY_DEFINE=-UARM_LARGE_MEMORY
  ARM64_LINK_ADDR=0xfffffff007004000 ARM64_PLKSEG_ADDR=0xfffffff004004000
  DEPLOYMENT_TARGET_FLAGS="-miphoneos-version-min=26.0 -DXNU_TARGET_OS_OSX"
  DEPLOYMENT_LINKER_FLAGS="-Wl,-ios_version_min,26.0"
  RC_DARWIN_KERNEL_VERSION="${XNU_DARWIN:-25.5.0}" RC_ProjectSourceVersion="${XNU_VERSION:-12377.121.6}"
  BUILD_LTO=0 BOUND_CHECKS=0 BUILD_WERROR=0 MAKEJOBS=-j"$JOBS" KDKROOT="$KDK"
  CFLAGS_EXTRA="$CFLAGS_EXTRA" OBJROOT="$OBJ" SYMROOT="$OUT/sym" DSTROOT="$OUT/dst")
DT=$X/un/build/platform-12377-arm64e/ArmDTPlatform/libArmDTPlatform.a
CPU=$X/un/build/platform-12377-arm64e/ArmCpu/libArmCpu.a
# Xcode 27's ld dropped -threaded_starts_section; the kernel's arm_slide still needs __TEXT,__thread_starts, so link
# with the bundled ld-classic when the toolchain has it.
LD_CLASSIC=$(xcrun -f ld-classic 2>/dev/null || true)
LDX="-Wl,-no_fixup_chains -Wl,-threaded_starts_section"
if [ -n "$LD_CLASSIC" ]; then
  MAKE+=("LD=$LD_CLASSIC")
  log "using ld-classic for the threaded-starts link: $LD_CLASSIC"
else
  LDX="-Wl,-no_fixup_chains"
  log "warning: no ld-classic; linking without -threaded_starts_section"
fi
LD_BASE="$LDX \
-L$SDK/usr/local/lib/kernel -L$SDK/usr/local/lib/kernel/platform \
-L$FAKE/usr/local/lib/kernel -L$FAKE/usr/local/lib/kernel/platform -lfirehose_kernel"
"${MAKE[@]}" LD_KERNEL_ARCHIVES="$LD_BASE -Wl,-force_load,$DT -Wl,-force_load,$CPU" || true
RECORD=$OBJ/DEVELOPMENT_ARM64_BCM2837/iokit/DEVELOPMENT/IOPlatformExpert.cpo.json
[ -f "$RECORD" ] || fail "no compile records after the first pass"
# build-native-ram-block.py reads its flags from e-obj by default; point it at the same records.
ln -sfn "$OBJ" "$X/build/xnu/e-obj"

# ------------------------------------------------------------------------------------------------------ platform libs
log "ArmDTPlatform and ArmCpu (arm64e, from the kernel's compile record)"
# The public helper resolves its own ROOT from __file__, so it has to stay inside the UniXNU tree; copy it there
# (not to out/harness) and relax the plain-arm64 subtype assertion for arm64e.
PLATFORM=$OUT/unixnu/scripts/build-platform-12377.py
python3 - "$PLATFORM" <<'PY'
import sys
from pathlib import Path
path = Path(sys.argv[1]); text = path.read_text()
old = "if struct.unpack_from('<4I', data) != (0xfeedfacf, 0x100000c, 0, 1):"
new = ("if struct.unpack_from('<I', data, 0)[0] != 0xfeedfacf or "
       "struct.unpack_from('<I', data, 4)[0] != 0x100000c:   # arm64 or arm64e")
if old in text:
    text = text.replace(old, new)
elif new not in text:
    raise SystemExit(f'{path}: unexpected subtype assertion')
# The compile record may say plain arm64; the kernel is arm64e, so force the object arch.
if "'-arch', 'arm64e'" not in text:
    marker = "command += ['-Wall'"
    if marker not in text:
        raise SystemExit(f'{path}: unexpected command assembly')
    text = text.replace(marker, "command += ['-arch', 'arm64e', '-Wall'", 1)
path.write_text(text)
PY
mkdir -p "$OUT/unixnu/build/xnu-12377.121.6"
ln -sfn "$OBJ" "$OUT/unixnu/build/xnu-12377.121.6/ios-obj"
for component in ArmDTPlatform ArmCpu; do
  python3 "$PLATFORM" "$component"
  cp "$OUT/unixnu/build/platform-12377/$component/lib$component.a" \
     "$X/un/build/platform-12377-arm64e/$component/lib$component.a"
done

# ------------------------------------------------------------------------------------------------ final link (kc27)
log "second pass: kernel with the kc27 segment layout"
# The checked-in k27/segaddrs.sh was generated from the original kernel's segment sizes; ours differ (TEXT_EXEC
# overlaps __KLD at those addresses). Recompute the layout from the first-pass kernel with kc27-layout.py.
BOOT_KERNEL=$(find "$OBJ/DEVELOPMENT_ARM64_BCM2837" -maxdepth 1 -name '*development*.unstripped.noctf' -print -quit 2>/dev/null || true)
if [ -n "$BOOT_KERNEL" ] && [ -s "$ROOT/out/kc/kc27.bin" ]; then
  python3 "$ROOT/k27/kc27-layout.py" "$ROOT/out/kc/kc27.bin" "$BOOT_KERNEL" --write "$ROOT/k27/segaddrs.sh" \
    || log "warning: kc27-layout.py failed; keeping the checked-in segaddrs.sh"
fi
SEGADDRS=$(bash "$ROOT/k27/segaddrs.sh")
rm -f "$OBJ/DEVELOPMENT_ARM64_BCM2837/mach.development.bcm2837.unstripped.noctf"
"${MAKE[@]}" \
  XNU_KC_SEGADDRS="$SEGADDRS" \
  LD_KERNEL_ARCHIVES="$LD_BASE -Wl,-force_load,$DT -Wl,-force_load,$CPU" \
  XNU_EXTERNAL_KERNEL_ARCHIVES="$DT $CPU"

KERNEL=$(find "$OBJ/DEVELOPMENT_ARM64_BCM2837" -maxdepth 1 \
  \( -name 'kernel.development*.unstripped.noctf' -o -name 'mach.development*.unstripped.noctf' \) -print -quit)
[ -n "$KERNEL" ] && [ -s "$KERNEL" ] || fail "no kernel mach-o in $OBJ/DEVELOPMENT_ARM64_BCM2837"
cp "$KERNEL" "$ROOT/out/k27/kernel-k27.macho"
ls -la "$ROOT/out/k27/kernel-k27.macho"
echo "build-kernel: done"
