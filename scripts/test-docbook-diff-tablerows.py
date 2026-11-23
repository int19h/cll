#!/usr/bin/env python3
"""Whole added or deleted table rows in DocBook comparisons.

Only the innermost row whose own cells are all added (or all deleted)
is marked as one unit: one background and a single left bar on the
first cell, instead of styling each cell's content separately. A layout
row that merely contains a changed nested table is never marked.
Deleted rows keep their strikethrough. Rows with mixed changes keep
per-cell marking. Interlinear-gloss rows (per-word cells) are never
row-marked.
"""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).with_name('docbook-diff.py')

PAGE_HEAD = """<html><head><title>t</title></head><body>
<div class="toc"><div class="toc-title">Table of Contents</div>
<ul class="toc"><li><span class="chapter"><a href="#chapter-a">1. Chapter</a></span></li></ul></div>
<section class="chapter" id="chapter-a">
"""

ORDINARY_ADDED = """<table><tbody>
<tr><td><span class="added"><span class="phrase">new one</span></span></td>
<td><span class="added"><span class="phrase">new two</span></span></td></tr>
</tbody></table>
"""

ORDINARY_DELETED = """<table><tbody>
<tr><td><div class="deleted"><p>old one</p></div></td>
<td><div class="deleted"><p>old two</p></div></td></tr>
</tbody></table>
"""

ORDINARY_MIXED = """<table><tbody>
<tr><td><span class="added"><span class="phrase">new one</span></span></td>
<td>untouched two</td></tr>
</tbody></table>
"""

CMAVO_ADDED = """<table class="cmavo-list"><tbody>
<tr class="cmavo-entry"><td class="cmavo"><div class="added"><p>la'au</p></div></td>
<td class="selmaho"><div class="added"><p>LU*</p></div></td>
<td class="description"><div class="added"><p>name from grammatical text</p></div></td></tr>
</tbody></table>
"""

INTERLINEAR_ADDED = """<table class="interlinear-gloss"><tbody>
<tr class="jbo"><td><span class="added"><span class="phrase">mi</span></span></td>
<td><span class="added"><span class="phrase">klama</span></span></td></tr>
<tr class="gloss"><td><span class="added"><span class="phrase">I</span></span></td>
<td><span class="added"><span class="phrase">go</span></span></td></tr>
</tbody></table>
"""

WITH_EMPTY_CELL = """<table><tbody>
<tr><td><span class="added"><span class="phrase">new one</span></span></td><td> </td></tr>
</tbody></table>
"""

def word(text):
    return '<span class="added"><span class="phrase">%s</span></span>' % text


def cmavo_entry(cmavo, selmaho, description, added):
    wrap = '<div class="added">%s</div>' if added else '%s'
    cell = lambda cls, text: ('<td class="%s">%s</td>'
                              % (cls, wrap % ('<p class="%s">%s</p>' % (cls, text))))
    return ('<tr class="cmavo-entry">'
            + cell('cmavo', cmavo) + cell('selmaho', selmaho)
            + cell('description', description) + '</tr>')


# Two cmavo lists side by side in a noborder layout table, as in 18.2:
# only the first entry of the left list is added.
SIDE_BY_SIDE = (
    '<div class="informaltable"><table class="noborder"><tr>'
    '<td><div class="informaltable"><table class="cmavo-list">'
    + cmavo_entry("xo'e", 'PA', 'some number', True)
    + cmavo_entry('pa', 'PA', '1', False)
    + cmavo_entry('re', 'PA', '2', False)
    + '</table></div></td>'
    '<td><div class="informaltable"><table class="cmavo-list">'
    + cmavo_entry('vo', 'PA', '4', False)
    + '</table></div></td></tr></table></div>')

# A caption table holding a nested interlinear gloss (chapter 1 shape):
# a wholly added jbo line and gloss line must not become whole rows,
# and neither must the outer caption row that contains them. The plain
# added row after the nested table is still marked.
CAPTION_WITH_GLOSS = (
    '<table class="vertsep">'
    '<tr><td><a class="link" href="#c5">Chapter 5</a></td>'
    '<td><p> (none) </p></td></tr>'
    '<tr><td>' + word('Chapter 22') + '</td>'
    '<td><div class="informaltable"><table class="interlinear-gloss">'
    '<tr class="jbo"><td>' + word('mi') + '</td><td>' + word('klama') + '</td></tr>'
    '<tr class="gloss"><td>' + word('I') + '</td><td>' + word('go') + '</td></tr>'
    '</table></div></td></tr>'
    '<tr><td>' + word('Chapter 23') + '</td><td><p>' + word('(none)') + '</p></td></tr>'
    '</table>')

PAGE_TAIL = "</section></body></html>"


class TableRowTests(unittest.TestCase):
    def finish(self, *tables):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        root = Path(temp.name)
        (root / 'index.html').write_text(
            PAGE_HEAD + ''.join(tables) + PAGE_TAIL, encoding='utf-8')
        (root / 'stats.json').write_text(json.dumps({'statuses': {}, 'stats': {}}))
        run = subprocess.run(
            [sys.executable, str(SCRIPT), 'finish', str(root / 'index.html'),
             str(root / 'out'), '--old-label', 'Old', '--new-label', 'New',
             '--stats', str(root / 'stats.json')],
            capture_output=True, text=True)
        self.assertEqual(run.returncode, 0, run.stderr)
        return ((root / 'out' / 'difference.html').read_text(encoding='utf-8'),
                (root / 'out' / 'difference_prefixed.html').read_text(encoding='utf-8'))

    def test_fully_added_row_is_one_unit(self):
        page, prefixed = self.finish(ORDINARY_ADDED)
        self.assertIn('<tr class="diff-row-added">', page)
        # One marker for the row, not one per cell. The first direct
        # cell carries the single left bar.
        self.assertEqual(prefixed.count('<span class="diffmark">[+]</span>'), 1)
        self.assertIn('<td class="diff-row-first"><span class="diffmark">[+]</span>',
                      prefixed)
        self.assertIn('<td class="diff-row-first">', page)

    def test_fully_deleted_row_keeps_strike(self):
        page, prefixed = self.finish(ORDINARY_DELETED)
        self.assertIn('<tr class="diff-row-deleted">', page)
        self.assertIn('class="deleted"', page)  # strikethrough stays
        self.assertEqual(prefixed.count('<span class="diffmark">[\u2212]</span>'), 1)

    def test_cmavo_row_is_one_unit(self):
        page, prefixed = self.finish(CMAVO_ADDED)
        self.assertIn('cmavo-entry diff-row-added', page)
        self.assertEqual(prefixed.count('<span class="diffmark">[+]</span>'), 1)

    def test_mixed_row_keeps_per_cell_marking(self):
        page, prefixed = self.finish(ORDINARY_MIXED)
        self.assertNotIn('diff-row-added', page)
        self.assertNotIn('diff-row-deleted', page)
        self.assertEqual(prefixed.count('<span class="diffmark">[+]</span>'), 1)

    def test_interlinear_rows_are_not_row_marked(self):
        page, prefixed = self.finish(INTERLINEAR_ADDED)
        self.assertNotIn('diff-row-added', page)
        self.assertNotIn('diff-row-deleted', page)
        # ... but their per-word marks still work as today.
        self.assertGreater(prefixed.count('<span class="diffmark">[+]</span>'), 1)

    def test_empty_cell_does_not_block_row_marking(self):
        page, _ = self.finish(WITH_EMPTY_CELL)
        self.assertIn('<tr class="diff-row-added">', page)

    def test_nested_lists_mark_only_the_added_inner_row(self):
        # As in 18.2: the outer layout row merely contains the lists,
        # so it stays plain; the added inner entry becomes one row.
        page, prefixed = self.finish(SIDE_BY_SIDE)
        self.assertIn('<tr class="cmavo-entry diff-row-added">', page)
        self.assertEqual(page.count('diff-row-added'), 1)  # the inner row only
        self.assertNotIn('<tr class="diff-row-added">', page)
        self.assertNotIn('<table class="noborder diff-row-added">', page)
        # One marker for the inner row; the inner [+] marks are gone.
        self.assertEqual(prefixed.count('<span class="diffmark">[+]</span>'), 1)
        self.assertIn('<td class="cmavo diff-row-first">'
                      '<span class="diffmark">[+]</span>', prefixed)

    def test_caption_table_with_nested_gloss(self):
        # Wholly added jbo/gloss lines stay per-word marks, the outer
        # caption row stays plain, and the plain added row after the
        # nested table is still marked.
        page, prefixed = self.finish(CAPTION_WITH_GLOSS)
        self.assertNotIn('jbo diff-row-added', page)
        self.assertNotIn('gloss diff-row-added', page)
        self.assertIn('<table class="vertsep">', page)
        self.assertNotIn('<table class="vertsep diff-row-added">', page)
        self.assertIn('<tr class="diff-row-added">', page)
        # Four per-word marks in the gloss, one beside the Chapter 22
        # caption, one for the marked plain row: 4 + 1 + 1.
        self.assertEqual(prefixed.count('<span class="diffmark">[+]</span>'), 6)


if __name__ == '__main__':
    unittest.main()
