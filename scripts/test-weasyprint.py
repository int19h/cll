#!/usr/bin/env python3
"""Exercise math conversion, linked index pagination, and failure handling."""
import importlib.util
import os
from pathlib import Path
import tempfile
import unittest

from lxml import html
from weasyprint.urls import FatalURLFetchingError

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('cll_weasyprint', ROOT / 'scripts/weasyprint/render.py')
backend = importlib.util.module_from_spec(spec)
spec.loader.exec_module(backend)


class PreparationTests(unittest.TestCase):
    def test_span_uses_column_width_and_row_spans(self):
        tree = html.fromstring('''<table><tbody>
          <tr><td rowspan="2">A</td><td colspan="2">B</td></tr>
          <tr><td>C</td><td>D</td></tr>
          <tr><td colspan="12321">translation</td></tr>
          </tbody></table>''')
        self.assertEqual(backend.normalize_spans(tree), 1)
        self.assertEqual(tree.xpath('.//tr[last()]/td')[0].get('colspan'), '3')

    def test_invalid_sentinel_fails(self):
        tree = html.fromstring('<table><tr><td colspan="12321">A</td><td>B</td></tr></table>')
        with self.assertRaises(ValueError):
            backend.normalize_spans(tree)

    def test_index_keeps_markup_and_see_also(self):
        tree = html.fromstring('''<div class="whole-index"><dl><dt>
          <em>term</em>, <a class="indexterm" href="#c">C</a>,
          <a class="indexterm" href="#a">A</a>, <a class="indexterm" href="#b">B</a>,
          <a class="indexterm" href="#a">A</a> (see <a href="#other">other</a>)
          </dt></dl></div>''')
        [(span, targets)] = backend.collect_indexes(tree)
        ranges = backend.page_ranges(targets, {'a': 1, 'b': 2, 'c': 3})
        backend.write_index(span, ranges)
        self.assertEqual(''.join(span.itertext()), '1–3')
        self.assertEqual(span.xpath('./a/@href'), ['#a', '#c'])
        self.assertEqual(tree.xpath('.//em')[0].text, 'term')
        self.assertIn('(see other)', tree.text_content())
        self.assertEqual(tree.xpath('.//a[@href="#other"]')[0].text, 'other')

    def test_missing_target_fails(self):
        with self.assertRaisesRegex(ValueError, 'missing'):
            backend.page_ranges(['absent'], {})


class RenderingTests(unittest.TestCase):
    def setUp(self):
        base = ROOT / 'build/weasyprint-tests'
        base.mkdir(parents=True, exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=base)
        self.directory = Path(self.temp.name)
        (self.directory / 'weasyprint.css').write_text('')

    def tearDown(self):
        self.temp.cleanup()

    def test_math_and_converged_index(self):
        source = self.directory / 'input.html'
        source.write_text('''<!doctype html><html><head><meta charset="utf-8">
          <style>@page {size:100mm 120mm;margin:10mm} .newpage {break-before:page}</style>
          </head><body><p id="a">First page: “huáiyùn” 中文</p>
          <math xmlns="http://www.w3.org/1998/Math/MathML"><mfrac><mn>2</mn><mn>7</mn></mfrac></math>
          <p id="b" class="newpage">Second page</p>
          <p id="c" class="newpage">Third page</p>
          <div class="whole-index newpage"><dl><dt>term,
          <a class="indexterm" href="#c">Third</a>, <a class="indexterm" href="#a">First</a>,
          <a class="indexterm" href="#b">Second</a>, <a class="indexterm" href="#a">First</a>
          </dt></dl></div></body></html>''')
        pdf = self.directory / 'result.pdf'
        report = backend.render(source, pdf)
        self.assertTrue(pdf.read_bytes().startswith(b'%PDF-'))
        self.assertEqual(report['pages'], 4)
        self.assertEqual(report['passes'], 2)
        self.assertEqual(report['index_targets'], {'a': 1, 'b': 2, 'c': 3})
        self.assertEqual(report['mathjax']['expressions'], 1)
        prepared = html.parse(str(self.directory / 'cll-weasyprint.html'))
        self.assertEqual(prepared.xpath('//span[@class="index-pages"]')[0].text_content(), '1–3')
        self.assertEqual(len(prepared.xpath('//mjx-mfrac')), 1)
        self.assertFalse(prepared.xpath('//math | //script'))
        self.assertTrue(list((self.directory / 'mathjax-fonts').glob('*.woff2')))
        # Exercise the consumer's encoding detection, not just lxml's decoding.
        parsed = backend.HTML(filename=str(self.directory / 'cll-weasyprint.html'))
        self.assertIn('“huáiyùn” 中文', ''.join(parsed.etree_element.itertext()))

    def test_missing_image_does_not_publish_pdf(self):
        source = self.directory / 'input.html'
        source.write_text('<html><head></head><body><img src="missing.png"></body></html>')
        pdf = self.directory / 'result.pdf'
        pdf.write_bytes(b'existing PDF')
        with self.assertRaises(FatalURLFetchingError):
            backend.render(source, pdf)
        self.assertEqual(pdf.read_bytes(), b'existing PDF')

    def test_hidden_vocabulary_keeps_index_anchor_without_text(self):
        (self.directory / 'weasyprint.css').write_text(
            '.display-none {display:none} .index-markers {height:0;line-height:0;font-size:0}')
        source = self.directory / 'input.html'
        source.write_text('''<html><head></head><body><h1>Reading passage</h1>
          <p class="display-none"><em><a id="word-marker" class="indexterm"></a>invisible-seed</em></p>
          <p>The visible passage.</p><div class="whole-index"><dl><dt>word,
          <a class="indexterm" href="#word-marker">Reading passage</a></dt></dl></div>
          </body></html>''')
        report = backend.render(source, self.directory / 'result.pdf')
        self.assertEqual(report['relocated_hidden_index_anchors'], 1)
        self.assertEqual(report['index_targets']['word-marker'], 1)
        prepared = html.parse(str(self.directory / 'cll-weasyprint.html'))
        self.assertEqual(len(prepared.xpath('//*[@id="word-marker"]')), 1)
        self.assertEqual(prepared.xpath('//div[@class="index-markers"]')[0].text_content(), '')
        self.assertIn('invisible-seed', prepared.xpath('//p[@class="display-none"]')[0].text_content())

    def test_invalid_math_does_not_publish_pdf(self):
        source = self.directory / 'input.html'
        source.write_text('''<html><head></head><body>
          <math xmlns="http://www.w3.org/1998/Math/MathML"><mfrac><mn>2</mn></mfrac></math>
          </body></html>''')
        pdf = self.directory / 'result.pdf'
        with self.assertRaisesRegex(RuntimeError, 'MathJax conversion failed'):
            backend.render(source, pdf)
        self.assertFalse(pdf.exists())


if __name__ == '__main__':
    unittest.main()
