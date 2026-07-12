#!/usr/bin/env python3
"""Extract Lojban example text from DocBook chapters as TSV: file, id, text.

Pulls <jbo> lines from interlinear-gloss examples (id = the enclosing
<example> xml:id where present, with a per-example line index) and
<jbophrase> inline phrases (positional ids).

Cleanup applied (pedagogical typography, not language):
- bracketed elidables keep their content ("[ke'e]" -> "ke'e");
- grouping-aid hyphens are removed: standalone " - " always, and "--"
  joiners except in lines containing zoi/la'o (whose quoted payload must
  stay opaque; such lines keep all "--" and may need manual attention);
- XML entities are decoded.

NOT yet implemented (tracked in the example-validation issue #8): an
annotation/allowlist scheme for intentionally-ill-formed examples; those
currently appear as ordinary rows and show up as FAILs in the report.
"""
import html, re, sys

EXAMPLE = re.compile(r'<example[^>]*?xml:id="([^"]+)"[^>]*>(.*?)</example>', re.S)
JBO = re.compile(r"<jbo>(.*?)</jbo>", re.S)
PHRASE = re.compile(r"<jbophrase[^>]*>(.*?)</jbophrase>", re.S)
TAG = re.compile(r"<[^>]+>")

def clean(s):
    s = TAG.sub("", s)
    s = html.unescape(s)
    s = s.replace("[", " ").replace("]", " ")
    s = re.sub(r"(?<=\s)-+(?=\s)", " ", " " + s + " ")
    if not re.search(r"\bzoi\b|\bla'o\b", s):
        s = s.replace("--", " ")
    return " ".join(s.split())

for p in sys.argv[1:]:
    text = open(p, encoding="utf-8").read()
    consumed = set()
    for em in EXAMPLE.finditer(text):
        exid, body = em.group(1), em.group(2)
        for j, m in enumerate(JBO.finditer(body)):
            consumed.add(em.start(2) + m.start())
            t = clean(m.group(1))
            if t:
                print(f"{p}\t{exid}#{j}\t{t}")
    for i, m in enumerate(JBO.finditer(text)):
        if m.start() in consumed:
            continue
        t = clean(m.group(1))
        if t:
            print(f"{p}\tjbo-{i}\t{t}")
    for i, m in enumerate(PHRASE.finditer(text)):
        t = clean(m.group(1))
        if t:
            print(f"{p}\tphrase-{i}\t{t}")
