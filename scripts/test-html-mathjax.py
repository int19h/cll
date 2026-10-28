#!/usr/bin/env python3
"""Require a fixed browser MathJax release in every HTML build."""
import base64
import hashlib
from pathlib import Path
import sys
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
XSL = '{http://www.w3.org/1999/XSL/Transform}'


class HtmlMathJaxTest(unittest.TestCase):
    def test_browser_dependency(self):
        root = ET.parse(ROOT / 'xml/docbook2html_config_xhtml.xsl').getroot()
        head = root.find(f"{XSL}template[@name='user.head.content']")
        scripts = head.findall('script')
        external = [node for node in scripts if node.get('src')]
        self.assertEqual(len(external), 1)
        script = external[0]
        self.assertEqual(script.get('src'),
                         'https://cdn.jsdelivr.net/npm/mathjax@3.2.2/es5/tex-mml-chtml.js')
        integrity = script.get('integrity', '')
        self.assertTrue(integrity.startswith('sha384-'))
        self.assertEqual(len(base64.b64decode(integrity[7:], validate=True)), 48)
        self.assertEqual(script.get('crossorigin'), 'anonymous')
        configuration = next(node for node in scripts if 'MathJax =' in (node.text or ''))
        self.assertLess(scripts.index(configuration), scripts.index(script))
        if len(sys.argv) == 2:
            downloaded = Path(sys.argv[1]).read_bytes()
            actual = base64.b64encode(hashlib.sha384(downloaded).digest()).decode()
            self.assertEqual(integrity, 'sha384-' + actual)


if __name__ == '__main__':
    unittest.main(argv=[sys.argv[0]])
