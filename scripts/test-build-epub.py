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
                'epub/content.opf.s3', 'epub/cover.html',
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
<dl class="toc">
<dt><span class="chapter"><a href="chapter.html">Chapter</a></span></dt>
</dl>
</body></html>''')
            (xhtml / 'chapter.html').write_text('''<html><head><title>Chapter</title></head><body>
<h1 class="title"><a id="chapter"/>Chapter <a id="c1"/></h1><p><a id="indexterm"/>Reader text.</p>
<p>Reader content.</p><dl><dt>First</dt><dd>One</dd></dl><dl><dt>Second</dt><dd>Two</dd></dl></body></html>''')
            (build / 'cll.xml').write_text('''<book xmlns="http://docbook.org/ns/docbook">
<info><releaseinfo>fixture-version</releaseinfo></info></book>''')
            # The stylesheets write these. The packager copies the navigation
            # document and builds the spine from the page list (issue #208).
            nav = build / 'epub-nav'
            nav.mkdir()
            toc_bytes = b'''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
<head><title>Fixture</title></head>
<body><nav id="toc" epub:type="toc"><ol>
<li><a href="index.html">Contents</a></li>
<li><a href="chapter.html">Chapter</a></li>
</ol></nav></body>
</html>
'''
            (nav / 'toc.xhtml').write_bytes(toc_bytes)
            (nav / 'spine.txt').write_text('index.html\nchapter.html\n')

            def package():
                return subprocess.run(
                    ['bash', str(root / 'scripts/build_epub.sh'), str(root)],
                    cwd=root, text=True, stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                )

            result = package()
            self.assertEqual(result.returncode, 0, result.stdout)
            with zipfile.ZipFile(build / 'cll.epub') as archive:
                chapter = ET.fromstring(archive.read('chapter.html'))
                self.assertEqual(len(chapter.findall('.//{*}ul')), 2)
                self.assertEqual(archive.read('toc.xhtml'), toc_bytes)
                manifest = ET.fromstring(archive.read('content.opf'))
                refs = [item.get('idref') for item in manifest.findall('{*}spine/{*}itemref')]
                self.assertEqual(refs, ['cover', 'indexhtml', 'chapterhtml'])
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
                items = manifest.findall('{*}manifest/{*}item')
                self.assertTrue(any(i.get('href') == 'assets/media/logo.png' for i in items))
                self.assertFalse(any('context/' in i.get('href', '') for i in items))
                self.assertFalse(any(name == 'sw.js' or name.endswith('/sw.js')
                                     or name == 'offline.js' or name.endswith('/offline.js')
                                     for name in names))

            # A page named by the stylesheet list must be in the package.
            (nav / 'spine.txt').write_text('index.html\nchapter.html\nmissing.html\n')
            result = package()
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('Spine file missing.html is not in the package', result.stdout)

            # The last spine line counts even when the file has no final newline.
            (nav / 'spine.txt').write_text('index.html\nchapter.html')
            result = package()
            self.assertEqual(result.returncode, 0, result.stdout)
            with zipfile.ZipFile(build / 'cll.epub') as archive:
                manifest = ET.fromstring(archive.read('content.opf'))
                refs = [item.get('idref') for item in manifest.findall('{*}spine/{*}itemref')]
                self.assertEqual(refs, ['cover', 'indexhtml', 'chapterhtml'])

            (nav / 'toc.xhtml').unlink()
            result = package()
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('toc.xhtml is missing', result.stdout)
            (nav / 'toc.xhtml').write_bytes(toc_bytes)

            (nav / 'spine.txt').unlink()
            result = package()
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('spine.txt is missing', result.stdout)
            (nav / 'spine.txt').write_text('index.html\nchapter.html\n')

            # Unknown reader assets must still fail instead of disappearing.
            (xhtml / 'assets/media/unknown.bin').write_bytes(b'unknown')
            result = package()
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('No type found for assets/media/unknown.bin', result.stdout)


if __name__ == '__main__':
    unittest.main()
