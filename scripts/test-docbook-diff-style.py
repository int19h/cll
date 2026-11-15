#!/usr/bin/env python3
"""The comparison stylesheet must keep glyph substitutions inside one change."""
from pathlib import Path
import unittest

STYLE = Path(__file__).with_name('docbook-diff-style.xsl').read_text(encoding='utf-8')


class StyleTests(unittest.TestCase):
    def test_change_spans_disable_cross_boundary_substitutions(self):
        # Both drivers include this stylesheet. The counters have to cover
        # the inner phrase, because a Lojban span turns the features back on.
        self.assertIn('span.added, span.deleted,\nspan.added *, span.deleted *', STYLE)
        self.assertIn('font-variant-ligatures: none !important', STYLE)
        self.assertIn('font-variant-numeric: normal !important', STYLE)
        for feature in ('liga', 'clig', 'dlig', 'hlig', 'calt', 'frac'):
            self.assertIn('"%s" 0' % feature, STYLE)
        self.assertIn('span.added::before, span.added::after,\n'
                      'span.deleted::before, span.deleted::after { content: "\\200c"; }',
                      STYLE)

    def test_ordinary_text_is_not_restyled(self):
        self.assertNotIn('body {', STYLE)
        self.assertNotIn('p {', STYLE)
        rule = STYLE.split('span.added, span.deleted,\nspan.added *, span.deleted * {', 1)[1]
        rule = rule.split('}', 1)[0]
        self.assertIn('font-variant-ligatures: none !important', rule)
        self.assertNotIn('font-variant-ligatures: none', STYLE.replace(rule, '', 1))


if __name__ == '__main__':
    unittest.main()
