#!/usr/bin/env python3
"""Validate status markup (docs/status-markup.md) in DocBook chapter files.

Usage: lint-status-markup.py [--list] chapters/*.xml
Exit 1 on errors; warnings (missing condition) are report-only.
"""
import re, sys

STATUS_TOKENS = {'llg-ratified','bpfk-approved','checkpointed','de-facto',
                 'proposed','unsettled','editorial','historical'}
KEYS = {'status','date','body','src'}
BODIES = {'llg','bpfk','community'}
DATE_RE = re.compile(r'^\d{4}(-\d{2}(-\d{2})?)?$')
TAG_RE = re.compile(r'<(para|phrase)\b[^>]*>', re.S)
ATTR_RE = re.compile(r'(\w+)\s*=\s*"([^"]*)"')

def parse_condition(val):
    seen, errs = {}, []
    for part in filter(None, (p.strip() for p in val.split(';'))):
        if ':' not in part:
            errs.append(f'bad pair {part!r}'); continue
        k, v = part.split(':', 1)
        if k not in KEYS: errs.append(f'unknown key {k!r}'); continue
        if k in seen: errs.append(f'duplicate key {k!r}'); continue
        seen[k] = v
        if k == 'status' and v not in STATUS_TOKENS: errs.append(f'unknown status {v!r}')
        if k == 'date' and not DATE_RE.match(v): errs.append(f'bad date {v!r}')
        if k == 'body' and v not in BODIES: errs.append(f'unknown body {v!r}')
    if 'status' not in seen: errs.append('missing status: pair')
    return seen, errs

def main(argv):
    listing = '--list' in argv
    files = [a for a in argv if not a.startswith('--')]
    errors = warnings = 0
    for path in files:
        text = open(path, encoding='utf-8').read()
        for m in TAG_RE.finditer(text):
            attrs = dict(ATTR_RE.findall(m.group(0)))
            roles = set(attrs.get('role', '').split())
            cond = attrs.get('condition', '')
            line = text.count('\n', 0, m.start()) + 1
            is_status = bool(roles & {'status-note', 'status-mark'})
            if is_status and cond:
                seen, errs = parse_condition(cond)
                for e in errs:
                    print(f'{path}:{line}: error: {e} in condition={cond!r}'); errors += 1
                if listing and not errs:
                    print('\t'.join([path, str(line), seen.get('status',''),
                                     seen.get('date',''), seen.get('body',''), seen.get('src','')]))
            elif is_status:
                print(f'{path}:{line}: warning: status element without condition attribute')
                warnings += 1
            elif 'status:' in cond:
                print(f'{path}:{line}: error: status condition on non-status element (role={attrs.get("role","")!r})')
                errors += 1
    if not listing:
        print(f'{errors} errors, {warnings} warnings (warnings are report-only)')
    return 1 if errors else 0

if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
