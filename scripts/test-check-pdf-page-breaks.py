#!/usr/bin/env python3
"""Unit tests for HTML class-token matching in scripts/check-pdf-page-breaks.py."""
import importlib.util
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    'check_pdf_page_breaks', ROOT / 'scripts/check-pdf-page-breaks.py')
MOD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MOD)


class CheckPdfPageBreaksHtmlTests(unittest.TestCase):
    def test_table_leadins_skip_multi_token_marker_paragraphs(self):
        html = (
            '<p>Lead before plain marker:</p>'
            '<p class="allowbreaks"></p>'
            '<div class="informaltable"><table><tr><td>a</td></tr></table></div>'
            '<p>Lead before multi-token markers:</p>'
            '<p id="m1" class="extra twocolumn"></p>'
            '<p class="allowbreaks extra"></p>'
            '<div class="parallel-text informaltable"><table><tr><td>b</td></tr></table></div>'
            '<p>Lead before table-title only (must not match table div):</p>'
            '<div class="table-title">Not a table wrapper</div>'
            '<p>Lead before non-marker class:</p>'
            '<p class="not-allowbreaks"></p>'
            '<div class="table"><table><tr><td>c</td></tr></table></div>'
        )
        with tempfile.TemporaryDirectory(prefix='cll-cpb-') as temp:
            path = Path(temp) / 'sample.html'
            path.write_text(html, encoding='utf-8')
            tails = MOD.load_html_table_leadins(str(path))
        self.assertIn('Lead before plain marker:', tails)
        self.assertIn('Lead before multi-token markers:', tails)
        self.assertNotIn('Lead before table-title only (must not match table div):', tails)
        self.assertNotIn('Lead before non-marker class:', tails)

    def test_p_examples_match_multi_token_classes_without_hyphen_false_hits(self):
        html = (
            '<p>Intro to example A.1:</p>'
            '<div id="ex1" class="interlinear-gloss-example example">'
            '<div id="t1" class="extra example-title">Example A.1</div>'
            '<div class="example-contents"><p>Body</p></div>'
            '</div>'
            '<p>Intro to fake title-only div:</p>'
            '<div class="example-title">Example 9.9</div>'
        )
        with tempfile.TemporaryDirectory(prefix='cll-cpb-') as temp:
            path = Path(temp) / 'sample.html'
            path.write_text(html, encoding='utf-8')
            examples = MOD.load_html_p_examples(str(path))
        self.assertIn('A.1', examples)
        self.assertTrue(examples['A.1'][0])
        self.assertIn('Intro to example A.1:', examples['A.1'][1])
        self.assertNotIn('9.9', examples)


if __name__ == '__main__':
    unittest.main()
