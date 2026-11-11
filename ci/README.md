# CI for the macOS 27 kernel payload

`.github/workflows/macos27-payload.yml` builds, on the GitHub-hosted **`xcode-27`** preview image (macOS 27.0.1,
Xcode 27.0/27.1/27.2), the k27 kernel payload from public sources only. There is no uploaded toolchain bundle and no
developer tree:

```
ci/harness/fetch.sh            xnu-12377.121.6 + patches/xnu-12377 (git am), KDK headers, libplatform/libdispatch,
                              AvailabilityVersions, IOStorageFamily, none24smu/UniXNU@ios26 (ArmDTPlatform/ArmCpu)
ci/harness/fetch-kernelcache.sh  the 27 kernelcache, read out of the pinned IPSW with HTTP ranges, IM4P-decoded
ci/harness/build-kernel.sh     arm64e 4 KiB kernel with the kc27 segment layout (two make passes)
ci/k27-build.sh                kernel -> native kexts -> kernel collection (kc-k27.bin)
```

Everything is written into the paths the existing k27 scripts use (`out/x12377`, `out/k27`, `out/kc`), so
`k27/build-native-*.sh` and `scripts/kc-build.py` (through `k27/kc-build27.py`) run unchanged.

## Inputs

| Input | Source |
| --- | --- |
| XNU source | `apple-oss-distributions/xnu` tag `xnu-12377.121.6` (commit `ac9718f`) |
| XNU patches | `patches/xnu-12377` (47, replayed with `git am`; final tree `c97cc10…`) |
| Xcode / SDK / clang / iig / ld | runner image (Xcode 27) |
| KDK headers | `KDK_URL`/`KDK_SHA256` (a KdkSupportPkg disk image) + `none24smu/UniXNU@ios26` `kdk-headers.py`; optional if the Xcode SDK has the headers |
| Host sources | `scripts/prepare-sources.py` (UniXNU, UniXNU-droidvm, lzfse, apfsprogs, … from `configs/sources.lock.json`) |
| ArmDTPlatform / ArmCpu | `none24smu/UniXNU@ios26` drivers + its `build-platform-12377.py` (subtype check relaxed to arm64e) |
| 27 kernelcache | `configs/macos-27.2-26B8125.json` IPSW URL, member `kernelcache.release.vma2`, `pyimg4` |
| Boot fixtures | `ci/fixtures/UniXNU.efi`, `ci/fixtures/generated.dtb` (recovered from this repository's history) |

## Build notes (why the harness looks like this)

- **arm64e**: xnu-12377's `MakeInc.def` sets `ARCH_STRING_FOR_CURRENT_MACHINE_CONFIG=arm64e` for `ARCH_CONFIGS=ARM64`
  by default; the old baseline forced `arm64`. The harness passes `arm64e` explicitly, and
  `LDFLAGS_KERNEL_ONLY_SUBARCH_arm64e` adds `-Wl,-kernel`.
- **kc27 segments**: there is no makefile hook for extra kernel link flags, so the harness appends
  `LDFLAGS_KERNEL_GEN += $(XNU_KC_SEGADDRS)` to `makedefs/MakeInc.def` and passes the list from `k27/segaddrs.sh`.
- **Two passes**: `ArmDTPlatform`/`ArmCpu` are compiled with the flags of a kernel compile record, so the first make
  pass produces records (its link may fail against empty stand-in archives); the second links with the real archives
  and the kc27 `-segaddr` list.
- **KDK**: `KDKROOT` makes the makefile `force_load` `libBCM2837.os.DEVELOPMENT.a`; a headers-only KDK gets an empty
  archive so the link does not fail.
- **`LD_KERNEL_ARCHIVES`** is a plain make variable whose default holds the SDK `-L` paths; the harness overrides it
  with the full list (SDK/KDK/fakeroot `-L`, `-lfirehose_kernel`, the two platform archives).

## Not in this stage yet

`boot.img` assembly (`ci/boot27.py`) needs two generated inputs that are not in this workflow yet:

- a **Data seed** (`scratch-data.img`) built from the IPSW with `make-macos-disk.py` (large: OS + SystemOS cryptex);
- a **trust cache** from the IPSW's `StaticTrustCache` / `Cryptex1,SystemTrustCache`.

`DarwinBoot.efi` is built from source: `ci/darwinboot/make-gunyah-boot.py` derives `GunyahBootPkg/GunyahBoot.dsc`
from the public `edk2-gunyah` `GunyahPkg/GunyahKernel.dsc` (component list replaced by `DarwinBootPkg/Driver/DarwinBoot.inf`),
and `scripts/build-darwinboot.py` builds it with the UniXNU DarwinBoot driver. `ci/boot27.py` and the fixture
FDT/`UniXNU.efi` are ready for the boot-disk stage.
