#!/usr/bin/env python3
"""Verify printed ToC and inline cross-reference page numbers in a CLL PDF.

Checks:
1. Every Table of Contents entry: printed page number vs. link destination AND
   whether the target heading text actually appears on that destination page.
2. Every inline "(p. N)" cross-reference link across the book: printed page
   number vs. link destination AND whether the referenced target (Chapter N,
   Appendix X, Section N.M, Example N.M, Table N.M, Figure N.M, BNF rule #N,
   or selma'o NAME) is actually printed on that destination page.
3. Exact count reconciliation: compares found ToC and inline xref counts against
   the source HTML (passed via --html or auto-discovered beside the PDF) and
   against raw body-text "(p. N)" occurrences, failing and reporting any missing
   or unverified references instead of silently skipping them.

Works on both WeasyPrint and Prince PDFs. Requires PyMuPDF (pymupdf).
"""
import argparse
from collections import Counter, defaultdict
from html.parser import HTMLParser
from pathlib import Path
import re
import sys
from urllib.parse import unquote

import pymupdf

BODY_TOP = 46.0
BODY_BOTTOM = 631.0

TRAILING_PAGE_RE = re.compile(r'(\d+)\s*$')
INLINE_PAGE_RE = re.compile(r'\(p\.\s*(\d+)\)')
EMPTY_PAGE_RE = re.compile(r'\(p\.\s*\)')
COMPONENT_NUM_PAT = r'(?:\d+|[A-Z])'
SECTION_NUM_RE = re.compile(rf'^{COMPONENT_NUM_PAT}(?:\.\d+)+$')
SECTION_HEAD_LINE_RE = re.compile(rf'^({COMPONENT_NUM_PAT}(?:\.\d+)+)(?:\s+(.*))?$')
CHAPTER_OR_APPENDIX_ONLY_RE = re.compile(r'^(?:Chapter\s+\d+|Appendix\s+[A-Z])$')
CHAPTER_OR_APPENDIX_START_RE = re.compile(r'^(Chapter\s+\d+|Appendix\s+[A-Z])(?:\s+(.*))?$')
EXAMPLE_HEAD_RE = re.compile(rf'^(Example\s+{COMPONENT_NUM_PAT}\.\d+)(?:\.?(?:\s|$))')
TITLED_HEAD_RE = re.compile(rf'^((?:Table|Figure)\s+{COMPONENT_NUM_PAT}\.\d+)(?:\.?(?:\s|$))')
SELMAO_HEAD_RE = re.compile(r"^selma'o\s+([A-Za-z][A-Za-z0-9']*)(?![A-Za-z0-9'])")
BNF_RULE_LINE_RE = re.compile(r'^(?:[A-Za-z][A-Za-z0-9_-]*\s+|[A-Za-z][A-Za-z_-]*)(\d+)\s*=')


def normalize_ws(text):
    return ' '.join(text.replace('\u00a0', ' ').split())


def body_text(page):
    """Return text inside the printable body area (excluding running header/footer)."""
    clip = pymupdf.Rect(0, BODY_TOP, page.rect.width, BODY_BOTTOM)
    return normalize_ws(page.get_text('text', clip=clip))


def is_toc_entry_line(text):
    """Return True if a body line in the contents range is a printed ToC entry."""
    if not text or text == 'Table of Contents':
        return False
    if CHAPTER_OR_APPENDIX_ONLY_RE.match(text):
        return False
    m = TRAILING_PAGE_RE.search(text)
    if not m:
        return False
    head = text[:m.start()].strip()
    return bool(re.search(r'[A-Za-z]', head))


def is_body_start_page_lines(body_lines):
    """Return True if non-empty body lines mark the start of the book body after ToC."""
    first = body_lines[0]
    if CHAPTER_OR_APPENDIX_START_RE.match(first):
        if CHAPTER_OR_APPENDIX_ONLY_RE.match(first) or not TRAILING_PAGE_RE.search(first):
            return True
    return not any(is_toc_entry_line(txt) for txt in body_lines)


def find_toc_pages(doc):
    """Return 1-based page numbers belonging to the Table of Contents.

    Discovers the whole contents range from printed content, independent of
    PDF link annotations, so a contents page that lost its links is still
    counted and fails reconciliation.
    """
    start = None
    for index, page in enumerate(doc, 1):
        if 'Table of Contents' in page.get_text():
            start = index
            break
    if start is None:
        raise RuntimeError('Table of Contents not found in PDF')
    pages = [start]
    for pno in range(start + 1, len(doc) + 1):
        body_lines = [
            txt for _, y0, y1, _, _, txt in page_visual_lines(doc[pno - 1])
            if y1 > BODY_TOP and y0 < BODY_BOTTOM
        ]
        if not body_lines:
            # Blank verso page between the end of ToC and Chapter 1.
            break
        if is_body_start_page_lines(body_lines):
            break
        pages.append(pno)
    return pages


def heading_key_from_toc_label(label):
    """Derive (prefix, title) from a ToC label to confirm the heading on its page."""
    cleaned = re.sub(r'\.+\s*\d+\s*$', '', label).strip()
    cleaned = normalize_ws(cleaned)
    m = re.match(r'^(\d+)\.\s+(.*)$', cleaned)
    if m:
        return f'Chapter {m.group(1)}', m.group(2)
    m = re.match(r'^([A-Z])\.\s+(.*)$', cleaned)
    if m:
        return f'Appendix {m.group(1)}', m.group(2)
    m = re.match(rf'^({COMPONENT_NUM_PAT}(?:\.\d+)+)\.\s+(.*)$', cleaned)
    if m:
        return m.group(1), m.group(2)
    return cleaned, ''


def toc_heading_kind(prefix):
    """Classify a ToC heading prefix into its target kind."""
    if re.match(r'^Chapter\s+\d+$', prefix):
        return 'chapter'
    if re.match(r'^Appendix\s+[A-Z]$', prefix):
        return 'appendix'
    if SECTION_NUM_RE.match(prefix):
        return 'section'
    return 'unnumbered'


def page_visual_lines(page):
    """Return list of (y_mid, y0, y1, x0, x1, text) for every text line on page."""
    raw = []
    for block in page.get_text('dict')['blocks']:
        if block['type'] != 0:
            continue
        for line in block['lines']:
            x0, y0, x1, y1 = line['bbox']
            text = normalize_ws(''.join(span['text'] for span in line['spans']))
            if text:
                raw.append((0.5 * (y0 + y1), y0, y1, x0, x1, text))
    raw.sort(key=lambda item: (item[0], item[3]))
    merged = []
    for y_mid, y0, y1, x0, x1, text in raw:
        if merged and abs(y_mid - merged[-1][0]) < 2.5:
            pm, py0, py1, px0, px1, ptxt = merged[-1]
            merged[-1] = (pm, min(py0, y0), max(py1, y1), min(px0, x0), max(px1, x1), f'{ptxt} {text}')
        else:
            merged.append((y_mid, y0, y1, x0, x1, text))
    return merged


def count_printed_toc_lines(doc, toc_pages):
    """Count printed ToC entry lines independently of PDF link annotations."""
    count = 0
    for pno in toc_pages:
        for ym, y0, y1, x0, x1, txt in page_visual_lines(doc[pno - 1]):
            if y1 <= BODY_TOP or y0 >= BODY_BOTTOM:
                continue
            if is_toc_entry_line(txt):
                count += 1
    return count


def extract_toc_entries(doc, toc_pages):
    """Extract (toc_page, nameddest, label, printed_page, dest_page) for every ToC entry."""
    entries = []
    for pno in toc_pages:
        page = doc[pno - 1]
        links = [l for l in page.get_links() if 'page' in l and l['page'] >= 0]
        if not links:
            continue
        vlines = page_visual_lines(page)

        def line_text_for_rect(rect):
            matched = [t for ym, _, _, _, _, t in vlines if rect.y0 <= ym <= rect.y1]
            return normalize_ws(' '.join(matched))

        grouped = []
        by_named = {}
        for link in links:
            dest = link['page'] + 1
            rect = pymupdf.Rect(link['from'])
            nd = link.get('nameddest')
            if nd:
                if nd in by_named:
                    by_named[nd]['rects'].append(rect)
                else:
                    rec = {'dest': dest, 'named': nd, 'rects': [rect]}
                    by_named[nd] = rec
                    grouped.append(rec)
            else:
                if (grouped and grouped[-1]['named'] is None
                        and grouped[-1]['dest'] == dest
                        and abs(rect.y0 - grouped[-1]['rects'][-1].y1) < 4.0):
                    prev_txt = line_text_for_rect(grouped[-1]['rects'][-1])
                    if not TRAILING_PAGE_RE.search(prev_txt):
                        grouped[-1]['rects'].append(rect)
                        continue
                grouped.append({'dest': dest, 'named': None, 'rects': [rect]})

        grouped.sort(key=lambda r: (min(x.y0 for x in r['rects']), min(x.x0 for x in r['rects'])))

        for rec in grouped:
            y0 = min(r.y0 for r in rec['rects'])
            y1 = max(r.y1 for r in rec['rects'])
            matched = [t for ym, _, _, _, _, t in vlines if y0 <= ym <= y1]
            line_text = normalize_ws(' '.join(matched))
            m = TRAILING_PAGE_RE.search(line_text)
            printed = int(m.group(1)) if m else None
            entries.append((pno, rec['named'], line_text, printed, rec['dest']))
    return entries


def group_text(page, rects):
    """Extract normalized text across a link group's rectangles (deduping overlaps)."""
    by_line = []
    for r in sorted(rects, key=lambda x: (round(x.y0 / 4.0), x.x0)):
        if by_line and abs(r.y0 - by_line[-1].y0) < 3.0 and r.x0 <= by_line[-1].x1 + 2.0:
            by_line[-1] |= r
        else:
            by_line.append(pymupdf.Rect(r))
    parts = []
    for r in by_line:
        clip = pymupdf.Rect(r.x0 - 0.5, r.y0 + 0.5, r.x1 + 0.5, r.y1 - 0.5)
        parts.append(normalize_ws(page.get_text('text', clip=clip)))
    return normalize_ws(' '.join(parts))


def extract_inline_xrefs(doc, start_page):
    """Extract (src_page, nameddest, text, printed_page, dest_page, split_inside_p) for inline xrefs."""
    xrefs = []
    prev_tail = None  # Incomplete link group at the bottom of page pno - 1.
    for pno in range(start_page, len(doc) + 1):
        page = doc[pno - 1]
        links = [l for l in page.get_links() if 'page' in l and l['page'] >= 0]
        if not links:
            prev_tail = None
            continue

        links.sort(key=lambda l: (round(l['from'].y0 / 4.0), l['from'].x0))

        groups = []
        for link in links:
            dest = link['page'] + 1
            rect = pymupdf.Rect(link['from'])
            nd = link.get('nameddest')
            merged = False
            for g in reversed(groups):
                if g['dest'] != dest or g['named'] != nd:
                    continue
                last = g['rects'][-1]
                # Same line: WeasyPrint emits an overlapping ::after link rect
                # inside the parent <a> rect, or adjacent fragments on one line.
                same_line_overlap = abs(rect.y0 - last.y0) < 3.0 and rect.x0 <= last.x1 + 2.0
                if same_line_overlap:
                    # Only merge if the rectangles actually overlap or the group
                    # does not already have a complete "(p. N)" reference.
                    overlaps = rect.x0 < last.x1 - 0.5
                    if overlaps or not g['complete']:
                        g['rects'].append(rect)
                        g['text'] = group_text(page, g['rects'])
                        g['complete'] = bool(INLINE_PAGE_RE.search(g['text']))
                        merged = True
                        break
                # Next line: only merge a line-wrapped continuation if the
                # previous fragment does NOT already end with a complete "(p. N)".
                next_line = (
                    not g['complete']
                    and 3.0 <= (rect.y0 - last.y0) <= 16.0
                    and rect.x0 < 150.0
                    and last.x1 > 200.0
                )
                if next_line:
                    g['rects'].append(rect)
                    g['text'] = group_text(page, g['rects'])
                    g['complete'] = bool(INLINE_PAGE_RE.search(g['text']))
                    merged = True
                    break
            if not merged:
                txt = group_text(page, [rect])
                groups.append({
                    'dest': dest,
                    'named': nd,
                    'rects': [rect],
                    'text': txt,
                    'complete': bool(INLINE_PAGE_RE.search(txt)),
                    'split_inside_p': False,
                })

        # Stitch a cross-page wrapped link (e.g. "Section 3.6" at bottom of
        # pno - 1 followed by "(p. 41)" at top of pno, or "Section 19.14 (p."
        # at bottom of pno - 1 followed by "461)" at top of pno).
        if prev_tail is not None and groups:
            for g in groups:
                if min(r.y0 for r in g['rects']) > 90.0:
                    break
                if g['dest'] == prev_tail['dest'] and g['named'] == prev_tail['named']:
                    combined = normalize_ws(f"{prev_tail['text']} {g['text']}")
                    if INLINE_PAGE_RE.search(combined):
                        # If "(p. N)" itself was broken across the page boundary,
                        # neither single page's body_text matches INLINE_PAGE_RE.
                        g['split_inside_p'] = not bool(INLINE_PAGE_RE.search(g['text']))
                        g['text'] = combined
                        g['complete'] = True
                        break

        next_tail = None
        for g in groups:
            m = INLINE_PAGE_RE.search(g['text'])
            if m:
                xrefs.append((pno, g['named'], g['text'], int(m.group(1)), g['dest'], g['split_inside_p']))
            elif max(r.y1 for r in g['rects']) >= 560.0:
                next_tail = g
        prev_tail = next_tail
    return xrefs


class _HtmlRefCollector(HTMLParser):
    """Count div.toc a[href^="#"] and a.xref[href^="#"] in print HTML."""
    def __init__(self):
        super().__init__()
        self.toc_depth = 0
        self.div_stack = []
        self.toc_targets = []
        self.xref_targets = []

    def handle_starttag(self, tag, attrs):
        attr_map = dict(attrs)
        classes = set((attr_map.get('class') or '').split())
        if tag == 'div':
            is_toc = 'toc' in classes
            self.div_stack.append(is_toc)
            if is_toc:
                self.toc_depth += 1
        elif tag == 'a':
            href = attr_map.get('href', '')
            if href.startswith('#'):
                target = unquote(href[1:])
                if target:
                    if self.toc_depth > 0:
                        self.toc_targets.append(target)
                    elif 'xref' in classes:
                        self.xref_targets.append(target)

    def handle_endtag(self, tag):
        if tag == 'div' and self.div_stack:
            if self.div_stack.pop():
                self.toc_depth -= 1


def load_expected_html_refs(html_path):
    parser = _HtmlRefCollector()
    parser.feed(Path(html_path).read_text(encoding='utf-8'))
    return parser.toc_targets, parser.xref_targets


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


def parse_inline_xref_target(xref_text):
    """Classify the visible label before '(p. N)' in an inline xref."""
    label = INLINE_PAGE_RE.split(xref_text, maxsplit=1)[0].strip()
    label = normalize_ws(label)
    # Strip any stray leading punctuation captured by a tight clip box.
    label = label.lstrip('([“"\' ')
    m = re.match(r'^(Chapter\s+\d+)$', label)
    if m:
        return ('chapter', m.group(1))
    m = re.match(r'^(Appendix\s+[A-Z])$', label)
    if m:
        return ('appendix', m.group(1))
    m = re.match(rf'^Section\s+({COMPONENT_NUM_PAT}(?:\.\d+)+)$', label)
    if m:
        return ('section', m.group(1))
    m = re.match(rf'^(Example\s+{COMPONENT_NUM_PAT}\.\d+)$', label)
    if m:
        return ('example', m.group(1))
    m = re.match(rf'^((?:Table|Figure)\s+{COMPONENT_NUM_PAT}\.\d+)$', label)
    if m:
        return ('titled', m.group(1))
    m = re.match(r'^BNF\s+rule\s+#(\d+)$', label)
    if m:
        return ('bnf', m.group(1))
    # selma'o catalog reference (e.g. "BE", "LE", "BEhO", "GOhA", "ZAhO")
    m = re.match(r"^([A-Za-z][A-Za-z0-9']*)$", label)
    if m:
        return ('selmao', m.group(1))
    return ('unknown', label)


def span_is_prominent(span):
    """Return True if a text span carries heading/caption styling (bold or >= 10.5pt)."""
    return (
        bool(span['flags'] & 16)
        or 'Bold' in span.get('font', '')
        or span['size'] >= 10.5
    )


def page_body_styled_lines(page):
    """Return merged body lines as (y0, y1, text, is_head_start, is_head_cont).

    Merges fragments on the same visual line before scoring span styling so a
    small non-bold span (e.g. a subscript or inline symbol) on a heading or
    caption line does not hide the heading, while normal prose lines (even ones
    starting with a single bold word) stay rejected.
    """
    raw = []
    for block in page.get_text('dict')['blocks']:
        if block['type'] != 0:
            continue
        for line in block['lines']:
            x0, y0, x1, y1 = line['bbox']
            if y1 <= BODY_TOP or y0 >= BODY_BOTTOM:
                continue
            spans = [s for s in line['spans'] if s['text'].strip()]
            if not spans:
                continue
            txt = normalize_ws(''.join(s['text'] for s in line['spans']))
            if not txt:
                continue
            raw.append((0.5 * (y0 + y1), y0, y1, x0, txt, spans))
    raw.sort(key=lambda item: (item[0], item[3]))

    merged = []
    for ym, y0, y1, x0, txt, spans in raw:
        if merged and abs(ym - merged[-1][0]) < 2.5:
            pm, py0, py1, px0, ptxt, pspans = merged[-1]
            merged[-1] = (pm, min(py0, y0), max(py1, y1), min(px0, x0), f'{ptxt} {txt}', pspans + spans)
        else:
            merged.append((ym, y0, y1, x0, txt, list(spans)))

    result = []
    for _, y0, y1, _, txt, spans in merged:
        spans.sort(key=lambda s: s['bbox'][0])
        total_chars = sum(len(''.join(s['text'].split())) for s in spans)
        prominent_chars = sum(
            len(''.join(s['text'].split())) for s in spans if span_is_prominent(s)
        )
        max_size = max(s['size'] for s in spans)
        first_prominent = span_is_prominent(spans[0])
        mostly_prominent = max_size >= 10.5 or (prominent_chars * 2 >= total_chars)
        is_head_start = first_prominent and mostly_prominent
        is_head_cont = mostly_prominent
        result.append((y0, y1, txt, is_head_start, is_head_cont))
    return result


def is_distinct_target_line(txt):
    """Return True if a heading-styled line starts a distinct numbered/named target."""
    return bool(
        SECTION_HEAD_LINE_RE.match(txt)
        or CHAPTER_OR_APPENDIX_START_RE.match(txt)
        or EXAMPLE_HEAD_RE.match(txt)
        or TITLED_HEAD_RE.match(txt)
        or SELMAO_HEAD_RE.match(txt)
        or BNF_RULE_LINE_RE.match(txt)
    )


def page_targets(page):
    """Extract all verifiable heading, caption, selma'o, and BNF targets on page.

    Every target kind is matched on its actual heading, caption, or rule line,
    never as arbitrary text anywhere on the page.
    """
    lines = page_body_styled_lines(page)
    targets = {
        'chapter': {},
        'appendix': {},
        'section': {},
        'unnumbered': [],
        'example': set(),
        'titled': set(),
        'selmao': set(),
        'bnf': set(),
    }

    def collect_block(start_idx):
        parts = [lines[start_idx][2]]
        j = start_idx + 1
        while j < len(lines):
            ny0, _, ntxt, _, ncont = lines[j]
            if (
                ncont
                and '(p.' not in ntxt
                and (ny0 - lines[j - 1][1]) < 6.0
                and not is_distinct_target_line(ntxt)
            ):
                parts.append(ntxt)
                j += 1
            else:
                break
        return normalize_ws(' '.join(parts)), j

    i = 0
    while i < len(lines):
        _, _, txt, is_head_start, _ = lines[i]

        # BNF rule definitions print in regular font in WeasyPrint and bold in
        # Prince, always anchored at the start of their definition line.
        if '(p.' not in txt:
            bm = BNF_RULE_LINE_RE.match(txt)
            if bm:
                targets['bnf'].add(bm.group(1))
                i += 1
                continue

        if is_head_start:
            sm = SELMAO_HEAD_RE.match(txt)
            if sm:
                targets['selmao'].add(sm.group(1))
                i += 1
                continue

            if '(p.' not in txt:
                em = EXAMPLE_HEAD_RE.match(txt)
                if em:
                    targets['example'].add(em.group(1))
                    i += 1
                    continue

                tm = TITLED_HEAD_RE.match(txt)
                if tm:
                    targets['titled'].add(tm.group(1))
                    i += 1
                    continue

                cm = CHAPTER_OR_APPENDIX_START_RE.match(txt)
                if cm:
                    key = cm.group(1)
                    kind = 'chapter' if key.startswith('Chapter ') else 'appendix'
                    block_text, next_i = collect_block(i)
                    targets[kind].setdefault(key, []).append(block_text)
                    i = next_i
                    continue

                secm = SECTION_HEAD_LINE_RE.match(txt)
                if secm:
                    key = secm.group(1)
                    block_text, next_i = collect_block(i)
                    targets['section'].setdefault(key, []).append(block_text)
                    i = next_i
                    continue

                block_text, next_i = collect_block(i)
                targets['unnumbered'].append(block_text)
                i = next_i
                continue

        i += 1
    return targets


def starts_with_prefix(line, expected):
    """Return True if line starts with expected at a non-alphanumeric boundary."""
    if not line.startswith(expected):
        return False
    return len(line) == len(expected) or not line[len(expected)].isalnum()


def heading_block_matches(blocks, key, title=''):
    """Confirm heading 'key' (and title start, if known) prints as a heading line."""
    if not blocks:
        return False
    if title:
        short_title = ' '.join(title.split()[:3])
        expected = f'{key} {short_title}'
        return any(starts_with_prefix(line, expected) for line in blocks)
    return True


def target_on_page(targets, kind, key, title=''):
    """Verify the target heading/caption/rule/selma'o prints on its own line on page."""
    if not targets:
        return False
    if kind in ('chapter', 'appendix', 'section'):
        return heading_block_matches(targets[kind].get(key), key, title)
    if kind == 'unnumbered':
        short = ' '.join(key.split()[:3]) if key else ''
        return bool(short) and any(starts_with_prefix(line, short) for line in targets['unnumbered'])
    if kind in ('example', 'titled', 'selmao', 'bnf'):
        return key in targets[kind]
    return False


def check_pdf(pdf_path, html_path=None, verbose=False):
    doc = pymupdf.open(pdf_path)
    total_pages = len(doc)
    body_cache = {}
    targets_cache = {}

    def get_body(pno):
        if pno not in body_cache:
            body_cache[pno] = body_text(doc[pno - 1]) if 1 <= pno <= total_pages else ''
        return body_cache[pno]

    def get_targets(pno):
        if pno not in targets_cache:
            targets_cache[pno] = page_targets(doc[pno - 1]) if 1 <= pno <= total_pages else None
        return targets_cache[pno]

    def toc_heading_matches(pno, prefix, title):
        return target_on_page(get_targets(pno), toc_heading_kind(prefix), prefix, title)

    toc_pages = find_toc_pages(doc)
    printed_toc_lines = count_printed_toc_lines(doc, toc_pages)
    toc_entries = extract_toc_entries(doc, toc_pages)

    # Map ToC heading prefixes ("Chapter 22", "Appendix B", "21.2", ...) -> title.
    toc_titles = {}
    toc_unparsed = []
    toc_dest_mismatches = []
    toc_heading_mismatches = []

    for pno, nd, text, printed, dest in toc_entries:
        prefix, title = heading_key_from_toc_label(text)
        if prefix and title:
            toc_titles[prefix] = title
        if printed is None:
            toc_unparsed.append((pno, nd, text, dest))
            continue
        if printed != dest:
            toc_dest_mismatches.append((pno, nd, text, printed, dest, dest - printed))
        if not toc_heading_matches(dest, prefix, title):
            actual = None
            for cand in range(max(1, dest - 3), min(total_pages, dest + 3) + 1):
                if toc_heading_matches(cand, prefix, title):
                    actual = cand
                    break
            toc_heading_mismatches.append((pno, nd, text, printed, dest, actual))

    first_body_page = max(toc_pages) + 1
    xrefs = extract_inline_xrefs(doc, first_body_page)

    xref_mismatches = []
    xref_blank_dests = []
    xref_target_missing = []
    xref_unknown_shape = []
    cross_page_split_p = 0
    for pno, nd, text, printed, dest, split_inside_p in xrefs:
        if split_inside_p:
            cross_page_split_p += 1
        if printed != dest:
            xref_mismatches.append((pno, nd, text, printed, dest, dest - printed))
        dest_text = get_body(dest)
        if not dest_text:
            xref_blank_dests.append((pno, nd, text, printed, dest))
            continue
        kind, key = parse_inline_xref_target(text)
        if kind == 'unknown':
            xref_unknown_shape.append((pno, nd, text, dest))
        elif not target_on_page(get_targets(dest), kind, key, toc_titles.get(key, '')):
            xref_target_missing.append((pno, nd, text, kind, key, dest))

    # Reconcile extracted inline xref count against raw body-text "(p. N)" count
    # and against the print HTML source when available.
    body_ref_pages = Counter()
    for pno in range(first_body_page, total_pages + 1):
        txt = get_body(pno)
        n = len(INLINE_PAGE_RE.findall(txt))
        if n:
            body_ref_pages[pno] = n
    found_ref_pages = Counter(x[0] for x in xrefs if not x[5])
    page_count_diffs = []
    for pno in sorted(set(body_ref_pages) | set(found_ref_pages)):
        if body_ref_pages[pno] != found_ref_pages[pno]:
            page_count_diffs.append((pno, body_ref_pages[pno], found_ref_pages[pno]))

    resolved_html = Path(html_path) if html_path else auto_discover_html(pdf_path)
    expected_toc = None
    expected_xrefs = None
    missing_html_xref_targets = {}
    if resolved_html and resolved_html.is_file():
        html_toc, html_xrefs = load_expected_html_refs(resolved_html)
        expected_toc = len(html_toc)
        expected_xrefs = len(html_xrefs)
        if any(x[1] is not None for x in xrefs):
            missing = Counter(html_xrefs) - Counter(x[1] for x in xrefs)
            if missing:
                missing_html_xref_targets = dict(missing)

    empty_refs = []
    for pno in range(1, total_pages + 1):
        if EMPTY_PAGE_RE.search(get_body(pno)):
            empty_refs.append(pno)

    print(f'PDF: {pdf_path} ({total_pages} pages)')
    if resolved_html:
        print(f'  HTML source: {resolved_html} (expected ToC={expected_toc}, inline xrefs={expected_xrefs})')
    print(f'  ToC pages: {toc_pages[0]}..{toc_pages[-1]} ({len(toc_entries)} linked entries, {printed_toc_lines} printed lines)')
    print(f'  ToC unparsed entries: {len(toc_unparsed)}')
    print(f'  ToC printed != link dest: {len(toc_dest_mismatches)}')
    print(f'  ToC heading not on dest page: {len(toc_heading_mismatches)}')
    print(f'  Inline "(p. N)" xrefs checked: {len(xrefs)} (body text "(p. N)" count: {sum(body_ref_pages.values())}, cross-page split "(p. N)": {cross_page_split_p})')
    print(f'  Inline xrefs printed != link dest: {len(xref_mismatches)}')
    print(f'  Inline xrefs target heading/label not on dest page: {len(xref_target_missing)}')
    print(f'  Inline xrefs unrecognized label shape: {len(xref_unknown_shape)}')
    print(f'  Inline xrefs pointing to blank page: {len(xref_blank_dests)}')
    print(f'  Pages where extracted xref count != body "(p. N)" count: {len(page_count_diffs)}')
    print(f'  Empty "(p. )" references: {len(empty_refs)}')

    if toc_unparsed:
        print('  Sample ToC unparsed:')
        for item in toc_unparsed[:10]:
            print('   ', item)
    if toc_dest_mismatches:
        deltas = defaultdict(int)
        for item in toc_dest_mismatches:
            deltas[item[5]] += 1
        print(f'  ToC delta distribution (dest - printed): {dict(sorted(deltas.items()))}')
        print('  Sample ToC mismatches:')
        sample = toc_dest_mismatches[:10] + (toc_dest_mismatches[-10:] if len(toc_dest_mismatches) > 10 else [])
        for pno, nd, text, printed, dest, delta in sample:
            print(f'    ToC p.{pno}: printed={printed} dest={dest} ({delta:+d}) | {text[:75]}')
    if toc_heading_mismatches:
        print('  Sample ToC heading-not-on-dest:')
        for item in toc_heading_mismatches[:10]:
            print('   ', item)
    if xref_mismatches:
        deltas = defaultdict(int)
        for item in xref_mismatches:
            deltas[item[5]] += 1
        print(f'  Inline xref delta distribution (dest - printed): {dict(sorted(deltas.items()))}')
        print('  Sample inline xref mismatches:')
        for pno, nd, text, printed, dest, delta in xref_mismatches[:15]:
            print(f'    p.{pno} -> #{nd}: printed={printed} dest={dest} ({delta:+d}) | {text}')
        if verbose and len(xref_mismatches) > 15:
            for pno, nd, text, printed, dest, delta in xref_mismatches[15:]:
                print(f'    p.{pno} -> #{nd}: printed={printed} dest={dest} ({delta:+d}) | {text}')
    if xref_target_missing:
        print('  Sample inline xref targets not printed on dest page:')
        for item in xref_target_missing[:15]:
            print('   ', item)
    if xref_unknown_shape:
        print('  Unrecognized inline xref shapes:')
        for item in xref_unknown_shape[:15]:
            print('   ', item)
    if page_count_diffs:
        print('  Pages with extracted != body "(p. N)" count:')
        for pno, bcnt, fcnt in page_count_diffs[:15]:
            print(f'    p.{pno}: body_text={bcnt} extracted_links={fcnt}')
    if missing_html_xref_targets:
        print('  HTML a.xref targets missing from extracted links:', missing_html_xref_targets)
    if xref_blank_dests:
        print('  Inline xrefs to blank page:', xref_blank_dests[:10])
    if empty_refs:
        print('  Pages with empty "(p. )":', empty_refs[:10])

    doc.close()
    toc_links_match_printed = (len(toc_entries) == printed_toc_lines)
    toc_count_ok = toc_links_match_printed and (
        (len(toc_entries) == expected_toc) if expected_toc is not None else (len(toc_entries) >= 350)
    )
    xref_count_ok = (len(xrefs) == expected_xrefs) if expected_xrefs is not None else (len(xrefs) >= 2000)
    ok = (
        toc_count_ok
        and xref_count_ok
        and not toc_unparsed
        and not toc_dest_mismatches
        and not toc_heading_mismatches
        and not xref_mismatches
        and not xref_target_missing
        and not xref_unknown_shape
        and not xref_blank_dests
        and not page_count_diffs
        and not missing_html_xref_targets
        and not empty_refs
    )
    return 0 if ok else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('pdfs', nargs='+', help='PDF file(s) to check')
    parser.add_argument('--html', help='Print HTML file for exact expected ToC/xref counts')
    parser.add_argument('-v', '--verbose', action='store_true')
    args = parser.parse_args()
    rc = 0
    for pdf in args.pdfs:
        rc |= check_pdf(pdf, html_path=args.html, verbose=args.verbose)
    sys.exit(rc)


if __name__ == '__main__':
    main()
