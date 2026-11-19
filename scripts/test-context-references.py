#!/usr/bin/env python3
"""Test the rendered cross-references. Requires PyMuPDF and a full ConTeXt PDF."""
import re
import sys
import unittest

import pymupdf

PDF_PATH = sys.argv.pop(1) if len(sys.argv) > 1 else 'build/cll-context.pdf'


class ContextReferencesTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        with pymupdf.open(PDF_PATH) as pdf:
            cls.text = '\n'.join(page.get_text() for page in pdf)

    def test_no_empty_page_references(self):
        # Bridgehead anchors once lost their page numbers when the anchor
        # sat inside the heading's title argument (issue #169).
        self.assertNotRegex(self.text, r'\(p\. \)')

    def test_selmao_catalog_references_use_names(self):
        # A selma'o anchor's xreflabel is the visible label, not the
        # containing section's number (issue #168).
        self.assertRegex(self.text, r'\bBE \(p\. \d+\)')
        self.assertRegex(self.text, r'\bLE \(p\. \d+\)')

    def test_grammar_rule_references_use_rule_numbers(self):
        self.assertRegex(self.text, r'BNF rule #\d+ \(p\. \d+\)')


if __name__ == '__main__':
    unittest.main()
