#!/usr/bin/env python3
"""Verify that the typeset PEG appendix still states the grammar exactly.

chapters/a02.xml prints the word-form grammar as a variablelist, one entry
per rule, with the file's ASCII arrow set as U+2192. The machine-readable
grammar it was made from is kept verbatim at tests/fixtures/peg-morphology.peg.

This check reconstructs "name <- body" from every appendix entry and requires
the result to match the fixture's rules exactly: same rules, same order, same
bodies (including the "#: DIRECTIVE" annotations, which the appendix sets in
italics). Any drift — a typo introduced while editing the appendix, or a rule
updated in the fixture but not in print — fails.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
APPENDIX = ROOT / "chapters" / "a02.xml"
FIXTURE = ROOT / "tests" / "fixtures" / "peg-morphology.peg"
ARROW = "→"

ENTRY = re.compile(
    r"<varlistentry>\s*<term>(?P<name>.*?)\s*(?:&#8594;|→)\s*</term>\s*"
    r"<listitem>\s*<para>(?P<body>.*?)</para>\s*</listitem>\s*</varlistentry>",
    re.S,
)
DIRECTIVE = re.compile(r"\s*<emphasis>#:\s*(?P<d>[^<]+?)\s*</emphasis>\s*$")


def appendix_rules():
    text = APPENDIX.read_text(encoding="utf-8")
    if ARROW in text and "&#8594;" not in text:
        pass  # either spelling is fine
    rules = []
    for m in ENTRY.finditer(text):
        name = m.group("name").strip()
        body = m.group("body")
        d = DIRECTIVE.search(body)
        directive = None
        if d:
            directive = d.group("d")
            body = body[: d.start()]
        body = body.strip()
        if "<" in body.replace("&lt;", ""):
            sys.exit(f"check-peg-appendix: unexpected markup inside rule {name!r}: {body[:80]}")
        rules.append((name, body, directive))
    return rules


def fixture_rules():
    rules = []
    for line in FIXTURE.read_text(encoding="utf-8").split("\n"):
        if "&lt;-" not in line or line.strip().startswith("#"):
            continue
        name, body = line.split("&lt;-", 1)
        directive = None
        m = re.search(r"\s+#:\s*(\S+)\s*$", body)
        if m:
            directive = m.group(1)
            body = body[: m.start()]
        rules.append((name.strip(), body.strip(), directive))
    return rules


def main():
    got, want = appendix_rules(), fixture_rules()
    problems = []
    if len(got) != len(want):
        problems.append(f"rule count: appendix {len(got)}, fixture {len(want)}")
    for i, (g, w) in enumerate(zip(got, want)):
        if g != w:
            problems.append(
                f"rule {i + 1} differs:\n  appendix: {g[0]} <- {g[1]}"
                + (f"  #: {g[2]}" if g[2] else "")
                + f"\n  fixture:  {w[0]} <- {w[1]}"
                + (f"  #: {w[2]}" if w[2] else "")
            )
    only_a = {r[0] for r in got} - {r[0] for r in want}
    only_f = {r[0] for r in want} - {r[0] for r in got}
    if only_a:
        problems.append(f"rules only in the appendix: {sorted(only_a)}")
    if only_f:
        problems.append(f"rules only in the fixture: {sorted(only_f)}")
    if problems:
        print("check-peg-appendix: FAILED")
        for p in problems[:20]:
            print(" -", p)
        return 1
    print(f"check-peg-appendix: {len(got)} rules match tests/fixtures/peg-morphology.peg exactly")
    return 0


if __name__ == "__main__":
    sys.exit(main())
