#!/usr/bin/env python3
"""Test the rendered book indexes. Requires PyMuPDF and a full ConTeXt PDF."""
import re
import sys
import unittest

import pymupdf

PDF_PATH = sys.argv.pop(1) if len(sys.argv) > 1 else 'build/cll-context.pdf'


class ContextIndexTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        with pymupdf.open(PDF_PATH) as pdf:
            headings = {entry[1]: entry[2] - 1 for entry in pdf.get_toc() if entry[0] == 1}
            start = headings['Lojban Words Index']
            middle = headings['General Index']
            cls.lojban = ''.join(pdf[index].get_text() for index in range(start, middle)).replace('’', "'")
            cls.general = ''.join(pdf[index].get_text() for index in range(middle, len(pdf))).replace('’', "'")
        cls.general_start = middle

    def test_apostrophe_pairs_each_have_one_complete_headword(self):
        for term in ("bei", "be'i", "doi", "do'i"):
            with self.subTest(term=term):
                self.assertEqual(len(re.findall(r'^' + re.escape(term) + r'\s+\d', self.lojban, re.MULTILINE)), 1)

    def test_general_index_ignores_case_when_ordering_headwords(self):
        def position(term):
            match = re.search(r'^' + re.escape(term) + r'(?:\s+\d[^\n]*)?$', self.general, re.MULTILINE)
            self.assertIsNotNone(match, term)
            return match.start()
        self.assertLess(position('abbreviated lujvo and plausibility'), position('Avon'))
        self.assertLess(position('zero'), position("Zipf's Law"))

    def test_leading_space_does_not_move_a_name_entry_before_a(self):
        entry = re.search(r'^name equivalent for ["“]typical', self.general, re.MULTILINE)
        self.assertIsNotNone(entry)
        self.assertGreater(entry.start(), self.general.index('Avon'))

    def test_sort_key_sentinel_does_not_appear_as_a_heading(self):
        self.assertNotRegex(self.general, r'(?m)^!$')
        self.assertNotRegex(self.lojban, r'(?m)^!$')

    def test_see_entry_has_target_and_no_page_number(self):
        line = re.search(r'^masses[^\n]*', self.general, re.M)
        self.assertIsNotNone(line, 'masses entry missing from the general index')
        line = line.group(0)
        self.assertIn('see groups', line)
        self.assertNotRegex(line, r'\d')

    def test_see_connector_is_plain_text_and_target_links_to_headword(self):
        # The "see" connecting word must not link anywhere (it once linked
        # to the Contents page); only the target headword links, to the
        # target's own entry. Visible text alone cannot show this, so follow
        # the PDF link annotations on the "masses see groups" line.
        with pymupdf.open(PDF_PATH) as pdf:
            found = None
            for index in range(self.general_start, len(pdf)):
                page = pdf[index]
                words = page.get_text('words')
                lines = {}
                for word in words:
                    lines.setdefault((word[5], word[6]), []).append(word)
                for line_words in lines.values():
                    texts = [word[4] for word in sorted(line_words, key=lambda word: word[0])]
                    if texts == ['masses', 'see', 'groups']:
                        found = (index, line_words)
                        break
                if found is not None:
                    break
            self.assertIsNotNone(found, 'masses see groups line missing from the general index')
            index, line_words = found
            by_text = {word[4]: pymupdf.Rect(word[:4]) for word in line_words}
            links = pdf[index].get_links()
            def touching(rect):
                # A real link covers its word; a neighbouring line's link
                # box can graze the word's edge by a fraction of a point.
                return [link for link in links if 'page' in link and
                        (pymupdf.Rect(link['from']) & rect).get_area() > 0.1 * rect.get_area()]
            self.assertEqual(touching(by_text['see']), [],
                             'the "see" connecting word must not link anywhere')
            targets = touching(by_text['groups'])
            self.assertTrue(targets, 'the see target "groups" must link to its headword')
            for link in targets:
                target_text = pdf[link['page']].get_text()
                self.assertRegex(target_text, r'(?m)^groups\s+\d',
                                 'the see target must link to the "groups" headword entry')


if __name__ == '__main__':
    unittest.main()
