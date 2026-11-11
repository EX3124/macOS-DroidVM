#!/usr/bin/env bash
# Build the macOS 27 boot payload in a CI checkout: the k27 kernel, the native kexts and the kernel collection (KC).
#
# The k27 chain is the one of docs/xnu-12377-port.md and k27/TODO.md. It runs on Linux with this project's own
# toolchain, sources and object tree (toolchains/, out/x12377/, sources/xnu-12377, the 27 kernelcache at
# out/kc/kc27.bin), which git does not carry; ci/make-k27-bundle.sh packs them once and the workflow downloads that
# bundle before this script runs. Everything else is the developer command sequence, with each output checked.
#
#   ci/k27-build.sh [kernel|kexts|kc|all]        (default: all)
#
# Environment:
#   K27_TAG      artifacts/TAG of the profile (default 27.2)
#   K27_KEXTS    space separated extra kexts to link: display video audio gpu input ethernet
#                (default: none; the KC always gets NativeVirtioBlock, NativeRamBlock and NativeAES, which are what
#                mount the store and decrypt Image4's nonces)
#   K27_JOBS     make parallelism (default: nproc)
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
TAG=${K27_TAG:-27.2}
export MACOS_TAG=$TAG
mkdir -p out/tmp out/k27 out/rig
export TMPDIR=$ROOT/out/tmp
JOBS=${K27_JOBS:-$(nproc)}

stage=${1:-all}
case "$stage" in
  kernel|kexts|kc|all) ;;
  *) echo "k27-build: stage must be kernel, kexts, kc or all" >&2; exit 2 ;;
esac

need() {
  [ -e "$1" ] || {
    echo "k27-build: missing $1" >&2
    echo "k27-build: run ci/harness/fetch.sh first (it materializes every public input)" >&2
    exit 1
  }
}
need sources/xnu-12377/.k27-patched
need out/harness/unixnu/scripts
need out/x12377/storage-abi/include
need sources/UniXNU/drivers/NativeAES
need sources/UniXNU/drivers/NativeRamBlock
need sources/UniXNU/drivers/NativeVirtioBlock

if [ "$stage" = kernel ] || [ "$stage" = all ]; then
  echo "== k27 kernel (xnu-12377 + patches/xnu-12377, Xcode 27 toolchain)"
  bash ci/harness/build-kernel.sh
  test -s out/k27/kernel-k27.macho
fi

if [ "$stage" = kexts ] || [ "$stage" = all ]; then
  echo "== native kexts"
  # NativeAES: selector 2212 for 27's AppleImage4 nonce entanglement (k27/build-native-aes.sh edits a copy).
  bash k27/build-native-aes.sh
  # NativeRamBlock: the Data disk and its DroidVMDataStore store (the script edits a copy of the upstream driver).
  python3 scripts/build-native-ram-block.py
  # NativeVirtioBlock: overlay/kext/NativeVirtioBlock.patch applies to the upstream source, so build a scratch copy.
  work=$(mktemp -d)
  trap 'rm -rf "$work"' EXIT
  cp sources/UniXNU/drivers/NativeVirtioBlock/NativeVirtioBlock.cpp "$work/"
  patch -p1 -s --batch -d "$work" -i "$ROOT/overlay/kext/NativeVirtioBlock.patch"
  python3 scripts/build-native-kext.py NativeVirtioBlock "$work/NativeVirtioBlock.cpp" overlay/kext/NativeKextGlue.cpp \
    -I sources/UniXNU/drivers/NativeVirtioBlock -I "$ROOT/out/x12377/storage-abi/include" \
    -D U:TARGET_OS_OSX -D TARGET_OS_OSX=1

  # DroidVMGpu exports NativeAdreno into out/x12377/src-gpu and builds the GPU kext; DroidVMDisplay takes its
  # DroidVMVirtgpuABI.h from that export, so build it once before the per-kext loop.
  case " ${K27_KEXTS:-} " in
    *" gpu "*|*" display "*) python3 scripts/build-droidvm-gpu.py ;;
  esac

  for kext in ${K27_KEXTS:-}; do
    case "$kext" in
      display)  bash k27/build-native-display.sh ;;   # needs out/x12377/src-gpu: scripts/build-droidvm-gpu.py first
      video)    bash k27/build-native-video.sh ;;
      audio)    bash k27/build-native-audio.sh ;;
      gpu)      ;;                                    # built once, before the loop
      input)    python3 scripts/build-native-kext.py DroidVMInput overlay/kext/DroidVMInput/DroidVMInput.cpp \
                  overlay/kext/NativeKextGlue.cpp -I overlay/kext/DroidVMInput ;;
      ethernet) python3 scripts/build-native-kext.py DroidVMEthernet overlay/kext/DroidVMEthernet.cpp \
                  overlay/kext/NativeKextGlue.cpp -I "$ROOT/out/x12377/inc-net" \
                  -I "$ROOT/overlay/droidvm/drivers/NativeVirtioBlock" ;;
      *) echo "k27-build: unknown kext $kext" >&2; exit 2 ;;
    esac
  done
fi

if [ "$stage" = kc ] || [ "$stage" = all ]; then
  echo "== kernel collection (27 kernelcache kexts + our kernel + native kexts)"
  need out/kc/kc27.bin
  # k27/try.sh builds the KC and boots it once; K27_NO_BOOT stops after the link, which is what CI wants.
  # The extra kexts of K27_KEXTS go through the same switches try.sh uses for a developer build.
  case " ${K27_KEXTS:-} " in
    *" display "*) export MACOS_DISPLAY=1 ;;
  esac
  case " ${K27_KEXTS:-} " in
    *" gpu "*) export MACOS_GPU=1 ;;
  esac
  case " ${K27_KEXTS:-} " in
    *" video "*) export MACOS_VIDEO=1 ;;
  esac
  case " ${K27_KEXTS:-} " in
    *" audio "*) export MACOS_AUDIO=1 ;;
  esac
  K27_NO_BOOT=1 bash k27/try.sh 1 --
  test -s out/k27/kc-k27.bin
  ls -la out/k27/kc-k27.bin out/k27/kc-k27.natives.json 2>/dev/null || true
fi

echo "k27-build: $stage done (TAG=$TAG, JOBS=$JOBS)"
