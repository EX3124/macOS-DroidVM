#!/usr/bin/env python3
"""Write GunyahBootPkg/GunyahBoot.dsc from the public GunyahPkg/GunyahKernel.dsc.

    make-gunyah-boot.py EDK2_GUNYAH_DIR OUTPUT_DIR

The developer tree had a GunyahBootPkg: a copy of GunyahPkg whose DSC builds only DarwinBootPkg/Driver/DarwinBoot.inf
(scripts/build-darwinboot.py). The public edk2-gunyah has GunyahPkg and GunyahKernel.dsc but no GunyahBoot.dsc, so this
derives it: keep the platform PCDs, library classes and build options of GunyahKernel.dsc, replace its component list
with the one DarwinBoot module. GunyahKernel.dsc's FDF is not used for a -m build.
"""
import sys
from pathlib import Path

source, output = Path(sys.argv[1]), Path(sys.argv[2])
dsc = (source / 'GunyahPkg/GunyahKernel.dsc').read_text()
marker = '[Components'
if marker not in dsc:
    raise SystemExit(f'{source}/GunyahPkg/GunyahKernel.dsc: no [Components] section')
text = dsc[:dsc.index(marker)]
replacements = [
    ('PLATFORM_NAME                  = Gunyah', 'PLATFORM_NAME                  = GunyahBoot'),
    ('OUTPUT_DIRECTORY               = Build/GunyahKernel-$(ARCH)', 'OUTPUT_DIRECTORY               = Build/GunyahBoot-$(ARCH)'),
]
for old, new in replacements:
    if old not in text:
        raise SystemExit(f'GunyahKernel.dsc: unexpected header line: {old!r}')
    text = text.replace(old, new)
text += ('\n'
         '################################################################################\n'
         '#\n'
         '# Components - only the DarwinBoot bootloader package (build-darwinboot.py -m)\n'
         '#\n'
         '################################################################################\n'
         '[Components]\n'
         '  DarwinBootPkg/Driver/DarwinBoot.inf\n')
output.mkdir(parents=True, exist_ok=True)
(output / 'GunyahBoot.dsc').write_text(text)
print(f'{output / "GunyahBoot.dsc"}: {len(text)} bytes')
