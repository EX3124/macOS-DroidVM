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
  find "$1" -type f \( -name ld -o -name ld64 \) -print -quit 2>/dev/null || true
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
  # Xcode 27 has neither the tapi tool nor libtapi headers. The kernel link has no .tbd inputs, so compile the
  # text-stub support out of ld64 and satisfy the remaining declarations with ci/harness/tapi-stub/tapi/tapi.h.
  python3 - "$SRC" <<'PY'
import pathlib, re, sys
src = pathlib.Path(sys.argv[1])
(src / "src/ld/parsers/textstub_dylib_file.cpp").write_text(
    "// TAPI disabled: the kernel link has no .tbd inputs.\n")
inp = src / "src/ld/InputFiles.cpp"
text = inp.read_text()
patched, n = re.subn(r'\n\tif \(info\.isInlined\) \{.*?\n\t\}\n', '\n', text, count=1, flags=re.S)
if n == 0:
    print("build-ld64: warning: inlined-dylib block not found", file=sys.stderr)
inp.write_text(patched)
mrf = src / "src/ld/parsers/macho_relocatable_file.cpp"
mt = mrf.read_text()
mt = mt.replace(
    "char symName[nameLen+2];",
    "std::vector<char> symNameStorage(nameLen+2); char* symName = symNameStorage.data();")
mt = mt.replace(
    "pint_t cfiStartsArray[cfiStartsCount+cuLsdaCount];",
    "std::vector<pint_t> cfiStartsArrayStorage(cfiStartsCount+cuLsdaCount+1); "
    "pint_t* cfiStartsArray = cfiStartsArrayStorage.data();")
mt = mt.replace(
    "uint8_t machOSectsStorage[sizeof(MachOSectionAndSectionClass<P>)*(_machOSectionsCount+2)];",
    "std::vector<uint8_t> machOSectsStorageStorage("
    "sizeof(MachOSectionAndSectionClass<P>)*(_machOSectionsCount+2)+1); "
    "uint8_t* machOSectsStorage = machOSectsStorageStorage.data();")
mt = re.sub(
    r'#define STACK_ALLOC_IF_SMALL.*?\n\n',
    "#define STACK_ALLOC_IF_SMALL(_type, _name, _actual_count, _maxCount) \\\n"
    "\tuint32_t _name##_count = _actual_count ? _actual_count : 1; \\\n"
    "\tstd::vector<_type> _name##_storage(_name##_count); \\\n"
    "\t_type* _name = _name##_storage.data();\n\n",
    mt, count=1, flags=re.S)
mt = mt.replace(
    "uint32_t sortedSectionIndexes[_machOSectionsCount];",
    "std::vector<uint32_t> sortedSectionIndexesStorage(_machOSectionsCount ? _machOSectionsCount : 1); "
    "uint32_t* sortedSectionIndexes = sortedSectionIndexesStorage.data();")
mt = mt.replace(
    "uint32_t sortedSymbolIndexes[_symbolsInSections];",
    "std::vector<uint32_t> sortedSymbolIndexesStorage(_symbolsInSections ? _symbolsInSections : 1); "
    "uint32_t* sortedSymbolIndexes = sortedSymbolIndexesStorage.data();")
mrf.write_text(mt)
blob = src / "src/ld/code-sign-blobs/blob.h"
bt = blob.read_text()
if "BlobCore *clone() const" not in bt:
    bt = bt.replace(
        "void length(size_t size)\t\t\t{ mLength = size; }",
        "void length(size_t size)\t\t\t{ mLength = size; }\n"
        "\tBlobCore *clone() const\n"
        "\t{\n"
        "\t\tBlobCore *result = (BlobCore *)::malloc(length());\n"
        "\t\tif (result != NULL) ::memcpy(result, this, length());\n"
        "\t\treturn result;\n"
        "\t}")
    bt = bt.replace("#include <stdint.h>", "#include <stdint.h>\n#include <stdlib.h>\n#include <string.h>", 1)
    blob.write_text(bt)
PY
  echo "build-ld64: xcodebuild ($PROJ, target $TARGET, TAPI stubbed)"
  xcodebuild -project "$PROJ" -target "$TARGET" -configuration Release \
    SDKROOT=macosx HEADER_SEARCH_PATHS="$ROOT/ci/harness/tapi-stub $ROOT/ci/harness/sdk-stub" TAPI_HEADER_SEARCH_PATHS= \
    MACOSX_DEPLOYMENT_TARGET=12.0 \
    SYMROOT="$OUT/sym" OBJROOT="$OUT/obj" ARCHS=x86_64 VALID_ARCHS=x86_64 ONLY_ACTIVE_ARCH=NO \
    CODE_SIGNING_ALLOWED=NO >"$OUT/build.log" 2>&1 || {
      echo "build-ld64: xcodebuild failed; tail of build.log:" >&2; tail -50 "$OUT/build.log" >&2; exit 1; }
  BIN=$(find_binary "$OUT/sym")
  if [ -z "$BIN" ]; then BIN=$(find_binary "$OUT"); fi
  if [ -z "$BIN" ]; then BIN=$(find_binary "$SRC"); fi
  if [ -z "$BIN" ]; then
    echo "build-ld64: xcodebuild produced no ld binary; search dirs:" >&2
    find "$OUT" "$SRC" -maxdepth 4 -type f -perm -111 2>/dev/null | head -30 >&2 || true
    tail -30 "$OUT/build.log" >&2 || true
    exit 1
  fi
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
