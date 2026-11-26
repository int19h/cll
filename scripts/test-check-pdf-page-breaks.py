#!/usr/bin/env python3
"""Unit tests for HTML class-token matching in scripts/check-pdf-page-breaks.py."""
import importlib.util
from pathlib import Path
import tempfile
import unittest

import pymupdf

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

    def test_example_caption_with_nested_xref_is_not_vetoed_while_self_ref_is(self):
        # A genuine example caption at page top containing a nested inline xref
        # must still be detected as a split colon-ending lead-in, while a bold
        # inline self-reference "Example 1.2 (p. 3)" at page top must be ignored.
        with tempfile.TemporaryDirectory(prefix='cll-cpb-') as temp:
            pdf_path = Path(temp) / 'nested.pdf'
            doc = pymupdf.open()
            for _ in range(3):
                doc.new_page(width=450, height=680)
            p1, p2, p3 = doc[0], doc[1], doc[2]
            p1.insert_text((50, 75), 'Chapter 1', fontsize=14, fontname='hebo')
            p1.insert_text((50, 95), 'Intro', fontsize=14, fontname='hebo')
            p1.insert_text((50, 600), 'Consider the following example:', fontsize=9, fontname='helv')

            # Page 2 top: real caption with a nested inline xref link.
            p2.insert_text((50, 70), 'Example 1.1. See ', fontsize=9, fontname='hebo')
            w = pymupdf.get_text_length('Example 1.1. See ', fontname='hebo', fontsize=9)
            link_txt = 'Section 1.2 (p. 1)'
            p2.insert_text((50 + w, 70), link_txt, fontsize=9, fontname='helv')
            lw = pymupdf.get_text_length(link_txt, fontname='helv', fontsize=9)
            p2.insert_link({
                'kind': pymupdf.LINK_GOTO,
                'from': pymupdf.Rect(50 + w - 1, 60, 50 + w + lw + 1, 73),
                'page': 0,
            })
            p2.insert_text((50, 600), 'Another colon lead-in:', fontsize=9, fontname='helv')

            # Page 3 top: bold self-reference (NOT an example heading).
            p3.insert_text((50, 70), 'Example 1.2 (p. 2) shows this.', fontsize=9, fontname='hebo')

            doc.set_toc([[1, 'Chapter 1 Intro', 1]])
            doc.save(str(pdf_path))
            doc.close()

            res = MOD.audit_pdf(str(pdf_path))
            split_nums = [ex_num for _, ex_num, _ in res['split_colon']]
            self.assertEqual(split_nums, ['1.1'])


if __name__ == '__main__':
    unittest.main()
