#!/usr/bin/env python3
"""Table-of-contents change markers in DocBook comparisons.

A comparison page must mark, on each table-of-contents entry's section
NUMBER (never the title, whose inline diffs keep working):
  * light blue (#a9c8ff) when the surviving section changed anywhere under it;
  * the existing added green for an entirely new section;
  * the existing deleted pink, struck through, for a deleted section.
Each marked number carries a tooltip naming its visible change kinds, and
difference_prefixed.html puts [*] (changed), [+] (added) or [-] (deleted)
before the number. The banner of both pages explains the marks.
"""
import json
from html.parser import HTMLParser
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
    """docbook-diff.py main() reports per-section visible change kinds."""

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
        self.assertTrue(sections['section-a'].get('changed'))
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
        self.assertTrue(entry.get('added'))
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
        self.assertTrue(entry.get('deleted'))
        # The re-inserted copy keeps its id, so the ToC link still resolves.
        ids = [el.get(XML_ID) for el in tree.iter() if isinstance(el.tag, str)]
        self.assertIn('section-b', ids)

    def test_deleted_paragraph_marks_section_and_chapter(self):
        # Losing a block is a change even though nothing was added.
        result, _ = self.compare(
            chapter_file(section('section-a', 'Section',
                                 '<para>Keep this sentence.</para>'
                                 '<para>Drop this whole paragraph.</para>')),
            chapter_file(section('section-a', 'Section',
                                 '<para>Keep this sentence.</para>')))
        sections = result.get('sections', {})
        self.assertEqual(sections.get('section-a', {}).get('status'), 'changed')
        self.assertTrue(sections['section-a'].get('deleted'))
        self.assertEqual(sections.get('chapter-a', {}).get('status'), 'changed')

    def test_deleted_subsection_marks_its_parents(self):
        result, tree = self.compare(
            chapter_file(section('section-a', 'Section',
                                 '<para>Keep this sentence.</para>',
                                 section('section-sub', 'Gone',
                                         '<para>Doomed text one.</para>'
                                         '<para>Doomed text two.</para>'))),
            chapter_file(section('section-a', 'Section',
                                 '<para>Keep this sentence.</para>')))
        sections = result.get('sections', {})
        self.assertEqual(sections.get('section-sub', {}).get('status'), 'deleted')
        self.assertEqual(sections.get('section-a', {}).get('status'), 'changed')
        self.assertEqual(sections.get('chapter-a', {}).get('status'), 'changed')
        ids = [el.get(XML_ID) for el in tree.iter() if isinstance(el.tag, str)]
        self.assertIn('section-sub', ids)

    def test_moved_out_marks_source_and_destination(self):
        first = ('The first paragraph has a fair amount of distinctive text '
                 'in it so it can move.')
        mid = ''.join('<para>Stable paragraph number %d with some words to '
                      'anchor alignment here.</para>' % k for k in range(8))
        old = (chapter_file(section('section-a', 'Alpha',
                                    '<para>Keep one here.</para>'
                                    '<para>' + first + '</para>')
                            + '<section xml:id="section-m"><title>Middle</title>'
                            + mid + '</section>'
                            + section('section-b', 'Beta',
                                      '<para>Keep two here.</para>')))
        new = (chapter_file(section('section-a', 'Alpha',
                                    '<para>Keep one here.</para>')
                            + '<section xml:id="section-m"><title>Middle</title>'
                            + mid + '</section>'
                            + section('section-b', 'Beta',
                                      '<para>Keep two here.</para>'
                                      '<para>' + first + '</para>')))
        result, _ = self.compare(old, new)
        sections = result.get('sections', {})
        self.assertEqual(sections.get('section-a', {}).get('status'), 'changed')
        self.assertTrue(sections['section-a'].get('moved'))
        self.assertEqual(sections.get('section-b', {}).get('status'), 'changed')
        self.assertEqual(sections.get('chapter-a', {}).get('status'), 'changed')
        self.assertTrue(sections['section-b'].get('moved'))
        self.assertTrue(sections['chapter-a'].get('moved'))

    def test_multiblock_move_marks_source_destination_and_parent(self):
        # A moved example has one visible note at its source and moved
        # lines at its destination; either kind of evidence marks moved.
        example = ('<example><interlinear-gloss>'
                   '<jbo>mi klama lo zarci i lo sa zdani li u</jbo>'
                   '<gloss>I go-to a market and then to a house.</gloss>'
                   '<natlang>I went to the market and then to the house.</natlang>'
                   '</interlinear-gloss></example>')
        mid = ''.join('<para>Stable paragraph number %d with some words to '
                      'anchor alignment here.</para>' % k for k in range(8))
        old = (chapter_file(section('section-a', 'Alpha',
                                    '<para>Keep one here.</para>' + example)
                            + '<section xml:id="section-m"><title>Middle</title>'
                            + mid + '</section>'
                            + section('section-d', 'Delta',
                                      '<para>Keep two here.</para>')))
        new = (chapter_file(section('section-a', 'Alpha',
                                    '<para>Keep one here.</para>')
                            + '<section xml:id="section-m"><title>Middle</title>'
                            + mid + '</section>'
                            + section('section-d', 'Delta',
                                      '<para>Keep two here.</para>' + example)))
        result, _ = self.compare(old, new)
        sections = result.get('sections', {})
        self.assertTrue(sections['section-a'].get('moved'))
        self.assertTrue(sections['section-d'].get('moved'))
        self.assertTrue(sections['chapter-a'].get('moved'))

    def test_moved_and_changed_line_also_marks_changed(self):
        # A moved example whose gloss changes shows added and struck words
        # at its destination: movechg means both moved and changed.
        old_example = ('<example><interlinear-gloss>'
                       '<jbo>mi klama lo zarci i lo sa zdani li u</jbo>'
                       '<gloss>I go-to a market and then to a house.</gloss>'
                       '<natlang>I went to the market and then to the house.</natlang>'
                       '</interlinear-gloss></example>')
        new_example = old_example.replace('and then to a house',
                                          'and later to a house')
        mid = ''.join('<para>Stable paragraph number %d with some words to '
                      'anchor alignment here.</para>' % k for k in range(8))
        old = (chapter_file(section('section-a', 'Alpha',
                                    '<para>Keep one here.</para>' + old_example)
                            + '<section xml:id="section-m"><title>Middle</title>'
                            + mid + '</section>'
                            + section('section-d', 'Delta',
                                      '<para>Keep two here.</para>')))
        new = (chapter_file(section('section-a', 'Alpha',
                                    '<para>Keep one here.</para>')
                            + '<section xml:id="section-m"><title>Middle</title>'
                            + mid + '</section>'
                            + section('section-d', 'Delta',
                                      '<para>Keep two here.</para>' + new_example)))
        result, _ = self.compare(old, new)
        sections = result.get('sections', {})
        self.assertTrue(sections['section-d'].get('moved'))
        self.assertTrue(sections['section-d'].get('changed'))
        self.assertTrue(sections['chapter-a'].get('changed'))

    def test_renamed_section_counts_as_surviving(self):
        # Same content under a new id: the section survived (blue),
        # not a wholly new one, and nothing counts as deleted.
        result, _ = self.compare(
            chapter_file(section('section-a', 'Alpha',
                                 '<para>Keep one here.</para>'
                                 '<para>Keep two here.</para>')),
            chapter_file(section('section-b', 'Alpha',
                                 '<para>Keep one here.</para>'
                                 '<para>Keep two here.</para>')))
        sections = result.get('sections', {})
        self.assertEqual(sections.get('section-b', {}).get('status'), 'changed')
        self.assertNotIn('section-a', sections)

    def test_renamed_section_with_changed_content(self):
        # Most content paired with one old section: changed, with the
        # visibly struck deletion counted in the annotated subtree.
        result, _ = self.compare(
            chapter_file(section('section-a', 'Alpha',
                                 '<para>Keep one here.</para>'
                                 '<para>Drop this paragraph.</para>')),
            chapter_file(section('section-b', 'Alpha',
                                 '<para>Keep one here.</para>')))
        sections = result.get('sections', {})
        self.assertEqual(sections.get('section-b', {}).get('status'), 'changed')
        self.assertTrue(sections['section-b'].get('deleted'))

    def test_genuinely_new_section_reusing_title_stays_added(self):
        # A reused title alone is not identity: the new section is
        # added (green). The old paragraphs show as deleted blocks
        # inside it, so the old id gets no deleted number of its own.
        result, _ = self.compare(
            chapter_file(section('section-a', 'Alpha',
                                 '<para>Zebra xylophone quartet jamboree.</para>'
                                 '<para>Quixotic wizards vex brown jackals.</para>')),
            chapter_file(section('section-b', 'Alpha',
                                 '<para>Luminous nebulae drift silently onward.</para>'
                                 '<para>Copper kettles sing thermal ballads.</para>')))
        sections = result.get('sections', {})
        self.assertEqual(sections.get('section-b', {}).get('status'), 'added')
        self.assertNotIn('section-a', sections)

    def test_shared_title_anchor_does_not_override_new_content(self):
        # The title anchor survived a rewrite, but the section has
        # enough own blocks to judge by content: one paired title out
        # of three blocks is not familiar material, so it stays green.
        old = ('<chapter xml:id="chapter-a"><title>Chapter</title>'
               '<section xml:id="section-a"><title>'
               '<anchor xml:id="c4s8"/>Alpha</title>'
               '<para>Zebra xylophone quartet jamboree.</para>'
               '<para>Quixotic wizards vex brown jackals.</para></section></chapter>')
        new = ('<chapter xml:id="chapter-a"><title>Chapter</title>'
               '<section xml:id="section-b"><title>'
               '<anchor xml:id="c4s8"/>Alpha</title>'
               '<para>Luminous nebulae drift silently onward.</para>'
               '<para>Copper kettles sing thermal ballads.</para></section></chapter>')
        result, _ = self.compare(old, new)
        sections = result.get('sections', {})
        self.assertEqual(sections.get('section-b', {}).get('status'), 'added')
        self.assertNotIn('section-a', sections)

    def test_renamed_parent_with_subsections_counts_as_surviving(self):
        # The parent was renamed but its subsections kept their ids:
        # it matches the gone old parent instead of looking wholly new.
        old = (chapter_file(section('section-a', 'Section',
                                    '<para>Keep this sentence.</para>')
                            + section('section-p', 'Parent',
                                      '<para>Parent words one.</para>'
                                      + section('section-c1', 'C1',
                                                '<para>Child one words.</para>'
                                                '<para>Child two words.</para>')
                                      + section('section-c2', 'C2',
                                                '<para>Child three words.</para>'
                                                '<para>Child four words.</para>'))))
        new = (chapter_file(section('section-a', 'Section',
                                    '<para>Keep this sentence.</para>')
                            + section('section-p2', 'Parent',
                                      '<para>Parent words one.</para>'
                                      + section('section-c1', 'C1',
                                                '<para>Child one words.</para>'
                                                '<para>Child two words.</para>')
                                      + section('section-c2', 'C2',
                                                '<para>Child three words.</para>'
                                                '<para>Child four words.</para>'))))
        result, _ = self.compare(old, new)
        sections = result.get('sections', {})
        self.assertEqual(sections.get('section-p2', {}).get('status'), 'changed')

    def test_renamed_chapter_matches_old_chapter(self):
        # Three sections, one changed paragraph plus a deleted third
        # section: the chapter matches the old chapter (del 3 from the
        # deleted section's title and paragraphs), not one of its sections.
        long1 = ('First paragraph with enough distinctive words to align well.')
        long2 = ('Second paragraph with enough distinctive words to align well.')
        long3 = ('Third paragraph with enough distinctive words to align well.')
        old = ('<chapter xml:id="chapter-a"><title>Chapter</title>'
               '<section xml:id="section-k"><title>Keep</title>'
               '<para>Stable lead paragraph here.</para></section>'
               '<section xml:id="section-a"><title>Alpha</title>'
               '<para>' + long1 + '</para><para>' + long2 + '</para>'
               '<para>' + long3 + '</para></section>'
               '<section xml:id="section-z"><title>Gone</title>'
               '<para>Doomed words one.</para><para>Doomed words two.</para>'
               '</section></chapter>')
        new = ('<chapter xml:id="chapter-b"><title>Chapter</title>'
               '<section xml:id="section-k"><title>Keep</title>'
               '<para>Stable lead paragraph here.</para></section>'
               '<section xml:id="section-a"><title>Alpha</title>'
               '<para>' + long1 + '</para><para>' + long2 + ' More.</para>'
               '<para>' + long3 + '</para></section></chapter>')
        result, _ = self.compare(old, new)
        sections = result.get('sections', {})
        self.assertEqual(sections.get('chapter-b', {}).get('status'), 'changed')
        self.assertTrue(sections['chapter-b'].get('deleted'))
        self.assertEqual(sections.get('section-z', {}).get('status'), 'deleted')

    def test_deleted_section_keeps_pink_despite_shared_inner_id(self):
        # The old section was rewritten from scratch under a new id but
        # kept its example id: the struck copy stays deleted (pink).
        # Content decides the new section -- all new text means green,
        # even with the kept id; only a small section may match by alias.
        old = ('<chapter xml:id="chapter-a"><title>Chapter</title>'
               '<section xml:id="section-a"><title>Gone</title>'
               '<para>Zebra xylophone quartet jamboree.</para>'
               '<example xml:id="ex1">'
               '<para>Quixotic wizards vex brown jackals.</para></example></section>'
               '</chapter>')
        new = ('<chapter xml:id="chapter-a"><title>Chapter</title>'
               '<section xml:id="section-b"><title>New</title>'
               '<para>Luminous nebulae drift silently onward.</para>'
               '<example xml:id="ex1">'
               '<para>Copper kettles sing thermal ballads.</para></example></section>'
               '</chapter>')
        result, _ = self.compare(old, new)
        sections = result.get('sections', {})
        self.assertEqual(sections.get('section-a', {}).get('status'), 'deleted')
        self.assertEqual(sections.get('section-b', {}).get('status'), 'added')

    def test_kept_anchor_on_mostly_new_section_stays_green(self):
        # 22.3's shape: the new section keeps the old section's id as
        # an anchor and reuses its title, but only one of its four own
        # blocks pairs with old text. Content decides: green.
        old = ('<chapter xml:id="chapter-a"><title>Chapter</title>'
               '<section xml:id="section-old"><title>Repairs</title>'
               '<para>Zebra xylophone quartet jamboree.</para>'
               '<para>Quixotic wizards vex brown jackals.</para>'
               '<para>Pack my box with five dozen liquor jugs.</para>'
               '<para>How vexingly quick daft zebras jump.</para></section>'
               '</chapter>')
        new = ('<chapter xml:id="chapter-a"><title>Chapter</title>'
               '<section xml:id="section-new"><title>'
               '<anchor xml:id="section-old"/>Repairs</title>'
               '<para>Pack my box with five dozen liquor jugs.</para>'
               '<para>Luminous nebulae drift silently onward.</para>'
               '<para>Copper kettles sing thermal ballads.</para>'
               '<para>Sphinx of black quartz judge my vow.</para></section>'
               '</chapter>')
        result, _ = self.compare(old, new)
        sections = result.get('sections', {})
        self.assertEqual(sections.get('section-new', {}).get('status'), 'added')
        self.assertNotIn('section-old', [
            s for s, e in sections.items() if e.get('status') == 'changed'])

    def test_shared_anchor_decides_small_section(self):
        # The same kept anchor on a section too small to judge by
        # content (a title plus one paragraph): the alias still counts,
        # so the section is blue.
        old = ('<chapter xml:id="chapter-a"><title>Chapter</title>'
               '<section xml:id="section-old"><title>'
               '<anchor xml:id="ca"/>Old title</title>'
               '<para>Vanishing words one.</para></section>'
               '</chapter>')
        new = ('<chapter xml:id="chapter-a"><title>Chapter</title>'
               '<section xml:id="section-new"><title>'
               '<anchor xml:id="ca"/>Old title</title>'
               '<para>Fresh words one.</para></section>'
               '</chapter>')
        result, _ = self.compare(old, new)
        sections = result.get('sections', {})
        self.assertEqual(sections.get('section-new', {}).get('status'), 'changed')

    def test_merged_section_counts_as_surviving(self):
        # Content from two gone old sections, most of it paired: blue,
        # not green. Green means "read this as new text".
        paras = ['Distinctive paragraph %s with enough words to align well.'
                 % w for w in ('alpha one', 'alpha two', 'alpha three',
                               'beta one', 'beta two', 'beta three')]
        old = (chapter_file(section('section-a', 'Alpha',
                                    '<para>' + paras[0] + '</para>'
                                    '<para>' + paras[1] + '</para>'
                                    '<para>' + paras[2] + '</para>')
                            + section('section-b', 'Beta',
                                      '<para>' + paras[3] + '</para>'
                                      '<para>' + paras[4] + '</para>'
                                      '<para>' + paras[5] + '</para>')))
        new = (chapter_file(section(
            'section-m', 'Merged',
            ''.join('<para>' + p + '</para>' for p in paras))))
        result, _ = self.compare(old, new)
        sections = result.get('sections', {})
        self.assertEqual(sections.get('section-m', {}).get('status'), 'changed')

    def test_exactly_half_old_stays_added(self):
        # The rule is more than half: a section that is exactly half
        # old text stays green.
        old = (chapter_file(section(
            'section-a', 'Alpha',
            '<para>Zebra xylophone quartet jamboree.</para>'
            '<para>Quixotic wizards vex brown jackals.</para>')))
        new = (chapter_file(section(
            'section-b', 'Beta',
            '<para>Zebra xylophone quartet jamboree.</para>'
            '<para>Quixotic wizards vex brown jackals.</para>'
            '<para>Luminous nebulae drift silently onward.</para>')))
        result, _ = self.compare(old, new)
        sections = result.get('sections', {})
        self.assertEqual(sections.get('section-b', {}).get('status'), 'added')

    def test_new_section_quoting_one_old_line_stays_added(self):
        # One quoted old line among new text does not make it familiar.
        old = (chapter_file(section(
            'section-a', 'Alpha',
            '<para>Zebra xylophone quartet jamboree.</para>'
            '<para>Quixotic wizards vex brown jackals.</para>'
            '<para>Pack my box with five dozen liquor jugs.</para>'
            '<para>How vexingly quick daft zebras jump.</para>')))
        new = (chapter_file(section(
            'section-b', 'Beta',
            '<para>Zebra xylophone quartet jamboree.</para>'
            '<para>Luminous nebulae drift silently onward.</para>'
            '<para>Copper kettles sing thermal ballads.</para>'
            '<para>Sphinx of black quartz judge my vow.</para>'
            '<para>Waltz bad nymph for quick jigs vex.</para>')))
        result, _ = self.compare(old, new)
        sections = result.get('sections', {})
        self.assertEqual(sections.get('section-b', {}).get('status'), 'added')

    def test_split_off_section_shows_deletions_where_shown(self):
        # Half of a surviving old section moved to a new one: the new
        # section stays blue and shows deleted material because the
        # struck copy is visibly inserted into its subtree.
        paras = ''.join('<para>Stable paragraph number %d with some words to '
                        'anchor alignment here.</para>' % k for k in range(6))
        old = (chapter_file(section('section-a', 'Alpha',
                                            paras + '<para>Gone paragraph here.</para>')))
        new = (chapter_file(section(
            'section-a', 'Alpha',
            '<para>Stable paragraph number 0 with some words to anchor '
            'alignment here.</para>'
            '<para>Stable paragraph number 1 with some words to anchor '
            'alignment here.</para>')
            + section(
                'section-b', 'Beta',
                '<para>Stable paragraph number 2 with some words to anchor '
                'alignment here.</para>'
                '<para>Stable paragraph number 3 with some words to anchor '
                'alignment here.</para>'
                '<para>Stable paragraph number 4 with some words to anchor '
                'alignment here.</para>'
                '<para>Stable paragraph number 5 with some words to anchor '
                'alignment here.</para>')))
        result, _ = self.compare(old, new)
        sections = result.get('sections', {})
        self.assertEqual(sections.get('section-b', {}).get('status'), 'changed')
        self.assertTrue(sections['section-b'].get('deleted'))
        self.assertNotIn('section-a', sections)

    def test_kept_anchor_does_not_hide_a_deletion(self):
        # The new title keeps the old section id as an anchor for old
        # links, but the section itself is gone: the deletion is visible,
        # not just an id rename.
        old = ('<chapter xml:id="chapter-a"><title>Chapter</title>'
               '<section xml:id="section-cmene"><title>'
               '<anchor xml:id="c4s8"/>cmevla</title>'
               '<para>Keep this paragraph unchanged.</para>'
               '<para>Remove this paragraph entirely.</para></section></chapter>')
        new = ('<chapter xml:id="chapter-a"><title>Chapter</title>'
               '<section xml:id="section-cmevla"><title>'
               '<anchor xml:id="c4s8"/><anchor xml:id="section-cmene"/>cmevla</title>'
               '<para>Keep this paragraph unchanged.</para></section></chapter>')
        result, _ = self.compare(old, new)
        sections = result.get('sections', {})
        self.assertEqual(sections.get('section-cmevla', {}).get('status'), 'changed')
        self.assertTrue(sections['section-cmevla'].get('deleted'))

    def test_struck_copy_does_not_identify_the_parent(self):
        # The deleted subsection is re-inserted as a struck copy inside
        # the new section, but it is not a surviving child: the new
        # section stays added (green).
        old = (chapter_file(section('section-lead', 'Lead',
                                    '<para>Stable lead text here.</para>')
                            + section('section-before', 'Notes',
                                      '<para>abcdefghijklm nopqrstuvwxyz</para>'
                                      '<para>abcdefghi klmnopqrstuvw xyz</para>'
                                      + section('section-removed', 'Retired',
                                                '<para>zyxwvutsrqpon unique retired words</para>'))
                            + section('section-trail', 'Trailing',
                                      '<para>Stable trailing text here.</para>')))
        new = (chapter_file(section('section-lead', 'Lead',
                                    '<para>Stable lead text here.</para>')
                            + section('section-after', 'Notes',
                                      '<para>111111111111111111111111111111</para>'
                                      '<para>222222222222222222222222222222</para>'
                                      '<para>333333333333333333333333333333</para>'
                                      '<para>444444444444444444444444444444</para>')
                            + section('section-trail', 'Trailing',
                                      '<para>Stable trailing text here.</para>')))
        result, tree = self.compare(old, new)
        sections = result.get('sections', {})
        self.assertEqual(sections.get('section-after', {}).get('status'), 'added')
        self.assertEqual(sections.get('section-removed', {}).get('status'), 'deleted')
        # The struck copy really sits inside the new section: without
        # the dead-copy guard the parent lookup would match it.
        after = tree.find('.//*[@xml:id="section-after"]'.replace(
            'xml:id', '{http://www.w3.org/XML/1998/namespace}id'))
        ids = [el.get(XML_ID) for el in after.iter() if isinstance(el.tag, str)]
        self.assertIn('section-removed', ids)

    def test_anchor_child_identifies_renamed_parent(self):
        # The child kept only its title anchor under a new id; the
        # parent is still that parent renamed, not a new section.
        def family(pid, ptitle, p1, p2, cid):
            return ('<section xml:id="%s"><title>%s</title>'
                    '<para>%s</para><para>%s</para>'
                    '<section xml:id="%s"><title>'
                    '<anchor xml:id="ca"/>Child title</title>'
                    '<para>Child words here.</para></section></section>'
                    % (pid, ptitle, p1, p2, cid))
        lead = ('<section xml:id="section-lead"><title>Lead</title>'
                '<para>Stable lead text here.</para></section>')
        trail = ('<section xml:id="section-trail"><title>Trailing</title>'
                 '<para>Stable trailing text here.</para></section>')
        old = ('<chapter xml:id="chapter-a"><title>Chapter</title>' + lead
               + family('section-pold', 'Same parent',
                        'Parent words one.', 'Parent words two.', 'section-cold')
               + trail + '</chapter>')
        new = ('<chapter xml:id="chapter-a"><title>Chapter</title>' + lead
               + family('section-pnew', 'New parent',
                        'Fresh parent words one.', 'Fresh parent words two.', 'section-cnew')
               + trail + '</chapter>')
        result, _ = self.compare(old, new)
        sections = result.get('sections', {})
        self.assertEqual(sections.get('section-pnew', {}).get('status'), 'changed')
        self.assertEqual(sections.get('section-cnew', {}).get('status'), 'changed')

    def test_split_moves_charged_to_supplier_and_receiver(self):
        # B takes three paragraphs from A, two others move A to D: B
        # supplied and received none of the moves, so B reports none
        # while A and D report theirs.
        astro = 'The astronomer carefully recorded distant galaxies throughout the winter observation period.'
        garden = 'A patient gardener planted fragrant flowers beside the old stone cottage yesterday.'
        sail = 'Sailors navigated treacherous ocean currents using ancient maps and polished brass instruments.'
        bake = 'Bakers prepared delicious crusty sourdough loaves before sunrise at the village market.'
        music = 'Musicians rehearsed intricate melodies together inside the historic concert hall downtown.'
        scient = 'Scientists measured unexpected volcanic tremors beneath the remote mountain range overnight.'
        trav = 'Travelers discovered remarkable pottery ruins among the ruins of an abandoned settlement.'
        para = lambda s: '<para>' + s + '</para>'
        old = (chapter_file(section('section-a', 'Section A',
                                    para(astro) + para(scient) + para(trav)
                                    + para(garden) + para(sail) + para(bake) + para(music))
                            + section('section-d', 'Section D',
                                      para('The distinct first observation here.')
                                      + para('The distinct second observation here.')
                                      + para('The distinct third observation here.'))))
        new = (chapter_file(section('section-a', 'Section A',
                                    para(astro) + para(garden))
                            + section('section-b', 'Section B',
                                      para(sail) + para(bake) + para(music))
                            + section('section-d', 'Section D',
                                      para('The distinct first observation here.')
                                      + para('The distinct second observation here.')
                                      + para('The distinct third observation here.')
                                      + para(scient) + para(trav))))
        result, _ = self.compare(old, new)
        sections = result.get('sections', {})
        self.assertEqual(sections.get('section-b', {}).get('status'), 'changed')
        self.assertFalse(sections['section-b'].get('moved'))
        self.assertTrue(sections.get('section-a', {}).get('moved'))
        self.assertTrue(sections.get('section-d', {}).get('moved'))

    def test_split_deletion_marks_only_its_visible_host(self):
        # The old section is gone, its content split over two new ones
        # and one paragraph deleted: only the successor holding the
        # struck copy shows deleted material.
        old = (chapter_file(section(
            'section-a', 'Section A',
            '<para>Keep this paragraph unchanged.</para>'
            '<para>Keep this other paragraph unchanged.</para>'
            '<para>Keep a third paragraph unchanged.</para>'
            '<para>Keep a fourth paragraph unchanged.</para>'
            '<para>Remove this paragraph entirely.</para>')))
        new = (chapter_file(section(
            'section-b', 'Section B',
            '<para>Keep this paragraph unchanged.</para>'
            '<para>Keep this other paragraph unchanged.</para>')
            + section(
                'section-c', 'Section C',
                '<para>Keep a third paragraph unchanged.</para>'
                '<para>Keep a fourth paragraph unchanged.</para>')))
        result, _ = self.compare(old, new)
        sections = result.get('sections', {})
        self.assertEqual(sections.get('section-b', {}).get('status'), 'changed')
        self.assertEqual(sections.get('section-c', {}).get('status'), 'changed')
        self.assertFalse(sections['section-b'].get('deleted'))
        self.assertTrue(sections['section-c'].get('deleted'))

    def test_green_section_lists_struck_text_and_move_note(self):
        # 22.10's shape: a green section that kept one paragraph,
        # lost one paragraph to deletion and one to a move. Its tooltip
        # lists every change, including the struck text and the move.
        keep = 'Keep this sentence here for alignment purposes only.'
        moved = ('The first paragraph has a fair amount of distinctive text '
                 'in it so it can move across sections.')
        gone = 'Vanishing words one two three four five, gone completely now.'
        new1 = 'Luminous nebulae drift silently onward through the void.'
        new2 = 'Copper kettles sing thermal ballads late at night.'
        old = chapter_file(section('section-a', 'Section A',
                                           '<para>' + keep + '</para>'
                                           + '<para>' + moved + '</para>'
                                           + '<para>' + gone + '</para>'),
                                    section('section-x', 'Section X',
                                            '<para>Stable text here.</para>'))
        new = chapter_file(section('section-b', 'Section B',
                                   '<para>' + keep + '</para>'
                                   + '<para>' + new1 + '</para>'
                                   + '<para>' + new2 + '</para>'),
                           section('section-x', 'Section X',
                                   '<para>Stable text here.</para>'
                                   '<para>' + moved + '</para>'))
        result, tree = self.compare(old, new)
        sections = result.get('sections', {})
        self.assertEqual(sections.get('section-b', {}).get('status'), 'added')
        self.assertTrue(sections['section-b'].get('deleted'))
        self.assertTrue(sections['section-b'].get('moved'))
        # The struck paragraph and the move note really sit in section b.
        ids = [el.get(XML_ID) for el in tree.iter() if isinstance(el.tag, str)]
        self.assertIn('section-b', ids)

    def test_blue_sections_show_deletions_where_they_are_shown(self):
        # CLL 1.1's quantified/indefinite descriptions shape: a paragraph
        # of A pairs across the section boundary with one in B, so A's five
        # deleted blocks are inserted before it in B. Tooltips follow them.
        shared = ('A surviving paragraph with enough shared wording '
                  'to align across sections.')
        gone = ''.join('<para>Deleted block %d from section A.</para>' % n
                       for n in range(5))
        old = chapter_file(
            section('section-a', 'Old heading',
                    gone + '<para>' + shared + '</para>'),
            section('section-b', 'Old B heading',
                    '<para>Keep this paragraph in section B.</para>'))
        new = chapter_file(
            section('section-a', 'Completely different title',
                    '<para>Fresh replacement text in section A.</para>'),
            section('section-b', 'New B title',
                    '<para>' + shared + ' Extra words.</para>'
                    '<para>Keep this paragraph in section B.</para>'))
        result, _ = self.compare(old, new)
        sections = result.get('sections', {})
        self.assertEqual(sections.get('section-a', {}).get('status'), 'changed')
        self.assertEqual(sections.get('section-b', {}).get('status'), 'changed')
        self.assertFalse(sections['section-a'].get('deleted'))
        self.assertTrue(sections['section-b'].get('deleted'))

    def test_deleted_list_marks_section(self):
        # A struck list makes deleted material visible in the section.
        keep = 'Keep this sentence here for alignment purposes only.'
        entries = ''.join('<listitem><member>Old entry %d.</member></listitem>' % n
                          for n in range(5))
        old = chapter_file(section(
            'section-a', 'Section A',
            '<para>' + keep + '</para><itemizedlist>' + entries + '</itemizedlist>'))
        new = chapter_file(section(
            'section-b', 'Section B',
            '<para>' + keep + '</para>'
            '<para>Luminous nebulae drift silently onward through the void.</para>'
            '<para>Copper kettles sing thermal ballads late at night.</para>'))
        result, _ = self.compare(old, new)
        sections = result.get('sections', {})
        self.assertEqual(sections.get('section-b', {}).get('status'), 'added')
        self.assertTrue(sections['section-b'].get('deleted'))

    def test_deleted_inline_valsi_phrases_are_not_deleted_blocks(self):
        # Opus's inline reproduction: the surviving changed paragraph has
        # two struck phrases containing valsi markup, but no deleted block.
        old = ('<chapter xml:id="chapter-a"><title>Chapter</title>'
               '<section xml:id="s-k"><title>Keep</title><para>'
               'A stable lead paragraph that never changes in any version of this test book.'
               '</para></section><section xml:id="s-g"><title>Grab bag</title><para>'
               "The quote word <valsi>zo'oi</valsi> and the name word <valsi>la'oi</valsi> "
               'both take one foreign word, as <xref linkend="s-k"/> says.'
               '</para></section></chapter>')
        new = ('<chapter xml:id="chapter-a"><title>Chapter</title>'
               '<section xml:id="s-k"><title>Keep</title><para>'
               'A stable lead paragraph that never changes in any version of this test book.'
               '</para></section><section xml:id="s-n"><title>Quoting</title>'
               '<para>Fresh paragraph one about quoting here.</para>'
               '<para>Fresh paragraph two about quoting here.</para>'
               '<para>Fresh paragraph three about quoting here.</para><para>'
               "The quote word <valsi>zo'oi</valsi> takes one foreign word."
               '</para></section></chapter>')
        result, _ = self.compare(old, new)
        sections = result.get('sections', {})
        self.assertEqual(sections.get('s-n', {}).get('status'), 'added')
        self.assertTrue(sections['s-n'].get('changed'))
        self.assertFalse(sections['s-n'].get('deleted'))

    def test_nested_deleted_example_line_is_visible(self):
        # 4.5's bralo'i line is nested inside a surviving lujvo-making
        # block. The outer block has live lines, but the nested jbo line
        # is wholly struck and makes the section contain deleted material.
        old = chapter_file(section(
            'section-lujvo', 'lujvo',
            '<example><lujvo-making><jbo>bralo\'i</jbo>'
            '<gloss>big-boat</gloss><natlang>ship</natlang>'
            '</lujvo-making></example>'))
        new = chapter_file(section(
            'section-lujvo', 'lujvo',
            '<example><lujvo-making><jbo>brablo</jbo>'
            '<gloss>big-boat</gloss><natlang>ship</natlang>'
            '</lujvo-making></example>'))
        result, _ = self.compare(old, new)
        entry = result['sections']['section-lujvo']
        self.assertTrue(entry.get('deleted'))
        self.assertTrue(entry.get('added'))

    def test_deleted_footnote_paragraph_is_visible(self):
        # Nested blocks returned by inline_text need the same traversal
        # as Book.linearize, including a footnote inside a live paragraph.
        old = chapter_file(section(
            'section-a', 'Section',
            '<para>Surviving text.<footnote><para>Deleted footnote.</para>'
            '</footnote> After footnote.</para>'))
        new = chapter_file(section(
            'section-a', 'Section',
            '<para>Surviving text. After footnote.</para>'))
        result, _ = self.compare(old, new)
        self.assertTrue(result['sections']['section-a'].get('deleted'))

    def test_deleted_subsection_inherits_outer_deletion(self):
        old = ('<chapter xml:id="c1"><title>Chapter</title>'
               '<section xml:id="c1s1"><title>Stable</title>'
               '<para>Stable preceding paragraph.</para></section>'
               '<section xml:id="c1s2"><title>Deleted outer</title>'
               '<para>Outer deleted substance.</para>'
               '<section xml:id="c1s3"><title>Nested deleted</title>'
               '<para>Nested deleted substance.</para></section></section>'
               '<section xml:id="c1s4"><title>Stable again</title>'
               '<para>Stable final paragraph.</para></section></chapter>')
        new = ('<chapter xml:id="c1"><title>Chapter</title>'
               '<section xml:id="c1s1"><title>Stable</title>'
               '<para>Stable preceding paragraph.</para></section>'
               '<section xml:id="c1s4"><title>Stable again</title>'
               '<para>Stable final paragraph.</para></section></chapter>')
        result, _ = self.compare(old, new)
        self.assertTrue(result['sections']['c1s2'].get('deleted'))
        self.assertTrue(result['sections']['c1s3'].get('deleted'))

    def test_struck_punctuation_after_live_xref_is_not_deleted_block(self):
        old = ('<chapter xml:id="chapter-a"><title>Chapter</title>'
               '<section xml:id="target"><title>Target</title>'
               '<para>Target content.</para></section>'
               '<section xml:id="section-a"><title>Section</title>'
               '<para>Before unchanged.</para><para><xref linkend="target"/>.</para>'
               '<para>After unchanged.</para></section></chapter>')
        new = old.replace('<xref linkend="target"/>.', '<xref linkend="target"/>')
        result, _ = self.compare(old, new)
        entry = result['sections']['section-a']
        self.assertTrue(entry.get('changed'))
        self.assertFalse(entry.get('deleted'))

    def test_folded_deleted_paragraph_marks_host(self):
        old = ('<chapter xml:id="chapter-a"><title>Chapter</title>'
               '<section xml:id="B"><title>Host</title>'
               '<para>Stable host paragraph survives unchanged.</para></section>'
               '<section xml:id="A"><title>Other topic</title>'
               '<para>Unique fully deleted paragraph describes obsolete matters.</para>'
               '<para>Unchanged paragraph X discusses a distinctive neighboring topic.</para>'
               '</section><section xml:id="fence"><title>Fence</title>'
               '<para>Fence paragraph remains stable.</para></section></chapter>')
        new = ('<chapter xml:id="chapter-a"><title>Chapter</title>'
               '<section xml:id="B"><title>Host</title>'
               '<para>Stable host paragraph survives unchanged.</para>'
               '<para>Unchanged paragraph X discusses a distinctive neighboring topic.</para>'
               '</section><section xml:id="fence"><title>Fence</title>'
               '<para>Fence paragraph remains stable.</para></section></chapter>')
        result, _ = self.compare(old, new)
        self.assertIn('B', result['sections'])
        self.assertTrue(result['sections']['B'].get('deleted'))

    def test_promoted_bridgehead_is_judged_by_content(self):
        old = ('<chapter xml:id="chapter-a"><title>Chapter</title>'
               '<section xml:id="section-a"><title>Section A</title>'
               '<bridgehead xml:id="topic">Same heading</bridgehead></section></chapter>')
        new = ('<chapter xml:id="chapter-a"><title>Chapter</title>'
               '<section xml:id="section-a"><title>Section A</title>'
               '<section xml:id="topic"><title>Same heading</title>'
               '<para>111111111111111111111111111</para>'
               '<para>222222222222222222222222222</para>'
               '<para>333333333333333333333333333</para>'
               '<para>444444444444444444444444444</para></section></section></chapter>')
        result, _ = self.compare(old, new)
        entry = result['sections']['topic']
        self.assertEqual(entry.get('status'), 'added')
        self.assertFalse(entry.get('renamed'))

    def test_rewritten_child_does_not_identify_new_parent(self):
        old = ('<chapter xml:id="chapter-a"><title>Chapter</title>'
               '<section xml:id="s-old-parent"><title>Quartz</title>'
               '<section xml:id="old-id"><title><anchor xml:id="child-anchor"/>'
               'Child heading</title><para>abcdefghijklmnop qrstuvwxyz</para>'
               '<para>bcdefghijklmnopq rstuvwxyza</para>'
               '<para>cdefghijklmnopqr stuvwxyzab</para>'
               '<para>defghijklmnopqrs tuvwxyzabc</para></section></section></chapter>')
        new = ('<chapter xml:id="chapter-a"><title>Chapter</title>'
               '<section xml:id="s-new-parent"><title>11111111111111111111</title>'
               '<section xml:id="new-id"><title><anchor xml:id="child-anchor"/>'
               'Child heading</title><para>111111111111111111111111111</para>'
               '<para>222222222222222222222222222</para>'
               '<para>333333333333333333333333333</para>'
               '<para>444444444444444444444444444</para></section></section></chapter>')
        result, _ = self.compare(old, new)
        self.assertEqual(result['sections']['new-id'].get('status'), 'added')
        self.assertEqual(result['sections']['s-new-parent'].get('status'), 'added')

    def test_split_from_surviving_parent_is_not_renamed(self):
        old = ('<chapter xml:id="chapter-a"><title>Chapter</title>'
               '<section xml:id="section-a"><title>Alpha</title>'
               '<para>Stable introductory paragraph remains identical.</para>'
               '<bridgehead>Topic</bridgehead>'
               '<para>Astronomers observed distant galaxies throughout winter.</para>'
               '<para>Gardeners planted fragrant flowers beside cottages.</para>'
               '<para>Sailors navigated treacherous currents using maps.</para>'
               '</section></chapter>')
        new = ('<chapter xml:id="chapter-a"><title>Chapter</title>'
               '<section xml:id="section-a"><title>Alpha</title>'
               '<para>Stable introductory paragraph remains identical.</para>'
               '<section xml:id="topic"><title>Topic</title>'
               '<para>Astronomers observed distant galaxies throughout winter.</para>'
               '<para>Gardeners planted fragrant flowers beside cottages.</para>'
               '<para>Sailors navigated treacherous currents using maps.</para>'
               '</section></section></chapter>')
        result, _ = self.compare(old, new)
        self.assertNotIn('topic', result['sections'])

    def test_renamed_chapter_with_own_content_matches_old_chapter(self):
        # A renamed chapter with three own blocks: the title and both
        # intro paragraphs are new, but both subsections continue old
        # ones, so the parent rule matches the gone old chapter.
        old = ('<chapter xml:id="chapter-a"><title>Chapter</title>'
               '<para>Zebra xylophone quartet jamboree here.</para>'
               '<para>Quixotic wizards vex brown jackals here.</para>'
               '<section xml:id="section-k"><title>Keep</title>'
               '<para>Stable lead paragraph here.</para></section>'
               '<section xml:id="section-a"><title>Alpha</title>'
               '<para>Stable alpha paragraph here.</para></section>'
               '</chapter>')
        new = ('<chapter xml:id="chapter-b"><title>Chapter</title>'
               '<para>Luminous nebulae drift silently onward here.</para>'
               '<para>Copper kettles sing thermal ballads here.</para>'
               '<section xml:id="section-k"><title>Keep</title>'
               '<para>Stable lead paragraph here.</para></section>'
               '<section xml:id="section-a"><title>Alpha</title>'
               '<para>Stable alpha paragraph here.</para></section>'
               '</chapter>')
        result, _ = self.compare(old, new)
        sections = result.get('sections', {})
        self.assertEqual(sections.get('chapter-b', {}).get('status'), 'changed')
        self.assertTrue(sections['chapter-b'].get('deleted'))

    def test_deleted_section_keeps_subsection_ids(self):
        # Subsections of a wholly deleted section get the deleted mark
        # on their own numbers too.
        result, tree = self.compare(
            chapter_file(section('section-a', 'Section',
                                 '<para>Keep this sentence.</para>'),
                         section('section-b', 'Doomed',
                                 '<para>Doomed paragraph.</para>',
                                 section('section-b1', 'Doomed child',
                                         '<para>Doomed child text.</para>'))),
            chapter_file(section('section-a', 'Section',
                                 '<para>Keep this sentence.</para>')))
        sections = result.get('sections', {})
        self.assertEqual(sections.get('section-b', {}).get('status'), 'deleted')
        self.assertEqual(sections.get('section-b1', {}).get('status'), 'deleted')
        ids = [el.get(XML_ID) for el in tree.iter() if isinstance(el.tag, str)]
        self.assertIn('section-b', ids)
        self.assertIn('section-b1', ids)

    def test_partly_moved_deleted_section_keeps_its_id(self):
        # A deleted section that lost some material to a move takes the
        # skeleton path, which drops the id too; it is still marked deleted.
        first = ('The first paragraph has a fair amount of distinctive text '
                 'in it so it can move.')
        old = (chapter_file(section('section-a', 'Section',
                                    '<para>Keep this sentence.</para>')
                            + section('section-c', 'Vanishing',
                                      '<para>' + first + '</para>'
                                      '<para>Vanishing paragraph two.</para>')
                            + section('section-d', 'Staying',
                                      '<para>Staying paragraph.</para>')))
        new = (chapter_file(section('section-a', 'Section',
                                    '<para>Keep this sentence.</para>')
                            + section('section-d', 'Staying',
                                      '<para>Staying paragraph.</para>'
                                      '<para>' + first + '</para>')))
        result, tree = self.compare(old, new)
        sections = result.get('sections', {})
        self.assertEqual(sections.get('section-c', {}).get('status'), 'deleted')
        ids = [el.get(XML_ID) for el in tree.iter() if isinstance(el.tag, str)]
        self.assertIn('section-c', ids)


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
        'chapter-a': {'status': 'changed', 'changed': True, 'added': True,
                      'deleted': True, 'moved': True},
        'section-a': {'status': 'changed', 'changed': True},
        'section-b': {'status': 'changed', 'changed': True},
        'section-c': {'status': 'added', 'added': True},
        'section-d': {'status': 'deleted', 'deleted': True},
    },
}


def text_of(page):
    """Visible text of a page, for comparing output against its input."""
    class Texts(HTMLParser):
        def __init__(self):
            super().__init__(convert_charrefs=False)
            self.parts = []

        def handle_data(self, data):
            self.parts.append(data)

    collector = Texts()
    collector.feed(page)
    collector.close()
    return ''.join(collector.parts)


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

    def test_changed_number_gets_blue_and_tooltip(self):
        page, _ = self.finish()
        self.assertIn('<span class="diff-toc-changed" title="Changed material">1.1.</span>'
                      ' Unchanged title', page)

    def test_retitled_entry_keeps_title_diffs(self):
        page, _ = self.finish()
        self.assertIn('<span class="diff-toc-changed" title="Changed material">1.2.</span>'
                      ' Old <span class="deleted">', page)
        self.assertIn('<span class="added"><span class="phrase">different heading</span></span>',
                      page)

    def test_new_section_number_gets_green(self):
        page, _ = self.finish()
        self.assertIn('<span class="diff-toc-added" title="Added material">1.3.</span>'
                      ' New section', page)

    def test_deleted_section_number_gets_pink_strike(self):
        page, _ = self.finish()
        self.assertIn('<span class="diff-toc-deleted" title="Deleted material">1.4.</span>'
                      ' Deleted section', page)

    def test_chapter_number_gets_blue(self):
        page, _ = self.finish()
        self.assertIn('<span class="diff-toc-changed" '
                      'title="Changed, added, deleted and moved material">1.</span>'
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
            self.assertIn('#a9c8ff', variant)
            self.assertIn('#97f295', variant)
            self.assertIn('#ffb6ba', variant)
            self.assertIn('continues from the old version — keeping its place, '
                          'or with most of its text from old text — changed', variant)
            self.assertNotIn(' -- ', variant)
            self.assertIn('to read as new text', variant)
            self.assertIn('struck through, is a deleted section', variant)
            self.assertNotIn('wholly new section', variant)
            self.assertNotIn('more than half of its blocks', variant)
            self.assertNotIn('Blocks (paragraphs', variant)
            # The existing explanations stay right.
            self.assertIn('Moved material itself is not marked at its new place '
                          'unless its wording also changed.', variant)
            self.assertIn('ignores differences that are only in the formatting.',
                          variant)

    def test_toc_appears_exactly_once(self):
        # The toc-title div nested inside the ToC used to match the ToC
        # region pattern too, duplicating the whole table of contents.
        page, _ = self.finish()
        self.assertEqual(page.count('class="toc-title"'), 1)
        for href in ('#chapter-a', '#section-a', '#section-b',
                     '#section-c', '#section-d'):
            self.assertEqual(page.count('href="%s"' % href), 1, href)
        self.assertEqual(page.count('<div'), page.count('</div>'))

    def without_banner(self, page):
        start = page.rfind('<', 0, page.find('class="diff-banner"'))
        end = page.find('</div>', page.find('class="diff-banner"'))
        return page[:start] + page[end + len('</div>'):]

    def test_output_text_matches_input_apart_from_marks(self):
        page, prefixed = self.finish()
        want = text_of(PAGE_HEAD + PAGE_BODY)
        self.assertEqual(text_of(self.without_banner(page)), want)
        stripped = prefixed
        for mark in ('[*]', '[+]', '[\u2212]'):
            stripped = stripped.replace('<span class="diffmark">%s</span>' % mark,
                                        '')
        self.assertEqual(text_of(self.without_banner(stripped)), want)

    def test_prefixed_banner_explains_markers(self):
        page, prefixed = self.finish()
        self.assertIn('[*] marks a changed section', prefixed)
        self.assertIn('[+] added, [\u2212] deleted, [\u2192] moved', prefixed)
        self.assertNotIn('[*] marks a changed section', page)

    def test_pure_rename_tooltip_names_the_rename(self):
        page, _ = self.finish(stats={
            'statuses': {}, 'stats': {},
            'sections': {'chapter-a': {'status': 'changed', 'renamed': True}}})
        self.assertIn('title="Section renamed"', page)

    def test_rename_precedes_visible_change_kinds(self):
        page, _ = self.finish(stats={
            'statuses': {}, 'stats': {},
            'sections': {'chapter-a': {'status': 'changed', 'renamed': True,
                                       'changed': True, 'added': True,
                                       'deleted': True}}})
        self.assertIn('title="Section renamed; changed, added and deleted material"', page)

    def test_no_visible_change_and_no_rename_gets_no_mark(self):
        page, prefixed = self.finish(stats={
            'statuses': {}, 'stats': {},
            'sections': {'chapter-a': {'status': 'changed', 'renamed': False}}})
        for variant in (page, prefixed):
            self.assertIn('<a href="#chapter-a">1. Chapter</a>', variant)
            self.assertNotIn('diff-toc-changed', variant)
            self.assertNotIn('Section renamed', variant)


if __name__ == '__main__':
    unittest.main()
