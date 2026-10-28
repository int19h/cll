#!/usr/bin/env python3
"""Regressions for deleted material in DocBook comparisons (issue #165)."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET

SCRIPT = Path(__file__).with_name('docbook-diff.py')
KEEP = 'Keep this sentence unchanged across the two versions.'
DELETED = 'DELETED_SENTINEL This explanation must remain in the comparison.'


class DeletionTests(unittest.TestCase):
    def compare(self, old, new):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        root = Path(temp.name)
        for name, content in [('old', old), ('new', new)]:
            chapter = root / name / 'chapters' / '01.xml'
            chapter.parent.mkdir(parents=True)
            chapter.write_text('<chapter xml:id="chapter-a"><title>Chapter</title>'
                               '<section xml:id="section-a"><title>Section</title>'
                               + content + '</section></chapter>')
        output = root / 'out' / 'chapters' / '01.xml'
        output.parent.mkdir(parents=True)
        output.write_text('OUTPUT_UNTOUCHED')
        result = subprocess.run([sys.executable, str(SCRIPT), str(root / 'old'),
                                 str(root / 'new'), str(root / 'out')],
                                capture_output=True, text=True)
        return result, output.read_text()

    def assert_deleted(self, old, new, order):
        result, output = self.compare(old, new)
        self.assertEqual(result.returncode, 0, result.stderr)
        root = ET.fromstring(output)
        marked = [''.join(el.itertext()) for el in root.iter()
                  if el.get('revisionflag') == 'deleted']
        self.assertTrue(any(DELETED in text for text in marked), output)
        text = ''.join(root.itertext())
        self.assertEqual([text.index(value) for value in order],
                         sorted(text.index(value) for value in order))
        self.assertNotIn('unplaced', json.loads(result.stdout)['stats'])

    def test_removed_preceding_wrapper(self):
        self.assert_deleted('<blockquote><informalexample><para>' + KEEP
                            + '</para></informalexample><para>' + DELETED
                            + '</para></blockquote>',
                            '<blockquote><para>' + KEEP + '</para></blockquote>',
                            [KEEP, DELETED])

    def test_removed_following_wrapper(self):
        self.assert_deleted('<blockquote><para>' + DELETED
                            + '</para><informalexample><para>' + KEEP
                            + '</para></informalexample></blockquote>',
                            '<blockquote><para>' + KEEP + '</para></blockquote>',
                            [DELETED, KEEP])

    def test_multiple_deletions_keep_order(self):
        self.assert_deleted('<blockquote><informalexample><para>' + KEEP
                            + '</para></informalexample><para>' + DELETED
                            + '</para><para>SECOND_DELETION</para></blockquote>',
                            '<blockquote><para>' + KEEP + '</para></blockquote>',
                            [KEEP, DELETED, 'SECOND_DELETION'])

    def test_nearest_surviving_section(self):
        self.assert_deleted('<blockquote><informalexample><para>' + KEEP
                            + '</para></informalexample><para>' + DELETED
                            + '</para></blockquote>', '<para>' + KEEP + '</para>',
                            [KEEP, DELETED])

    def test_unplaceable_structure_fails_before_writes(self):
        result, output = self.compare(
            '<informaltable><tbody><tr><td>' + KEEP + '</td></tr>'
            '<tr><td>' + DELETED + '</td></tr></tbody></informaltable>',
            '<para>' + KEEP + '</para>')
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn('01.xml', result.stderr)
        self.assertIn('tr', result.stderr)
        self.assertIn('DELETED_SENTINEL', result.stderr)
        self.assertEqual(output, 'OUTPUT_UNTOUCHED')

    def test_unplaceable_words_fail_before_writes(self):
        result, output = self.compare(
            '<interlinear-gloss-itemized><jbo>' + KEEP
            + ' DELETED_WORD</jbo></interlinear-gloss-itemized>',
            '<interlinear-gloss-itemized><jbo>' + KEEP
            + '</jbo></interlinear-gloss-itemized>')
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn('01.xml', result.stderr)
        self.assertIn('jbo', result.stderr)
        self.assertIn('DELETED_WORD', result.stderr)
        self.assertEqual(output, 'OUTPUT_UNTOUCHED')


if __name__ == '__main__':
    unittest.main()
