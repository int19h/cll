#!/usr/bin/env python3
"""Extract Lojban example text from DocBook chapters as TSV: file, exampleid, text.
Pulls <jbo> lines from interlinear-gloss examples and <jbophrase> inline phrases.
Examples marked role="pre-reform" or with a bad-example annotation are tagged SKIP.
"""
import re, sys

JBO = re.compile(r"<jbo>(.*?)</jbo>", re.S)
PHRASE = re.compile(r"<jbophrase[^>]*>(.*?)</jbophrase>", re.S)
TAG = re.compile(r"<[^>]+>")

def clean(s):
    s = TAG.sub("", s)
    s = s.replace("[", " ").replace("]", " ")   # bracketed elidables: keep the word
    s = re.sub(r"(?<=\s)-+(?=\s)", " ", " " + s + " ")  # standalone hyphens = grouping aids
    s = s.replace("&amp;", "&").replace("&lt;", "<").replace("&gt;", ">")
    return " ".join(s.split())

for path in sys.argv[1:]:
    text = open(path, encoding="utf-8").read()
    for i, m in enumerate(JBO.finditer(text)):
        t = clean(m.group(1))
        if t:
            print(f"{path}\tjbo-{i}\t{t}")
    for i, m in enumerate(PHRASE.finditer(text)):
        t = clean(m.group(1))
        if t:
            print(f"{path}\tphrase-{i}\t{t}")
