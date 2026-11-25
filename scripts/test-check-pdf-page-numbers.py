#!/usr/bin/env python3
"""Unit tests for scripts/check-pdf-page-numbers.py (issue #344).

Covers:
1. Section target verification must match an actual section heading line on the
   destination page, not a prose cross-reference plus matching title words
   elsewhere on the page (both ToC-listed sections and deeper subsections).
2. ToC page discovery and printed-line counting must span the whole contents
   range independently of PDF link annotations, so a contents page that lost
   its links fails the check even in standalone mode (without companion HTML).
"""
import importlib.util
from pathlib import Path
import tempfile
import unittest

import pymupdf

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    'check_pdf_page_numbers', ROOT / 'scripts/check-pdf-page-numbers.py')
MOD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MOD)


def add_toc_line(page, y, text, dest_page_0based=None):
    """Draw a ToC line and optionally attach an internal link annotation."""
    page.insert_text((50, y), text, fontsize=9, fontname='helv')
    if dest_page_0based is not None:
        rect = pymupdf.Rect(48, y - 10, 400, y + 3)
        page.insert_link({
            'kind': pymupdf.LINK_GOTO,
            'from': rect,
            'page': dest_page_0based,
        })


def add_inline_xref(page, x, y, text, dest_page_0based):
    """Draw an inline '(p. N)' xref with a link annotation over its rect."""
    page.insert_text((x, y), text, fontsize=9, fontname='helv')
    width = pymupdf.get_text_length(text, fontname='helv', fontsize=9)
    rect = pymupdf.Rect(x - 1, y - 10, x + width + 1, y + 3)
    page.insert_link({
        'kind': pymupdf.LINK_GOTO,
        'from': rect,
        'page': dest_page_0based,
    })


def build_section_target_pdf(pdf_path, html_path, *, real_heading=True,
                             wrapped_heading=False, subsection_heading=True):
    """Build a small PDF with a ToC, Chapter 1, and inline section xrefs."""
    doc = pymupdf.open()
    for _ in range(4):
        doc.new_page(width=450, height=680)
    p1, p2, p3, p4 = doc[0], doc[1], doc[2], doc[3]

    # Page 1: Title page
    p1.insert_text((50, 120), 'Test Book', fontsize=18, fontname='hebo')

    # Page 2: Table of Contents (points to pages 3 and 4)
    p2.insert_text((50, 70), 'Table of Contents', fontsize=12, fontname='hebo')
    add_toc_line(p2, 95, '1. Introduction ....................................... 3', 2)
    add_toc_line(p2, 110, '1.1. First topic ...................................... 3', 2)
    add_toc_line(p2, 125, '1.2. Second topic details ............................. 4', 3)

    # Page 3: Chapter 1 + Section 1.1 + inline xrefs to Section 1.2 and 1.2.1
    p3.insert_text((50, 75), 'Chapter 1', fontsize=14, fontname='hebo')
    p3.insert_text((50, 95), 'Introduction', fontsize=14, fontname='hebo')
    p3.insert_text((50, 125), '1.1 First topic', fontsize=11, fontname='hebo')
    p3.insert_text((50, 145), 'See ', fontsize=9, fontname='helv')
    add_inline_xref(p3, 72, 145, 'Section 1.2 (p. 4)', 3)
    p3.insert_text((50, 165), 'Also see ', fontsize=9, fontname='helv')
    add_inline_xref(p3, 95, 165, 'Section 1.2.1 (p. 4)', 3)

    # Page 4: destination page for Section 1.2 and Section 1.2.1
    if real_heading:
        if wrapped_heading:
            p4.insert_text((50, 75), '1.2 Second', fontsize=11, fontname='hebo')
            p4.insert_text((50, 90), 'topic details', fontsize=11, fontname='hebo')
        else:
            p4.insert_text((50, 75), '1.2 Second topic details', fontsize=11, fontname='hebo')
        p4.insert_text((50, 115), 'Body text for section 1.2.', fontsize=9, fontname='helv')
    else:
        # No heading line for 1.2: only a prose cross-reference supplying "1.2"
        # and prose elsewhere containing the first words of the title.
        p4.insert_text((50, 75), '1.3 Unrelated heading', fontsize=11, fontname='hebo')
        p4.insert_text((50, 100), 'As noted earlier in Section 1.2 above, this differs.', fontsize=9, fontname='helv')
        p4.insert_text((50, 120), 'We discuss Second topic details in passing here.', fontsize=9, fontname='helv')

    if subsection_heading:
        p4.insert_text((50, 155), '1.2.1 Deeper subsection', fontsize=11, fontname='hebo')
        p4.insert_text((50, 175), 'Subsection prose.', fontsize=9, fontname='helv')
    else:
        # No heading line for 1.2.1: only prose containing the number.
        p4.insert_text((50, 155), 'Recall that 1.2.1 appears on another page.', fontsize=9, fontname='helv')

    doc.save(str(pdf_path))
    doc.close()

    html_path.write_text(
        '<html><body>'
        '<div class="toc"><ul>'
        '<li><a href="#ch1">1. Introduction</a></li>'
        '<li><a href="#s11">1.1. First topic</a></li>'
        '<li><a href="#s12">1.2. Second topic details</a></li>'
        '</ul></div>'
        '<p><a class="xref" href="#s12">Section 1.2</a>'
        '<a class="xref" href="#s121">Section 1.2.1</a></p>'
        '</body></html>',
        encoding='utf-8',
    )


def build_multipage_toc_pdf(pdf_path, *, drop_links_on_pages=(), blank_before_body=True):
    """Build a PDF with a 3-page ToC (pages 2..4) and optional blank page 5."""
    doc = pymupdf.open()
    body_start_0based = 5 if blank_before_body else 4
    total = body_start_0based + 3
    for _ in range(total):
        doc.new_page(width=450, height=680)
    p1, p2, p3, p4 = doc[0], doc[1], doc[2], doc[3]
    b1, b2, b3 = doc[body_start_0based], doc[body_start_0based + 1], doc[body_start_0based + 2]

    # Page 1: Title
    p1.insert_text((50, 120), 'Test Book', fontsize=18, fontname='hebo')

    # Pages 2..4: 3 ToC pages
    p2.insert_text((50, 70), 'Table of Contents', fontsize=12, fontname='hebo')
    add_toc_line(
        p2, 95, f'1. Introduction ............................... {body_start_0based + 1}',
        None if 2 in drop_links_on_pages else body_start_0based,
    )
    add_toc_line(
        p2, 110, f'1.1. First section ............................ {body_start_0based + 1}',
        None if 2 in drop_links_on_pages else body_start_0based,
    )

    add_toc_line(
        p3, 75, f'2. Second chapter ............................. {body_start_0based + 2}',
        None if 3 in drop_links_on_pages else body_start_0based + 1,
    )
    add_toc_line(
        p3, 90, f'2.1. Second section ........................... {body_start_0based + 2}',
        None if 3 in drop_links_on_pages else body_start_0based + 1,
    )

    add_toc_line(
        p4, 75, f'A. Appendix title ............................. {body_start_0based + 3}',
        None if 4 in drop_links_on_pages else body_start_0based + 2,
    )
    add_toc_line(
        p4, 90, f'General Index ................................. {body_start_0based + 3}',
        None if 4 in drop_links_on_pages else body_start_0based + 2,
    )

    # Body pages
    b1.insert_text((50, 75), 'Chapter 1', fontsize=14, fontname='hebo')
    b1.insert_text((50, 95), 'Introduction', fontsize=14, fontname='hebo')
    b1.insert_text((50, 125), '1.1 First section', fontsize=11, fontname='hebo')

    b2.insert_text((50, 75), 'Chapter 2', fontsize=14, fontname='hebo')
    b2.insert_text((50, 95), 'Second chapter', fontsize=14, fontname='hebo')
    b2.insert_text((50, 125), '2.1 Second section', fontsize=11, fontname='hebo')

    b3.insert_text((50, 75), 'Appendix A', fontsize=14, fontname='hebo')
    b3.insert_text((50, 95), 'Appendix title', fontsize=14, fontname='hebo')
    b3.insert_text((50, 125), 'General Index', fontsize=14, fontname='hebo')

    doc.save(str(pdf_path))
    doc.close()


class CheckPdfPageNumbersTests(unittest.TestCase):
    def test_real_section_and_subsection_headings_pass(self):
        with tempfile.TemporaryDirectory(prefix='cll-cpn-') as temp:
            pdf = Path(temp) / 'ok.pdf'
            html = Path(temp) / 'ok.html'
            build_section_target_pdf(pdf, html, real_heading=True, subsection_heading=True)
            self.assertEqual(MOD.check_pdf(str(pdf), html_path=str(html)), 0)

    def test_wrapped_section_heading_passes(self):
        with tempfile.TemporaryDirectory(prefix='cll-cpn-') as temp:
            pdf = Path(temp) / 'wrapped.pdf'
            html = Path(temp) / 'wrapped.html'
            build_section_target_pdf(pdf, html, real_heading=True, wrapped_heading=True)
            self.assertEqual(MOD.check_pdf(str(pdf), html_path=str(html)), 0)

    def test_prose_number_and_title_words_fail_section_target_check(self):
        # Issue #344: prose containing "Section 1.2" and the first title words
        # elsewhere on the page must not satisfy a section target check.
        with tempfile.TemporaryDirectory(prefix='cll-cpn-') as temp:
            pdf = Path(temp) / 'prose.pdf'
            html = Path(temp) / 'prose.html'
            build_section_target_pdf(pdf, html, real_heading=False, subsection_heading=True)
            self.assertEqual(MOD.check_pdf(str(pdf), html_path=str(html)), 1)

    def test_prose_subsection_number_fails_section_target_check(self):
        # Depth-3 subsection not in ToC: prose mentioning "1.2.1" must not pass.
        with tempfile.TemporaryDirectory(prefix='cll-cpn-') as temp:
            pdf = Path(temp) / 'sub.pdf'
            html = Path(temp) / 'sub.html'
            build_section_target_pdf(pdf, html, real_heading=True, subsection_heading=False)
            self.assertEqual(MOD.check_pdf(str(pdf), html_path=str(html)), 1)

    def test_toc_discovery_and_line_count_catch_last_page_without_links(self):
        # Issue #344: if the last ToC page loses its link annotations, page
        # discovery must still cover it so printed_toc_lines > len(toc_entries).
        with tempfile.TemporaryDirectory(prefix='cll-cpn-') as temp:
            pdf = Path(temp) / 'toc-last-unlinked.pdf'
            build_multipage_toc_pdf(pdf, drop_links_on_pages=(4,), blank_before_body=True)
            doc = pymupdf.open(str(pdf))
            try:
                toc_pages = MOD.find_toc_pages(doc)
                printed = MOD.count_printed_toc_lines(doc, toc_pages)
                entries = MOD.extract_toc_entries(doc, toc_pages)
            finally:
                doc.close()
            self.assertEqual(toc_pages, [2, 3, 4])
            self.assertEqual(printed, 6)
            self.assertEqual(len(entries), 4)
            self.assertNotEqual(len(entries), printed)

    def test_toc_discovery_catches_middle_page_without_links(self):
        with tempfile.TemporaryDirectory(prefix='cll-cpn-') as temp:
            pdf = Path(temp) / 'toc-mid-unlinked.pdf'
            build_multipage_toc_pdf(pdf, drop_links_on_pages=(3,), blank_before_body=False)
            doc = pymupdf.open(str(pdf))
            try:
                toc_pages = MOD.find_toc_pages(doc)
                printed = MOD.count_printed_toc_lines(doc, toc_pages)
                entries = MOD.extract_toc_entries(doc, toc_pages)
            finally:
                doc.close()
            self.assertEqual(toc_pages, [2, 3, 4])
            self.assertEqual(printed, 6)
            self.assertEqual(len(entries), 4)

    def test_toc_discovery_all_links_intact_matches_printed_lines(self):
        with tempfile.TemporaryDirectory(prefix='cll-cpn-') as temp:
            pdf = Path(temp) / 'toc-ok.pdf'
            build_multipage_toc_pdf(pdf, drop_links_on_pages=(), blank_before_body=True)
            doc = pymupdf.open(str(pdf))
            try:
                toc_pages = MOD.find_toc_pages(doc)
                printed = MOD.count_printed_toc_lines(doc, toc_pages)
                entries = MOD.extract_toc_entries(doc, toc_pages)
            finally:
                doc.close()
            self.assertEqual(toc_pages, [2, 3, 4])
            self.assertEqual(printed, 6)
            self.assertEqual(len(entries), 6)

    def test_toc_all_pages_unlinked_fails_cleanly(self):
        with tempfile.TemporaryDirectory(prefix='cll-cpn-') as temp:
            pdf = Path(temp) / 'toc-none-linked.pdf'
            build_multipage_toc_pdf(pdf, drop_links_on_pages=(2, 3, 4), blank_before_body=True)
            doc = pymupdf.open(str(pdf))
            try:
                toc_pages = MOD.find_toc_pages(doc)
                printed = MOD.count_printed_toc_lines(doc, toc_pages)
                entries = MOD.extract_toc_entries(doc, toc_pages)
            finally:
                doc.close()
            self.assertEqual(toc_pages, [2, 3, 4])
            self.assertEqual(printed, 6)
            self.assertEqual(len(entries), 0)
            self.assertEqual(MOD.check_pdf(str(pdf)), 1)


if __name__ == '__main__':
    unittest.main()
