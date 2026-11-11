#!/usr/bin/env python3
"""Assemble the macOS 27 boot disk (boot.img) from a kernel collection and the pinned boot inputs.

    ci/boot27.py --kernel out/k27/kc-k27.bin \
                 --trustcache artifacts/27.2/boot/kernel.macho.trustcache \
                 --data artifacts/27.2/disk/scratch-data.img \
                 --fdt artifacts/27.2/generated.dtb \
                 --unixnu-efi artifacts/boot-inputs/UniXNU.efi \
                 --darwinboot artifacts/boot-inputs/DarwinBoot.efi \
                 --out out/boot27

This is the assembly half of `droidvm-app.py boot` (scripts/droidvm-app.py, boot_disk): the ADT generated from the FDT
the VM's crosvm dumped, the kernel command line, the trust cache, the Data seed and the kernel collection are written
into the 384 MiB FAT payload image the app boots. It needs no phone, so CI can run it; the FDT and UniXNU.efi are
recorded inputs (ci/make-k27-bundle.sh carries them), while the kernel collection is built by ci/k27-build.sh.

The board's kernel arguments come from sources/UniXNU-droidvm/board.toml (run-macos-vm.py), so the pinned device
repository must be present.
"""
import argparse
import hashlib
import importlib.util
import json
import os
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CHIP_ID = '47554e5941480001'
# scripts/droidvm-app.py REQUIRED_ARGS: without them launchd cannot get far on this kernel (see TODO.md).
REQUIRED_ARGS = ['mac-amfi-launch-permissive=1', 'malloc-ranges-off=1', 'arm64_maxoffset=0x7FFE000000',
                 'ml-timeout-lock-scale=40', 'droidvm-timebase-hz=24000000']
# scripts/droidvm-app.py GPU_ARGS: Metal on the virtio GPU's 3D (vgpu-3d=1) and WindowServer's frame pacing.
GPU_ARGS = ['vgpu-3d=1', 'ca-triple-buffer=1', 'ca-free-wakeup=1']
EXEC_ENV = ['com.apple.WebKit.WebContent:GIGACAGE_ENABLED=no']


def sha256(path):
    digest = hashlib.sha256()
    with open(path, 'rb') as handle:
        for block in iter(lambda: handle.read(1 << 24), b''):
            digest.update(block)
    return digest.hexdigest()


def require(path, what):
    path = Path(path)
    if not path.is_file() or path.stat().st_size == 0:
        raise SystemExit(f'boot27: missing {what}: {path}')
    return path


def rel(path):
    """Path for the manifest: repository-relative when possible, absolute otherwise."""
    resolved = Path(path).resolve()
    try:
        return str(resolved.relative_to(ROOT))
    except ValueError:
        return str(resolved)


def load_run(kernel, tag, root_uuid):
    """Import scripts/run-macos-vm.py with the environment its module-level constants read."""
    os.environ['MACOS_KERNEL'] = str(Path(kernel).resolve())
    os.environ['MACOS_TAG'] = tag
    os.environ.setdefault('MACOS_LP_SIP0', '0x2')          # CSR_ALLOW_UNRESTRICTED_FS: the dyld cache has no SF_RESTRICTED
    os.environ['MACOS_ROOT_UUID'] = root_uuid
    spec = importlib.util.spec_from_file_location('run_macos_vm', ROOT / 'scripts/run-macos-vm.py')
    module = importlib.util.module_from_spec(spec)
    sys.modules['run_macos_vm'] = module
    spec.loader.exec_module(module)
    return module


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--kernel', required=True, help='the kernel collection (kc-k27.bin) or a kernel.macho')
    parser.add_argument('--trustcache', required=True, help='kernel.macho.trustcache (OS + System + our modules)')
    parser.add_argument('--data', required=True, help='scratch-data.img, the Data seed the payload carries')
    parser.add_argument('--fdt', required=True, help='generated.dtb dumped by the VM config (ADT source)')
    parser.add_argument('--unixnu-efi', required=True, help='UniXNU.efi (the app boot disk\'s EFI/BOOT/BOOTAA64.EFI)')
    parser.add_argument('--darwinboot', required=True, help='DarwinBoot.efi (scripts/build-darwinboot.py)')
    parser.add_argument('--out', default='out/boot27', help='output directory (boot.img and its manifest)')
    parser.add_argument('--tag', default=os.environ.get('MACOS_TAG', '27.2'))
    parser.add_argument('--mem-mb', type=int, default=5120, help='guest RAM; must match the VM whose FDT dumped')
    parser.add_argument('--root-uuid', default='4646A7E0-5598-41A2-B158-E1AF6D3CF7FB', help='System volume UUID of the store')
    parser.add_argument('--virtio-gpu', action=argparse.BooleanOptionalAction, default=True, help='crosvm --virtio-mmio-gpu is on')
    parser.add_argument('--net', action=argparse.BooleanOptionalAction, default=True, help='crosvm --virtio-mmio-net is on')
    parser.add_argument('--snd', action='store_true', help='crosvm --virtio-mmio-snd is on')
    parser.add_argument('--media', type=int, default=0, help='crosvm --virtio-media devices on virtio-mmio')
    parser.add_argument('--gpu', action=argparse.BooleanOptionalAction, default=False,
                        help='Metal on the GPU (vgpu-3d, frame pacing); needs the DroidVMGpu/DroidVMDisplay kexts and the plugin')
    parser.add_argument('--kernel-arg', action='append', default=[], help='extra kernel argument (repeatable)')
    args = parser.parse_args()

    if not (ROOT / 'sources/UniXNU-droidvm/board.toml').is_file():
        raise SystemExit('boot27: missing sources/UniXNU-droidvm/board.toml '
                         '(scripts/prepare-sources.py fetches it; the bundle carries it)')
    kernel = require(args.kernel, 'kernel collection')
    trust = require(args.trustcache, 'trust cache')
    data = require(args.data, 'Data seed')
    fdt = require(args.fdt, 'FDT')
    unixnu = require(args.unixnu_efi, 'UniXNU.efi')
    darwinboot = require(args.darwinboot, 'DarwinBoot.efi')
    if args.media and not args.virtio_gpu:
        raise SystemExit('boot27: --media needs --virtio-gpu (the media windows follow the GPU window)')

    out = Path(args.out).resolve()
    shutil.rmtree(out, ignore_errors=True)
    out.mkdir(parents=True)
    local = out / 'boot'
    local.mkdir()

    # run-macos-vm.build_boot_disk reads the two EFI payloads from artifacts/boot-inputs/.
    inputs = ROOT / 'artifacts/boot-inputs'
    inputs.mkdir(parents=True, exist_ok=True)
    for source, name in ((unixnu, 'UniXNU.efi'), (darwinboot, 'DarwinBoot.efi')):
        destination = inputs / name
        if source.resolve() != destination.resolve():
            shutil.copyfile(source, destination)

    run = load_run(kernel, args.tag, args.root_uuid)
    # The ADT's DRAM ends below the firmware window, the simplefb framebuffer and the host pools at the top of RAM
    # (scripts/droidvm-app.py boot_disk).
    dram = args.mem_mb * 1024 * 1024 - 0x600000 - run.fdt_framebuffer_bytes(fdt) - run.fdt_pool_bytes(fdt)
    if dram <= 0:
        raise SystemExit(f'boot27: MEM_MB={args.mem_mb} leaves no DRAM after the firmware window, framebuffer and pools')
    adt = local.parent / 'kernel.macho.adt'
    run.make_adt(fdt, hex(dram), CHIP_ID, adt, cpu_regs=None,                      # every vCPU the app gives the VM
                 virtio_gpu=args.virtio_gpu, net=args.net, snd=args.snd, media=args.media)

    extra = list(REQUIRED_ARGS)
    if args.gpu:
        extra += GPU_ARGS
    extra += ['exec-env=' + ';'.join(EXEC_ENV)] + list(args.kernel_arg)
    line = run.kernel_args(extra)
    disk = run.build_boot_disk(local, trust, data, adt, line)

    final = out / 'boot.img'
    shutil.move(disk, final)
    shutil.rmtree(local, ignore_errors=True)

    manifest = {
        'tag': args.tag, 'mem_mb': args.mem_mb, 'root_uuid': args.root_uuid.upper(),
        'virtio_gpu': args.virtio_gpu, 'net': args.net, 'snd': args.snd, 'media': args.media, 'gpu': args.gpu,
        'kernel_args': line,
        'inputs': {rel(path): {'size': path.resolve().stat().st_size, 'sha256': sha256(path)}
                   for path in (kernel, trust, data, fdt, unixnu, darwinboot)},
        'output': {'file': final.name, 'size': final.stat().st_size, 'sha256': sha256(final)},
    }
    (out / 'boot.json').write_text(json.dumps(manifest, indent=2) + '\n')
    (out / 'boot.img.sha256').write_text(f'{manifest["output"]["sha256"]}  boot.img\n')
    print(json.dumps({'boot.img': str(final), 'size': manifest['output']['size'],
                      'sha256': manifest['output']['sha256'], 'kernel_args': line}, indent=2))


if __name__ == '__main__':
    main()
