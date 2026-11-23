#!/usr/bin/env python3
"""Table-of-contents change markers in DocBook comparisons.

A comparison page must mark, on each table-of-contents entry's section
NUMBER (never the title, whose inline diffs keep working):
  * amber (#ffd84d) when the surviving section changed anywhere under it;
  * the existing added green for an entirely new section;
  * the existing deleted pink, struck through, for a deleted section.
Each marked number carries a tooltip with per-section block counts, and
difference_prefixed.html puts [*] (changed), [+] (added) or [-] (deleted)
before the number. The banner of both pages explains the marks.
"""
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET

SCRIPT = Path(__file__).with_name('docbook-diff.py')
XML_ID = '{http://www.w3.org/XML/1998/namespace}id'


def chapter_file(*sections):
    return ('<chapter xml:id="chapter-a"><title>Chapter</title>'
            + ''.join(sections) + '</chapter>')


def section(sec_id, title, *paras):
    return ('<section xml:id="%s"><title>%s</title>' % (sec_id, title)
            + ''.join(paras) + '</section>')


class TocMainTests(unittest.TestCase):
    """docbook-diff.py main() reports per-section block counts."""

    def compare(self, old, new):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        root = Path(temp.name)
        for name, content in [('old', old), ('new', new)]:
            chapter = root / name / 'chapters' / '01.xml'
            chapter.parent.mkdir(parents=True)
            chapter.write_text(content)
        output = root / 'out' / 'chapters'
        output.mkdir(parents=True)
        run = subprocess.run([sys.executable, str(SCRIPT), str(root / 'old'),
                              str(root / 'new'), str(root / 'out')],
                             capture_output=True, text=True)
        self.assertEqual(run.returncode, 0, run.stderr)
        result = json.loads(run.stdout)
        tree = ET.parse(output / '01.xml').getroot()
        return result, tree

    def test_changed_section_with_unchanged_title(self):
        result, _ = self.compare(
            chapter_file(section('section-a', 'Section',
                                 '<para>Keep this sentence. Old words here.</para>')),
            chapter_file(section('section-a', 'Section',
                                 '<para>Keep this sentence. New words here.</para>')))
        sections = result.get('sections', {})
        self.assertEqual(sections.get('section-a', {}).get('status'), 'changed')
        self.assertEqual(sections['section-a'].get('chg'), 1)
        self.assertEqual(sections.get('chapter-a', {}).get('status'), 'changed')

    def test_entirely_retitled_section_still_counts_as_changed(self):
        result, tree = self.compare(
            chapter_file(section('section-a', 'Old title words',
                                 '<para>Keep this sentence.</para>')),
            chapter_file(section('section-a', 'Completely different heading',
                                 '<para>Keep this sentence.</para>')))
        sections = result.get('sections', {})
        self.assertEqual(sections.get('section-a', {}).get('status'), 'changed')
        # The title keeps its own strikeout and green at the DocBook level.
        titles = [el for el in tree.iter() if el.tag == 'title']
        flags = [el.get('revisionflag') for el in tree.iter()]
        self.assertIn('deleted', flags)
        self.assertIn('added', flags)
        self.assertTrue(titles)

    def test_new_section_reported_added(self):
        result, _ = self.compare(
            chapter_file(section('section-a', 'Section',
                                 '<para>Keep this sentence.</para>')),
            chapter_file(section('section-a', 'Section',
                                 '<para>Keep this sentence.</para>'),
                         section('section-b', 'Brand new',
                                 '<para>First new paragraph.</para>'
                                 '<para>Second new paragraph.</para>')))
        sections = result.get('sections', {})
        entry = sections.get('section-b', {})
        self.assertEqual(entry.get('status'), 'added')
        self.assertEqual(entry.get('ins'), 3)  # title plus two paragraphs
        self.assertNotIn('section-a', sections)

    def test_deleted_section_reported_deleted_and_keeps_its_id(self):
        result, tree = self.compare(
            chapter_file(section('section-a', 'Section',
                                 '<para>Keep this sentence.</para>'),
                         section('section-b', 'Doomed',
                                 '<para>First doomed paragraph.</para>'
                                 '<para>Second doomed paragraph.</para>')),
            chapter_file(section('section-a', 'Section',
                                 '<para>Keep this sentence.</para>')))
        sections = result.get('sections', {})
        entry = sections.get('section-b', {})
        self.assertEqual(entry.get('status'), 'deleted')
        self.assertEqual(entry.get('del'), 3)  # title plus two paragraphs
        # The re-inserted copy keeps its id, so the ToC link still resolves.
        ids = [el.get(XML_ID) for el in tree.iter() if isinstance(el.tag, str)]
        self.assertIn('section-b', ids)


PAGE_HEAD = """<html><head><title>t</title></head><body>
<div class="toc"><div class="toc-title">Table of Contents</div>
<ul class="toc">
<li><span class="chapter"><a href="#chapter-a">1. Chapter</a></span><ul>
<li><span class="section"><a href="#section-a">1.1. Unchanged title</a></span></li>
<li><span class="section"><a href="#section-b">1.2. Old <span class="deleted"><span class="phrase">words</span></span><span class="added"><span class="phrase">different heading</span></span></a></span></li>
<li><span class="section"><a href="#section-c">1.3. New section</a></span></li>
<li><span class="section"><a href="#section-d">1.4. Deleted section</a></span></li>
<li><span class="section"><a href="#glossary">Lojban Words Glossary</a></span></li>
</ul></li></ul></div>
"""

PAGE_BODY = """<section class="chapter" id="chapter-a">
<h1 class="title">Chapter 1. Chapter</h1>
<section class="section" id="section-a"><h2 class="title">1.1. Unchanged title</h2>
<p>Keep this <span class="added"><span class="phrase">inserted word</span></span> here.</p></section>
<section class="section" id="section-b"><h2 class="title">1.2. <span class="deleted"><span class="phrase">Old words</span></span> <span class="added"><span class="phrase">different heading</span></span></h2>
<p>Keep this sentence.</p></section>
<section class="section" id="section-c"><div class="added"><p>First new paragraph.</p><p>Second new paragraph.</p></div></section>
<div class="deleted"><section class="section" id="section-d"><h2 class="title">1.4. Deleted section</h2>
<p>Doomed paragraph.</p></section></div>
</section></body></html>
"""

STATS = {
    'statuses': {'chg': 4, 'ins': 4, 'del': 2},
    'stats': {},
    'sections': {
        'chapter-a': {'status': 'changed', 'chg': 2, 'ins': 2, 'del': 1, 'mov': 0},
        'section-a': {'status': 'changed', 'chg': 1, 'ins': 0, 'del': 0, 'mov': 0},
        'section-b': {'status': 'changed', 'chg': 1, 'ins': 0, 'del': 0, 'mov': 0},
        'section-c': {'status': 'added', 'chg': 0, 'ins': 2, 'del': 0, 'mov': 0},
        'section-d': {'status': 'deleted', 'chg': 0, 'ins': 0, 'del': 1, 'mov': 0},
    },
}


class TocFinishTests(unittest.TestCase):
    """docbook-diff.py finish() marks ToC numbers and explains them."""

    def finish(self, page=PAGE_HEAD + PAGE_BODY, stats=None):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        root = Path(temp.name)
        (root / 'index.html').write_text(page, encoding='utf-8')
        args = [sys.executable, str(SCRIPT), 'finish', str(root / 'index.html'),
                str(root / 'out'), '--old-label', 'Old', '--new-label', 'New']
        if stats is not False:
            (root / 'stats.json').write_text(
                json.dumps(stats if stats is not None else STATS))
            args += ['--stats', str(root / 'stats.json')]
        run = subprocess.run(args, capture_output=True, text=True)
        self.assertEqual(run.returncode, 0, run.stderr)
        return ((root / 'out' / 'difference.html').read_text(encoding='utf-8'),
                (root / 'out' / 'difference_prefixed.html').read_text(encoding='utf-8'))

    def test_changed_number_gets_amber_and_tooltip(self):
        page, _ = self.finish()
        self.assertIn('<span class="diff-toc-changed" title="1 block changed">1.1.</span>'
                      ' Unchanged title', page)

    def test_retitled_entry_keeps_title_diffs(self):
        page, _ = self.finish()
        self.assertIn('<span class="diff-toc-changed" title="1 block changed">1.2.</span>'
                      ' Old <span class="deleted">', page)
        self.assertIn('<span class="added"><span class="phrase">different heading</span></span>',
                      page)

    def test_new_section_number_gets_green(self):
        page, _ = self.finish()
        self.assertIn('<span class="diff-toc-added" title="2 blocks added">1.3.</span>'
                      ' New section', page)

    def test_deleted_section_number_gets_pink_strike(self):
        page, _ = self.finish()
        self.assertIn('<span class="diff-toc-deleted" title="1 block deleted">1.4.</span>'
                      ' Deleted section', page)

    def test_chapter_number_gets_amber(self):
        page, _ = self.finish()
        self.assertIn('<span class="diff-toc-changed" '
                      'title="2 blocks changed, 2 added, 1 deleted">1.</span>'
                      ' Chapter', page)

    def test_numberless_entry_is_left_alone(self):
        page, _ = self.finish()
        self.assertIn('<a href="#glossary">Lojban Words Glossary</a>', page)

    def test_prefixed_marks_before_numbers(self):
        _, prefixed = self.finish()
        self.assertIn('<span class="diffmark">[*]</span>'
                      '<span class="diff-toc-changed"', prefixed)
        self.assertIn('<span class="diffmark">[+]</span>'
                      '<span class="diff-toc-added"', prefixed)
        self.assertIn('<span class="diffmark">[\u2212]</span>'
                      '<span class="diff-toc-deleted"', prefixed)

    def test_banner_explains_toc_marks_in_both_pages(self):
        page, prefixed = self.finish()
        for variant in (page, prefixed):
            self.assertIn('table of contents', variant.lower())
            self.assertIn('#ffd84d', variant)
            self.assertIn('#97f295', variant)
            self.assertIn('#ffb6ba', variant)
            # The existing explanations stay right.
            self.assertIn('Moved material itself is not marked at its new place.',
                          variant)
            self.assertIn('ignores differences that are only in the formatting.',
                          variant)


if __name__ == '__main__':
    unittest.main()
