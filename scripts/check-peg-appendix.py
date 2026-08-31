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

ROOT_TAG = "article"
ROOT_ID = "appendix-peg-morphology"
ROOT_ANCHOR = "a02"

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
# The only places outside a rule's term where the prose may show an arrow,
# pinned by structural location as well as exact text.
APPROVED_ARROW_CONTEXTS = [
    ("./para[2]/quote[1]", "←"),
    ("./para[2]/quote[2]", "<-"),
    ("./itemizedlist[1]/listitem[1]/para[1]",
     "A rule has the form name ← expression: the construct called "
     "name is parsed by that expression."),
]

# Structure-and-text digest of everything before the first grammar section.
# Pinning the whole introduction is what makes the arrow inventory closed:
# without it, an approved context can be removed and a rule-like impostor put
# in its place, preserving the count and the pinned path. Editing the
# introduction means updating this constant in the same commit.
INTRO_SHA256 = "5fcd570473ff02bcf298deb4cb0032d282c3a2ef24cbe1c7065acf6582272e08"

PREDEFINED = {"amp": "&", "lt": "<", "gt": ">", "quot": '"', "apos": "'"}


def norm(s):
    """Collapse only XML's formatting whitespace. U+00A0 and friends are
    meaningful characters here: a definition written with non-breaking spaces
    renders as one unbreakable run, which is the clipping this appendix was
    retypeset to fix, so it must not compare equal to ordinary spaces."""
    return re.sub(r"[ \t\r\n]+", " ", s or "").strip(" \t\r\n")


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


def xml_id(el):
    return el.get("{http://www.w3.org/XML/1998/namespace}id")


def check_root(root, problems):
    """The appendix's own identity is load-bearing: eight cross-references
    point at it, and its anchor survives from the first edition."""
    if root.tag != ROOT_TAG:
        problems.append(f"root element is <{root.tag}>, expected <{ROOT_TAG}>")
    if xml_id(root) != ROOT_ID:
        problems.append(f"root xml:id is {xml_id(root)!r}, expected {ROOT_ID!r}")
    if not any(el.tag == "anchor" and xml_id(el) == ROOT_ANCHOR for el in root.iter()):
        problems.append(f"the {ROOT_ANCHOR!r} anchor is missing")
    ids = [xml_id(el) for el in root.iter() if xml_id(el)]
    dupes = {i for i in ids if ids.count(i) > 1}
    if dupes:
        problems.append(f"duplicate xml:id values: {sorted(dupes)}")


def intro_digest(root):
    """Tags and text of every element before the first grammar section."""
    parts = []
    for child in root:
        if child.tag == "section":
            break
        for node in child.iter():
            parts.extend((node.tag, norm(node.text), norm(node.tail)))
    return hashlib.sha256("\x1f".join(parts).encode("utf-8")).hexdigest()


def check_intro(root, problems):
    digest = intro_digest(root)
    if digest != INTRO_SHA256:
        problems.append(
            "the appendix introduction has changed:\n"
            f"    expected SHA-256 {INTRO_SHA256}\n"
            f"    found            {digest}\n"
            "    (update INTRO_SHA256 in the same commit as the prose)"
        )


def approved_contexts(root, problems):
    """The approved arrow-bearing prose elements, resolved at their pinned
    locations. Returning the elements themselves lets the audit compare
    identity, not merely content."""
    els = []
    for path, text in APPROVED_ARROW_CONTEXTS:
        el = root.find(path)
        if el is None:
            problems.append(f"the approved arrow context at {path} is missing")
            continue
        got = norm("".join(el.itertext()))
        if got != text:
            problems.append(f"the approved arrow context at {path} reads {got!r}, expected {text!r}")
        els.append(el)
    return els


def check_attributes(root, problems):
    """No attribute may carry an arrow: a rendered one (xreflabel, say) would
    print a rule-like line that the text audit never sees."""
    for el in root.iter():
        for name, value in el.attrib.items():
            if any(tok in value for tok in ARROW_TOKENS):
                problems.append(f"<{el.tag}> attribute {name}={value!r} contains an arrow")


def collect(root, problems):
    """Closed inventory of the appendix's rule entries."""
    parents = parent_map(root)
    sections = list(root.iter("section"))
    ids = [xml_id(s) for s in sections]
    if ids != SECTION_IDS:
        problems.append(
            "grammar sections differ from the expected set/order:\n"
            f"    found:    {ids}\n"
            f"    expected: {SECTION_IDS}"
        )
    for s in sections:
        if parents.get(id(s)) is not root:
            problems.append(f"section {xml_id(s)} is nested inside another element")
    section_of = {id(s): xml_id(s) for s in sections}

    rules = []
    terms = []
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

        li_children = list(listitem)
        if [c.tag for c in li_children] != ["para"]:
            problems.append(f"{where}/{name}: listitem must contain exactly one para")
            continue
        para = li_children[0]

        # Every structural text node around the rule must be formatting only:
        # stray text anywhere here is printed next to the definition.
        stray = {
            "before the term": entry.text,
            "between term and listitem": term.tail,
            "before the paragraph": listitem.text,
            "after the paragraph": para.tail,
            "after the listitem": listitem.tail,
            "after the entry": entry.tail,
        }
        bad = {k: v for k, v in stray.items() if norm(v)}
        if bad:
            problems.append(f"{where}/{name}: stray text {bad}")
            continue

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
        terms.append(term)
    return rules, terms


def arrow_owners(root):
    """Innermost elements whose rendered text carries an arrow, in document
    order. Working from rendered text rather than single text nodes catches an
    arrow split across inline markup."""
    owners = []
    for el in root.iter():
        full = "".join(el.itertext())
        shown = [tok for tok in ARROW_TOKENS if tok in full]
        if not shown:
            continue
        child_texts = ["".join(c.itertext()) for c in el]
        if any(not any(tok in ct for ct in child_texts) for tok in shown):
            owners.append(el)
    return owners


def arrow_audit(root, approved, terms, problems):
    """The arrows in the appendix are a closed, ordered inventory: the pinned
    prose contexts, in order, then one per rule term — compared by element
    identity, so nothing can take an approved context's place."""
    owners = arrow_owners(root)
    expected = approved + terms
    if len(owners) != len(expected):
        problems.append(
            f"arrow-bearing elements: found {len(owners)}, expected "
            f"{len(approved)} in the introduction and one per rule term ({len(terms)})"
        )
    for i, (got, want) in enumerate(zip(owners, expected)):
        if got is not want:
            kind = "approved prose context" if i < len(approved) else "rule term"
            problems.append(
                f"arrow-bearing element {i + 1} is not the expected {kind}: "
                f"<{got.tag}> {norm(''.join(got.itertext()))[:80]!r}"
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

    check_root(root, problems)
    check_intro(root, problems)
    check_attributes(root, problems)
    approved = approved_contexts(root, problems)
    got, terms = collect(root, problems)
    arrow_audit(root, approved, terms, problems)

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
