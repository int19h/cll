#!/usr/bin/env python3
"""Audit stranded section headings, split lead-ins, and page fill in CLL PDFs.

Checks:
1. Stranded section headings: outline headings (h2/h3/h4/...) at the foot of a
   page with either no body content below them OR only a short colon-ending
   lead-in paragraph (e.g. "The following cmavo are discussed in this section:")
   before a page break (the heading-stranding shape reported in issue #333).
2. Split example lead-ins: bold numbered examples ("Example N.M") starting at
   the top of a page whose previous page ends with the introducing paragraph.
3. Split table lead-ins: pages ending with a colon-ending lead-in paragraph
   whose next block in the book is a table (e.g. cmavo-list informaltable).
4. Page fill ratios and before/after comparison when --compare BASE_PDF is given.

Requires PyMuPDF (pymupdf).
"""
import argparse
from pathlib import Path
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
    raw = open(html_path, encoding='utf-8').read()
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
        before = raw[max(0, m.start() - 4000):m.start()].rstrip()
        prev_is_p = before.endswith('</p>')
        tail = ''
        if prev_is_p:
            p_start = before.rfind('<p')
            if p_start != -1:
                tail = normalize_ws(tag_strip.sub('', before[p_start:]))[-100:]
        result[ex_num] = (prev_is_p, tail)
    return result


def load_html_table_leadins(html_path):
    """Return set of normalized colon-ending lead-in tails directly before a table."""
    raw = open(html_path, encoding='utf-8').read()
    tag_strip = re.compile(r'<[^>]+>')
    tails = set()
    # Match <div class="informaltable"> or <div class="table">, optionally
    # preceded by empty marker paragraphs (<p class="allowbreaks"></p>, etc.).
    div_re = re.compile(r'<div\s+[^>]*class="[^"]*\b(?:informaltable|table)\b[^"]*"[^>]*>', re.S)
    empty_marker_re = re.compile(r'(?:<p\s+class="(?:allowbreaks|twocolumn)"[^>]*>\s*</p>\s*)+$', re.S)
    for m in div_re.finditer(raw):
        before = raw[max(0, m.start() - 4000):m.start()].rstrip()
        before = empty_marker_re.sub('', before).rstrip()
        if not before.endswith('</p>'):
            continue
        p_start = before.rfind('<p')
        if p_start == -1:
            continue
        text = normalize_ws(tag_strip.sub('', before[p_start:]))
        if text.endswith(':'):
            tails.add(text[-60:])
    return tails


def auto_discover_html(pdf_path):
    """Look for the sibling print HTML beside cll-weasyprint.pdf or cll.pdf."""
    pdf = Path(pdf_path).resolve()
    parent = pdf.parent
    candidates = []
    if 'weasyprint' in pdf.name:
        candidates.extend([
            parent / 'weasyprint-work/cll-weasyprint.html',
            parent / 'weasyprint/cll_processed_xhtml_pdf.html',
        ])
    else:
        candidates.append(parent / 'pdf/cll_processed_xhtml_pdf.html')
    for cand in candidates:
        if cand.is_file():
            return cand
    return None


def audit_pdf(pdf_path, html_examples=None, html_table_leadins=None):
    doc = pymupdf.open(pdf_path)
    total_pages = len(doc)
    first_ch, backmatter = find_body_range(doc)

    headings_by_page = {}
    chapter_starts = set()
    for level, title, page in doc.get_toc():
        t = normalize_ws(title)
        if level == 1 and page >= first_ch:
            chapter_starts.add(page)
        if level >= 2 and first_ch <= page < backmatter:
            headings_by_page.setdefault(page, []).append((level, t))

    lines_by_page = {}
    for pno in range(first_ch, backmatter):
        lines_by_page[pno] = page_body_lines(doc[pno - 1])

    # 1. Stranded section headings:
    # A heading on page p is stranded if:
    # - (bare) no non-heading body content or body image follows it on page p; OR
    # - (lead-in only) only a short lead-in (<= 2 non-heading lines, ending in
    #   ":", no body image below) follows it on page p before the page break.
    stranded_bare = []
    stranded_leadin = []
    for pno, hdgs in sorted(headings_by_page.items()):
        lines = lines_by_page[pno]
        if not lines:
            continue
        heading_line_indices = set()
        matched_headings = []
        for level, htitle in hdgs:
            head_stem = htitle.split('(', 1)[0].strip()
            key = head_stem[:28] if len(head_stem) >= 6 else htitle[:28]
            matched_idx = None
            for idx, ln in enumerate(lines):
                if key in ln[6] or (len(ln[6]) >= 8 and htitle.startswith(ln[6])):
                    if ln[5] or ln[4] >= 10.5:
                        matched_idx = idx
                        break
            if matched_idx is not None:
                h_indices = [matched_idx]
                j = matched_idx + 1
                while j < len(lines):
                    if (lines[j][5] or lines[j][4] >= 10.5) and (lines[j][0] - lines[j - 1][1]) < 6.0 and (lines[j][6] in htitle or '(p.' in lines[j][6]):
                        h_indices.append(j)
                        j += 1
                    else:
                        break
                heading_line_indices.update(h_indices)
                matched_headings.append((level, htitle, h_indices[0], h_indices[-1]))

        body_img_bottom = CONTENT_TOP
        for block in doc[pno - 1].get_text('dict')['blocks']:
            if block['type'] == 1:
                y0, y1 = block['bbox'][1], block['bbox'][3]
                if y1 > BODY_TOP and y0 < BODY_BOTTOM:
                    body_img_bottom = max(body_img_bottom, y1)

        for level, htitle, first_i, last_i in matched_headings:
            heading_bottom = lines[last_i][1]
            has_img_below = body_img_bottom > heading_bottom + 2.0
            following = [
                lines[idx] for idx in range(last_i + 1, len(lines))
                if idx not in heading_line_indices
            ]
            if not following and not has_img_below:
                stranded_bare.append((pno, level, htitle, round(lines[first_i][0], 1)))
            elif not has_img_below and len(following) <= 2 and following[-1][6].endswith(':'):
                # Check that the following lines are a single lead-in paragraph
                # (all at the left body margin, not multi-column table cells).
                if all(ln[2] < 80.0 for ln in following):
                    lead_txt = ' '.join(ln[6] for ln in following)
                    stranded_leadin.append((pno, level, htitle, round(lines[first_i][0], 1), lead_txt))

    # 2. Split example lead-ins:
    split_colon = []
    split_p_all = []
    for pno in range(first_ch + 1, backmatter):
        lines = lines_by_page[pno]
        if not lines:
            continue
        first_ln = lines[0]
        first_txt = first_ln[6]
        if not first_ln[5] or '(p.' in first_txt:
            continue
        m = EXAMPLE_HEAD_RE.match(first_txt)
        if not m:
            continue
        ex_num = m.group(1)
        prev_lines = lines_by_page.get(pno - 1, [])
        if not prev_lines:
            continue
        prev_last_txt = prev_lines[-1][6]
        ends_colon = prev_last_txt.endswith(':')
        if ends_colon:
            split_colon.append((pno, ex_num, prev_last_txt[-80:]))
        if html_examples is not None and ex_num in html_examples:
            prev_is_p, _ = html_examples[ex_num]
            if prev_is_p:
                split_p_all.append((pno, ex_num, ends_colon, prev_last_txt[-80:]))

    # 3. Split table lead-ins (pages ending with a colon-ending table lead-in):
    split_table_leadins = []
    if html_table_leadins:
        for pno in range(first_ch, backmatter - 1):
            prev_lines = lines_by_page.get(pno, [])
            if not prev_lines:
                continue
            # Combine last 2 lines on the page to match wrapped lead-in tails.
            tail_window = normalize_ws(' '.join(ln[6] for ln in prev_lines[-2:]))
            if not tail_window.endswith(':'):
                continue
            last_line = prev_lines[-1][6]
            if any(tail_window.endswith(t) or (len(last_line) >= 12 and t.endswith(last_line)) for t in html_table_leadins):
                split_table_leadins.append((pno, last_line[-80:]))

    # 4. Page fill ratios (excluding blank pages and chapter/appendix end pages):
    chapter_ends = set()
    for ch_p in chapter_starts:
        prev = ch_p - 1
        while prev >= first_ch and not lines_by_page.get(prev):
            prev -= 1
        if prev >= first_ch:
            chapter_ends.add(prev)
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
        'stranded_bare': stranded_bare,
        'stranded_leadin': stranded_leadin,
        'stranded': stranded_bare + stranded_leadin,
        'split_colon': split_colon,
        'split_p_all': split_p_all,
        'split_table_leadins': split_table_leadins,
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
    print(f"  Stranded section headings: {len(res['stranded'])} (bare={len(res['stranded_bare'])}, heading+lead-in={len(res['stranded_leadin'])})")
    for pno, lvl, title, y0 in res['stranded_bare'][:25]:
        print(f"    p.{pno} (bare h{lvl}, y={y0}): {title}")
    for pno, lvl, title, y0, lead in res['stranded_leadin'][:25]:
        print(f"    p.{pno} (lead-in h{lvl}, y={y0}): {title} | {lead!r}")

    print(f"  Split colon-ending example lead-ins: {len(res['split_colon'])}")
    for pno, ex_num, tail in res['split_colon'][:15]:
        print(f"    p.{pno - 1}->{pno} Example {ex_num}: ...{tail!r}")
    if len(res['split_colon']) > 15:
        print(f"    ... ({len(res['split_colon']) - 15} more)")

    if res['split_p_all']:
        p_colon = sum(1 for x in res['split_p_all'] if x[2])
        non_colon = len(res['split_p_all']) - p_colon
        print(f"  Split HTML <p>+div.example total: {len(res['split_p_all'])} (colon={p_colon}, non-colon={non_colon})")

    print(f"  Split colon-ending table lead-ins: {len(res['split_table_leadins'])}")
    for pno, tail in res['split_table_leadins'][:15]:
        print(f"    p.{pno}->{pno + 1}: ...{tail!r}")
    if len(res['split_table_leadins']) > 15:
        print(f"    ... ({len(res['split_table_leadins']) - 15} more)")

    print(f"  Non-chapter-end body pages: {len(fills)} | median fill={med:.1%} min fill={mn:.1%}")
    print(f"  Pages with fill < 70%: {len(low_70)} | < 60%: {len(low_60)} | < 50%: {len(low_50)}")
    sparsest = sorted(fills.items(), key=lambda kv: kv[1])[:10]
    print('  10 sparsest non-chapter-end pages:', ', '.join(f'p.{p} ({f:.0%})' for p, f in sparsest))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('pdf', help='PDF file to audit')
    parser.add_argument('--html', help='Optional print HTML file for exact <p>+div.example and table lead-in checks')
    parser.add_argument('--compare', help='Optional baseline PDF to compare page count and fill against')
    parser.add_argument('--strict', action='store_true', help='Exit non-zero if any stranded heading or split lead-in is found')
    args = parser.parse_args()

    cur_html = Path(args.html) if args.html else auto_discover_html(args.pdf)
    cur_examples = load_html_p_examples(cur_html) if cur_html and cur_html.is_file() else None
    cur_table_leadins = load_html_table_leadins(cur_html) if cur_html and cur_html.is_file() else None
    cur = audit_pdf(args.pdf, html_examples=cur_examples, html_table_leadins=cur_table_leadins)
    if args.compare:
        base_html = auto_discover_html(args.compare) or cur_html
        base_examples = load_html_p_examples(base_html) if base_html and base_html.is_file() else None
        base_table_leadins = load_html_table_leadins(base_html) if base_html and base_html.is_file() else None
        base = audit_pdf(args.compare, html_examples=base_examples, html_table_leadins=base_table_leadins)
        print_report(base, 'BASE')
        print()
        print_report(cur, 'BRANCH')
        print()
        print('=== COMPARISON (BRANCH vs BASE) ===')
        print(f"  Total pages: {base['total_pages']} -> {cur['total_pages']} ({cur['total_pages'] - base['total_pages']:+d})")
        print(f"  Stranded headings: {len(base['stranded'])} (bare={len(base['stranded_bare'])}, lead-in={len(base['stranded_leadin'])}) -> {len(cur['stranded'])} (bare={len(cur['stranded_bare'])}, lead-in={len(cur['stranded_leadin'])})")
        print(f"  Split colon example lead-ins: {len(base['split_colon'])} -> {len(cur['split_colon'])}")
        if cur_examples is not None:
            print(f"  Split all <p>+div.example: {len(base['split_p_all'])} -> {len(cur['split_p_all'])}")
        if cur_table_leadins is not None:
            print(f"  Split colon table lead-ins: {len(base['split_table_leadins'])} -> {len(cur['split_table_leadins'])}")
        for thresh in (0.70, 0.60, 0.50):
            b_cnt = sum(1 for f in base['fills'].values() if f < thresh)
            c_cnt = sum(1 for f in cur['fills'].values() if f < thresh)
            print(f"  Non-chapter-end pages < {int(thresh*100)}% fill: {b_cnt} -> {c_cnt} ({c_cnt - b_cnt:+d})")
    else:
        print_report(cur)

    if args.strict and (cur['stranded'] or cur['split_colon'] or cur['split_p_all'] or cur['split_table_leadins']):
        sys.exit(1)


if __name__ == '__main__':
    main()
