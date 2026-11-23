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
    <para role="status-note" condition="status:de-facto;&#9;date:2015-08-08">Tab separated date prose.</para>
    <para>Ordinary <phrase role="status-mark" condition="status:de-facto;also:historical">accepted by parsers</phrase> here, and <phrase role="status-mark extra" condition="status:proposed;body:bpfk;date:2020-01-02">a BPFK proposal clause</phrase> too.</para>
  </chapter>
  <appendix xml:id="appendix-changes">
    <title>Changes</title>
    <section xml:id="section-changes-how-to-read">
      <title>How to read</title>
      <variablelist xml:id="status-legend">
        <varlistentry><term>Ratified by the LLG</term>
        <listitem><para>An LLG vote.</para></listitem></varlistentry>
      </variablelist>
    </section>
  </appendix>
</book>
'''


# The same chapter without the changes appendix: a partial build whose
# sources have no status-legend element must leave the labels unlinked
# (issue #290). The chapter prose is identical to BOOK's, so the two
# outputs must agree in everything but the link.
BOOK_NO_LEGEND = '''<?xml version="1.0" encoding="UTF-8"?>
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
    <para role="status-note" condition="status:de-facto;&#9;date:2015-08-08">Tab separated date prose.</para>
    <para>Ordinary <phrase role="status-mark" condition="status:de-facto;also:historical">accepted by parsers</phrase> here, and <phrase role="status-mark extra" condition="status:proposed;body:bpfk;date:2020-01-02">a BPFK proposal clause</phrase> too.</para>
  </chapter>
</book>
'''


def run_unchunked(book_xml, prefix):
    """Transform book_xml to a single page; return (temporary, document).

    The caller owns the TemporaryDirectory and must close it.
    """
    temporary = tempfile.TemporaryDirectory(prefix=prefix)
    root = Path(temporary.name)
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
    book.write_text(book_xml)
    out = root / 'out.html'
    r = subprocess.run(['xsltproc', '-o', str(out), str(wrapper), str(book)],
                       capture_output=True, text=True)
    if r.returncode != 0:
        raise AssertionError(f'xsltproc failed: {r.stderr[:2000]}')
    text = re.sub(r'<!DOCTYPE[^>]*>', '', out.read_text())
    return temporary, ET.fromstring(text)


def run_chunked(book_xml, prefix):
    """Transform book_xml to chunked pages; return (temporary, outdir).

    The caller owns the TemporaryDirectory and must close it.
    """
    temporary = tempfile.TemporaryDirectory(prefix=prefix)
    root = Path(temporary.name)
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
    book.write_text(book_xml)
    out = root / 'out'
    out.mkdir()
    r = subprocess.run(
        ['xsltproc', '--stringparam', 'base.dir', str(out) + '/',
         '--stringparam', 'chunk.section.depth', '8',
         str(wrapper), str(book)],
        capture_output=True, text=True, cwd=root)
    if r.returncode != 0:
        raise AssertionError(f'xsltproc failed: {r.stderr[:2000]}')
    return temporary, out


def reader_text(element):
    """The element's text the way a reader gets it (textContent):
    no whitespace is invented between elements. Joining with split()
    would hide fused words (review O1)."""
    return ''.join(element.itertext())


def specificity(selector):
    """(ids, classes, elements) for the simple selectors used here."""
    ids = selector.count('#')
    classes = selector.count('.') + selector.count('[')
    classes += len(re.findall(r'(?<!:):(?!:)', selector))
    elements = selector.count('::')
    for compound in re.split(r'[\s>+~]+', selector):
        if re.match(r'[A-Za-z][\w-]*', compound):
            elements += 1
    return (ids, classes, elements)


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

    def test_per_status_borders_outrank_any_base_border(self):
        # Review O6: a base selector of higher specificity
        # (section.section > p.status-note) silently cancelled every
        # per-status border colour/style/width in the real book,
        # where notes are direct children of section.section.
        css = (SOURCE / 'assets' / 'css' / 'master.css').read_text()
        css = re.sub(r'/\*.*?\*/', '', css, flags=re.S)
        token_re = r'\.status-(' + '|'.join(LABELS) + r')\b'
        base = []
        per_status = {}
        for selectors, body in re.findall(r'([^{}]+)\{([^{}]*)\}', css):
            if 'border-left' not in body:
                continue
            for selector in selectors.split(','):
                selector = ' '.join(selector.split())
                if 'status-note' not in selector or '::' in selector:
                    continue
                m = re.search(token_re, selector)
                if m:
                    per_status.setdefault(m.group(1), []).append(
                        specificity(selector))
                else:
                    base.append((selector, specificity(selector)))
        self.assertTrue(base, 'no base status-note border rule found')
        self.assertEqual(set(per_status), set(LABELS))
        for selector, spec in base:
            for token, specs in per_status.items():
                for other in specs:
                    self.assertLess(
                        spec, other,
                        f'base {selector!r} {spec} outranks or ties the '
                        f'per-status border for {token} {other}')

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

    def test_margin_glyphs_are_decorative_only(self):
        # Screen readers may announce CSS-generated content, while the
        # real-text label already carries the status. Every status margin
        # glyph keeps its visible content declaration and adds an
        # identical one with an empty alternative text, so engines that
        # understand alt text skip the decorative glyph; older engines
        # fall back to the plain glyph. The legend link templates are
        # untouched.
        css = (SOURCE / 'assets' / 'css' / 'master.css').read_text()
        css = re.sub(r'/\*.*?\*/', '', css, flags=re.S)
        count = 0
        for m in re.finditer(
                r'(p\.status-note[^{]*?::before|span\.status-mark[^{]*?::after)'
                r'\s*\{([^}]*)\}', css):
            selector, body = m.group(1), m.group(2)
            if 'content:' not in body:
                continue
            count += 1
            self.assertIn('/ "";', body, selector)
        self.assertEqual(count, 2 + 2 * len(LABELS), count)

    @staticmethod
    def ruby_hash(source, name):
        block = source.split(name + ' = {', 1)[1].split('}.freeze', 1)[0]
        # Values may use either quote style (NAMED_BODIES is single-quoted).
        out = {}
        for line in block.splitlines():
            key, sep, value = line.partition('=>')
            if not sep:
                continue
            token = key.strip().strip("'")
            value = value.strip().rstrip(",").strip().strip("'").strip('"')
            out[token] = value
        return out

    @staticmethod
    def decode_ruby_escapes(value):
        # The Ruby table writes non-ASCII glyphs as \uXXXX escapes.
        return re.sub(r'\\u([0-9A-Fa-f]{4})',
                      lambda m: chr(int(m.group(1), 16)), value)

    @staticmethod
    def decode_css_escapes(value):
        return re.sub(r'\\([0-9A-Fa-f]{4})(?![0-9A-Fa-f])',
                      lambda m: chr(int(m.group(1), 16)), value)

    @staticmethod
    def xsl_choose(xsl, name, var):
        # Every token the template names, with the label it assigns:
        # handles alternatives joined by 'or' (body.named names two).
        block = xsl.split(f'<xsl:template name="{name}">', 1)[1]
        block = block.split('</xsl:template>', 1)[0]
        out = {}
        for cond, text in re.findall(
                r'<xsl:when test="([^"]+)">([^<]*)</xsl:when>', block):
            for token in re.findall(rf"\${var} = '([a-z-]+)'", cond):
                out[token] = text
        return out

    def test_ruby_tables_match_xsl(self):
        # scripts/status_labels.rb is the one Ruby copy the Typst and
        # ConTeXt converters share. Compare the whole token-to-label
        # mapping, keys included, so a swapped pair of XSL labels fails
        # this test; compare the body tables too, and require the same
        # token sets so an extra entry on either side fails as well.
        ruby = (SOURCE / 'scripts' / 'status_labels.rb').read_text()
        xsl = (SOURCE / 'xml' / 'docbook2html_config_common.xsl').read_text()
        self.assertEqual(self.ruby_hash(ruby, 'LABELS'),
                         self.xsl_choose(xsl, 'cll.status.label', 'token'))
        self.assertEqual(self.ruby_hash(ruby, 'BODY_LABELS'),
                         self.xsl_choose(xsl, 'cll.status.body.label', 'body'))
        self.assertEqual(self.ruby_hash(ruby, 'NAMED_BODIES'),
                         self.xsl_choose(xsl, 'cll.status.body.named', 'token'))

    def test_ruby_glyphs_match_css(self):
        css = (SOURCE / 'assets' / 'css' / 'master.css').read_text()
        ruby = (SOURCE / 'scripts' / 'status_labels.rb').read_text()
        css_glyphs = {}
        for token in LABELS:
            m = re.search(r'p\.status-note\.status-' + re.escape(token) +
                          r'::before \{ content: "([^"]+)"', css)
            self.assertIsNotNone(m, token)
            css_glyphs[token] = self.decode_css_escapes(m.group(1))
        ruby_glyphs = {token: self.decode_ruby_escapes(value)
                       for token, value in
                       self.ruby_hash(ruby, 'GLYPHS').items()}
        self.assertEqual(ruby_glyphs, css_glyphs)

    def test_ruby_tables_match_docs(self):
        # The docs claim the table is checked against docs/status-markup.md:
        # parse its label table and glyph list and require the same maps.
        docs = (SOURCE / 'docs' / 'status-markup.md').read_text()
        ruby = (SOURCE / 'scripts' / 'status_labels.rb').read_text()
        docs_labels = dict(re.findall(
            r"^\| `([a-z-]+)` \| ([^|]+?) \|", docs, re.M))
        self.assertEqual(docs_labels, self.ruby_hash(ruby, 'LABELS'))
        bullet = docs.split('differs by status', 1)[1].split('fonts', 1)[0]
        pairs = []
        for chunk in re.split(r'[,\n]', bullet):
            m = re.match(r'\s*(\S+)\s+([a-z-]+)\s*$', chunk)
            if m:
                pairs.append((m.group(2), m.group(1)))
        docs_glyphs = dict(pairs)
        ruby_glyphs = {token: self.decode_ruby_escapes(value)
                       for token, value in
                       self.ruby_hash(ruby, 'GLYPHS').items()}
        self.assertEqual(docs_glyphs, ruby_glyphs)

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
        # Review O1: read as textContent, the also-line must not fuse
        # with the first word of the prose when CSS is absent. This
        # fixture's prose starts right after the start tag.
        self.assertIn('also: First-edition rule Dotside note prose.',
                      reader_text(note))
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
        # Review O3: the inline label shows its date as real text,
        # like the block label, not only in the tooltip.
        self.assertIn('[Proposal, BPFK, 2020-01-02]', text)

    def test_condition_whitespace_beyond_spaces(self):
        # Review O4: a tab character reference in @condition survives
        # XML attribute normalization; the lint strips all whitespace,
        # so the renderer must find the key after it too.
        note = self.notes[6]
        self.assertEqual(note.get('data-date'), '2015-08-08')
        self.assertTrue(reader_text(note).startswith(
            'Established usage, 2015-08-08'), reader_text(note))

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


class NoLegendTransform(unittest.TestCase):
    """Without the legend in the build, labels stay plain text (issue
    #290): no dangling status-legend-link for EPUBCheck to reject, with
    the same classes, data attributes and label text."""

    @classmethod
    def setUpClass(cls):
        cls.temporary, cls.doc = run_unchunked(BOOK_NO_LEGEND,
                                               'cll-status-nolegend-')
        cls.notes = [p for p in cls.doc.iter(XHTML + 'p')
                     if 'status-note' in (p.get('class') or '')]
        cls.linked_temporary, cls.linked = run_unchunked(BOOK,
                                                         'cll-status-keep-')
        cls.linked_notes = [p for p in cls.linked.iter(XHTML + 'p')
                            if 'status-note' in (p.get('class') or '')]

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()
        cls.linked_temporary.cleanup()

    def test_no_legend_links(self):
        links = [a for a in self.doc.iter(XHTML + 'a')
                 if a.get('class') == 'status-legend-link']
        self.assertEqual(links, [])

    def test_no_legend_id_in_output(self):
        ids = {el.get('id') for el in self.doc.iter() if el.get('id')}
        self.assertNotIn('status-legend', ids)

    def test_unlinked_notes_match_linked_notes_but_for_the_link(self):
        self.assertEqual(len(self.notes), len(self.linked_notes))
        for plain, linked in zip(self.notes, self.linked_notes):
            self.assertEqual(plain.get('class'), linked.get('class'))
            for attr in ('id', 'data-status', 'data-also',
                         'data-date', 'data-body'):
                self.assertEqual(plain.attrib.get(attr),
                                 linked.attrib.get(attr), attr)
            self.assertEqual(reader_text(plain), reader_text(linked))

    def test_unlinked_label_text(self):
        labels = [s for s in self.doc.iter(XHTML + 'span')
                  if s.get('class') == 'status-label']
        self.assertEqual(len(labels), 6)
        texts = [reader_text(label) for label in labels]
        self.assertEqual(texts[0], 'Approved by the BPFK, 2015-08-08')
        self.assertEqual(texts[1], 'Established usage')
        self.assertEqual(texts[2], 'Proposal, BPFK')
        self.assertEqual(texts[3], 'Approved by the BPFK')
        self.assertEqual(texts[4], 'BPFK checkpoint')
        self.assertEqual(texts[5], 'Established usage, 2015-08-08')
        for label in labels:
            self.assertEqual(list(label.iter(XHTML + 'a')), [])

    def test_inline_marks_unchanged(self):
        mark = next(s for s in self.doc.iter(XHTML + 'span')
                    if s.get('class') == 'status-mark status-de-facto')
        self.assertEqual(mark.get('data-also'), 'historical')
        self.assertIn('Established usage', mark.get('title'))
        text = ''.join(mark.itertext())
        self.assertIn('accepted by parsers', text)
        self.assertIn('[Established usage]', text)


class NoLegendChunkedTransform(unittest.TestCase):
    """Chunked output without the legend: label spans stay, legend
    links go (issue #290)."""

    @classmethod
    def setUpClass(cls):
        cls.temporary, cls.out = run_chunked(BOOK_NO_LEGEND,
                                             'cll-status-nolegend-chunk-')

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def test_chunked_pages_have_labels_but_no_legend_links(self):
        labels = []
        for page in sorted(self.out.glob('*.html')):
            text = re.sub(r'<!DOCTYPE[^>]*>', '', page.read_text())
            doc = ET.fromstring(text)
            labels.extend(s for s in doc.iter(XHTML + 'span')
                          if s.get('class') == 'status-label')
            links = [a for a in doc.iter(XHTML + 'a')
                     if a.get('class') == 'status-legend-link']
            self.assertEqual(links, [], page.name)
        self.assertTrue(labels)
        self.assertIn('Approved by the BPFK, 2015-08-08',
                      [reader_text(label) for label in labels])


if __name__ == '__main__':
    unittest.main()
