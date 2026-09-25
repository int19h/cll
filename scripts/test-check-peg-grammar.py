#!/usr/bin/env python3
"""Self-test for scripts/check-peg-grammar.py.

The fidelity claim of the PEG section in chapter 21 rests on that checker, so the checker's own
blind spots are a correctness problem. Each case below is a way the printed
grammar could come to contradict the pinned fixture — most of them raised by
the PR #105 review, and all of them valid or plausible enough to survive the
repository's other checks. Every one must make the checker fail; the
unmodified tree must make it pass.

Run: python3 scripts/test-check-peg-grammar.py
"""
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

CMEVLA_ENTRY = """        <varlistentry>
          <term>CMEVLA &#8592;</term>
          <listitem>
            <para>cmevla</para>
          </listitem>
        </varlistentry>
"""


def sub_once(text, old, new, label):
    if old not in text:
        raise SystemExit(f"self-test setup failed: {label}: anchor not found")
    return text.replace(old, new, 1)


# Each mutation takes (chapter_text, fixture_text) and returns the pair.
def m_stray_root_para(a, f):
    return sub_once(a, "    <section xml:id=\"peg-classes\">",
                    "    <para>FAKE &#8592; wrong</para>\n    <section xml:id=\"peg-classes\">",
                    "stray root para"), f


def m_notation_prefix_abuse(a, f):
    return sub_once(a, "      <title>Word classes</title>",
                    "      <title>Word classes</title>\n"
                    "    <para>A rule has the form FAKE &#8592; wrong</para>",
                    "notation-prefix abuse"), f


def m_simpara(a, f):
    return sub_once(a, "      <title>Word classes</title>",
                    "      <title>Word classes</title>\n    <simpara>FAKE &#8592; wrong</simpara>",
                    "simpara"), f


def m_second_term(a, f):
    return sub_once(a, "          <term>CMEVLA &#8592;</term>",
                    "          <term>CMEVLA &#8592;</term>\n          <term>FAKE &#8592;</term>",
                    "second term"), f


def m_second_para(a, f):
    return sub_once(a, "            <para>cmevla</para>",
                    "            <para>cmevla</para>\n            <para>FAKE &#8592; wrong</para>",
                    "second para"), f


# The introduction's notation key also mentions "#: PUSH", so these anchor on
# the rule paragraph itself, not on the first match in the file.
RULE_WITH_DIRECTIVE = "<para>lojban_word <emphasis>#: PUSH</emphasis></para>"


def m_directive_tail(a, f):
    return sub_once(a, RULE_WITH_DIRECTIVE,
                    "<para>lojban_word <emphasis>#: PUSH</emphasis> GARBAGE</para>",
                    "text after directive"), f


def m_directive_phrase(a, f):
    return sub_once(a, RULE_WITH_DIRECTIVE,
                    "<para>lojban_word <phrase>GARBAGE</phrase> <emphasis>#: PUSH</emphasis></para>",
                    "phrase before directive"), f


def m_nested_section(a, f):
    return sub_once(a, "      <title>Word classes</title>",
                    "      <title>Word classes</title>\n"
                    "      <section xml:id=\"peg-fake\"><title>Fake</title><variablelist>\n"
                    + CMEVLA_ENTRY.replace("CMEVLA", "FAKE").replace("cmevla", "wrong")
                    + "      </variablelist></section>",
                    "nested section"), f


def m_entity_arrow(a, f):
    return sub_once(a, "      <title>Word classes</title>",
                    "      <title>Word classes</title>\n    <para>FAKE &larr; wrong</para>",
                    "entity arrow"), f


def m_ascii_arrow(a, f):
    return sub_once(a, "      <title>Word classes</title>",
                    "      <title>Word classes</title>\n    <para>FAKE &lt;- wrong</para>",
                    "ascii arrow"), f


def m_entry_outside_list(a, f):
    return sub_once(a, "      <title>Word classes</title>",
                    "      <title>Word classes</title>\n" + CMEVLA_ENTRY.replace("CMEVLA", "FAKE"),
                    "entry outside a variablelist"), f


def m_unknown_entity(a, f):
    return sub_once(a, "      <title>Word classes</title>",
                    "      <title>Word classes</title>\n    <para>&nosuchentity;</para>",
                    "unresolvable entity"), f


def m_body_edit(a, f):
    return sub_once(a, "<para>gismu / lujvo / fuhivla</para>",
                    "<para>gismu / lujvo</para>", "definition edited"), f


def m_sync_delete(a, f):
    return (sub_once(a, CMEVLA_ENTRY, "", "synchronized delete"),
            sub_once(f, "CMEVLA &lt;- cmevla\n", "", "synchronized delete (fixture)"))


def m_sync_swap(a, f):
    brivla = CMEVLA_ENTRY.replace("CMEVLA", "BRIVLA").replace(
        "<para>cmevla</para>", "<para>gismu / lujvo / fuhivla</para>")
    a2 = sub_once(a, CMEVLA_ENTRY + brivla, brivla + CMEVLA_ENTRY, "synchronized swap")
    f2 = sub_once(f, "CMEVLA &lt;- cmevla\nBRIVLA &lt;- gismu / lujvo / fuhivla\n",
                  "BRIVLA &lt;- gismu / lujvo / fuhivla\nCMEVLA &lt;- cmevla\n",
                  "synchronized swap (fixture)")
    return a2, f2


def m_sync_duplicate(a, f):
    return (sub_once(a, CMEVLA_ENTRY, CMEVLA_ENTRY * 2, "synchronized duplicate"),
            sub_once(f, "CMEVLA &lt;- cmevla\n", "CMEVLA &lt;- cmevla\n" * 2,
                     "synchronized duplicate (fixture)"))


def m_cross_section_move(a, f):
    entry = """        <varlistentry>
          <term>cmevla &#8592;</term>
          <listitem>
            <para>jbocme / zifcme</para>
          </listitem>
        </varlistentry>
"""
    a2 = sub_once(a, entry, "", "cross-section move (remove)")
    a2 = sub_once(a2, "    <section xml:id=\"peg-cmevla\">",
                  "    <section xml:id=\"peg-cmevla\">", "anchor")
    # reinsert into the previous section's list
    a2 = sub_once(a2, "      </variablelist>\n    </section>\n    <section xml:id=\"peg-cmevla\">",
                  entry + "      </variablelist>\n    </section>\n    <section xml:id=\"peg-cmevla\">",
                  "cross-section move (insert)")
    return a2, f


def m_ui_all_nbsp(a, f):
    """Round-3 finding 5: an all-NBSP definition renders as one unbreakable
    run — issue #104's clipping, reintroduced."""
    m = re.search(r"(<term>UI &#8592;</term>\s*<listitem>\s*<para>)([^<]*)(</para>)", a)
    if not m:
        raise SystemExit("self-test setup failed: UI rule not found")
    return a[: m.start(2)] + m.group(2).replace(" ", "&nbsp;") + a[m.end(2):], f


def m_single_nbsp(a, f):
    return sub_once(a, "<para>gismu / lujvo / fuhivla</para>",
                    "<para>gismu&nbsp;/ lujvo / fuhivla</para>", "single nbsp"), f


def m_thin_space(a, f):
    return sub_once(a, "<para>gismu / lujvo / fuhivla</para>",
                    "<para>gismu&thinsp;/ lujvo / fuhivla</para>", "thin space"), f


def m_para_tail(a, f):
    return sub_once(a, "            <para>cmevla</para>\n",
                    "            <para>cmevla</para> GARBAGE\n", "text after the rule paragraph"), f


def m_split_arrow(a, f):
    return sub_once(a, "      <title>Word classes</title>",
                    "      <title>Word classes</title>\n"
                    "    <para>FAKE &lt;<phrase>-</phrase> wrong</para>",
                    "arrow split across markup"), f


def m_reused_quote(a, f):
    return sub_once(a, "      <title>Word classes</title>",
                    "      <title>Word classes</title>\n"
                    "    <para>FAKE <quote>&#8592;</quote> wrong</para>",
                    "approved context reused elsewhere"), f


def m_duplicate_context(a, f):
    return sub_once(a, "      <quote>&#8592;</quote>",
                    "      <quote>&#8592;</quote><quote>&#8592;</quote>",
                    "approved context duplicated"), f


def m_remove_context(a, f):
    return sub_once(a, "      <quote>&lt;-</quote>", "      <quote>the ASCII form</quote>",
                    "approved context removed"), f


def m_xreflabel_arrow(a, f):
    return sub_once(a, '<section xml:id="section-peg-grammar">',
                    '<section xreflabel="FAKE &#8592; wrong" xml:id="section-peg-grammar">',
                    "arrow in a rendered attribute"), f


def m_root_id(a, f):
    return sub_once(a, 'xml:id="section-peg-grammar"', 'xml:id="section-peg-gram"',
                    "root id changed"), f


def m_duplicate_id(a, f):
    return sub_once(a, 'xml:id="section-peg-grammar"', 'xml:id="peg-classes"',
                    "root id duplicates a section id"), f


def m_root_tag(a, f):
    a = sub_once(a, '<section xml:id="section-peg-grammar">',
                 '<article xml:id="section-peg-grammar">', "root tag changed")
    return sub_once(a, '    </section>\n  </section>\n  <section xml:id="section-EBNF">',
                    '    </section>\n  </article>\n  <section xml:id="section-EBNF">',
                    "root tag changed (close)"), f


def m_drop_anchor(a, f):
    return sub_once(a, '<anchor xml:id="c21-peg" />', "", "c21-peg anchor removed"), f


def m_compensating_relocation(a, f):
    """Round-4 finding 3: neutralize the real approved context and put an
    impostor in its slot, preserving the owner count and the pinned path."""
    a = sub_once(a, "<quote>&#8592;</quote>", "<quote>the left arrow</quote>",
                 "relocation: neutralize the real context")
    return sub_once(a, "    <para>\n      The grammar is the one that",
                    "    <para>FAKE\n      <quote>&#8592;</quote>\n      wrong</para>\n"
                    "    <para>\n      The grammar is the one that",
                    "relocation: insert the impostor"), f


def m_relocate_notation(a, f):
    """The same trick against the notation item."""
    a = sub_once(a, "A rule has the form <emphasis>name</emphasis> &#8592; expression",
                 "A rule has the form <emphasis>name</emphasis>, an arrow, then an expression",
                 "notation relocation: neutralize")
    return sub_once(a, "    <section xml:id=\"peg-classes\">",
                    "    <itemizedlist><listitem><para>A rule has the form "
                    "<emphasis>name</emphasis> &#8592; expression: that expression parses "
                    "the construct called name.</para></listitem></itemizedlist>\n"
                    "    <section xml:id=\"peg-classes\">",
                    "notation relocation: insert"), f


def m_intro_edit(a, f):
    """Any introduction edit must be pinned deliberately."""
    return sub_once(a, "Here is the full notation:", "Here is the notation, in full:", "intro edited"), f


def m_root_text_arrow(a, f):
    """Raw text between the root <section> and its title: outside every element
    the older digest serialized, but printed by the transform."""
    return sub_once(a, 'xml:id="section-peg-grammar">\n    <title>',
                    'xml:id="section-peg-grammar">FAKE &#8592; ROOT\n    <title>',
                    "arrow in the root's own text"), f


def m_section_title_tail(a, f):
    return sub_once(a, "      <title>Word classes</title>",
                    "      <title>Word classes</title>FAKE &#8592; TITLETAIL",
                    "arrow in a section title's tail"), f


def m_last_section_tail(a, f):
    return sub_once(a, '    </section>\n  </section>\n  <section xml:id="section-EBNF">',
                    '    </section>FAKE &#8592; LASTTAIL\n  </section>\n  <section xml:id="section-EBNF">',
                    "arrow after the last section"), f


def m_endterm_label(a, f):
    """A generated cross-reference label reprints a rule's arrow from a
    source that contains no arrow of its own."""
    a = sub_once(a, "<term>zifcme &#8592;</term>",
                 '<term xml:id="fake-arrow-source">zifcme &#8592;</term>',
                 "endterm: label a term")
    return sub_once(a, "      <title>cmevla</title>",
                    "      <title>cmevla</title>\n"
                    '      <para>FAKE <xref linkend="fake-arrow-source" '
                    'endterm="fake-arrow-source" /></para>',
                    "endterm: generated label"), f


def m_intro_attribute_only(a, f):
    """An attribute-only intro change: a cross-reference retargeted, which
    changes the label it prints."""
    return sub_once(a, '<xref linkend="chapter-phonology" />',
                    '<xref linkend="chapter-morphology" />',
                    "intro cross-reference retargeted"), f


def m_inline_boundary_space(a, f):
    """Removing the spaces around an approved quote changes what prints
    without changing any word."""
    return sub_once(a, "definition is\n      <quote>&#8592;</quote>\n      here",
                    "definition is<quote>&#8592;</quote>here",
                    "inline boundary spaces removed"), f


WRONG_ENTRY = ("<variablelist><varlistentry><term>cmevla &#8592;</term>"
               "<listitem><para>WRONG</para></listitem></varlistentry></variablelist>")
EBNF_START = '  <section xml:id="section-EBNF">'
INTRO_TITLE = '<title><anchor xml:id="c21-intro" />About the formal grammars</title>'


def m_sibling_section(a, f):
    """PR #119 review: a wrong rule in a new section between the PEG section
    and the EBNF escaped both checks."""
    return sub_once(a, EBNF_START,
                    '  <section xml:id="peg-extra"><title>Extra</title>' + WRONG_ENTRY
                    + "</section>\n" + EBNF_START, "sibling section"), f


def m_chapter_level_list(a, f):
    return sub_once(a, EBNF_START, "  " + WRONG_ENTRY + "\n" + EBNF_START,
                    "rule list directly in the chapter"), f


def m_intro_rule(a, f):
    return sub_once(a, INTRO_TITLE,
                    INTRO_TITLE + "\n    <para>cmevla &#8592; WRONG</para>",
                    "rule-like paragraph in the chapter introduction"), f


def m_duplicate_root_id(a, f):
    return sub_once(a, INTRO_TITLE,
                    INTRO_TITLE + '\n    <para xml:id="section-peg-grammar">Fake</para>',
                    "second element with the section's id"), f


def m_ebnf_arrow(a, f):
    title = '<title><anchor xml:id="c21s2" />EBNF grammar of Lojban</title>'
    return sub_once(a, title, title + "\n    <para>FAKE &#8592; wrong</para>",
                    "arrow in the EBNF section"), f


MUTATIONS = [
    ("stray rule-like paragraph at section level", m_stray_root_para),
    ("paragraph abusing the notation wording", m_notation_prefix_abuse),
    ("rule-like simpara inside a section", m_simpara),
    ("second term in an entry", m_second_term),
    ("second paragraph in an entry", m_second_para),
    ("text after a directive", m_directive_tail),
    ("phrase before a directive", m_directive_phrase),
    ("nested section with its own rule list", m_nested_section),
    ("arrow written as an entity", m_entity_arrow),
    ("ASCII arrow in prose", m_ascii_arrow),
    ("entry outside a variablelist", m_entry_outside_list),
    ("unresolvable entity", m_unknown_entity),
    ("a definition edited in print only", m_body_edit),
    ("synchronized delete from print and fixture", m_sync_delete),
    ("synchronized swap in print and fixture", m_sync_swap),
    ("synchronized duplicate in print and fixture", m_sync_duplicate),
    ("rule moved to the wrong section", m_cross_section_move),
    ("definition set entirely in non-breaking spaces", m_ui_all_nbsp),
    ("one non-breaking space in a definition", m_single_nbsp),
    ("a thin space in a definition", m_thin_space),
    ("text after the rule paragraph", m_para_tail),
    ("arrow split across inline markup", m_split_arrow),
    ("approved arrow context reused in a section", m_reused_quote),
    ("approved arrow context duplicated", m_duplicate_context),
    ("approved arrow context removed", m_remove_context),
    ("arrow in a rendered attribute", m_xreflabel_arrow),
    ("section root id changed", m_root_id),
    ("root id duplicating a section id", m_duplicate_id),
    ("root element retagged", m_root_tag),
    ("c21-peg anchor removed", m_drop_anchor),
    ("approved context relocated with a compensating removal", m_compensating_relocation),
    ("notation context relocated with a compensating removal", m_relocate_notation),
    ("introduction edited without updating its pin", m_intro_edit),
    ("arrow in the root element's own text", m_root_text_arrow),
    ("arrow in a section title's tail", m_section_title_tail),
    ("arrow after the last section", m_last_section_tail),
    ("generated cross-reference label reprinting a rule arrow", m_endterm_label),
    ("introduction changed by attribute only", m_intro_attribute_only),
    ("inline boundary spaces removed around an approved arrow", m_inline_boundary_space),
    ("wrong rule in a new sibling section", m_sibling_section),
    ("rule list directly in the chapter", m_chapter_level_list),
    ("rule-like paragraph in the chapter introduction", m_intro_rule),
    ("second element with the section's id", m_duplicate_root_id),
    ("arrow in the EBNF section", m_ebnf_arrow),
]


def run_checker(tree):
    return subprocess.run(
        [sys.executable, str(tree / "scripts" / "check-peg-grammar.py")],
        capture_output=True, text=True,
    ).returncode


def main():
    failures = []
    with tempfile.TemporaryDirectory(prefix="peg-selftest-") as tmp:
        tree = Path(tmp) / "cll"
        for sub in ("scripts", "chapters", "tests/fixtures", "dtd", "xml"):
            src = ROOT / sub
            dst = tree / sub
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copytree(src, dst, ignore=shutil.ignore_patterns("*.pdf", "*.zip"))
        chapter = tree / "chapters" / "21.xml"
        fixture = tree / "tests" / "fixtures" / "peg-morphology.peg"
        base_a = chapter.read_text(encoding="utf-8")
        base_f = fixture.read_text(encoding="utf-8")

        rc = run_checker(tree)
        print(f"{'ok  ' if rc == 0 else 'FAIL'}  unmodified tree passes")
        if rc != 0:
            failures.append("unmodified tree does not pass")

        for label, mutate in MUTATIONS:
            a, f = mutate(base_a, base_f)
            chapter.write_text(a, encoding="utf-8")
            fixture.write_text(f, encoding="utf-8")
            rc = run_checker(tree)
            ok = rc != 0
            print(f"{'ok  ' if ok else 'FAIL'}  detected: {label}")
            if not ok:
                failures.append(label)
            chapter.write_text(base_a, encoding="utf-8")
            fixture.write_text(base_f, encoding="utf-8")

    print()
    if failures:
        print(f"test-check-peg-grammar: {len(failures)} case(s) NOT detected:")
        for f in failures:
            print(" -", f)
        return 1
    print(f"test-check-peg-grammar: all {len(MUTATIONS)} corruption cases detected")
    return 0


if __name__ == "__main__":
    sys.exit(main())
