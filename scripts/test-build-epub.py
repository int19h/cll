#!/usr/bin/env python3
"""Exercise the real ePub packager with a small book and print-only assets."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET
import zipfile

SOURCE = Path(__file__).resolve().parent.parent


class EpubAssets(unittest.TestCase):
    def test_reader_assets_survive_and_renderer_sources_do_not(self):
        with tempfile.TemporaryDirectory(prefix='cll-epub-') as temporary:
            root = Path(temporary)
            for relative in (
                '.env', 'scripts/build_epub.sh', 'scripts/epub_branding.rb',
                'epub/mimetype', 'epub/META-INF/container.xml',
                'epub/content.opf.s1', 'epub/content.opf.s2',
                'epub/content.opf.s3', 'epub/toc.xhtml.s1',
                'epub/toc.xhtml.s2', 'epub/cover.html',
            ):
                target = root / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(SOURCE / relative, target)
            build = root / 'build'
            xhtml = build / 'epub-xhtml'
            shutil.copytree(SOURCE / 'assets', xhtml / 'assets')
            # Use the same producer exclusions as scripts/Makefile's ePub target.
            for excluded in ('css', 'scripts', 'media/examples', 'media/vreji'):
                shutil.rmtree(xhtml / 'assets' / excluded, ignore_errors=True)
            (xhtml / 'final.css').write_text('body { color: black; }')
            (xhtml / 'index.html').write_text('''<html><head><title>Fixture</title></head><body>
<dl>
<dt>
<a href="chapter.html">Chapter</a>
</dt>
</dl>
</body></html>''')
            (xhtml / 'chapter.html').write_text('''<html><head><title>Chapter</title></head><body>
<h1 class="title"><a id="c1"/>Chapter</h1>
<p>Reader content.</p></body></html>''')
            (build / 'cll.xml').write_text('''<book xmlns="http://docbook.org/ns/docbook">
<info><releaseinfo>fixture-version</releaseinfo></info></book>''')

            def package():
                return subprocess.run(
                    ['bash', str(root / 'scripts/build_epub.sh'), str(root)],
                    cwd=root, text=True, stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                )

            result = package()
            self.assertEqual(result.returncode, 0, result.stdout)
            with zipfile.ZipFile(build / 'cll.epub') as archive:
                names = set(archive.namelist())
                self.assertIn('chapter.html', names)
                self.assertIn('assets/media/logo.png', names)
                self.assertEqual(archive.read('assets/media/logo.png'),
                                 (SOURCE / 'assets/media/logo.png').read_bytes())
                pictures = list((SOURCE / 'assets/media').glob('chapter-*.png'))
                self.assertEqual(len(pictures), 22)  # 21 pictures and the diagram
                for picture in pictures:
                    name = 'assets/media/' + picture.name
                    self.assertIn(name, names)
                    self.assertEqual(archive.read(name), picture.read_bytes())
                self.assertFalse(any(n.startswith('assets/media/chapter-')
                                     and n.endswith(('.gif', '.svg')) for n in names))
                self.assertFalse(any(n.startswith('assets/media/chapter-')
                                     and n.endswith('.svg.png')
                                     and n != 'assets/media/chapter-2-diagram.svg.png'
                                     for n in names))
                self.assertFalse(any(n.startswith('assets/context/') for n in names))
                manifest = ET.fromstring(archive.read('content.opf'))
                items = manifest.findall('{*}manifest/{*}item')
                self.assertTrue(any(i.get('href') == 'assets/media/logo.png' for i in items))
                self.assertFalse(any('context/' in i.get('href', '') for i in items))

            # Unknown reader assets must still fail instead of disappearing.
            (xhtml / 'assets/media/unknown.bin').write_bytes(b'unknown')
            result = package()
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('No type found for assets/media/unknown.bin', result.stdout)


if __name__ == '__main__':
    unittest.main()
