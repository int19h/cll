#!/usr/bin/env python3
"""Self-test of check-cross-reference.py: the real chapter passes, and each
planted defect fails. Run from the repository root; exit 1 on any problem."""
import importlib.util, os, re, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
CHAPTER = os.path.join(HERE, '..', 'chapters', '21.xml')

spec = importlib.util.spec_from_file_location('ccr', os.path.join(HERE, 'check-cross-reference.py'))
ccr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ccr)


def run(text):
    with tempfile.NamedTemporaryFile('w', suffix='.xml', delete=False, encoding='utf-8') as f:
        f.write(text)
    try:
        msgs = []
        rc = ccr.main(f.name, out=msgs.append)
        return rc, '\n'.join(msgs)
    finally:
        os.unlink(f.name)


def ebnf_span(s):
    a = s.find('<section xml:id="section-EBNF">')
    b = s.find('<section xml:id="section-cross-reference">')
    assert 0 < a < b
    return a, b


def mutate(s, name, old, new, count=1):
    """Replace `old` with `new` inside the entry of rule `name` in the EBNF."""
    a, b = ebnf_span(s)
    sec = s[a:b]
    m = re.search(r'<varlistentry\b[^>]*>\s*<term>(?:(?!</varlistentry>).)*?\n\s*' + re.escape(name)
                  + r'\n(?:(?!</varlistentry>).)*?</varlistentry>', sec, re.S)
    assert m, name
    entry = m.group(0)
    assert entry.count(old) >= count, (name, old)
    entry2 = entry.replace(old, new, count)
    return s[:a] + sec[:m.start()] + entry2 + sec[m.end():] + s[b:]


def main():
    s = open(CHAPTER, encoding='utf-8').read()
    problems = []

    rc, msg = run(s)
    if rc != 0:
        problems.append(f'the real chapter fails:\n{msg}')

    cases = []
    # A whole rule or table row inside a comment is absent from the book.
    a, b = ebnf_span(s)
    entry = next(m for m in re.finditer(r'<varlistentry\b[^>]*>.*?</varlistentry>', s[a:b], re.S)
                 if '<anchor xml:id="b40"' in m.group(0))
    hidden = re.sub(r'<!--.*?-->', '', entry.group(0), flags=re.S)
    cases.append(('whole sentence rule commented out',
                  s[:a + entry.start()] + '<!--' + hidden + '-->' + s[a + entry.end():]))
    xr_entry = re.search(r'<varlistentry\b[^>]*>.*?</varlistentry>', s[b:], re.S)
    cases.append(('whole cross-reference row commented out',
                  s[:b + xr_entry.start()] + '<!--' + xr_entry.group(0) + '-->' + s[b + xr_entry.end():]))
    cases.append(('whole EBNF section hidden in CDATA',
                  s[:a] + '<![CDATA[' + s[a:b] + ']]>' + s[b:]))
    # D1: delete the alternation bar from rule text (0): same names, other language.
    cases.append(('D1 alternation bar removed from text',
                  mutate(s, 'text', '# | (indicators', '# (indicators')))
    # D2: delete both # markers from text-1 (2).
    cases.append(('D2 free-modifier markers removed from text-1',
                  mutate(s, 'text-1', ' #', '', 2)))
    # E: delete every rule and every table entry, keep the shells.
    a, b = ebnf_span(s)
    sec = re.sub(r'<variablelist>.*?</variablelist>', '', s[a:b], flags=re.S)
    xr = re.sub(r'<variablelist>.*?</variablelist>', '', s[b:], flags=re.S)
    cases.append(('E every rule and entry deleted', s[:a] + sec + xr))
    # Anchors: missing, duplicated, misplaced into the body, mismatched number.
    cases.append(('missing anchor',
                  mutate(s, 'sentence', '<anchor xml:id="b40" />', '')))
    cases.append(('duplicated anchor',
                  mutate(s, 'sentence', '<anchor xml:id="b40" />',
                         '<anchor xml:id="b40" /><anchor xml:id="b40" />')))
    moved = mutate(s, 'sentence', '<anchor xreflabel="BNF rule #40" xml:id="cll_bnf-40" />', '')
    cases.append(('anchor misplaced into the body',
                  mutate(moved, 'sentence', '<para>',
                         '<para><anchor xreflabel="BNF rule #40" xml:id="cll_bnf-40" />')))
    cases.append(('anchor number mismatched',
                  mutate(mutate(s, 'sentence', 'xml:id="b40"', 'xml:id="b4000"'),
                         'sentence', 'xreflabel="BNF rule #40" xml:id="cll_bnf-40"',
                         'xreflabel="BNF rule #4000" xml:id="cll_bnf-4000"')))
    cases.append(('anchor label missing its prefix',
                  mutate(s, 'sentence', 'xreflabel="BNF rule #40"', 'xreflabel="40"')))
    # E2: delete only the table entries, keeping every rule.
    cases.append(('E2 every table entry deleted', s[:b] + xr))
    # A rule printed twice.
    a2, b2 = ebnf_span(s)
    sec2 = s[a2:b2]
    m2 = re.search(r'<varlistentry\b[^>]*>\s*<term>(?:(?!</varlistentry>).)*?\n\s*prenex\n(?:(?!</varlistentry>).)*?</varlistentry>', sec2, re.S)
    cases.append(('a rule printed twice',
                  s[:a2] + sec2[:m2.end()] + m2.group(0).replace('xml:id="b30"', 'xml:id="b3000"')
                  .replace('xreflabel="BNF rule #30" xml:id="cll_bnf-30"', 'xreflabel="BNF rule #30" xml:id="cll_bnf-3000"')
                  + sec2[m2.end():] + s[b2:], 'printed twice'))
    # A silent rewording of a rule body that keeps every name.
    cases.append(('rule body reordered',
                  mutate(s, 'prenex', 'terms ZOhU #', 'ZOhU terms #')))
    # A duplicate xml:id elsewhere in the chapter.
    cases.append(('duplicate xml:id in the chapter',
                  s.replace('xml:id="ebnf-terms"', 'xml:id="ebnf-sumti"', 1)))

    for case in cases:
        label, text = case[0], case[1]
        expect = case[2] if len(case) > 2 else None
        if text == s:
            problems.append(f'{label}: the mutation did not change the text')
            continue
        rc, msg = run(text)
        if rc == 0:
            problems.append(f'{label}: the checker passed a defective chapter')
        elif expect and expect not in msg:
            problems.append(f'{label}: the failure does not mention {expect!r}')

    if problems:
        print('test-check-cross-reference: FAIL')
        for p in problems:
            print('  ' + p)
        return 1
    print(f'test-check-cross-reference: the chapter passes and {len(cases)} planted defects fail')
    return 0


if __name__ == '__main__':
    sys.exit(main())
