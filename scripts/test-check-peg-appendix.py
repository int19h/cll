#!/usr/bin/env python3
"""Self-test for scripts/check-peg-appendix.py.

The appendix's fidelity claim rests on that checker, so the checker's own
blind spots are a correctness problem. Each case below is a way the printed
grammar could come to contradict the pinned fixture — most of them raised by
the PR #105 review, and all of them valid or plausible enough to survive the
repository's other checks. Every one must make the checker fail; the
unmodified tree must make it pass.

Run: python3 scripts/test-check-peg-appendix.py
"""
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

CMEVLA_ENTRY = """      <varlistentry>
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


# Each mutation takes (appendix_text, fixture_text) and returns the pair.
def m_stray_root_para(a, f):
    return sub_once(a, "  <section xml:id=\"a02-classes\">",
                    "  <para>FAKE &#8592; wrong</para>\n  <section xml:id=\"a02-classes\">",
                    "stray root para"), f


def m_notation_prefix_abuse(a, f):
    return sub_once(a, "    <title>Word classes</title>",
                    "    <title>Word classes</title>\n"
                    "    <para>A rule has the form FAKE &#8592; wrong</para>",
                    "notation-prefix abuse"), f


def m_simpara(a, f):
    return sub_once(a, "    <title>Word classes</title>",
                    "    <title>Word classes</title>\n    <simpara>FAKE &#8592; wrong</simpara>",
                    "simpara"), f


def m_second_term(a, f):
    return sub_once(a, "        <term>CMEVLA &#8592;</term>",
                    "        <term>CMEVLA &#8592;</term>\n        <term>FAKE &#8592;</term>",
                    "second term"), f


def m_second_para(a, f):
    return sub_once(a, "          <para>cmevla</para>",
                    "          <para>cmevla</para>\n          <para>FAKE &#8592; wrong</para>",
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
    return sub_once(a, "    <title>Word classes</title>",
                    "    <title>Word classes</title>\n"
                    "    <section xml:id=\"a02-fake\"><title>Fake</title><variablelist>\n"
                    + CMEVLA_ENTRY.replace("CMEVLA", "FAKE").replace("cmevla", "wrong")
                    + "    </variablelist></section>",
                    "nested section"), f


def m_entity_arrow(a, f):
    return sub_once(a, "    <title>Word classes</title>",
                    "    <title>Word classes</title>\n    <para>FAKE &larr; wrong</para>",
                    "entity arrow"), f


def m_ascii_arrow(a, f):
    return sub_once(a, "    <title>Word classes</title>",
                    "    <title>Word classes</title>\n    <para>FAKE &lt;- wrong</para>",
                    "ascii arrow"), f


def m_entry_outside_list(a, f):
    return sub_once(a, "    <title>Word classes</title>",
                    "    <title>Word classes</title>\n" + CMEVLA_ENTRY.replace("CMEVLA", "FAKE"),
                    "entry outside a variablelist"), f


def m_unknown_entity(a, f):
    return sub_once(a, "    <title>Word classes</title>",
                    "    <title>Word classes</title>\n    <para>&nosuchentity;</para>",
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
    entry = """      <varlistentry>
        <term>cmevla &#8592;</term>
        <listitem>
          <para>jbocme / zifcme</para>
        </listitem>
      </varlistentry>
"""
    a2 = sub_once(a, entry, "", "cross-section move (remove)")
    a2 = sub_once(a2, "  <section xml:id=\"a02-cmevla\">",
                  "  <section xml:id=\"a02-cmevla\">", "anchor")
    # reinsert into the previous section's list
    a2 = sub_once(a2, "    </variablelist>\n  </section>\n  <section xml:id=\"a02-cmevla\">",
                  entry + "    </variablelist>\n  </section>\n  <section xml:id=\"a02-cmevla\">",
                  "cross-section move (insert)")
    return a2, f


MUTATIONS = [
    ("stray rule-like paragraph at article level", m_stray_root_para),
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
]


def run_checker(tree):
    return subprocess.run(
        [sys.executable, str(tree / "scripts" / "check-peg-appendix.py")],
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
        appendix = tree / "chapters" / "a02.xml"
        fixture = tree / "tests" / "fixtures" / "peg-morphology.peg"
        base_a = appendix.read_text(encoding="utf-8")
        base_f = fixture.read_text(encoding="utf-8")

        rc = run_checker(tree)
        print(f"{'ok  ' if rc == 0 else 'FAIL'}  unmodified tree passes")
        if rc != 0:
            failures.append("unmodified tree does not pass")

        for label, mutate in MUTATIONS:
            a, f = mutate(base_a, base_f)
            appendix.write_text(a, encoding="utf-8")
            fixture.write_text(f, encoding="utf-8")
            rc = run_checker(tree)
            ok = rc != 0
            print(f"{'ok  ' if ok else 'FAIL'}  detected: {label}")
            if not ok:
                failures.append(label)
            appendix.write_text(base_a, encoding="utf-8")
            fixture.write_text(base_f, encoding="utf-8")

    print()
    if failures:
        print(f"test-check-peg-appendix: {len(failures)} case(s) NOT detected:")
        for f in failures:
            print(" -", f)
        return 1
    print(f"test-check-peg-appendix: all {len(MUTATIONS)} corruption cases detected")
    return 0


if __name__ == "__main__":
    sys.exit(main())
