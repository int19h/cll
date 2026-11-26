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
from collections import defaultdict, namedtuple
import html as html_lib
from html.parser import HTMLParser
from pathlib import Path
import re
import sys

import pymupdf

BODY_TOP = 46.0
BODY_BOTTOM = 631.0
CONTENT_TOP = 48.19
CONTENT_HEIGHT = 632.13 - CONTENT_TOP

HTML_WS_RE = re.compile(r'[ \t\r\n\f]+')
INLINE_PAGE_STRIP_RE = re.compile(r'\s*\(p\.\s*\d+\)')
PARTIAL_INLINE_PAGE_RE = re.compile(r'(?:\s*\(p\.?)?$')
EXAMPLE_HEAD_RE = re.compile(r'^Example[\s\u00a0]+((?:\d+|[A-Z])\.\d+)(?:\.?(?:\s|$))')
EXAMPLE_SELF_REF_RE = re.compile(r'^Example[\s\u00a0]+(?:\d+|[A-Z])\.\d+\.?\s*\(p\.\s*\d+\)')
SECTION_NUM_DOT_RE = re.compile(r'^((?:\d+|[A-Z])(?:\.\d+)+)\.(?=\s|$)')
EXAMPLE_NUM_DOT_RE = re.compile(r'^(Example\s+(?:\d+|[A-Z])\.\d+)\.(?=\s|$)')
MARGIN_GLYPHS = set('◆★●■△?▲◇')

BodyLine = namedtuple(
    'BodyLine',
    'y0 y1 x0 x1 size bold is_bold_cont is_prom_start is_prom_cont text',
)


def normalize_ws(text):
    return ' '.join(text.replace('\u00a0', ' ').split())


def canonical_caption_text(text, *, from_pdf=False):
    """Normalize an example caption for comparing PDF lines against companion HTML."""
    s = INLINE_PAGE_STRIP_RE.sub('', text) if from_pdf else text
    s = normalize_ws(s)
    return EXAMPLE_NUM_DOT_RE.sub(r'\1', s)


def canonical_heading_text(text, *, from_pdf=False):
    """Normalize a section heading for comparing PDF lines against outline/HTML text."""
    s = INLINE_PAGE_STRIP_RE.sub('', text) if from_pdf else text
    s = normalize_ws(s)
    return SECTION_NUM_DOT_RE.sub(r'\1', s)


def _is_canonical_prefix(cand, canon_expected):
    probes = [cand]
    trimmed_p = PARTIAL_INLINE_PAGE_RE.sub('', cand).rstrip()
    if trimmed_p and trimmed_p != cand:
        probes.append(trimmed_p)
    for probe in list(probes):
        if probe.endswith('-') and len(probe) > 1:
            probes.append(probe[:-1])
    for probe in probes:
        if any(exp.startswith(probe) for exp in canon_expected):
            return True
    return False


def match_lines_to_expected(lines, start_idx, canon_expected, *, canonicalize, cont_attr):
    """Consume consecutive continuation lines from start_idx until canon_expected matches.

    Returns the inclusive end index on match, or None if the lines starting at
    start_idx do not match any expected text.
    """
    if not canon_expected or start_idx >= len(lines):
        return None
    accum = {lines[start_idx].text}
    j = start_idx
    while True:
        canons = [canonicalize(s) for s in accum]
        if any(c in canon_expected for c in canons):
            return j
        if not any(_is_canonical_prefix(c, canon_expected) for c in canons):
            return None
        next_j = j + 1
        if next_j >= len(lines) or (next_j - start_idx) >= 8:
            return None
        nxt = lines[next_j]
        if not getattr(nxt, cont_attr) or (nxt.y0 - lines[j].y1) >= 12.0:
            return None
        next_accum = set()
        for s in accum:
            next_accum.add(f'{s} {nxt.text}')
            if s.endswith('-') and not s.endswith(' -'):
                next_accum.add(f'{s}{nxt.text}')
                next_accum.add(f'{s[:-1]}{nxt.text}')
        accum = next_accum
        j = next_j


def span_in_links(span, link_rects):
    if not link_rects:
        return False
    x0, y0, x1, y1 = span['bbox']
    cx, cy = 0.5 * (x0 + x1), 0.5 * (y0 + y1)
    return any(r.x0 <= cx <= r.x1 and r.y0 <= cy <= r.y1 for r in link_rects)


def join_row_fragments(frags):
    """Join left-to-right fragments on one visual line without splitting touching subscripts."""
    frags_sorted = sorted(frags, key=lambda item: item[3])
    parts = []
    prev_x1 = None
    prev_raw = ''
    for _, _, _, x0, x1, raw_txt, txt, _ in frags_sorted:
        if parts:
            touching = (
                not prev_raw.endswith((' ', '\t', '\u00a0'))
                and not raw_txt.startswith((' ', '\t', '\u00a0'))
                and (x0 - prev_x1) < 1.2
            )
            parts.append('' if touching else ' ')
        parts.append(txt)
        prev_x1 = x1
        prev_raw = raw_txt
    return normalize_ws(''.join(parts))


def page_body_lines(page):
    """Return sorted list of BodyLine tuples inside the printable body area."""
    link_rects = [
        pymupdf.Rect(l['from']) for l in page.get_links()
        if 'page' in l and l['page'] >= 0
    ]
    raw = []
    for block in page.get_text('dict')['blocks']:
        if block['type'] != 0:
            continue
        for line in block['lines']:
            x0, y0, x1, y1 = line['bbox']
            if y1 <= BODY_TOP or y0 >= BODY_BOTTOM:
                continue
            raw_txt = ''.join(span['text'] for span in line['spans'])
            text = normalize_ws(raw_txt)
            if not text or text in MARGIN_GLYPHS:
                continue
            spans = [s for s in line['spans'] if s['text'].strip()]
            if not spans:
                continue
            raw.append((0.5 * (y0 + y1), y0, y1, x0, x1, raw_txt, text, spans))
    raw.sort(key=lambda item: (item[0], item[3]))

    rows = []
    for frag in raw:
        ym, y0, y1, x0, x1, raw_txt, txt, spans = frag
        fsize = max(s['size'] for s in spans)
        placed = False
        for row in reversed(rows):
            ry0, ry1, rym, rsize, rfrags = row
            if abs(ym - rym) < 2.5:
                rfrags.append(frag)
                row[0] = min(ry0, y0)
                row[1] = max(ry1, y1)
                row[3] = max(rsize, fsize)
                placed = True
                break
            is_sub_or_sup = (
                fsize < rsize - 0.5
                and ry0 <= ym <= ry1
                and any(-1.5 <= (x0 - fx1) < 6.0 or -1.5 <= (fx0 - x1) < 6.0
                        for _, _, _, fx0, fx1, _, _, _ in rfrags)
                and not any(x0 < fx1 - 1.5 and x1 > fx0 + 1.5
                            for _, _, _, fx0, fx1, _, _, _ in rfrags)
            )
            if is_sub_or_sup:
                rfrags.append(frag)
                row[0] = min(ry0, y0)
                row[1] = max(ry1, y1)
                placed = True
                break
        if not placed:
            rows.append([y0, y1, ym, fsize, [frag]])

    rows.sort(key=lambda row: (row[0], min(f[3] for f in row[4])))

    is_bold = lambda s: bool(s['flags'] & 16) or 'Bold' in s.get('font', '')
    is_prom = lambda s: is_bold(s) or s['size'] >= 10.5

    lines = []
    for y0, y1, _, _, rfrags in rows:
        x0 = min(f[3] for f in rfrags)
        x1 = max(f[4] for f in rfrags)
        text = join_row_fragments(rfrags)
        spans = []
        for f in rfrags:
            spans.extend(f[7])
        spans.sort(key=lambda s: s['bbox'][0])
        max_size = max(span['size'] for span in spans)
        has_link = any(span_in_links(s, link_rects) for s in spans)
        non_link_spans = [s for s in spans if not span_in_links(s, link_rects)]
        non_link_chars = sum(len(''.join(s['text'].split())) for s in non_link_spans)
        non_link_alnum = sum(sum(ch.isalnum() for ch in s['text']) for s in non_link_spans)
        scored = non_link_spans if non_link_chars > 0 else spans
        total_chars = sum(len(''.join(s['text'].split())) for s in scored)
        bold_chars = sum(len(''.join(s['text'].split())) for s in scored if is_bold(s))
        prom_chars = sum(len(''.join(s['text'].split())) for s in scored if is_prom(s))
        mostly_bold = (bold_chars * 2 > total_chars)
        mostly_prom = (prom_chars * 2 > total_chars)
        link_only_cont = has_link and non_link_alnum == 0
        bold = is_bold(spans[0]) and mostly_bold
        is_bold_cont = mostly_bold or link_only_cont
        is_prom_start = is_prom(spans[0]) and mostly_prom
        is_prom_cont = mostly_prom or link_only_cont
        lines.append(BodyLine(
            y0, y1, x0, x1, max_size,
            bold, is_bold_cont, is_prom_start, is_prom_cont, text,
        ))
    return lines


def page_body_bottom(page, lines):
    """Lowest y coordinate of body text or body images on a page."""
    bottom = max((ln.y1 for ln in lines), default=CONTENT_TOP)
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


class _HtmlStructureCollector(HTMLParser):
    """Collect expected example captions and headings from companion print HTML."""
    _HEADING_TAGS = frozenset({'h1', 'h2', 'h3', 'h4', 'h5', 'h6'})

    def __init__(self):
        super().__init__()
        self.example_titles = defaultdict(list)
        self.headings = []
        self._div_stack = []
        self._toc_depth = 0
        self._example_depth = 0
        self._cap_kind = None
        self._cap_tag = None
        self._cap_depth = 0
        self._cap_parts = []

    def handle_starttag(self, tag, attrs):
        attr_map = dict(attrs)
        classes = {tok for tok in HTML_WS_RE.split(attr_map.get('class') or '') if tok}
        if tag == 'div':
            is_toc = 'toc' in classes
            is_example = 'example' in classes
            self._div_stack.append((is_toc, is_example))
            if is_toc:
                self._toc_depth += 1
            if is_example:
                self._example_depth += 1
            if self._cap_depth == 0 and self._example_depth > 0 and 'example-title' in classes:
                self._cap_kind, self._cap_tag, self._cap_depth, self._cap_parts = 'example', 'div', 1, []
            elif self._cap_depth > 0 and tag == self._cap_tag:
                self._cap_depth += 1
        elif tag in self._HEADING_TAGS and self._toc_depth == 0 and self._cap_depth == 0:
            self._cap_kind, self._cap_tag, self._cap_depth, self._cap_parts = 'heading', tag, 1, []
        elif self._cap_depth > 0 and tag == self._cap_tag:
            self._cap_depth += 1

        if tag == 'br' and self._cap_depth > 0:
            self._cap_parts.append(' ')

    def handle_data(self, data):
        if self._cap_depth > 0:
            self._cap_parts.append(data)

    def handle_endtag(self, tag):
        if self._cap_depth > 0 and tag == self._cap_tag:
            self._cap_depth -= 1
            if self._cap_depth == 0:
                text = normalize_ws(''.join(self._cap_parts))
                if text:
                    if self._cap_kind == 'example':
                        m = EXAMPLE_HEAD_RE.match(text)
                        if m:
                            self.example_titles[m.group(1)].append(text)
                    elif self._cap_kind == 'heading':
                        self.headings.append(text)
                self._cap_kind = None
                self._cap_tag = None
                self._cap_parts = []
        if tag == 'div' and self._div_stack:
            was_toc, was_example = self._div_stack.pop()
            if was_toc:
                self._toc_depth -= 1
            if was_example:
                self._example_depth -= 1


def load_html_example_titles(html_path):
    """Return {example_number: [expected_caption_text, ...]} from companion print HTML."""
    parser = _HtmlStructureCollector()
    parser.feed(Path(html_path).read_text(encoding='utf-8'))
    return dict(parser.example_titles)


def load_html_p_examples(html_path):
    """Return {example_number: (prev_is_p, prev_text_tail)} from the rendered print HTML."""
    raw = Path(html_path).read_text(encoding='utf-8')
    result = {}
    ws = r'[ \t\r\n\f]'
    div_re = re.compile(rf'<div{ws}+[^>]*class="(?:[^"]*{ws})?example(?:{ws}[^"]*)?"[^>]*>', re.S | re.ASCII)
    title_re = re.compile(rf'<div{ws}+[^>]*class="(?:[^"]*{ws})?example-title(?:{ws}[^"]*)?"[^>]*>(.*?)</div>', re.S | re.ASCII)
    tag_strip = re.compile(r'<[^>]+>')
    for m in div_re.finditer(raw):
        tm = title_re.search(raw, m.end(), m.end() + 600)
        if not tm:
            continue
        title_txt = normalize_ws(html_lib.unescape(tag_strip.sub('', tm.group(1))))
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
                tail = normalize_ws(html_lib.unescape(tag_strip.sub('', before[p_start:])))[-100:]
        result[ex_num] = (prev_is_p, tail)
    return result


def load_html_table_leadins(html_path):
    """Return set of normalized colon-ending lead-in tails directly before a table."""
    raw = Path(html_path).read_text(encoding='utf-8')
    tag_strip = re.compile(r'<[^>]+>')
    tails = set()
    ws = r'[ \t\r\n\f]'
    # Match <div class="informaltable"> or <div class="table">, optionally
    # preceded by empty marker paragraphs (<p class="allowbreaks"></p>, etc.).
    div_re = re.compile(rf'<div{ws}+[^>]*class="(?:[^"]*{ws})?(?:informaltable|table)(?:{ws}[^"]*)?"[^>]*>', re.S | re.ASCII)
    empty_marker_re = re.compile(rf'(?:<p{ws}+[^>]*class="(?:[^"]*{ws})?(?:allowbreaks|twocolumn)(?:{ws}[^"]*)?"[^>]*>{ws}*</p>{ws}*)+$', re.S | re.ASCII)
    for m in div_re.finditer(raw):
        before = raw[max(0, m.start() - 4000):m.start()].rstrip()
        before = empty_marker_re.sub('', before).rstrip()
        if not before.endswith('</p>'):
            continue
        p_start = before.rfind('<p')
        if p_start == -1:
            continue
        text = normalize_ws(html_lib.unescape(tag_strip.sub('', before[p_start:])))
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


def audit_pdf(pdf_path, html_examples=None, html_table_leadins=None, html_example_titles=None):
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
            canon_expected = {canonical_heading_text(htitle, from_pdf=False)}
            matched_span = None
            for idx, ln in enumerate(lines):
                if not ln.is_prom_start:
                    continue
                end_idx = match_lines_to_expected(
                    lines, idx, canon_expected,
                    canonicalize=lambda s: canonical_heading_text(s, from_pdf=True),
                    cont_attr='is_prom_cont',
                )
                if end_idx is not None:
                    matched_span = (idx, end_idx)
                    break
            if matched_span is not None:
                first_i, last_i = matched_span
                heading_line_indices.update(range(first_i, last_i + 1))
                matched_headings.append((level, htitle, first_i, last_i))

        body_img_bottom = CONTENT_TOP
        for block in doc[pno - 1].get_text('dict')['blocks']:
            if block['type'] == 1:
                y0, y1 = block['bbox'][1], block['bbox'][3]
                if y1 > BODY_TOP and y0 < BODY_BOTTOM:
                    body_img_bottom = max(body_img_bottom, y1)

        for level, htitle, first_i, last_i in matched_headings:
            heading_bottom = lines[last_i].y1
            has_img_below = body_img_bottom > heading_bottom + 2.0
            following = [
                lines[idx] for idx in range(last_i + 1, len(lines))
                if idx not in heading_line_indices
            ]
            if not following and not has_img_below:
                stranded_bare.append((pno, level, htitle, round(lines[first_i].y0, 1)))
            elif not has_img_below and len(following) <= 2 and following[-1].text.endswith(':'):
                # Check that the following lines are a single lead-in paragraph
                # (all at the left body margin, not multi-column table cells).
                if all(ln.x0 < 80.0 for ln in following):
                    lead_txt = ' '.join(ln.text for ln in following)
                    stranded_leadin.append((pno, level, htitle, round(lines[first_i].y0, 1), lead_txt))

    # 2. Split example lead-ins:
    split_colon = []
    split_p_all = []
    for pno in range(first_ch + 1, backmatter):
        lines = lines_by_page[pno]
        if not lines:
            continue
        first_ln = lines[0]
        first_txt = first_ln.text
        if not first_ln.bold or EXAMPLE_SELF_REF_RE.match(first_txt):
            continue
        m = EXAMPLE_HEAD_RE.match(first_txt)
        if not m:
            continue
        ex_num = m.group(1)
        if html_example_titles is not None:
            expected_titles = html_example_titles.get(ex_num)
            if not expected_titles:
                continue
            canon_expected = {canonical_caption_text(t, from_pdf=False) for t in expected_titles}
            matched_end = match_lines_to_expected(
                lines, 0, canon_expected,
                canonicalize=lambda s: canonical_caption_text(s, from_pdf=True),
                cont_attr='is_bold_cont',
            )
            if matched_end is None:
                continue
        prev_lines = lines_by_page.get(pno - 1, [])
        if not prev_lines:
            continue
        prev_last_txt = prev_lines[-1].text
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
            # Combine last 2 lines on the page to match wrapped lead-in tails,
            # stripping PDF-only '(p. N)' suffixes before comparing with HTML.
            raw_tail = normalize_ws(' '.join(ln.text for ln in prev_lines[-2:]))
            tail_window = normalize_ws(INLINE_PAGE_STRIP_RE.sub('', raw_tail))
            if not tail_window.endswith(':'):
                continue
            last_line = normalize_ws(INLINE_PAGE_STRIP_RE.sub('', prev_lines[-1].text))
            if any(tail_window.endswith(t) or (len(last_line) >= 12 and t.endswith(last_line)) for t in html_table_leadins):
                split_table_leadins.append((pno, prev_lines[-1].text[-80:]))

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
    cur_has_html = bool(cur_html and cur_html.is_file())
    cur_examples = load_html_p_examples(cur_html) if cur_has_html else None
    cur_example_titles = load_html_example_titles(cur_html) if cur_has_html else None
    cur_table_leadins = load_html_table_leadins(cur_html) if cur_has_html else None
    cur = audit_pdf(
        args.pdf,
        html_examples=cur_examples,
        html_table_leadins=cur_table_leadins,
        html_example_titles=cur_example_titles,
    )
    if args.compare:
        base_html = auto_discover_html(args.compare) or cur_html
        base_has_html = bool(base_html and base_html.is_file())
        base_examples = load_html_p_examples(base_html) if base_has_html else None
        base_example_titles = load_html_example_titles(base_html) if base_has_html else None
        base_table_leadins = load_html_table_leadins(base_html) if base_has_html else None
        base = audit_pdf(
            args.compare,
            html_examples=base_examples,
            html_table_leadins=base_table_leadins,
            html_example_titles=base_example_titles,
        )
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
