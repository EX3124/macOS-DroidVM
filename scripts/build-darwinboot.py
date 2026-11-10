#!/usr/bin/env python3
"""Build DarwinBoot.efi from the locked UniXNU DarwinBoot with this project's patch, using the local EDK II and GCC.

The patch (patches/darwinboot-reclaim-memory-and-512mb-kernel.patch) ports ios droidvm-linux/patches/darwinboot-reclaim-memory.patch to
the locked DarwinBoot (the /chosen/darwinboot-memory-limit consumer) and raises the kernel read limit from 128 MiB to 256 MiB: the
macOS kernel embeds 143 MB of block hashes. Output: artifacts/boot-inputs/DarwinBoot.efi and a provenance entry.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
WORK = ROOT / 'out/darwinboot'
EDK2 = ROOT / 'sources/edk2'
PATCH = ROOT / 'patches/darwinboot-reclaim-memory-and-512mb-kernel.patch'
PATCHES = [PATCH, ROOT / 'patches/darwinboot-accept-arm64e.patch']


def main():
    genfw = EDK2 / 'BaseTools/Source/C/bin/GenFw'
    if not genfw.exists():
        raise SystemExit(f'missing {genfw}')
    driver = WORK / 'DarwinBoot'
    shutil.rmtree(driver, ignore_errors=True)
    shutil.copytree(ROOT / 'sources/UniXNU/drivers/DarwinBoot', driver, ignore=shutil.ignore_patterns('.git'))
    for patch in PATCHES:
        subprocess.run(['patch', '-p1', '--no-backup-if-mismatch', '-i', str(patch)], cwd=driver, check=True)
    # GunyahBootPkg is the local firmware platform (sources/ only, not published); CI builds the same driver with the
    # DSC of the DarwinBoot package itself (UniXNU/DarwinBoot), which provides the MdePkg library classes it needs.
    gunyah = ROOT / 'sources/GunyahBootPkg/GunyahBoot.dsc'
    platform = 'GunyahBootPkg/GunyahBoot.dsc' if gunyah.exists() else 'DarwinBootPkg/DarwinBoot.dsc'
    workspace = WORK / 'ws'
    shutil.rmtree(workspace, ignore_errors=True)
    workspace.mkdir(parents=True)
    env = dict(os.environ, WORKSPACE=str(workspace), EDK_TOOLS_PATH=str(EDK2 / 'BaseTools'), PYTHON_COMMAND='python3',
               PACKAGES_PATH=':'.join([str(ROOT / 'sources'), str(EDK2), str(ROOT / 'sources/UniXNU/package'), str(driver)]),
               GCC_AARCH64_PREFIX='aarch64-linux-gnu-')
    # mu_basecore has no edksetup.sh (the workflow uses it for BaseTools): create the Conf files and PATH entry that
    # edksetup.sh provides, and keep using edksetup.sh when a full edk2 tree is in sources/.
    env['PATH'] = str(EDK2 / 'BaseTools/BinWrappers/PosixLike') + os.pathsep + env['PATH']
    conf = workspace / 'Conf'
    conf.mkdir(parents=True, exist_ok=True)
    for template, name in (('target.template', 'target.txt'), ('tools_def.template', 'tools_def.txt')):
        source = EDK2 / 'BaseTools/Conf' / template
        if source.exists() and not (conf / name).exists():
            shutil.copyfile(source, conf / name)
    build = f'build -p {platform} -m DarwinBootPkg/Driver/DarwinBoot.inf -a AARCH64 -b DEBUG -t GCC -n 4'
    if (EDK2 / 'edksetup.sh').exists():
        command = f'set +u; source "$1/edksetup.sh" BaseTools; set -u; {build}'
    else:
        command = f'set -u; {build}'
    subprocess.run(['bash', '-c', command, 'bash', str(EDK2)], cwd=ROOT, env=env, check=True)
    efi = next(workspace.rglob('DarwinBootPkg/Driver/DarwinBoot/OUTPUT/DarwinBoot.efi'))
    destination = ROOT / 'artifacts/boot-inputs/DarwinBoot.efi'
    shutil.copyfile(efi, destination)
    provenance = ROOT / 'artifacts/boot-inputs/provenance.json'
    record = json.loads(provenance.read_text())
    record['DarwinBoot.efi'] = {
        'sha256': hashlib.sha256(destination.read_bytes()).hexdigest(), 'bytes': destination.stat().st_size,
        'source': 'scripts/build-darwinboot.py: sources/UniXNU/drivers/DarwinBoot + ' + ' + '.join(p.name for p in PATCHES) +
                  ', edk2 ' + subprocess.check_output(['git', '-C', str(EDK2), 'rev-parse', 'HEAD'], text=True).strip()}
    provenance.write_text(json.dumps(record, indent=2) + '\n')
    print(destination, record['DarwinBoot.efi']['sha256'])


if __name__ == '__main__':
    main()
