#!/usr/bin/env python3
"""Regenerate chapter 21's EBNF Cross-Reference and verify the printed table.

The cross-reference (section-cross-reference) is the first edition's
reverse index over the EBNF: for each selma'o or grammatical-construct
name, it lists the number of every rule whose right-hand side refers to
that name. This checker rebuilds that index from the printed EBNF
itself and requires the printed table to match it exactly:

  * entry set   -- one entry per name referenced by any numbered rule;
  * entry order -- plain ASCII sort of the names (inherited);
  * per-entry reference list -- the referring rules' numbers, ordered
    by referring-rule name with '=' appended (the inherited order sorts
    the literal "name = ..." grammar lines, so suffixed forms such as
    bridi-tail-1 precede their base form bridi-tail);
  * every reference -- an <xref linkend="cll_bnf-N"/> whose displayed
    <subscript> is the same N;
  * every anchor -- cll_bnf-N must exist in the EBNF section and mark
    the rule whose printed subscript is N (an anchor physically sits at
    the tail of the previous rule's body, marking the start of the next
    rule).

Unnumbered pseudo-rules (any-word, anything) have prose bodies and no
anchors; they can be referenced but never refer.

Usage: check-cross-reference.py chapters/21.xml   (exit 1 on failure)
"""
import re, sys


def strip_markup(text):
    text = re.sub(r'<!--.*?-->', ' ', text, flags=re.S)
    text = re.sub(r'<[^>]+>', ' ', text)
    text = re.sub(r'&\w+;', ' ', text)
    return re.sub(r'\s+', ' ', text).strip()


def main(path):
    s = open(path, encoding='utf-8').read()
    cut = s.find('<section xml:id="section-cross-reference">')
    if cut < 0:
        print('cross-reference section not found')
        return 1
    ebnf, xr = s[:cut], s[cut:]
    bad = 0

    # ---- parse the EBNF rules ----
    rules = []           # (name, number-or-None, body-token-list)
    anchor_rule = {}     # anchor number N -> rule name it marks
    pending = []         # anchors seen in a body: they mark the NEXT rule
    for e in re.findall(r'<varlistentry>(.*?)</varlistentry>', ebnf, re.S):
        raw_term = re.search(r'<term>(.*?)</term>', e, re.S).group(1)
        term_anchors = [int(x) for x in re.findall(r'xml:id="cll_bnf-(\d+)"', raw_term)]
        term = strip_markup(raw_term)
        m = re.match(r"^([\w'-]+)\s*(\d+)?\s*=$", term)
        if not m:
            print(f'FAIL cannot parse rule term: {term!r}')
            return 1
        name, num = m.group(1), (int(m.group(2)) if m.group(2) else None)
        for n in pending + term_anchors:
            anchor_rule[n] = name
        raw_body = re.search(r'<listitem>(.*?)$', e, re.S).group(1)
        pending = [int(x) for x in re.findall(
            r'xml:id="cll_bnf-(\d+)"', re.sub(r'<!--.*?-->', ' ', raw_body, flags=re.S))]
        body = strip_markup(raw_body)
        rules.append((name, num, re.findall(r"[A-Za-z][A-Za-z0-9'-]*", body)))

    # every numbered rule must have its own anchor, correctly placed
    for name, num, _ in rules:
        if num is None:
            continue
        if anchor_rule.get(num) != name:
            print(f'FAIL rule {name} ({num}): anchor cll_bnf-{num} missing or '
                  f'marks {anchor_rule.get(num)!r}')
            bad += 1

    # ---- regenerate the reverse index ----
    refs = {}
    for name, num, toks in rules:
        if num is None:
            continue
        for tok in sorted(set(toks)):
            refs.setdefault(tok, []).append((name, num))
    linekey = lambda n: n + '='
    expected = {t: [num for _, num in sorted(lst, key=lambda x: linekey(x[0]))]
                for t, lst in refs.items()}

    # ---- parse the printed table ----
    printed, order = {}, []
    for m in re.finditer(r'<varlistentry>\s*<term>(.*?)</term>\s*<listitem>\s*'
                         r'<para>(.*?)</para>\s*</listitem>\s*</varlistentry>', xr, re.S):
        term = m.group(1).strip()
        pairs = re.findall(r'<xref linkend="cll_bnf-(\d+)"/>\s*<subscript>(\d+)</subscript>',
                           m.group(2))
        nxrefs = len(re.findall(r'<xref', m.group(2)))
        if nxrefs != len(pairs):
            print(f'FAIL {term}: {nxrefs} xrefs but only {len(pairs)} '
                  f'well-formed xref/subscript pairs')
            bad += 1
        printed[term] = pairs
        order.append(term)

    # ---- compare ----
    for term in sorted(set(expected) - set(printed)):
        print(f'FAIL missing entry: {term} (referenced by rules '
              f'{expected[term]})')
        bad += 1
    for term in sorted(set(printed) - set(expected)):
        print(f'FAIL spurious entry: {term} (nothing references it)')
        bad += 1
    if order != sorted(order):
        print('FAIL entry order is not the inherited ASCII sort')
        bad += 1
    ok = 0
    for term, pairs in printed.items():
        if term not in expected:
            continue
        mism = [(a, b) for a, b in pairs if a != b]
        if mism:
            print(f'FAIL {term}: linkend/subscript mismatch {mism}')
            bad += 1
            continue
        got = [int(a) for a, _ in pairs]
        if got != expected[term]:
            print(f'FAIL {term}: printed {got}, regenerated {expected[term]}')
            bad += 1
            continue
        for n, _ in pairs:
            if int(n) not in anchor_rule:
                print(f'FAIL {term}: link target cll_bnf-{n} has no anchor')
                bad += 1
                break
        else:
            ok += 1
    print(f'{ok}/{len(printed)} entries match the regenerated reverse index, '
          f'{bad} failures')
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1]))
