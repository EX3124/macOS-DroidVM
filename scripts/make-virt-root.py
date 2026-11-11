#!/usr/bin/env python3
"""Unsigned block hashes of the root disks for the virtual machine board.

  make-virt-root.py OS.raw SYSTEMOS.dmg OUTDIR
  make-virt-root.py hash OS.raw SYSTEMOS.dmg OUTDIR

OS.raw is the IPSW OS image expanded with udif-expand.py (GPT + APFS), SYSTEMOS.dmg the Cryptex1,SystemOS member as is
(a raw APFS container). Both are served read-only as virtio-blk disks.

OUTDIR receives os.manifest.bin / systemos.manifest.bin (the 160-byte VROOT01 header followed by one SHA-256 per 4096-byte
block, no RSA signature), os.samples.bin, inputs.json and verified-root-inputs.tar.gz (the same files archived).

The owner key pair was removed: this project builds and boots without verifying the root disks, so nothing here is
signed. The header's anchor field (bytes 120..152) is zero and there is no 384-byte signature; consumers that expect the
owner envelope (kits/VerifiedRoot, scripts/owner-policy-dirs.py) are not part of the build any more. The block hashes
remain useful as host-side evidence that an image is the one that was hashed.

The volume UUIDs are the 21H461 ones for the iOS root; a macOS root has its volumes renamed before hashing
(apfs-volumes.py --set-uuid). Override with OS_UUID / SYSTEMOS_UUID in the environment.
"""
import hashlib
import json
import os
from pathlib import Path
import struct
import sys
import tarfile
import uuid

OS_UUID = os.environ.get('OS_UUID', '04769D26-2CA0-4825-B443-E2E5F88300F2')        # the 21H461 OS volume
SYSTEMOS_UUID = os.environ.get('SYSTEMOS_UUID', '8846FE78-2910-4297-AF97-D59BB6F8FC16')  # the 21H461 SystemOS volume
NAMES = (('os', OS_UUID), ('systemos', SYSTEMOS_UUID))


def hash_image(image, volume, work):
    """header.bin, hashes.bin and record.json for one image, without a key or a signature."""
    work.mkdir(parents=True, exist_ok=True)
    size = image.stat().st_size
    image_hash, table_hash = hashlib.sha256(), hashlib.sha256()
    count = 0
    with image.open('rb') as stream, (work / 'hashes.bin').open('wb') as hashes:
        remaining = size
        while remaining:
            data = stream.read(min(4096, remaining))
            if len(data) != min(4096, remaining):
                raise ValueError('Short image stream')
            digest = hashlib.sha256(data).digest()
            image_hash.update(data)
            table_hash.update(digest)
            hashes.write(digest)
            remaining -= len(data)
            count += 1
    # '<8s4I2Q16s32s32s32sQ': the anchor field is zero because there is no owner key.
    header = struct.pack('<8s4I2Q16s32s32s32sQ', b'VROOT01\0', 1, 160, 4096, 0, size, count,
                         uuid.UUID(volume).bytes, image_hash.digest(), table_hash.digest(), bytes(32), 1)
    (work / 'header.bin').write_bytes(header)
    record = dict(version=1, block_bytes=4096, image_bytes=size, block_count=count, volume_uuid=volume.upper(),
                  generation=1, image_sha256=image_hash.hexdigest(), hash_table_sha256=table_hash.hexdigest(),
                  signed=False, signature_algorithm='none', signature_verified_by_openssl=False,
                  image_modified=False, hardware_tested=False, boot_root_authenticated=False)
    (work / 'record.json').write_text(json.dumps(record, indent=2) + '\n')
    return record


def hash_step(os_image, systemos_image, out):
    out.mkdir(parents=True, exist_ok=True)
    records = {}
    for (name, volume), image in zip(NAMES, (os_image, systemos_image)):
        work = out / f'{name}-manifest'
        records[name] = hash_image(image, volume, work)
        # The unsigned envelope is the header followed by the block hashes; no 384-byte RSA signature.
        with (out / f'{name}.manifest.bin').open('wb') as envelope:
            envelope.write((work / 'header.bin').read_bytes())
            envelope.write((work / 'hashes.bin').read_bytes())
        print(f'{name}: {records[name]["block_count"]} blocks, image sha256 {records[name]["image_sha256"]}, '
              f'volume {volume}')
    count, size = records['os']['block_count'], records['os']['image_bytes']
    indices = [0, 1, count // 2, count - 1]
    lengths = [4096, 4096, 4096, size - (count - 1) * 4096]
    with os_image.open('rb') as stream, (out / 'os.samples.bin').open('wb') as samples:
        for index, length in zip(indices, lengths):
            stream.seek(index * 4096)
            samples.write(stream.read(length).ljust(4096, b'\0'))
    records['os'].update(sample_indices=indices, sample_lengths=lengths)
    (out / 'inputs.json').write_text(json.dumps(records, indent=2) + '\n')
    members = ['os.manifest.bin', 'systemos.manifest.bin', 'os.samples.bin', 'inputs.json']
    with tarfile.open(out / 'verified-root-inputs.tar.gz', 'w:gz') as archive:
        for member in members:
            archive.add(out / member, arcname=member)
    digest = hashlib.sha256((out / 'verified-root-inputs.tar.gz').read_bytes()).hexdigest()
    print(f'{out / "verified-root-inputs.tar.gz"}: sha256 {digest}')


if len(sys.argv) == 5 and sys.argv[1] == 'hash':
    hash_step(Path(sys.argv[2]), Path(sys.argv[3]), Path(sys.argv[4]))
elif len(sys.argv) == 4:
    hash_step(Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3]))
else:
    raise SystemExit(__doc__)
