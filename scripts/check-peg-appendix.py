#!/usr/bin/env python3
"""Verify that the typeset PEG appendix still states the grammar exactly.

chapters/a02.xml prints the word-form grammar as a variablelist per section,
one entry per rule, with the file's ASCII arrow set as U+2190. The
machine-readable grammar it was made from is kept verbatim at
tests/fixtures/peg-morphology.peg.

Three independent things are checked, because a mutual comparison of two
mutable copies is not enough on its own — a synchronized edit to both would
otherwise pass:

1. The fixture is the grammar this edition published: its SHA-256 must equal
   FIXTURE_SHA256 below, which is the digest of the verbatim listing that
   chapters/a02.xml carried before it was typeset. A deliberate grammar
   update changes the digest here, in a reviewable commit; an accidental
   edit fails.
2. The appendix's rule inventory matches the fixture exactly: same count,
   unique names, same order, same definitions and directives after decoding
   XML entities — and each of the thirteen appendix sections holds exactly
   the rules of the corresponding block of the fixture, so a rule cannot be
   moved between sections unnoticed.
3. The appendix's structure holds: every rule entry is a varlistentry inside
   a variablelist inside a grammar section, and no other visible element
   carries an arrow (which would let a contradictory line masquerade as a
   rule), apart from the notation key in the introduction.
"""
import hashlib
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
APPENDIX = ROOT / "chapters" / "a02.xml"
FIXTURE = ROOT / "tests" / "fixtures" / "peg-morphology.peg"

# SHA-256 of tests/fixtures/peg-morphology.peg. This is the grammar as
# published: the exact bytes of the programlisting that chapters/a02.xml
# carried before PR #105 typeset it. Update only together with the printed
# grammar, in a commit that says why.
FIXTURE_SHA256 = "327f2e474580d04d9346f2ce85c36773814570666d1d1b6939d8bbdad3e6a886"

ARROW = "←"
EXPECTED_SECTIONS = 13
# The introduction states the notation with a bare arrow; that is the only
# arrow-bearing text allowed outside a rule entry.
NOTATION_PREFIX = "A rule has the form"


PREDEFINED = ("amp", "lt", "gt", "quot", "apos")


def entity_safe(text):
    """Parse a chapter that uses DTD entities (&ndash; and friends) without
    the DTD: mask entity references the parser would reject, leaving XML's
    five predefined entities and all numeric character references (so the
    arrow survives) to be decoded normally."""
    return re.sub(
        r"&(?!#)(?!(?:%s);)(\w+);" % "|".join(PREDEFINED), r"[[ent:\1]]", text
    )


def load_appendix():
    tree = ET.fromstring(entity_safe(APPENDIX.read_text(encoding="utf-8")))
    return tree


def itertext(el):
    return "".join(el.itertext())


def appendix_rules(root):
    """[(section_id, name, body, directive)] in document order, plus a list of
    structural problems found while collecting them."""
    problems = []
    rules = []
    seen_entries = set()
    sections = [s for s in root.findall("section")]
    if len(sections) != EXPECTED_SECTIONS:
        problems.append(f"expected {EXPECTED_SECTIONS} grammar sections, found {len(sections)}")
    for sec in sections:
        sid = sec.get("{http://www.w3.org/XML/1998/namespace}id") or "(no id)"
        for vl in sec.findall("variablelist"):
            for entry in vl.findall("varlistentry"):
                seen_entries.add(id(entry))
                term = entry.find("term")
                para = entry.find("listitem/para")
                if term is None or para is None:
                    problems.append(f"{sid}: varlistentry missing term or para")
                    continue
                t = itertext(term).strip()
                if not t.endswith(ARROW):
                    problems.append(f"{sid}: term does not end with the arrow: {t!r}")
                    continue
                name = t[: -len(ARROW)].strip()
                directive = None
                em = para.find("emphasis")
                if em is not None:
                    d = itertext(em).strip()
                    m = re.fullmatch(r"#:\s*(\S+)", d)
                    if not m:
                        problems.append(f"{sid}/{name}: unexpected emphasis {d!r}")
                    else:
                        directive = m.group(1)
                    body = (para.text or "").strip()
                else:
                    body = itertext(para).strip()
                rules.append((sid, name, body, directive))

    # Inside the grammar sections, only a rule entry may carry an arrow: a
    # stray paragraph or heading with one could otherwise read as a rule.
    # (The introduction, outside these sections, names the arrow in prose.)
    for sec in sections:
        in_entry = {id(e) for entry in sec.iter("varlistentry") for e in entry.iter()}
        for el in sec.iter():
            if el.tag not in ("para", "term", "title", "bridgehead"):
                continue
            if id(el) in in_entry:
                continue
            text = itertext(el)
            if ARROW in text and not text.strip().startswith(NOTATION_PREFIX):
                sid = sec.get("{http://www.w3.org/XML/1998/namespace}id") or "(no id)"
                problems.append(
                    f"{sid}: arrow outside a rule entry in <{el.tag}>: {text.strip()[:70]!r}"
                )
    return rules, problems


def fixture_blocks():
    """[[(name, body, directive)]] — one list per '#___' separated block."""
    blocks, cur = [], []
    for line in FIXTURE.read_text(encoding="utf-8").split("\n"):
        if line.strip().startswith("#___"):
            blocks.append(cur)
            cur = []
            continue
        if "&lt;-" not in line or line.strip().startswith("#"):
            continue
        name, body = line.split("&lt;-", 1)
        directive = None
        m = re.search(r"\s+#:\s*(\S+)\s*$", body)
        if m:
            directive = m.group(1)
            body = body[: m.start()]
        cur.append((name.strip(), decode(body.strip()), directive))
    blocks.append(cur)
    return blocks


def decode(s):
    """Decode the XML entities the fixture inherited from the programlisting."""
    for ent, ch in (("&lt;", "<"), ("&gt;", ">"), ("&quot;", '"'), ("&#x27;", "'"), ("&amp;", "&")):
        s = s.replace(ent, ch)
    return s


def main():
    problems = []

    digest = hashlib.sha256(FIXTURE.read_bytes()).hexdigest()
    if digest != FIXTURE_SHA256:
        problems.append(
            "the grammar fixture has changed:\n"
            f"    expected SHA-256 {FIXTURE_SHA256}\n"
            f"    found            {digest}\n"
            "    (update FIXTURE_SHA256 only together with the printed grammar)"
        )

    root = load_appendix()
    got, structural = appendix_rules(root)
    problems += structural

    blocks = fixture_blocks()
    want = [(i, n, b, d) for i, blk in enumerate(blocks) for (n, b, d) in blk]

    if len(got) != len(want):
        problems.append(f"rule count: appendix {len(got)}, fixture {len(want)}")

    names = [r[1] for r in got]
    dupes = {n for n in names if names.count(n) > 1}
    if dupes:
        problems.append(f"duplicate rule names in the appendix: {sorted(dupes)}")

    # section ids in document order, to map fixture block index -> section id
    section_ids = [
        s.get("{http://www.w3.org/XML/1998/namespace}id")
        for s in root.findall("section")
    ]
    for i, (g, w) in enumerate(zip(got, want)):
        g_sid, g_name, g_body, g_dir = g
        w_block, w_name, w_body, w_dir = w
        expected_sid = section_ids[w_block] if w_block < len(section_ids) else "(missing)"
        if (g_name, g_body, g_dir) != (w_name, w_body, w_dir):
            problems.append(
                f"rule {i + 1} differs:\n"
                f"    appendix: {g_name} <- {g_body}" + (f"  #: {g_dir}" if g_dir else "") + "\n"
                f"    fixture:  {w_name} <- {w_body}" + (f"  #: {w_dir}" if w_dir else "")
            )
        elif g_sid != expected_sid:
            problems.append(
                f"rule {g_name} is in section {g_sid}, but belongs to the block printed as {expected_sid}"
            )

    if problems:
        print("check-peg-appendix: FAILED")
        for p in problems[:20]:
            print(" -", p)
        if len(problems) > 20:
            print(f" … and {len(problems) - 20} more")
        return 1
    print(
        f"check-peg-appendix: {len(got)} rules in {len(section_ids)} sections match "
        f"tests/fixtures/peg-morphology.peg (digest pinned)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
