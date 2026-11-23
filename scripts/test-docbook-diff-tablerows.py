#!/usr/bin/env python3
"""Whole added or deleted table rows in DocBook comparisons.

When every cell of a table row holds only added (or only deleted)
material, finish() must mark the row as one unit: one background and a
single left bar on the first cell, instead of styling each cell's content
separately. Deleted rows keep their strikethrough. Rows with mixed
changes keep per-cell marking. Interlinear-gloss rows (per-word cells)
are never row-marked.
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
        # One marker for the row, not one per cell.
        self.assertEqual(prefixed.count('<span class="diffmark">[+]</span>'), 1)
        self.assertIn('<td><span class="diffmark">[+]</span>', prefixed)

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


if __name__ == '__main__':
    unittest.main()
