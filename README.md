# unixnu-droidvm-ci

macOS 开发规划与阶段验收见 [TODO.md](TODO.md)（2026-10-22，参考本地 iOS、UniXNU、ios-vermeer-lab 和 Snapintosh）。

本项目全部开发与产物保存在 `macos/` 内，外部目录仅作只读参考；文档仅保留本地，不纳入 commit。

GitHub Actions builds for porting [UniXNU](https://github.com/UniXNU) to QEMU/KVM `virt` and to
[DroidVM](https://github.com/Droid-VM) crosvm on Gunyah.

- `.github/workflows/kernel.yml`: `unixnu build kernel` on a macOS runner.
- `.github/workflows/macos27-payload.yml`: the macOS 27 kernel payload (xnu-12377 + patches, native kexts, kernel collection) on a macOS runner with Xcode 27, from public sources (`ci/harness/`).
- `device/UniXNU-droidvm`: device repository of the virtual board.
- `local/`: local overrides of UniXNU modules, same layout as the UniXNU repository.

Binary artifacts contain components of Apple's kernelcache and are uploaded as plain artifacts (and release assets).

The DroidVM mainline is built unsigned: there is no owner key and no `verified-root-inputs.tar.gz`. `mainline.yml` rewrites
the device tree with `scripts/disable-owner-verification.py` (probe and boot manifest off, NativeVirtioBlock reads without
authenticating blocks, owner mounts unchanged). See [docs/unsigned-build.md](docs/unsigned-build.md).
