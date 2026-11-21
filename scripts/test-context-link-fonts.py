#!/usr/bin/env python3
"""Test that linked Lojban words print italic in the ConTeXt PDF.

Requires PyMuPDF and a full ConTeXt PDF. Linked table cells must use
the book's normal style for linked Lojban words: the same italic as a
linked <valsi> in running prose, with bracketed words keeping roman
brackets outside the link (round 2 review REAL 1: ConTeXt printed every
glossary link in roman because the interaction style was `normal`).
"""
import sys
import unittest

import pymupdf

PDF_PATH = sys.argv.pop(1) if len(sys.argv) > 1 else 'build/cll-context.pdf'

# Split compound cells whose parts must each link separately.
SPLIT_WORDS = ("roinai", "pino'o", "pirau")


def is_italic(fontname):
    return 'OI' in fontname or 'Italic' in fontname or fontname.endswith('It')


def iter_spans(pdf):
    for index, page in enumerate(pdf):
        for block in page.get_text('dict')['blocks']:
            for line in block.get('lines', []):
                for span in line.get('spans', []):
                    yield index, page, span


def overlapping_links(page, bbox):
    x0, y0, x1, y1 = bbox
    return [link for link in page.get_links()
            if link['from'][0] <= x1 and link['from'][2] >= x0
            and link['from'][1] <= y1 and link['from'][3] >= y0]


def linked_spans(pdf, text):
    """Spans reading exactly `text` that carry at least one link annotation."""
    found = []
    for index, page, span in iter_spans(pdf):
        if span['text'].strip().replace('\u2019', "'") != text:
            continue
        if overlapping_links(page, span['bbox']):
            found.append((index, page, span))
    return found


class ContextLinkFontTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.pdf = pymupdf.open(PDF_PATH)

    @classmethod
    def tearDownClass(cls):
        cls.pdf.close()

    def test_split_parts_link_in_italic_with_no_space(self):
        for word in SPLIT_WORDS:
            with self.subTest(word=word):
                hits = linked_spans(self.pdf, word)
                self.assertTrue(hits, f'no linked {word!r} cell found')
                for index, page, span in hits:
                    self.assertTrue(is_italic(span['font']),
                                    f'{word!r} on p.{index + 1} prints {span["font"]}, not italic')
                    links = overlapping_links(page, span['bbox'])
                    self.assertGreaterEqual(
                        len(links), 2,
                        f'{word!r} on p.{index + 1} has {len(links)} link(s), not one per part')

    def test_no_split_cell_renders_with_a_space(self):
        spaced_forms = ('roi nai', "pi no'o", 'pi rau')
        spaced = []
        for _, _, span in iter_spans(self.pdf):
            text = span['text'].replace('\u2019', "'")
            for split in spaced_forms:
                if split in text or split.replace(' ', '  ') in text:
                    spaced.append((text.strip(), span['font']))
        self.assertEqual(spaced, [], f'split cells render with a space: {spaced[:5]}')

    def test_bracketed_gismu_link_italic_with_roman_brackets(self):
        hits = linked_spans(self.pdf, 'galtu')
        self.assertTrue(hits, 'no linked galtu cell found')
        for index, page, span in hits:
            self.assertTrue(is_italic(span['font']),
                            f'galtu on p.{index + 1} prints {span["font"]}, not italic')
            y0, y1 = span['bbox'][1], span['bbox'][3]
            brackets = [s for _, p, s in iter_spans(self.pdf)
                        if p.number == index and s['text'].strip() in ('[', ']')
                        and s['bbox'][1] < y1 and s['bbox'][3] > y0]
            self.assertTrue(brackets, f'no brackets found near galtu on p.{index + 1}')
            for bracket in brackets:
                self.assertFalse(is_italic(bracket['font']),
                                 f'bracket {bracket["text"]!r} on p.{index + 1} prints '
                                 f'{bracket["font"]}, not roman')

    def test_running_prose_valsi_link_italic(self):
        hits = linked_spans(self.pdf, 'basti')
        self.assertTrue(hits, 'no linked prose basti found')
        for index, _, span in hits:
            self.assertTrue(is_italic(span['font']),
                            f'prose basti on p.{index + 1} prints {span["font"]}, not italic')


if __name__ == '__main__':
    unittest.main()
