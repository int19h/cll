#!/usr/bin/env python3
"""Keep chapter artwork references and shipped PNGs consistent."""
from pathlib import Path
import re
import struct
import unittest

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent


class ChapterPictures(unittest.TestCase):
    def test_chapter_artwork(self):
        referenced = set()
        for number in range(1, 22):
            source = (ROOT / 'chapters' / f'{number:02}.xml').read_text()
            picture = re.search(r'<mediaobject xml:id="chapter-[^"]+-picture">(.*?)</mediaobject>', source, re.S)
            self.assertIsNotNone(picture, f'chapter {number}')
            name = re.search(r'fileref="([^"]+)"', picture.group(1)).group(1)
            self.assertRegex(name, r'^assets/media/chapter-[a-z-]+\.png$')
            referenced.add(name)
            data = (ROOT / name).read_bytes()
            self.assertEqual(data[:8], b'\x89PNG\r\n\x1a\n')
            width, height, depth, color = struct.unpack('>IIBB', data[16:26])
            self.assertGreater(width, 650)
            self.assertGreater(height, 500)
            self.assertEqual((depth, color), (8, 6), name)
        self.assertEqual(len(referenced), 21)
        shipped = {str(p.relative_to(ROOT)) for p in (ROOT / 'assets/media').glob('chapter-*')}
        self.assertEqual(shipped, referenced | {'assets/media/chapter-2-diagram.svg.png'})
        self.assertIn('fileref="assets/media/chapter-2-diagram.svg.png"',
                      (ROOT / 'chapters/02.xml').read_text())

    def test_diagram_resolution_and_size(self):
        data = (ROOT / 'assets/media/chapter-2-diagram.svg.png').read_bytes()
        self.assertEqual(struct.unpack('>IIBB', data[16:26]), (1200, 576, 8, 6))
        css = (ROOT / 'assets/css/master.css').read_text()
        self.assertRegex(css, re.escape('img[src$="/chapter-2-diagram.svg.png"]')
                         + r'\s*\{\s*width:\s*299\.625px;')

    def test_diagram_padding(self):
        with Image.open(ROOT / 'assets/media/chapter-2-diagram.svg.png') as image:
            # Ignore nearly transparent antialiasing at the drawing's edges.
            bounds = image.getchannel('A').point(lambda alpha: 255 if alpha >= 32 else 0).getbbox()
            self.assertIsNotNone(bounds)
            top, bottom = bounds[1], image.height - bounds[3]
            self.assertGreater(top, 0)
            self.assertLessEqual(abs(top - bottom), 1, (top, bottom))

    def test_shared_picture_limits(self):
        css = (ROOT / 'assets/css/master.css').read_text()
        shared = re.search(r'^img\s*\{([^}]+)\}', css, re.M).group(1)
        self.assertRegex(shared, r'max-width:\s*60%;')
        self.assertRegex(shared, r'max-height:\s*350px;')
        overrides = re.findall(r'img\[src\$="/chapter-[^"]+"\]\s*\{([^}]+)\}', css)
        self.assertTrue(all('max-height' not in rule for rule in overrides))


if __name__ == '__main__':
    unittest.main()
