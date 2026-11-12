#!/usr/bin/env bash
# Build Apple's open-source ld64, the linker that still knows -threaded_starts_section (Xcode 27's new linker does
# not, and Xcode 27 no longer ships ld-classic). Output: out/harness/ld64/ld.
#
#   ci/harness/build-ld64.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
ROOT=$PWD
SRC=$ROOT/out/harness/ld64-src
OUT=$ROOT/out/harness/ld64
mkdir -p "$OUT"
if [ -x "$OUT/ld" ]; then
  echo "build-ld64: $OUT/ld (cached)"
  exit 0
fi
[ -d "$SRC" ] || { echo "build-ld64: missing $SRC (run ci/harness/fetch.sh)" >&2; exit 1; }

find_binary() {
  find "$1" -type f -perm -111 \( -name ld64 -o -name ld \) -print -quit 2>/dev/null || true
}

PROJ=$(find "$SRC" -maxdepth 2 -name 'ld64.xcodeproj' -print -quit 2>/dev/null || true)
if [ -n "$PROJ" ]; then
  # The project's target name changed across tags; ask the project instead of assuming "ld64".
  LIST=$(xcodebuild -project "$PROJ" -list 2>/dev/null || true)
  TARGET=$(printf '%s\n' "$LIST" | awk '/Targets:/{t=1;next} t && /^[[:space:]]+ld$/{gsub(/^[ \t]+/,""); print; exit}')
  if [ -z "$TARGET" ]; then
    TARGET=$(printf '%s\n' "$LIST" | awk '/Targets:/{t=1;next} t && /^[[:space:]]+[A-Za-z0-9_.-]+$/{gsub(/^[ \t]+/,""); print; exit}')
  fi
  [ -n "$TARGET" ] || TARGET=ld
  echo "build-ld64: xcodebuild ($PROJ, target $TARGET)"
  printf '%s\n' "$LIST" | sed -n '1,40p'
  # The project asks for Apple's internal SDK and for DT_TOOLCHAIN_DIR-derived header paths; override both.
  xcodebuild -project "$PROJ" -target "$TARGET" -configuration Release \
    SDKROOT=macosx HEADER_SEARCH_PATHS= TAPI_HEADER_SEARCH_PATHS= \
    MACOSX_DEPLOYMENT_TARGET=12.0 \
    SYMROOT="$OUT/sym" OBJROOT="$OUT/obj" ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
    CODE_SIGNING_ALLOWED=NO >"$OUT/build.log" 2>&1 || {
      echo "build-ld64: xcodebuild failed; tail of build.log:" >&2; tail -50 "$OUT/build.log" >&2; exit 1; }
  BIN=$(find_binary "$OUT/sym")
else
  echo "build-ld64: make"
  make -C "$SRC" -j"$(sysctl -n hw.ncpu)" >"$OUT/build.log" 2>&1 || {
    echo "build-ld64: make failed; tail of build.log:" >&2; tail -50 "$OUT/build.log" >&2; exit 1; }
  BIN=$(find_binary "$SRC")
fi
[ -n "$BIN" ] || { echo "build-ld64: no ld64 binary produced" >&2; exit 1; }
cp "$BIN" "$OUT/ld"
chmod +x "$OUT/ld"
"$OUT/ld" -v 2>&1 | head -3 || true
echo "build-ld64: $OUT/ld"
