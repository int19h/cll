#!/usr/bin/env python3
"""Status-note rendering (issue #47): the XSL label table, the CSS
glyphs and badges, the legend anchor, and the reservation of
@condition against DocBook profiling.

Needs xsltproc for the transform smoke test. It does not build the book.
"""
from pathlib import Path
import re
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET
import zipfile

SOURCE = Path(__file__).resolve().parent.parent
XSL_NS = '{http://www.w3.org/1999/XSL/Transform}'
XHTML = '{http://www.w3.org/1999/xhtml}'

LABELS = {
    'llg-ratified': 'Ratified by the LLG',
    'bpfk-approved': 'Approved by the BPFK',
    'checkpointed': 'BPFK checkpoint',
    'de-facto': 'Established usage',
    'proposed': 'Proposal',
    'unsettled': 'Open question',
    'editorial': "This edition's choice",
    'historical': 'First-edition rule',
}

# The book element carries the DocBook namespace, as the real merged
# book does: the stock stylesheets then strip the namespace and turn
# @xml:id into @id (common/stripns.xsl), which the legend lookup and
# the id copying in the customization layer must survive.
BOOK = '''<?xml version="1.0" encoding="UTF-8"?>
<book xmlns="http://docbook.org/ns/docbook" xml:lang="en">
  <info><title>Fixture</title></info>
  <chapter xml:id="chapter-one">
    <title>First</title>
    <para role="status-note" condition="status:bpfk-approved;also:historical;date:2015-08-08">Dotside note prose.</para>
    <para xml:id="note-usage" role="status-note" condition="status:de-facto">Usage note prose.</para>
    <para role="status-note">Bare note prose.</para>
    <para role="status-note" condition="status:proposed;body:bpfk">BPFK proposal prose.</para>
    <para role="status-note" condition="status:bpfk-approved;body:bpfk">Explicit named body prose.</para>
    <para role="extra status-note" condition="status:checkpointed">Extra role token prose.</para>
    <para>Ordinary <phrase role="status-mark" condition="status:de-facto;also:historical">accepted by parsers</phrase> here, and <phrase role="status-mark extra" condition="status:proposed;body:bpfk">a BPFK proposal clause</phrase> too.</para>
  </chapter>
  <article xml:id="appendix-changes">
    <title>Changes</title>
    <section xml:id="section-changes-how-to-read">
      <title>How to read</title>
      <variablelist xml:id="status-legend">
        <varlistentry><term>Ratified by the LLG</term>
        <listitem><para>An LLG vote.</para></listitem></varlistentry>
      </variablelist>
    </section>
  </article>
</book>
'''


class ProfilingReservation(unittest.TestCase):
    def test_no_stylesheet_sets_a_profiling_parameter(self):
        # DocBook profiling keys off @condition; setting any
        # profile.* parameter in a customization layer would put the
        # status notes at risk of being profiled out of the book.
        for xsl in sorted((SOURCE / 'xml').glob('*.xsl')):
            tree = ET.parse(xsl)
            for param in tree.getroot().iter(XSL_NS + 'param'):
                self.assertFalse(
                    (param.get('name') or '').startswith('profile.'),
                    f'{xsl.name} sets {param.get("name")}')

    def test_no_build_script_passes_profile_condition(self):
        for name in ('cll_build', 'scripts/Makefile', 'scripts/build_epub.sh',
                     'scripts/build-selected-formats.sh'):
            path = SOURCE / name
            if path.exists():
                self.assertNotIn('profile.condition', path.read_text(), name)

    def test_docs_reserve_condition(self):
        docs = (SOURCE / 'docs' / 'status-markup.md').read_text()
        self.assertIn('reserved for status notes', docs)


class LabelTableAndCss(unittest.TestCase):
    def test_label_table_in_common_xsl(self):
        xsl = (SOURCE / 'xml' / 'docbook2html_config_common.xsl').read_text()
        for token, label in LABELS.items():
            self.assertIn(f"$token = '{token}'", xsl, token)
            self.assertIn(label, xsl, token)

    def test_label_table_nowhere_else(self):
        # One source of truth: no second XSL may carry the table.
        for xsl in sorted((SOURCE / 'xml').glob('*.xsl')):
            if xsl.name == 'docbook2html_config_common.xsl':
                continue
            self.assertNotIn('cll.status.label', xsl.read_text(), xsl.name)

    def test_css_glyph_and_badge_per_status(self):
        css = (SOURCE / 'assets' / 'css' / 'master.css').read_text()
        glyphs = []
        for token in LABELS:
            m = re.search(r'p\.status-note\.status-' + re.escape(token) +
                          r'::before \{ content: "([^"]+)"', css)
            self.assertIsNotNone(m, token)
            glyphs.append(m.group(1))
            self.assertIn(f'p.status-note.status-{token} span.status-label',
                          css, token)
        # The mark differs by shape, never by colour alone.
        self.assertEqual(len(set(glyphs)), len(glyphs), glyphs)

    def test_legend_anchor(self):
        a03 = (SOURCE / 'chapters' / 'a03.xml').read_text()
        self.assertIn('xml:id="status-legend"', a03)

    def test_epub_gets_the_light_label_not_the_filled_badge(self):
        # Review R3: an ePub reading system reports screen media, so
        # the filled screen badge must be undone for body.epub (the
        # class scripts/epub_pages.rb puts on packaged pages).
        css = (SOURCE / 'assets' / 'css' / 'master.css').read_text()
        m = re.search(r'body\.epub p\.status-note span\.status-label '
                      r'\{([^}]*)\}', css)
        self.assertIsNotNone(m)
        self.assertIn('background: none', m.group(1))
        self.assertIn('color: inherit', m.group(1))

    def test_print_keeps_the_label_with_the_prose_start(self):
        # Review R1, static half (the pagination itself is in
        # scripts/test-status-pagination.py): the print rules keep
        # the note in one fragment and the also-line attached.
        css = (SOURCE / 'assets' / 'css' / 'master.css').read_text()
        m = re.search(r'p\.status-note \{ color: inherit;([^}]*)\}', css)
        self.assertIsNotNone(m)
        self.assertIn('break-inside: avoid', m.group(1))
        m = re.search(r'span\.status-also \{ color: #333;([^}]*)\}', css)
        self.assertIsNotNone(m)
        self.assertIn('break-after: avoid', m.group(1))


class Transform(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix='cll-status-')
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
            '</xsl:stylesheet>\n')
        book = root / 'book.xml'
        book.write_text(BOOK)
        out = root / 'out.html'
        r = subprocess.run(['xsltproc', '-o', str(out), str(wrapper), str(book)],
                           capture_output=True, text=True)
        if r.returncode != 0:
            raise AssertionError(f'xsltproc failed: {r.stderr[:2000]}')
        text = re.sub(r'<!DOCTYPE[^>]*>', '', out.read_text())
        cls.doc = ET.fromstring(text)
        cls.notes = [p for p in cls.doc.iter(XHTML + 'p')
                     if 'status-note' in (p.get('class') or '')]

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def test_full_note(self):
        note = self.notes[0]
        self.assertEqual(note.get('class'), 'status-note status-bpfk-approved')
        self.assertEqual(note.get('data-status'), 'bpfk-approved')
        self.assertEqual(note.get('data-also'), 'historical')
        self.assertEqual(note.get('data-date'), '2015-08-08')
        self.assertEqual(note.get('data-body'), 'bpfk')
        text = ' '.join(''.join(note.itertext()).split())
        self.assertTrue(text.startswith('Approved by the BPFK, 2015-08-08'), text)
        self.assertIn('also: First-edition rule', text)
        self.assertIn('Dotside note prose.', text)
        link = next(a for a in note.iter(XHTML + 'a')
                    if a.get('class') == 'status-legend-link')
        self.assertTrue(link.get('href').endswith('#status-legend'), link.get('href'))
        self.assertIn('2015-08-08', link.get('title'))
        self.assertIn('BPFK', link.get('title'))

    def test_plain_and_bare_notes(self):
        plain, bare = self.notes[1], self.notes[2]
        self.assertEqual(plain.get('id'), 'note-usage')
        self.assertEqual(plain.get('data-body'), 'community')
        self.assertNotIn('data-also', plain.attrib)
        self.assertTrue(' '.join(''.join(plain.itertext()).split())
                        .startswith('Established usage'))
        self.assertEqual(bare.get('class'), 'status-note')
        self.assertNotIn('data-status', bare.attrib)
        self.assertEqual(''.join(bare.itertext()).strip(), 'Bare note prose.')

    def test_explicit_body_in_the_visible_label(self):
        # Review R4: an explicit body: that the primary label does not
        # name is real label text ("Proposal, BPFK", distinct from
        # approval); one the label already names is not repeated;
        # a defaulted body stays out of the visible label.
        proposal, approved = self.notes[3], self.notes[4]
        self.assertEqual(proposal.get('data-body'), 'bpfk')
        text = ' '.join(''.join(proposal.itertext()).split())
        self.assertTrue(text.startswith('Proposal, BPFK'), text)
        self.assertIn('BPFK proposal prose.', text)
        text = ' '.join(''.join(approved.itertext()).split())
        self.assertTrue(
            text.startswith('Approved by the BPFK Explicit'), text)
        self.assertNotIn('BPFK, BPFK', text)
        plain_text = ' '.join(''.join(self.notes[1].itertext()).split())
        self.assertNotIn('Community', plain_text)

    def test_role_matched_by_token_membership(self):
        # Review L1: role is a token list; extra tokens must not lose
        # the label or the metadata, and survive as classes.
        extra = self.notes[5]
        self.assertEqual(extra.get('class'),
                         'extra status-note status-checkpointed')
        self.assertEqual(extra.get('data-status'), 'checkpointed')
        text = ' '.join(''.join(extra.itertext()).split())
        self.assertTrue(text.startswith('BPFK checkpoint'), text)
        mark = next(s for s in self.doc.iter(XHTML + 'span')
                    if s.get('class') == 'status-mark extra status-proposed')
        self.assertEqual(mark.get('data-body'), 'bpfk')
        text = ''.join(mark.itertext())
        self.assertIn('a BPFK proposal clause', text)
        self.assertIn('[Proposal, BPFK]', text)

    def test_inline_mark(self):
        mark = next(s for s in self.doc.iter(XHTML + 'span')
                    if s.get('class') == 'status-mark status-de-facto')
        self.assertEqual(mark.get('data-also'), 'historical')
        self.assertIn('Established usage', mark.get('title'))
        self.assertIn('also: First-edition rule', mark.get('title'))
        text = ''.join(mark.itertext())
        self.assertIn('accepted by parsers', text)
        self.assertIn('[Established usage]', text)

    def test_legend_id_in_output(self):
        ids = {el.get('id') for el in self.doc.iter() if el.get('id')}
        self.assertIn('status-legend', ids)


class ChunkedTransform(unittest.TestCase):
    """In chunked output the legend link must name the appendix file:
    a bare fragment fails EPUBCheck (RSC-012) on every other page."""

    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix='cll-status-chunk-')
        root = Path(cls.temporary.name)
        with zipfile.ZipFile(SOURCE / 'xml' / 'docbook-xsl-1.78.1.zip') as z:
            z.extractall(root / 'xsl')
        xsl = root / 'xsl' / 'docbook-xsl-1.78.1'
        wrapper = root / 'wrapper.xsl'
        wrapper.write_text(
            "<?xml version='1.0'?>\n"
            '<xsl:stylesheet xmlns:xsl="http://www.w3.org/1999/XSL/Transform" version="1.0">\n'
            f'<xsl:import href="{xsl}/xhtml5/chunk.xsl"/>\n'
            f'<xsl:include href="{SOURCE / "xml" / "docbook2html_config_epub.xsl"}"/>\n'
            '</xsl:stylesheet>\n')
        book = root / 'book.xml'
        book.write_text(BOOK)
        out = root / 'out'
        out.mkdir()
        r = subprocess.run(
            ['xsltproc', '--stringparam', 'base.dir', str(out) + '/',
             '--stringparam', 'chunk.section.depth', '8',
             str(wrapper), str(book)],
            capture_output=True, text=True, cwd=root)
        if r.returncode != 0:
            raise AssertionError(f'xsltproc failed: {r.stderr[:2000]}')
        cls.out = out

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def test_chunked_legend_href_names_the_appendix_file(self):
        hrefs = []
        for page in sorted(self.out.glob('*.html')):
            text = re.sub(r'<!DOCTYPE[^>]*>', '', page.read_text())
            doc = ET.fromstring(text)
            hrefs.extend(a.get('href') for a in doc.iter(XHTML + 'a')
                         if a.get('class') == 'status-legend-link')
        self.assertTrue(hrefs)
        for href in hrefs:
            self.assertEqual(href, 'appendix-changes.html#status-legend')


if __name__ == '__main__':
    unittest.main()
