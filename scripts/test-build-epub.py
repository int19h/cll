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
            (xhtml / 'assets/media').mkdir(parents=True)
            (xhtml / 'assets/context').mkdir()
            (xhtml / 'assets/context/cll-layout.tex').write_text('renderer source')
            (xhtml / 'assets/media/fixture.png').write_bytes(b'fixture image')
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
                self.assertIn('assets/media/fixture.png', names)
                self.assertFalse(any(n.startswith('assets/context/') for n in names))
                manifest = ET.fromstring(archive.read('content.opf'))
                items = manifest.findall('{*}manifest/{*}item')
                self.assertTrue(any(i.get('href') == 'assets/media/fixture.png' for i in items))
                self.assertFalse(any('context/' in i.get('href', '') for i in items))

            # Unknown reader assets must still fail instead of disappearing.
            (xhtml / 'assets/media/unknown.bin').write_bytes(b'unknown')
            result = package()
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('No type found for assets/media/unknown.bin', result.stdout)


if __name__ == '__main__':
    unittest.main()
