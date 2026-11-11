#!/usr/bin/env python3
"""Turn the VerifiedRoot/owner verification chain off in a DroidVM device tree and its UniXNU checkout.

    disable-owner-verification.py DEVICE [--unixnu UNIXNU] [--tree TREE]

The mainline embeds the owner root policies of its OS and SystemOS disks (scripts/make-virt-root.py) and NativeVirtioBlock
authenticates every block it reads against them. Producing those policies needs an RSA-3072 owner key pair; this project
now builds without signing, so the device repository and the XNU patches are rewritten here, inside the workflow, instead
of in the upstream repositories:

  - board.toml: drop the build-verified-root-probe.py archive and the --verified-root flags of
    build-arm-driver.py NativeVirtioBlock;
  - the defconfig: XNU_VERIFIED_ROOT_PROBE=n, XNU_OWNER_BOOT_MANIFEST=n, and no XNU_VERIFIED_ROOT_ARCHIVE;
  - the scratch Data mount's #error in offline-owner-systemos-mount.patch, which requires a boot manifest.

The owner mounts (cache mount, cache carrier, union SystemOS, Data) stay enabled: they are what makes the macOS root
bootable, and the overlay NativeVirtioBlock exports a permissive native_verified_block_root_authorized() when
NATIVE_VERIFIED_BLOCK is off, so their authorization hooks still link and accept the published disks.

Everything is located by text: an upstream rewrite fails loudly instead of silently leaving verification on.
"""
import argparse
import re
import sys
from pathlib import Path


def edit_board(device):
    board = device / 'board.toml'
    text = board.read_text()
    removed = 0
    lines = []
    for line in text.splitlines(keepends=True):
        if re.match(r'\s*"build-(?:(?:virt-)?verified-root|owner-(?:os|systemos)-policy)[^"]*",\s*$', line):
            removed += 1
            continue
        lines.append(line)
    text = ''.join(lines)
    if not removed and 'build-verified-root' in text:
        raise SystemExit(f'{board}: build-verified-root entry not matched by the archive pattern')
    text, drivers = re.subn(
        r'("build-arm-driver\.py NativeVirtioBlock)((?: [^"]*)?)"',
        lambda match: match.group(1) + re.sub(r' --verified-root(?:-bundle)?', '', match.group(2)) + '"',
        text)
    if '--verified-root' in text:
        raise SystemExit(f'{board}: a --verified-root flag survived')
    # Without --verified-root-bundle build-arm-driver.py writes build/native-virtio-block, so the bindings builder and the
    # archive path must move with it.
    text = text.replace('build/native-virtio-block-verified-bundle', 'build/native-virtio-block')
    if 'verified-bundle' in text:
        raise SystemExit(f'{board}: a verified-bundle path survived')
    board.write_text(text)
    if drivers:
        print(f'{board}: removed {removed} verified-root archive(s), {drivers} NativeVirtioBlock builder(s) unsigned')
    else:
        # make-reference-device.py drops the NativeVirtioBlock builder (and its verification options) from the
        # reference candidate entirely.
        print(f'{board}: removed {removed} verified-root archive(s), no NativeVirtioBlock builder (reference device)')


def edit_defconfig(device, defconfig):
    config = device / 'configs' / defconfig
    if not config.is_file():
        raise SystemExit(f'{config}: missing')
    out = []
    for line in config.read_text().splitlines(keepends=True):
        stripped = line.strip()
        if stripped.startswith('CONFIG_XNU_VERIFIED_ROOT_PROBE='):
            out.append('CONFIG_XNU_VERIFIED_ROOT_PROBE=n\n')
        elif stripped.startswith('CONFIG_XNU_OWNER_BOOT_MANIFEST='):
            out.append('CONFIG_XNU_OWNER_BOOT_MANIFEST=n\n')
        elif stripped.startswith('CONFIG_XNU_VERIFIED_ROOT_ARCHIVE='):
            continue
        else:
            out.append(line)
    body = ''.join(out).replace('(verified owner root)', '(unsigned owner root)')
    body = body.replace('build/native-virtio-block-verified-bundle', 'build/native-virtio-block')
    if 'verified-bundle' in body:
        raise SystemExit(f'{config}: a verified-bundle archive path survived')
    for line in body.splitlines():
        stripped = line.strip()
        if stripped in ('CONFIG_XNU_VERIFIED_ROOT_PROBE=y', 'CONFIG_XNU_OWNER_BOOT_MANIFEST=y',
                        'CONFIG_XNU_VERIFIED_ROOT_ARCHIVE') or stripped.startswith('CONFIG_XNU_VERIFIED_ROOT_ARCHIVE='):
            raise SystemExit(f'{config}: verification option survived: {stripped}')
    header = '# Unsigned build: no owner key or policy is embedded (scripts/disable-owner-verification.py).\n'
    if header not in body:
        body = header + body
    config.write_text(body)
    print(f'{config}: probe and boot manifest off, probe archive path removed')


def edit_patch(device, unixnu):
    name = 'offline-owner-systemos-mount.patch'
    targets = [unixnu / 'patches/xnu' / name]
    copied = device / 'patches/xnu' / name
    if copied.is_file() and copied not in targets:
        targets.append(copied)   # the workflow copies UniXNU's patches into the device repository first
    guard = re.compile(
        r'\+#if !defined\(XNU_OWNER_BOOT_MANIFEST\) \|\| !XNU_OWNER_BOOT_MANIFEST\r?\n'
        r'\+#error Scratch Data mounting requires the authenticated original OS startup path\r?\n'
        r'\+#endif\r?\n')
    for patch in targets:
        if not patch.is_file():
            raise SystemExit(f'{patch}: missing')
        text = patch.read_text()
        # The replacement must keep the hunk's added-line count: a unified diff whose @@ header no longer matches its
        # body is corrupt (git apply: "corrupt patch"). Three added lines replace the three removed ones.
        text, count = guard.subn(
            '+/*\n'
            '+ * Unsigned build: no boot manifest is published; the scratch Data mount still runs.\n'
            '+ */\n', text)
        if not count:
            if '#error Scratch Data mounting requires the authenticated original OS startup path' in text:
                raise SystemExit(f'{patch}: the Data mount guard did not match')
            print(f'{patch}: already unsigned')
        else:
            patch.write_text(text)
            print(f'{patch}: boot-manifest requirement of the scratch Data mount removed')


def edit_baseline(script):
    """Relax the two build-script guards that assume the signed owner chain is present."""
    if not script.is_file():
        print(f'{script}: missing, no baseline guards to relax')
        return
    text = script.read_text()
    guards = (
        (re.compile(
            r'if \[ "\$OWNER_ROOT_AUDIT" = 1 \] && \[ "\$OWNER_ROOT_PROBE" != 1 \]'
            r'(?: && \[ "\$\{XNU_SOURCE_STORAGE:-0\}" != 1 \])?; then\n'
            r'  echo \'The root-binding audit requires real owner-verified block crypto\' >&2\n'
            r'  exit 1\n'
            r'fi\n'),
         '# Unsigned build: the root-binding audit keeps running against the permissive driver hook.\n',
         'The root-binding audit requires real owner-verified block crypto'),
        (re.compile(
            r'if \[ "\$OWNER_DATA_MOUNT" = 1 \] && \[ "\$OWNER_BOOT_MANIFEST" != 1 \]; then\n'
            r'  echo \'Scratch Data requires authenticated original OS/owner metadata startup\' >&2\n'
            r'  exit 1\n'
            r'fi\n'),
         '# Unsigned build: no boot manifest is published; the scratch Data mount still runs.\n',
         'Scratch Data requires authenticated original OS/owner metadata startup'),
    )
    for pattern, replacement, marker in guards:
        text, count = pattern.subn(replacement, text)
        if not count:
            if marker in text:
                raise SystemExit(f'{script}: the owner guard did not match')
            print(f'{script}: {marker!r} already absent')
    script.write_text(text)
    print(f'{script}: owner-root and scratch-Data guards relaxed')


def edit_applied_tree(tree):
    """An existing out/.../tree has already applied the XNU patches; drop the guard from its work tree too."""
    source = tree / '.cache/xnu-work/bsd/vm/vm_unix.c'
    if not source.is_file():
        print(f'{source}: not applied yet')
        return
    text = source.read_text()
    guard = re.compile(
        r'#if !defined\(XNU_OWNER_BOOT_MANIFEST\) \|\| !XNU_OWNER_BOOT_MANIFEST\s*\n'
        r'#error Scratch Data mounting requires the authenticated original OS startup path\s*\n'
        r'#endif\s*\n')
    text, count = guard.subn('/* Unsigned build: no boot manifest is published; the scratch Data mount still runs. */\n',
                             text)
    if count:
        source.write_text(text)
        print(f'{source}: boot-manifest requirement of the scratch Data mount removed')
    elif '#error Scratch Data mounting requires' in text:
        raise SystemExit(f'{source}: the Data mount guard did not match')
    else:
        print(f'{source}: already unsigned')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('device', type=Path, help='a UniXNU-droidvm checkout')
    parser.add_argument('--unixnu', type=Path, help='the UniXNU checkout whose patches/xnu is built (optional)')
    parser.add_argument('--tree', type=Path, help='an already assembled unixnu tree (optional)')
    args = parser.parse_args()
    device = args.device.resolve()
    board = device / 'board.toml'
    if not board.is_file():
        raise SystemExit(f'{board}: missing')
    import tomllib
    defconfig = tomllib.load(open(board, 'rb'))['kernel']['defconfig']
    edit_board(device)
    edit_defconfig(device, defconfig)
    if args.unixnu:
        unixnu = args.unixnu.resolve()
        if not (unixnu / 'patches/xnu').is_dir():
            raise SystemExit(f'{unixnu}: no patches/xnu')
        edit_patch(device, unixnu)
        edit_baseline(unixnu / 'scripts/build-xnu-4k-baseline.sh')
    if args.tree:
        tree = args.tree.resolve()
        edit_applied_tree(tree)
        edit_baseline(tree / 'scripts/build-xnu-4k-baseline.sh')


if __name__ == '__main__':
    sys.exit(main())
