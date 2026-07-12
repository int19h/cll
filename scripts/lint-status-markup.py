#!/usr/bin/env python3
"""Validate status markup (docs/status-markup.md) in DocBook chapter files.

Usage:
    lint-status-markup.py chapters/*.xml          # validate; exit 1 on errors
    lint-status-markup.py --list chapters/*.xml   # emit the TSV extraction

Diagnostics always go to stderr. In --list mode stdout carries ONLY the
versioned TSV described in docs/status-markup.md (header line first).

XML-aware: parses each chapter with expat (comments and CDATA are handled
correctly; start-tags may span lines; single- or double-quoted attributes).
Undefined DTD entities are blanked (length-preserving) before parsing, since
only element structure and attributes matter here.
"""
import re, sys, datetime
import xml.parsers.expat

AUTHORITY = {'llg-ratified','bpfk-approved','checkpointed','de-facto','proposed','unsettled'}
NOTE_KINDS = {'editorial','historical'}
STATUS_TOKENS = AUTHORITY | NOTE_KINDS
KEYS = {'status','also','date','body','src'}
BODIES = {'llg','bpfk','community'}
DATE_RE = re.compile(r'^(\d{4})(?:-(\d{2})(?:-(\d{2}))?)?$')
SLUG_RE = re.compile(r'^[a-z0-9][a-z0-9-]*$')
STATUS_ELEMENTS = {'para', 'phrase'}
TSV_HEADER = 'file\telement\tanchor\tstatus\talso\tdate\tbody\tsrc'

def check_date(v):
    m = DATE_RE.match(v)
    if not m: return f'bad date {v!r} (want YYYY[-MM[-DD]])'
    y, mo, d = m.group(1), m.group(2), m.group(3)
    try:
        datetime.date(int(y), int(mo or 1), int(d or 1))
        if mo and not (1 <= int(mo) <= 12): raise ValueError
    except ValueError:
        return f'bad date {v!r} (not a real calendar date)'
    return None

def parse_condition(val):
    seen, errs = {}, []
    for part in val.split(';'):
        part = part.strip()
        if not part:
            errs.append('empty condition component'); continue
        if ':' not in part:
            errs.append(f'bad pair {part!r}'); continue
        k, v = (x.strip() for x in part.split(':', 1))
        if k not in KEYS: errs.append(f'unknown key {k!r}'); continue
        if k in seen: errs.append(f'duplicate key {k!r}'); continue
        if not v: errs.append(f'empty value for {k!r}'); continue
        seen[k] = v
        if k == 'status' and v not in STATUS_TOKENS: errs.append(f'unknown status {v!r}')
        if k == 'also':
            for tok in v.split(','):
                if tok.strip() not in STATUS_TOKENS: errs.append(f'unknown also-token {tok.strip()!r}')
        if k == 'date':
            e = check_date(v)
            if e: errs.append(e)
        if k == 'body' and v not in BODIES: errs.append(f'unknown body {v!r}')
        if k == 'src' and not SLUG_RE.match(v): errs.append(f'bad src slug {v!r}')
    if 'status' not in seen: errs.append('missing status: pair')
    return seen, errs

ENTITY_RE = re.compile(r'&(?!amp;|lt;|gt;|quot;|apos;|#)(\w+);')

class Scanner:
    def __init__(self, path, listing, rows, diag):
        self.path, self.listing, self.rows, self.diag = path, listing, rows, diag
        self.errors = self.warnings = 0
        self.id_stack = []   # nearest ancestor xml:id per depth
        self.p = xml.parsers.expat.ParserCreate()
        self.p.StartElementHandler = self.start
        self.p.EndElementHandler = self.end

    def start(self, name, attrs):
        xid = attrs.get('xml:id')
        self.id_stack.append(xid or (self.id_stack[-1] if self.id_stack else ''))
        roles = set(attrs.get('role', '').split())
        cond = attrs.get('condition', '')
        line = self.p.CurrentLineNumber
        is_status = bool(roles & {'status-note', 'status-mark'})
        local = name.split('}')[-1]
        if is_status and local not in STATUS_ELEMENTS:
            self.diag(f'{self.path}:{line}: error: status role on unsupported element <{local}>')
            self.errors += 1
            return
        if is_status and cond:
            seen, errs = parse_condition(cond)
            for e in errs:
                self.diag(f'{self.path}:{line}: error: {e} in condition={cond!r}'); self.errors += 1
            if self.listing and not errs:
                self.rows.append('\t'.join([self.path, local, self.id_stack[-1],
                                            seen.get('status',''), seen.get('also',''),
                                            seen.get('date',''), seen.get('body',''), seen.get('src','')]))
        elif is_status:
            self.diag(f'{self.path}:{line}: warning: status element without condition attribute')
            self.warnings += 1
        elif 'status:' in cond:
            self.diag(f'{self.path}:{line}: error: status condition on non-status element '
                      f'(<{local}> role={attrs.get("role","")!r})')
            self.errors += 1

    def end(self, name):
        if self.id_stack: self.id_stack.pop()

    def run(self):
        text = open(self.path, encoding='utf-8').read()
        text = ENTITY_RE.sub(lambda m: ' ' * (len(m.group(0))), text)
        try:
            self.p.Parse(text, True)
        except xml.parsers.expat.ExpatError as e:
            self.diag(f'{self.path}: error: XML parse failed: {e}')
            self.errors += 1

def main(argv):
    listing = '--list' in argv
    files = [a for a in argv if not a.startswith('--')]
    rows, errors, warnings = [], 0, 0
    diag = lambda msg: print(msg, file=sys.stderr)
    for path in files:
        sc = Scanner(path, listing, rows, diag)
        sc.run()
        errors += sc.errors; warnings += sc.warnings
    if listing:
        print(TSV_HEADER)
        for r in rows: print(r)
    diag(f'{errors} errors, {warnings} warnings (warnings are report-only)')
    return 1 if errors else 0

if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
