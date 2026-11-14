#!/usr/bin/env python3
"""Check duplicate ids and relative links in HTML pages.

A relative href must name a file next to the page, and a fragment must
name an id in that file. External links are left alone.
"""
import sys
import xml.etree.ElementTree as ET
from pathlib import Path
from urllib.parse import unquote, urlsplit

SKIP_SCHEMES = {'http', 'https', 'mailto', 'data'}


def pages_under(path):
    path = Path(path)
    if path.is_file():
        return [path]
    if not path.is_dir():
        return []
    found = []
    for child in path.rglob('*'):
        # cll-weasyprint.html is the renderer's working copy, not a contract page.
        if child.is_file() and child.suffix in {'.html', '.xhtml'} and child.name != 'cll-weasyprint.html':
            found.append(child)
    return sorted(found)


def local_name(tag):
    return tag.rsplit('}', 1)[-1]


def href_values(element):
    values = []
    for key, value in element.attrib.items():
        name = local_name(key)
        if name == 'href':
            values.append(value)
    return values


def collect_ids(root):
    found = []
    for element in root.iter():
        if 'id' in element.attrib:
            found.append(element.attrib['id'])
    return found


def main(argv):
    if not argv:
        print('usage: python3 scripts/check-html-links.py FILE_OR_DIRECTORY...', file=sys.stderr)
        return 2
    files = []
    for arg in argv:
        files.extend(pages_under(arg))
    if not files:
        print('no HTML pages', file=sys.stderr)
        return 1
    bad = 0
    id_maps = {}
    trees = {}
    for path in files:
        try:
            root = ET.parse(path).getroot()
        except ET.ParseError as error:
            print(f'{path}: {error}', file=sys.stderr)
            bad += 1
            continue
        ids = collect_ids(root)
        seen = set()
        reported = set()
        for item in ids:
            if item in seen and item not in reported:
                print(f'{path}: duplicate id {item}', file=sys.stderr)
                reported.add(item)
                bad += 1
            seen.add(item)
        resolved = path.resolve()
        id_maps[resolved] = seen
        trees[resolved] = root
    for path, root in trees.items():
        for element in root.iter():
            for href in href_values(element):
                raw = href.strip()
                if raw == '':
                    print(f'{path}: empty href on {local_name(element.tag)}', file=sys.stderr)
                    bad += 1
                    continue
                parts = urlsplit(raw)
                if parts.scheme in SKIP_SCHEMES or parts.scheme or raw.startswith('//'):
                    continue
                if parts.path:
                    target = (path.parent / unquote(parts.path)).resolve()
                else:
                    target = path
                fragment = parts.fragment
                if not target.is_file():
                    print(f'{path}: missing {raw}', file=sys.stderr)
                    bad += 1
                    continue
                if fragment and fragment not in id_maps.get(target, ()):
                    print(f'{path}: missing id {fragment} for {raw}', file=sys.stderr)
                    bad += 1
    print(f'files={len(files)} bad={bad}')
    return 0 if bad == 0 else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
