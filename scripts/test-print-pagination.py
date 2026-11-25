#!/usr/bin/env python3
"""Section headings stay with their content and examples stay with lead-ins.

Regression for issue #333:
- Section headings (h2..h6 and section.section > div.titlepage) must not be
  stranded at the foot of a page away from their following content.
- An example (div.example) following a paragraph (p + div.example) must not
  start a new page while the paragraph that introduces it ends the previous
  page, and the example itself must not split across pages.

Sweeps a spacer across a page height so one case always lands on the boundary,
for both WeasyPrint and Prince (when prince is installed).
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
    # Sweep h2 (inside DocBook section > div.titlepage), h3, h4, h5, h6.
    for level in (2, 3, 4, 5, 6):
        for i in range(CASES):
            head_tok = f'HeadL{level}Case{i}'
            body_tok = f'BodyL{level}Case{i}'
            if level == 2:
                inner = (
                    f'<section class="section">'
                    f'<div class="titlepage"><div><div>'
                    f'<h2 class="title" style="clear: both">{head_tok}</h2>'
                    f'</div></div></div>'
                    f'<p>{body_tok} line one.<br>line two.<br>line three.</p>'
                    f'</section>')
            else:
                inner = (
                    f'<h{level}>{head_tok}</h{level}>'
                    f'<p>{body_tok} line one.<br>line two.<br>line three.</p>')
            blocks.append(
                f'<div class="case"><div style="height: {i * 4}mm"></div>'
                f'{inner}</div>')

    # Sweep section heading followed by empty styling markers (p.twocolumn +
    # p.allowbreaks) and a table, as in Section 17.16.
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

    # Sweep p + div.example across page boundaries.
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
    for level in (2, 3, 4, 5, 6):
        for i in range(CASES):
            hp = find_page(test, pages, f'HeadL{level}Case{i}')
            bp = find_page(test, pages, f'BodyL{level}Case{i}')
            test.assertEqual(
                hp, bp,
                f'h{level} case {i}: heading stranded on page {hp + 1} '
                f'while its content starts on page {bp + 1}')
    for i in range(CASES):
        hp = find_page(test, pages, f'MarkerHead{i}')
        rp = find_page(test, pages, f'MarkerRow{i}')
        test.assertEqual(
            hp, rp,
            f'marker-heading case {i}: heading stranded on page {hp + 1} '
            f'while its table starts on page {rp + 1}')
    for i in range(CASES):
        lp = find_page(test, pages, f'LeadEnd{i}:')
        ep = find_page(test, pages, f'ExStart{i}')
        ee = find_page(test, pages, f'ExEnd{i}')
        test.assertEqual(
            lp, ep,
            f'example case {i}: lead-in ends on page {lp + 1} '
            f'while example starts on page {ep + 1}')
        test.assertEqual(
            ep, ee,
            f'example case {i}: example broke across pages {ep + 1}..{ee + 1}')


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
