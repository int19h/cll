#!/usr/bin/env python3
"""Exercise archive recipes and dependency scheduling without book renderers."""
from pathlib import Path
import os
import shutil
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

    def make(self, *args, makefile=None, old=None, env=None):
        if old is None:
            old = [self.build / 'cll_processed_xhtml.xml', self.build / 'build-metadata']
        command = ['make', '--no-print-directory', '-f',
                   str(makefile or SOURCE / 'scripts/Makefile'),
                   f'builddir={self.build}', 'chapters=chapters/01.xml']
        for path in old:
            command.extend(['-o', str(path)])
        command.extend(map(str, args))
        result = subprocess.run(
            command, cwd=SOURCE, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            env=env)
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
	touch {self.build}/xhtml_{kind}_chunks/sw.js $@
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
                self.assertFalse((directory / 'sw.js').exists())
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
        (html / 'sw.js').touch()
        for name in ('pdf.done', 'xhtml_no_chunks.done'):
            (self.build / name).touch()
        for name in ('first', 'second'):
            archive = self.root / name
            self.make('-o', 'clean', 'coverage', f'covcopydir={archive}')
            self.assertEqual((archive / 'cll.pdf').read_text(), 'coverage PDF')
            self.assertEqual((archive / 'cll-xhtml_no_chunks/index.html').read_text(), 'coverage HTML')
            self.assertFalse((archive / 'cll-xhtml_no_chunks/sw.js').exists())

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
            ('scripts/xhtml_postprocess_offline.rb', xhtml_done, 'xhtml_postprocess_offline.rb', None),
            ('scripts/sw.template.js', xhtml_done, 'sw.template.js', None),
            ('assets/scripts/offline.js', xhtml_done, 'xhtml_chapter_chunks', None),
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

    def test_epub_depends_on_the_epubcheck_scripts(self):
        epub = self.build / 'cll.epub'
        html = self.build / 'epub-xhtml/index.html'
        self.touch_output(html)
        self.touch_output(epub)
        current = self.make('-n', epub)
        self.assertTrue(
            'Nothing to be done' in current or 'is up to date' in current, current)
        for script in ('scripts/run-epubcheck.sh', 'scripts/install-epubcheck.sh'):
            with self.subTest(script=script):
                output = self.make('-n', f'-W{script}', epub)
                self.assertIn('scripts/run-epubcheck.sh', output)
                self.assertNotIn('is up to date', output)

    def test_clean_keeps_the_epubcheck_install(self):
        # Make reads PWD from the environment, not from the process cwd.
        coverage = self.root / 'coverage/build'
        coverage.mkdir(parents=True)
        gone = coverage / 'gone.pdf'
        gone.write_text('gone')
        tool = self.build / 'tools/epubcheck'
        tool.mkdir(parents=True)
        jar = tool / 'epubcheck.jar'
        jar.write_text('jar')
        stamp = tool / '.sha256'
        stamp.write_text('abc\n')
        other = self.build / 'cll.epub'
        other.write_text('epub')
        outside = Path(tempfile.mkdtemp(prefix='cll-make-outside-'))
        self.addCleanup(lambda: shutil.rmtree(outside, ignore_errors=True))
        # The environment points PWD at a decoy checkout with its own build/.
        # Only the command-line PWD keeps clean inside the temporary root, so
        # this file is deleted if that argument is ever dropped.
        (outside / 'build').mkdir()
        (outside / 'coverage/build').mkdir(parents=True)
        survivor = outside / 'build/survivor.epub'
        survivor.write_text('keep')
        env = os.environ.copy()
        env['PWD'] = str(outside)
        self.make(f'PWD={self.root}', 'clean', env=env)
        self.assertEqual(jar.read_text(), 'jar')
        self.assertEqual(stamp.read_text(), 'abc\n')
        self.assertFalse(other.exists())
        self.assertFalse(gone.exists())
        self.assertEqual(survivor.read_text(), 'keep')

    def test_formatter_rebuilds_html_and_pdf_stays_unformatted(self):
        processed = self.build / 'cll_processed_xhtml.xml'
        targets = [
            (self.build / 'xhtml_no_chunks.done', False),
            (self.build / 'pdf.done', True),
            (self.build / 'weasyprint/cll_processed_xhtml_pdf.html', True),
            (self.build / 'epub-xhtml/index.html', False),
        ]
        self.touch_output(processed)
        for path, _none in targets:
            self.touch_output(path)
        for helper in ('scripts/html_format.rb', 'scripts/html_whitespace_guard.rb'):
            for target, unformatted in targets:
                with self.subTest(helper=helper, target=target.name):
                    current = self.make('-n', target)
                    self.assertTrue(
                        'Nothing to be done' in current or 'is up to date' in current, current)
                    stale = self.make('-n', f'-W{helper}', target)
                    self.assertIn('xhtml_postprocess_cleanup.sh', stale)
                    self.assertNotIn('Nothing to be done', stale)
                    self.assertNotIn('is up to date', stale)
                    if unformatted:
                        self.assertIn('CLL_HTML_FORMAT=none', stale)
                    else:
                        self.assertNotIn('CLL_HTML_FORMAT=none', stale)

    def test_offline_no_skips_the_generator(self):
        done = self.build / 'xhtml_no_chunks.done'
        self.touch_output(done)
        default = self.make('-n', '-Wscripts/xhtml_postprocess_offline.rb', done)
        self.assertIn('xhtml_postprocess_offline.rb', default)
        skipped = self.make('-n', '-Wscripts/xhtml_postprocess_offline.rb', 'offline=no', done)
        self.assertNotIn('xhtml_postprocess_offline.rb', skipped)
        self.assertIn('xhtml_postprocess_cleanup.sh', skipped)
        env = os.environ.copy()
        env['offline'] = 'no'
        from_env = self.make('-n', '-Wscripts/xhtml_postprocess_offline.rb', done, env=env)
        self.assertNotIn('xhtml_postprocess_offline.rb', from_env)
        self.assertIn('touch', from_env)


if __name__ == '__main__':
    unittest.main()
