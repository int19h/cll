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

    def make(self, *args, makefile=None, old=None):
        if old is None:
            old = [self.build / 'cll_processed_xhtml.xml', self.build / 'build-metadata']
        command = ['make', '--no-print-directory', '-f',
                   str(makefile or SOURCE / 'scripts/Makefile'),
                   f'builddir={self.build}', 'chapters=chapters/01.xml']
        for path in old:
            command.extend(['-o', str(path)])
        command.extend(map(str, args))
        result = subprocess.run(
            command, cwd=SOURCE, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        self.assertEqual(result.returncode, 0, result.stdout)
        return result.stdout

    def touch_output(self, path):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.touch()

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

    def test_mobi_target_is_removed(self):
        result = subprocess.run(
            ['make', '--no-print-directory', '-f', str(SOURCE / 'scripts/Makefile'),
             f'builddir={self.build}', 'chapters=chapters/01.xml', 'mobi'],
            cwd=SOURCE, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("No rule to make target 'mobi'", result.stdout)

    def test_changed_inputs_rebuild_and_other_files_do_not(self):
        cll_xml = self.build / 'cll.xml'
        processed = self.build / 'cll_processed_xhtml.xml'
        pdf_done = self.build / 'pdf.done'
        xhtml_done = self.build / 'xhtml_chapter_chunks.done'
        epub_html = self.build / 'epub-xhtml/index.html'
        for path in (cll_xml, processed, pdf_done, xhtml_done, epub_html):
            self.touch_output(path)
        mp3 = next((SOURCE / 'assets/media/vreji').glob('*.mp3'))
        mp3_rel = mp3.relative_to(SOURCE).as_posix()
        upstream = [self.build / 'cll.xml', self.build / 'build-metadata']
        cases = [
            ('dictionary/all_words.xml', cll_xml, 'scripts/merge.sh', None),
            ('scripts/util.rb', cll_xml, 'scripts/merge.sh', None),
            ('assets/scripts/sance-next.js', cll_xml, 'regenerator', None),
            ('scripts/header.xml', cll_xml, 'scripts/merge.sh', None),
            ('dtd/docbook-5.0.dtd', processed, 'scripts/xml_preprocess.rb', upstream),
            ('scripts/util.rb', processed, 'scripts/xml_preprocess.rb', upstream),
            ('assets/fonts/crisa-regular.otf', pdf_done, 'prince', None),
            ('assets/media/logo.png', pdf_done, 'prince', None),
            ('scripts/prince_shave_index.js', pdf_done, 'prince', None),
            ('scripts/xml_prince_postprocess.rb', pdf_done, 'xml_prince_postprocess.rb', None),
            ('xml/docbook2html_config_common.xsl', pdf_done, 'docbook2html_config_prince.xsl', None),
            ('scripts/header.xml', pdf_done, 'xml_prince_postprocess.rb', None),
            ('assets/fonts/crisa-regular.otf', xhtml_done, 'xhtml_chapter_chunks', None),
            ('assets/media/logo.png', xhtml_done, 'xhtml_chapter_chunks', None),
            (mp3_rel, xhtml_done, 'xhtml_chapter_chunks', None),
            ('xml/docbook2html_config_common.xsl', xhtml_done, 'docbook2html_config_chapter_chunks.xsl', None),
            ('assets/fonts/crisa-regular.otf', epub_html, 'epub-xhtml', None),
            ('assets/media/logo.png', epub_html, 'epub-xhtml', None),
        ]
        for changed, target, needle, old in cases:
            with self.subTest(changed=changed, target=target.name):
                output = self.make('-n', f'-W{changed}', target, old=old)
                self.assertIn(needle, output)
                self.assertNotIn('Nothing to be done', output)
                self.assertNotIn('is up to date', output)
        for changed, target in (
                ('README.md', pdf_done),
                (mp3_rel, pdf_done),
                ('assets/media/examples', pdf_done),
                ('README.md', cll_xml)):
            with self.subTest(unchanged=changed, target=target.name):
                output = self.make('-n', f'-W{changed}', target)
                self.assertTrue(
                    'Nothing to be done' in output or 'is up to date' in output,
                    output)


if __name__ == '__main__':
    unittest.main()
