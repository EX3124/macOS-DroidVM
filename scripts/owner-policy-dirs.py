#!/usr/bin/env python3
"""Lay out an unsigned verified-root-inputs directory as build/verified-root-{os,systemos}.

    owner-policy-dirs.py INPUTS TREE [ios|macos]

INPUTS is the directory extracted from verified-root-inputs.tar.gz (scripts/make-virt-root.py, unsigned): os.manifest.bin,
systemos.manifest.bin, os.samples.bin and inputs.json. TREE is the unixnu build tree; this writes
TREE/build/verified-root-os/ and TREE/build/verified-root-systemos/ (manifest.bin, verification.json, and
original-samples.bin for the OS). There is no trusted-key.bin: the manifests are header + block hashes without an RSA
signature.

The mainline build no longer consumes these files (scripts/disable-owner-verification.py turns the probe, the boot manifest
and NativeVirtioBlock verification off). This script keeps the host-side layout for comparing an image with the hashes it
was generated from.
"""
import json
from pathlib import Path
import shutil
import sys

ROOTS = {
    # iPadOS 21H461: the OS member expanded, the Cryptex1,SystemOS member as is.
    'ios': {'os': ('e5634d04a8ac35f024845f583394e0a35deb26a04cb0c00286a8674e25a9a4f2', 1483785),
            'systemos': ('b4908cde41d23e6bc05e6af51a2c9eeb00cf0f863a6a18b1600c96a3fd70414f', 806400)},
}


def expected(root, kind):
    if kind != 'macos':
        return ROOTS[kind]
    pins = root / 'out/owner/macos-root-pins.json'
    if not pins.is_file():
        raise SystemExit(f'{pins} missing: no macOS pins to compare against')
    data = json.loads(pins.read_text())
    return {name: (pin['image_sha256'], pin['blocks_verified']) for name, pin in data.items()}


inputs, tree = map(Path, sys.argv[1:3])
kind = sys.argv[3] if len(sys.argv) > 3 else 'ios'
pins = expected(Path(__file__).resolve().parents[1], kind)
records = json.loads((inputs / 'inputs.json').read_text())
for name, (digest, blocks) in pins.items():
    record = records[name]
    if record['image_sha256'] != digest or record['block_count'] != blocks:
        raise SystemExit(f'{name}: the hashes do not describe the expected image')
    out = tree / 'build' / f'verified-root-{name}'
    out.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(inputs / f'{name}.manifest.bin', out / 'manifest.bin')
    report = dict(image_bytes=record['image_bytes'], blocks_verified=record['block_count'], image_sha256=digest,
                  volume_uuid=record['volume_uuid'], generation=record['generation'], signed=False,
                  real_c_signature_and_block_verification=False, original_image_modified=False, host_only=True,
                  boot_root_authenticated=False, hardware_tested=False,
                  source='make-virt-root.py: unsigned per-block SHA-256 of an unmodified image')
    if name == 'os':
        report.update(actual_sample_indices=record['sample_indices'], actual_sample_lengths=record['sample_lengths'])
        shutil.copyfile(inputs / 'os.samples.bin', out / 'original-samples.bin')
    (out / 'verification.json').write_text(json.dumps(report, indent=2) + '\n')
    print(f'{out}: {blocks} blocks, image {digest[:16]}')
