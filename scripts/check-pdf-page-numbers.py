#!/usr/bin/env python3
"""Verify printed ToC and inline cross-reference page numbers in a CLL PDF.

Checks every Table of Contents entry (printed page number vs. link target and
actual page where the target heading is printed) and every inline "(p. N)"
cross-reference link across the book. Works on both WeasyPrint and Prince PDFs.

Requires PyMuPDF (pymupdf).
"""
import argparse
from collections import defaultdict
import re
import sys

import pymupdf

BODY_TOP = 46.0
BODY_BOTTOM = 631.0

TRAILING_PAGE_RE = re.compile(r'(\d+)\s*$')
INLINE_PAGE_RE = re.compile(r'\(p\.\s*(\d+)\)')
EMPTY_PAGE_RE = re.compile(r'\(p\.\s*\)')


def normalize_ws(text):
    return ' '.join(text.replace('\u00a0', ' ').split())


def body_text(page):
    """Return text inside the printable body area (excluding running header/footer)."""
    clip = pymupdf.Rect(0, BODY_TOP, page.rect.width, BODY_BOTTOM)
    return normalize_ws(page.get_text('text', clip=clip))


def find_toc_pages(doc):
    """Return 1-based page numbers belonging to the Table of Contents."""
    start = None
    for index, page in enumerate(doc, 1):
        if 'Table of Contents' in page.get_text():
            start = index
            break
    if start is None:
        raise RuntimeError('Table of Contents not found in PDF')
    pages = []
    for pno in range(start, min(start + 25, len(doc) + 1)):
        page = doc[pno - 1]
        text = page.get_text()
        if pno > start and ('Chapter\xa01' in text or 'Chapter 1\n' in text or 'Chapter 1 ' in text):
            # Stop once the first chapter starts.
            if not page.get_links() or '1.1' in text and 'Table of Contents' not in text:
                break
        if page.get_links():
            pages.append(pno)
        elif pno > start:
            # Blank verso page after the ToC before Chapter 1.
            break
    return pages


def heading_key_from_toc_label(label):
    """Derive a search needle from a ToC label to confirm the heading on its page."""
    cleaned = re.sub(r'\.+\s*\d+\s*$', '', label).strip()
    cleaned = normalize_ws(cleaned)
    # Chapter: "22. Beyond the standard..." -> "Chapter 22"
    m = re.match(r'^(\d+)\.\s+(.*)$', cleaned)
    if m:
        return f'Chapter {m.group(1)}', m.group(2)
    # Appendix: "A. Chrestomathy" -> "Appendix A"
    m = re.match(r'^([A-Z])\.\s+(.*)$', cleaned)
    if m:
        return f'Appendix {m.group(1)}', m.group(2)
    # Numbered section/subsection: "4.12. The lujvo..." or "B.1. How to..."
    m = re.match(r'^((?:\d+|[A-Z])(?:\.\d+)+)\.\s+(.*)$', cleaned)
    if m:
        return m.group(1), m.group(2)
    # Unnumbered top-level: Glossary, Lojban Words Index, General Index
    return cleaned, ''


def heading_present_on_page(page_text, prefix, title):
    """Check whether the heading identified by (prefix, title) appears on the page."""
    if not page_text:
        return False
    if prefix and title:
        # Take first 3 words of title to tolerate line breaks/punctuation differences.
        words = title.split()[:3]
        short_title = ' '.join(words)
        if f'{prefix} {short_title}' in page_text:
            return True
        if prefix in page_text and short_title in page_text:
            return True
    elif prefix and prefix in page_text:
        return True
    return False


def page_visual_lines(page):
    """Return list of (y_mid, y0, y1, x0, x1, text) for every text line on page."""
    # Group text spans on the same horizontal baseline (within 2.5pt) into one
    # visual line, since WeasyPrint puts title, leader dots, and page number in
    # separate blocks/lines at the same y coordinate.
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

        # Group overlapping/same-entry link annotations. WeasyPrint emits up to
        # three annotations per ToC <a> (full text, ::after, leader) with the
        # same nameddest; Prince emits one annotation per visual line with
        # nameddest=None.
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
                # Prince: merge consecutive lines of a wrapped entry if they have
                # the same dest, touch vertically, and the previous line did not
                # already end with a page number.
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


def extract_inline_xrefs(doc, start_page):
    """Extract (src_page, nameddest, text, printed_page, dest_page) for inline xrefs."""
    xrefs = []
    for pno in range(start_page, len(doc) + 1):
        page = doc[pno - 1]
        links = [l for l in page.get_links() if 'page' in l and l['page'] >= 0]
        if not links:
            continue

        # Sort links in reading order (line y, then x).
        links.sort(key=lambda l: (round(l['from'].y0 / 4.0), l['from'].x0))

        # Merge link fragments belonging to the same xref:
        # - WeasyPrint emits two overlapping rects on the same line (<a> and ::after)
        #   plus wrapped line-2 rects, all sharing nameddest.
        # - Prince emits one rect per line segment of a wrapped link (same dest,
        #   adjacent lines, x1 near right margin / x0 near left margin).
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
                # Same line overlapping/adjacent, or next line immediately below.
                same_line = abs(rect.y0 - last.y0) < 3.0 and rect.x0 <= last.x1 + 6.0
                next_line = 3.0 <= (rect.y0 - last.y0) <= 16.0 and rect.x0 < 120.0 and last.x1 > 250.0
                if same_line or next_line:
                    g['rects'].append(rect)
                    merged = True
                    break
            if not merged:
                groups.append({'dest': dest, 'named': nd, 'rects': [rect]})

        for g in groups:
            # Pick distinct line rects (union overlapping rects on the same line)
            # so text is not duplicated.
            by_line = []
            for r in sorted(g['rects'], key=lambda x: (round(x.y0 / 4.0), x.x0)):
                if by_line and abs(r.y0 - by_line[-1].y0) < 3.0:
                    by_line[-1] |= r
                else:
                    by_line.append(pymupdf.Rect(r))
            parts = []
            for r in by_line:
                # Tiny vertical trim to avoid adjacent lines.
                clip = pymupdf.Rect(r.x0 - 0.5, r.y0 + 0.5, r.x1 + 0.5, r.y1 - 0.5)
                parts.append(normalize_ws(page.get_text('text', clip=clip)))
            full_text = normalize_ws(' '.join(parts))
            m = INLINE_PAGE_RE.search(full_text)
            if m:
                xrefs.append((pno, g['named'], full_text, int(m.group(1)), g['dest']))
    return xrefs


def check_pdf(pdf_path, verbose=False):
    doc = pymupdf.open(pdf_path)
    total_pages = len(doc)
    body_cache = {}

    def get_body(pno):
        if pno not in body_cache:
            body_cache[pno] = body_text(doc[pno - 1]) if 1 <= pno <= total_pages else ''
        return body_cache[pno]

    toc_pages = find_toc_pages(doc)
    toc_entries = extract_toc_entries(doc, toc_pages)

    toc_unparsed = []
    toc_dest_mismatches = []
    toc_heading_mismatches = []

    for pno, nd, text, printed, dest in toc_entries:
        if printed is None:
            toc_unparsed.append((pno, nd, text, dest))
            continue
        if printed != dest:
            toc_dest_mismatches.append((pno, nd, text, printed, dest, dest - printed))
        prefix, title = heading_key_from_toc_label(text)
        if not heading_present_on_page(get_body(dest), prefix, title):
            # Search nearby pages to report where the heading actually is.
            actual = None
            for cand in range(max(1, dest - 3), min(total_pages, dest + 3) + 1):
                if heading_present_on_page(get_body(cand), prefix, title):
                    actual = cand
                    break
            toc_heading_mismatches.append((pno, nd, text, printed, dest, actual))

    first_body_page = max(toc_pages) + 1
    xrefs = extract_inline_xrefs(doc, first_body_page)
    xref_mismatches = []
    xref_blank_dests = []
    for pno, nd, text, printed, dest in xrefs:
        if printed != dest:
            xref_mismatches.append((pno, nd, text, printed, dest, dest - printed))
        if not get_body(dest):
            xref_blank_dests.append((pno, nd, text, printed, dest))

    empty_refs = []
    for pno in range(1, total_pages + 1):
        txt = get_body(pno)
        if EMPTY_PAGE_RE.search(txt):
            empty_refs.append(pno)

    print(f'PDF: {pdf_path} ({total_pages} pages)')
    print(f'  ToC pages: {toc_pages[0]}..{toc_pages[-1]} ({len(toc_entries)} entries)')
    print(f'  ToC unparsed entries: {len(toc_unparsed)}')
    print(f'  ToC printed != link dest: {len(toc_dest_mismatches)}')
    print(f'  ToC heading not on dest page: {len(toc_heading_mismatches)}')
    print(f'  Inline "(p. N)" xrefs checked: {len(xrefs)}')
    print(f'  Inline xrefs printed != link dest: {len(xref_mismatches)}')
    print(f'  Inline xrefs pointing to blank page: {len(xref_blank_dests)}')
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
    if xref_blank_dests:
        print('  Inline xrefs to blank page:', xref_blank_dests[:10])
    if empty_refs:
        print('  Pages with empty "(p. )":', empty_refs[:10])

    doc.close()
    ok = (
        len(toc_entries) >= 350
        and not toc_unparsed
        and not toc_dest_mismatches
        and not toc_heading_mismatches
        and len(xrefs) >= 2000
        and not xref_mismatches
        and not xref_blank_dests
        and not empty_refs
    )
    return 0 if ok else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('pdfs', nargs='+', help='PDF file(s) to check')
    parser.add_argument('-v', '--verbose', action='store_true')
    args = parser.parse_args()
    rc = 0
    for pdf in args.pdfs:
        rc |= check_pdf(pdf, verbose=args.verbose)
    sys.exit(rc)


if __name__ == '__main__':
    main()
