#!/usr/bin/env python3
"""DocBook-level visual diff of the book (issue #127).

    docbook-diff.py [--repo DIR] [--stats FILE] OLD NEW OUT_TREE
    docbook-diff.py finish BUILT_INDEX OUT_DIR --old-label X --new-label Y
                    [--assets PREFIX] [--stats FILE]

OLD and NEW each name a source tree: a directory (a checkout) or a git
revision of the repository given by --repo (default: the current
directory). OUT_TREE must already hold a copy of the NEW source tree; its
chapters/*.xml are overwritten with annotated copies, and a chapter that
exists only in OLD is written there too, so the normal build renders the
whole NEW book with the changes marked through DocBook revisionflag:

  * a changed block: inserted words wrapped in <phrase revisionflag="added">,
    removed words re-inserted as <phrase revisionflag="deleted">;
  * an added block: revisionflag="added" on the largest element that holds
    only added material;
  * a deleted block: re-inserted at its old position, with
    revisionflag="deleted", stripped of ids and of links to ids that no
    longer exist;
  * a moved block: left unmarked at its new place; its old place gets a
    short note (revisionflag="changed") with an xref to the new place.

Blocks (paragraphs, example rows, table rows, list entries, titles...) are
linearized book-wide with their text normalized, aligned with difflib, and
paired inside replaced regions by similarity; deleted and inserted blocks
are then aligned against each other to find moves. Changed blocks are
diffed word by word on their own inline markup.

Rules the build pipeline imposes (see issue #127):
  * never flag jbo/gloss rows, tr/td, row/entry, titles: their flags are
    lost; mark their content with phrases instead, one phrase per word in
    interlinear rows so that the word-by-word cells stay aligned;
  * deleted material must lose its xml:ids, and its links to vanished ids;
  * revisionflag takes exactly added|deleted|changed|off.

The finish step turns the built page into the published difference.html
(with a banner explaining the marks) and difference_prefixed.html (the same
with a searchable text marker at each change); it also marks each changed
section's number in the table of contents and collapses fully added or
deleted table rows into one marked row. Per-section block counts for the
table of contents travel in the stats file under "sections"; see finish().

Standard library only.
"""
import argparse
import copy
import difflib
import json
import re
import subprocess
import sys
import time
import xml.etree.ElementTree as ET
from html.parser import HTMLParser
from pathlib import Path

XML_ID = '{http://www.w3.org/XML/1998/namespace}id'
XLINK_NS = 'http://www.w3.org/1999/xlink'
MML_NS = 'http://www.w3.org/1998/Math/MathML'
ET.register_namespace('xlink', XLINK_NS)
PREDEFINED = {'amp', 'lt', 'gt', 'quot', 'apos'}

# ---------------------------------------------------------------- element classes

# Block-level units of the alignment (as in the research prototype).
BLOCK = {
    'para', 'simpara', 'title', 'bridgehead', 'term', 'programlisting',
    'literallayout', 'screen', 'caption', 'attribution', 'footnote',
    'jbo', 'gloss', 'natlang', 'ipa', 'comment', 'sumti', 'selbri', 'score',
    'cmavo-entry', 'cmavo-list-head', 'member', 'rafsi-group',
    'lujvo-making', 'grammar-template', 'lojbanization', 'compound-cmavo',
    'pseudo-cmavo', 'series', 'definition', 'content',
    'tr', 'row', 'dbmath', 'mmlmath', 'textobject',
}
SECTIONISH = {'chapter', 'article', 'appendix', 'section', 'preface',
              'sect1', 'sect2', 'sect3', 'simplesect'}
VERBATIM = {'programlisting', 'literallayout', 'screen'}
SKIP = {'indexterm', 'anchor', 'imagedata', 'colgroup', 'col'}
CELL = {'td', 'th', 'entry'}
# Inline elements diffed as one token (never descended into): their text is
# used by the build, they have no text, or their destination is meaningful.
ATOM = {'xref', 'link', 'valsi', 'glossterm', 'footnoteref', 'inlinemediaobject',
        'mmlinlinemath', 'inlineequation', 'imageobject'}
# Structural elements whose own text is only indentation: no phrase may be
# put directly in them.
STRUCT = {'tr', 'row', 'thead', 'tbody', 'tfoot', 'tgroup', 'table',
          'informaltable', 'cmavo-entry', 'cmavo-list-head', 'cmavo-list',
          'interlinear-gloss', 'interlinear-gloss-itemized', 'simplelist',
          'itemizedlist', 'orderedlist', 'variablelist', 'varlistentry',
          'listitem', 'lujvo-making', 'pronunciation', 'compound-cmavo',
          'lojbanization', 'example', 'informalexample', 'blockquote',
          'mediaobject', 'textobject', 'imageobject', 'footnote', 'note',
          'rafsi-group', 'figure', 'informalfigure', 'equation',
          'informalequation'} | SECTIONISH
# Elements on which revisionflag survives xml_preprocess.rb and is rendered
# by the driver stylesheet (as a div or a span). Anything else is marked by
# recursing into it.
FLAGGABLE = {
    # blocks
    'para', 'simpara', 'section', 'chapter', 'article', 'appendix', 'preface',
    'example', 'informalexample', 'itemizedlist', 'orderedlist',
    'variablelist', 'varlistentry', 'blockquote', 'table', 'informaltable',
    'interlinear-gloss', 'interlinear-gloss-itemized', 'lujvo-making',
    'cmavo-list', 'pronunciation', 'compound-cmavo', 'lojbanization',
    'programlisting', 'literallayout', 'screen', 'bridgehead', 'mediaobject',
    'note', 'natlang', 'ipa', 'dbmath', 'grammar-template', 'definition',
    'simplelist',
    # inlines
    'member', 'phrase', 'emphasis', 'quote', 'foreignphrase', 'jbophrase',
    'valsi', 'cmevla', 'letteral', 'diphthong', 'morphology', 'veljvo',
    'citetitle', 'subscript', 'superscript', 'xref', 'link', 'glossterm',
    'filename', 'literal', 'dbinlinemath', 'comment', 'rafsi',
}
# cmavo-entry / itemized-row children become para (flaggable) in place.
ROWCHILD_FLAGGABLE = {'cmavo', 'gismu', 'selmaho', 'series', 'rafsi',
                      'compound', 'modal-place', 'attitudinal-scale',
                      'pseudo-cmavo', 'description', 'sumti', 'selbri',
                      'elidable', 'td', 'rafsi-group'}
ROWCHILD_PARENTS = {'cmavo-entry', 'jbo', 'gloss'}
# Elements that may occur only once in their parent: never duplicated.
SINGLETON = {'title', 'term', 'caption', 'attribution', 'info', 'content',
             'textobject', 'score', 'cmavo-list-head', 'thead', 'tfoot'}
# Parents that accept a note paragraph.
PARA_OK = {'section', 'chapter', 'article', 'appendix', 'preface', 'sect1',
           'sect2', 'sect3', 'simplesect', 'listitem', 'entry', 'td', 'th',
           'blockquote', 'example', 'footnote', 'note', 'interlinear-gloss',
           'sidebar', 'glossdef'}
NOTE_TARGETS = SECTIONISH | {'example', 'table'}
DUPLICABLE = {'para', 'simpara', 'natlang', 'jbo', 'gloss', 'member',
              'cmavo-entry', 'row', 'tr', 'programlisting', 'literallayout',
              'screen', 'ipa', 'bridgehead', 'lojbanization', 'lujvo-making',
              'grammar-template', 'definition', 'dbmath'}
NBSP = ' '


def local(tag):
    return tag.split('}', 1)[1] if isinstance(tag, str) and '}' in tag else tag


def is_el(e):
    return isinstance(e.tag, str)


def ws(s):
    return re.sub(r'\s+', ' ', s or '').strip()


# ---------------------------------------------------------------- source trees

class Source:
    """A source tree: a directory or a git revision."""

    def __init__(self, spec, repo):
        self.spec = spec
        p = Path(spec)
        if p.is_dir():
            self.dir, self.rev = p, None
        else:
            self.dir, self.rev = None, spec
            self.repo = repo
            subprocess.run(['git', '-C', str(repo), 'rev-parse', '--verify', '-q',
                            spec + '^{commit}'], check=True, capture_output=True)

    def files(self, pattern_dir, suffixes):
        if self.dir:
            d = self.dir / pattern_dir
            return sorted(f.name for f in d.iterdir()
                          if f.is_file() and f.suffix in suffixes) if d.is_dir() else []
        out = subprocess.run(['git', '-C', str(self.repo), 'ls-tree', '--name-only',
                              self.rev, pattern_dir + '/'], check=True,
                             capture_output=True).stdout.decode().split()
        return sorted(Path(n).name for n in out if Path(n).suffix in suffixes)

    def read(self, path):
        if self.dir:
            return (self.dir / path).read_text(encoding='utf-8', errors='replace')
        return subprocess.run(['git', '-C', str(self.repo), 'show',
                               '%s:%s' % (self.rev, path)], check=True,
                              capture_output=True).stdout.decode('utf-8', errors='replace')


def entity_map(sources):
    m = {}
    for src in sources:
        for d in ('dtd', 'xml'):
            for name in src.files(d, {'.ent'}):
                text = src.read('%s/%s' % (d, name))
                for n, v in re.findall(r'<!ENTITY\s+([A-Za-z][\w.-]*)\s+"([^"]*)"', text):
                    v = re.sub(r'&#x([0-9a-fA-F]+);', lambda mm: chr(int(mm.group(1), 16)), v)
                    v = re.sub(r'&#(\d+);', lambda mm: chr(int(mm.group(1))), v)
                    m.setdefault(n, v)
    return m


def resolve(text, ents):
    def sub(mm):
        n = mm.group(1)
        if n in PREDEFINED:
            return mm.group(0)
        if n in ents:
            return ents[n].replace('&', '&amp;').replace('<', '&lt;')
        raise KeyError('unresolved entity &%s;' % n)
    return re.sub(r'&(?!#)([A-Za-z][\w.-]*);', sub, text)


def parse(text, ents):
    # chapters rely on the book element's xlink declaration
    # (and old sources use an undeclared mml: prefix for MathML)
    m = re.search(r'<(?![?!])[^>]*>', text)
    for prefix, uri in (('xlink', XLINK_NS), ('mml', MML_NS)):
        if m and prefix + ':' in text and 'xmlns:' + prefix not in m.group():
            text = text[:m.start()] + re.sub(r'^(<[^\s/>]+)', r'\1 xmlns:%s="%s"' % (prefix, uri),
                                             m.group()) + text[m.end():]
            m = re.search(r'<(?![?!])[^>]*>', text)
    parser = ET.XMLParser(target=ET.TreeBuilder(insert_comments=True, insert_pis=True))
    parser.feed(resolve(text, ents))
    return parser.close()


# ---------------------------------------------------------------- linearization

class Block:
    __slots__ = ('key', 'file', 'tag', 'text', 'el', 'path', 'status', 'partner', 'seq')

    def __init__(self, file, tag, text, el, path):
        self.file, self.tag, self.text, self.el, self.path = file, tag, text, el, path
        self.status, self.partner, self.seq = None, None, 0


def link_target(el):
    if el.get('linkend') is not None:
        return 'internal', el.get('linkend')
    href = el.get('{%s}href' % XLINK_NS)
    if href is None:
        return 'none', ''
    if href.startswith('#'):
        return 'internal', href[1:]
    return 'external', href


def reference_text(el):
    """Reference attributes that supply an empty inline element's label."""
    parts = [local(el.tag)]
    for attr in ('linkend', 'endterm', 'otherterm'):
        if el.get(attr) is not None:
            parts.append('%s:\x01%s\x02' % (attr, el.get(attr)))
    for attr in ('xrefstyle', 'xreflabel', 'label'):
        if el.get(attr) is not None:
            parts.append('%s:%s' % (attr, el.get(attr)))
    return ' '.join(parts)


def inline_key(text, idkey):
    return ws(re.sub('\x01([^\x02]*)\x02', lambda m: idkey(m.group(1)), text))


def inline_text(el, out, nested):
    if el.text:
        out.append(el.text)
    for ch in el:
        t = local(ch.tag)
        if not is_el(ch) or t in SKIP:
            pass
        elif t in BLOCK:
            nested.append(ch)
            out.append(' ')
        elif t in ('xref', 'footnoteref'):
            out.append(' ' + reference_text(ch) + ' ')
        elif t == 'link':
            inline_text(ch, out, nested)
            kind, target = link_target(ch)
            if kind == 'internal':
                out.append(' link-internal:\x01%s\x02 ' % target)
            else:
                out.append(' link-%s:%s ' % (kind, target))
        elif t == 'quote':
            out.append('“')
            inline_text(ch, out, nested)
            out.append('”')
        elif t in CELL:
            out.append(' | ')
            inline_text(ch, out, nested)
        else:
            inline_text(ch, out, nested)
        if ch.tail:
            out.append(ch.tail)


class Book:
    def __init__(self, src, ents):
        self.src = src
        self.files = []            # (name, root)
        self.blocks = []
        self.groups = {}           # id -> alias set
        self.ids = {}              # id -> element
        self.parent = {}
        names = src.files('chapters', {'.xml'})
        for name in names:
            root = parse(src.read('chapters/' + name), ents)
            self.files.append((name, root))
            for p in root.iter():
                for c in p:
                    self.parent[c] = p
            self.collect_ids(root)
            self.linearize(name, root)
        for i, b in enumerate(self.blocks):
            b.seq = i

    def collect_ids(self, root):
        for el in root.iter():
            if not is_el(el):
                continue
            i = el.get(XML_ID)
            if not i:
                continue
            self.ids[i] = el
            if local(el.tag) == 'anchor':
                self.groups.setdefault(i, set()).add(i)
                continue
            g = {i}
            for sub in [el] + [c for c in el if is_el(c) and local(c.tag) == 'title']:
                for a in sub:
                    if is_el(a) and local(a.tag) == 'anchor' and a.get(XML_ID):
                        g.add(a.get(XML_ID))
            for x in g:
                self.groups.setdefault(x, set()).update(g)

    def linearize(self, name, root):
        def walk(el, path):
            if not is_el(el):
                return
            t = local(el.tag)
            if t in SKIP:
                return
            if t in SECTIONISH:
                title = el.find('title')
                tt = ''
                if title is not None:
                    o = []
                    inline_text(title, o, [])
                    tt = ws(''.join(o))
                path = path + (tt,)
            direct = (el.text or '').strip() or any((c.tail or '').strip() for c in el)
            if t in BLOCK or (direct and t not in SECTIONISH):
                out, nested = [], []
                inline_text(el, out, nested)
                text = ''.join(out) if t in VERBATIM else ws(''.join(out))
                if t in VERBATIM:
                    text = '\n'.join(' '.join(l.split()) for l in text.splitlines() if l.strip())
                if text:
                    self.blocks.append(Block(name, t, text, el, path))
                for n in nested:
                    walk(n, path)
                return
            for ch in el:
                walk(ch, path)
        walk(root, ())

    def depth(self, el):
        d = 0
        while el in self.parent:
            el = self.parent[el]
            d += 1
        return d

    def up(self, el, k):
        for _ in range(k):
            el = self.parent.get(el)
            if el is None:
                return None
        return el


PUNCT_BEFORE = re.compile(r'\s+(?=[,.;:!?)\]”»])')
PUNCT_AFTER = re.compile(r'(?<=[(\[“«])\s+')


def finalize(old, new):
    common = set(old.groups) & set(new.groups)

    def rep(groups):
        cache = {}

        def f(m):
            i = m.group(1)
            if i not in cache:
                c = sorted(groups.get(i, {i}) & common)
                cache[i] = '\x01' + (c[0] if c else i) + '\x02'
            return cache[i]
        return f
    for book in (old, new):
        r = rep(book.groups)
        for b in book.blocks:
            t = re.sub('\x01([^\x02]*)\x02', r, b.text)
            t = PUNCT_AFTER.sub('', PUNCT_BEFORE.sub('', t))
            b.text = t
            b.key = re.sub(r'\s*([^\w\s])\s*', r'\1', t)
    return rep


# ---------------------------------------------------------------- block alignment

def sim(a, b):
    sm = difflib.SequenceMatcher(None, a, b, autojunk=False)
    if sm.real_quick_ratio() < 0.4 or sm.quick_ratio() < 0.4:
        return 0.0
    return sm.ratio()


def pair_region(olds, news, thresh=0.5):
    n, m = len(olds), len(news)
    if n * m > 4000:
        return [(i, i) for i in range(min(n, m)) if sim(olds[i].text, news[i].text) >= thresh]
    S = [[sim(olds[i].text, news[j].text) for j in range(m)] for i in range(n)]
    D = [[0.0] * (m + 1) for _ in range(n + 1)]
    for i in range(n - 1, -1, -1):
        for j in range(m - 1, -1, -1):
            best = max(D[i + 1][j], D[i][j + 1])
            if S[i][j] >= thresh:
                best = max(best, S[i][j] + D[i + 1][j + 1])
            D[i][j] = best
    pairs, i, j = [], 0, 0
    while i < n and j < m:
        if S[i][j] >= thresh and D[i][j] == S[i][j] + D[i + 1][j + 1]:
            pairs.append((i, j))
            i += 1
            j += 1
        elif D[i][j] == D[i + 1][j]:
            i += 1
        else:
            j += 1
    return pairs


def link(a, b, status):
    a.status, b.status = status, status
    a.partner, b.partner = b, a


def align(old, new):
    """Set .status on every block: eq/chg (in place), move/movechg (moved),
    del (old only), ins (new only)."""
    ids = {}
    ka = [ids.setdefault(b.key, len(ids)) for b in old.blocks]
    kb = [ids.setdefault(b.key, len(ids)) for b in new.blocks]
    sm = difflib.SequenceMatcher(None, ka, kb, autojunk=False)
    for op, i1, i2, j1, j2 in sm.get_opcodes():
        if op == 'equal':
            for k in range(i2 - i1):
                link(old.blocks[i1 + k], new.blocks[j1 + k], 'eq')
            continue
        olds, news = old.blocks[i1:i2], new.blocks[j1:j2]
        pairs = pair_region(olds, news) if olds and news else []
        for x, y in pairs:
            link(olds[x], news[y], 'chg')
        for b in olds:
            b.status = b.status or 'del'
        for b in news:
            b.status = b.status or 'ins'
    # moves: align the deleted blocks against the inserted ones
    dels = [b for b in old.blocks if b.status == 'del']
    inss = [b for b in new.blocks if b.status == 'ins']
    dk = [ids.setdefault(b.key, len(ids)) for b in dels]
    ik = [ids.setdefault(b.key, len(ids)) for b in inss]
    msm = difflib.SequenceMatcher(None, dk, ik, autojunk=False)
    mops = msm.get_opcodes()
    for n, (op, a1, a2, b1, b2) in enumerate(mops):
        if op == 'equal':
            size = sum(len(dels[k].text) for k in range(a1, a2))
            if a2 - a1 >= 3 or size >= 40:
                for k in range(a2 - a1):
                    link(dels[a1 + k], inss[b1 + k], 'move')
        elif (op == 'replace' and 0 < n < len(mops) - 1
              and mops[n - 1][0] == 'equal' and mops[n + 1][0] == 'equal'):
            for x, y in pair_region(dels[a1:a2], inss[b1:b2], 0.6):
                link(dels[a1 + x], inss[b1 + y], 'movechg')


# ---------------------------------------------------------------- per-element summaries

class Summary:
    """Block statuses below each element of a book (the element's own block
    included)."""

    def __init__(self, book):
        self.book = book
        self.counts = {}           # element -> {status: n}
        self.own = {}              # element -> its own block
        self.lists = {}
        for b in book.blocks:
            self.own.setdefault(b.el, b)
            el = b.el
            while el is not None:
                c = self.counts.setdefault(el, {})
                c[b.status] = c.get(b.status, 0) + 1
                self.lists.setdefault(el, []).append(b)
                el = book.parent.get(el)

    def get(self, el):
        return self.counts.get(el, {})

    def blocks_under(self, el):
        return self.lists.get(el, [])


SURV = ('eq', 'chg')
MOVED = ('move', 'movechg')


# ---------------------------------------------------------------- word-level engine

TOK = re.compile(r"\s+|\.?[\w'’]+(?:-[\w'’]+)*|[^\w\s]", re.UNICODE)
WORDTOK = re.compile(r'\s+|\S+')


class Seg:
    __slots__ = ('owner', 'slot', 'writable', 'row')

    def __init__(self, owner, slot, writable, row):
        self.owner, self.slot, self.writable, self.row = owner, slot, writable, row

    def get(self):
        return (self.owner.text if self.slot == 'text' else self.owner.tail) or ''


class Tok:
    __slots__ = ('kind', 'seg', 'start', 'end', 's', 'key', 'el', 'prev_seg', 'next_seg')


def is_row(el, parent):
    return local(el.tag) in ('jbo', 'gloss') and parent is not None and \
        local(parent.tag) == 'interlinear-gloss'


def writable(el, parent=None):
    t = local(el.tag)
    if t in ('jbo', 'gloss') and parent is not None and \
            local(parent.tag) == 'interlinear-gloss-itemized':
        return False
    if t not in STRUCT:
        return True
    return bool((el.text or '').strip() or any((c.tail or '').strip() for c in el))


class Flat:
    """The token stream of one block element's own inline content."""

    def __init__(self, el, parent_of, verbatim=False, idkey=None):
        self.el = el
        self.segs, self.toks = [], []
        self.verbatim = verbatim
        self.idkey = idkey or (lambda i: i)
        self.parent_of = parent_of
        self.row_el = el if is_row(el, parent_of.get(el)) else None
        self.walk(el, True)

    def add_seg(self, owner, slot, container):
        seg = Seg(owner, slot, writable(container, self.parent_of.get(container)),
                  container is self.row_el)
        self.segs.append(seg)
        k = len(self.segs) - 1
        text = seg.get()
        rx = WORDTOK if seg.row else TOK
        for m in rx.finditer(text):
            t = Tok()
            t.kind, t.seg, t.start, t.end, t.s = 't', k, m.start(), m.end(), m.group()
            t.el = None
            if t.s.isspace():
                t.key = t.s if self.verbatim else ' '
            else:
                t.key = t.s
            self.toks.append(t)

    def walk(self, el, top):
        self.add_seg(el, 'text', el)
        for ch in el:
            t = local(ch.tag) if is_el(ch) else None
            if t is None or t in SKIP or (t in BLOCK and t not in CELL):
                pass
            elif t in ATOM:
                tk = Tok()
                tk.kind, tk.el, tk.prev_seg = 'a', ch, len(self.segs) - 1
                tk.seg = tk.prev_seg
                tk.s = atom_text(ch)
                if t in ('xref', 'footnoteref'):
                    tk.key = inline_key(reference_text(ch), self.idkey)
                elif t == 'link':
                    kind, target = link_target(ch)
                    if kind == 'internal':
                        target = self.idkey(target)
                    label, nested = [], []
                    inline_text(ch, label, nested)
                    tk.key = ('link', kind, target, inline_key(''.join(label), self.idkey))
                else:
                    tk.key = t + ':' + ws(''.join(ch.itertext()))
                tk.next_seg = len(self.segs)       # the tail seg added next
                self.toks.append(tk)
            else:
                self.walk(ch, False)
            self.add_seg(ch, 'tail', el)

    def content(self):
        return [t for t in self.toks if not (t.kind == 't' and t.s.isspace())]


def atom_text(el):
    t = local(el.tag)
    if t == 'xref':
        return ''
    return ''.join(el.itertext())


class Editor:
    """Collects the edits of one block element and applies them."""

    def __init__(self, flat, parent_of):
        self.f = flat
        self.parent_of = parent_of
        self.segedits = {}         # seg index -> list of edits
        self.atomflags = []        # (atom element, flag)
        self.wordwraps = {}        # (seg, start) -> edit dict, row mode

    # --- positions
    def pos_before(self, j):
        toks = self.f.toks
        for k in range(j, len(toks)):
            t = toks[k]
            if t.kind == 'a':
                if self.f.segs[t.prev_seg].writable:
                    return (t.prev_seg, len(self.f.segs[t.prev_seg].get()))
                continue
            if not t.s.isspace() and self.f.segs[t.seg].writable:
                return (t.seg, t.start)
        return self.pos_after(j - 1)

    def pos_after(self, j):
        toks = self.f.toks
        for k in range(j, -1, -1):
            t = toks[k]
            if t.kind == 'a':
                if self.f.segs[t.next_seg].writable:
                    return (t.next_seg, 0)
                continue
            if not t.s.isspace() and self.f.segs[t.seg].writable:
                return (t.seg, t.end)
        if self.f.segs and self.f.segs[0].writable:
            return (0, len(self.f.segs[0].get()))
        return None

    # --- edits
    def add_wrap(self, seg, start, end, flag):
        self.segedits.setdefault(seg, []).append(
            {'kind': 'wrap', 'start': start, 'end': end, 'flag': flag, 'pre': [], 'post': []})
        return self.segedits[seg][-1]

    def mark_added(self, j1, j2):
        toks = self.f.toks
        run = None
        for k in range(j1, j2):
            t = toks[k]
            if t.kind == 'a':
                run = None
                self.atomflags.append((t.el, 'added'))
                continue
            seg = self.f.segs[t.seg]
            if t.s.isspace():
                if seg.row or (run and run['seg'] != t.seg):
                    run = None
                continue
            if not seg.writable:
                continue
            if seg.row:
                e = self.add_wrap(t.seg, t.start, t.end, 'added')
                self.wordwraps[(t.seg, t.start)] = e
                run = None
            elif run and run['seg'] == t.seg:
                run['edit']['end'] = t.end
            else:
                e = self.add_wrap(t.seg, t.start, t.end, 'added')
                run = {'seg': t.seg, 'edit': e}

    def mark_deleted(self, nodes, j):
        """Insert deleted content before new token j."""
        pos = self.pos_before(j)
        if pos is None:
            return False
        seg, off = pos
        s = self.f.segs[seg]
        if s.row:
            nodes = [n.replace(' ', NBSP).replace('\n', NBSP) if isinstance(n, str) else n
                     for n in nodes]
            nodes = strip_nodes(nodes)
            if not nodes:
                return True
            text = s.get()
            words = [m for m in re.finditer(r'\S+', text)]
            after = [m for m in words if m.start() >= off]
            before = [m for m in words if m.end() <= off]
            if after and (not before or after[0].start() == off):
                m, side = after[0], 'pre'
            elif before:
                m, side = before[-1], 'post'
            else:
                m = None
            if m is not None:
                e = self.wordwraps.get((seg, m.start()))
                if e is None:
                    e = self.add_wrap(seg, m.start(), m.end(), None)
                    self.wordwraps[(seg, m.start())] = e
                if side == 'pre':
                    e['pre'].extend(nodes)
                else:
                    e['post'].extend([NBSP] + nodes)
                return True
        self.segedits.setdefault(seg, []).append({'kind': 'ins', 'start': off, 'end': off,
                                                  'nodes': nodes})
        return True

    # --- application
    def apply(self):
        for k, edits in self.segedits.items():
            self.apply_seg(self.f.segs[k], edits)
        for el, flag in self.atomflags:
            flag_element(el, flag, self.parent_of)

    def apply_seg(self, seg, edits):
        text = seg.get()
        # insertions before wraps at the same offset
        edits.sort(key=lambda e: (e['start'], 0 if e['kind'] == 'ins' else 1))
        pieces, pos = [], 0
        for e in edits:
            if e['start'] < pos:           # overlapping; keep the first
                continue
            pieces.append(text[pos:e['start']])
            if e['kind'] == 'ins':
                pieces.append(make_phrase('deleted', e['nodes']))
                pos = e['start']
            else:
                body = text[e['start']:e['end']]
                inner = make_phrase(e['flag'], [body]) if e['flag'] else body
                if e['pre'] or e['post']:
                    parts = []
                    if e['pre']:
                        parts.append(make_phrase('deleted', e['pre']))
                    parts.append(inner)
                    if e['post']:
                        post = e['post']
                        parts.append(post[0])
                        parts.append(make_phrase('deleted', post[1:]))
                    pieces.append(make_phrase(None, parts))
                else:
                    pieces.append(inner)
                pos = e['end']
        pieces.append(text[pos:])
        place_pieces(seg, pieces, self.parent_of)


def coalesce(ops, otoks, ntoks, words=True):
    """Merge changes separated only by whitespace (and, outside example rows
    and verbatim text, by one short word or punctuation mark) into one
    replacement, so a rewritten phrase reads as one deletion and one
    insertion rather than as alternating fragments."""
    def glue(i1, i2):
        # an equal run too small to read on its own between two changes:
        # whitespace, plus at most one short word or punctuation mark
        content = [t for t in otoks[i1:i2] if not (t.kind == 't' and t.s.isspace())]
        return not content or (words and len(content) == 1 and content[0].kind == 't'
                               and len(content[0].s) <= 3)
    out = []
    for op in ops:
        tag, i1, i2, j1, j2 = op
        if (tag != 'equal' and len(out) >= 2 and out[-1][0] == 'equal' and out[-2][0] != 'equal'
                and glue(out[-1][1], out[-1][2])):
            out.pop()
            p = out.pop()
            out.append(('replace', p[1], i2, p[3], j2))
        elif tag != 'equal' and out and out[-1][0] != 'equal':
            p = out.pop()
            out.append(('replace', p[1], i2, p[3], j2))
        else:
            out.append(op)
    return out


def strip_nodes(nodes):
    nodes = list(nodes)
    while nodes and isinstance(nodes[0], str) and not nodes[0].strip(' \t\n' + NBSP):
        nodes.pop(0)
    while nodes and isinstance(nodes[-1], str) and not nodes[-1].strip(' \t\n' + NBSP):
        nodes.pop()
    if nodes and isinstance(nodes[0], str):
        nodes[0] = nodes[0].lstrip(' \t\n' + NBSP)
    if nodes and isinstance(nodes[-1], str):
        nodes[-1] = nodes[-1].rstrip(' \t\n' + NBSP)
    return nodes


def make_phrase(flag, nodes):
    p = ET.Element('phrase')
    if flag:
        p.set('revisionflag', flag)
    fill(p, nodes)
    return p


def fill(el, nodes):
    """Set el's content from a list of strings and elements."""
    last = None
    for n in nodes:
        if isinstance(n, str):
            if last is None:
                el.text = (el.text or '') + n
            else:
                last.tail = (last.tail or '') + n
        else:
            n.tail = None
            el.append(n)
            last = n


def place_pieces(seg, pieces, parent_of):
    """pieces alternate str / element (strings possibly empty)."""
    norm = [pieces[0]]
    for p in pieces[1:]:
        if isinstance(p, str) and isinstance(norm[-1], str):
            norm[-1] += p
        else:
            if not isinstance(p, str) and not isinstance(norm[-1], str):
                norm.append('')
            norm.append(p)
    if isinstance(norm[-1], ET.Element):
        norm.append('')
    first, rest = norm[0], norm[1:]
    els = rest[0::2]
    tails = rest[1::2]
    for e, t in zip(els, tails):
        e.tail = t or None
    if seg.slot == 'text':
        seg.owner.text = first or None
        for i, e in enumerate(els):
            seg.owner.insert(i, e)
            parent_of[e] = seg.owner
    else:
        seg.owner.tail = first or None
        par = parent_of[seg.owner]
        idx = list(par).index(seg.owner)
        for i, e in enumerate(els):
            par.insert(idx + 1 + i, e)
            parent_of[e] = par



def flag_element(el, flag, parent_of):
    """Flag an inline atom, wrapping it in a phrase if its own flag would be
    lost."""
    if local(el.tag) in FLAGGABLE:
        el.set('revisionflag', flag)
        return
    par = parent_of[el]
    idx = list(par).index(el)
    p = ET.Element('phrase', {'revisionflag': flag})
    p.tail, el.tail = el.tail, None
    par.remove(el)
    p.append(el)
    par.insert(idx, p)
    parent_of[p] = par
    parent_of[el] = p


def mark_all(el, flag, parent_of, top=True):
    """Mark all of el's content with flag, on the largest elements whose flag
    survives the build."""
    if not is_el(el):
        return
    t = local(el.tag)
    if t in SKIP:
        return
    par = parent_of.get(el)
    pt = local(par.tag) if par is not None else None
    row = is_row(el, par)
    if not row and t not in ('title', 'term', 'caption', 'attribution') and (
            t in FLAGGABLE and not (t in ('jbo', 'gloss')) or
            (t in ROWCHILD_FLAGGABLE and pt in ROWCHILD_PARENTS and t != 'td')):
        el.set('revisionflag', flag)
        return
    if t in ('jbo', 'gloss') and not row and pt in ('lujvo-making', 'pronunciation',
                                                    'compound-cmavo', 'lojbanization'):
        el.set('revisionflag', flag)
        return
    wr = writable(el, par)
    children = list(el)
    for c in children:
        if is_el(c) and local(c.tag) in ATOM:
            flag_element(c, flag, parent_of)
        else:
            mark_all(c, flag, parent_of, False)
    if not wr:
        return
    segs = [(el, 'text')] + [(c, 'tail') for c in el]
    for owner, slot in segs:
        text = (owner.text if slot == 'text' else owner.tail) or ''
        if not text.strip():
            continue
        seg = Seg(owner, slot, True, row)
        if row:
            pieces, pos = [], 0
            for m in re.finditer(r'\S+', text):
                pieces += [text[pos:m.start()], make_phrase(flag, [m.group()])]
                pos = m.end()
            pieces.append(text[pos:])
        else:
            m = re.match(r'(\s*)(.*?)(\s*)$', text, re.S)
            pieces = [m.group(1), make_phrase(flag, [m.group(2)]), m.group(3)]
        place_pieces(seg, pieces, parent_of)


# ---------------------------------------------------------------- the diff proper

class Differ:
    def __init__(self, old, new, rep):
        self.old, self.new = old, new
        self.so, self.sn = None, None
        self.new_ids = set(new.ids)
        self.deleted_sections = []     # (old section, re-inserted copy)
        self.preserved_ids = set()     # old section ids kept on their copies
        self.stats = {}
        self.unplaced = []
        self.dropped_words = []
        self.parent_of = dict(new.parent)          # live parent map of the output
        self.id_rep_old = rep(old.groups)
        self.id_rep_new = rep(new.groups)
        self.after = {}

    def count(self, k, n=1):
        self.stats[k] = self.stats.get(k, 0) + n

    # --- id handling
    def map_old_id(self, i):
        if i in self.new_ids:
            return i
        for a in sorted(self.old.groups.get(i, ())):
            if a in self.new_ids:
                return a
        return None

    def old_title(self, i):
        el = self.old.ids.get(i)
        if el is None:
            return None
        if local(el.tag) == 'anchor':
            el = self.old.parent.get(el)
            if el is not None and local(el.tag) == 'title':
                el = self.old.parent.get(el)
        if el is None:
            return None
        title = el.find('title')
        if title is None:
            return None
        return ws(''.join(t for t in text_skipping(title)))

    def sanitize(self, el):
        """A deep copy of old material safe to put into the new book."""
        holder = ET.Element('x')
        c = copy.deepcopy(el)
        c.tail = None
        holder.append(c)
        self._sanitize(holder)
        kids = list(holder)
        if len(kids) == 1 and not (holder.text or '').strip():
            return kids[0]
        p = ET.Element('phrase')           # the root itself became text
        p.text = holder.text
        for k in kids:
            p.append(k)
        return p

    def _sanitize(self, el):
        new_children = []
        for ch in list(el):
            el.remove(ch)
            if not is_el(ch):
                new_children.append(ch)
                continue
            t = local(ch.tag)
            if ch.tag.startswith('{%s}' % MML_NS):
                ch.tag = t            # the book's MathML is unprefixed now
            if t in ('anchor', 'indexterm'):
                if ch.tail:
                    new_children.append(ch.tail)
                continue
            if ch.get(XML_ID):
                del ch.attrib[XML_ID]
            if t == 'valsi':
                ch.set('valid', 'maybe')
            repl = None
            for attr in ('linkend', 'endterm', 'otherterm'):
                v = ch.get(attr)
                if v is None:
                    continue
                m = self.map_old_id(v)
                if m is not None:
                    ch.set(attr, m)
                elif attr == 'linkend' and t == 'xref':
                    title = self.old_title(v)
                    repl = ['“%s”' % title if title else '(removed)']
                elif attr == 'linkend' and t == 'link':
                    ch.tag = 'phrase'
                    del ch.attrib[attr]
                else:
                    del ch.attrib[attr]
            href = ch.get('{%s}href' % XLINK_NS)
            if t == 'link' and href is not None and href.startswith('#'):
                mapped = self.map_old_id(href[1:])
                if mapped is None:
                    ch.tag = 'phrase'
                    del ch.attrib['{%s}href' % XLINK_NS]
                else:
                    ch.set('{%s}href' % XLINK_NS, '#' + mapped)
            if repl is not None:
                new_children.extend(repl)
                if ch.tail:
                    new_children.append(ch.tail)
                continue
            self._sanitize(ch)
            tail, ch.tail = ch.tail, None
            new_children.append(ch)
            if tail:
                new_children.append(tail)
        # rebuild children
        last = None
        for n in new_children:
            if isinstance(n, str):
                if last is None:
                    el.text = (el.text or '') + n
                else:
                    last.tail = (last.tail or '') + n
            else:
                el.append(n)
                last = n

    def old_nodes(self, toks, show_targets=False):
        """Deleted content (old tokens) as strings and sanitized copies."""
        out = []
        for t in toks:
            if t.kind != 'a':
                out.append(t.s)
                continue
            if local(t.el.tag) == 'xref':
                m = self.map_old_id(t.el.get('linkend', ''))
                if m is None:
                    title = self.old_title(t.el.get('linkend', ''))
                    out.append('\u201c%s\u201d' % title if title else '(removed)')
                else:
                    out.append(self.sanitize(t.el))
                continue
            c = self.sanitize(t.el)
            c.tail = None
            out.append(c)
            if show_targets and local(t.el.tag) == 'link':
                out.append(self.target_note(t.el))
        # merge adjacent strings
        merged = []
        for n in out:
            if isinstance(n, str) and merged and isinstance(merged[-1], str):
                merged[-1] += n
            else:
                merged.append(n)
        return merged

    def target_note(self, el):
        kind, target = link_target(el)
        label = ('#' + target) if kind == 'internal' else target
        note = ET.Element('phrase', {'role': 'diff-link-destination'})
        note.text = ' [destination: %s]' % (label if kind != 'none' else '(none)')
        return note

    # --- step 1: low-similarity pairs become a deletion plus an insertion
    def split_low_similarity(self):
        for b in self.new.blocks:
            if b.status not in ('chg', 'movechg'):
                continue
            o = b.partner
            fo = Flat(o.el, self.old.parent, o.tag in VERBATIM)
            fn = Flat(b.el, self.new.parent, b.tag in VERBATIM)
            ko = [t.key for t in fo.content()]
            kn = [t.key for t in fn.content()]
            r = difflib.SequenceMatcher(None, ko, kn, autojunk=False).ratio()
            if r < 0.5 and b.tag in DUPLICABLE and o.tag == b.tag and \
                    local(b.el.tag) == local(o.el.tag):
                o.status, b.status = 'del', 'ins'
                o.partner = b.partner = None
                self.count('split_low_similarity')

    # --- step 2: which moves can be shown as notes; the rest are demoted
    def plan_moves(self):
        so = Summary(self.old)
        demote = []

        def plan(O):
            c = so.get(O)
            if not c:
                return
            if any(c.get(s) for s in SURV):
                for ch in O:
                    if is_el(ch):
                        plan(ch)
                if O in so.own and so.own[O].status in MOVED:
                    demote.append(so.own[O])    # moved block inside a surviving one
                return
            nmov = sum(c.get(s, 0) for s in MOVED)
            if not nmov:
                return
            if not any(c.get(s) for s in ('del',)) and self.representable(O):
                return
            if O in so.own or not any(is_el(ch) and so.get(ch) for ch in O):
                demote.extend(b for b in so.blocks_under(O) if b.status in MOVED)
                return
            for ch in O:
                if is_el(ch):
                    plan(ch)
        for _, root in self.old.files:
            plan(root)
        for b in demote:
            p = b.partner
            if p is None:
                continue
            b.status, p.status = 'del', 'ins'
            b.partner = p.partner = None
            self.count('moves_demoted')

    def representable(self, O):
        t = local(O.tag)
        if t in SINGLETON:
            return False
        if t in SECTIONISH or t == 'listitem':
            return True
        par = self.old.parent.get(O)
        return par is not None and local(par.tag) in PARA_OK

    # --- step 3: annotate the new book in place
    def annotate_new(self):
        sn = Summary(self.new)
        self.sn = sn
        todo = []

        def walk(N):
            c = sn.get(N)
            if not c:
                return
            if set(c) == {'ins'}:
                todo.append(('all', N))
                return
            for ch in N:
                if is_el(ch):
                    walk(ch)
        for _, root in self.new.files:
            walk(root)
        for b in self.new.blocks:
            if b.status in ('chg', 'movechg'):
                todo.append(('chg', b))
            elif b.status == 'ins':
                pass
        for kind, x in todo:
            if kind == 'all':
                mark_all(x, 'added', self.parent_of)
                self.count('added_elements')
            else:
                self.word_diff(x)

    def word_diff(self, b):
        o = b.partner
        verb = b.tag in VERBATIM
        fo = Flat(o.el, self.old.parent, verb, self._old_key)
        fn = Flat(b.el, self.parent_of, verb, self._new_key)
        ko = [t.key for t in fo.toks]
        kn = [t.key for t in fn.toks]
        sm = difflib.SequenceMatcher(None, ko, kn, autojunk=False)
        ed = Editor(fn, self.parent_of)
        whole = local(b.el.tag) in SINGLETON and sm.ratio() < 0.5
        ops = sm.get_opcodes()
        if whole:
            ops = [('replace', 0, len(ko), 0, len(kn))]
        ops = coalesce(ops, fo.toks, fn.toks, words=not verb and fn.row_el is None)
        changed = False
        target_notes = []
        for op, i1, i2, j1, j2 in ops:
            if op == 'equal':
                continue
            otoks, ntoks = fo.toks[i1:i2], fn.toks[j1:j2]
            old_links = [t for t in otoks if t.kind == 'a' and local(t.el.tag) == 'link']
            new_links = [t for t in ntoks if t.kind == 'a' and local(t.el.tag) == 'link']
            show_targets = [t.key[1:3] for t in old_links] != [t.key[1:3] for t in new_links]
            if all(t.kind == 't' and t.s.isspace() for t in otoks + ntoks):
                continue
            if j2 > j1 and not all(t.kind == 't' and t.s.isspace() for t in ntoks):
                ed.mark_added(j1, j2)
                if show_targets:
                    target_notes.extend(t.el for t in new_links)
                changed = True
            if i2 > i1 and not all(t.kind == 't' and t.s.isspace() for t in otoks):
                nodes = strip_nodes(self.old_nodes(otoks, show_targets))
                if j2 == j1 and j1 < len(fn.toks) and not verb:
                    nodes.append(' ')     # pure deletion before a word
                if not ed.mark_deleted(nodes, j1):
                    self.count('deleted_words_dropped')
                    self.dropped_words.append(o.el)
                changed = True
        ed.apply()
        for el in target_notes:
            note = self.target_note(el)
            note.set('revisionflag', 'added')
            note.tail, el.tail = el.tail, None
            parent = self.parent_of[el]
            parent.insert(list(parent).index(el) + 1, note)
            self.parent_of[note] = parent
        self.count('changed_blocks' if changed else 'changed_blocks_ws_only')

    def _old_key(self, i):
        return self.id_rep_old(re.match('(.*)', i, re.S)).strip('\x01\x02')

    def _new_key(self, i):
        return self.id_rep_new(re.match('(.*)', i, re.S)).strip('\x01\x02')

    # --- step 4: re-insert old-only material
    def insert_old(self):
        so = Summary(self.old)
        self.so = so
        deleted_files = []
        todo = []

        def walk(O, is_root):
            c = so.get(O)
            if not c:
                return
            if any(c.get(s) for s in SURV):
                for ch in O:
                    if is_el(ch):
                        walk(ch, False)
                return
            todo.append((O, is_root))
        for name, root in self.old.files:
            walk(root, True)
        for O, is_root in todo:
            nodes = self.reconstruct(O)
            if is_root:
                deleted_files.append((self.old_file_of(O), nodes))
                self.count('deleted_files')
                continue
            if not self.place(O, nodes):
                self.unplaced.append(O)
                self.count('unplaced')
        return deleted_files

    def old_file_of(self, root):
        for name, r in self.old.files:
            if r is root:
                return name

    def reconstruct(self, O):
        so = self.so
        c = so.get(O)
        nmov = sum(c.get(s, 0) for s in MOVED)
        if not nmov:
            cp = self.sanitize(O)
            cp.tail = None
            self.mark_deleted_copy(cp, O)
            self.count('deleted_elements')
            if local(O.tag) in SECTIONISH:
                # A wholly deleted section keeps its id (when nothing in the
                # new book uses it), so the comparison table of contents and
                # the re-inserted body still link to each other. Refs to such
                # an id stay dangling: _sanitize never lets a copy point at
                # one, so any remaining ref comes from the new book, where
                # the id does not exist either (see check_ids).
                oid = O.get(XML_ID)
                if oid and oid not in self.new_ids:
                    cp.set(XML_ID, oid)
                    self.preserved_ids.add(oid)
                    self._keep_section_ids(O, cp)
                self.deleted_sections.append((O, cp))
            return [cp]
        if not c.get('del') and self.representable(O):
            self.count('move_notes')
            return [self.note(O)]
        # skeleton
        S = ET.Element(O.tag, {k: v for k, v in O.attrib.items() if k != XML_ID})
        S.text = O.text
        for ch in O:
            if not is_el(ch):
                S.append(copy.deepcopy(ch))
                continue
            t = local(ch.tag)
            if so.get(ch):
                if t in SINGLETON:
                    cp = self.sanitize(ch)
                    cp.tail = ch.tail
                    self.mark_deleted_copy(cp, ch, parent_tag=local(O.tag))
                    S.append(cp)
                    continue
                parts = self.reconstruct(ch)
            elif t in ('anchor', 'indexterm'):
                continue
            else:
                parts = [self.sanitize(ch)]
            for p in parts:
                p.tail = '\n'
                S.append(p)
        self.merge_notes(S)
        if local(O.tag) in SECTIONISH:
            oid = O.get(XML_ID)
            if oid and oid not in self.new_ids:
                S.set(XML_ID, oid)
                self.preserved_ids.add(oid)
                self._keep_section_ids(O, S)
                self.deleted_sections.append((O, S))
        return [S]

    def _keep_section_ids(self, O, cp):
        """Keep the ids of deleted subsections for their ToC links.

        Sanitizing strips every id from a re-inserted copy, so without
        this the ToC links of subsections inside a deleted section point
        at generated ids and the subsections get no mark. Sanitizing
        keeps SECTIONISH elements in order (it only drops anchors,
        indexterms and inline replacements), so pair the old and copied
        subsection sequences positionally; on any shape mismatch keep
        nothing rather than mislabel.
        """
        olds = [e for e in O.iter()
                if e is not O and is_el(e) and local(e.tag) in SECTIONISH]
        news = [e for e in cp.iter()
                if e is not cp and is_el(e) and local(e.tag) in SECTIONISH]
        if len(olds) != len(news):
            return
        for o_el, n_el in zip(olds, news):
            oid = o_el.get(XML_ID)
            if oid and not n_el.get(XML_ID) and oid not in self.new_ids:
                n_el.set(XML_ID, oid)
                self.preserved_ids.add(oid)
                self.deleted_sections.append((o_el, n_el))

    def mark_deleted_copy(self, cp, orig, parent_tag=None):
        par = self.old.parent.get(orig)
        tmp_parent = ET.Element(parent_tag or (local(par.tag) if par is not None else 'section'))
        tmp_parent.append(cp)
        pmap = {cp: tmp_parent}
        for p in cp.iter():
            for ch in p:
                pmap[ch] = p
        mark_all(cp, 'deleted', pmap)
        tmp_parent.remove(cp)

    def target_of(self, O):
        """Where the moved blocks under O went: the ids of the nearest
        id-bearing sections/examples around their new places."""
        tg = []
        for b in self.so.blocks_under(O):
            if b.status not in MOVED:
                continue
            el = b.partner.el
            while el is not None and not (local(el.tag) in NOTE_TARGETS and el.get(XML_ID)):
                el = self.new.parent.get(el)
            if el is not None:
                i = el.get(XML_ID)
                if not tg or tg[-1] != i:
                    tg.append(i)
        return tg

    def note(self, O):
        t = local(O.tag)
        targets = self.target_of(O)
        p = ET.Element('para', {'role': 'diff-moved', 'revisionflag': 'changed'})
        p.set('diffmoved', ' '.join(targets))
        self.fill_note(p, targets)
        if t in SECTIONISH:
            title = O.find('title')
            sec = ET.Element('section')
            tt = ET.SubElement(sec, 'title')
            if title is not None:
                tt.append(make_phrase('deleted', [ws(''.join(text_skipping(title)))]))
            p.tail = '\n'
            sec.append(p)
            sec.set('diffmoved', ' '.join(targets))
            return sec
        if t == 'listitem':
            li = ET.Element('listitem')
            li.append(p)
            li.set('diffmoved', ' '.join(targets))
            return li
        return p

    def fill_note(self, p, targets):
        targets = self.condense(targets)
        nodes = ['Moved to ']
        for k, i in enumerate(targets):
            if k:
                nodes.append(', ' if k < len(targets) - 1 else ' and ')
            nodes.append(ET.Element('xref', {'linkend': i}))
        nodes.append('.')
        for ch in list(p):
            p.remove(ch)
        p.text = None
        fill(p, nodes)

    def condense(self, targets):
        """Many targets inside one section (not a chapter): name the section."""
        if len(targets) <= 1:
            return targets
        chains = []
        for i in targets:
            el, ch = self.new.ids[i], []
            while el is not None:
                if local(el.tag) in NOTE_TARGETS and el.get(XML_ID):
                    ch.append(el)
                el = self.new.parent.get(el)
            chains.append(ch[::-1])
        common = None
        for k in range(min(len(c) for c in chains)):
            if all(c[k] is chains[0][k] for c in chains):
                common = chains[0][k]
        if common is not None and local(common.tag) not in ('chapter', 'article', 'appendix'):
            return [common.get(XML_ID)]
        out = []
        for i in targets:
            if i not in out:
                out.append(i)
        return out

    def merge_notes(self, S):
        """Merge runs of consecutive move notes into one; a run of section
        notes becomes one paragraph when no real section follows it."""
        kids = [c for c in S if is_el(c)]
        runs, cur = [], []
        for c in kids:
            if c.get('diffmoved') is not None:
                cur.append(c)
            else:
                if cur:
                    runs.append(cur)
                cur = []
        if cur:
            runs.append(cur)
        for run in runs:
            if len(run) < 2 and local(run[0].tag) != 'section':
                continue
            targets = []
            for c in run:
                for i in c.get('diffmoved').split():
                    if i not in targets:
                        targets.append(i)
            last = run[-1]
            idx = kids.index(last)
            later_sections = any(local(c.tag) in SECTIONISH for c in kids[idx + 1:])
            earlier_sections = any(local(c.tag) in SECTIONISH and c.get('diffmoved') is None
                                   for c in kids[:kids.index(run[0])])
            p = ET.Element('para', {'role': 'diff-moved', 'revisionflag': 'changed',
                                    'diffmoved': ' '.join(targets)})
            self.fill_note(p, targets)
            if local(S.tag) in SECTIONISH and (later_sections or earlier_sections) and \
                    all(local(c.tag) == 'section' for c in run):
                if len(run) < 2:
                    continue
                sec = ET.Element('section', {'diffmoved': ' '.join(targets)})
                tt = ET.SubElement(sec, 'title')
                titles = []
                for c in run:
                    ti = c.find('title')
                    titles.append(ws(''.join(text_skipping(ti))) if ti is not None else '')
                tt.append(make_phrase('deleted', ['; '.join(x for x in titles if x)]))
                sec.append(p)
                repl = sec
            elif local(S.tag) not in PARA_OK and not all(local(c.tag) == 'listitem' for c in run):
                continue
            elif all(local(c.tag) == 'listitem' for c in run):
                if len(run) < 2:
                    continue
                repl = ET.Element('listitem', {'diffmoved': ' '.join(targets)})
                repl.append(p)
            else:
                repl = p
            i0 = list(S).index(run[0])
            for c in run:
                S.remove(c)
            repl.tail = '\n'
            S.insert(i0, repl)
            kids = [c for c in S if is_el(c)]

    def merge_singletons(self, par, nodes):
        """A deleted title (term, table head...) whose place already holds a
        new one is merged into it rather than added as a second one."""
        out = []
        for n in nodes:
            t = local(n.tag)
            same = [c for c in par if is_el(c) and local(c.tag) == t] if t in SINGLETON else []
            if not same:
                out.append(n)
                continue
            tgt = same[0]
            ocells = [c for c in n if is_el(c) and local(c.tag) in CELL]
            ncells = [c for c in tgt if is_el(c) and local(c.tag) in CELL]
            pairs = list(zip(ocells, ncells)) if ocells and ncells else [(n, tgt)]
            for src, dst in pairs:
                lead = (src.text or '').strip()
                kids = [c for c in src if is_el(c)]
                if not kids and not lead:
                    continue
                for c in kids:
                    src.remove(c)
                holder = ET.Element('x')
                fill(holder, ([lead] if lead else []) + kids + [' ' + (dst.text or '')])
                dst.text = holder.text
                for i, c in enumerate(list(holder)):
                    holder.remove(c)
                    dst.insert(i, c)
                    self.parent_of[c] = dst
            self.count('merged_singletons')
        return out

    def place(self, O, nodes):
        """Insert nodes (the reconstruction of old-only O) at O's old place
        in the new book."""
        old, so = self.old, self.so
        P = old.parent.get(O)
        sibs = [c for c in P if is_el(c)]
        idx = sibs.index(O)
        for X in reversed(sibs[:idx]):
            if any(so.get(X).get(s) for s in SURV):
                S = [b for b in so.blocks_under(X) if b.status in SURV][-1]
                Xn = self.counterpart(X, S)
                if Xn is not None:
                    self.insert_after(Xn, self.merge_singletons(self.parent_of[Xn], nodes))
                    return True
                break
        for X in sibs[idx + 1:]:
            if any(so.get(X).get(s) for s in SURV):
                S = [b for b in so.blocks_under(X) if b.status in SURV][0]
                Xn = self.counterpart(X, S)
                if Xn is not None:
                    self.insert_before(Xn, self.merge_singletons(self.parent_of[Xn], nodes))
                    return True
                break
        if P in so.own and so.own[P].status in SURV:
            Pn = so.own[P].partner.el
            for n in self.merge_singletons(Pn, nodes):
                n.tail = None
                Pn.append(n)
                self.parent_of[n] = Pn
            return True
        return self.place_in_container(O, nodes)

    def place_in_container(self, O, nodes):
        """Place deleted paragraphs in the nearest surviving container.

        Wrapper changes invalidate depth-based sibling matches. Infer the
        container from stable IDs or surviving descendants instead. Other
        deleted structures need their original placement rules.
        """
        if not all(local(n.tag) in ('para', 'simpara') for n in nodes):
            return False
        blocks = self.so.blocks_under(O)
        first, last = blocks[0].seq, blocks[-1].seq
        ancestor = self.old.parent.get(O)
        while ancestor is not None:
            if local(ancestor.tag) in PARA_OK:
                target = None
                mapped = self.map_old_id(ancestor.get(XML_ID, ''))
                if mapped:
                    candidate = self.new.ids[mapped]
                    if local(candidate.tag) == local(ancestor.tag):
                        target = candidate
                survivors = [b for b in self.so.blocks_under(ancestor) if b.status in SURV]
                if target is None:
                    candidates = set()
                    for b in survivors:
                        candidate = b.partner.el
                        while candidate is not None and local(candidate.tag) != local(ancestor.tag):
                            candidate = self.new.parent.get(candidate)
                        if candidate is not None:
                            candidates.add(candidate)
                    if len(candidates) == 1:
                        target = candidates.pop()
                if target is not None:
                    def child_at(b):
                        child = b.partner.el
                        while child is not None and self.new.parent.get(child) is not target:
                            child = self.new.parent.get(child)
                        return child
                    before = [b for b in survivors if b.seq < first]
                    after = [b for b in survivors if b.seq > last]
                    for b in reversed(before):
                        child = child_at(b)
                        if child is not None:
                            self.insert_after(child, nodes)
                            return True
                    for b in after:
                        child = child_at(b)
                        if child is not None:
                            self.insert_before(child, nodes)
                            return True
                    for n in nodes:
                        n.tail = '\n'
                        target.append(n)
                        self.parent_of[n] = target
                    return True
            ancestor = self.old.parent.get(ancestor)
        return False

    def require_complete(self):
        """Refuse output when a deleted block or word could not be placed."""
        problems = [('unplaced deleted element', el) for el in self.unplaced]
        problems += [('unplaced deleted words', el) for el in self.dropped_words]
        if not problems:
            return
        lines = ['docbook-diff: incomplete comparison; no output written']
        for reason, el in problems:
            blocks = self.so.blocks_under(el)
            name = blocks[0].file if blocks else '?'
            identity = el.get(XML_ID, '')
            excerpt = ws(''.join(el.itertext()))[:200]
            lines.append('%s: chapters/%s <%s> id=%s: %s' %
                         (reason, name, local(el.tag), identity or '(none)', excerpt))
        sys.exit('\n'.join(lines))

    def counterpart(self, X, S):
        k = self.old.depth(S.el) - self.old.depth(X)
        Xn = self.new.up(S.partner.el, k)
        if Xn is None or local(Xn.tag) != local(X.tag):
            return None
        return Xn

    def insert_after(self, Xn, nodes):
        ref = self.after.get(id(Xn), Xn)
        par = self.parent_of[ref]
        i = list(par).index(ref)
        for n in nodes:
            n.tail = '\n'
            i += 1
            par.insert(i, n)
            self.parent_of[n] = par
            ref = n
        self.after[id(Xn)] = ref

    def insert_before(self, Xn, nodes):
        par = self.parent_of[Xn]
        i = list(par).index(Xn)
        for n in nodes:
            n.tail = '\n'
            par.insert(i, n)
            self.parent_of[n] = par
            i += 1

    # --- step 5: deleted copies of low-similarity splits and demoted moves
    # are handled by insert_old (their old blocks are 'del').

    def section_summaries(self):
        """Per-section change counts for the comparison table of contents.

        Maps each changed section's xml:id to its status -- added for an
        entirely new section, deleted for a re-inserted deleted one,
        changed for a surviving section with any change under it -- and to
        its block counts, so finish() can mark the section's ToC number.
        Counts follow the banner: chg/ins count new-side blocks, del counts
        old-side blocks, mov counts moved pairs touching the section.
        """
        out = {}
        sn, so = self.sn, self.so
        dead = set()
        for O, cp in self.deleted_sections:
            for e in cp.iter():
                dead.add(id(e))
        old_sec_of_id = self._id_sections(self.old, None)
        resolved = []
        for _, root in self.new.files:
            for el in root.iter():
                if not is_el(el) or local(el.tag) not in SECTIONISH:
                    continue
                i = el.get(XML_ID)
                if not i:
                    continue
                c = sn.get(el)
                old_el = self.old.ids.get(i)
                via = 'direct' if old_el is not None else None
                if old_el is None:
                    old_el = self._alias_old_section(el, old_sec_of_id, dead)
                    if old_el is not None:
                        via = 'alias'
                    else:
                        old_el = self._parent_old_section(el, dead, old_sec_of_id)
                        if old_el is not None:
                            via = 'parent'
                        else:
                            old_el = self._aligned_old_section(el)
                            if old_el is not None:
                                via = 'align'
                oc = so.get(old_el) if old_el is not None else {}
                if via in (None, 'direct') and not self._section_changed(c, oc):
                    continue
                resolved.append((el, i, c, oc, old_el, via))
        matched = {}
        for el, i, c, oc, old_el, via in resolved:
            if via in ('alias', 'parent', 'align'):
                matched[old_el] = matched.get(old_el, 0) + 1
        for el, i, c, oc, old_el, via in resolved:
            out[i] = {'status': 'changed' if old_el is not None else 'added',
                      'chg': (c or {}).get('chg', 0), 'ins': (c or {}).get('ins', 0),
                      'del': self._deleted_count(old_el, oc, via, matched),
                      'mov': self._moved_touching(el, old_el, via)}
        for O, cp in self.deleted_sections:
            i = cp.get(XML_ID)
            if not i:
                continue
            oc = so.get(O)
            out[i] = {'status': 'deleted', 'chg': 0, 'ins': 0,
                      'del': oc.get('del', 0),
                      'mov': oc.get('move', 0) + oc.get('movechg', 0)}
        return out

    def _section_of(self, book, el):
        """Nearest enclosing-or-self sectionish ancestor of el."""
        while el is not None:
            if is_el(el) and local(el.tag) in SECTIONISH:
                return el
            el = book.parent.get(el)
        return None

    def _section_survives(self, old_el):
        """Whether the old section still exists under the same id.

        A bare id occurrence (an anchor kept for old links) does not
        count: only a section carrying the id means the section
        survived. An id reused as an anchor must not hide that section's
        own deletions, nor block an alias match.
        """
        oid = old_el.get(XML_ID)
        n = self.new.ids.get(oid) if oid else None
        return n is not None and is_el(n) and local(n.tag) in SECTIONISH

    def _id_sections(self, book, dead):
        """Map every live xml:id to its nearest sectionish element.

        Ids inside re-inserted deleted copies (dead) are skipped: they
        name the copy, not a surviving section.
        """
        out = {}
        dead = dead or ()
        for _, root in book.files:
            stack = [root]
            while stack:
                e = stack.pop()
                if not is_el(e) or id(e) in dead:
                    continue
                i = e.get(XML_ID)
                if i and i not in out:
                    out[i] = self._section_of(book, e)
                stack.extend(e)
        return out

    def _live_ids(self, el, dead, own_level=False):
        """xml:ids under el, skipping re-inserted deleted copies.

        With own_level, ids inside a nested section of el itself do not
        count: only the section's own level decides its identity, so a
        renamed parent is not outvoted by its kept subsections.
        """
        out = []
        stack = [el]
        while stack:
            e = stack.pop()
            if not is_el(e) or id(e) in dead:
                continue
            i = e.get(XML_ID)
            if i:
                out.append(i)
            for c in e:
                if not is_el(c):
                    continue
                if own_level and c is not el and local(c.tag) in SECTIONISH:
                    continue
                stack.append(c)
        return out

    def _own_blocks(self, new_el):
        """Blocks whose nearest new section is new_el itself.

        Blocks under nested subsections belong to those subsections, so
        a renamed parent is judged on its own title and paragraphs, and
        a renamed chapter on its title.
        """
        return [b for b in self.sn.blocks_under(new_el)
                if self._section_of(self.new, b.el) is new_el]

    def _alias_old_section(self, new_el, old_sec_of_id, dead):
        """Old section sharing own-level inner ids with a renamed section.

        A new section whose title anchor or other own stable inner ids
        all point into one old section that is itself gone counts as
        that section surviving under a new id (blue), not as wholly new.
        """
        cands = set()
        for i in self._live_ids(new_el, dead, own_level=True):
            o = old_sec_of_id.get(i)
            if o is not None:
                cands.add(o)
        if len(cands) != 1:
            return None
        o = cands.pop()
        if o is None or self._section_survives(o):
            return None
        return o

    def _parent_old_section(self, new_el, dead, old_sec_of_id):
        """Gone old parent whose subsections the new subsections continue.

        Only subsections present in the new source count: a struck
        re-inserted deleted copy is not a surviving child. Each child
        resolves by id, or through the same alias as a rename (a kept
        title anchor or inner id). When the resolved old subsections
        share one gone old parent, the new section is that parent
        renamed -- even a chapter, and even when its own blocks pair
        elsewhere.
        """
        cands = set()
        resolved = 0
        for ch in new_el:
            if not is_el(ch) or local(ch.tag) not in SECTIONISH:
                continue
            if id(ch) in dead:
                continue
            i = ch.get(XML_ID)
            if not i:
                continue
            o = self.old.ids.get(i)
            if o is None:
                o = self._alias_old_section(ch, old_sec_of_id, dead)
                if o is None:
                    continue
            resolved += 1
            par = self.old.parent.get(o)
            while par is not None and not (is_el(par) and local(par.tag) in SECTIONISH):
                par = self.old.parent.get(par)
            cands.add(par)
        if not resolved or len(cands) != 1:
            return None
        p = cands.pop()
        if p is None or self._section_survives(p):
            return None
        return p

    def _aligned_old_section(self, new_el):
        """Old material behind most of a renamed new section's content.

        When over half of the new section's own blocks pair with old
        blocks, from any old sections, the section holds familiar
        material, changed: blue, not green. Green then means "read this
        as new text". A reused title alone never reaches the bar:
        single-block sections need a shared id to match. Of the old
        sections, the one holding most of the paired blocks supplies
        the tooltip counts.
        """
        total, per = 0, {}
        for b in self._own_blocks(new_el):
            total += 1
            if b.partner is not None:
                o = self._section_of(self.old, b.partner.el)
                if o is not None:
                    per[o] = per.get(o, 0) + 1
        if total < 2 or not per:
            return None
        if sum(per.values()) / total <= 0.5:
            return None
        return max(per, key=per.get)

    @staticmethod
    def _section_changed(c, oc):
        """Whether a surviving section changed anywhere under it.

        New-side blocks (changed, added, moved) live in c; deleted
        blocks and the old side of a move live only in oc, so a section
        that only lost material counts as changed too.
        """
        if c and any(c.get(s) for s in ('chg', 'ins', 'move', 'movechg')):
            return True
        return bool(oc) and any(oc.get(s) for s in ('del', 'move', 'movechg'))

    def _deleted_count(self, old_el, oc, via, matched):
        """Deleted blocks to charge to a new section's number.

        A directly matched section carries its own old counts. A
        section matched to a different old one carries that old
        section's deletions only when it is the sole claimant and the
        old section is gone: a split must not charge the same deletion
        to every successor, and a surviving old section keeps its own.
        """
        if via == 'direct':
            return oc.get('del', 0)
        if old_el is None or matched.get(old_el, 0) > 1:
            return 0
        if self._section_survives(old_el):
            return 0
        return oc.get('del', 0)

    def _moved_touching(self, new_el, old_el, via):
        """Moved pairs the section supplied or received.

        Counts moved blocks under the new section wherever they came
        from, plus moved blocks under a directly matched old section
        wherever they went. For a section matched to a different old
        section, only pairs touching the new section itself count: a
        bystander never inherits another section's moves.
        """
        pairs = set()
        for b in self.sn.blocks_under(new_el):
            if b.status in MOVED and b.partner is not None:
                pairs.add(id(b.partner))
        if old_el is not None:
            for b in self.so.blocks_under(old_el):
                if b.status in MOVED and b.partner is not None:
                    if via == 'direct' or self._section_of(self.new, b.partner.el) is new_el:
                        pairs.add(id(b))
        return len(pairs)

    def fix_order(self, root):
        """Inserted paragraphs may not follow a section in a section: wrap
        them in a section of their own."""
        for S in root.iter():
            if not is_el(S) or local(S.tag) not in SECTIONISH:
                continue
            seen_section = False
            for c in list(S):
                if not is_el(c):
                    continue
                t = local(c.tag)
                if t in SECTIONISH:
                    seen_section = True
                    continue
                if seen_section and t not in ('title', 'info') and \
                        (c.get('revisionflag') in ('deleted', 'changed') or c.get('diffmoved') is not None):
                    i = list(S).index(c)
                    S.remove(c)
                    sec = ET.Element('section')
                    tt = ET.SubElement(sec, 'title')
                    label = 'Moved material' if c.get('diffmoved') is not None else 'Deleted material'
                    tt.append(make_phrase(c.get('revisionflag') or 'changed', [label]))
                    tail, c.tail = c.tail, '\n'
                    sec.append(c)
                    sec.tail = tail
                    S.insert(i, sec)
                    self.count('wrapped_in_section')


def text_skipping(el):
    """itertext() without indexterm/anchor content."""
    if el.text:
        yield el.text
    for ch in el:
        if is_el(ch) and local(ch.tag) not in ('indexterm', 'anchor'):
            yield from text_skipping(ch)
        if ch.tail:
            yield ch.tail


def cleanup(root):
    for el in root.iter():
        if is_el(el) and 'diffmoved' in el.attrib:
            del el.attrib['diffmoved']


def check_ids(roots, invalid=frozenset()):
    """Duplicate ids and dangling links in the annotated roots.

    Ids in invalid (old section ids kept on re-inserted deleted copies)
    never resolve a ref: sanitizing strips every id from the copies, so a
    ref to one comes from the new book, where the id does not exist either.
    """
    seen, dup = set(), []
    for r in roots:
        for el in r.iter():
            if is_el(el):
                i = el.get(XML_ID)
                if i:
                    if i in seen:
                        dup.append(i)
                    seen.add(i)
    refs = []
    for r in roots:
        for el in r.iter():
            if is_el(el):
                for a in ('linkend', 'endterm', 'otherterm'):
                    v = el.get(a)
                    if v and (v not in seen or v in invalid):
                        refs.append(v)
    return dup, refs


def serialize(root):
    s = ET.tostring(root, encoding='unicode')
    return s + '\n'


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    ap.add_argument('old')
    ap.add_argument('new')
    ap.add_argument('out')
    ap.add_argument('--repo', default='.')
    ap.add_argument('--stats')
    a = ap.parse_args()
    t0 = time.perf_counter()
    repo = Path(a.repo).resolve()
    so, sn = Source(a.old, repo), Source(a.new, repo)
    # Each book expands entities with its own definitions, so a changed
    # definition shows as a change of the text. The other tree only fills
    # in a name that this tree does not define.
    old, new = Book(so, entity_map([so, sn])), Book(sn, entity_map([sn, so]))
    rep = finalize(old, new)
    t1 = time.perf_counter()
    align(old, new)
    d = Differ(old, new, rep)
    d.split_low_similarity()
    d.plan_moves()
    t2 = time.perf_counter()
    d.annotate_new()
    deleted_files = d.insert_old()
    d.require_complete()
    outdir = Path(a.out) / 'chapters'
    new_names = {n for n, _ in new.files}
    roots = [r for _, r in new.files]
    written = []
    for name, nodes in deleted_files:
        target = name if name not in new_names else Path(name).stem + '-deleted.xml'
        for r in nodes:
            roots.append(r)
            written.append((target, r))
    for r in roots:
        d.fix_order(r)
        cleanup(r)
    dup, dangling = check_ids(roots, d.preserved_ids)
    if dup or dangling:
        print('docbook-diff: duplicate ids %s; dangling links %s' % (sorted(set(dup))[:20],
              sorted(set(dangling))[:20]), file=sys.stderr)
        sys.exit(1)
    for name, root in new.files:
        (outdir / name).write_text(serialize(root), encoding='utf-8')
    for target, r in written:
        (outdir / target).write_text(serialize(r), encoding='utf-8')
    t3 = time.perf_counter()
    kinds = {}
    for b in old.blocks + new.blocks:
        kinds[b.status] = kinds.get(b.status, 0) + 1
    res = dict(old=a.old, new=a.new, old_blocks=len(old.blocks), new_blocks=len(new.blocks),
               statuses=kinds, stats=d.stats, deleted_files=[t for t, _ in written],
               sections=d.section_summaries(),
               t_parse=round(t1 - t0, 2), t_align=round(t2 - t1, 2),
               t_annotate=round(t3 - t2, 2))
    print(json.dumps(res, ensure_ascii=False))
    if a.stats:
        Path(a.stats).write_text(json.dumps(res, ensure_ascii=False, indent=1))


# ---------------------------------------------------------------- page finishing

FLAG_TAG = re.compile(r'<(/?)(span|div)\b([^>]*?)(/?)>')
MARKS = {'added': '[+]', 'deleted': '[\u2212]', 'changed': '[\u2192]'}
TOC_MARKS = {'added': '[+]', 'deleted': '[\u2212]', 'changed': '[*]'}
TOC_CLASSES = {'added': 'diff-toc-added', 'deleted': 'diff-toc-deleted',
               'changed': 'diff-toc-changed'}
TOC_LINK = re.compile(r'<a\b[^>]*href="#([^"]+)"[^>]*>')
TOC_NUMBER = re.compile(r'\s*(\d[\d.]*\.?|[A-Z]\.[\d.]*\.?)(?=\s)')
ROW_MARK = {'added': '[+]', 'deleted': '[\u2212]'}


class _Offsets(HTMLParser):
    """HTMLParser with absolute offsets for tag boundaries.

    In handle_starttag and handle_data, getpos() points at the '<' of
    the tag (and at the end of the data); in handle_endtag it points at
    the '<' of the end tag. A start tag therefore spans abs() up to
    abs() plus len(get_starttag_text()), and an end tag ends at the
    next '>'.
    """

    def __init__(self, page):
        super().__init__(convert_charrefs=False)
        self.page = page
        self.starts = [0]
        pos = page.find('\n')
        while pos != -1:
            self.starts.append(pos + 1)
            pos = page.find('\n', pos + 1)

    def abs(self):
        ln, col = self.getpos()
        return self.starts[ln - 1] + col

    def open_start(self):
        return self.abs()

    def open_end(self):
        return self.abs() + len(self.get_starttag_text())

    def close_end(self):
        return self.page.find('>', self.abs()) + 1


class _TocWalk(_Offsets):
    """Spans of top-level divs whose class list contains 'toc'.

    A nested div like toc-title is part of its ToC region, never a
    region of its own, so each table of contents is visited exactly
    once no matter how its inner divs are classed.
    """

    def __init__(self, page):
        super().__init__(page)
        self.regions = []
        self._depth = None
        self._start = None

    def handle_starttag(self, tag, attrs):
        if tag != 'div':
            return
        if self._depth is not None:
            self._depth += 1
            return
        if 'toc' in dict(attrs).get('class', '').split():
            self._depth = 1
            self._start = self.open_start()

    def handle_endtag(self, tag):
        if tag != 'div' or self._depth is None:
            return
        self._depth -= 1
        if self._depth == 0:
            self.regions.append((self._start, self.close_end()))
            self._depth = None
class _TableWalk(_Offsets):
    """Table/row/cell structure of a page with absolute offsets.

    Each row records its own direct cells, whether any cell holds a
    nested table, and whether it sits inside an interlinear-gloss
    table. Judging rows only by their own direct cells means a layout
    row that merely contains a changed nested table is never marked,
    and rows after a nested table are still examined.
    """

    def __init__(self, page):
        super().__init__(page)
        self.tables = []
        self.rows = []
        self._open_rows = []

    def _cur_row(self):
        if (self.tables and self._open_rows and
                self._open_rows[-1]['table'] is self.tables[-1]):
            return self._open_rows[-1]
        return None

    def handle_starttag(self, tag, attrs):
        if tag == 'table':
            if self._open_rows:
                self._open_rows[-1]['nested'] = True
            cls = set(dict(attrs).get('class', '').split())
            self.tables.append({'start': self.open_start(), 'classes': cls,
                                'gloss': (_is_gloss_table(cls) or
                                          any(t['gloss'] for t in self.tables))})
        elif tag == 'tr':
            if not self.tables:
                return
            self._open_rows.append(
                {'table': self.tables[-1], 'start': self.open_start(),
                 'open': self.get_starttag_text(), 'tds': [], 'nested': False,
                 'end': None,
                 'classes': set(dict(attrs).get('class', '').split()),
                 'gloss': any(t['gloss'] for t in self.tables)})
        elif tag == 'td' or tag == 'th':
            row = self._cur_row()
            if row is None:
                return
            row['tds'].append({'start': self.open_start(),
                               'open': self.get_starttag_text(),
                               'open_end': self.open_end(), 'close': None})

    def handle_endtag(self, tag):
        if tag == 'td' or tag == 'th':
            row = self._cur_row()
            if row is not None and row['tds'] and row['tds'][-1]['close'] is None:
                row['tds'][-1]['close'] = self.abs()
        elif tag == 'tr':
            if self._open_rows:
                row = self._open_rows.pop()
                row['end'] = self.close_end()
                self.rows.append(row)
        elif tag == 'table':
            if self.tables:
                self.tables.pop()


def _is_gloss_table(classes):
    """Whether a table class set marks an interlinear gloss table.

    Matches interlinear-gloss and anything built on it, such as
    interlinear-gloss-itemized; the per-word cells of any of them must
    keep working and never collapse into one marked row.
    """
    return any(c.startswith('interlinear-gloss') for c in classes)


ROW_CLASSES_NEVER_MARKED = frozenset(('jbo', 'gloss', 'natlang'))


def _cell_text(inner):
    """Visible text of a cell, for telling content apart from markup."""
    return re.sub(r'<[^>]*>', '', inner).strip()


def _add_class(open_tag, cls):
    """Append cls to the class attribute of a raw start tag."""
    m = re.search(r'''\sclass=(["'])(.*?)\1''', open_tag)
    if m:
        q = m.group(1)
        return (open_tag[:m.start()] + ' class=%s%s %s%s' % (q, m.group(2), cls, q)
                + open_tag[m.end():])
    base = open_tag.rstrip()
    if base.endswith('/>'):
        return base[:-2] + ' class="%s"/>' % cls
    return base[:-1] + ' class="%s"' % cls + base[-1:]


def _apply_edits(page, edits):
    """Splice (start, end, replacement) edits into the page."""
    out, pos = [], 0
    for start, end, text in sorted(edits):
        out.append(page[pos:start])
        out.append(text)
        pos = end
    out.append(page[pos:])
    return ''.join(out)


def toc_tip(entry):
    """Tooltip for a marked ToC number from its per-section block counts."""
    counts = [(entry.get(k, 0), w) for k, w in
              (('chg', 'changed'), ('ins', 'added'),
               ('del', 'deleted'), ('mov', 'moved'))]
    counts = [(n, w) for n, w in counts if n]
    if not counts:
        return 'section id renamed'
    (n0, w0), rest = counts[0], counts[1:]
    tip = '%d block%s %s' % (n0, '' if n0 == 1 else 's', w0)
    return ', '.join([tip] + ['%d %s' % (n, w) for n, w in rest])


def mark_toc(page, sections):
    """Wrap each changed section's NUMBER in ToC links, never the title.

    Inline diffs in titles keep working because only the leading number
    token is wrapped. Returns the page with the spans inserted.
    """
    if not sections:
        return page
    walk = _TocWalk(page)
    walk.feed(page)
    walk.close()
    regions = walk.regions
    out, pos = [], 0
    for r0, r1 in regions:
        out.append(page[pos:r0])
        chunks, bpos = [], r0
        for lm in TOC_LINK.finditer(page, r0, r1):
            entry = sections.get(lm.group(1))
            if not entry or entry.get('status') not in TOC_CLASSES:
                continue
            nm = TOC_NUMBER.match(page, lm.end())
            if not nm:
                continue
            chunks.append(page[bpos:nm.start(1)])
            chunks.append('<span class="%s" title="%s">%s</span>'
                          % (TOC_CLASSES[entry['status']], toc_tip(entry),
                             nm.group(1)))
            bpos = nm.end(1)
        chunks.append(page[bpos:r1])
        out.append(''.join(chunks))
        pos = r1
    out.append(page[pos:])
    return ''.join(out)


class _CellPurity(HTMLParser):
    """Whether a table cell holds only added (or only deleted) material.

    Text outside same-kind change wrappers, or any other-kind change
    markup, makes the cell impure. Whitespace-only cells are empty.
    """

    def __init__(self, kind):
        super().__init__(convert_charrefs=True)
        self.kind = kind
        # One entry per open span/div: whether it is a same-kind wrapper.
        # A counter is not enough: the end tag of a nested inline span
        # must not close the wrapper around the text after it.
        self.stack = []
        self.pure = True
        self.has_text = False

    def handle_starttag(self, tag, attrs):
        if tag not in ('span', 'div'):
            return
        classes = dict(attrs).get('class', '').split()
        if self.kind in classes:
            self.stack.append(True)
        else:
            if ('added' in classes or 'deleted' in classes
                    or 'changed' in classes):
                self.pure = False
            self.stack.append(False)

    def handle_endtag(self, tag):
        if tag in ('span', 'div') and self.stack:
            self.stack.pop()

    def handle_data(self, data):
        if not data.strip():
            return
        if any(self.stack):
            self.has_text = True
        else:
            self.pure = False


def _cell_status(inner):
    """'added'/'deleted' when the cell holds only that kind of material."""
    for kind in ('added', 'deleted'):
        probe = _CellPurity(kind)
        try:
            probe.feed(inner)
            probe.close()
        except Exception:
            return None
        if probe.pure and probe.has_text:
            return kind
    return None


def _walk_tables(page):
    walk = _TableWalk(page)
    walk.feed(page)
    walk.close()
    return walk.rows


def mark_rows(page):
    """Mark fully added or deleted table rows as one unit.

    Only the innermost row whose own cells are all added (or all
    deleted) gets the mark: a layout row that merely contains a changed
    nested table never does, and neither does a row inside an
    interlinear-gloss table, whose per-word cells must keep working.
    A cell with no text counts as empty even when it carries same-kind
    change markup (a new cmavo entry whose series cell is empty still
    collapses); a cell holding other-kind change markup is never empty.
    The tr gets diff-row-added (or diff-row-deleted) and its first
    direct cell gets diff-row-first, so the stylesheet can paint one
    background with a single left bar instead of styling each cell
    separately.
    """
    edits = []
    for row in _walk_tables(page):
        if row['nested'] or row['gloss'] or not row['tds']:
            continue
        if row['classes'] & ROW_CLASSES_NEVER_MARKED:
            continue
        if 'diff-row-added' in row['classes'] or 'diff-row-deleted' in row['classes']:
            continue
        kinds = set()
        seen = False
        pending = []
        for td in row['tds']:
            inner = page[td['open_end']:td['close'] or td['open_end']]
            if _cell_text(inner):
                status = _cell_status(inner)
                if status is None:
                    break
                kinds.add(status)
                seen = True
            else:
                pending.append(inner)
        else:
            if not seen or len(kinds) != 1:
                continue
            kind = kinds.pop()
            blank = True
            for inner in pending:
                probe = _CellPurity(kind)
                try:
                    probe.feed(inner)
                    probe.close()
                except Exception:
                    blank = False
                    break
                if not (probe.pure and not probe.has_text):
                    blank = False
                    break
            if not blank:
                continue
            edits.append((row['start'], row['start'] + len(row['open']),
                          _add_class(row['open'], 'diff-row-%s' % kind)))
            first = row['tds'][0]
            edits.append((first['start'], first['start'] + len(first['open']),
                          _add_class(first['open'], 'diff-row-first')))
            continue
    return _apply_edits(page, edits)


def collapse_row_marks(prefixed):
    """One prefixed marker per row-marked row, after its first cell."""
    edits = []
    for row in _walk_tables(prefixed):
        kind = ('added' if 'diff-row-added' in row['classes']
                else 'deleted' if 'diff-row-deleted' in row['classes'] else None)
        if kind is None or not row['tds'] or row['end'] is None:
            continue
        mark = '<span class="diffmark">%s</span>' % ROW_MARK[kind]
        first = row['tds'][0]
        inner = prefixed[first['open_end']:row['end']].replace(mark, '')
        edits.append((first['open_end'], row['end'], mark + inner))
    return _apply_edits(prefixed, edits)


def finish(argv):
    """docbook-diff.py finish BUILT_INDEX OUT_DIR --old-label X --new-label Y
    [--assets PREFIX] [--stats FILE]

    Turn the built xhtml_no_chunks page of an annotated tree into
    OUT_DIR/difference.html (with a banner explaining the marks) and
    OUT_DIR/difference_prefixed.html (the same, with a searchable text
    marker at the start of each outermost change: [+] added, [\u2212]
    deleted, [\u2192] moved). Links to assets/ and final.css are rewritten to
    PREFIX (the version's own xhtml_no_chunks), so they are not copied."""
    ap = argparse.ArgumentParser(prog='docbook-diff.py finish')
    ap.add_argument('index')
    ap.add_argument('outdir')
    ap.add_argument('--old-label', required=True)
    ap.add_argument('--new-label', required=True)
    ap.add_argument('--assets', default='')
    ap.add_argument('--stats')
    a = ap.parse_args(argv)
    page = Path(a.index).read_text(encoding='utf-8')
    page = page.replace(' manifest="cll.appcache"', '')
    if a.assets:
        page = re.sub(r'(\s(?:src|href))="(assets/|final\.css")',
                      lambda m: '%s="%s%s' % (m.group(1), a.assets, m.group(2)), page)
    esc = lambda x: x.replace('&', '&amp;').replace('<', '&lt;')
    counts = ''
    sections = {}
    if a.stats:
        st = json.loads(Path(a.stats).read_text())
        k = st.get('statuses', {})
        counts = (' Blocks (paragraphs, example lines, table rows, list entries, titles): '
                  '%d changed, %d added, %d deleted, %d moved.'
                  % (k.get('chg', 0) // 2, k.get('ins', 0), k.get('del', 0),
                     (k.get('move', 0) + k.get('movechg', 0)) // 2))
        sections = st.get('sections', {})
    banner = (
        '<div class="diff-banner"><p><strong>Changes from %s to %s.</strong> '
        'This is the complete text of %s, with the changes since %s marked in place: '
        '<span class="added">added text</span>, '
        '<span class="deleted">deleted text</span> (kept where it was, struck through), and '
        '<span class="changed">notes where moved material used to be</span>, '
        'with a link to its new place. Moved material itself is not marked at its new place.%s '
        'In the table of contents, a light blue number (#a9c8ff) is a section that is '
        'mostly familiar material, changed (more than half of its blocks come from old '
        'text); a green number (#97f295) is a section to read as new text (half or less '
        'comes from old text, but it may hold a little moved or changed material); '
        'a pink number (#ffb6ba), struck through, is a deleted section (its text is kept '
        'below, struck through). '
        'The comparison is computed from the DocBook sources of the two versions, '
        'so it ignores differences that are only in the formatting.</p></div>'
        % (esc(a.old_label), esc(a.new_label), esc(a.new_label), esc(a.old_label), counts))
    page, n = re.subn(r'(<body\b[^>]*>)', lambda m: m.group(1) + banner, page, count=1)
    if not n:
        sys.exit('docbook-diff finish: no <body> in %s' % a.index)
    page = mark_rows(mark_toc(page, sections))
    out = Path(a.outdir)
    out.mkdir(parents=True, exist_ok=True)
    (out / 'difference.html').write_text(page, encoding='utf-8')
    # prefixed variant: a marker after the opening tag of each outermost change
    res, pos, stack, depth = [], 0, [], 0
    body = page.index(banner) + len(banner)
    res.append(page[:body])
    pos = body
    for m in FLAG_TAG.finditer(page, body):
        close, tag, attrs, selfclose = m.group(1), m.group(2), m.group(3), m.group(4)
        if close:
            if stack:
                if stack.pop():
                    depth -= 1
            continue
        cm = re.search(r'\bclass="(added|deleted|changed)"', attrs)
        tm = (not cm and tag == 'span' and
              re.search(r'\bclass="diff-toc-(added|deleted|changed)"', attrs))
        if selfclose:
            continue
        stack.append(bool(cm))
        if cm and depth == 0:
            res.append(page[pos:m.end()])
            res.append('<span class="diffmark">%s</span>' % MARKS[cm.group(1)])
            pos = m.end()
        elif tm and depth == 0:
            res.append(page[pos:m.start()])
            res.append('<span class="diffmark">%s</span>' % TOC_MARKS[tm.group(1)])
            pos = m.start()
        if cm:
            depth += 1
    res.append(page[pos:])
    # The prefixed page also explains its text markers, which the plain
    # page never shows.
    banner_pre = (banner[:-len('</p></div>')]
                  + ' In this version, a text marker comes before each change: '
                  '[+] added, [\u2212] deleted, [\u2192] moved; in the table '
                  'of contents, [*] marks a changed section.</p></div>')
    (out / 'difference_prefixed.html').write_text(
        collapse_row_marks(''.join(res)).replace(banner, banner_pre, 1),
        encoding='utf-8')


if __name__ == '__main__':
    if len(sys.argv) > 1 and sys.argv[1] == 'finish':
        finish(sys.argv[2:])
    else:
        main()
