#!/usr/bin/env python3
"""Regressions for link destinations in DocBook comparisons (issue #166)."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET

SCRIPT = Path(__file__).with_name('docbook-diff.py')
HREF = '{http://www.w3.org/1999/xlink}href'


class LinkTests(unittest.TestCase):
    def compare(self, old, new, targets='', old_targets=None):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for name, content, ids in [('old', old, targets if old_targets is None else old_targets),
                                       ('new', new, targets)]:
                chapter = root / name / 'chapters' / '01.xml'
                chapter.parent.mkdir(parents=True)
                chapter.write_text('<chapter xml:id="chapter-a"><title>Chapter</title>'
                                   '<section xml:id="section-a"><title>Section</title>'
                                   '<para>Read ' + content + ' for more information.</para>'
                                   + ids + '</section></chapter>')
            (root / 'out' / 'chapters').mkdir(parents=True)
            run = subprocess.run([sys.executable, str(SCRIPT), str(root / 'old'),
                                  str(root / 'new'), str(root / 'out')],
                                 capture_output=True, text=True)
            self.assertEqual(run.returncode, 0, run.stderr)
            return ET.parse(root / 'out' / 'chapters' / '01.xml').getroot(), json.loads(run.stdout)

    def assert_change(self, old_attr, new_attr, targets=''):
        root, result = self.compare('<link ' + old_attr + '>the guide</link>',
                                    '<link ' + new_attr + '>the guide</link>', targets)
        deleted, added = [], []
        def walk(el, flag=None):
            flag = el.get('revisionflag', flag)
            if el.tag == 'link':
                if flag == 'deleted':
                    deleted.append(el)
                elif flag == 'added':
                    added.append(el)
            for child in el:
                walk(child, flag)
        walk(root)
        self.assertEqual(len(deleted), 1, ET.tostring(root, encoding='unicode'))
        self.assertEqual(len(added), 1)
        self.assertEqual(''.join(deleted[0].itertext()), 'the guide')
        self.assertEqual(''.join(added[0].itertext()), 'the guide')
        self.assertEqual(result['stats'].get('changed_blocks'), 1)
        self.assertNotIn('changed_blocks_ws_only', result['stats'])
        notes = root.findall('.//phrase[@role="diff-link-destination"]')
        self.assertEqual(len(notes), 2)
        self.assertTrue(all('[destination:' in note.text for note in notes))
        return deleted[0], added[0]

    def test_external_target_only(self):
        old, new = self.assert_change('xlink:href="https://example.org/old"',
                                     'xlink:href="https://example.org/new"')
        self.assertEqual(old.get(HREF), 'https://example.org/old')
        self.assertEqual(new.get(HREF), 'https://example.org/new')

    def test_internal_target_only(self):
        old, new = self.assert_change('linkend="old-target"', 'linkend="new-target"',
                                     '<para xml:id="old-target">First target.</para>'
                                     '<para xml:id="new-target">Second target.</para>')
        self.assertEqual(old.get('linkend'), 'old-target')
        self.assertEqual(new.get('linkend'), 'new-target')

    def test_target_kind_changes(self):
        self.assert_change('linkend="target"', 'xlink:href="target"',
                           '<para xml:id="target">Target.</para>')

    def test_fragment_target_only(self):
        old, new = self.assert_change('xlink:href="#old-target"', 'xlink:href="#new-target"',
                                     '<para xml:id="old-target">First target.</para>'
                                     '<para xml:id="new-target">Second target.</para>')
        self.assertEqual(old.get(HREF), '#old-target')
        self.assertEqual(new.get(HREF), '#new-target')

    def test_unchanged_target(self):
        root, result = self.compare('<link xlink:href="https://example.org">the guide</link>',
                                    '<link xlink:href="https://example.org">the guide</link>')
        self.assertFalse(any(el.get('revisionflag') for el in root.iter()))
        self.assertEqual(result['stats'], {})

    def test_internal_alias_is_unchanged(self):
        root, result = self.compare('<link linkend="target">the guide</link>',
                                    '<link linkend="alias">the guide</link>',
                                    '<para xml:id="target"><anchor xml:id="alias"/>Target.</para>')
        self.assertFalse(any(el.get('revisionflag') for el in root.iter()))
        self.assertEqual(result['stats'], {})

    def test_fragment_alias_is_unchanged(self):
        root, result = self.compare('<link xlink:href="#target">the guide</link>',
                                    '<link xlink:href="#alias">the guide</link>',
                                    '<para xml:id="target"><anchor xml:id="alias"/>Target.</para>')
        self.assertFalse(any(el.get('revisionflag') for el in root.iter()))
        self.assertEqual(result['stats'], {})

    def test_external_target_is_not_an_internal_alias(self):
        self.assert_change('xlink:href="target"', 'xlink:href="alias"',
                           '<para xml:id="target"><anchor xml:id="alias"/>Target.</para>')

    def test_removed_fragment_target_is_sanitized(self):
        root, result = self.compare('<link xlink:href="#gone">the guide</link>',
                                    '<link xlink:href="#target">the guide</link>',
                                    '<para xml:id="target">Current target.</para>',
                                    '<para xml:id="gone">Removed target.</para>'
                                    '<para xml:id="target">Current target.</para>')
        self.assertFalse(any(el.get(HREF) == '#gone' for el in root.iter()))
        self.assertGreater(result['stats'].get('changed_blocks', 0), 0)

    def test_label_change_preserves_both_links(self):
        root, result = self.compare('<link xlink:href="https://example.org">old guide</link>',
                                    '<link xlink:href="https://example.org">new guide</link>')
        self.assertEqual(len(root.findall('.//link')), 2)
        self.assertEqual(result['stats'].get('changed_blocks'), 1)

    def test_nested_xref_target_changes(self):
        root, result = self.compare(
            '<link xlink:href="https://example.org"><xref linkend="first"/></link>',
            '<link xlink:href="https://example.org"><xref linkend="second"/></link>',
            '<para xml:id="first">First target.</para>'
            '<para xml:id="second">Second target.</para>')
        self.assertEqual(result['stats'].get('changed_blocks'), 1)
        self.assertNotIn('changed_blocks_ws_only', result['stats'])
        self.assertTrue(any(el.get('revisionflag') == 'deleted'
                            and el.find('.//xref[@linkend="first"]') is not None
                            for el in root.iter()))
        self.assertIsNotNone(root.find('.//link[@revisionflag="added"]/xref[@linkend="second"]'))

    def test_nested_xref_alias_is_unchanged(self):
        root, result = self.compare(
            '<link xlink:href="https://example.org"><xref linkend="target"/></link>',
            '<link xlink:href="https://example.org"><xref linkend="alias"/></link>',
            '<para xml:id="target"><anchor xml:id="alias"/>Target.</para>')
        self.assertFalse(any(el.get('revisionflag') for el in root.iter()))
        self.assertEqual(result['stats'], {})

    def test_nested_xref_endterm_changes(self):
        root, result = self.compare(
            '<link xlink:href="https://example.org"><xref linkend="target" endterm="first"/></link>',
            '<link xlink:href="https://example.org"><xref linkend="target" endterm="second"/></link>',
            '<para xml:id="target">Target.</para>'
            '<para xml:id="first">First label.</para>'
            '<para xml:id="second">Second label.</para>')
        self.assertEqual(result['stats'].get('changed_blocks'), 1)
        self.assertNotIn('changed_blocks_ws_only', result['stats'])
        self.assertIsNotNone(root.find('.//xref[@endterm="first"]'))
        self.assertIsNotNone(root.find('.//xref[@endterm="second"]'))

    def test_nested_xref_style_changes(self):
        root, result = self.compare(
            '<link xlink:href="https://example.org"><xref linkend="target" xrefstyle="title"/></link>',
            '<link xlink:href="https://example.org"><xref linkend="target" xrefstyle="number"/></link>',
            '<para xml:id="target">Target.</para>')
        self.assertEqual(result['stats'].get('changed_blocks'), 1)
        self.assertIsNotNone(root.find('.//xref[@xrefstyle="title"]'))
        self.assertIsNotNone(root.find('.//xref[@xrefstyle="number"]'))

    def test_nested_footnote_reference_changes(self):
        root, result = self.compare(
            '<link xlink:href="https://example.org"><footnoteref linkend="first"/></link>',
            '<link xlink:href="https://example.org"><footnoteref linkend="second"/></link>',
            '<para>Notes<footnote xml:id="first"><para>First note.</para></footnote>'
            '<footnote xml:id="second"><para>Second note.</para></footnote></para>')
        self.assertEqual(result['stats'].get('changed_blocks'), 1)
        self.assertIsNotNone(root.find('.//footnoteref[@linkend="first"]'))
        self.assertIsNotNone(root.find('.//footnoteref[@linkend="second"]'))

    def test_removed_internal_target_has_no_dangling_link(self):
        root, result = self.compare('<link linkend="gone">the guide</link>',
                                    '<link linkend="target">the guide</link>',
                                    '<para xml:id="target">Current target.</para>',
                                    '<para xml:id="gone">Removed target.</para>'
                                    '<para xml:id="target">Current target.</para>')
        self.assertFalse(any(el.get('linkend') == 'gone' for el in root.iter()))
        self.assertTrue(any(el.get('revisionflag') == 'deleted' and 'the guide' in ''.join(el.itertext())
                            for el in root.iter()))
        self.assertGreater(result['stats'].get('changed_blocks', 0), 0)


if __name__ == '__main__':
    unittest.main()
