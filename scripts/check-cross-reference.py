#!/usr/bin/env python3
"""Verify chapter 21's EBNF: its rule text, its anchors, and the printed
EBNF Cross-Reference.

The EBNF (section-EBNF) prints each rule as a <varlistentry>. The term holds
the rule's two anchors, its name, its number and "=", and the body holds the
right-hand side. The cross-reference (section-cross-reference) is the first
edition's reverse index over the EBNF: for each selma'o or grammatical-
construct name, it lists the number of every rule whose right-hand side
refers to that name.

This checker requires:

  * rule text -- the SHA-256 digest of the normalized (name, number, body)
    triples equals EBNF_SHA256. A deliberate change to the grammar updates
    the constant in the same commit (issue #120), so that no silent edit of
    a rule passes CI;
  * anchors -- every numbered rule carries exactly one b<N> and exactly one
    cll_bnf-<N> (with xreflabel "BNF rule #N") in its own term, N being its
    printed number, and no rule carries an anchor in its body;
  * xml:id uniqueness -- across the whole chapter file;
  * entry set   -- one table entry per name referenced by any numbered rule;
  * entry order -- plain ASCII sort of the names (inherited);
  * per-entry reference list -- the referring rules' numbers, ordered by
    referring-rule name with '=' appended (the inherited order sorts the
    literal "name = ..." grammar lines, so suffixed forms such as
    bridi-tail-1 precede their base form bridi-tail);
  * every reference -- an <xref linkend="cll_bnf-N"/> whose displayed
    <subscript> is the same N, and whose anchor exists;
  * non-emptiness -- the EBNF and the table both have entries.

Unnumbered pseudo-rules (any-word, anything) have prose bodies and no
anchors; they can be referenced but never refer.

Usage: check-cross-reference.py chapters/21.xml   (exit 1 on failure)
scripts/test-check-cross-reference.py plants defects and requires failures.
"""
import hashlib, re, sys
import xml.etree.ElementTree as ET

# Digest of the normalized rule triples. Update it in the same commit as a
# deliberate change to a printed rule (see the module docstring).
EBNF_SHA256 = "b200a452b22f403e2f7ece8e74a5440a04b4663a4506e99b221b3ebf91c095d7"


def strip_markup(text):
    text = re.sub(r'<!--.*?-->', ' ', text, flags=re.S)
    text = re.sub(r'<[^>]+>', ' ', text)
    text = re.sub(r'&\w+;', ' ', text)
    return re.sub(r'\s+', ' ', text).strip()


def normalize_body(raw_body):
    """The rule text as printed: markup removed, entities kept, spaces folded."""
    text = re.sub(r'<!--.*?-->', ' ', raw_body, flags=re.S)
    text = re.sub(r'<[^>]+>', ' ', text)
    return re.sub(r'\s+', ' ', text).strip()


def digest(rules):
    h = hashlib.sha256()
    for name, num, body in rules:
        h.update(f'{name}\t{num if num is not None else ""}\t{body}\n'.encode('utf-8'))
    return h.hexdigest()


def main(path, out=print):
    try:
        root = ET.parse(path).getroot()
    except ET.ParseError as exc:
        out(f'FAIL invalid XML: {exc}')
        return 1
    xml_id = '{http://www.w3.org/XML/1998/namespace}id'
    sections = list(root.iter('section'))
    ebnf = next((el for el in sections if el.get(xml_id) == 'section-EBNF'), None)
    xr = next((el for el in sections if el.get(xml_id) == 'section-cross-reference'), None)
    if ebnf is None or xr is None or sections.index(ebnf) >= sections.index(xr):
        out('FAIL EBNF section not found before the cross-reference')
        return 1
    bad = 0

    # ---- xml:id uniqueness across the chapter ----
    ids = [el.get(xml_id) for el in root.iter() if el.get(xml_id)]
    dupes = sorted({i for i in ids if ids.count(i) > 1})
    if dupes:
        out(f'FAIL duplicate xml:id values: {dupes}')
        bad += 1

    # ---- parse the EBNF rules ----
    rules = []           # (name, number-or-None, normalized body)
    toks = {}            # (name, number) -> body token list
    anchor_rule = {}     # anchor number N -> rule name it marks
    for entry in ebnf.iter('varlistentry'):
        term_el = entry.find('term')
        body_el = entry.find('listitem')
        if term_el is None or body_el is None:
            out('FAIL rule entry needs a term and listitem')
            return 1
        term = strip_markup(ET.tostring(term_el, encoding='unicode'))
        m = re.match(r"^([\w'-]+)\s*(\d+)?\s*=$", term)
        if not m:
            out(f'FAIL cannot parse rule term: {term!r}')
            return 1
        name, num = m.group(1), (int(m.group(2)) if m.group(2) else None)
        raw_body = ET.tostring(body_el, encoding='unicode')
        if list(body_el.iter('anchor')):
            out(f'FAIL rule {name}: an anchor sits in the body; anchors belong in the term')
            bad += 1
        anchors = list(term_el.iter('anchor'))
        b_anchors = [int(a.get(xml_id)[1:]) for a in anchors
                     if re.fullmatch(r'b\d+', a.get(xml_id, ''))]
        x_anchors = [(a.get('xreflabel', ''),
                      a.get(xml_id)[8:]) for a in anchors
                     if re.fullmatch(r'cll_bnf-\d+', a.get(xml_id, ''))]
        n_anchors = len(anchors)
        if num is None:
            if n_anchors:
                out(f'FAIL rule {name}: an unnumbered rule carries an anchor')
                bad += 1
        else:
            ok_b = b_anchors == [num]
            ok_x = x_anchors == [(f'BNF rule #{num}', str(num))]
            if not (ok_b and ok_x and n_anchors == 2):
                out(f'FAIL rule {name} ({num}): expected exactly the anchors b{num} and '
                    f'cll_bnf-{num} (xreflabel "BNF rule #{num}") in its term; found '
                    f'b={b_anchors} cll_bnf={x_anchors} total={n_anchors}')
                bad += 1
            for _, n in x_anchors:
                anchor_rule[int(n)] = name
        body = normalize_body(raw_body)
        if (name, num) in toks:
            out(f'FAIL rule {name} ({num}) is printed twice')
            bad += 1
        rules.append((name, num, body))
        toks[(name, num)] = re.findall(r"[A-Za-z][A-Za-z0-9'-]*", strip_markup(raw_body))
    if not rules:
        out('FAIL the EBNF section has no rules')
        return 1

    # ---- pin the rule text ----
    d = digest(rules)
    if d != EBNF_SHA256:
        out(f'FAIL the EBNF rule text changed: digest {d}\n'
            f'     expected EBNF_SHA256 {EBNF_SHA256}\n'
            f'     If the change to the printed grammar is deliberate, update '
            f'EBNF_SHA256 in scripts/check-cross-reference.py in the same commit.')
        bad += 1

    # ---- regenerate the reverse index ----
    refs = {}
    for name, num, _ in rules:
        if num is None:
            continue
        for tok in sorted(set(toks[(name, num)])):
            refs.setdefault(tok, []).append((name, num))
    linekey = lambda n: n + '='
    expected = {t: [num for _, num in sorted(lst, key=lambda x: linekey(x[0]))]
                for t, lst in refs.items()}

    # ---- parse the printed table ----
    printed, order = {}, []
    for entry in xr.iter('varlistentry'):
        term_el = entry.find('term')
        para = entry.find('./listitem/para')
        if term_el is None or para is None:
            out('FAIL cross-reference entry needs a term and paragraph')
            bad += 1
            continue
        term = ''.join(term_el.itertext()).strip()
        children = list(para)
        pairs = []
        for i, child in enumerate(children):
            if child.tag != 'xref':
                continue
            target = re.fullmatch(r'cll_bnf-(\d+)', child.get('linkend', ''))
            sub = children[i + 1] if i + 1 < len(children) else None
            if target and sub is not None and sub.tag == 'subscript':
                number = ''.join(sub.itertext()).strip()
                if number.isdigit():
                    pairs.append((target.group(1), number))
        nxrefs = len(list(para.iter('xref')))
        if nxrefs != len(pairs):
            out(f'FAIL {term}: {nxrefs} xrefs but only {len(pairs)} '
                f'well-formed xref/subscript pairs')
            bad += 1
        if term in printed:
            out(f'FAIL duplicate entry: {term}')
            bad += 1
        else:
            printed[term] = pairs
        order.append(term)
    if not printed:
        out('FAIL the cross-reference table has no entries')
        return 1

    # every <varlistentry> in the table must have parsed as exactly one row
    n_entries = len(list(xr.iter('varlistentry')))
    if n_entries != len(order):
        out(f'FAIL {n_entries} <varlistentry> elements in the table but '
            f'{len(order)} parsed entries')
        bad += 1

    # ---- compare ----
    for term in sorted(set(expected) - set(printed)):
        out(f'FAIL missing entry: {term} (referenced by rules '
            f'{expected[term]})')
        bad += 1
    for term in sorted(set(printed) - set(expected)):
        out(f'FAIL spurious entry: {term} (nothing references it)')
        bad += 1
    if order != sorted(order):
        out('FAIL entry order is not the inherited ASCII sort')
        bad += 1
    ok = 0
    for term, pairs in printed.items():
        if term not in expected:
            continue
        mism = [(a, b) for a, b in pairs if a != b]
        if mism:
            out(f'FAIL {term}: linkend/subscript mismatch {mism}')
            bad += 1
            continue
        got = [int(a) for a, _ in pairs]
        if got != expected[term]:
            out(f'FAIL {term}: printed {got}, regenerated {expected[term]}')
            bad += 1
            continue
        for n, _ in pairs:
            if int(n) not in anchor_rule:
                out(f'FAIL {term}: link target cll_bnf-{n} has no anchor')
                bad += 1
                break
        else:
            ok += 1
    out(f'{ok}/{len(printed)} entries match the regenerated reverse index, '
        f'{len(rules)} rules pinned, {bad} failures')
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1]))
