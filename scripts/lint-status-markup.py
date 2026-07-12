#!/usr/bin/env python3
"""Validate status markup (docs/status-markup.md) in DocBook chapter files.

Usage:
    lint-status-markup.py chapters/*.xml          # validate; exit 1 on errors
    lint-status-markup.py --list chapters/*.xml   # emit the TSV extraction

Diagnostics always go to stderr. In --list mode stdout carries ONLY the
versioned TSV described in docs/status-markup.md (header line first).

XML-aware: parses each chapter with expat, namespace-aware (comments and
CDATA are handled correctly; start-tags may span lines; single- or
double-quoted attributes; prefixed DocBook-namespace carriers such as
db:para are recognized; foreign-namespace elements are never carriers).
Undefined DTD entities (any XML-Name entity reference) are blanked
length-preservingly before parsing, since only element structure and
attributes matter here.
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

# XML Name grammar (ASCII plus \w's unicode letters): enough to blank any
# entity reference the DTD might define, e.g. &foo-bar; -- but never
# character references (&#...;) or the five predefined entities.
ENTITY_RE = re.compile(r'&(?!amp;|lt;|gt;|quot;|apos;|#)([A-Za-z_:][-.:\w]*);')

CARRIER_OF = {'status-note': 'para', 'status-mark': 'phrase'}
DOCBOOK_NS = 'http://docbook.org/ns/docbook'
XML_NS = 'http://www.w3.org/XML/1998/namespace'

def localname(name):
    """Local name for DocBook or un-namespaced elements; None if foreign."""
    if ' ' in name:
        uri, local = name.rsplit(' ', 1)
        return local if uri == DOCBOOK_NS else None
    return name

def condition_keys(val):
    keys = set()
    for part in val.split(';'):
        if ':' in part:
            keys.add(part.split(':', 1)[0].strip())
    return keys

class Scanner:
    def __init__(self, path, listing, rows, diag):
        self.path, self.listing, self.rows, self.diag = path, listing, rows, diag
        self.errors = self.warnings = 0
        self.id_stack = []   # nearest xml:id per depth (self-or-ancestor)
        self.p = xml.parsers.expat.ParserCreate(namespace_separator=' ')
        self.p.StartElementHandler = self.start
        self.p.EndElementHandler = self.end

    def start(self, name, attrs):
        # anchor contract: nearest ANCESTOR xml:id, captured before this
        # element's own id joins the stack
        ancestor_id = self.id_stack[-1] if self.id_stack else ''
        xid = attrs.get('xml:id') or attrs.get(XML_NS + ' id')
        self.id_stack.append(xid or ancestor_id)
        roles = set(attrs.get('role', '').split())
        cond = attrs.get('condition', '')
        line = self.p.CurrentLineNumber
        status_roles = roles & set(CARRIER_OF)
        local = localname(name)
        if len(status_roles) > 1:
            self.diag(f'{self.path}:{line}: error: conflicting status roles {sorted(status_roles)}')
            self.errors += 1
            return
        if status_roles:
            role = status_roles.pop()
            want = CARRIER_OF[role]
            if local != want:
                shown = local if local is not None else name
                self.diag(f'{self.path}:{line}: error: role {role!r} belongs on '
                          f'<{want}>, found on unsupported element <{shown}>')
                self.errors += 1
                return
            if cond:
                seen, errs = parse_condition(cond)
                for e in errs:
                    self.diag(f'{self.path}:{line}: error: {e} in condition={cond!r}'); self.errors += 1
                if self.listing and not errs:
                    self.rows.append('\t'.join([self.path, local, ancestor_id,
                                                seen.get('status',''), seen.get('also',''),
                                                seen.get('date',''), seen.get('body',''), seen.get('src','')]))
            elif role == 'status-note':
                self.diag(f'{self.path}:{line}: warning: status-note without condition attribute')
                self.warnings += 1
            else:
                self.diag(f'{self.path}:{line}: error: status-mark without condition attribute '
                          '(only status-note has the transitional bare form)')
                self.errors += 1
        elif 'status' in condition_keys(cond):
            shown = local if local is not None else name
            self.diag(f'{self.path}:{line}: error: status condition on non-status element '
                      f'(<{shown}> role={attrs.get("role","")!r})')
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
