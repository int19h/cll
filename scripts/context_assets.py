#!/usr/bin/env python3
"""Stage the exact source fonts and referenced images for ConTeXt."""
import json
from pathlib import Path
import shutil
import sys

from PIL import Image


def stage(root, output):
    report = json.loads((output / 'conversion.json').read_text())
    shutil.copytree(root / 'assets/fonts', output / 'assets/fonts', dirs_exist_ok=True)
    for relative in report['images']:
        source = (root / relative).resolve()
        if not source.is_relative_to((root / 'assets/media').resolve()):
            raise ValueError(f'Image outside assets/media: {relative}')
        target = output / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        if source.suffix.lower() == '.gif':
            with Image.open(source) as image:
                image.convert('RGBA').save(str(target) + '.png', dpi=(96, 96))
        elif source.suffix.lower() == '.png':
            # HTML uses 96 pixels per inch, regardless of the PNG's print DPI.
            with Image.open(source) as image:
                image.save(target, dpi=(96, 96))
        else:
            shutil.copyfile(source, target)


if __name__ == '__main__':
    if len(sys.argv) != 3:
        sys.exit('Usage: context_assets.py REPOSITORY OUTPUT_DIRECTORY')
    stage(Path(sys.argv[1]), Path(sys.argv[2]))
