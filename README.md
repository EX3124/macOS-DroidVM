# unixnu-droidvm-ci

macOS 开发规划与阶段验收见 [TODO.md](TODO.md)（2026-10-22，参考本地 iOS、UniXNU、ios-vermeer-lab 和 Snapintosh）。

本项目全部开发与产物保存在 `macos/` 内，外部目录仅作只读参考；文档仅保留本地，不纳入 commit。

GitHub Actions builds for porting [UniXNU](https://github.com/UniXNU) to QEMU/KVM `virt` and to
[DroidVM](https://github.com/Droid-VM) crosvm on Gunyah.

- `.github/workflows/kernel.yml`: `unixnu build kernel` on a macOS runner.
- `device/UniXNU-droidvm`: device repository of the virtual board.
- `local/`: local overrides of UniXNU modules, same layout as the UniXNU repository.

Binary artifacts contain components of Apple's kernelcache and are uploaded as plain artifacts (and release assets).

`mainline.yml` dispatches the other workflows of the repository when a run finishes; disable it with the
`trigger_downstream=false` input.

The kernel embeds the owner root policies of its disks, so the `root-policies` (iOS) and `root-policies-macos` (macOS)
releases must exist before a `mainline` run. In a fresh fork, run them in this order first: `root-policies.yml`, then
`macos-disks.yml` (it reuses the owner key of the first one), then `mainline.yml`.
