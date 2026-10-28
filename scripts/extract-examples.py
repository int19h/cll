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

The chrestomathy appendix (a01.xml) is handled specially: its texts are
continuous prose/verse laid out as table rows (first cell of each row is
the Lojban, second the English), where quotations and verse lines span
cell boundaries. Per-cell parsing therefore produces false failures, so
each a01 section is emitted as ONE row of continuous text (id = the
section xml:id), per issue #75 and the parse-sweep audit.

NOT yet implemented (tracked in the example-validation issue #8): an
annotation/allowlist scheme for intentionally-ill-formed examples; those
currently appear as ordinary rows and show up as FAILs in the report.
"""
import os, re, sys
import xml.etree.ElementTree as ET
from pathlib import Path

XML_ID = '{http://www.w3.org/XML/1998/namespace}id'
ROOT = Path(__file__).resolve().parent.parent
ENTITY_FILES = sorted(ROOT.glob('dtd/*.ent')) + sorted(ROOT.glob('xml/*.ent'))
ENTITIES = '\n'.join(match.group(0) for path in ENTITY_FILES
                     for match in re.finditer(r'<!ENTITY\s+([A-Za-z][\w.-]*)\s+"([^"]*)"\s*>',
                                              path.read_text(encoding='utf-8')))



def read_chapter(path):
    # Chapters have no document type of their own. Supply the book's local
    # publishing entities without loading an external DTD or network resource.
    text = Path(path).read_text(encoding='utf-8')
    return ET.fromstring('<!DOCTYPE chapter [\n' + ENTITIES + '\n]>\n' + text)


def clean(s):
    s = s.replace("[", " ").replace("]", " ")
    s = re.sub(r"(?<=\s)-+(?=\s)", " ", " " + s + " ")
    if not re.search(r"\bzoi\b|\bla'o\b", s):
        s = s.replace("--", " ")
        s = s.replace("\u2013", " ").replace("\u2014", " ")
    return " ".join(s.split())

def extract(path):
    root = read_chapter(path)
    if os.path.basename(path) == 'a01.xml':
        for section in root.iter('section'):
            pieces = []
            for row in section.iter('tr'):
                cells = [cell for cell in row if cell.tag in ('td', 'th')]
                if cells:
                    text = clean(''.join(cells[0].itertext()))
                    if text:
                        pieces.append(text)
            if pieces:
                yield section.get(XML_ID), ' '.join(pieces)
        return
    consumed = set()
    for example in root.iter('example'):
        example_id = example.get(XML_ID)
        if example_id is None:
            continue
        for index, element in enumerate(example.iter('jbo')):
            consumed.add(element)
            text = clean(''.join(element.itertext()))
            if text:
                yield f'{example_id}#{index}', text
    for index, element in enumerate(root.iter('jbo')):
        if element not in consumed:
            text = clean(''.join(element.itertext()))
            if text:
                yield f'jbo-{index}', text
    for index, element in enumerate(root.iter('jbophrase')):
        text = clean(''.join(element.itertext()))
        if text:
            yield f'phrase-{index}', text


if __name__ == '__main__':
    for path in sys.argv[1:]:
        for identifier, text in extract(path):
            print(f'{path}\t{identifier}\t{text}')
