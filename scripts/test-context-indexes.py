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


if __name__ == '__main__':
    unittest.main()
