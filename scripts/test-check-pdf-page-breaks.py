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

    def test_bold_prose_example_mention_at_page_top_is_rejected_using_html_caption(self):
        # REAL 2: bold prose "**Example 1.1** (see Section 1.2 (p. 1))." at top
        # of p. 2 while the real caption "Example 1.1. Actual sample" is lower
        # on p. 2 must not count in split_colon or split_p_all; positive controls
        # (single-line, wrapped, and list-wrapped colon lead-in) must still fire.
        def build_case(temp, name, *, mode):
            pdf_path = Path(temp) / f'{name}.pdf'
            html_path = Path(temp) / f'{name}.html'
            doc = pymupdf.open()
            for _ in range(3):
                doc.new_page(width=450, height=680)
            p1, p2, p3 = doc[0], doc[1], doc[2]
            p1.insert_text((50, 75), 'Chapter 1', fontsize=14, fontname='hebo')
            p1.insert_text((50, 95), 'Intro', fontsize=14, fontname='hebo')
            p1.insert_text((50, 600), 'Consider the following example:', fontsize=9, fontname='helv')
            p3.insert_text((50, 75), 'Trailing page.', fontsize=9, fontname='helv')

            if mode == 'bold_prose':
                p2.insert_text((50, 70), 'Example 1.1', fontsize=9, fontname='hebo')
                w1 = pymupdf.get_text_length('Example 1.1', fontname='hebo', fontsize=9)
                rest = ' (see Section 1.2 (p. 1)).'
                p2.insert_text((50 + w1, 70), rest, fontsize=9, fontname='helv')
                pre = ' (see '
                lx = 50 + w1 + pymupdf.get_text_length(pre, fontname='helv', fontsize=9)
                lw = pymupdf.get_text_length('Section 1.2 (p. 1)', fontname='helv', fontsize=9)
                p2.insert_link({'kind': pymupdf.LINK_GOTO, 'from': pymupdf.Rect(lx - 1, 60, lx + lw + 1, 73), 'page': 0})
                p2.insert_text((50, 120), 'Example 1.1. Actual sample', fontsize=9, fontname='hebo')
                html = (
                    '<html><body><h1>Chapter 1 Intro</h1>'
                    '<p>Consider the following example:</p>'
                    '<p><b>Example 1.1</b> (see <a href="#s12">Section 1.2</a>).</p>'
                    '<div class="example"><div class="example-title">Example 1.1. Actual sample</div><p>Body</p></div>'
                    '</body></html>'
                )
            elif mode == 'regular_prose':
                p2.insert_text((50, 70), 'Example 1.1 (see Section 1.2 (p. 1)).', fontsize=9, fontname='helv')
                lx = 50 + pymupdf.get_text_length('Example 1.1 (see ', fontname='helv', fontsize=9)
                lw = pymupdf.get_text_length('Section 1.2 (p. 1)', fontname='helv', fontsize=9)
                p2.insert_link({'kind': pymupdf.LINK_GOTO, 'from': pymupdf.Rect(lx - 1, 60, lx + lw + 1, 73), 'page': 0})
                p2.insert_text((50, 120), 'Example 1.1. Actual sample', fontsize=9, fontname='hebo')
                html = (
                    '<html><body><h1>Chapter 1 Intro</h1>'
                    '<p>Consider the following example:</p>'
                    '<p>Example 1.1 (see <a href="#s12">Section 1.2</a>).</p>'
                    '<div class="example"><div class="example-title">Example 1.1. Actual sample</div><p>Body</p></div>'
                    '</body></html>'
                )
            elif mode == 'split_caption':
                p2.insert_text((50, 70), 'Example 1.1. See ', fontsize=9, fontname='hebo')
                w = pymupdf.get_text_length('Example 1.1. See ', fontname='hebo', fontsize=9)
                link_txt = 'Section 1.2 (p. 1)'
                p2.insert_text((50 + w, 70), link_txt, fontsize=9, fontname='helv')
                lw = pymupdf.get_text_length(link_txt, fontname='helv', fontsize=9)
                p2.insert_link({'kind': pymupdf.LINK_GOTO, 'from': pymupdf.Rect(50 + w - 1, 60, 50 + w + lw + 1, 73), 'page': 0})
                html = (
                    '<html><body><h1>Chapter 1 Intro</h1>'
                    '<p>Consider the following example:</p>'
                    '<div class="example"><div class="example-title">Example 1.1. See <a href="#s12">Section 1.2</a></div><p>Body</p></div>'
                    '</body></html>'
                )
            elif mode == 'wrapped_caption':
                p2.insert_text((50, 70), 'Example 1.1. See', fontsize=9, fontname='hebo')
                link_txt = 'Section 1.2 (p. 1)'
                p2.insert_text((50, 82), link_txt, fontsize=9, fontname='helv')
                lw = pymupdf.get_text_length(link_txt, fontname='helv', fontsize=9)
                p2.insert_link({'kind': pymupdf.LINK_GOTO, 'from': pymupdf.Rect(49, 72, 51 + lw, 85), 'page': 0})
                html = (
                    '<html><body><h1>Chapter 1 Intro</h1>'
                    '<p>Consider the following example:</p>'
                    '<div class="example"><div class="example-title">Example 1.1. See <a href="#s12">Section 1.2</a></div><p>Body</p></div>'
                    '</body></html>'
                )
            elif mode == 'list_wrapped_leadin':
                p2.insert_text((50, 70), 'Example 1.1. Actual sample', fontsize=9, fontname='hebo')
                html = (
                    '<html><body><h1>Chapter 1 Intro</h1>'
                    '<ul><li>Consider the following example:</li></ul>'
                    '<div class="example"><div class="example-title">Example 1.1. Actual sample</div><p>Body</p></div>'
                    '</body></html>'
                )
            else:
                raise ValueError(mode)

            doc.set_toc([[1, 'Chapter 1 Intro', 1]])
            doc.save(str(pdf_path))
            doc.close()
            html_path.write_text(html, encoding='utf-8')
            return MOD.audit_pdf(
                str(pdf_path),
                html_examples=MOD.load_html_p_examples(html_path),
                html_table_leadins=MOD.load_html_table_leadins(html_path),
                html_example_titles=MOD.load_html_example_titles(html_path),
            )

        with tempfile.TemporaryDirectory(prefix='cll-cpb-') as temp:
            for mode, want_colon, want_p in (
                ('bold_prose', [], []),
                ('regular_prose', [], []),
                ('split_caption', ['1.1'], ['1.1']),
                ('wrapped_caption', ['1.1'], ['1.1']),
                ('list_wrapped_leadin', ['1.1'], []),
            ):
                with self.subTest(mode=mode):
                    res = build_case(temp, mode, mode=mode)
                    self.assertEqual([x[1] for x in res['split_colon']], want_colon)
                    self.assertEqual([x[1] for x in res['split_p_all']], want_p)

    def test_stranded_section_heading_handles_wrapped_link_without_swallowing_prose(self):
        # Stranded-heading matching uses the outline title across wrapped lines
        # (including a wrapped inline link) without treating an unrelated bold
        # line containing '(p. 1)' as a heading continuation.
        with tempfile.TemporaryDirectory(prefix='cll-cpb-') as temp:
            for stranded in (True, False):
                with self.subTest(stranded=stranded):
                    pdf_path = Path(temp) / f'sec-{stranded}.pdf'
                    doc = pymupdf.open()
                    for _ in range(2):
                        doc.new_page(width=450, height=680)
                    p1, p2 = doc[0], doc[1]
                    p1.insert_text((50, 75), 'Chapter 1', fontsize=14, fontname='hebo')
                    p1.insert_text((50, 95), 'Intro', fontsize=14, fontname='hebo')
                    p1.insert_text((50, 560), '1.2. Summary of', fontsize=11, fontname='hebo')
                    link_txt = 'Example 1.1 (p. 1)'
                    p1.insert_text((50, 574), link_txt, fontsize=9, fontname='helv')
                    lw = pymupdf.get_text_length(link_txt, fontname='helv', fontsize=9)
                    p1.insert_link({'kind': pymupdf.LINK_GOTO, 'from': pymupdf.Rect(49, 564, 51 + lw, 577), 'page': 0})
                    if not stranded:
                        p1.insert_text((50, 592), 'Following body paragraph referring to (p. 1).', fontsize=9, fontname='helv')
                    p2.insert_text((50, 75), 'Next page body.', fontsize=9, fontname='helv')
                    doc.set_toc([
                        [1, 'Chapter 1 Intro', 1],
                        [2, '1.2. Summary of Example 1.1', 1],
                    ])
                    doc.save(str(pdf_path))
                    doc.close()

                    res = MOD.audit_pdf(str(pdf_path))
                    if stranded:
                        self.assertEqual(len(res['stranded_bare']), 1)
                    else:
                        self.assertEqual(res['stranded_bare'], [])

    def test_html_class_matching_rejects_nbsp_separator(self):
        html = (
            '<p>Intro before nbsp example:</p>'
            '<div class="example\u00a0extra"><div class="example-title">Example 1.1</div></div>'
            '<p>Lead before nbsp table:</p>'
            '<div class="table\u00a0extra"><table><tr><td>a</td></tr></table></div>'
        )
        with tempfile.TemporaryDirectory(prefix='cll-cpb-') as temp:
            path = Path(temp) / 'nbsp.html'
            path.write_text(html, encoding='utf-8')
            self.assertEqual(MOD.load_html_p_examples(path), {})
            self.assertEqual(MOD.load_html_example_titles(path), {})
            self.assertEqual(MOD.load_html_table_leadins(path), set())


if __name__ == '__main__':
    unittest.main()
