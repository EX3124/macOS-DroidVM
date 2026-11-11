# 不签名的构建（已关闭 VerifiedRoot/owner 验证链）

2026-11-11。本项目不再生成、发布或嵌入 owner root policy，也不再需要 RSA-3072 owner 密钥对。
主线的构建在 workflow 里改写外部仓库，而不是去改 `Droid-VM/UniXNU` 与 `Droid-VM/UniXNU-droidvm`。

## 改了什么

`scripts/disable-owner-verification.py DEVICE [--unixnu UNIXNU] [--tree TREE]` 对 device 树和 UniXNU 做三件事：

| 位置 | 改动 |
| --- | --- |
| `board.toml` | 删掉 `build-verified-root-probe.py --component os --include-systemos` 归档；把 `build-arm-driver.py NativeVirtioBlock --verified-root --verified-root-bundle` 改成不带 flag 的版本；bindings 的 `--directory` 从 `build/native-virtio-block-verified-bundle` 改为 `build/native-virtio-block`（不带 flag 时 `build-arm-driver.py` 就写这个目录） |
| `configs/<defconfig>` | `CONFIG_XNU_VERIFIED_ROOT_PROBE=n`、`CONFIG_XNU_OWNER_BOOT_MANIFEST=n`，删掉 `CONFIG_XNU_VERIFIED_ROOT_ARCHIVE`，`CONFIG_XNU_NATIVE_VIRTIO_BLOCK_ARCHIVE` 改指 `build/native-virtio-block/libVirtioMmioBlock.a` |
| `patches/xnu/offline-owner-systemos-mount.patch` | 去掉 “scratch Data mount 需要 boot manifest” 的 `#error` |
| `scripts/build-xnu-4k-baseline.sh` | 去掉两条构建期一致性检查：`OWNER_ROOT_AUDIT` 必须配 `VERIFIED_ROOT_PROBE`，以及 `OWNER_DATA_MOUNT` 必须配 `OWNER_BOOT_MANIFEST`（否则脚本直接 `exit 1`） |

`mainline.yml` 在 Sources 之后、Fetch 之前对 `device` 和 `device-ref` 各跑一次；`scripts/build-linux.py full`
对 `out/linux/device-full` 和已应用的 `out/linux/UniXNU` 工作树跑同样的脚本。

`NativeVirtioBlock` 不再用 `kits/VerifiedRoot`（没有 `--verified-root` 就没有 `NATIVE_VERIFIED_BLOCK`）：

- `configureVerification()` / `vr_open()` 不参与编译，读盘走原来的 `readSectors()`，不查哈希表；
- 但 owner 的 SystemOS/cache 挂载补丁仍调用 `native_verified_block_volume_device()` 与
  `native_verified_block_root_authorized()`，所以 overlay 驱动在无验证模式里导出这两个符号：前者按卷 UUID 找
  IOMedia，后者恒返回 1（“已授权”）。
- `native_verified_block_manifest_sha384()` 也保留为返回 0 的桩；`XNU_OWNER_BOOT_MANIFEST=n` 时没有调用者。

## 保留了什么

owner 的**挂载**功能没有关，否则 macOS 根起不来：

- `CONFIG_XNU_OWNER_ROOT_AUDIT=y`、`CONFIG_XNU_OWNER_ROOT_TRUST=y`：`bsd_init` 的 `FSIOC_KERNEL_ROOTAUTH` 失败时，
  仍然靠 `native_verified_block_root_authorized()` 放行（现在是恒真），不走 `panic("rootvp not authenticated")`；
- `CONFIG_XNU_OWNER_CACHE_MOUNT` / `CACHE_STARTUP` / `CACHE_CARRIER` / `UNION_SYSTEMOS` / `DATA_MOUNT`：SystemOS
  挂载、dyld 共享缓存载体、Data 挂到 `/private/var` 的逻辑不变；
- `root_match_volume_uuid` 等启动参数不变。

## 失去了什么

- 根盘和 SystemOS 的块级校验：`NativeVirtioBlock` 不再拒绝被改过的 4096 字节块，任何同容量的镜像都会被接受。
- owner 身份：没有 owner 公钥，内核不再区分“本项目签发的根盘”。
- boot manifest：`/chosen` 不再发布 `owner-boot-manifest-domain` / `boot-manifest-hash`。
- 发布资产 `root-policies` / `root-policies-macos` 与 `owner-keys.tar.gz` 不再需要；已有 release 可以删除。

## 仍然可以单独生成哈希清单

`scripts/make-virt-root.py OS.raw SYSTEMOS.dmg OUTDIR` 现在只做逐块 SHA-256：

- `{os,systemos}.manifest.bin` = 160 字节 `VROOT01` 头 + 32 字节 × 块数，**没有 384 字节签名**；
- header 的 anchor 字段（120..152）为 0，`trusted-key.bin` 不再生成；
- `verified-root-inputs.tar.gz` 只含 `os.manifest.bin`、`systemos.manifest.bin`、`os.samples.bin`、`inputs.json`。

`scripts/owner-policy-dirs.py INPUTS TREE [ios|macos]` 仍可把这套文件摆成 `build/verified-root-{os,systemos}/`，
但主线不再调用它；`verification.json` 里明确写 `signed: false`。`local-root-policy.py`、
`macos-root-pins.py`、`macos-policy-inputs.py`、`macos-root-probe.py` 是签名时代的工具，保留但已不参与构建。

## 参考分支的 refs

`mainline.yml` 的 `unixnu_ref` / `device_ref` 默认值改成
`baeb8f0cf2143bd84e6076252c7f90345cc6fef6` / `bf7fc44cc3b1a92c842c84aa980993eaa74a2cd8`（2026-11-07 最后一次成功链接的
上游 run 42393995268），与 `ci/pre-upstream-sync-20261111` 分支一致。`wip/droidvm` 和 `wip/hackintosh` 后来切到 iPadOS 27
树，`package/DroidVMGpu.cpp` / `DroidVMFileExport.c` 引用的 `OSMetaClassAdoptSuperclass`、`droidvm_page_info` 等符号由
`ipados27/patches` 提供，而 21H461 板只应用 `patches/xnu`（overlay + UniXNU），链接会报 undefined symbols。需要测试新 ref 时
用 workflow_dispatch 的输入覆盖。

## 第一次跑的检查点

这台机器上没有 macOS SDK 和 XNU 源码，改动只做了 Python 单测（`tests/test_disable_owner_verification.py`）。
第一次 CI 跑 mainline 时重点看：

1. `disable-owner-verification.py` 在两个 device 树上都成功（没有 “cannot find” 报错）；
2. 链接没有 `native_verified_block_*` 未定义符号；
3. 串口里没有 `NativeVirtioBlock: ... policy refused`，`native_virtio_verified_devices` 为 0 或不存在；
4. SystemOS 挂载、Data 挂载仍然成功（`native_owner_cache_status=0` / `native_owner_data_status=0`）；
5. 没有 `native_owner_boot_manifest_status`（BOOT_MANIFEST 已关）。
