#!/usr/bin/env python3
"""Exercise archive recipes and dependency scheduling without book renderers."""
from pathlib import Path
import os
import re
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
                   f'builddir={self.build}', 'ALLOW_OUTSIDE_BUILDDIR=yes',
                   'chapters=chapters/01.xml']
        for path in old:
            command.extend(['-o', str(path)])
        command.extend(map(str, args))
        if env is None:
            env = dict(os.environ, PWD=str(SOURCE))
        result = subprocess.run(
            command, cwd=SOURCE, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            env=env)
        self.assertEqual(result.returncode, 0, result.stdout)
        return result.stdout

    def fixture_page(self, kind):
        return (
            '<!DOCTYPE html>'
            '<html xmlns="http://www.w3.org/1999/xhtml" lang="en" xml:lang="en">'
            '<head><meta http-equiv="Content-Type" content="text/html; charset=utf-8" />'
            f'<title>{kind}</title></head><body><p>{kind} fixture</p></body></html>'
        )

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
	printf '%s' '{self.fixture_page(kind)}' > {self.build}/xhtml_{kind}_chunks/index.html
	touch {self.build}/xhtml_{kind}_chunks/sw.js $@
''' for kind in ('chapter', 'section', 'no'))+'''
html_check:
	@true
''')
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
                self.assertEqual((directory / 'index.html').read_text(), self.fixture_page(kind))
                self.assertFalse((directory / 'sw.js').exists())
            artifacts = [self.build / 'pdf.done', self.build / 'cll.epub'] + list(self.build.glob('*.done'))
            times = {str(p): p.stat().st_mtime_ns for p in artifacts}
            if previous is not None:
                self.assertEqual(times, previous, 'Archiving must not rerender current output')
            previous = times

    def test_html_check_names_stylesheets_from_a_fresh_folder(self):
        # A fresh output folder has no chunk files. The check target must
        # still expand the xhtml5 stylesheets. An empty -x is the failure.
        output = self.make('-n', 'html_check')
        self.assertIn('xml/docbook-xsl-1.78.1/xhtml5/docbook.xsl', output)
        self.assertIn('xml/docbook-xsl-1.78.1/xhtml5/chunk.xsl', output)
        self.assertNotRegex(output, r'-x\s+-o')
        self.assertIn('scripts/run-html-check.sh', output)

    def test_site_comparison_edit_selects_the_diff_driver(self):
        # pages commit 86ff2e46, scripts/build-site.sh line 225.
        makefile = self.root / 'Makefile'
        shutil.copy(SOURCE / 'scripts/Makefile', makefile)
        sed = subprocess.run(
            ['sed', '-i',
             r's|^\(xhtml_nochunks: xsl_file = \).*|\1xml/docbook2html_diff.xsl|',
             str(makefile)],
            text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        self.assertEqual(sed.returncode, 0, sed.stdout)
        text = makefile.read_text()
        self.assertIn('xhtml_nochunks: xsl_file = xml/docbook2html_diff.xsl\n', text)
        self.assertIsNotNone(re.search(
            r'^\$\(builddir\)/xhtml_no_chunks\.done: nochunks = -nochunks$',
            text, re.M))
        self.assertIsNone(re.search(
            r'^\$\(builddir\)/xhtml_no_chunks\.done: xsl_file =',
            text, re.M))
        output = self.make('-n', 'xhtml_nochunks', makefile=makefile)
        self.assertIn('-x xml/docbook2html_diff.xsl', output)
        self.assertNotIn('xhtml5/docbook.xsl', output)

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

    def test_bad_builddir_stops_before_any_recipe(self):
        # Parse-time guards (issue #271): no recipe line may print or run.
        for bad in ('', '/', str(self.root / 'elsewhere')):
            with self.subTest(builddir=bad):
                result = subprocess.run(
                    ['make', '--no-print-directory', '-f',
                     str(SOURCE / 'scripts/Makefile'),
                     f'builddir={bad}', 'chapters=chapters/01.xml',
                     'xhtml_nochunks'],
                    cwd=SOURCE, text=True, stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertIn('builddir', result.stdout)
                self.assertNotIn('scripts/merge.sh', result.stdout)
                self.assertNotIn('mkdir -p', result.stdout)
        for variable in ('copydir=/', 'covcopydir=/', 'epubnavdir=/tmp'):
            with self.subTest(variable=variable):
                result = subprocess.run(
                    ['make', '--no-print-directory', '-f',
                     str(SOURCE / 'scripts/Makefile'),
                     'builddir=build', variable,
                     'chapters=chapters/01.xml', 'xhtml_nochunks'],
                    cwd=SOURCE, text=True, stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertNotIn('scripts/merge.sh', result.stdout)

    def make_in_scratch_checkout(self, checkout, *args, env=None, builddir='build'):
        if env is None:
            env = dict(os.environ, PWD=str(checkout))
        return subprocess.run(
            ['make', '--no-print-directory', '-f',
             str(SOURCE / 'scripts/Makefile'), f'PWD={checkout}',
             f'builddir={builddir}', 'chapters=chapters/01.xml', *args],
            cwd=checkout, text=True, stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, env=env)

    def test_linked_build_folder_cannot_reach_the_checkout(self):
        # Round 2 (Astra R1): the guard resolves links before clean walks
        # the build folder, so build -> ., build -> .. and a link to the
        # home folder all stop at parse time and the source file survives.
        for name in ('dot', 'dotdot', 'home'):
            with self.subTest(link=name):
                scratch = self.root / f'link-{name}'
                checkout = scratch / 'co'
                (checkout / 'chapters').mkdir(parents=True)
                source = checkout / 'chapters/source.xml'
                source.write_text('source')
                env = None
                if name == 'dot':
                    target = '.'
                elif name == 'dotdot':
                    target = '..'
                else:
                    fake_home = scratch / 'home'
                    fake_home.mkdir()
                    target = str(fake_home)
                    env = dict(os.environ, HOME=str(fake_home))
                (checkout / 'build').symlink_to(target, target_is_directory=True)
                result = self.make_in_scratch_checkout(checkout, 'clean', env=env)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertEqual(source.read_text(), 'source')

    def test_linked_build_folder_to_a_separate_folder_still_works(self):
        # The supported setup: build/ links to a separate folder, as on
        # /build. clean empties that folder and leaves the checkout alone.
        checkout = self.root / 'linked-co'
        (checkout / 'chapters').mkdir(parents=True)
        source = checkout / 'chapters/source.xml'
        source.write_text('source')
        real_build = self.root / 'linked-real-build'
        real_build.mkdir()
        junk = real_build / 'junk.pdf'
        junk.write_text('junk')
        dictionary = real_build / 'jbovlaste_fixture.xml'
        dictionary.write_text('keep')
        (checkout / 'build').symlink_to(real_build, target_is_directory=True)
        result = self.make_in_scratch_checkout(checkout, 'clean')
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertFalse(junk.exists())
        self.assertEqual(dictionary.read_text(), 'keep')
        self.assertEqual(source.read_text(), 'source')

    def scratch_checkout(self, name):
        checkout = self.root / name
        (checkout / 'chapters').mkdir(parents=True)
        source = checkout / 'chapters/source.xml'
        source.write_text('source')
        return checkout, source

    def test_build_link_into_the_source_tree_is_refused(self):
        # Round 3 (both reviewers, REAL): build -> chapters, and the same
        # through coverage/build, stop before clean deletes a source.
        checkout, source = self.scratch_checkout('link-inside-co')
        (checkout / 'build').symlink_to('chapters', target_is_directory=True)
        result = self.make_in_scratch_checkout(checkout, 'clean')
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn('points into the source tree', result.stdout)
        self.assertEqual(source.read_text(), 'source')

        checkout, source = self.scratch_checkout('covlink-inside-co')
        (checkout / 'build').mkdir()
        (checkout / 'coverage').mkdir()
        (checkout / 'coverage/build').symlink_to(
            '../chapters', target_is_directory=True)
        result = self.make_in_scratch_checkout(checkout, 'clean')
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn('points into the source tree', result.stdout)
        self.assertEqual(source.read_text(), 'source')

    def test_pwd_that_disagrees_with_the_working_folder_stops(self):
        checkout, source = self.scratch_checkout('pwd-co')
        (checkout / 'build').mkdir()
        decoy = self.root / 'pwd-decoy'
        (decoy / 'build').mkdir(parents=True)
        marker = decoy / 'build/marker.epub'
        marker.write_text('keep')
        env = dict(os.environ, PWD=str(decoy))
        result = subprocess.run(
            ['make', '--no-print-directory', '-f',
             str(SOURCE / 'scripts/Makefile'), 'builddir=build',
             'chapters=chapters/01.xml', 'clean'],
            cwd=checkout, text=True, stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, env=env)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn('does not match the working folder', result.stdout)
        self.assertEqual(marker.read_text(), 'keep')
        self.assertEqual(source.read_text(), 'source')

    def test_resolved_build_folder_with_space_or_glob_is_refused(self):
        # Round 3 (Astra L2): a link target with a space or a wildcard
        # must not split or expand in the cleanup recipes.
        checkout, source = self.scratch_checkout('space-co')
        (checkout / 'coverage/build').mkdir(parents=True)
        external = self.root / 'external chapters'
        external.mkdir()
        junk = external / 'junk.pdf'
        junk.write_text('junk')
        (checkout / 'build').symlink_to(external, target_is_directory=True)
        result = self.make_in_scratch_checkout(
            checkout, 'clean', builddir='coverage/build')
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertEqual(source.read_text(), 'source')
        self.assertEqual(junk.read_text(), 'junk')

        checkout, source = self.scratch_checkout('glob-co')
        (checkout / 'coverage/build').mkdir(parents=True)
        starred = self.root / 'build*'
        starred.mkdir()
        secret = self.root / 'build-secret'
        secret.mkdir()
        marker = secret / 'marker.pdf'
        marker.write_text('keep')
        (checkout / 'build').symlink_to(starred, target_is_directory=True)
        result = self.make_in_scratch_checkout(
            checkout, 'clean', builddir='coverage/build')
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertEqual(source.read_text(), 'source')
        self.assertEqual(marker.read_text(), 'keep')

    def test_guard_cannot_be_split_or_overridden(self):
        # Round 2 (Opus L1/L2, Astra L3): two-word folders and command-line
        # assignments to the guard's own variables must not get through.
        cases = [
            ['make', '--no-print-directory', '-f', str(SOURCE / 'scripts/Makefile'),
             'builddir=build /etc', 'chapters=chapters/01.xml', 'clean'],
            ['make', '--no-print-directory', '-f', str(SOURCE / 'scripts/Makefile'),
             'builddir=build', 'copydir=/a /b', 'chapters=chapters/01.xml', 'clean'],
            ['make', '--no-print-directory', '-f', str(SOURCE / 'scripts/Makefile'),
             'builddir=/etc', '_builddir_r=build', 'chapters=chapters/01.xml', 'clean'],
            ['make', '--no-print-directory', '-f', str(SOURCE / 'scripts/Makefile'),
             'builddir=/etc', '_defbuild_r=/etc', '_reject_outside=yes',
             'chapters=chapters/01.xml', 'clean'],
            ['make', '--no-print-directory', '-f', str(SOURCE / 'scripts/Makefile'),
             f'builddir={SOURCE}', 'ALLOW_OUTSIDE_BUILDDIR=yes',
             '_checkout_r=/nonexistent', '_home_r=/nonexistent',
             '_reject_forbidden=yes', 'chapters=chapters/01.xml', 'clean'],
            ['make', '--no-print-directory', '-f', str(SOURCE / 'scripts/Makefile'),
             'builddir=/etc', '_clean_dirs=build', 'chapters=chapters/01.xml', 'clean'],
        ]
        for command in cases:
            with self.subTest(command=command[4:-2]):
                result = subprocess.run(
                    command, cwd=SOURCE, text=True, stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    env=dict(os.environ, PWD=str(SOURCE)))
                self.assertNotEqual(result.returncode, 0, result.stdout)

    def test_mobi_target_is_removed(self):
        result = subprocess.run(
            ['make', '--no-print-directory', '-f', str(SOURCE / 'scripts/Makefile'),
             f'builddir={self.build}', 'ALLOW_OUTSIDE_BUILDDIR=yes',
             'chapters=chapters/01.xml', 'mobi'],
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
            ('xml/docbook2html_config_headings.xsl', pdf_done, 'docbook2html_config_prince.xsl', None),
            ('scripts/header.xml', pdf_done, 'xml_prince_postprocess.rb', None),
            ('assets/fonts/crisa-regular.otf', xhtml_done, 'xhtml_chapter_chunks', None),
            ('assets/media/logo.png', xhtml_done, 'xhtml_chapter_chunks', None),
            (mp3_rel, xhtml_done, 'xhtml_chapter_chunks', None),
            ('xml/docbook2html_config_common.xsl', xhtml_done, 'docbook2html_config_chapter_chunks.xsl', None),
            ('xml/docbook2html_config_headings.xsl', xhtml_done, 'docbook2html_config_chapter_chunks.xsl', None),
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
        # The checkout is make's working folder (CURDIR). Run in the
        # scratch root; the decoy tree outside it is never walked.
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
        work = self.build / 'weasyprint-work/cll-weasyprint.html'
        work.parent.mkdir(parents=True)
        work.write_text('working copy')
        outside_temporary = tempfile.TemporaryDirectory(prefix='cll-make-outside-')
        self.addCleanup(outside_temporary.cleanup)
        outside = Path(outside_temporary.name)
        (outside / 'build').mkdir()
        (outside / 'coverage/build').mkdir(parents=True)
        survivor = outside / 'build/survivor.epub'
        survivor.write_text('keep')
        result = self.make_in_scratch_checkout(self.root, 'clean')
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(jar.read_text(), 'jar')
        self.assertEqual(stamp.read_text(), 'abc\n')
        self.assertFalse(other.exists())
        self.assertFalse(work.exists())
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
        for helper in ('scripts/html_format.rb', 'scripts/html_whitespace_guard.rb', 'scripts/html_stylesheet_scan.rb', 'scripts/html_table_spans.rb'):
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

    @unittest.skipUnless(
        shutil.which('ruby') and subprocess.run(
            ['ruby', '-rnokogiri', '-e', ''], stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL).returncode == 0,
        'the real cleanup recipe needs ruby with nokogiri')
    def test_weasyprint_recipe_runs_twice_in_one_folder(self):
        # Run the processed-XHTML recipe twice in one build folder. Only
        # xmlto is stubbed; the cleanup and postprocess are the real ones.
        # Between the runs, leave the file the renderer used to write into
        # build/weasyprint/: HTML serialization, not XML. The cleanup parses
        # every XHTML-namespace file in that folder as XML, so on the old
        # layout the second run died on the leftover.
        stub = self.root / 'bin'
        stub.mkdir()
        xmlto = stub / 'xmlto'
        page = self.fixture_page('weasyprint')
        xmlto.write_text(f'''#!/usr/bin/env python3
import sys
from pathlib import Path
args = sys.argv[1:]
out = Path(args[args.index('-o') + 1])
out.mkdir(parents=True, exist_ok=True)
source = Path(args[-1])
(out / (source.stem + '.html')).write_text({page!r})
print('xmlto fixture')
''')
        xmlto.chmod(0o755)
        env = os.environ.copy()
        env['PATH'] = f'{stub}:{env["PATH"]}'
        env['PWD'] = str(SOURCE)
        self.touch_output(self.build / 'cll_processed_xhtml.xml')
        target = self.build / 'weasyprint/cll_processed_xhtml_pdf.html'
        self.make(target, env=env)
        self.assertIn('weasyprint fixture', target.read_text())
        leftover = self.build / 'weasyprint/cll-weasyprint.html'
        leftover.write_text(
            '<!doctype html>\n'
            '<html xmlns="http://www.w3.org/1999/xhtml"><head>'
            '<meta charset="utf-8"></head><body><p>one<br>two</p>'
            '</body></html>')
        self.make('-Wassets/css/master.css', target, env=env)
        self.assertIn('weasyprint fixture', target.read_text())
        self.assertFalse(leftover.exists())

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
