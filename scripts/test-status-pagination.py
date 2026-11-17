#!/usr/bin/env python3
"""A status note's label stays with the start of its prose in print.

Regression for issue #47 review R1: in the Prince build, the label of
the diphthong note stood alone at the foot of page 20 while its
also-line and prose began on page 21. The fixture sweeps a spacer in
front of an otherwise identical note over a whole page height, so one
case always lands on the boundary that stranded the label, whatever
the engine's exact metrics. A note taller than a page must still
break (the rule keeps the label with the start, not the whole note
on one page at any cost).

Per-page text comes from pdftotext (poppler-utils) for both engines.
The Prince check runs when the prince binary is available, following
scripts/test-pdf-bookmarks.py.
"""
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CASES = 15
LONG_START = 'LongProseStart'
LONG_END = 'LongProseEnd'


def note_html(start, words):
    return (
        '<p class="status-note status-de-facto" data-status="de-facto">'
        '<span class="status-label"><a class="status-legend-link" '
        'href="#status-legend">Established usage</a></span> '
        '<span class="status-also">also: Approved by the BPFK</span>'
        f'{start} ' + ' '.join(['word'] * words) + '.</p>')


def write_fixture(directory, stylesheets):
    links = '\n'.join(
        f'<link rel="stylesheet" href="{path.resolve().as_uri()}">'
        for path in stylesheets)
    cases = []
    for i in range(CASES):
        cases.append(
            f'<div class="case"><div style="height: {i * 4}mm"></div>'
            + note_html(f'ProseStart{i}', 40) + '</div>')
    long_note = (
        '<div class="case">'
        + note_html(LONG_START, 900)[:-5] + f' {LONG_END}.</p></div>')
    html_path = directory / 'fixture.html'
    html_path.write_text(f'''<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
{links}
<style>
@page {{ size: 100mm 80mm; margin: 10mm; }}
body {{ font-family: "DejaVu Serif", serif; font-size: 10pt;
        line-height: 14pt; }}
p {{ margin: 0; }}
.case {{ break-before: page; }}
</style>
</head>
<body>
{''.join(cases)}
{long_note}
</body>
</html>
''')
    return html_path


def assert_labels_attached(test, pages):
    """pages: one text string per rendered page, in order.

    Small caps extract differently per engine ("ESTABLISHED USAGE",
    "EstablishEd usagE"), so compare case-folded throughout."""
    pages = [text.lower() for text in pages]
    test.assertTrue(pages, 'no pages rendered')
    for i in range(CASES):
        token = f'ProseStart{i}'.lower()
        starts = [n for n, text in enumerate(pages) if token in text]
        test.assertTrue(starts, f'{token} missing from every page')
        page = pages[starts[0]]
        test.assertIn('established usage', page,
                      f'case {i}: label not on the page where its prose '
                      f'begins (page {starts[0] + 1})')
        test.assertIn('also:', page,
                      f'case {i}: also-line not on the page where its '
                      f'prose begins (page {starts[0] + 1})')
    long_starts = [n for n, text in enumerate(pages) if LONG_START.lower() in text]
    long_ends = [n for n, text in enumerate(pages) if LONG_END.lower() in text]
    test.assertTrue(long_starts and long_ends, 'long note text missing')
    test.assertIn('established usage', pages[long_starts[0]],
                  'long note: label not on its first page')
    test.assertGreater(long_ends[0], long_starts[0],
                       'long note did not break across pages; the '
                       'fixture no longer exceeds one page')


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


class StatusPaginationTests(unittest.TestCase):
    def test_one_pdf_engine_is_available(self):
        if weasyprint_html() is None and shutil.which('prince') is None:
            self.fail('Install WeasyPrint or Prince to check status-note '
                      'pagination')

    def test_weasyprint_label_stays_with_prose_start(self):
        HTML = weasyprint_html()
        if HTML is None:
            self.skipTest('WeasyPrint is not installed')
        with tempfile.TemporaryDirectory(prefix='cll-status-pages-') as temp:
            directory = Path(temp)
            html_path = write_fixture(directory, [
                ROOT / 'assets/css/master.css',
                ROOT / 'assets/css/weasyprint.css',
            ])
            pdf_path = directory / 'fixture.pdf'
            HTML(filename=str(html_path)).write_pdf(str(pdf_path))
            pages = pdf_pages(self, pdf_path)
        assert_labels_attached(self, pages)

    @unittest.skipUnless(shutil.which('prince'), 'Prince is not installed')
    def test_prince_label_stays_with_prose_start(self):
        with tempfile.TemporaryDirectory(prefix='cll-status-pages-') as temp:
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
        assert_labels_attached(self, pages)


if __name__ == '__main__':
    unittest.main()
