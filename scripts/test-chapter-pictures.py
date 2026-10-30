#!/usr/bin/env python3
"""Keep chapter artwork references and shipped PNGs consistent."""
from pathlib import Path
import re
import struct
import unittest

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

    def test_cropped_picture_limits(self):
        css = (ROOT / 'assets/css/master.css').read_text()
        # These drawings had large margins. A 200px crop would enlarge them.
        for name, limit in [('letterals', 85), ('attitudinals', 128),
                            ('sumti-tcita', 136), ('phonology', 176)]:
            self.assertRegex(css, re.escape(f'img[src$="/chapter-{name}.png"]')
                             + r'\s*\{\s*max-height:\s*' + str(limit) + r'px;')


if __name__ == '__main__':
    unittest.main()
