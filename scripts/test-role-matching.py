#!/usr/bin/env python3
"""Role token-membership tests for the XSL stylesheets (issue #348).

DocBook @role is a whitespace-separated token list. Templates that match
@role must match by token membership (and preserve extra tokens as HTML
classes), never by exact whole-attribute equality.

Needs xsltproc. Does not build the book.
"""
from pathlib import Path
import re
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET
import zipfile

SOURCE = Path(__file__).resolve().parent.parent
XHTML = '{http://www.w3.org/1999/xhtml}'

BOOK = '''<?xml version="1.0" encoding="UTF-8"?>
<book xmlns="http://docbook.org/ns/docbook" xml:lang="en">
  <info>
    <title>Fixture</title>
    <releaseinfo>
      <phrase role=" extra release-version ">v1.0</phrase>
      <phrase role=" release-separator extra "> | </phrase>
      <phrase role="release-date  extra">2026-11-25</phrase>
    </releaseinfo>
    <othercredit>
      <orgname role=" publication-notice extra ">Notice text<phrase role=" extra publication-disclaimer ">Disclaimer text</phrase></orgname>
    </othercredit>
  </info>
  <chapter xml:id="chapter-one">
    <title>First</title>
    <example xml:id="ex-padded" role=" interlinear-gloss-example extra ">
      <title>Padded</title>
      <para>Example body.</para>
    </example>
    <itemizedlist xml:id="list-plain" role="bullets">
      <listitem><para>One</para></listitem>
    </itemizedlist>
    <itemizedlist xml:id="list-multi" role=" extra  bullets ">
      <listitem><para>Two</para></listitem>
    </itemizedlist>
    <itemizedlist xml:id="list-sub" role="not-bullets">
      <listitem><para>Three</para></listitem>
    </itemizedlist>
  </chapter>
  <appendix xml:id="volume-chrestomathy">
    <title>Chrestomathy</title>
    <informaltable xml:id="tbl-plain" role="parallel-text">
      <tbody><tr><td>Plain</td><td>Plain EN</td></tr></tbody>
    </informaltable>
    <informaltable xml:id="tbl-padded" role="  parallel-text  ">
      <tbody><tr><td>Padded</td><td>Padded EN</td></tr></tbody>
    </informaltable>
    <informaltable xml:id="tbl-multi" role="parallel-text noborder">
      <tbody><tr><td>Multi</td><td>Multi EN</td></tr></tbody>
    </informaltable>
    <informaltable xml:id="tbl-multi-rev" role="noborder parallel-text">
      <tbody><tr><td>MultiRev</td><td>MultiRev EN</td></tr></tbody>
    </informaltable>
    <informaltable xml:id="tbl-prefix" role="not-parallel-text">
      <tbody><tr><td>Prefix</td><td>Prefix EN</td></tr></tbody>
    </informaltable>
    <informaltable xml:id="tbl-suffix" role="parallel-text-2">
      <tbody><tr><td>Suffix</td><td>Suffix EN</td></tr></tbody>
    </informaltable>
  </appendix>
</book>
'''


class RoleMatchingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix='cll-roles-')
        root = Path(cls.temporary.name)
        with zipfile.ZipFile(SOURCE / 'xml' / 'docbook-xsl-1.78.1.zip') as z:
            z.extractall(root / 'xsl')
        xsl = root / 'xsl' / 'docbook-xsl-1.78.1'
        wrapper = root / 'wrapper.xsl'
        wrapper.write_text(
            "<?xml version='1.0'?>\n"
            '<xsl:stylesheet xmlns:xsl="http://www.w3.org/1999/XSL/Transform" version="1.0">\n'
            f'<xsl:import href="{xsl}/xhtml5/docbook.xsl"/>\n'
            f'<xsl:include href="{SOURCE / "xml" / "docbook2html_config_prince.xsl"}"/>\n'
            '</xsl:stylesheet>\n',
            encoding='utf-8',
        )
        book = root / 'book.xml'
        book.write_text(BOOK, encoding='utf-8')
        out = root / 'out.html'
        r = subprocess.run(['xsltproc', '-o', str(out), str(wrapper), str(book)],
                           capture_output=True, text=True)
        if r.returncode != 0:
            raise AssertionError(f'xsltproc failed: {r.stderr[:2000]}')
        text = re.sub(r'<!DOCTYPE[^>]*>', '', out.read_text(encoding='utf-8'))
        cls.doc = ET.fromstring(text)
        cls.by_id = {el.get('id'): el for el in cls.doc.iter() if el.get('id')}

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def test_no_whole_value_role_match_in_common_xsl(self):
        # Guard the whole class: common XSL must match @role by token
        # membership, never by @role='...'.
        xsl = (SOURCE / 'xml' / 'docbook2html_config_common.xsl').read_text(encoding='utf-8')
        matches = re.findall(r"@role\s*=\s*['\"][^'\"]+['\"]", xsl)
        self.assertEqual(matches, [], f'whole-value @role equality in common XSL: {matches}')

    def test_parallel_text_informaltable_role_tokens(self):
        self.assertEqual(self.by_id['tbl-plain'].get('class'), 'parallel-text informaltable')
        self.assertEqual(self.by_id['tbl-padded'].get('class'), 'parallel-text informaltable')
        self.assertEqual(self.by_id['tbl-multi'].get('class'), 'parallel-text noborder informaltable')
        self.assertEqual(self.by_id['tbl-multi-rev'].get('class'), 'noborder parallel-text informaltable')
        # Substring look-alikes must not match the parallel-text template.
        self.assertEqual(self.by_id['tbl-prefix'].get('class'), 'informaltable')
        self.assertEqual(self.by_id['tbl-suffix'].get('class'), 'informaltable')

    def test_bullets_itemizedlist_role_tokens(self):
        self.assertEqual(self.by_id['list-plain'].get('class'), 'bullets')
        self.assertEqual(self.by_id['list-multi'].get('class'), 'extra bullets')
        self.assertEqual(self.by_id['list-sub'].get('class'), 'itemizedlist')

    def test_example_role_normalizes_whitespace(self):
        self.assertEqual(
            self.by_id['ex-padded'].get('class'),
            'interlinear-gloss-example extra example',
        )

    def test_branding_roles_match_by_token(self):
        spans = {el.get('class'): ''.join(el.itertext())
                 for el in self.doc.iter(XHTML + 'span') if el.get('class')}
        self.assertEqual(spans.get('extra release-version'), 'v1.0')
        self.assertEqual(spans.get('release-separator extra'), ' | ')
        self.assertEqual(spans.get('release-date extra'), '2026-11-25')
        self.assertIn('Notice text', spans.get('orgname publication-notice extra', ''))
        self.assertEqual(spans.get('extra publication-disclaimer'), 'Disclaimer text')


if __name__ == '__main__':
    unittest.main()
