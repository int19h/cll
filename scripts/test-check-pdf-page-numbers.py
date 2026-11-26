#!/usr/bin/env python3
"""Unit tests for scripts/check-pdf-page-numbers.py (issues #344, #348).

Covers:
1. Exact heading/caption/rule line matching for every target kind: chapters,
   appendices, sections (and subsections), unnumbered headings, examples,
   tables, figures (including appendix-lettered Example/Table/Figure A.1),
   selma'o headings, and BNF rules — never matching prose anywhere on the page.
2. Small non-bold spans on a heading or caption line do not hide the heading,
   while prose lines starting with a single bold word stay rejected.
3. ToC page discovery scans to the detected body start (beyond 25 pages)
   independently of PDF link annotations, and check_pdf() itself fails
   end-to-end when a contents page loses its links (with or without HTML).
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


def build_multipage_toc_pdf(pdf_path, html_path=None, *, drop_links_on_pages=(),
                            blank_before_body=True):
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

    if html_path is not None:
        html_path.write_text(
            '<html><body>'
            '<div class="toc"><ul>'
            '<li><a href="#ch1">1. Introduction</a></li>'
            '<li><a href="#s11">1.1. First section</a></li>'
            '<li><a href="#ch2">2. Second chapter</a></li>'
            '<li><a href="#s21">2.1. Second section</a></li>'
            '<li><a href="#appA">A. Appendix title</a></li>'
            '<li><a href="#idx">General Index</a></li>'
            '</ul></div>'
            '</body></html>',
            encoding='utf-8',
        )


def build_all_targets_pdf(pdf_path, html_path, *,
                          chapter_real=True, appendix_real=True, unnumbered_real=True,
                          example_a_real=True, table_a_real=True, figure_a_real=True,
                          bnf_real=True, nonbold_span_heading=False,
                          prose_bold_lead=False):
    """Build a synthetic PDF exercising every target kind and span shape."""
    doc = pymupdf.open()
    for _ in range(5):
        doc.new_page(width=450, height=680)
    p1, p2, p3, p4, p5 = doc[0], doc[1], doc[2], doc[3], doc[4]

    # Page 1: Title
    p1.insert_text((50, 120), 'Test Book', fontsize=18, fontname='hebo')

    # Page 2: ToC
    p2.insert_text((50, 70), 'Table of Contents', fontsize=12, fontname='hebo')
    add_toc_line(p2, 95, '1. Introduction ....................................... 3', 2)
    add_toc_line(p2, 110, '1.1. Subscript x1 place ............................... 3', 2)
    add_toc_line(p2, 125, 'A. Chrestomathy ....................................... 4', 3)
    add_toc_line(p2, 140, 'General Index ......................................... 5', 4)

    # Page 3: Chapter 1, Section 1.1, and inline xrefs to all target kinds
    if chapter_real:
        p3.insert_text((50, 75), 'Chapter 1', fontsize=14, fontname='hebo')
        p3.insert_text((50, 95), 'Introduction', fontsize=14, fontname='hebo')
    elif prose_bold_lead:
        p3.insert_text((50, 75), 'Chapter 1', fontsize=9, fontname='hebo')
        w = pymupdf.get_text_length('Chapter 1', fontname='hebo', fontsize=9)
        p3.insert_text((50 + w + 3, 75), 'Introduction is discussed in regular prose here.', fontsize=9, fontname='helv')
    else:
        p3.insert_text((50, 75), 'Recall Chapter 1 and its Introduction from earlier.', fontsize=9, fontname='helv')

    if nonbold_span_heading:
        # Heading line with a small non-bold subscript span in the middle
        p3.insert_text((50, 125), '1.1 Subscript x', fontsize=11, fontname='hebo')
        w1 = pymupdf.get_text_length('1.1 Subscript x', fontname='hebo', fontsize=11)
        p3.insert_text((50 + w1, 127), '1', fontsize=7, fontname='helv')
        w2 = pymupdf.get_text_length('1', fontname='helv', fontsize=7)
        p3.insert_text((50 + w1 + w2 + 2, 125), 'place', fontsize=11, fontname='hebo')
    else:
        p3.insert_text((50, 125), '1.1 Subscript x1 place', fontsize=11, fontname='hebo')

    add_inline_xref(p3, 50, 150, 'Chapter 1 (p. 3)', 2)
    add_inline_xref(p3, 50, 168, 'Appendix A (p. 4)', 3)
    add_inline_xref(p3, 50, 186, 'Example A.1 (p. 4)', 3)
    add_inline_xref(p3, 50, 204, 'Table A.1 (p. 4)', 3)
    add_inline_xref(p3, 50, 222, 'Figure A.1 (p. 4)', 3)
    add_inline_xref(p3, 50, 240, 'BNF rule #10 (p. 5)', 4)
    add_inline_xref(p3, 50, 258, 'BAI (p. 5)', 4)

    # Page 4: Appendix A + Example A.1 + Table A.1 + Figure A.1
    if appendix_real:
        p4.insert_text((50, 75), 'Appendix A', fontsize=14, fontname='hebo')
        p4.insert_text((50, 95), 'Chrestomathy', fontsize=14, fontname='hebo')
    else:
        p4.insert_text((50, 75), 'See Appendix A for the Chrestomathy texts.', fontsize=9, fontname='helv')

    if example_a_real:
        if nonbold_span_heading:
            p4.insert_text((50, 125), 'Example A.1 x', fontsize=9, fontname='hebo')
            w = pymupdf.get_text_length('Example A.1 x', fontname='hebo', fontsize=9)
            p4.insert_text((50 + w, 127), '1', fontsize=6.5, fontname='helv')
        else:
            p4.insert_text((50, 125), 'Example A.1', fontsize=9, fontname='hebo')
    else:
        p4.insert_text((50, 125), 'Prose mentioning Example A.1 in passing.', fontsize=9, fontname='helv')

    if table_a_real:
        p4.insert_text((50, 150), 'Table A.1. Parallel summary', fontsize=9, fontname='hebo')
    else:
        p4.insert_text((50, 150), 'Table A.1 shows the summary in prose only.', fontsize=9, fontname='helv')

    if figure_a_real:
        p4.insert_text((50, 175), 'Figure A.1. Sample diagram', fontsize=9, fontname='hebo')
    else:
        p4.insert_text((50, 175), 'Figure A.1 illustrates the diagram in prose only.', fontsize=9, fontname='helv')

    # Page 5: General Index + BNF rule #10 + selma'o BAI
    if unnumbered_real:
        p5.insert_text((50, 75), 'General Index', fontsize=14, fontname='hebo')
    else:
        p5.insert_text((50, 75), 'Refer to the General Index at the back.', fontsize=9, fontname='helv')

    if bnf_real:
        p5.insert_text((50, 110), 'paragraph ', fontsize=9, fontname='helv')
        w1 = pymupdf.get_text_length('paragraph ', fontname='helv', fontsize=9)
        p5.insert_text((50 + w1, 112), '10', fontsize=7, fontname='helv')
        w2 = pymupdf.get_text_length('10', fontname='helv', fontsize=7)
        p5.insert_text((50 + w1 + w2, 110), ' = statement', fontsize=9, fontname='helv')
    else:
        p5.insert_text((50, 110), 'In arithmetic, 10 = 5 + 5 is always true.', fontsize=9, fontname='helv')

    p5.insert_text((50, 145), "selma'o BAI (Section 1.1)", fontsize=14, fontname='hebo')

    doc.save(str(pdf_path))
    doc.close()

    html_path.write_text(
        '<html><body>'
        '<div class="toc"><ul>'
        '<li><a href="#ch1">1. Introduction</a></li>'
        '<li><a href="#s11">1.1. Subscript x1 place</a></li>'
        '<li><a href="#appA">A. Chrestomathy</a></li>'
        '<li><a href="#idx">General Index</a></li>'
        '</ul></div>'
        '<p>'
        '<a class="xref" href="#ch1">Chapter 1</a>'
        '<a class="xref" href="#appA">Appendix A</a>'
        '<a class="xref" href="#exA1">Example A.1</a>'
        '<a class="xref" href="#tblA1">Table A.1</a>'
        '<a class="xref" href="#figA1">Figure A.1</a>'
        '<a class="xref" href="#bnf10">BNF rule #10</a>'
        '<a class="xref" href="#BAI">BAI</a>'
        '</p>'
        '</body></html>',
        encoding='utf-8',
    )


def build_long_toc_pdf(pdf_path, html_path, *, toc_page_count=27, drop_last_links=False):
    """Build a PDF whose ToC exceeds the old 25-page cap."""
    doc = pymupdf.open()
    body_page_0based = 1 + toc_page_count  # Page 1 title, pages 2..toc_page_count+1 ToC
    for _ in range(body_page_0based + 1):
        doc.new_page(width=450, height=680)
    doc[0].insert_text((50, 120), 'Long ToC Book', fontsize=18, fontname='hebo')

    html_toc_items = []
    for idx in range(toc_page_count):
        page = doc[1 + idx]
        y = 95 if idx == 0 else 75
        if idx == 0:
            page.insert_text((50, 70), 'Table of Contents', fontsize=12, fontname='hebo')
        is_last = (idx == toc_page_count - 1)
        dest = None if (drop_last_links and is_last) else body_page_0based
        if idx == 0:
            label = f'1. Introduction ............................... {body_page_0based + 1}'
            html_toc_items.append('<li><a href="#ch1">1. Introduction</a></li>')
        else:
            label = f'1.{idx}. Section {idx} .......................... {body_page_0based + 1}'
            html_toc_items.append(f'<li><a href="#s1_{idx}">1.{idx}. Section {idx}</a></li>')
        add_toc_line(page, y, label, dest)

    body = doc[body_page_0based]
    body.insert_text((50, 75), 'Chapter 1', fontsize=14, fontname='hebo')
    body.insert_text((50, 95), 'Introduction', fontsize=14, fontname='hebo')
    for idx in range(1, toc_page_count):
        body.insert_text((50, 115 + idx * 15), f'1.{idx} Section {idx}', fontsize=11, fontname='hebo')

    doc.save(str(pdf_path))
    doc.close()

    html_path.write_text(
        '<html><body><div class="toc"><ul>'
        + ''.join(html_toc_items)
        + '</ul></div></body></html>',
        encoding='utf-8',
    )


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

    def test_check_pdf_end_to_end_fails_when_toc_page_loses_links_with_html(self):
        # Issue #348: end-to-end check_pdf() with companion HTML passes when
        # all ToC links are intact and fails when a ToC page loses its links.
        with tempfile.TemporaryDirectory(prefix='cll-cpn-') as temp:
            ok_pdf = Path(temp) / 'toc-ok.pdf'
            ok_html = Path(temp) / 'toc-ok.html'
            build_multipage_toc_pdf(ok_pdf, ok_html, drop_links_on_pages=(), blank_before_body=True)
            self.assertEqual(MOD.check_pdf(str(ok_pdf), html_path=str(ok_html)), 0)

            bad_pdf = Path(temp) / 'toc-lost-last.pdf'
            bad_html = Path(temp) / 'toc-lost-last.html'
            build_multipage_toc_pdf(bad_pdf, bad_html, drop_links_on_pages=(4,), blank_before_body=True)
            self.assertEqual(MOD.check_pdf(str(bad_pdf), html_path=str(bad_html)), 1)

            mid_pdf = Path(temp) / 'toc-lost-mid.pdf'
            mid_html = Path(temp) / 'toc-lost-mid.html'
            build_multipage_toc_pdf(mid_pdf, mid_html, drop_links_on_pages=(3,), blank_before_body=False)
            self.assertEqual(MOD.check_pdf(str(mid_pdf), html_path=str(mid_html)), 1)

    def test_all_target_kinds_and_appendix_labels_pass_on_real_lines(self):
        with tempfile.TemporaryDirectory(prefix='cll-cpn-') as temp:
            pdf = Path(temp) / 'all-ok.pdf'
            html = Path(temp) / 'all-ok.html'
            build_all_targets_pdf(pdf, html)
            self.assertEqual(MOD.check_pdf(str(pdf), html_path=str(html)), 0)

    def test_small_nonbold_span_does_not_hide_heading_or_caption(self):
        with tempfile.TemporaryDirectory(prefix='cll-cpn-') as temp:
            pdf = Path(temp) / 'nonbold-span.pdf'
            html = Path(temp) / 'nonbold-span.html'
            build_all_targets_pdf(pdf, html, nonbold_span_heading=True)
            self.assertEqual(MOD.check_pdf(str(pdf), html_path=str(html)), 0)

    def test_prose_never_satisfies_chapter_appendix_caption_or_bnf_targets(self):
        # Every target kind must match its own heading/caption/rule line.
        for kw in (
            {'chapter_real': False},
            {'chapter_real': False, 'prose_bold_lead': True},
            {'appendix_real': False},
            {'unnumbered_real': False},
            {'example_a_real': False},
            {'table_a_real': False},
            {'figure_a_real': False},
            {'bnf_real': False},
        ):
            with self.subTest(case=kw):
                with tempfile.TemporaryDirectory(prefix='cll-cpn-') as temp:
                    pdf = Path(temp) / 'fail.pdf'
                    html = Path(temp) / 'fail.html'
                    build_all_targets_pdf(pdf, html, **kw)
                    self.assertEqual(MOD.check_pdf(str(pdf), html_path=str(html)), 1)

    def test_parse_inline_xref_target_covers_appendix_letters_and_not_aa(self):
        self.assertEqual(MOD.parse_inline_xref_target('Example A.1 (p. 4)'), ('example', 'Example A.1'))
        self.assertEqual(MOD.parse_inline_xref_target('Table A.1 (p. 4)'), ('titled', 'Table A.1'))
        self.assertEqual(MOD.parse_inline_xref_target('Figure A.1 (p. 4)'), ('titled', 'Figure A.1'))
        self.assertEqual(MOD.parse_inline_xref_target('Section A.1 (p. 4)'), ('section', 'A.1'))
        self.assertEqual(MOD.parse_inline_xref_target('Appendix A (p. 4)'), ('appendix', 'Appendix A'))
        # Maintainer decision: appendix labels past Z (AA forms) are not supported.
        self.assertEqual(MOD.parse_inline_xref_target('Example AA.1 (p. 4)')[0], 'unknown')
        self.assertEqual(MOD.parse_inline_xref_target('Table AA.1 (p. 4)')[0], 'unknown')
        self.assertEqual(MOD.parse_inline_xref_target('Figure AA.1 (p. 4)')[0], 'unknown')
        self.assertEqual(MOD.parse_inline_xref_target('Appendix AA (p. 4)')[0], 'unknown')

    def test_toc_discovery_scans_past_25_pages_to_body_start(self):
        with tempfile.TemporaryDirectory(prefix='cll-cpn-') as temp:
            pdf = Path(temp) / 'long-toc.pdf'
            html = Path(temp) / 'long-toc.html'
            build_long_toc_pdf(pdf, html, toc_page_count=27, drop_last_links=False)
            doc = pymupdf.open(str(pdf))
            try:
                toc_pages = MOD.find_toc_pages(doc)
            finally:
                doc.close()
            self.assertEqual(toc_pages, list(range(2, 29)))
            self.assertEqual(MOD.check_pdf(str(pdf), html_path=str(html)), 0)

            bad_pdf = Path(temp) / 'long-toc-bad.pdf'
            bad_html = Path(temp) / 'long-toc-bad.html'
            build_long_toc_pdf(bad_pdf, bad_html, toc_page_count=27, drop_last_links=True)
            self.assertEqual(MOD.check_pdf(str(bad_pdf), html_path=str(bad_html)), 1)


if __name__ == '__main__':
    unittest.main()
