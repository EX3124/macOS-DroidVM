# Boot fixtures recovered from this repository's history

These two files are boot inputs that cannot be fetched from a public URL and cannot be derived on a machine without
the phone; they were tracked once, dropped when the legacy boot-disk path was removed (`3811d11`), and are restored
here so the macOS 27 boot payload does not depend on an uploaded bundle for them.

| File | Size | SHA-256 | Recovered from |
| --- | --- | --- | --- |
| `UniXNU.efi` | 95232 | `116c7b83fec8ca0fa97f50d61ff5090087c84a02471592b3ccf2967c8d2aee8f` | `ff7c4a4` ("bootdisk-build: add UniXNU.efi") |
| `generated.dtb` | 8287 | `e9074729a8dcac17fcfb0f7e9e64e6127942fcdda314f5bc3b86d4395caa9388` | `eabebe7` ("bootdisk-build: add generated.dtb") |

`UniXNU.efi` is the UEFI boot manager (`EFI/BOOT/BOOTAA64.EFI` of the app's boot disk). `generated.dtb` is the FDT a
VM run dumped; `ci/boot27.py` turns it into the ADT.

Caveat: the recorded FDT is the one of the 23G93-era VM (the old `bootdisk-build` workflow asked for 6144 MB and the
devices of that configuration). The macOS 27 VM has a different device set (virtio-gpu, net, snd, media windows and
5120 MB); a boot disk assembled from this FDT will only be right together with the same device set and `--mem-mb`.
Regenerate it on the device (`droidvm-app.py prepare` dumps `generated.dtb` for the VM it registered) when the 27
configuration changes. It is kept here as the only recorded copy, not as the qualified 27 input.
