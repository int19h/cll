#!/usr/bin/env python3
"""Title-page credits stay siblings in the PDF bookmark tree.

The author heading and the two other title-page credits share the book
title as their parent. A later subsection still nests under its section,
and an index letter heading stays out of the outline.

A bookmark's parent is the nearest preceding bookmark with a lower level.
The WeasyPrint check renders the fixture with the print stylesheets.
The Prince check does the same when the prince binary and pymupdf are
both available.
"""
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TITLE = 'The Contemporary Lojban Language'
AUTHOR = 'John Woldemar Cowan'
REVISED = 'revised by the Lojban community'
PUBLISHER = '(not a Logical Language Group publication)'
CHAPTER = 'Chapter 1'
SECTION = 'What is Lojban?'
SUBSECTION = 'Sounds'
INDEX_LETTER = 'A'

EXPECTED = [
    (1, TITLE, None),
    (2, AUTHOR, TITLE),
    (2, REVISED, TITLE),
    (2, PUBLISHER, TITLE),
    (1, CHAPTER, None),
    (2, SECTION, CHAPTER),
    (3, SUBSECTION, SECTION),
]


def parents_of(rows):
    """Return (level, title, page, parent title) from a flat outline."""
    stack = []
    result = []
    for level, title, page in rows:
        while stack and stack[-1][0] >= level:
            stack.pop()
        parent = stack[-1][1] if stack else None
        result.append((level, title, page, parent))
        stack.append((level, title))
    return result


def write_fixture(directory, stylesheets):
    links = '\n'.join(
        f'<link rel="stylesheet" href="{path.resolve().as_uri()}">'
        for path in stylesheets)
    html_path = directory / 'fixture.html'
    html_path.write_text(f'''<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
{links}
<style>@page {{ size: A4; margin: 12mm; }}</style>
</head>
<body>
<div class="book">
  <div class="titlepage">
    <h1 class="title">{TITLE}</h1>
    <div class="author"><h2 class="author">{AUTHOR}</h2></div>
    <div class="othercredit"><h3 class="othercredit">{REVISED}</h3></div>
    <div class="othercredit"><h3 class="othercredit">{PUBLISHER}</h3></div>
  </div>
</div>
<h1>{CHAPTER}</h1>
<h2>{SECTION}</h2>
<h3>{SUBSECTION}</h3>
<div class="indexdiv"><h2>{INDEX_LETTER}</h2><p>alpha</p></div>
</body>
</html>
''')
    return html_path


def assert_outline(test, rows):
    titled = [
        (level, ' '.join(title.split()), page, parent)
        for level, title, page, parent in rows]
    test.assertNotIn(INDEX_LETTER, [title for _, title, _, _ in titled])
    outline = [(level, title, parent) for level, title, _, parent in titled]
    test.assertEqual(outline, EXPECTED)
    # The title page itself is page 1. Later headings may move when the
    # shared title-page margins are applied.
    for _level, title, page, _parent in titled[:4]:
        test.assertEqual(page, 1, title)


def weasyprint_html():
    try:
        from weasyprint import HTML
    except ImportError:
        return None
    return HTML


class BookmarkTests(unittest.TestCase):
    def test_one_pdf_engine_is_available(self):
        if weasyprint_html() is None and shutil.which('prince') is None:
            self.fail('Install WeasyPrint or Prince to check the bookmark tree')

    def test_weasyprint_title_page_credits_share_the_book_title(self):
        HTML = weasyprint_html()
        if HTML is None:
            self.skipTest('WeasyPrint is not installed')
        with tempfile.TemporaryDirectory(prefix='cll-bookmarks-') as temp:
            directory = Path(temp)
            html_path = write_fixture(directory, [
                ROOT / 'assets/css/master.css',
                ROOT / 'assets/css/weasyprint.css',
            ])
            document = HTML(filename=str(html_path)).render()
            rows = []

            def walk(nodes, level):
                for label, target, children, _state in nodes:
                    rows.append((level, str(label), target[0] + 1))
                    walk(children, level + 1)

            walk(document.make_bookmark_tree(), 1)
        assert_outline(self, parents_of(rows))

    @unittest.skipUnless(shutil.which('prince'), 'Prince is not installed')
    def test_prince_title_page_credits_share_the_book_title(self):
        try:
            import pymupdf
        except ImportError:
            self.skipTest('pymupdf is not installed')
        with tempfile.TemporaryDirectory(prefix='cll-bookmarks-') as temp:
            directory = Path(temp)
            html_path = write_fixture(directory, [
                ROOT / 'assets/css/master.css',
                ROOT / 'assets/css/prince.css',
            ])
            pdf_path = directory / 'fixture.pdf'
            result = subprocess.run(
                ['prince', '--no-network', str(html_path), '-o', str(pdf_path)],
                check=False, capture_output=True, text=True)
            if result.returncode != 0:
                self.fail(result.stderr or result.stdout)
            document = pymupdf.open(pdf_path)
            try:
                flat = [(level, title, page) for level, title, page, *_rest in document.get_toc()]
            finally:
                document.close()
        assert_outline(self, parents_of(flat))


if __name__ == '__main__':
    unittest.main()
