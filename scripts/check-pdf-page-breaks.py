#!/usr/bin/env python3
"""Audit stranded section headings, split example lead-ins, and page fill in CLL PDFs.

Checks:
1. Stranded section headings: headings from the PDF outline (h2/h3/h4/...) that
   appear at the bottom of a page with no non-heading body content below them.
2. Split example lead-ins: numbered examples ("Example N.M") starting at the
   top of a page whose previous page ends with the paragraph introducing it
   (reporting both colon-ending lead-ins and all HTML-preceding <p> lead-ins
   when --html is supplied).
3. Page fill ratios and before/after comparison when --compare BASE_PDF is given.

Requires PyMuPDF (pymupdf).
"""
import argparse
from html.parser import HTMLParser
import re
import sys

import pymupdf

BODY_TOP = 46.0
BODY_BOTTOM = 631.0
CONTENT_TOP = 48.19
CONTENT_HEIGHT = 632.13 - CONTENT_TOP

EXAMPLE_HEAD_RE = re.compile(r'^Example[\s\u00a0]+(\d+\.\d+)\b')
MARGIN_GLYPHS = set('◆★●■△?▲◇')


def normalize_ws(text):
    return ' '.join(text.replace('\u00a0', ' ').split())


def page_body_lines(page):
    """Return sorted list of (y0, y1, x0, x1, size, bold, text) inside body area."""
    lines = []
    for block in page.get_text('dict')['blocks']:
        if block['type'] != 0:
            continue
        for line in block['lines']:
            y0, y1 = line['bbox'][1], line['bbox'][3]
            if y1 <= BODY_TOP or y0 >= BODY_BOTTOM:
                continue
            text = normalize_ws(''.join(span['text'] for span in line['spans']))
            if not text or text in MARGIN_GLYPHS:
                continue
            max_size = max(span['size'] for span in line['spans'])
            bold = all(
                bool(span['flags'] & 16) or 'Bold' in span.get('font', '')
                for span in line['spans']
                if span['text'].strip()
            )
            lines.append((y0, y1, line['bbox'][0], line['bbox'][2], max_size, bold, text))
    lines.sort(key=lambda item: (round(item[0], 1), item[2]))
    return lines


def page_body_bottom(page, lines):
    """Lowest y coordinate of body text or body images on a page."""
    bottom = max((ln[1] for ln in lines), default=CONTENT_TOP)
    for block in page.get_text('dict')['blocks']:
        if block['type'] == 1:  # image
            y0, y1 = block['bbox'][1], block['bbox'][3]
            if y1 > BODY_TOP and y0 < BODY_BOTTOM:
                bottom = max(bottom, min(y1, BODY_BOTTOM))
    return bottom


def find_body_range(doc):
    """Return (first_chapter_page, glossary_or_index_page) as 1-based page numbers."""
    toc = doc.get_toc()
    first_ch = None
    backmatter = len(doc) + 1
    for level, title, page in toc:
        t = normalize_ws(title)
        if first_ch is None and t.startswith('Chapter 1 '):
            first_ch = page
        if t in ('Lojban Words Glossary', 'Lojban Words Index', 'General Index'):
            backmatter = min(backmatter, page)
    if first_ch is None:
        first_ch = 11
    return first_ch, backmatter


def load_html_p_examples(html_path):
    """Return {example_number: (prev_is_p, prev_text_tail)} from the rendered print HTML."""
    # Lightweight scan using regex on the serialized print HTML (no lxml dependency).
    raw = open(html_path, encoding='utf-8').read()
    # Find each <div class="...example..." ...> and inspect the tag immediately before it.
    result = {}
    div_re = re.compile(r'<div\s+[^>]*class="[^"]*\bexample\b[^"]*"[^>]*>', re.S)
    title_re = re.compile(r'<div\s+class="example-title"[^>]*>(.*?)</div>', re.S)
    tag_strip = re.compile(r'<[^>]+>')
    for m in div_re.finditer(raw):
        tm = title_re.search(raw, m.end(), m.end() + 600)
        if not tm:
            continue
        title_txt = normalize_ws(tag_strip.sub('', tm.group(1)))
        em = EXAMPLE_HEAD_RE.match(title_txt)
        if not em:
            continue
        ex_num = em.group(1)
        # Look backward for the immediately preceding closing tag (ignoring whitespace).
        before = raw[max(0, m.start() - 4000):m.start()].rstrip()
        prev_is_p = before.endswith('</p>')
        tail = ''
        if prev_is_p:
            p_start = before.rfind('<p')
            if p_start != -1:
                tail = normalize_ws(tag_strip.sub('', before[p_start:]))[-100:]
        result[ex_num] = (prev_is_p, tail)
    return result


def audit_pdf(pdf_path, html_examples=None):
    doc = pymupdf.open(pdf_path)
    total_pages = len(doc)
    first_ch, backmatter = find_body_range(doc)

    # Map 1-based page -> list of outline headings (level >= 2) on that page.
    headings_by_page = {}
    chapter_starts = set()
    for level, title, page in doc.get_toc():
        t = normalize_ws(title)
        if level == 1 and page >= first_ch:
            chapter_starts.add(page)
        if level >= 2 and first_ch <= page < backmatter:
            headings_by_page.setdefault(page, []).append((level, t))

    # Extract body lines per page once.
    lines_by_page = {}
    for pno in range(first_ch, backmatter):
        lines_by_page[pno] = page_body_lines(doc[pno - 1])

    # 1. Stranded section headings:
    # A heading on page p is stranded if every body line at or below its y0 on
    # page p belongs to outline headings on page p (no body content follows it).
    stranded = []
    for pno, hdgs in sorted(headings_by_page.items()):
        lines = lines_by_page[pno]
        if not lines:
            continue
        # Identify line indices matching each outline heading on this page.
        heading_line_indices = set()
        matched_headings = []
        for level, htitle in hdgs:
            # Match by heading text prefix. Bookmarks omit CSS-generated "(p. N)"
            # and can have extra spaces around "(" (e.g. "selma'o A ( Section 14.6)").
            head_stem = htitle.split('(', 1)[0].strip()
            key = head_stem[:28] if len(head_stem) >= 6 else htitle[:28]
            matched_idx = None
            for idx, ln in enumerate(lines):
                if key in ln[6] or (len(ln[6]) >= 8 and htitle.startswith(ln[6])):
                    # Avoid matching body prose that happens to mention the heading text:
                    # section headings are bold or larger than 9.5pt.
                    if ln[5] or ln[4] >= 10.5:
                        matched_idx = idx
                        break
            if matched_idx is not None:
                # Include wrapped continuation lines of the same heading.
                h_indices = [matched_idx]
                j = matched_idx + 1
                while j < len(lines):
                    # Wrapped heading line: bold/large and within 6pt vertically.
                    if (lines[j][5] or lines[j][4] >= 10.5) and (lines[j][0] - lines[j - 1][1]) < 6.0 and (lines[j][6] in htitle or '(p.' in lines[j][6]):
                        h_indices.append(j)
                        j += 1
                    else:
                        break
                heading_line_indices.update(h_indices)
                matched_headings.append((level, htitle, h_indices[0], h_indices[-1]))

        # Check if any matched heading has NO non-heading body lines after it (and no body image below it).
        body_img_bottom = CONTENT_TOP
        for block in doc[pno - 1].get_text('dict')['blocks']:
            if block['type'] == 1:
                y0, y1 = block['bbox'][1], block['bbox'][3]
                if y1 > BODY_TOP and y0 < BODY_BOTTOM:
                    body_img_bottom = max(body_img_bottom, y1)

        for level, htitle, first_i, last_i in matched_headings:
            heading_bottom = lines[last_i][1]
            has_content_below = any(
                idx not in heading_line_indices
                for idx in range(last_i + 1, len(lines))
            ) or body_img_bottom > heading_bottom + 2.0
            if not has_content_below:
                stranded.append((pno, level, htitle, round(lines[first_i][0], 1)))

    # 2. Split example lead-ins:
    # Find every page p where the first body line is "Example N.M", and inspect
    # the last body line on page p-1.
    split_colon = []
    split_p_all = []
    for pno in range(first_ch + 1, backmatter):
        lines = lines_by_page[pno]
        if not lines:
            continue
        first_txt = lines[0][6]
        m = EXAMPLE_HEAD_RE.match(first_txt)
        if not m:
            continue
        ex_num = m.group(1)
        prev_lines = lines_by_page.get(pno - 1, [])
        if not prev_lines:
            continue
        prev_last_txt = prev_lines[-1][6]
        # Skip if the previous page ended with an example or table/heading?
        # Check colon ending directly:
        ends_colon = prev_last_txt.endswith(':')
        if html_examples is not None and ex_num in html_examples:
            prev_is_p, tail = html_examples[ex_num]
            if prev_is_p:
                split_p_all.append((pno, ex_num, ends_colon, prev_last_txt[-80:]))
                if ends_colon:
                    split_colon.append((pno, ex_num, prev_last_txt[-80:]))
        else:
            if ends_colon:
                split_colon.append((pno, ex_num, prev_last_txt[-80:]))

    # 3. Page fill ratios (excluding blank pages and pages immediately before a chapter/appendix start):
    chapter_ends = set()
    for ch_p in chapter_starts:
        # Walk back past any blank page to find the last content page of the previous chapter.
        prev = ch_p - 1
        while prev >= first_ch and not lines_by_page.get(prev):
            prev -= 1
        if prev >= first_ch:
            chapter_ends.add(prev)
    # Also exclude the last page before backmatter.
    last_body = backmatter - 1
    while last_body >= first_ch and not lines_by_page.get(last_body):
        last_body -= 1
    chapter_ends.add(last_body)

    fills = {}
    for pno in range(first_ch, backmatter):
        lines = lines_by_page[pno]
        if not lines or pno in chapter_ends:
            continue
        bottom = page_body_bottom(doc[pno - 1], lines)
        fills[pno] = max(0.0, min(1.0, (bottom - CONTENT_TOP) / CONTENT_HEIGHT))

    doc.close()
    return {
        'pdf': pdf_path,
        'total_pages': total_pages,
        'body_range': (first_ch, backmatter - 1),
        'stranded': stranded,
        'split_colon': split_colon,
        'split_p_all': split_p_all,
        'fills': fills,
    }


def print_report(res, label=''):
    prefix = f'[{label}] ' if label else ''
    fills = res['fills']
    low_70 = [(p, f) for p, f in sorted(fills.items()) if f < 0.70]
    low_60 = [(p, f) for p, f in sorted(fills.items()) if f < 0.60]
    low_50 = [(p, f) for p, f in sorted(fills.items()) if f < 0.50]
    sorted_fills = sorted(fills.values())
    med = sorted_fills[len(sorted_fills) // 2] if sorted_fills else 0.0
    mn = sorted_fills[0] if sorted_fills else 0.0

    print(f"{prefix}PDF: {res['pdf']} ({res['total_pages']} pages, body p.{res['body_range'][0]}..{res['body_range'][1]})")
    print(f"  Stranded section headings: {len(res['stranded'])}")
    for pno, lvl, title, y0 in res['stranded'][:25]:
        print(f"    p.{pno} (h{lvl}, y={y0}): {title}")
    if len(res['stranded']) > 25:
        print(f"    ... ({len(res['stranded']) - 25} more)")

    print(f"  Split colon-ending example lead-ins: {len(res['split_colon'])}")
    for pno, ex_num, tail in res['split_colon'][:25]:
        print(f"    p.{pno - 1}->{pno} Example {ex_num}: ...{tail!r}")
    if len(res['split_colon']) > 25:
        print(f"    ... ({len(res['split_colon']) - 25} more)")

    if res['split_p_all']:
        non_colon = [x for x in res['split_p_all'] if not x[2]]
        print(f"  Split HTML <p>+div.example total: {len(res['split_p_all'])} (colon={len(res['split_colon'])}, non-colon={len(non_colon)})")
        for pno, ex_num, _, tail in non_colon[:15]:
            print(f"    p.{pno - 1}->{pno} Example {ex_num} (non-colon): ...{tail!r}")

    print(f"  Non-chapter-end body pages: {len(fills)} | median fill={med:.1%} min fill={mn:.1%}")
    print(f"  Pages with fill < 70%: {len(low_70)} | < 60%: {len(low_60)} | < 50%: {len(low_50)}")
    sparsest = sorted(fills.items(), key=lambda kv: kv[1])[:10]
    print('  10 sparsest non-chapter-end pages:', ', '.join(f'p.{p} ({f:.0%})' for p, f in sparsest))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('pdf', help='PDF file to audit')
    parser.add_argument('--html', help='Optional print HTML file for exact <p>+div.example classification')
    parser.add_argument('--compare', help='Optional baseline PDF to compare page count and fill against')
    parser.add_argument('--strict', action='store_true', help='Exit non-zero if any stranded heading or split example lead-in is found')
    args = parser.parse_args()

    html_examples = load_html_p_examples(args.html) if args.html else None
    cur = audit_pdf(args.pdf, html_examples=html_examples)
    if args.compare:
        base = audit_pdf(args.compare, html_examples=html_examples)
        print_report(base, 'BASE')
        print()
        print_report(cur, 'BRANCH')
        print()
        print('=== COMPARISON (BRANCH vs BASE) ===')
        print(f"  Total pages: {base['total_pages']} -> {cur['total_pages']} ({cur['total_pages'] - base['total_pages']:+d})")
        print(f"  Stranded headings: {len(base['stranded'])} -> {len(cur['stranded'])}")
        print(f"  Split colon lead-ins: {len(base['split_colon'])} -> {len(cur['split_colon'])}")
        if html_examples is not None:
            print(f"  Split all <p>+div.example: {len(base['split_p_all'])} -> {len(cur['split_p_all'])}")
        for thresh in (0.70, 0.60, 0.50):
            b_cnt = sum(1 for f in base['fills'].values() if f < thresh)
            c_cnt = sum(1 for f in cur['fills'].values() if f < thresh)
            print(f"  Non-chapter-end pages < {int(thresh*100)}% fill: {b_cnt} -> {c_cnt} ({c_cnt - b_cnt:+d})")
    else:
        print_report(cur)

    if args.strict and (cur['stranded'] or cur['split_colon'] or cur['split_p_all']):
        sys.exit(1)


if __name__ == '__main__':
    main()
