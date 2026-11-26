#!/usr/bin/env python3
"""Lint role="parallel-text" usage on Appendix A informaltables (issue #348).

Usage:
    lint-parallel-text.py chapters/*.xml

Checks:
1. Inside the chrestomathy appendix (<appendix xml:id="volume-chrestomathy">),
   every <informaltable> not inside an <example> must carry the "parallel-text"
   token in its @role attribute so print CSS allows multi-page breaks on it.
2. Outside that appendix, or on any element other than <informaltable>, the
   "parallel-text" role token is rejected because the print CSS rule is scoped
   to section#volume-chrestomathy div.parallel-text.informaltable.
"""
import html.entities
import re
import sys
import xml.parsers.expat

ENTITY_DECL_RE = re.compile(r'<!ENTITY\s+([A-Za-z_:][-.:\w]*)\s')
ENTITY_RE = re.compile(r'&(?!amp;|lt;|gt;|quot;|apos;|#)([A-Za-z_:][-.:\w]*);')
# Exact XPath 1.0 normalize-space() / XML 1.0 S whitespace (excludes U+00A0).
XML_WS_RE = re.compile(r'[ \t\r\n]+')
DOCBOOK_NS = 'http://docbook.org/ns/docbook'
XML_NS = 'http://www.w3.org/XML/1998/namespace'
CHRESTOMATHY_ID = 'volume-chrestomathy'
PARALLEL_ROLE = 'parallel-text'


def split_xml_tokens(value):
    """Split an XML attribute token list on XML whitespace only (like XPath normalize-space)."""
    return [tok for tok in XML_WS_RE.split(value) if tok]


def resolve_undeclared_entities(text):
    """Replace undeclared named entities without ever inventing ASCII whitespace."""
    declared = set(ENTITY_DECL_RE.findall(text))

    def repl(match):
        name = match.group(1)
        if name in declared:
            return match.group(0)
        cp = html.entities.name2codepoint.get(name)
        if cp is not None:
            ch = chr(cp)
            if ch not in (' ', '\t', '\r', '\n', '<', '>', '&', '"', "'"):
                return ch
        return '_'

    return ENTITY_RE.sub(repl, text)


def localname(name):
    if ' ' in name:
        uri, local = name.rsplit(' ', 1)
        return local if uri == DOCBOOK_NS else None
    return name


class Scanner:
    def __init__(self, path, diag):
        self.path = path
        self.diag = diag
        self.errors = 0
        self.in_chrestomathy = 0
        self.in_example = 0
        self.stack = []
        self.p = xml.parsers.expat.ParserCreate(namespace_separator=' ')
        self.p.StartElementHandler = self.start
        self.p.EndElementHandler = self.end

    def start(self, name, attrs):
        local = localname(name)
        xid = attrs.get('xml:id') or attrs.get(XML_NS + ' id') or attrs.get('id')
        entered_chrest = (local == 'appendix' and xid == CHRESTOMATHY_ID)
        entered_example = (local == 'example')
        if entered_chrest:
            self.in_chrestomathy += 1
        if entered_example:
            self.in_example += 1
        self.stack.append((entered_chrest, entered_example))

        roles = set(split_xml_tokens(attrs.get('role', '')))
        line = self.p.CurrentLineNumber

        if PARALLEL_ROLE in roles:
            if local != 'informaltable':
                shown = local if local is not None else name
                self.diag(
                    f'{self.path}:{line}: error: role {PARALLEL_ROLE!r} belongs on '
                    f'<informaltable>, found on <{shown}>'
                )
                self.errors += 1
            elif self.in_chrestomathy == 0:
                self.diag(
                    f'{self.path}:{line}: error: role {PARALLEL_ROLE!r} is only '
                    f'effective inside <appendix xml:id="{CHRESTOMATHY_ID}">'
                )
                self.errors += 1
        elif local == 'informaltable' and self.in_chrestomathy > 0 and self.in_example == 0:
            self.diag(
                f'{self.path}:{line}: error: <informaltable> in Appendix A outside '
                f'<example> must carry role="{PARALLEL_ROLE}" '
                f'(put other tables inside <example> or use <table>)'
            )
            self.errors += 1

    def end(self, name):
        if self.stack:
            entered_chrest, entered_example = self.stack.pop()
            if entered_chrest:
                self.in_chrestomathy -= 1
            if entered_example:
                self.in_example -= 1

    def run(self):
        with open(self.path, encoding='utf-8') as fh:
            text = fh.read()
        text = resolve_undeclared_entities(text)
        try:
            self.p.Parse(text, True)
        except xml.parsers.expat.ExpatError as e:
            self.diag(f'{self.path}: error: XML parse failed: {e}')
            self.errors += 1


def main(argv):
    files = [a for a in argv if not a.startswith('--')]
    errors = 0
    diag = lambda msg: print(msg, file=sys.stderr)
    for path in files:
        sc = Scanner(path, diag)
        sc.run()
        errors += sc.errors
    diag(f'{errors} errors')
    return 1 if errors else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
