#!/usr/bin/env python3
"""End-to-end deleted-section ToC marks through the real DocBook XSL."""
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile

SCRIPT = Path(__file__).with_name('docbook-diff.py')
XSL_ZIP = SCRIPT.parent.parent / 'xml' / 'docbook-xsl-1.78.1.zip'
NS = ('xmlns="http://docbook.org/ns/docbook" '
      'xmlns:xlink="http://www.w3.org/1999/xlink" version="5.0"')


def section(sec_id, title, *content):
    return ('<section xml:id="%s"><title>%s</title>' % (sec_id, title)
            + ''.join(content) + '</section>')


def paragraph(text):
    return '<para>%s</para>' % text


class DeletedSectionRenderTests(unittest.TestCase):
    def setUp(self):
        if shutil.which('xsltproc') is None:
            self.skipTest('xsltproc is required for the real stylesheet check')

    def test_deleted_numbers_use_the_copies_own_ids(self):
        stable = section('c1s1', 'Stable', paragraph('Stable preceding paragraph.'))
        deleted = section(
            'c1s2', 'Deleted outer', paragraph('Outer deleted substance.'),
            section('c1s3', 'Nested deleted', paragraph('Nested deleted substance.')))
        last = section('c1s4', 'Stable again', paragraph('Stable final paragraph.'))
        old = '<chapter %s xml:id="c1"><title>Chapter</title>%s</chapter>' % (
            NS, stable + deleted + last)
        anchored = section(
            'c1s1', 'Stable<anchor xml:id="c1s2"/><anchor xml:id="c1s3"/>',
            paragraph('Stable preceding paragraph.'))
        new = '<chapter %s xml:id="c1"><title>Chapter</title>%s</chapter>' % (
            NS, anchored + last)

        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            for name, content in (('old', old), ('new', new)):
                chapter = root / name / 'chapters' / '01.xml'
                chapter.parent.mkdir(parents=True)
                chapter.write_text(content)
            (root / 'out' / 'chapters').mkdir(parents=True)
            run = subprocess.run(
                [sys.executable, str(SCRIPT), '--stats', str(root / 'stats.json'),
                 str(root / 'old'), str(root / 'new'), str(root / 'out')],
                capture_output=True, text=True)
            self.assertEqual(run.returncode, 0, run.stderr)
            annotated = (root / 'out' / 'chapters' / '01.xml').read_text().strip()
            (root / 'book.xml').write_text(
                '<?xml version="1.0"?><book %s><title>B</title>%s</book>' % (NS, annotated))
            with zipfile.ZipFile(XSL_ZIP) as archive:
                archive.extractall(root / 'xsl')
            stylesheet = root / 'xsl' / 'docbook-xsl-1.78.1' / 'xhtml' / 'docbook.xsl'
            rendered = subprocess.run(
                ['xsltproc', '--nonet', '--stringparam', 'section.autolabel', '1',
                 '--stringparam', 'section.label.includes.component.label', '1',
                 str(stylesheet), str(root / 'book.xml')],
                capture_output=True, text=True)
            self.assertEqual(rendered.returncode, 0, rendered.stderr)
            (root / 'index.html').write_text(rendered.stdout)
            subprocess.run(
                [sys.executable, str(SCRIPT), 'finish', str(root / 'index.html'),
                 str(root / 'fin'), '--old-label', 'Old', '--new-label', 'New',
                 '--stats', str(root / 'stats.json')], check=True,
                capture_output=True, text=True)
            page = (root / 'fin' / 'difference.html').read_text()
            prefixed = (root / 'fin' / 'difference_prefixed.html').read_text()
            sections = json.loads((root / 'stats.json').read_text())['sections']

        targets = sorted(key for key, entry in sections.items()
                         if key.startswith('diff-deleted-section-'))
        self.assertEqual(len(targets), 2)
        for target, number in zip(targets, ('1.2.', '1.2.1.')):
            self.assertIn('<a href="#%s"><span class="diff-toc-deleted" '
                          'title="Deleted material">%s</span>' % (target, number), page)
            self.assertIn('<a href="#%s"><span class="diffmark">[\u2212]</span>'
                          '<span class="diff-toc-deleted" title="Deleted material">'
                          '%s</span>' % (target, number), prefixed)
        self.assertNotIn('href="#c1s2"><span class="diff-toc-deleted"', page)
        self.assertNotIn('href="#c1s3"><span class="diff-toc-deleted"', page)


if __name__ == '__main__':
    unittest.main()
