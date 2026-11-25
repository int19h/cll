#!/usr/bin/env python3
"""Section headings with table lead-ins, marker headings, and examples stay attached.

Regression for issue #333:
- A section heading followed by a lead-in paragraph ("The following cmavo are
  discussed in this section:") and an unbreakable div.informaltable (cmavo-list)
  must not strand the heading and lead-in at the foot of a page while the table
  moves to the next page.
- A paragraph introducing a div.table must stay with the table.
- A section heading followed by empty styling-marker paragraphs (p.twocolumn,
  p.allowbreaks) and a table (as in Section 17.16) must not strand the heading.
- A paragraph introducing a div.example (p + div.example) or a list item
  introducing a div.example (div.itemizedlist + div.example, as in Examples
  17.34-17.39) must stay with the example, and the example itself must stay
  unbreakable.

Every sweep group in this file fails against origin/main's CSS in WeasyPrint
and passes with the fix. Sweeps a spacer across a page height so one case
always lands on the boundary, for both WeasyPrint and Prince (when installed).
"""
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CASES = 15


def write_fixture(directory, stylesheets):
    links = '\n'.join(
        f'<link rel="stylesheet" href="{path.resolve().as_uri()}">'
        for path in stylesheets)
    blocks = []

    # 1. Section heading + one-line lead-in + unbreakable cmavo informaltable
    # (issue #333 reported shape: 22.5, 22.6, 22.10, 18.8).
    for i in range(CASES):
        head_tok = f'CmavoHead{i}'
        lead_tok = f'CmavoLead{i}:'
        row_start = f'CmavoRowStart{i}'
        row_end = f'CmavoRowEnd{i}'
        blocks.append(
            f'<div class="case"><div style="height: {i * 4}mm"></div>'
            f'<section class="section">'
            f'<div class="titlepage"><div><div>'
            f'<h2 class="title" style="clear: both">{head_tok}</h2>'
            f'</div></div></div>'
            f'<p>The following cmavo are discussed in this section {lead_tok}</p>'
            f'<div class="informaltable"><table class="cmavo-list">'
            f'<tr><td>{row_start}</td><td>PA*</td><td>first row</td></tr>'
            f'<tr><td>cmavo2</td><td>PA*</td><td>second row</td></tr>'
            f'<tr><td>cmavo3</td><td>PA*</td><td>third row</td></tr>'
            f'<tr><td>{row_end}</td><td>PA*</td><td>fourth row</td></tr>'
            f'</table></div></section></div>')

    # 2. Lead-in paragraph + formal div.table.
    for i in range(CASES):
        lead_tok = f'TableLead{i}:'
        tbl_start = f'TableStart{i}'
        tbl_end = f'TableEnd{i}'
        blocks.append(
            f'<div class="case"><div style="height: {i * 4}mm"></div>'
            f'<p>Introductory text leading into the formal table {lead_tok}</p>'
            f'<div class="table"><div class="table-title">{tbl_start}</div>'
            f'<div class="table-contents"><table>'
            f'<tr><td>r1</td><td>val1</td></tr>'
            f'<tr><td>r2</td><td>val2</td></tr>'
            f'<tr><td>r3</td><td>{tbl_end}</td></tr>'
            f'</table></div></div></div>')

    # 3. Section heading + empty styling markers (p.twocolumn + p.allowbreaks)
    # + informaltable (Section 17.16 shape).
    for i in range(CASES):
        head_tok = f'MarkerHead{i}'
        row_tok = f'MarkerRow{i}'
        blocks.append(
            f'<div class="case"><div style="height: {i * 4}mm"></div>'
            f'<section class="section">'
            f'<div class="titlepage"><div><div>'
            f'<h2 class="title" style="clear: both">{head_tok}</h2>'
            f'</div></div></div>'
            f'<p class="twocolumn"></p><p class="allowbreaks"></p>'
            f'<div class="informaltable"><table>'
            f'<tr><td>{row_tok}</td><td>alpha</td></tr>'
            f'<tr><td>row2</td><td>beta</td></tr>'
            f'<tr><td>row3</td><td>gamma</td></tr>'
            f'</table></div></section></div>')

    # 4. Paragraph + unbreakable div.example.
    for i in range(CASES):
        lead_tok = f'LeadEnd{i}:'
        ex_tok = f'ExStart{i}'
        ex_end = f'ExEnd{i}'
        blocks.append(
            f'<div class="case"><div style="height: {i * 4}mm"></div>'
            f'<p>Introductory paragraph text leading into the example {lead_tok}</p>'
            f'<div class="example"><div class="example-title">{ex_tok}</div>'
            f'<div class="example-contents"><p>line a<br>line b<br>{ex_end}</p></div>'
            f'</div></div>')

    # 5. List-wrapped lead-in + unbreakable div.example (Examples 17.34-17.39 shape).
    for i in range(CASES):
        lead_tok = f'ListLead{i}:'
        ex_tok = f'ListExStart{i}'
        ex_end = f'ListExEnd{i}'
        blocks.append(
            f'<div class="case"><div style="height: {i * 4}mm"></div>'
            f'<div class="itemizedlist"><ul class="itemizedlist"><li>'
            f'<p>A lerfu string in a one-item list introducing {lead_tok}</p>'
            f'</li></ul></div>'
            f'<div class="example"><div class="example-title">{ex_tok}</div>'
            f'<div class="example-contents"><p>line a<br>line b<br>{ex_end}</p></div>'
            f'</div></div>')

    html_path = directory / 'fixture.html'
    html_path.write_text(f'''<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
{links}
<style>
@page {{ size: 100mm 75mm; margin: 10mm; }}
body {{ font-family: "DejaVu Serif", serif; font-size: 9pt; line-height: 11pt; }}
.case {{ break-before: page; page-break-before: always; }}
</style>
</head>
<body>
{''.join(blocks)}
</body>
</html>
''')
    return html_path


def find_page(test, pages, token):
    hits = [idx for idx, text in enumerate(pages) if token in text]
    test.assertTrue(hits, f'{token} missing from rendered PDF')
    return hits[0]


def assert_pagination(test, pages):
    test.assertTrue(pages, 'no pages rendered')
    for i in range(CASES):
        hp = find_page(test, pages, f'CmavoHead{i}')
        lp = find_page(test, pages, f'CmavoLead{i}:')
        rs = find_page(test, pages, f'CmavoRowStart{i}')
        re_ = find_page(test, pages, f'CmavoRowEnd{i}')
        test.assertEqual(
            hp, lp,
            f'cmavo-heading case {i}: heading on p.{hp + 1}, lead-in on p.{lp + 1}')
        test.assertEqual(
            lp, rs,
            f'cmavo-heading case {i}: heading+lead-in stranded on p.{lp + 1} '
            f'while cmavo table starts on p.{rs + 1}')
        test.assertEqual(
            rs, re_,
            f'cmavo-heading case {i}: cmavo table broke across pp.{rs + 1}..{re_ + 1}')
    for i in range(CASES):
        lp = find_page(test, pages, f'TableLead{i}:')
        ts = find_page(test, pages, f'TableStart{i}')
        te = find_page(test, pages, f'TableEnd{i}')
        test.assertEqual(
            lp, ts,
            f'formal-table case {i}: lead-in ends on p.{lp + 1} '
            f'while table starts on p.{ts + 1}')
        test.assertEqual(
            ts, te,
            f'formal-table case {i}: table broke across pp.{ts + 1}..{te + 1}')
    for i in range(CASES):
        hp = find_page(test, pages, f'MarkerHead{i}')
        rp = find_page(test, pages, f'MarkerRow{i}')
        test.assertEqual(
            hp, rp,
            f'marker-heading case {i}: heading stranded on p.{hp + 1} '
            f'while its table starts on p.{rp + 1}')
    for i in range(CASES):
        lp = find_page(test, pages, f'LeadEnd{i}:')
        ep = find_page(test, pages, f'ExStart{i}')
        ee = find_page(test, pages, f'ExEnd{i}')
        test.assertEqual(
            lp, ep,
            f'example case {i}: lead-in ends on p.{lp + 1} '
            f'while example starts on p.{ep + 1}')
        test.assertEqual(
            ep, ee,
            f'example case {i}: example broke across pp.{ep + 1}..{ee + 1}')
    for i in range(CASES):
        lp = find_page(test, pages, f'ListLead{i}:')
        ep = find_page(test, pages, f'ListExStart{i}')
        ee = find_page(test, pages, f'ListExEnd{i}')
        test.assertEqual(
            lp, ep,
            f'list-example case {i}: list lead-in ends on p.{lp + 1} '
            f'while example starts on p.{ep + 1}')
        test.assertEqual(
            ep, ee,
            f'list-example case {i}: example broke across pp.{ep + 1}..{ee + 1}')


def weasyprint_html():
    try:
        from weasyprint import HTML
    except ImportError:
        return None
    return HTML


def pdf_pages(test, pdf_path):
    pdftotext = shutil.which('pdftotext')
    if pdftotext is None:
        test.skipTest('pdftotext (poppler-utils) is not installed')
    result = subprocess.run(
        [pdftotext, str(pdf_path), '-'],
        check=False, capture_output=True, text=True)
    if result.returncode != 0:
        test.fail(result.stderr or result.stdout)
    return result.stdout.split('\f')


def weasyprint_pages(document):
    """Extract per-page text directly from a rendered WeasyPrint Document."""
    pages = []
    for page in document.pages:
        parts = []

        def walk(box):
            text = getattr(box, 'text', None)
            if text:
                parts.append(text)
            for child in getattr(box, 'children', ()):
                walk(child)

        walk(page._page_box)
        pages.append(' '.join(parts))
    return pages


class PrintPaginationTests(unittest.TestCase):
    def test_one_pdf_engine_is_available(self):
        if weasyprint_html() is None and shutil.which('prince') is None:
            self.fail('Install WeasyPrint or Prince to check print pagination')

    def test_weasyprint_headings_and_examples(self):
        HTML = weasyprint_html()
        if HTML is None:
            self.skipTest('WeasyPrint is not installed')
        with tempfile.TemporaryDirectory(prefix='cll-print-pages-') as temp:
            directory = Path(temp)
            html_path = write_fixture(directory, [
                ROOT / 'assets/css/master.css',
                ROOT / 'assets/css/weasyprint.css',
            ])
            document = HTML(filename=str(html_path)).render()
            if shutil.which('pdftotext'):
                pdf_path = directory / 'fixture.pdf'
                document.write_pdf(str(pdf_path))
                pages = pdf_pages(self, pdf_path)
            else:
                pages = weasyprint_pages(document)
        assert_pagination(self, pages)

    @unittest.skipUnless(shutil.which('prince'), 'Prince is not installed')
    def test_prince_headings_and_examples(self):
        with tempfile.TemporaryDirectory(prefix='cll-print-pages-') as temp:
            directory = Path(temp)
            html_path = write_fixture(directory, [
                ROOT / 'assets/css/master.css',
                ROOT / 'assets/css/prince.css',
            ])
            pdf_path = directory / 'fixture.pdf'
            result = subprocess.run(
                ['prince', '--no-network', str(html_path), '-o', str(pdf_path)],
                check=False, capture_output=True, text=True)
            if result.returncode != 0:
                self.fail(result.stderr or result.stdout)
            pages = pdf_pages(self, pdf_path)
        assert_pagination(self, pages)


if __name__ == '__main__':
    unittest.main()
