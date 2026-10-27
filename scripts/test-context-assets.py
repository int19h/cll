#!/usr/bin/env python3
import json
from pathlib import Path
import tempfile
import unittest

from PIL import Image
from context_assets import stage


class ContextAssetsTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / 'source'
        self.output = Path(self.temp.name) / 'output'
        (self.root / 'assets/fonts').mkdir(parents=True)
        (self.root / 'assets/media').mkdir()
        self.output.mkdir()

    def prepare(self, images):
        (self.output / 'conversion.json').write_text(json.dumps({'images': images}))
        stage(self.root, self.output)

    def test_png_keeps_pixels_and_alpha_but_uses_css_resolution(self):
        source = self.root / 'assets/media/test.png'
        image = Image.new('RGBA', (2, 1), (24, 48, 96, 128))
        image.save(source, dpi=(300, 300))
        original = source.read_bytes()
        self.prepare(['assets/media/test.png'])
        with Image.open(self.output / 'assets/media/test.png') as result:
            self.assertEqual(result.tobytes(), image.tobytes())
            self.assertEqual(result.size, image.size)
            self.assertAlmostEqual(result.info['dpi'][0], 96, delta=.1)
        self.assertEqual(source.read_bytes(), original)

    def test_gif_becomes_png_with_transparency(self):
        source = self.root / 'assets/media/test.gif'
        image = Image.new('RGBA', (2, 1), (0, 0, 0, 0))
        image.putpixel((1, 0), (255, 0, 0, 255))
        image.save(source)
        self.prepare(['assets/media/test.gif'])
        with Image.open(self.output / 'assets/media/test.gif.png') as result:
            self.assertEqual(result.convert('RGBA').tobytes(), image.tobytes())
            self.assertAlmostEqual(result.info['dpi'][0], 96, delta=.1)

    def test_image_paths_cannot_leave_the_media_directory(self):
        with self.assertRaises(ValueError):
            self.prepare(['assets/media/../../outside.png'])


if __name__ == '__main__':
    unittest.main()
