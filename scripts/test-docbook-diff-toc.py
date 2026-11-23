#!/usr/bin/env python3
"""Table-of-contents change markers in DocBook comparisons.

A comparison page must mark, on each table-of-contents entry's section
NUMBER (never the title, whose inline diffs keep working):
  * light blue (#a9c8ff) when the surviving section changed anywhere under it;
  * the existing added green for an entirely new section;
  * the existing deleted pink, struck through, for a deleted section.
Each marked number carries a tooltip with per-section block counts, and
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
        self.assertEqual(sections['section-a'].get('del'), 1)
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
        self.assertGreater(sections['section-a'].get('mov'), 0)
        self.assertEqual(sections.get('section-b', {}).get('status'), 'changed')
        self.assertEqual(sections.get('chapter-a', {}).get('status'), 'changed')

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
        # deleted paragraph counted from the old section.
        result, _ = self.compare(
            chapter_file(section('section-a', 'Alpha',
                                 '<para>Keep one here.</para>'
                                 '<para>Drop this paragraph.</para>')),
            chapter_file(section('section-b', 'Alpha',
                                 '<para>Keep one here.</para>')))
        sections = result.get('sections', {})
        self.assertEqual(sections.get('section-b', {}).get('status'), 'changed')
        self.assertEqual(sections['section-b'].get('del'), 1)

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

    def test_shared_anchor_identifies_renamed_section(self):
        # The title anchor survived a rewrite: the section counts as
        # the old one (blue), not as wholly new.
        old = ('<chapter xml:id="chapter-a"><title>Chapter</title>'
               '<section xml:id="section-a"><title>'
               '<anchor xml:id="c4s8"/>Alpha</title>'
               '<para>Old words about Alpha.</para>'
               '<para>More old words here.</para></section></chapter>')
        new = ('<chapter xml:id="chapter-a"><title>Chapter</title>'
               '<section xml:id="section-b"><title>'
               '<anchor xml:id="c4s8"/>Alpha</title>'
               '<para>Entirely new words about Beta.</para>'
               '<para>Further new words here.</para></section></chapter>')
        result, _ = self.compare(old, new)
        sections = result.get('sections', {})
        self.assertEqual(sections.get('section-b', {}).get('status'), 'changed')
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
        self.assertEqual(sections['chapter-b'].get('del'), 3)
        self.assertEqual(sections.get('section-z', {}).get('status'), 'deleted')

    def test_deleted_section_keeps_pink_despite_shared_inner_id(self):
        # The old section was rewritten from scratch under a new id but
        # kept its example id: the struck copy stays deleted (pink) while
        # the new section is changed (blue) through the forward alias.
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
        self.assertEqual(sections.get('section-b', {}).get('status'), 'changed')

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

    def test_split_off_section_ignores_old_deletion_counts(self):
        # Half of a surviving old section moved to a new one: the new
        # section stays blue, but the old section's own deleted
        # paragraph is not charged to it.
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
        self.assertEqual(sections['section-b'].get('del'), 0)
        self.assertEqual(sections.get('section-a', {}).get('status'), 'changed')
        self.assertEqual(sections['section-a'].get('del'), 1)

    def test_kept_anchor_does_not_hide_a_deletion(self):
        # The new title keeps the old section id as an anchor for old
        # links, but the section itself is gone: the deletion still
        # counts, it is not just an id rename.
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
        self.assertEqual(sections['section-cmevla'].get('del'), 1)

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
        self.assertEqual(sections['section-b'].get('mov'), 0)
        self.assertEqual(sections.get('section-a', {}).get('mov'), 2)
        self.assertEqual(sections.get('section-d', {}).get('mov'), 2)

    def test_split_deletion_counted_once(self):
        # The old section is gone, its content split over two new ones
        # and one paragraph deleted: neither successor may claim the
        # deletion twice, so neither claims it.
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
        self.assertEqual(sections['section-b'].get('del'), 0)
        self.assertEqual(sections['section-c'].get('del'), 0)

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
        # skeleton path, which drops the id too; it still counts as deleted.
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
        'chapter-a': {'status': 'changed', 'chg': 2, 'ins': 2, 'del': 1, 'mov': 0},
        'section-a': {'status': 'changed', 'chg': 1, 'ins': 0, 'del': 0, 'mov': 0},
        'section-b': {'status': 'changed', 'chg': 1, 'ins': 0, 'del': 0, 'mov': 0},
        'section-c': {'status': 'added', 'chg': 0, 'ins': 2, 'del': 0, 'mov': 0},
        'section-d': {'status': 'deleted', 'chg': 0, 'ins': 0, 'del': 1, 'mov': 0},
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

    def test_chapter_number_gets_blue(self):
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
            self.assertIn('#a9c8ff', variant)
            self.assertIn('#97f295', variant)
            self.assertIn('#ffb6ba', variant)
            self.assertIn('mostly familiar material, changed', variant)
            self.assertIn('to read as new text', variant)
            self.assertIn('more than half of its blocks come from old text', variant)
            self.assertIn('half or less comes from old text', variant)
            self.assertNotIn('wholly new section', variant)
            # The existing explanations stay right.
            self.assertIn('Moved material itself is not marked at its new place.',
                          variant)
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
        # A renamed section with unchanged content has no block counts;
        # its tooltip says what happened instead of staying empty.
        page, _ = self.finish(stats={
            'statuses': {}, 'stats': {},
            'sections': {'chapter-a': {'status': 'changed', 'chg': 0,
                                       'ins': 0, 'del': 0, 'mov': 0}}})
        self.assertIn('title="section id renamed"', page)


if __name__ == '__main__':
    unittest.main()
