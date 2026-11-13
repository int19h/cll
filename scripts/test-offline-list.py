#!/usr/bin/env python3
"""The offline generator lists the files a book folder actually uses.

Run: python3 scripts/test-offline-list.py
"""
import base64
import hashlib
import json
import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
GENERATOR = ROOT / 'scripts' / 'xhtml_postprocess_offline.rb'
TEMPLATE = ROOT / 'scripts' / 'sw.template.js'

BUILD_RE = re.compile(r"const BUILD = '([0-9a-f]{16})'")
PRECACHE_RE = re.compile(r'const PRECACHE = (\[[\s\S]*?\n\]);')
LAZY_RE = re.compile(r'const LAZY = new Set\((\[.*\])\);')

EXPECTED = [
    'assets/fonts/a.otf',
    'assets/media/picture.png',
    'assets/scripts/offline.js',
    'final.css',
    'index.html',
    'other.html',
]
LAZY = ['assets/fonts/noto-cjk-x.otf']


def write_book(folder):
    folder.mkdir(parents=True)
    (folder / 'index.html').write_text(
        '<!DOCTYPE html><html><head>'
        '<link rel="stylesheet" href="./final.css">'
        '<script src="assets/scripts/offline.js"></script>'
        '<script src="https://cdn.example/lib.js"></script>'
        '<script src="//cdn.example/other.js"></script>'
        '</head><body><a href="#section">jump</a>'
        '<img src="assets/media/picture.png">'
        '<h2 style="clear: both">title</h2>'
        '<style>h2 { color: black; /* url("assets/fonts/missing.otf") */ }</style>'
        '</body></html>\n',
        encoding='utf-8')
    (folder / 'other.html').write_text(
        '<!DOCTYPE html><html><body>'
        '<img src="assets/media/picture.png#frag">'
        '</body></html>\n',
        encoding='utf-8')
    (folder / 'final.css').write_text(
        '@font-face { src: url("./assets/fonts/a.otf"); }\n'
        '@font-face { src: url(./assets/fonts/noto-cjk-x.otf); }\n',
        encoding='utf-8')
    for relative, text in (
            ('assets/fonts/a.otf', 'font-a'),
            ('assets/fonts/noto-cjk-x.otf', 'font-cjk'),
            ('assets/scripts/offline.js', '/* register */\n'),
            ('assets/media/picture.png', 'png'),
            ('assets/context/unused.tex', 'unused'),
    ):
        path = folder / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding='utf-8')


def run(folder, template=TEMPLATE, args=()):
    return subprocess.run(
        ['ruby', str(GENERATOR), *args, str(folder), str(template)],
        cwd=ROOT, capture_output=True, text=True)


def parse_worker(text):
    build = BUILD_RE.search(text)
    precache = PRECACHE_RE.search(text)
    lazy = LAZY_RE.search(text)
    if not build or not precache or not lazy:
        raise AssertionError('sw.js is missing BUILD, PRECACHE, or LAZY')
    return (
        build.group(1),
        json.loads(precache.group(1)),
        json.loads(lazy.group(1)),
    )


def integrity(folder, relative):
    digest = hashlib.sha256((folder / relative).read_bytes()).digest()
    return 'sha256-' + base64.b64encode(digest).decode()


def expected_hash(folder, template_text, lazy_names=LAZY):
    entries = [[name, integrity(folder, name)] for name in EXPECTED]
    lazy_entries = [[name, integrity(folder, name)] for name in lazy_names]
    payload = json.dumps([entries, lazy_entries, template_text], separators=(',', ':'))
    return hashlib.sha256(payload.encode()).hexdigest()[:16]


class OfflineListTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.folder = Path(self.tmp.name) / 'book'
        write_book(self.folder)
        self.template_text = TEMPLATE.read_text(encoding='utf-8')

    def tearDown(self):
        self.tmp.cleanup()

    def test_list_integrity_and_stable_hash(self):
        pages = {
            name: (self.folder / name).read_bytes()
            for name in ('index.html', 'other.html')
        }
        first = run(self.folder)
        self.assertEqual(first.returncode, 0, first.stderr)
        worker_path = self.folder / 'sw.js'
        text = worker_path.read_text(encoding='utf-8')
        build, precache, lazy = parse_worker(text)
        paths = [entry[0] for entry in precache]
        self.assertEqual(paths, EXPECTED)
        self.assertEqual(lazy, LAZY)
        self.assertNotIn('sw.js', paths + lazy)
        self.assertNotIn('assets/context/unused.tex', paths + lazy)
        for path, value in precache:
            self.assertEqual(value, integrity(self.folder, path), path)
        self.assertEqual(build, expected_hash(self.folder, self.template_text))
        for token in ('@BUILD@', '@PRECACHE@', '@LAZY@'):
            self.assertNotIn(token, text)
        self.assertIn(build, first.stdout)
        self.assertIn('2 pages', first.stdout)
        self.assertIn('6 files', first.stdout)
        self.assertIn('1 lazy', first.stdout)
        for name, content in pages.items():
            self.assertEqual((self.folder / name).read_bytes(), content)

        second = run(self.folder)
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(worker_path.read_bytes(), text.encode())

        verified = run(self.folder, args=('--verify',))
        self.assertEqual(verified.returncode, 0, verified.stderr)
        self.assertEqual(worker_path.read_bytes(), text.encode())
        self.assertIn(build, verified.stdout)

    def test_page_or_template_change_changes_the_hash(self):
        self.assertEqual(run(self.folder).returncode, 0)
        worker_path = self.folder / 'sw.js'
        original = worker_path.read_bytes()
        build, _, _ = parse_worker(original.decode())

        index = self.folder / 'index.html'
        index.write_text(index.read_text(encoding='utf-8') + '<!-- x -->\n', encoding='utf-8')
        stale = run(self.folder, args=('--verify',))
        self.assertEqual(stale.returncode, 1)
        self.assertIn('does not match', stale.stderr)
        self.assertEqual(worker_path.read_bytes(), original)

        changed = run(self.folder)
        self.assertEqual(changed.returncode, 0, changed.stderr)
        new_build, _, _ = parse_worker(worker_path.read_text(encoding='utf-8'))
        self.assertNotEqual(new_build, build)
        self.assertEqual(new_build, expected_hash(self.folder, self.template_text))

        edited = Path(self.tmp.name) / 'template.js'
        edited.write_text(self.template_text + '\n/* changed */\n', encoding='utf-8')
        retimed = run(self.folder, template=edited)
        self.assertEqual(retimed.returncode, 0, retimed.stderr)
        timed_build, _, _ = parse_worker(worker_path.read_text(encoding='utf-8'))
        self.assertNotEqual(timed_build, new_build)

    def test_lazy_bytes_change_the_hash(self):
        self.assertEqual(run(self.folder).returncode, 0)
        worker_path = self.folder / 'sw.js'
        build, _, lazy_paths = parse_worker(worker_path.read_text(encoding='utf-8'))
        self.assertEqual(lazy_paths, LAZY)
        font = self.folder / LAZY[0]
        font.write_bytes(font.read_bytes() + b'x')
        changed = run(self.folder)
        self.assertEqual(changed.returncode, 0, changed.stderr)
        new_build, precache, new_lazy = parse_worker(worker_path.read_text(encoding='utf-8'))
        self.assertEqual(new_lazy, LAZY)
        self.assertEqual([entry[0] for entry in precache], EXPECTED)
        self.assertNotEqual(new_build, build)
        self.assertEqual(new_build, expected_hash(self.folder, self.template_text))

    def test_missing_file_names_the_file_and_writes_nothing(self):
        index = self.folder / 'index.html'
        index.write_text(
            index.read_text(encoding='utf-8').replace(
                '</head>', '<script src="assets/scripts/missing.js"></script></head>'),
            encoding='utf-8')
        result = run(self.folder)
        self.assertEqual(result.returncode, 1)
        self.assertIn('assets/scripts/missing.js', result.stderr)
        self.assertFalse((self.folder / 'sw.js').exists())

    def test_space_in_a_name_is_an_error(self):
        spaced = self.folder / 'assets' / 'media' / 'my file.png'
        spaced.write_text('png', encoding='utf-8')
        index = self.folder / 'index.html'
        index.write_text(
            index.read_text(encoding='utf-8').replace(
                '</body>', '<img src="assets/media/my file.png"></body>'),
            encoding='utf-8')
        result = run(self.folder)
        self.assertEqual(result.returncode, 1)
        self.assertIn('my file.png', result.stderr)
        self.assertFalse((self.folder / 'sw.js').exists())

    def test_budget(self):
        too_small = run(self.folder, args=('--budget', '10'))
        self.assertEqual(too_small.returncode, 1)
        self.assertIn('budget', too_small.stderr)
        self.assertFalse((self.folder / 'sw.js').exists())

        self.assertEqual(run(self.folder).returncode, 0)
        original = (self.folder / 'sw.js').read_bytes()
        size = sum((self.folder / name).stat().st_size for name in EXPECTED)
        exact = run(self.folder, args=('--budget', str(size)))
        self.assertEqual(exact.returncode, 0, exact.stderr)
        self.assertEqual((self.folder / 'sw.js').read_bytes(), original)
        over = run(self.folder, args=('--budget', str(size - 1)))
        self.assertEqual(over.returncode, 1)
        self.assertIn('budget', over.stderr)
        self.assertEqual((self.folder / 'sw.js').read_bytes(), original)

    def test_default_budget_is_20_mib(self):
        budget = 20 * 1024 * 1024
        index = self.folder / 'index.html'
        index.write_text(
            index.read_text(encoding='utf-8').replace(
                '</body>', '<img src="assets/media/big.bin"></body>'),
            encoding='utf-8')
        others = sum((self.folder / name).stat().st_size for name in EXPECTED)
        big = self.folder / 'assets' / 'media' / 'big.bin'
        big.write_bytes(b'')
        os.truncate(big, budget - others)
        exact = run(self.folder)
        self.assertEqual(exact.returncode, 0, exact.stderr)
        original = (self.folder / 'sw.js').read_bytes()
        os.truncate(big, budget - others + 1)
        over = run(self.folder)
        self.assertEqual(over.returncode, 1)
        self.assertIn('budget', over.stderr)
        self.assertIn(str(budget), over.stderr)
        self.assertEqual((self.folder / 'sw.js').read_bytes(), original)

    def test_css_parent_path_stays_inside_the_folder(self):
        css = self.folder / 'assets' / 'css' / 'extra.css'
        css.parent.mkdir(parents=True)
        css.write_text('body { background: url("../fonts/a.otf"); }\n', encoding='utf-8')
        index = self.folder / 'index.html'
        index.write_text(
            index.read_text(encoding='utf-8').replace(
                '</head>', '<link rel="stylesheet" href="assets/css/extra.css"></head>'),
            encoding='utf-8')
        result = run(self.folder)
        self.assertEqual(result.returncode, 0, result.stderr)
        _, precache, _ = parse_worker((self.folder / 'sw.js').read_text(encoding='utf-8'))
        paths = [entry[0] for entry in precache]
        self.assertIn('assets/fonts/a.otf', paths)
        self.assertIn('assets/css/extra.css', paths)
        self.assertTrue(all('..' not in path for path in paths))

    def test_css_path_that_escapes_the_folder_is_an_error(self):
        (self.folder / 'final.css').write_text(
            'body { background: url("../outside.otf"); }\n', encoding='utf-8')
        result = run(self.folder)
        self.assertEqual(result.returncode, 1)
        self.assertIn('escapes', result.stderr)
        self.assertFalse((self.folder / 'sw.js').exists())

    def test_template_without_a_placeholder_writes_nothing(self):
        broken = Path(self.tmp.name) / 'broken.js'
        broken.write_text(self.template_text.replace('@LAZY@', '[]'), encoding='utf-8')
        result = run(self.folder, template=broken)
        self.assertEqual(result.returncode, 1)
        self.assertIn('@LAZY@', result.stderr)
        self.assertFalse((self.folder / 'sw.js').exists())

    def test_verify_without_a_worker_fails(self):
        result = run(self.folder, args=('--verify',))
        self.assertEqual(result.returncode, 1)
        self.assertFalse((self.folder / 'sw.js').exists())

    def test_root_relative_reference_is_an_error(self):
        index = self.folder / 'index.html'
        original = index.read_text(encoding='utf-8')
        index.write_text(
            original.replace('assets/media/picture.png', '/assets/media/picture.png'),
            encoding='utf-8')
        result = run(self.folder)
        self.assertEqual(result.returncode, 1)
        self.assertIn('/assets/media/picture.png', result.stderr)
        self.assertIn('root-relative', result.stderr)
        self.assertFalse((self.folder / 'sw.js').exists())

        index.write_text(original, encoding='utf-8')
        (self.folder / 'final.css').write_text(
            'body { background: url("/assets/fonts/a.otf"); }\n', encoding='utf-8')
        css_result = run(self.folder)
        self.assertEqual(css_result.returncode, 1)
        self.assertIn('/assets/fonts/a.otf', css_result.stderr)
        self.assertIn('final.css', css_result.stderr)
        self.assertFalse((self.folder / 'sw.js').exists())

    def test_url_inside_a_css_comment_is_ignored(self):
        css = self.folder / 'final.css'
        css.write_text(
            '/* url("./assets/fonts/missing.otf")\n'
            '   url(/also-missing.otf) */\n'
            + css.read_text(encoding='utf-8'),
            encoding='utf-8')
        result = run(self.folder)
        self.assertEqual(result.returncode, 0, result.stderr)
        _, precache, _ = parse_worker((self.folder / 'sw.js').read_text(encoding='utf-8'))
        paths = [entry[0] for entry in precache]
        self.assertNotIn('assets/fonts/missing.otf', paths)
        self.assertNotIn('also-missing.otf', paths)

    def test_unread_reference_forms_are_errors(self):
        index = self.folder / 'index.html'
        original = index.read_text(encoding='utf-8')
        cases = [
            ('srcset', original.replace(
                '</body>',
                '<img src="assets/media/picture.png" srcset="assets/media/picture.png 2x"></body>'),
             'srcset'),
            ('source', original.replace(
                '</body>', '<video><source src="clip.mp4"></video></body>'),
             'source element'),
            ('object', original.replace(
                '</body>', '<object data="assets/media/picture.png"></object></body>'),
             'object element'),
            ('embed', original.replace(
                '</body>', '<embed src="assets/media/picture.png"></body>'),
             'embed element'),
            ('style attribute', original.replace(
                '</body>', '<p style="background: url(assets/media/picture.png)"></p></body>'),
             'style attribute'),
            ('style element', original.replace(
                '</body>', '<style>@import "extra.css";</style></body>'),
             'style element'),
        ]
        for name, text, needle in cases:
            with self.subTest(name=name):
                index.write_text(text, encoding='utf-8')
                result = run(self.folder)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn(needle, result.stderr)
                self.assertFalse((self.folder / 'sw.js').exists())
        index.write_text(original, encoding='utf-8')
        css = self.folder / 'final.css'
        css.write_text(css.read_text(encoding='utf-8') + '@import "extra.css";\n', encoding='utf-8')
        imported = run(self.folder)
        self.assertEqual(imported.returncode, 1)
        self.assertIn('unread @import', imported.stderr)
        self.assertIn('final.css', imported.stderr)
        self.assertFalse((self.folder / 'sw.js').exists())


if __name__ == '__main__':
    unittest.main()
