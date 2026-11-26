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
import contextlib
import importlib.util
import io
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
        '<h1>Chapter 1<br/>Introduction</h1>'
        '<h2>1.1. First topic</h2>'
        '<h2>1.2. Second topic details</h2>'
        '<h3>1.2.1. Deeper subsection</h3>'
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
            '<h1>Chapter 1<br/>Introduction</h1>'
            '<h2>1.1. First section</h2>'
            '<h1>Chapter 2<br/>Second chapter</h1>'
            '<h2>2.1. Second section</h2>'
            '<h1>Appendix A<br/>Appendix title</h1>'
            '<h1>General Index</h1>'
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

    if bnf_real is True:
        p5.insert_text((50, 110), 'paragraph ', fontsize=9, fontname='helv')
        w1 = pymupdf.get_text_length('paragraph ', fontname='helv', fontsize=9)
        p5.insert_text((50 + w1, 112), '10', fontsize=7, fontname='helv')
        w2 = pymupdf.get_text_length('10', fontname='helv', fontsize=7)
        p5.insert_text((50 + w1 + w2, 110), ' =', fontsize=9, fontname='helv')
        p5.insert_text((65, 122), 'statement', fontsize=9, fontname='helv')
    elif bnf_real == 'glossary':
        # Glossary place-structure line that previously matched BNF_RULE_LINE_RE.
        p5.insert_text((50, 110), 'x10=fa1.', fontsize=9, fontname='helv')
    elif bnf_real == 'no_subscript':
        # Same text as a BNF header, but without a subscript span.
        p5.insert_text((50, 110), 'paragraph 10 =', fontsize=9, fontname='helv')
    elif bnf_real == 'wrong_name':
        # Valid BNF header shape with subscript, but wrong rule name for HTML.
        p5.insert_text((50, 110), 'other-rule ', fontsize=9, fontname='helv')
        w1 = pymupdf.get_text_length('other-rule ', fontname='helv', fontsize=9)
        p5.insert_text((50 + w1, 112), '10', fontsize=7, fontname='helv')
        w2 = pymupdf.get_text_length('10', fontname='helv', fontsize=7)
        p5.insert_text((50 + w1 + w2, 110), ' =', fontsize=9, fontname='helv')
    else:
        p5.insert_text((50, 110), 'In arithmetic, 10 = 5 + 5 is always true.', fontsize=9, fontname='helv')

    p5.insert_text((50, 145), "selma'o BAI (Section 1.1)", fontsize=14, fontname='hebo')

    doc.save(str(pdf_path))
    doc.close()

    ex_a1_html = 'Example A.1 x<sub>1</sub>' if nonbold_span_heading else 'Example A.1'
    html_path.write_text(
        '<html><body>'
        '<div class="toc"><ul>'
        '<li><a href="#ch1">1. Introduction</a></li>'
        '<li><a href="#s11">1.1. Subscript x<sub>1</sub> place</a></li>'
        '<li><a href="#appA">A. Chrestomathy</a></li>'
        '<li><a href="#idx">General Index</a></li>'
        '</ul></div>'
        '<h1>Chapter 1<br/>Introduction</h1>'
        '<h2>1.1. Subscript x<sub>1</sub> place</h2>'
        '<h1>Appendix A<br/>Chrestomathy</h1>'
        f'<div class="example-title">{ex_a1_html}</div>'
        '<div class="table-title">Table A.1. Parallel summary</div>'
        '<div class="figure-title">Figure A.1. Sample diagram</div>'
        '<h1>General Index</h1>'
        "<h2>selma'o BAI (Section 1.1)</h2>"
        '<p>'
        '<a class="xref" href="#ch1">Chapter 1</a>'
        '<a class="xref" href="#appA">Appendix A</a>'
        '<a class="xref" href="#exA1">Example A.1</a>'
        '<a class="xref" href="#tblA1">Table A.1</a>'
        '<a class="xref" href="#figA1">Figure A.1</a>'
        '<a class="xref" href="#bnf10">BNF rule #10</a>'
        '<a class="xref" href="#BAI">BAI</a>'
        '</p>'
        '<dl><dt><span class="term"><span id="b10"></span>paragraph <sub>10</sub> =</span></dt></dl>'
        '</body></html>',
        encoding='utf-8',
    )


def build_numeric_prose_regression_pdf(pdf_path, html_path, *,
                                       example_real=True, table_real=True,
                                       figure_real=True, bnf_real=True):
    """Build a PDF with numeric-only labels (Example 1.1, Table 1.1, Figure 1.1,
    BNF rule #2) that old check-pdf-page-numbers.py accepted anywhere on a page.
    """
    doc = pymupdf.open()
    for _ in range(4):
        doc.new_page(width=450, height=680)
    p1, p2, p3, p4 = doc[0], doc[1], doc[2], doc[3]

    p1.insert_text((50, 120), 'Numeric Regression Book', fontsize=18, fontname='hebo')

    p2.insert_text((50, 70), 'Table of Contents', fontsize=12, fontname='hebo')
    add_toc_line(p2, 95, '1. Introduction ....................................... 3', 2)
    add_toc_line(p2, 110, '1.1. Details .......................................... 4', 3)

    p3.insert_text((50, 75), 'Chapter 1', fontsize=14, fontname='hebo')
    p3.insert_text((50, 95), 'Introduction', fontsize=14, fontname='hebo')
    add_inline_xref(p3, 50, 140, 'Example 1.1 (p. 4)', 3)
    add_inline_xref(p3, 50, 158, 'Table 1.1 (p. 4)', 3)
    add_inline_xref(p3, 50, 176, 'Figure 1.1 (p. 4)', 3)
    add_inline_xref(p3, 50, 194, 'BNF rule #2 (p. 4)', 3)

    p4.insert_text((50, 75), '1.1 Details', fontsize=11, fontname='hebo')
    if example_real:
        p4.insert_text((50, 105), 'Example 1.1', fontsize=9, fontname='hebo')
    else:
        p4.insert_text((50, 105), 'Prose mentioning Example 1.1 in passing.', fontsize=9, fontname='helv')
    if table_real:
        p4.insert_text((50, 130), 'Table 1.1. Summary', fontsize=9, fontname='hebo')
    else:
        p4.insert_text((50, 130), 'Prose mentioning Table 1.1 in passing.', fontsize=9, fontname='helv')
    if figure_real:
        p4.insert_text((50, 155), 'Figure 1.1. Diagram', fontsize=9, fontname='hebo')
    else:
        p4.insert_text((50, 155), 'Prose mentioning Figure 1.1 in passing.', fontsize=9, fontname='helv')
    if bnf_real:
        p4.insert_text((50, 180), 'text-1 ', fontsize=9, fontname='helv')
        w1 = pymupdf.get_text_length('text-1 ', fontname='helv', fontsize=9)
        p4.insert_text((50 + w1, 182), '2', fontsize=7, fontname='helv')
        w2 = pymupdf.get_text_length('2', fontname='helv', fontsize=7)
        p4.insert_text((50 + w1 + w2, 180), ' =', fontsize=9, fontname='helv')
    else:
        p4.insert_text((50, 180), 'x2=fa1. Also 2 = 1 + 1 in prose.', fontsize=9, fontname='helv')

    doc.save(str(pdf_path))
    doc.close()

    html_path.write_text(
        '<html><body>'
        '<div class="toc"><ul>'
        '<li><a href="#ch1">1. Introduction</a></li>'
        '<li><a href="#s11">1.1. Details</a></li>'
        '</ul></div>'
        '<h1>Chapter 1<br/>Introduction</h1>'
        '<h2>1.1. Details</h2>'
        '<div class="example-title">Example 1.1</div>'
        '<div class="table-title">Table 1.1. Summary</div>'
        '<div class="figure-title">Figure 1.1. Diagram</div>'
        '<p>'
        '<a class="xref" href="#ex11">Example 1.1</a>'
        '<a class="xref" href="#tbl11">Table 1.1</a>'
        '<a class="xref" href="#fig11">Figure 1.1</a>'
        '<a class="xref" href="#b2">BNF rule #2</a>'
        '</p>'
        '<dl><dt><span class="term"><span id="b2"></span>text-1 <sub>2</sub> =</span></dt></dl>'
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

    html_body_headings = ['<h1>Chapter 1<br/>Introduction</h1>'] + [
        f'<h2>1.{idx}. Section {idx}</h2>' for idx in range(1, toc_page_count)
    ]
    html_path.write_text(
        '<html><body><div class="toc"><ul>'
        + ''.join(html_toc_items)
        + '</ul></div>'
        + ''.join(html_body_headings)
        + '</body></html>',
        encoding='utf-8',
    )


def run_check_captured(pdf_path, html_path=None):
    """Run check_pdf and analyze_pdf, returning (rc, stdout, analysis)."""
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        rc = MOD.check_pdf(str(pdf_path), html_path=str(html_path) if html_path else None)
    analysis = MOD.analyze_pdf(str(pdf_path), html_path=str(html_path) if html_path else None)
    return rc, buf.getvalue(), analysis


class CheckPdfPageNumbersTests(unittest.TestCase):
    def assert_clean_counters_except(self, analysis, *, allow=()):
        """Assert that no unrelated check failed (e.g. unrecognized label shape)."""
        allowed = set(allow)
        if 'toc_count' not in allowed:
            self.assertTrue(analysis['toc_count_ok'], 'unexpected toc_count failure')
            self.assertTrue(analysis['toc_links_match_printed'], 'unexpected toc link/line mismatch')
        if 'xref_count' not in allowed:
            self.assertTrue(analysis['xref_count_ok'], 'unexpected xref_count failure')
        for field in (
            'toc_entry_mismatches',
            'toc_unparsed',
            'toc_dest_mismatches',
            'toc_heading_mismatches',
            'xref_mismatches',
            'xref_target_missing',
            'xref_unknown_shape',
            'xref_blank_dests',
            'ambiguous_targets',
            'targets_missing_html_expected',
            'page_count_diffs',
            'missing_html_xref_targets',
            'empty_refs',
        ):
            if field not in allowed:
                self.assertFalse(analysis[field], f'unexpected failure in {field}: {analysis[field]}')

    def test_real_section_and_subsection_headings_pass(self):
        with tempfile.TemporaryDirectory(prefix='cll-cpn-') as temp:
            pdf = Path(temp) / 'ok.pdf'
            html = Path(temp) / 'ok.html'
            build_section_target_pdf(pdf, html, real_heading=True, subsection_heading=True)
            rc, _, res = run_check_captured(pdf, html)
            self.assertEqual(rc, 0)
            self.assert_clean_counters_except(res)

    def test_wrapped_section_heading_passes(self):
        with tempfile.TemporaryDirectory(prefix='cll-cpn-') as temp:
            pdf = Path(temp) / 'wrapped.pdf'
            html = Path(temp) / 'wrapped.html'
            build_section_target_pdf(pdf, html, real_heading=True, wrapped_heading=True)
            rc, _, res = run_check_captured(pdf, html)
            self.assertEqual(rc, 0)
            self.assert_clean_counters_except(res)

    def test_prose_number_and_title_words_fail_section_target_check(self):
        # Issue #344: prose containing "Section 1.2" and the first title words
        # elsewhere on the page must not satisfy a section target check.
        with tempfile.TemporaryDirectory(prefix='cll-cpn-') as temp:
            pdf = Path(temp) / 'prose.pdf'
            html = Path(temp) / 'prose.html'
            build_section_target_pdf(pdf, html, real_heading=False, subsection_heading=True)
            rc, out, res = run_check_captured(pdf, html)
            self.assertEqual(rc, 1)
            self.assert_clean_counters_except(res, allow=('toc_heading_mismatches', 'xref_target_missing'))
            self.assertEqual(len(res['toc_heading_mismatches']), 1)
            self.assertEqual(len(res['xref_target_missing']), 1)
            self.assertEqual(res['xref_target_missing'][0][3:5], ('section', '1.2'))
            self.assertIn('Inline xrefs target heading/label not on dest page: 1', out)
            self.assertIn('Inline xrefs unrecognized label shape: 0', out)

    def test_prose_subsection_number_fails_section_target_check(self):
        # Depth-3 subsection not in ToC: prose mentioning "1.2.1" must not pass.
        with tempfile.TemporaryDirectory(prefix='cll-cpn-') as temp:
            pdf = Path(temp) / 'sub.pdf'
            html = Path(temp) / 'sub.html'
            build_section_target_pdf(pdf, html, real_heading=True, subsection_heading=False)
            rc, out, res = run_check_captured(pdf, html)
            self.assertEqual(rc, 1)
            self.assert_clean_counters_except(res, allow=('xref_target_missing',))
            self.assertEqual(len(res['xref_target_missing']), 1)
            self.assertEqual(res['xref_target_missing'][0][3:5], ('section', '1.2.1'))
            self.assertIn('Inline xrefs target heading/label not on dest page: 1', out)

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
            rc, out, res = run_check_captured(pdf)
            self.assertEqual(rc, 1)
            self.assertEqual(res['toc_pages'], [2, 3, 4])
            self.assertEqual(res['printed_toc_lines'], 6)
            self.assertEqual(len(res['toc_entries']), 0)
            self.assertFalse(res['toc_links_match_printed'])
            self.assertIn('(0 linked entries, 6 printed lines)', out)

    def test_check_pdf_end_to_end_fails_when_toc_page_loses_links_with_html(self):
        # Issue #348: end-to-end check_pdf() with companion HTML passes when
        # all ToC links are intact and fails specifically on ToC link count
        # when a ToC page loses its links.
        with tempfile.TemporaryDirectory(prefix='cll-cpn-') as temp:
            ok_pdf = Path(temp) / 'toc-ok.pdf'
            ok_html = Path(temp) / 'toc-ok.html'
            build_multipage_toc_pdf(ok_pdf, ok_html, drop_links_on_pages=(), blank_before_body=True)
            rc, _, res = run_check_captured(ok_pdf, ok_html)
            self.assertEqual(rc, 0)
            self.assert_clean_counters_except(res)

            for name, drop, blank in (
                ('toc-lost-last', (4,), True),
                ('toc-lost-mid', (3,), False),
            ):
                with self.subTest(case=name):
                    bad_pdf = Path(temp) / f'{name}.pdf'
                    bad_html = Path(temp) / f'{name}.html'
                    build_multipage_toc_pdf(bad_pdf, bad_html, drop_links_on_pages=drop, blank_before_body=blank)
                    rc, out, res = run_check_captured(bad_pdf, bad_html)
                    self.assertEqual(rc, 1)
                    self.assert_clean_counters_except(res, allow=('toc_count', 'toc_entry_mismatches'))
                    self.assertTrue(res['toc_entry_mismatches'])
                    self.assertFalse(res['toc_links_match_printed'])
                    self.assertEqual(len(res['toc_entries']), 4)
                    self.assertEqual(res['printed_toc_lines'], 6)
                    self.assertIn('(4 linked entries, 6 printed lines)', out)

    def test_all_target_kinds_and_appendix_labels_pass_on_real_lines(self):
        with tempfile.TemporaryDirectory(prefix='cll-cpn-') as temp:
            pdf = Path(temp) / 'all-ok.pdf'
            html = Path(temp) / 'all-ok.html'
            build_all_targets_pdf(pdf, html)
            rc, _, res = run_check_captured(pdf, html)
            self.assertEqual(rc, 0)
            self.assert_clean_counters_except(res)

    def test_small_nonbold_span_does_not_hide_heading_or_caption(self):
        with tempfile.TemporaryDirectory(prefix='cll-cpn-') as temp:
            pdf = Path(temp) / 'nonbold-span.pdf'
            html = Path(temp) / 'nonbold-span.html'
            build_all_targets_pdf(pdf, html, nonbold_span_heading=True)
            rc, _, res = run_check_captured(pdf, html)
            self.assertEqual(rc, 0)
            self.assert_clean_counters_except(res)

    def test_prose_never_satisfies_chapter_appendix_caption_or_bnf_targets(self):
        # Every target kind must match its own heading/caption/rule line and
        # fail with the exact expected counter and target key (never because
        # of an unrecognized label shape).
        cases = [
            ({'chapter_real': False}, ('toc_heading_mismatches', 'xref_target_missing'), ('chapter', 'Chapter 1')),
            ({'chapter_real': False, 'prose_bold_lead': True}, ('toc_heading_mismatches', 'xref_target_missing'), ('chapter', 'Chapter 1')),
            ({'appendix_real': False}, ('toc_heading_mismatches', 'xref_target_missing'), ('appendix', 'Appendix A')),
            ({'unnumbered_real': False}, ('toc_heading_mismatches',), None),
            ({'example_a_real': False}, ('xref_target_missing',), ('example', 'Example A.1')),
            ({'table_a_real': False}, ('xref_target_missing',), ('titled', 'Table A.1')),
            ({'figure_a_real': False}, ('xref_target_missing',), ('titled', 'Figure A.1')),
            ({'bnf_real': False}, ('xref_target_missing',), ('bnf', '10')),
            ({'bnf_real': 'glossary'}, ('xref_target_missing',), ('bnf', '10')),
            ({'bnf_real': 'no_subscript'}, ('xref_target_missing',), ('bnf', '10')),
            ({'bnf_real': 'wrong_name'}, ('xref_target_missing',), ('bnf', '10')),
        ]
        for kw, expected_failures, expected_xref_key in cases:
            with self.subTest(case=kw):
                with tempfile.TemporaryDirectory(prefix='cll-cpn-') as temp:
                    pdf = Path(temp) / 'fail.pdf'
                    html = Path(temp) / 'fail.html'
                    build_all_targets_pdf(pdf, html, **kw)
                    rc, out, res = run_check_captured(pdf, html)
                    self.assertEqual(rc, 1)
                    self.assert_clean_counters_except(res, allow=expected_failures)
                    self.assertIn('Inline xrefs unrecognized label shape: 0', out)
                    if 'toc_heading_mismatches' in expected_failures:
                        self.assertEqual(len(res['toc_heading_mismatches']), 1)
                        self.assertIn('ToC heading not on dest page: 1', out)
                    if expected_xref_key is not None:
                        self.assertEqual(len(res['xref_target_missing']), 1)
                        self.assertEqual(res['xref_target_missing'][0][3:5], expected_xref_key)
                        self.assertIn('Inline xrefs target heading/label not on dest page: 1', out)

    def test_numeric_prose_anywhere_on_page_fails_specifically_on_target_missing(self):
        # Regression against the pre-#348 "anywhere on the page" fallback:
        # numeric-only labels (Example 1.1, Table 1.1, Figure 1.1, BNF rule #2)
        # were already recognized on main, so only the new line-level rules
        # catch them when they appear solely in prose or glossary x2= lines.
        with tempfile.TemporaryDirectory(prefix='cll-cpn-') as temp:
            ok_pdf = Path(temp) / 'num-ok.pdf'
            ok_html = Path(temp) / 'num-ok.html'
            build_numeric_prose_regression_pdf(ok_pdf, ok_html)
            rc, _, res = run_check_captured(ok_pdf, ok_html)
            self.assertEqual(rc, 0)
            self.assert_clean_counters_except(res)

            for kw, expected_key in (
                ({'example_real': False}, ('example', 'Example 1.1')),
                ({'table_real': False}, ('titled', 'Table 1.1')),
                ({'figure_real': False}, ('titled', 'Figure 1.1')),
                ({'bnf_real': False}, ('bnf', '2')),
            ):
                with self.subTest(case=kw):
                    pdf = Path(temp) / 'num-fail.pdf'
                    html = Path(temp) / 'num-fail.html'
                    build_numeric_prose_regression_pdf(pdf, html, **kw)
                    rc, out, res = run_check_captured(pdf, html)
                    self.assertEqual(rc, 1)
                    self.assert_clean_counters_except(res, allow=('xref_target_missing',))
                    self.assertEqual(len(res['xref_target_missing']), 1)
                    self.assertEqual(res['xref_target_missing'][0][3:5], expected_key)
                    self.assertIn('Inline xrefs target heading/label not on dest page: 1', out)
                    self.assertIn('Inline xrefs unrecognized label shape: 0', out)

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
            rc, _, res = run_check_captured(pdf, html)
            self.assertEqual(rc, 0)
            self.assert_clean_counters_except(res)

            bad_pdf = Path(temp) / 'long-toc-bad.pdf'
            bad_html = Path(temp) / 'long-toc-bad.html'
            build_long_toc_pdf(bad_pdf, bad_html, toc_page_count=27, drop_last_links=True)
            rc, out, res = run_check_captured(bad_pdf, bad_html)
            self.assertEqual(rc, 1)
            self.assert_clean_counters_except(res, allow=('toc_count', 'toc_entry_mismatches'))
            self.assertEqual(len(res['toc_entry_mismatches']), 1)
            self.assertFalse(res['toc_links_match_printed'])
            self.assertEqual(len(res['toc_entries']), 26)
            self.assertEqual(res['printed_toc_lines'], 27)
            self.assertIn('(26 linked entries, 27 printed lines)', out)

    def test_wrong_page_bold_prose_fails_table_caption_check(self):
        # REAL 3: moving "Table A.1. Parallel summary" to p. 5 while leaving a
        # bold prose mention "**Table A.1** follows." on p. 4 must fail on
        # xref_target_missing for Table A.1 (both via expected HTML caption and
        # non-link prominence > 50%).
        with tempfile.TemporaryDirectory(prefix='cll-cpn-') as temp:
            pdf = Path(temp) / 'moved-bold.pdf'
            html = Path(temp) / 'moved-bold.html'
            doc = pymupdf.open()
            for _ in range(5):
                doc.new_page(width=450, height=680)
            p1, p2, p3, p4, p5 = doc[0], doc[1], doc[2], doc[3], doc[4]
            p1.insert_text((50, 120), 'Test Book', fontsize=18, fontname='hebo')
            p2.insert_text((50, 70), 'Table of Contents', fontsize=12, fontname='hebo')
            add_toc_line(p2, 95, '1. Introduction ....................................... 3', 2)
            add_toc_line(p2, 110, 'A. Chrestomathy ....................................... 4', 3)
            p3.insert_text((50, 75), 'Chapter 1', fontsize=14, fontname='hebo')
            p3.insert_text((50, 95), 'Introduction', fontsize=14, fontname='hebo')
            add_inline_xref(p3, 50, 150, 'Table A.1 (p. 4)', 3)
            p4.insert_text((50, 75), 'Appendix A', fontsize=14, fontname='hebo')
            p4.insert_text((50, 95), 'Chrestomathy', fontsize=14, fontname='hebo')
            p4.insert_text((50, 150), 'Table A.1', fontsize=9, fontname='hebo')
            w = pymupdf.get_text_length('Table A.1', fontname='hebo', fontsize=9)
            p4.insert_text((50 + w, 150), ' follows.', fontsize=9, fontname='helv')
            p5.insert_text((50, 150), 'Table A.1. Parallel summary', fontsize=9, fontname='hebo')
            doc.save(str(pdf))
            doc.close()

            html.write_text(
                '<html><body>'
                '<div class="toc"><ul>'
                '<li><a href="#ch1">1. Introduction</a></li>'
                '<li><a href="#appA">A. Chrestomathy</a></li>'
                '</ul></div>'
                '<h1>Chapter 1<br/>Introduction</h1>'
                '<h1>Appendix A<br/>Chrestomathy</h1>'
                '<p><a class="xref" href="#tblA1">Table A.1</a></p>'
                '<div class="table-title">Table A.1. Parallel summary</div>'
                '</body></html>',
                encoding='utf-8',
            )
            rc, out, res = run_check_captured(pdf, html)
            self.assertEqual(rc, 1)
            self.assert_clean_counters_except(res, allow=('xref_target_missing',))
            self.assertEqual(len(res['xref_target_missing']), 1)
            self.assertEqual(res['xref_target_missing'][0][3:5], ('titled', 'Table A.1'))
            self.assertIn('Inline xrefs target heading/label not on dest page: 1', out)

    def test_ambiguous_target_on_multiple_pages_fails(self):
        # REAL 3: a target key that qualifies on more than one physical page
        # must fail as ambiguous even when the link points at one of those pages.
        with tempfile.TemporaryDirectory(prefix='cll-cpn-') as temp:
            pdf = Path(temp) / 'ambiguous.pdf'
            html = Path(temp) / 'ambiguous.html'
            doc = pymupdf.open()
            for _ in range(5):
                doc.new_page(width=450, height=680)
            p1, p2, p3, p4, p5 = doc[0], doc[1], doc[2], doc[3], doc[4]
            p1.insert_text((50, 120), 'Test Book', fontsize=18, fontname='hebo')
            p2.insert_text((50, 70), 'Table of Contents', fontsize=12, fontname='hebo')
            add_toc_line(p2, 95, '1. Introduction ....................................... 3', 2)
            add_toc_line(p2, 110, 'A. Chrestomathy ....................................... 4', 3)
            p3.insert_text((50, 75), 'Chapter 1', fontsize=14, fontname='hebo')
            p3.insert_text((50, 95), 'Introduction', fontsize=14, fontname='hebo')
            add_inline_xref(p3, 50, 150, 'Table A.1 (p. 4)', 3)
            p4.insert_text((50, 75), 'Appendix A', fontsize=14, fontname='hebo')
            p4.insert_text((50, 95), 'Chrestomathy', fontsize=14, fontname='hebo')
            p4.insert_text((50, 150), 'Table A.1. Parallel summary', fontsize=9, fontname='hebo')
            p5.insert_text((50, 150), 'Table A.1. Parallel summary', fontsize=9, fontname='hebo')
            doc.save(str(pdf))
            doc.close()

            html.write_text(
                '<html><body>'
                '<div class="toc"><ul>'
                '<li><a href="#ch1">1. Introduction</a></li>'
                '<li><a href="#appA">A. Chrestomathy</a></li>'
                '</ul></div>'
                '<h1>Chapter 1<br/>Introduction</h1>'
                '<h1>Appendix A<br/>Chrestomathy</h1>'
                '<p><a class="xref" href="#tblA1">Table A.1</a></p>'
                '<div class="table-title">Table A.1. Parallel summary</div>'
                '</body></html>',
                encoding='utf-8',
            )
            rc, out, res = run_check_captured(pdf, html)
            self.assertEqual(rc, 1)
            self.assert_clean_counters_except(res, allow=('ambiguous_targets',))
            self.assertEqual(res['ambiguous_targets'], [('titled', 'Table A.1', [4, 5])])
            self.assertIn('Ambiguous targets qualifying on multiple pages: 1', out)

    def test_valid_caption_containing_nested_inline_xref_passes(self):
        # REAL 3 / round-6 REAL 1: a genuine caption containing a working inline
        # "(p. N)" xref must pass whether on one line or wrapped across lines
        # (including when the linked xref alone occupies line 2).
        for prefix in ('Table A.1. Summary of ', 'Table A.1. See '):
            for wrapped in (False, True):
                with self.subTest(prefix=prefix, wrapped=wrapped):
                    with tempfile.TemporaryDirectory(prefix='cll-cpn-') as temp:
                        pdf = Path(temp) / 'caption-xref.pdf'
                        html = Path(temp) / 'caption-xref.html'
                        doc = pymupdf.open()
                        for _ in range(4):
                            doc.new_page(width=450, height=680)
                        p1, p2, p3, p4 = doc[0], doc[1], doc[2], doc[3]
                        p1.insert_text((50, 120), 'Test Book', fontsize=18, fontname='hebo')
                        p2.insert_text((50, 70), 'Table of Contents', fontsize=12, fontname='hebo')
                        add_toc_line(p2, 95, '1. Introduction ....................................... 3', 2)
                        add_toc_line(p2, 110, 'A. Chrestomathy ....................................... 4', 3)
                        p3.insert_text((50, 75), 'Chapter 1', fontsize=14, fontname='hebo')
                        p3.insert_text((50, 95), 'Introduction', fontsize=14, fontname='hebo')
                        add_inline_xref(p3, 50, 150, 'Example A.1 (p. 4)', 3)
                        add_inline_xref(p3, 50, 170, 'Table A.1 (p. 4)', 3)
                        p4.insert_text((50, 75), 'Appendix A', fontsize=14, fontname='hebo')
                        p4.insert_text((50, 95), 'Chrestomathy', fontsize=14, fontname='hebo')
                        p4.insert_text((50, 125), 'Example A.1', fontsize=9, fontname='hebo')
                        if wrapped:
                            p4.insert_text((50, 150), prefix.rstrip(), fontsize=9, fontname='hebo')
                            add_inline_xref(p4, 50, 162, 'Example A.1 (p. 4)', 3)
                        else:
                            p4.insert_text((50, 150), prefix, fontsize=9, fontname='hebo')
                            w = pymupdf.get_text_length(prefix, fontname='hebo', fontsize=9)
                            add_inline_xref(p4, 50 + w, 150, 'Example A.1 (p. 4)', 3)
                        doc.save(str(pdf))
                        doc.close()

                        html.write_text(
                            '<html><body>'
                            '<div class="toc"><ul>'
                            '<li><a href="#ch1">1. Introduction</a></li>'
                            '<li><a href="#appA">A. Chrestomathy</a></li>'
                            '</ul></div>'
                            '<h1>Chapter 1<br/>Introduction</h1>'
                            '<h1>Appendix A<br/>Chrestomathy</h1>'
                            '<p><a class="xref" href="#exA1">Example A.1</a>'
                            '<a class="xref" href="#tblA1">Table A.1</a></p>'
                            '<div class="example-title">Example A.1</div>'
                            f'<div class="table-title">{prefix}<a class="xref" href="#exA1">Example A.1</a></div>'
                            '</body></html>',
                            encoding='utf-8',
                        )
                        rc, _, res = run_check_captured(pdf, html)
                        self.assertEqual(rc, 0)
                        self.assert_clean_counters_except(res)

    def test_duplicate_toc_row_fails_entry_by_entry_reconciliation(self):
        # LATENT: duplicating a ToC row (label + destination) in place of
        # another entry keeps linked == printed == expected HTML counts equal,
        # so entry-by-entry reconciliation must catch it for every label kind.
        with tempfile.TemporaryDirectory(prefix='cll-cpn-') as temp:
            pdf = Path(temp) / 'dup-toc.pdf'
            html = Path(temp) / 'dup-toc.html'
            doc = pymupdf.open()
            for _ in range(4):
                doc.new_page(width=450, height=680)
            p1, p2, p3, p4 = doc[0], doc[1], doc[2], doc[3]
            p1.insert_text((50, 120), 'Test Book', fontsize=18, fontname='hebo')
            p2.insert_text((50, 70), 'Table of Contents', fontsize=12, fontname='hebo')
            add_toc_line(p2, 95, '1. Introduction ....................................... 3', 2)
            add_toc_line(p2, 110, '1.1. First topic ...................................... 3', 2)
            # Duplicated 1.1 row replacing 1.2 (same total count = 3).
            add_toc_line(p2, 125, '1.1. First topic ...................................... 3', 2)
            p3.insert_text((50, 75), 'Chapter 1', fontsize=14, fontname='hebo')
            p3.insert_text((50, 95), 'Introduction', fontsize=14, fontname='hebo')
            p3.insert_text((50, 125), '1.1 First topic', fontsize=11, fontname='hebo')
            p4.insert_text((50, 75), '1.2 Second topic details', fontsize=11, fontname='hebo')
            doc.save(str(pdf))
            doc.close()

            html.write_text(
                '<html><body>'
                '<div class="toc"><ul>'
                '<li><a href="#ch1">1. Introduction</a></li>'
                '<li><a href="#s11">1.1. First topic</a></li>'
                '<li><a href="#s12">1.2. Second topic details</a></li>'
                '</ul></div>'
                '<h1>Chapter 1<br/>Introduction</h1>'
                '<h2>1.1. First topic</h2>'
                '<h2>1.2. Second topic details</h2>'
                '</body></html>',
                encoding='utf-8',
            )
            rc, out, res = run_check_captured(pdf, html)
            self.assertEqual(rc, 1)
            self.assert_clean_counters_except(res, allow=('toc_entry_mismatches',))
            self.assertEqual(len(res['toc_entry_mismatches']), 1)
            self.assertEqual(res['toc_entry_mismatches'][0][0:3], (3, 'label-mismatch', '1.2. Second topic details'))
            self.assertIn('ToC entry-by-entry mismatches vs HTML: 1', out)

    def test_label_only_wrapped_captions_and_headings_pass_while_prose_stays_rejected(self):
        # Round-6 REAL 1: label-only first-line wraps must pass for every non-BNF
        # target kind when matching HTML expected text, while regular prose
        # following a bold label must still fail and duplicate pages stay ambiguous.
        with tempfile.TemporaryDirectory(prefix='cll-cpn-') as temp:
            pdf = Path(temp) / 'label-wraps.pdf'
            html = Path(temp) / 'label-wraps.html'
            doc = pymupdf.open()
            for _ in range(5):
                doc.new_page(width=450, height=680)
            p1, p2, p3, p4, p5 = doc[0], doc[1], doc[2], doc[3], doc[4]
            p1.insert_text((50, 120), 'Test Book', fontsize=18, fontname='hebo')
            p2.insert_text((50, 70), 'Table of Contents', fontsize=12, fontname='hebo')
            add_toc_line(p2, 95, '1. Introduction ....................................... 3', 2)
            add_toc_line(p2, 110, '1.1. Wrapped section title ............................ 3', 2)
            add_toc_line(p2, 125, 'A. Chrestomathy ....................................... 4', 3)
            add_toc_line(p2, 140, 'General Index ......................................... 5', 4)

            p3.insert_text((50, 75), 'Chapter 1', fontsize=14, fontname='hebo')
            p3.insert_text((50, 95), 'Introduction', fontsize=14, fontname='hebo')
            p3.insert_text((50, 125), '1.1.', fontsize=11, fontname='hebo')
            p3.insert_text((50, 140), 'Wrapped section title', fontsize=11, fontname='hebo')
            add_inline_xref(p3, 50, 165, 'Section 1.1 (p. 3)', 2)
            add_inline_xref(p3, 50, 183, 'Example 1.1 (p. 4)', 3)
            add_inline_xref(p3, 50, 201, 'Table 1.1 (p. 4)', 3)
            add_inline_xref(p3, 50, 219, 'Figure 1.1 (p. 4)', 3)
            add_inline_xref(p3, 50, 237, 'BAI (p. 5)', 4)

            p4.insert_text((50, 75), 'Appendix A', fontsize=14, fontname='hebo')
            p4.insert_text((50, 95), 'Chrestomathy', fontsize=14, fontname='hebo')
            p4.insert_text((50, 125), 'Example 1.1.', fontsize=9, fontname='hebo')
            p4.insert_text((50, 137), 'Summary of examples', fontsize=9, fontname='hebo')
            p4.insert_text((50, 165), 'Table 1.1.', fontsize=9, fontname='hebo')
            p4.insert_text((50, 177), 'Summary of examples', fontsize=9, fontname='hebo')
            p4.insert_text((50, 205), 'Figure 1.1.', fontsize=9, fontname='hebo')
            p4.insert_text((50, 217), 'Sample diagram', fontsize=9, fontname='hebo')

            p5.insert_text((50, 75), 'General', fontsize=14, fontname='hebo')
            p5.insert_text((50, 95), 'Index', fontsize=14, fontname='hebo')
            p5.insert_text((50, 130), "selma'o BAI", fontsize=14, fontname='hebo')
            p5.insert_text((50, 148), '(Section 1.1 (p. 3))', fontsize=9, fontname='helv')
            lw = pymupdf.get_text_length('Section 1.1 (p. 3)', fontname='helv', fontsize=9)
            lp = pymupdf.get_text_length('(', fontname='helv', fontsize=9)
            p5.insert_link({'kind': pymupdf.LINK_GOTO, 'from': pymupdf.Rect(50 + lp - 1, 138, 50 + lp + lw + 1, 151), 'page': 2})

            doc.save(str(pdf))
            doc.close()

            html.write_text(
                '<html><body>'
                '<div class="toc"><ul>'
                '<li><a href="#ch1">1. Introduction</a></li>'
                '<li><a href="#s11">1.1. Wrapped section title</a></li>'
                '<li><a href="#appA">A. Chrestomathy</a></li>'
                '<li><a href="#idx">General Index</a></li>'
                '</ul></div>'
                '<h1>Chapter 1<br/>Introduction</h1>'
                '<h2>1.1. Wrapped section title</h2>'
                '<h1>Appendix A<br/>Chrestomathy</h1>'
                '<div class="example-title">Example 1.1. Summary of examples</div>'
                '<div class="table-title">Table 1.1. Summary of examples</div>'
                '<div class="figure-title">Figure 1.1. Sample diagram</div>'
                '<h1>General Index</h1>'
                '<h2>selma\'o BAI (<a class="xref" href="#s11">Section 1.1</a>)</h2>'
                '<p>'
                '<a class="xref" href="#s11">Section 1.1</a>'
                '<a class="xref" href="#ex11">Example 1.1</a>'
                '<a class="xref" href="#tbl11">Table 1.1</a>'
                '<a class="xref" href="#fig11">Figure 1.1</a>'
                '<a class="xref" href="#BAI">BAI</a>'
                '</p>'
                '</body></html>',
                encoding='utf-8',
            )
            rc, _, res = run_check_captured(pdf, html)
            self.assertEqual(rc, 0)
            self.assert_clean_counters_except(res)

            # Negative control: bold label followed by regular non-link prose must fail.
            bad_pdf = Path(temp) / 'label-prose.pdf'
            bad_html = Path(temp) / 'label-prose.html'
            doc = pymupdf.open()
            for _ in range(4):
                doc.new_page(width=450, height=680)
            p1, p2, p3, p4 = doc[0], doc[1], doc[2], doc[3]
            p1.insert_text((50, 120), 'Test Book', fontsize=18, fontname='hebo')
            p2.insert_text((50, 70), 'Table of Contents', fontsize=12, fontname='hebo')
            add_toc_line(p2, 95, '1. Introduction ....................................... 3', 2)
            p3.insert_text((50, 75), 'Chapter 1', fontsize=14, fontname='hebo')
            p3.insert_text((50, 95), 'Introduction', fontsize=14, fontname='hebo')
            add_inline_xref(p3, 50, 150, 'Table 1.1 (p. 4)', 3)
            p4.insert_text((50, 150), 'Table 1.1.', fontsize=9, fontname='hebo')
            p4.insert_text((50, 162), 'Summary of examples', fontsize=9, fontname='helv')
            doc.save(str(bad_pdf))
            doc.close()
            bad_html.write_text(
                '<html><body>'
                '<div class="toc"><ul><li><a href="#ch1">1. Introduction</a></li></ul></div>'
                '<h1>Chapter 1<br/>Introduction</h1>'
                '<p><a class="xref" href="#tbl11">Table 1.1</a></p>'
                '<div class="table-title">Table 1.1. Summary of examples</div>'
                '</body></html>',
                encoding='utf-8',
            )
            rc, _, res = run_check_captured(bad_pdf, bad_html)
            self.assertEqual(rc, 1)
            self.assert_clean_counters_except(res, allow=('xref_target_missing',))
            self.assertEqual(res['xref_target_missing'][0][3:5], ('titled', 'Table 1.1'))

    def test_toc_labels_ending_with_title_digits_reconcile_cleanly(self):
        # Round-6 REAL 3: strip pagination suffix only on the PDF side so title
        # digits ('Changes since CLL 1.1', 'Notes on Section 4.2', 'Release 1.3.7')
        # are preserved across chapters, sections, appendices, and unnumbered heads.
        with tempfile.TemporaryDirectory(prefix='cll-cpn-') as temp:
            pdf = Path(temp) / 'numeric-toc.pdf'
            html = Path(temp) / 'numeric-toc.html'
            doc = pymupdf.open()
            for _ in range(5):
                doc.new_page(width=450, height=680)
            p1, p2, p3, p4, p5 = doc[0], doc[1], doc[2], doc[3], doc[4]
            p1.insert_text((50, 120), 'Test Book', fontsize=18, fontname='hebo')
            p2.insert_text((50, 70), 'Table of Contents', fontsize=12, fontname='hebo')
            add_toc_line(p2, 95, '1. Changes since CLL 1.1 .............................. 3', 2)
            add_toc_line(p2, 110, '1.1. Notes on Section 4.2 ............................. 3', 2)
            add_toc_line(p2, 125, 'A. Release 1.3.7 ...................................... 4', 3)
            add_toc_line(p2, 140, 'Index for CLL 1.1 ..................................... 5', 4)

            p3.insert_text((50, 75), 'Chapter 1', fontsize=14, fontname='hebo')
            p3.insert_text((50, 95), 'Changes since CLL 1.1', fontsize=14, fontname='hebo')
            p3.insert_text((50, 125), '1.1 Notes on Section 4.2', fontsize=11, fontname='hebo')

            p4.insert_text((50, 75), 'Appendix A', fontsize=14, fontname='hebo')
            p4.insert_text((50, 95), 'Release 1.3.7', fontsize=14, fontname='hebo')

            p5.insert_text((50, 75), 'Index for CLL 1.1', fontsize=14, fontname='hebo')

            doc.save(str(pdf))
            doc.close()

            html.write_text(
                '<html><body>'
                '<div class="toc"><ul>'
                '<li><a href="#ch1">1. Changes since CLL 1.1</a></li>'
                '<li><a href="#s11">1.1. Notes on Section 4.2</a></li>'
                '<li><a href="#appA">A. Release 1.3.7</a></li>'
                '<li><a href="#unnum">Index for CLL 1.1</a></li>'
                '</ul></div>'
                '<h1>Chapter 1<br/>Changes since CLL 1.1</h1>'
                '<h2>1.1. Notes on Section 4.2</h2>'
                '<h1>Appendix A<br/>Release 1.3.7</h1>'
                '<h1>Index for CLL 1.1</h1>'
                '</body></html>',
                encoding='utf-8',
            )
            rc, _, res = run_check_captured(pdf, html)
            self.assertEqual(rc, 0)
            self.assert_clean_counters_except(res)

            # Negative control: mismatched trailing version digit in PDF ToC still fails.
            bad_html = Path(temp) / 'numeric-toc-mismatch.html'
            bad_html.write_text(
                html.read_text(encoding='utf-8').replace(
                    '1. Changes since CLL 1.1', '1. Changes since CLL 1.2'
                ),
                encoding='utf-8',
            )
            rc, _, res = run_check_captured(pdf, bad_html)
            self.assertEqual(rc, 1)
            self.assert_clean_counters_except(res, allow=('toc_entry_mismatches',))
            self.assertEqual(len(res['toc_entry_mismatches']), 1)

    def test_missing_html_expected_text_fails_without_weak_fallback(self):
        # Opus D-1: when companion HTML is present, any referenced target whose
        # expected heading/caption/BNF text is missing from the HTML must fail
        # explicitly rather than falling back to the weaker PDF-only check.
        with tempfile.TemporaryDirectory(prefix='cll-cpn-') as temp:
            pdf = Path(temp) / 'missing-exp.pdf'
            html = Path(temp) / 'missing-exp.html'
            doc = pymupdf.open()
            for _ in range(4):
                doc.new_page(width=450, height=680)
            p1, p2, p3, p4 = doc[0], doc[1], doc[2], doc[3]
            p1.insert_text((50, 120), 'Test Book', fontsize=18, fontname='hebo')
            p2.insert_text((50, 70), 'Table of Contents', fontsize=12, fontname='hebo')
            add_toc_line(p2, 95, '1. Introduction ....................................... 3', 2)
            p3.insert_text((50, 75), 'Chapter 1', fontsize=14, fontname='hebo')
            p3.insert_text((50, 95), 'Introduction', fontsize=14, fontname='hebo')
            add_inline_xref(p3, 50, 150, 'Table 1.1 (p. 4)', 3)
            add_inline_xref(p3, 50, 170, 'BNF rule #10 (p. 4)', 3)
            p4.insert_text((50, 120), 'Table 1.1. Parallel summary', fontsize=9, fontname='hebo')
            p4.insert_text((50, 150), 'paragraph ', fontsize=9, fontname='helv')
            w1 = pymupdf.get_text_length('paragraph ', fontname='helv', fontsize=9)
            p4.insert_text((50 + w1, 152), '10', fontsize=7, fontname='helv')
            w2 = pymupdf.get_text_length('10', fontname='helv', fontsize=7)
            p4.insert_text((50 + w1 + w2, 150), ' =', fontsize=9, fontname='helv')
            doc.save(str(pdf))
            doc.close()

            # Simulate a stylesheet class rename: table-title and BNF term absent.
            html.write_text(
                '<html><body>'
                '<div class="toc"><ul><li><a href="#ch1">1. Introduction</a></li></ul></div>'
                '<h1>Chapter 1<br/>Introduction</h1>'
                '<p><a class="xref" href="#tbl11">Table 1.1</a>'
                '<a class="xref" href="#b10">BNF rule #10</a></p>'
                '<div class="renamed-table-title">Table 1.1. Parallel summary</div>'
                '</body></html>',
                encoding='utf-8',
            )
            rc, out, res = run_check_captured(pdf, html)
            self.assertEqual(rc, 1)
            self.assert_clean_counters_except(res, allow=('targets_missing_html_expected',))
            self.assertEqual(
                res['targets_missing_html_expected'],
                [('bnf', '10'), ('titled', 'Table 1.1')],
            )
            self.assertIn('Targets missing expected text in HTML: 2', out)

    def test_html_class_attribute_rejects_nbsp_separator(self):
        # LATENT class: HTML class tokens must split on ASCII whitespace only.
        with tempfile.TemporaryDirectory(prefix='cll-cpn-') as temp:
            html = Path(temp) / 'nbsp.html'
            html.write_text(
                '<html><body>'
                '<div class="table-title\u00a0extra">Table 1.1. Summary</div>'
                '<p><a class="xref\u00a0extra" href="#tbl11">Table 1.1</a></p>'
                '</body></html>',
                encoding='utf-8',
            )
            _, xref_targets, _, html_titles = MOD.load_expected_html_data(html)
            self.assertEqual(xref_targets, [])
            self.assertEqual(html_titles, {})


if __name__ == '__main__':
    unittest.main()
