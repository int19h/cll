#!/usr/bin/env python3
"""Flag likely undotted cmevla after la/lai/la'i/doi inside Lojban text elements.

Under dotside orthography the book writes cmevla with explicit dots on BOTH
sides («la .djan.»). Heuristic: within <jbo>/<jbophrase>/<valsi> content (inline
markup stripped), a word following a name particle whose final letter is a
consonant is a cmevla and must carry a leading and a trailing dot. Vowel-final
words (brivla/cmavo names like «la cribe») are exempt. Capital letters are
stress notation and count as their lowercase selves; commas and dots are
permitted word-internal characters.

Allowlist (scripts/lint-undotted-cmevla.allow): lines of
"<basename>:<snippet>:<max_count>". A file may contain at most max_count
occurrences of that offending snippet; any growth fails the lint. Tracked for
burn-down in the dotside sweep issue; do not add entries for new text.
"""
import os, re, sys
from collections import Counter
from pathlib import Path
from xml.parsers import expat

ALLOW_FILE = os.path.join(os.path.dirname(__file__), "lint-undotted-cmevla.allow")
ALLOW = {}
if os.path.exists(ALLOW_FILE):
    for ln in open(ALLOW_FILE, encoding="utf-8"):
        ln = ln.strip()
        if not ln or ln.startswith("#"):
            continue
        parts = ln.split(":")
        if len(parts) < 3:
            raise SystemExit(f"{ALLOW_FILE}: malformed line: {ln!r} (want base:snippet:max_count)")
        base, snippet, maxn = parts[0], ":".join(parts[1:-1]), parts[-1]
        ALLOW[(base, snippet)] = int(maxn)

ROOT = Path(__file__).resolve().parent.parent
ENTITY_FILES = sorted(ROOT.glob('dtd/*.ent')) + sorted(ROOT.glob('xml/*.ent'))
ENTITIES = '\n'.join(match.group(0) for path in ENTITY_FILES
                     for match in re.finditer(r'<!ENTITY\s+([A-Za-z][\w.-]*)\s+"([^"]*)"\s*>',
                                              path.read_text(encoding='utf-8')))


def lojban_elements(text):
    # Expat reports source lines and excludes comments from character data.
    prefix = '<!DOCTYPE chapter [\n' + ENTITIES + '\n]>\n'
    parser = expat.ParserCreate()
    active = []
    elements = []
    depth = 0

    def start(name, attributes):
        nonlocal depth
        for _, _, parts in active:
            parts.append(' ')
        depth += 1
        if name in ('jbo', 'jbophrase', 'valsi'):
            line = parser.CurrentLineNumber - prefix.count('\n')
            active.append((depth, line, []))

    def data(value):
        for _, _, parts in active:
            parts.append(value)

    def end(name):
        nonlocal depth
        if active and active[-1][0] == depth:
            _, line, parts = active.pop()
            elements.append((line, ''.join(parts)))
        for _, _, parts in active:
            parts.append(' ')
        depth -= 1

    parser.StartElementHandler = start
    parser.EndElementHandler = end
    parser.CharacterDataHandler = data
    parser.Parse(prefix + text, True)
    return sorted(elements, key=lambda item: item[0])

VOWELS = set("aeiou")
# word after a name particle: letters (any case), apostrophe, comma, dot
PARTICLE = re.compile(r"(?<![a-zA-Z'.])(la'i|lai|la|doi)\s+([a-zA-Z',.]+)")

CONSONANTS = set("bcdfgjklmnprstvxz")

def offending(word):
    # strip surrounding dots for analysis, remember them
    lead = word.startswith(".")
    core = word.strip(".")
    if not core:
        return False
    trail = word.endswith(".")
    last = core[-1].lower()
    if last not in CONSONANTS:
        return False  # vowel-final: not a cmevla, no dots required
    return not (lead and trail)

rc = 0
for path in sys.argv[1:]:
    base = os.path.basename(path)
    text = open(path, encoding="utf-8").read()
    counts = Counter()
    for line, content in lojban_elements(text):
        for w in PARTICLE.finditer(content):
            word = w.group(2)
            if not offending(word):
                continue
            snippet = f"{w.group(1)} {word}"
            counts[snippet] += 1
            allowed = ALLOW.get((base, snippet), 0)
            if counts[snippet] > allowed:
                extra = f" (allowlisted x{allowed}, found more)" if allowed else ""
                print(f"{path}:{line}: undotted cmevla? «{snippet}»{extra}")
                rc = 1
sys.exit(rc)
