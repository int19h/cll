#!/usr/bin/env python3
"""Prepare CLL print XHTML, typeset mathematics, and paginate linked indexes."""
import argparse
import gc
import hashlib
import json
import logging
import os
from pathlib import Path
import shutil
import subprocess
from urllib.parse import unquote

from lxml import etree, html
from weasyprint import HTML, __version__ as weasyprint_version
from weasyprint.text.fonts import FontConfiguration
from weasyprint.urls import URLFetcher


def has_class(node, name):
    return name in node.get('class', '').split()


def normalize_spans(tree):
    """Replace the legacy 'span the entire table' sentinel with its width."""
    changed = 0
    for table in tree.iter('table'):
        rows = table.xpath('./tr | ./thead/tr | ./tbody/tr | ./tfoot/tr')
        if not any(cell.get('colspan') == '12321' for row in rows for cell in row):
            continue
        occupied = {}
        width = 1
        full = []
        for row_number, row in enumerate(rows):
            cells = [cell for cell in row if cell.tag in ('td', 'th')]
            sentinels = [cell for cell in cells if cell.get('colspan') == '12321']
            if sentinels:
                if len(cells) != 1 or sentinels[0].get('rowspan', '1') != '1':
                    raise ValueError('A full-width sentinel must occupy its own row')
                full.extend(sentinels)
                continue
            column = 0
            for cell in cells:
                while occupied.get(column, 0) > row_number:
                    column += 1
                colspan = int(cell.get('colspan', '1'))
                rowspan = int(cell.get('rowspan', '1')) or len(rows) - row_number
                if colspan < 1 or rowspan < 1:
                    raise ValueError('Invalid table span')
                for offset in range(colspan):
                    occupied[column + offset] = row_number + rowspan
                column += colspan
                width = max(width, column)
        for cell in full:
            cell.set('colspan', str(width))
            changed += 1
    return changed


def typeset_math(tree, directory):
    nodes = list(tree.iter('math'))
    if not nodes:
        return {'expressions': 0, 'version': None}
    inputs = [etree.tostring(node, encoding='unicode', with_tail=False) for node in nodes]
    try:
        result = subprocess.run(
            ['node', str(Path(__file__).with_name('mathjax.cjs'))],
            input=json.dumps(inputs), capture_output=True, text=True, check=True,
        )
    except subprocess.CalledProcessError as error:
        raise RuntimeError(f'MathJax conversion failed:\n{error.stderr}') from error
    rendered = json.loads(result.stdout)
    if len(rendered['expressions']) != len(nodes):
        raise ValueError('MathJax returned the wrong number of expressions')
    for node, expression in zip(nodes, rendered['expressions']):
        replacement = html.fragment_fromstring(expression)
        replacement.tail = node.tail
        # Preserve source anchors on the mathematical expression itself.
        if node.get('id'):
            replacement.set('id', node.get('id'))
        node.getparent().replace(node, replacement)
    shutil.copytree(rendered['fonts'], directory / 'mathjax-fonts', dirs_exist_ok=True)
    (directory / 'mathjax.css').write_text(rendered['css'])
    head = tree.find('head')
    head.append(etree.Element('link', rel='stylesheet', href='mathjax.css'))
    return {'expressions': len(nodes), 'version': rendered['version']}


def preserve_hidden_index_anchors(tree):
    """Keep metadata-only index targets at the hidden list's document location."""
    count = 0
    for hidden in list(tree.iter()):
        if not has_class(hidden, 'display-none'):
            continue
        if any(has_class(parent, 'display-none') for parent in hidden.iterancestors()):
            continue
        anchors = [node for node in hidden.iter('a') if node.get('id') and has_class(node, 'indexterm')]
        if not anchors:
            continue
        marker = etree.Element('div', {'class': 'index-markers'})
        hidden.addprevious(marker)
        for anchor in anchors:
            if ''.join(anchor.itertext()).strip():
                raise ValueError('An index metadata anchor contains hidden text')
            parent, previous = anchor.getparent(), anchor.getprevious()
            if previous is None:
                parent.text = (parent.text or '') + (anchor.tail or '')
            else:
                previous.tail = (previous.tail or '') + (anchor.tail or '')
            anchor.tail = None
            marker.append(anchor)
            count += 1
    return count


def collect_indexes(tree):
    """Keep index terms and see-also markup, replacing only page references."""
    groups = []
    for entry in tree.iter('dt'):
        if not any(has_class(parent, 'whole-index') for parent in entry.iterancestors()):
            continue
        links = [child for child in entry if child.tag == 'a' and has_class(child, 'indexterm')]
        if not links:
            continue
        positions = [entry.index(link) for link in links]
        if positions != list(range(positions[0], positions[-1] + 1)):
            raise ValueError('Unexpected markup between index page references')
        if any((link.tail or '').strip(' ,\n\t\r') for link in links[:-1]):
            raise ValueError('Unexpected text between index page references')
        targets = []
        for link in links:
            href = link.get('href', '')
            if not href.startswith('#'):
                raise ValueError(f'Nonlocal index reference: {href}')
            targets.append(unquote(href[1:]))
        span = etree.Element('span', {'class': 'index-pages'})
        span.text = '0'
        span.tail = links[-1].tail
        entry.insert(positions[0], span)
        for link in links:
            entry.remove(link)
        groups.append((span, targets))
    return groups


def page_ranges(targets, pages):
    """Sort and deduplicate pages, then retain links at both range endpoints."""
    by_page = {}
    for target in targets:
        if target not in pages:
            raise ValueError(f'Index target is missing from rendered pages: {target}')
        by_page.setdefault(pages[target], target)
    ranges = []
    for page in sorted(by_page):
        endpoint = (page, by_page[page])
        if ranges and page == ranges[-1][-1][0] + 1:
            ranges[-1] = (ranges[-1][0], endpoint)
        else:
            ranges.append((endpoint, endpoint))
    return ranges


def write_index(span, ranges):
    tail = span.tail
    span.clear()
    span.set('class', 'index-pages')
    span.tail = tail
    for index, (start, end) in enumerate(ranges):
        if index:
            span[-1].tail = ', '
        link = etree.SubElement(span, 'a', href='#' + start[1])
        link.text = str(start[0])
        if start[0] != end[0]:
            link.tail = '–'
            link = etree.SubElement(span, 'a', href='#' + end[1])
            link.text = str(end[0])


class RenderErrors(logging.Handler):
    def __init__(self):
        super().__init__(logging.ERROR)
        self.messages = []

    def emit(self, record):
        self.messages.append(record.getMessage())


def render(input_path, output_path, max_passes=6):
    tree = html.parse(str(input_path), parser=html.HTMLParser(encoding='utf-8')).getroot()
    directory = input_path.parent
    # lxml's HTML serializer removes legacy http-equiv encoding declarations.
    # Keep an HTML5 declaration for browsers and explicitly decode in WeasyPrint.
    tree.find('head').insert(0, etree.Element('meta', charset='utf-8'))
    # The input is already processed XHTML. Do not fetch its old external DTD.
    for script in list(tree.iter('script')):
        script.getparent().remove(script)
    spans = normalize_spans(tree)
    hidden_anchors = preserve_hidden_index_anchors(tree)
    math = typeset_math(tree, directory)
    tree.find('head').append(etree.Element('link', rel='stylesheet', href='weasyprint.css'))
    indexes = collect_indexes(tree)
    prepared = directory / 'cll-weasyprint.html'
    font_config = FontConfiguration()
    errors = RenderErrors()
    logger = logging.getLogger('weasyprint')
    logger.addHandler(errors)
    previous = None
    seen = set()
    try:
        for pass_number in range(1, max_passes + 1):
            prepared.write_bytes(html.tostring(tree, encoding='utf-8', doctype='<!doctype html>'))
            print(f'WeasyPrint pagination pass {pass_number}', flush=True)
            fetcher = URLFetcher(allowed_protocols=('file', 'data'), fail_on_errors=True)
            document = HTML(filename=str(prepared), encoding='utf-8', url_fetcher=fetcher).render(font_config=font_config)
            if errors.messages:
                raise RuntimeError('WeasyPrint reported errors:\n' + '\n'.join(errors.messages))
            pages = {anchor: number for number, page in reversed(list(enumerate(document.pages, 1)))
                     for anchor in page.anchors}
            ranges = [page_ranges(targets, pages) for _, targets in indexes]
            signature = json.dumps(ranges)
            if not indexes or signature == previous:
                temporary = output_path.with_suffix('.pdf.tmp')
                try:
                    document.write_pdf(str(temporary))
                    if errors.messages:
                        raise RuntimeError('PDF writing failed:\n' + '\n'.join(errors.messages))
                    os.replace(temporary, output_path)
                finally:
                    temporary.unlink(missing_ok=True)
                report = {
                    'pages': len(document.pages), 'passes': pass_number,
                    'weasyprint': weasyprint_version,
                    'input_sha256': hashlib.sha256(input_path.read_bytes()).hexdigest(),
                    'prepared_sha256': hashlib.sha256(prepared.read_bytes()).hexdigest(),
                    'normalized_spans': spans, 'mathjax': math,
                    'relocated_hidden_index_anchors': hidden_anchors,
                    'index_entries': len(indexes),
                    'index_targets': {target: pages[target] for _, targets in indexes for target in targets},
                }
                (directory / 'render-report.json').write_text(json.dumps(report, indent=2) + '\n')
                print(f'Wrote {output_path}: {len(document.pages)} pages', flush=True)
                return report
            if signature in seen:
                raise RuntimeError('Index pagination oscillates instead of converging')
            seen.add(signature)
            previous = signature
            for (span, _), entries in zip(indexes, ranges):
                write_index(span, entries)
            del document
            gc.collect()
        raise RuntimeError(f'Index pagination did not converge after {max_passes} passes')
    finally:
        logger.removeHandler(errors)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('input', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    logging.basicConfig(level=logging.WARNING)
    render(args.input.resolve(), args.output.resolve())
