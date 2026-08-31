#!/usr/bin/env python3
"""Verify that the typeset PEG appendix still states the grammar exactly.

chapters/a02.xml prints the word-form grammar as a variablelist per section,
one entry per rule, with the file's ASCII arrow set as U+2190. The
machine-readable grammar it was made from is kept verbatim at
tests/fixtures/peg-morphology.peg.

The appendix claims that every rule definition is reproduced with its own
characters, in the file's own order. Proving that needs three things, because
comparing two mutable copies proves nothing against an edit to both, and
searching for expected shapes proves nothing about content that does not
match those shapes:

1. **The fixture is the grammar this edition published.** Its SHA-256 must
   equal FIXTURE_SHA256. A deliberate grammar update changes that constant in
   a reviewable commit; an accidental edit fails.
2. **The printed inventory is closed and matches it.** Every section, every
   varlistentry and every rule paragraph in the appendix is accounted for —
   not merely searched for — with the expected shape, and the rules match the
   fixture's names, order, definitions, directives, and block-to-section
   grouping.
3. **Nothing else in the appendix can read as a rule.** Every piece of text
   that owns an arrow (U+2190 or U+2192, or the source's ASCII "<-") must be
   either a rule's term or one of the few approved places where the prose
   names the notation. DTD entities are resolved from the repository's own
   entity files first, so an entity spelling cannot smuggle an arrow past the
   audit; an entity this script cannot resolve is a failure, not a shrug.
"""
import hashlib
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
APPENDIX = ROOT / "chapters" / "a02.xml"
FIXTURE = ROOT / "tests" / "fixtures" / "peg-morphology.peg"
ENTITY_FILES = sorted(ROOT.glob("dtd/*.ent")) + sorted(ROOT.glob("xml/*.ent"))

# SHA-256 of tests/fixtures/peg-morphology.peg: the grammar as published, the
# exact bytes of the programlisting chapters/a02.xml carried before PR #105
# typeset it. Update only together with the printed grammar.
FIXTURE_SHA256 = "327f2e474580d04d9346f2ce85c36773814570666d1d1b6939d8bbdad3e6a886"

ARROW = "←"
ARROW_TOKENS = ("←", "→", "<-")

# The appendix's grammar sections, in the order the fixture's blocks appear.
SECTION_IDS = [
    "a02-classes", "a02-words", "a02-cmevla", "a02-cmavo", "a02-brivla",
    "a02-fuhivla", "a02-gismu", "a02-syllables", "a02-vowels",
    "a02-consonants", "a02-boundaries", "a02-spaces", "a02-selmaho",
]

# The only places outside a rule's term where the prose may show an arrow,
# as (tag, exact normalized text). Editing the introduction's notation means
# updating this list deliberately.
ALLOWED_ARROW_CONTEXTS = {
    ("quote", "←"),
    ("quote", "<-"),
    ("para", "A rule has the form name ← expression: the construct called "
             "name is parsed by that expression."),
}

PREDEFINED = {"amp": "&", "lt": "<", "gt": ">", "quot": '"', "apos": "'"}


def norm(s):
    return re.sub(r"\s+", " ", s or "").strip()


def numeric_refs(s):
    s = re.sub(r"&#x([0-9a-fA-F]+);", lambda m: chr(int(m.group(1), 16)), s)
    return re.sub(r"&#(\d+);", lambda m: chr(int(m.group(1))), s)


def entity_map():
    """name -> replacement text, from the repository's own entity files."""
    m = {}
    for path in ENTITY_FILES:
        text = path.read_text(encoding="utf-8", errors="replace")
        for name, value in re.findall(r'<!ENTITY\s+([A-Za-z][\w.-]*)\s+"([^"]*)"', text):
            m.setdefault(name, numeric_refs(value))
    return m


def resolve_entities(text):
    """Replace named entity references with their characters. Returns the
    resolved text and the names that could not be resolved."""
    ents = entity_map()
    unknown = set()

    def sub(match):
        name = match.group(1)
        if name in PREDEFINED:
            return match.group(0)  # leave for the XML parser
        if name in ents:
            return ents[name]
        unknown.add(name)
        return match.group(0)

    return re.sub(r"&(?!#)([A-Za-z][\w.-]*);", sub, text), unknown


def parent_map(root):
    return {id(c): p for p in root.iter() for c in p}


def collect(root, problems):
    """Closed inventory of the appendix's rule entries."""
    parents = parent_map(root)
    sections = list(root.iter("section"))
    ids = [s.get("{http://www.w3.org/XML/1998/namespace}id") for s in sections]
    if ids != SECTION_IDS:
        problems.append(
            "grammar sections differ from the expected set/order:\n"
            f"    found:    {ids}\n"
            f"    expected: {SECTION_IDS}"
        )
    for s in sections:
        if parents.get(id(s)) is not root:
            sid = s.get("{http://www.w3.org/XML/1998/namespace}id")
            problems.append(f"section {sid} is nested inside another element")
    section_of = {id(s): s.get("{http://www.w3.org/XML/1998/namespace}id") for s in sections}

    rules = []
    terms = set()
    for entry in root.iter("varlistentry"):
        vl = parents.get(id(entry))
        sec = parents.get(id(vl)) if vl is not None else None
        where = section_of.get(id(sec)) if sec is not None else None
        if vl is None or vl.tag != "variablelist" or where is None:
            problems.append("a varlistentry is not inside a grammar section's variablelist")
            continue
        children = list(entry)
        tags = [c.tag for c in children]
        if tags != ["term", "listitem"]:
            problems.append(f"{where}: varlistentry has children {tags}, expected [term, listitem]")
            continue
        term, listitem = children
        if list(term):
            problems.append(f"{where}: term contains markup: {norm(''.join(term.itertext()))!r}")
            continue
        t = norm(term.text)
        if not t.endswith(ARROW):
            problems.append(f"{where}: term does not end with the arrow: {t!r}")
            continue
        name = t[: -len(ARROW)].strip()
        terms.add(id(term))

        li_children = list(listitem)
        if [c.tag for c in li_children] != ["para"] or norm(listitem.text):
            problems.append(f"{where}/{name}: listitem must contain exactly one para")
            continue
        para = li_children[0]
        para_children = list(para)
        directive = None
        if para_children:
            if [c.tag for c in para_children] != ["emphasis"]:
                problems.append(
                    f"{where}/{name}: rule paragraph contains "
                    f"{[c.tag for c in para_children]}, expected at most one emphasis"
                )
                continue
            em = para_children[0]
            if list(em) or norm(em.tail):
                problems.append(f"{where}/{name}: content after the directive: {norm(em.tail)!r}")
                continue
            d = norm("".join(em.itertext()))
            m = re.fullmatch(r"#:\s*(\S+)", d)
            if not m:
                problems.append(f"{where}/{name}: unexpected emphasis {d!r}")
                continue
            directive = m.group(1)
        body = norm(para.text)
        rules.append((where, name, body, directive))
    return rules, terms


def arrow_audit(root, terms, problems):
    """Every text node that owns an arrow must be a rule's term or one of the
    approved prose contexts."""
    for el in root.iter():
        owned = [el.text] + [c.tail for c in el]
        if not any(tok in (t or "") for t in owned for tok in ARROW_TOKENS):
            continue
        if id(el) in terms:
            continue
        key = (el.tag, norm("".join(el.itertext())))
        if key in ALLOWED_ARROW_CONTEXTS:
            continue
        problems.append(
            f"arrow outside a rule term in <{el.tag}>: {norm(''.join(el.itertext()))[:80]!r}"
        )


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
        cur.append((norm(name), decode_fixture(norm(body)), directive))
    blocks.append(cur)
    return blocks


def decode_fixture(s):
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

    text, unknown = resolve_entities(APPENDIX.read_text(encoding="utf-8"))
    if unknown:
        problems.append(
            f"entity references this check cannot resolve: {sorted(unknown)} "
            "(add the defining .ent file, or spell the character directly)"
        )
    try:
        root = ET.fromstring(text)
    except ET.ParseError as e:
        print(f"check-peg-appendix: FAILED\n - cannot parse {APPENDIX}: {e}")
        return 1

    got, terms = collect(root, problems)
    arrow_audit(root, terms, problems)

    want = [(SECTION_IDS[i] if i < len(SECTION_IDS) else f"(block {i})", n, b, d)
            for i, blk in enumerate(fixture_blocks()) for (n, b, d) in blk]

    if len(got) != len(want):
        problems.append(f"rule count: appendix {len(got)}, fixture {len(want)}")

    names = [r[1] for r in got]
    dupes = {n for n in names if names.count(n) > 1}
    if dupes:
        problems.append(f"duplicate rule names in the appendix: {sorted(dupes)}")

    for i, (g, w) in enumerate(zip(got, want)):
        if g[1:] != w[1:]:
            problems.append(
                f"rule {i + 1} differs:\n"
                f"    appendix: {g[1]} <- {g[2]}" + (f"  #: {g[3]}" if g[3] else "") + "\n"
                f"    fixture:  {w[1]} <- {w[2]}" + (f"  #: {w[3]}" if w[3] else "")
            )
        elif g[0] != w[0]:
            problems.append(f"rule {g[1]} is printed in section {g[0]}, but belongs to {w[0]}")

    if problems:
        print("check-peg-appendix: FAILED")
        for p in problems[:20]:
            print(" -", p)
        if len(problems) > 20:
            print(f" … and {len(problems) - 20} more")
        return 1
    print(
        f"check-peg-appendix: {len(got)} rules in {len(SECTION_IDS)} sections match "
        f"tests/fixtures/peg-morphology.peg (digest pinned, inventory closed)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
