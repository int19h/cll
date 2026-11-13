#!/usr/bin/env python3
"""EPUBCheck 5.4.0 is pinned, and an error stops the ePub check."""
from pathlib import Path
import os
import shutil
import stat
import subprocess
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
INSTALLER = ROOT / 'scripts/install-epubcheck.sh'
RUNNER = ROOT / 'scripts/run-epubcheck.sh'
PINNED_SHA256 = '33350c61038e71dfb3d45a76aed04bf5481e6d5500cb780f6e98db8bbd15a28c'
RELEASE_URL = 'https://github.com/w3c/epubcheck/releases/download/v5.4.0/epubcheck-5.4.0.zip'


def write_executable(path, text):
    path.write_text(text)
    path.chmod(path.stat().st_mode | stat.S_IEXEC)


def zip_archive(path, files):
    with zipfile.ZipFile(path, 'w') as archive:
        for name, data in files.items():
            archive.writestr(name, data)


def minimal_epub(path, extra_files=None, extra_manifest='', extra_spine=''):
    files = {
        'META-INF/container.xml': '''<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
''',
        'nav.xhtml': '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="en">
<head><title>Nav</title></head>
<body><nav epub:type="toc"><ol><li><a href="chap.xhtml">Chapter</a></li></ol></nav></body>
</html>
''',
        'chap.xhtml': '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" lang="en">
<head><title>Chapter</title></head>
<body><h1>Chapter</h1><p>Text.</p></body></html>
''',
        'content.opf': f'''<?xml version="1.0" encoding="UTF-8"?>
<package version="3.0" unique-identifier="uid" xmlns="http://www.idpf.org/2007/opf">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="uid">urn:test:fixture</dc:identifier>
    <dc:title>Fixture</dc:title>
    <dc:language>en</dc:language>
    <meta property="dcterms:modified">2026-11-12T00:00:00Z</meta>
  </metadata>
  <manifest>
    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
    <item id="chap" href="chap.xhtml" media-type="application/xhtml+xml"/>
    {extra_manifest}
  </manifest>
  <spine>
    <itemref idref="chap"/>
    {extra_spine}
  </spine>
</package>
''',
    }
    if extra_files:
        files.update(extra_files)
    with zipfile.ZipFile(path, 'w') as archive:
        info = zipfile.ZipInfo('mimetype')
        info.compress_type = zipfile.ZIP_STORED
        archive.writestr(info, 'application/epub+zip')
        for name, data in files.items():
            archive.writestr(name, data)


class EpubCheckTests(unittest.TestCase):
    def test_pin_and_recipe(self):
        installer = INSTALLER.read_text()
        self.assertIn(RELEASE_URL.replace('v5.4.0/epubcheck-5.4.0.zip', 'v${version}/epubcheck-${version}.zip'), installer)
        self.assertIn('version=5.4.0', installer)
        self.assertIn(PINNED_SHA256, installer)
        self.assertLess(installer.index('sha256sum'), installer.index('unzip'))
        self.assertNotIn('--failonwarnings', installer)
        runner = RUNNER.read_text()
        self.assertNotIn('--failonwarnings', runner)
        self.assertIn('exec java -jar "$jar" "$epub"', runner)
        makefile = (ROOT / 'scripts/Makefile').read_text()
        self.assertIn('scripts/run-epubcheck.sh $(builddir)/cll.tmp.epub', makefile)
        self.assertNotIn('epubcheck-4.0.1', makefile)
        self.assertNotIn("should have the extension '.xhtml'", makefile)
        dockerfile = (ROOT / 'Dockerfile').read_text()
        self.assertIn('bash /usr/local/src/install-epubcheck.sh /usr/local/share/epubcheck', dockerfile)
        self.assertIn('ENV EPUBCHECK_JAR=/usr/local/share/epubcheck/epubcheck.jar', dockerfile)
        selected = (ROOT / 'scripts/build-selected-formats.sh').read_text()
        self.assertIn('./scripts/install-epubcheck.sh build/tools/epubcheck', selected)
        self.assertFalse((ROOT / 'epub/epubcheck-4.0.1').exists())

    def test_bad_archive_is_rejected_before_extraction(self):
        with tempfile.TemporaryDirectory(prefix='cll-epubcheck-') as temporary:
            temporary = Path(temporary)
            archive = temporary / 'bad.zip'
            zip_archive(archive, {'epubcheck-5.4.0/LEAKED.txt': 'extracted too early'})
            destination = temporary / 'dest'
            result = subprocess.run(
                ['bash', str(INSTALLER), str(destination)],
                capture_output=True, text=True,
                env=dict(os.environ, EPUBCHECK_ARCHIVE=str(archive)))
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('pinned SHA-256', result.stderr)
            self.assertFalse((destination / 'epubcheck.jar').exists())
            self.assertFalse((destination / 'LEAKED.txt').exists())
            self.assertFalse(any(destination.rglob('LEAKED.txt')))

    def test_matching_hash_extracts_and_a_second_run_skips_the_download(self):
        with tempfile.TemporaryDirectory(prefix='cll-epubcheck-') as temporary:
            temporary = Path(temporary)
            archive = temporary / 'good.zip'
            zip_archive(archive, {
                'epubcheck-5.4.0/epubcheck.jar': 'fixture jar',
                'epubcheck-5.4.0/lib/note.txt': 'library',
            })
            digest = subprocess.check_output(['sha256sum', str(archive)], text=True).split()[0]
            script = temporary / 'install.sh'
            script.write_text(INSTALLER.read_text().replace(PINNED_SHA256, digest))
            script.chmod(0o755)
            stub_dir = temporary / 'bin'
            stub_dir.mkdir()
            calls = temporary / 'java-calls'
            write_executable(stub_dir / 'java', '#!/bin/bash\nprintf "%s\\n" "$*" >> "$JAVA_CALLS"\necho "EPUBCheck v5.4.0"\n')
            destination = temporary / 'dest'
            environment = dict(os.environ, PATH=str(stub_dir) + os.pathsep + os.environ['PATH'],
                               EPUBCHECK_ARCHIVE=str(archive), JAVA_CALLS=str(calls))
            result = subprocess.run(['bash', str(script), str(destination)],
                                    capture_output=True, text=True, env=environment)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual((destination / 'epubcheck.jar').read_text(), 'fixture jar')
            self.assertEqual((destination / 'lib/note.txt').read_text(), 'library')
            self.assertEqual((destination / '.sha256').read_text().strip(), digest)
            self.assertIn('--version', calls.read_text())
            # The stamp matches, so a second run must not read the archive or call Java.
            environment.pop('EPUBCHECK_ARCHIVE')
            calls.unlink()
            result = subprocess.run(['bash', str(script), str(destination)],
                                    capture_output=True, text=True, env=environment)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertFalse(calls.exists())

    def _make_check(self, java_text, epub_name):
        temporary = tempfile.TemporaryDirectory(prefix='cll-epubcheck-make-')
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        stub_dir = root / 'bin'
        stub_dir.mkdir()
        calls = root / 'java-calls'
        write_executable(stub_dir / 'java', java_text)
        jar = root / 'epubcheck.jar'
        jar.write_text('fixture')
        epub = root / epub_name
        epub.write_text('fixture epub')
        makefile = root / 'Makefile'
        makefile.write_text(
            'SHELL=/bin/bash -o pipefail\n'
            '.PHONY: check\n'
            'check:\n'
            f'\t"{RUNNER}" "{epub}"\n'
            '\techo CONTINUED\n')
        environment = dict(os.environ, PATH=str(stub_dir) + os.pathsep + os.environ['PATH'],
                           EPUBCHECK_JAR=str(jar), JAVA_CALLS=str(calls))
        result = subprocess.run(['make', '--no-print-directory', '-f', str(makefile), 'check'],
                                capture_output=True, text=True, env=environment)
        return result, calls

    def test_make_prints_a_warning_and_continues(self):
        result, calls = self._make_check(
            '#!/bin/bash\nprintf "%s\\n" "$*" > "$JAVA_CALLS"\n'
            'echo "WARNING(CSS-019): fixture: CSS font-face declaration has no attributes."\n'
            'echo "Check finished with warnings"\n'
            'exit 0\n',
            'warn.epub')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('WARNING(CSS-019)', result.stdout)
        self.assertIn('CONTINUED', result.stdout)
        self.assertNotIn('failonwarnings', calls.read_text())

    def test_make_stops_when_epubcheck_reports_an_error(self):
        result, calls = self._make_check(
            '#!/bin/bash\nprintf "%s\\n" "$*" > "$JAVA_CALLS"\n'
            'echo "ERROR(RSC-001): fixture: File \\"gone.xhtml\\" could not be found."\n'
            'echo "Check finished with errors"\n'
            'exit 1\n',
            'broken.epub')
        self.assertNotEqual(result.returncode, 0)
        combined = result.stdout + result.stderr
        self.assertIn('ERROR(RSC-001)', combined)
        self.assertNotIn('CONTINUED', combined)
        self.assertNotIn('failonwarnings', calls.read_text())

    def test_real_epubcheck_keeps_a_warning_and_fails_on_a_missing_spine_page(self):
        jar = os.environ.get('EPUBCHECK_JAR', '')
        candidates = [jar, '/usr/local/share/epubcheck/epubcheck.jar',
                      str(ROOT / 'build/tools/epubcheck/epubcheck.jar')]
        jar_path = next((Path(item) for item in candidates if item and Path(item).is_file()), None)
        if jar_path is None or shutil.which('java') is None:
            self.skipTest('EPUBCheck jar or Java is not installed')
        with tempfile.TemporaryDirectory(prefix='cll-epubcheck-live-') as temporary:
            temporary = Path(temporary)
            warning = temporary / 'warn.epub'
            broken = temporary / 'broken.epub'
            minimal_epub(warning, extra_files={'style.css': '@font-face { }\n'},
                         extra_manifest='<item id="css" href="style.css" media-type="text/css"/>')
            minimal_epub(broken,
                         extra_manifest='<item id="gone" href="gone.xhtml" media-type="application/xhtml+xml"/>',
                         extra_spine='<itemref idref="gone"/>')
            environment = dict(os.environ, EPUBCHECK_JAR=str(jar_path))
            warned = subprocess.run(['bash', str(RUNNER), str(warning)],
                                    capture_output=True, text=True, env=environment)
            self.assertEqual(warned.returncode, 0, warned.stdout + warned.stderr)
            self.assertIn('WARNING(CSS-019)', warned.stdout + warned.stderr)
            failed = subprocess.run(['bash', str(RUNNER), str(broken)],
                                    capture_output=True, text=True, env=environment)
            self.assertNotEqual(failed.returncode, 0)
            self.assertIn('ERROR(RSC-001)', failed.stdout + failed.stderr)
            self.assertIn('gone.xhtml', failed.stdout + failed.stderr)


if __name__ == '__main__':
    unittest.main()
