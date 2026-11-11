#!/usr/bin/env python3
"""The unsigned build rewrite of a device tree (scripts/disable-owner-verification.py)."""
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

BOARD = '''[board]
name = "droidvm"

[kernel]
defconfig = "droidvm_defconfig"
archives = [
  "build-corecrypto-14.py",
  "build-verified-root-probe.py --component os --include-systemos",
  "build-arm-driver.py NativeVirtioBlock --verified-root --verified-root-bundle",
  "build-native-virtio-bindings.py --component NativeVirtioBlock --directory build/native-virtio-block-verified-bundle",
]
'''

CONFIG = '''CONFIG_XNU_NATIVE_VIRTIO_BLOCK=y
CONFIG_XNU_VERIFIED_ROOT_PROBE=y
CONFIG_XNU_OWNER_ROOT_AUDIT=y
CONFIG_XNU_OWNER_ROOT_TRUST=y
CONFIG_XNU_OWNER_CACHE_MOUNT=y
CONFIG_XNU_OWNER_BOOT_MANIFEST=y
CONFIG_XNU_OWNER_DATA_MOUNT=y
CONFIG_XNU_NATIVE_VIRTIO_BLOCK_ARCHIVE="{tree}/build/native-virtio-block-verified-bundle/libVirtioMmioBlock.a"
CONFIG_XNU_VERIFIED_ROOT_ARCHIVE="{tree}/build/verified-root-os-xnu-bundle/libVerifiedRootProbe.a"
'''

PATCH = '''--- a/bsd/vm/vm_unix.c
+++ b/bsd/vm/vm_unix.c
@@
+#if defined(XNU_OWNER_DATA_MOUNT) && XNU_OWNER_DATA_MOUNT
+#if !defined(XNU_OWNER_BOOT_MANIFEST) || !XNU_OWNER_BOOT_MANIFEST
+#error Scratch Data mounting requires the authenticated original OS startup path
+#endif
+#if defined(XNU_NATIVE_RAM_BLOCK) && XNU_NATIVE_RAM_BLOCK
+#endif
'''


class DisableOwnerVerificationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        root = Path(self.temp.name)
        self.device = root / 'device'
        self.unixnu = root / 'UniXNU'
        (self.device / 'configs').mkdir(parents=True)
        (self.device / 'patches/xnu').mkdir(parents=True)
        (self.unixnu / 'patches/xnu').mkdir(parents=True)
        (self.device / 'board.toml').write_text(BOARD)
        (self.device / 'configs/droidvm_defconfig').write_text(CONFIG)
        (self.unixnu / 'patches/xnu/offline-owner-systemos-mount.patch').write_text(PATCH)
        (self.device / 'patches/xnu/offline-owner-systemos-mount.patch').write_text(PATCH)
        self.script = ROOT / 'scripts/disable-owner-verification.py'

    def tearDown(self):
        self.temp.cleanup()

    def run_script(self):
        subprocess.run([sys.executable, str(self.script), str(self.device), '--unixnu', str(self.unixnu)],
                       check=True, capture_output=True, text=True)

    def test_rewrites_the_device_and_the_patch(self):
        self.run_script()
        board = (self.device / 'board.toml').read_text()
        self.assertNotIn('build-verified-root', board)
        self.assertNotIn('--verified-root', board)
        self.assertIn('"build-arm-driver.py NativeVirtioBlock"', board)
        self.assertIn('build-native-virtio-bindings.py', board)
        config = (self.device / 'configs/droidvm_defconfig').read_text()
        self.assertIn('CONFIG_XNU_VERIFIED_ROOT_PROBE=n', config)
        self.assertIn('CONFIG_XNU_OWNER_BOOT_MANIFEST=n', config)
        self.assertNotIn('CONFIG_XNU_VERIFIED_ROOT_ARCHIVE', config)
        self.assertIn('CONFIG_XNU_OWNER_DATA_MOUNT=y', config)
        self.assertIn('CONFIG_XNU_OWNER_ROOT_TRUST=y', config)
        self.assertTrue(config.startswith('# Unsigned build:'))
        for patch in (self.device / 'patches/xnu', self.unixnu / 'patches/xnu'):
            text = (patch / 'offline-owner-systemos-mount.patch').read_text()
            self.assertNotIn('#error Scratch Data mounting', text)

    def test_idempotent(self):
        self.run_script()
        first = (self.device / 'configs/droidvm_defconfig').read_text()
        self.run_script()
        self.assertEqual((self.device / 'configs/droidvm_defconfig').read_text(), first)

    def test_removes_the_guard_from_an_applied_tree(self):
        tree = Path(self.temp.name) / 'tree'
        source = tree / '.cache/xnu-work/bsd/vm/vm_unix.c'
        source.parent.mkdir(parents=True)
        source.write_text('#if !defined(XNU_OWNER_BOOT_MANIFEST) || !XNU_OWNER_BOOT_MANIFEST\n'
                          '#error Scratch Data mounting requires the authenticated original OS startup path\n'
                          '#endif\n')
        subprocess.run([sys.executable, str(self.script), str(self.device), '--tree', str(tree)],
                       check=True, capture_output=True, text=True)
        self.assertNotIn('#error Scratch Data mounting', source.read_text())

    def test_reference_device_without_the_driver_is_tolerated(self):
        # make-reference-device.py drops build-arm-driver.py NativeVirtioBlock from the reference candidate.
        (self.device / 'board.toml').write_text(
            BOARD.replace('"build-arm-driver.py NativeVirtioBlock --verified-root --verified-root-bundle",\n', ''))
        self.run_script()
        board = (self.device / 'board.toml').read_text()
        self.assertNotIn('verified-root', board)

    def test_a_stray_verified_root_flag_fails(self):
        (self.device / 'board.toml').write_text(BOARD.replace('build-arm-driver.py NativeVirtioBlock',
                                                              'build-arm-driver.py ArmCpu --verified-root'))
        with self.assertRaises(subprocess.CalledProcessError):
            self.run_script()


if __name__ == '__main__':
    unittest.main()
