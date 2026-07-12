#!/usr/bin/env python3
"""Regression tests for lint-status-markup.py. Exit 1 on any failure."""
import subprocess, tempfile, os, sys

CASES = [  # (name, xml, want_exit, want_in_stderr)
 ('ok-full', '<para role="status-note" condition="status:checkpointed;date:2005-02-11;src:bpfk-quotations">x</para>', 0, None),
 ('ok-also', '<para role="status-note" condition="status:editorial;also:de-facto,historical">x</para>', 0, None),
 ('warn-bare', '<para role="status-note">x</para>', 0, 'warning: status-note without condition'),
 ('bad-status', '<para role="status-note" condition="status:invented">x</para>', 1, 'unknown status'),
 ('bad-month', '<para role="status-note" condition="status:de-facto;date:2005-13-01">x</para>', 1, 'not a real calendar date'),
 ('bad-day', '<para role="status-note" condition="status:de-facto;date:2005-02-30">x</para>', 1, 'not a real calendar date'),
 ('bad-width', '<para role="status-note" condition="status:de-facto;date:2005-2-1">x</para>', 1, 'bad date'),
 ('empty-pair', '<para role="status-note" condition="status:checkpointed;;date:2005-02-11">x</para>', 1, 'empty condition component'),
 ('empty-src', '<para role="status-note" condition="status:de-facto;src:">x</para>', 1, 'empty value'),
 ('bad-src', '<para role="status-note" condition="status:de-facto;src:not a slug">x</para>', 1, 'bad src slug'),
 ('missing-status', '<para role="status-note" condition="date:2005">x</para>', 1, 'missing status'),
 ('dup-key', '<para role="status-note" condition="status:de-facto;status:proposed">x</para>', 1, 'duplicate key'),
 ('nonstatus-el', '<para role="indent" condition="status:de-facto">x</para>', 1, 'status condition on non-status element'),
 ('single-quotes', "<para role='status-note' condition='status:invented'>x</para>", 1, 'unknown status'),
 ('section-cond', '<section role="ordinary" condition="status:checkpointed"><title>t</title><para>x</para></section>', 1, 'non-status element'),
 ('bad-element', '<example role="status-note" condition="status:de-facto"><title>t</title></example>', 1, 'unsupported element'),
 ('comment-immune', '<para>ok</para><!-- <para role="status-note" condition="status:invented">x</para> -->', 0, None),
 ('cdata-immune', '<para><programlisting><![CDATA[<para role="status-note" condition="status:invented">x</para>]]></programlisting></para>', 0, None),
 ('multiline-tag', '<para\n  role="status-note"\n  condition="status:de-facto">x</para>', 0, None),
 ('multi-token-role', '<para role="status-note foo" condition="status:de-facto">x</para>', 0, None),
 ('entity-immune', '<para role="status-note" condition="status:de-facto">a&ndash;b</para>', 0, None),
 ('phrase-ok', '<phrase role="status-mark" condition="status:de-facto">x</phrase>', 0, None),
 ('entity-xml-name', '<para role="status-note" condition="status:de-facto">a&foo-bar;b</para>', 0, None),
 ('ns-carrier-ok', '<db:para xmlns:db="http://docbook.org/ns/docbook" role="status-note" condition="status:de-facto">x</db:para>', 0, None),
 ('ns-foreign-not-carrier', '<f:para xmlns:f="http://example.org/foreign" role="status-note" condition="status:de-facto">x</f:para>', 1, 'unsupported element'),
 ('cond-key-spaced', '<para role="indent" condition="status : checkpointed">x</para>', 1, 'non-status element'),
 ('cond-key-other', '<para role="indent" condition="xstatus:checkpointed">x</para>', 0, None),
 ('crossed-para-mark', '<para role="status-mark" condition="status:de-facto">x</para>', 1, 'belongs on <phrase>'),
 ('crossed-phrase-note', '<phrase role="status-note" condition="status:de-facto">x</phrase>', 1, 'belongs on <para>'),
 ('bare-mark', '<phrase role="status-mark">x</phrase>', 1, 'status-mark without condition'),
 ('both-roles', '<para role="status-note status-mark" condition="status:de-facto">x</para>', 1, 'conflicting status roles'),
]

def main():
    d = tempfile.mkdtemp()
    lint = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'lint-status-markup.py')
    failures = 0
    for name, xml, want_exit, want_msg in CASES:
        p = os.path.join(d, name + '.xml')
        open(p, 'w').write(f'<chapter>{xml}</chapter>')
        r = subprocess.run([sys.executable, lint, p], capture_output=True, text=True)
        ok = (r.returncode == want_exit) and (want_msg is None or want_msg in r.stderr) and (r.stdout == '')
        if not ok:
            failures += 1
            print(f'FAIL {name}: exit={r.returncode} (want {want_exit}) stderr={r.stderr.strip()[:120]!r} stdout={r.stdout[:60]!r}')
    # --list contract: TSV only on stdout, exact schema-v1 header, complete
    # exact rows, nearest-ANCESTOR anchor even when the element has its own id
    p = os.path.join(d, 'list.xml')
    open(p, 'w').write(
        '<chapter xml:id="chapter-x"><section xml:id="section-y">'
        '<para xml:id="para-z" role="status-note" '
        'condition="status:checkpointed;also:de-facto;date:2005-02-11;body:bpfk;src:bpfk-quotations">x</para>'
        '<para role="status-note" condition="status:editorial">y</para>'
        '<para role="status-note">bare</para></section></chapter>')
    r = subprocess.run([sys.executable, lint, '--list', p], capture_output=True, text=True)
    lines = r.stdout.splitlines()
    want_header = 'file\telement\tanchor\tstatus\talso\tdate\tbody\tsrc'
    want_rows = [
        f'{p}\tpara\tsection-y\tcheckpointed\tde-facto\t2005-02-11\tbpfk\tbpfk-quotations',
        f'{p}\tpara\tsection-y\teditorial\t\t\t\t',
    ]
    if not (r.returncode == 0 and lines == [want_header] + want_rows
            and 'warning' in r.stderr):
        failures += 1
        print(f'FAIL list-contract: {r.stdout!r} / {r.stderr[:120]!r}')
    print(f'{len(CASES)+1 - failures}/{len(CASES)+1} tests passed')
    return 1 if failures else 0

if __name__ == '__main__':
    sys.exit(main())
