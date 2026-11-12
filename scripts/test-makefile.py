#!/usr/bin/env python3
"""Exercise archive recipes and dependency scheduling without book renderers."""
from pathlib import Path
import os
import subprocess
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parent.parent


class MakefileTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='cll-make-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.build = self.root / 'build'
        self.build.mkdir()

    def make(self, *args, makefile=None):
        result = subprocess.run(
            ['make', '--no-print-directory', '-f', str(makefile or SOURCE / 'scripts/Makefile'),
             f'builddir={self.build}', 'chapters=chapters/01.xml',
             '-o', str(self.build / 'cll_processed_xhtml.xml'),
             '-o', str(self.build / 'build-metadata'), *map(str, args)],
            cwd=SOURCE, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        self.assertEqual(result.returncode, 0, result.stdout)
        return result.stdout

    def test_default_archive_fresh_and_unchanged(self):
        # Replace only the expensive producers. Execute the production archive
        # recipes both after producing artifacts and with current artifacts.
        fixture = self.root / 'fixture.mk'
        fixture.write_text(f'''include {SOURCE}/scripts/Makefile
{self.build}/pdf.done:
	printf 'PDF fixture' > {self.build}/cll.pdf
	touch $@
{self.build}/cll.epub:
	printf 'EPUB fixture' > $@
'''+''.join(f'''{self.build}/xhtml_{kind}_chunks.done:
	mkdir -p {self.build}/xhtml_{kind}_chunks
	printf '{kind} fixture' > {self.build}/xhtml_{kind}_chunks/index.html
	touch {self.build}/xhtml_{kind}_chunks/cll.appcache $@
''' for kind in ('chapter', 'section', 'no')))
        previous = None
        for name in ('fresh', 'unchanged'):
            archive = self.root / name
            output = self.make('-o', self.build / 'epub-xhtml/index.html',
                               f'copydir={archive}', makefile=fixture)
            self.assertNotIn('cll.mobi', output)
            self.assertEqual((archive / 'cll.pdf').read_text(), 'PDF fixture')
            self.assertEqual((archive / 'cll.epub').read_text(), 'EPUB fixture')
            for kind in ('chapter', 'section', 'no'):
                directory = archive / f'cll-xhtml_{kind}_chunks'
                self.assertEqual((directory / 'index.html').read_text(), f'{kind} fixture')
                self.assertFalse((directory / 'cll.appcache').exists())
            artifacts = [self.build / 'pdf.done', self.build / 'cll.epub'] + list(self.build.glob('*.done'))
            times = {str(p): p.stat().st_mtime_ns for p in artifacts}
            if previous is not None:
                self.assertEqual(times, previous, 'Archiving must not rerender current output')
            previous = times

    def test_coverage_archive_unchanged(self):
        (self.build / 'cll.pdf').write_text('coverage PDF')
        html = self.build / 'xhtml_no_chunks'
        html.mkdir()
        (html / 'index.html').write_text('coverage HTML')
        (html / 'cll.appcache').touch()
        for name in ('pdf.done', 'xhtml_no_chunks.done'):
            (self.build / name).touch()
        for name in ('first', 'second'):
            archive = self.root / name
            self.make('-o', 'clean', 'coverage', f'covcopydir={archive}')
            self.assertEqual((archive / 'cll.pdf').read_text(), 'coverage PDF')
            self.assertEqual((archive / 'cll-xhtml_no_chunks/index.html').read_text(), 'coverage HTML')
            self.assertFalse((archive / 'cll-xhtml_no_chunks/cll.appcache').exists())


if __name__ == '__main__':
    unittest.main()
