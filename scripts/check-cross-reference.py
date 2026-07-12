#!/usr/bin/env python3
"""Verify chapter 21's EBNF Cross-Reference against the printed EBNF.

The cross-reference (section-cross-reference) maps each selma'o or
grammatical-construct name to the BNF rule (cll_bnf-N anchor) that
defines or canonically uses it. The choice of canonical rule is
editorial and inherited from the first edition; this checker verifies
the *soundness* of every entry: the anchor exists, and the production
it introduces defines the name (lowercase constructs) or mentions it
(selma'o and other terminals). It catches renumbered, removed, or
retargeted rules when the EBNF changes.

Usage: check-cross-reference.py chapters/21.xml   (exit 1 on failure)
"""
import re, sys

def main(path):
    s = open(path, encoding='utf-8').read()
    cut = s.find('<section xml:id="section-cross-reference">')
    if cut < 0:
        print('cross-reference section not found'); return 1
    ebnf, xr = s[:cut], s[cut:]

    # Split the EBNF into varlistentries in order; record which anchors
    # (cll_bnf-N) appear in each entry's body -- an anchor marks the
    # START of the NEXT entry's rule.
    entries = re.findall(r'<varlistentry>(.*?)</varlistentry>', ebnf, re.S)
    rule_of_anchor = {}   # N -> (name, body-tokens, term)
    pending = []          # body anchors waiting for the next entry
    for e in entries:
        raw_term = re.search(r'<term>(.*?)</term>', e, re.S).group(1)
        self_anchors = [int(x) for x in re.findall(r'xml:id="cll_bnf-(\d+)"', raw_term)]
        term = re.sub(r'<[^>]+>', ' ', re.sub(r'<!--.*?-->', ' ', raw_term, flags=re.S))
        term = re.sub(r'\s+', ' ', term).strip()
        m = re.match(r'^([\w-]+)\s*(?:(\d+)\s*)?=$', term)
        name = m.group(1) if m else None
        body = re.search(r'<listitem>\s*<para>(.*?)$', e, re.S).group(1)
        toks = set(re.findall(r"[\w'-]+", re.sub(r'<[^>]+>', ' ', re.sub(r'<!--.*?-->', ' ', body, flags=re.S))))
        for n in pending + self_anchors:
            rule_of_anchor[n] = (name, toks, term)
        pending = [int(x) for x in re.findall(r'xml:id="cll_bnf-(\d+)"', re.sub(r'<!--.*?-->', ' ', body, flags=re.S))]
    ok = bad = 0
    xr_entries = re.findall(r'<term>([^<]+)</term>\s*<listitem>\s*<para>\s*(<xref[^/]*/>.*?)</para>', xr, re.S)
    for t, b in xr_entries:
        t = t.strip()
        n = int(re.search(r'cll_bnf-(\d+)', b).group(1))
        if n not in rule_of_anchor:
            print(f'FAIL {t}: anchor cll_bnf-{n} not found in EBNF'); bad += 1; continue
        name, toks, term = rule_of_anchor[n]
        if t == name or t in toks:
            ok += 1
        else:
            print(f'FAIL {t}: rule at cll_bnf-{n} ({name!r}) neither defines nor mentions it'); bad += 1
    print(f'{ok} entries verified, {bad} failures ({len(xr_entries)} total)')
    return 1 if bad else 0

if __name__ == '__main__':
    sys.exit(main(sys.argv[1]))
