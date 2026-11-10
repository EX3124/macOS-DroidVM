#!/usr/bin/env python3
"""CI helper: OS.raw and SYSTEMOS.dmg from the board IPSW, for make-virt-root.py.

Extracts the OS and Cryptex1,SystemOS members through the UniXNU Ipsw machinery
(the sha256 pins of board.toml apply), then expands the UDIF OS image to a raw
disk with hdiutil convert (macOS runner) and copies the SystemOS cryptex member
as is (it is already a raw APFS container).
"""
import glob
import shutil
import subprocess
import sys
import tomllib
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent / 'UniXNU' / 'scripts'))
from unixnu.ipsw import Ipsw  # noqa: E402


class Ctx:
    def __init__(self):
        self.board = tomllib.load(open('device/board.toml', 'rb'))
        self.out_root = Path('out')

    @staticmethod
    def option_text(*names):
        return 'ipsw.ipsw'


def main():
    ipsw = Ipsw(Ctx())
    os_dmg = ipsw.extract('OS')
    systemos = ipsw.extract('Cryptex1,SystemOS')
    subprocess.run(['hdiutil', 'convert', str(os_dmg), '-format', 'UDRW', '-o', 'OSraw'], check=True)
    converted = [p for p in glob.glob('OSraw*')]
    if len(converted) != 1:
        raise SystemExit(f'hdiutil convert produced {converted}')
    shutil.move(converted[0], 'OS.raw')
    shutil.copyfile(systemos, 'SYSTEMOS.dmg')
    for name in ('OS.raw', 'SYSTEMOS.dmg'):
        print(f'{name}: {Path(name).stat().st_size} bytes')


if __name__ == '__main__':
    main()
