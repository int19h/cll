#!/usr/bin/env python3
"""Flag likely undotted cmevla in Lojban text: la/lai/la'i/doi followed by a
consonant-final word without leading/trailing dots, inside jbo-ish elements.

Under dotside orthography the book writes cmevla with explicit dots
(«la .djan.»). A consonant-final word right after a name particle is a cmevla
and must carry them; vowel-final words (brivla/cmavo) are fine undotted.
Heuristic by design; keep exceptions out via the allowlist below.
"""
import os, re, sys

# Known pre-existing offenders live in the allowlist file next to this script
# (format: "<basename>:<exact snippet>" per line, "#" comments). They are
# tracked for burn-down in the dotside sweep issue; the lint's job is to stop
# NEW undotted cmevla from entering.
ALLOW_FILE = os.path.join(os.path.dirname(__file__), "lint-undotted-cmevla.allow")
ALLOW = set()
if os.path.exists(ALLOW_FILE):
    for ln in open(ALLOW_FILE, encoding="utf-8"):
        ln = ln.strip()
        if ln and not ln.startswith("#"):
            ALLOW.add(ln)

JBO_ELEM = re.compile(r"<(jbo|jbophrase|valsi)\b[^>]*>(.*?)</\1>", re.S)
BAD = re.compile(r"\b(la|lai|la'i|doi)\s+([a-gjklmnp-vxz',\.]*[bcdfgjklmnprstvxz])(?=[\s<;:!?)]|$)")

rc = 0
for path in sys.argv[1:]:
    text = open(path, encoding="utf-8").read()
    for m in JBO_ELEM.finditer(text):
        for w in BAD.finditer(m.group(2)):
            word = w.group(2)
            if word.startswith(".") and word.endswith("."):
                continue  # properly dotted (dot included in match)
            line = text.count("\n", 0, m.start() + w.start()) + 1
            snippet = w.group(0)
            if f"{os.path.basename(path)}:{snippet}" in ALLOW:
                continue
            print(f"{path}:{line}: undotted cmevla? «{snippet}» (add to scripts/lint-undotted-cmevla.allow only for tracked pre-existing text)")
            rc = 1
sys.exit(rc)
