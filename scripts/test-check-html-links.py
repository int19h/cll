#!/usr/bin/env python3
"""Fixture checks for the HTML link and id checker."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
CHECKER = ROOT / 'scripts/check-html-links.py'


def page(body, extra_head=''):
    return (
        '<!DOCTYPE html>'
        '<html xmlns="http://www.w3.org/1999/xhtml" lang="en" xml:lang="en">'
        '<head><title>T</title>'
        '<meta http-equiv="Content-Type" content="text/html; charset=utf-8" />'
        f'{extra_head}</head><body>{body}</body></html>'
    )


class LinkCheckTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='cll-links-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def write(self, name, text):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        return path

    def run_checker(self, *args):
        return subprocess.run(
            ['python3', str(CHECKER), *map(str, args)],
            text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)

    def test_relative_link_and_fragment(self):
        self.write('index.html', page('<p id="here"><a href="other.html#there">go</a></p>'))
        self.write('other.html', page('<p id="there">there</p>'))
        result = self.run_checker(self.root)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn('files=2 bad=0', result.stdout)

    def test_external_link_is_left_alone(self):
        self.write('index.html', page('<a href="https://lojban.org/cll">book</a>'))
        result = self.run_checker(self.root)
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_missing_target_and_duplicate_id(self):
        self.write('index.html', page('<a id="a"></a><a id="a"></a><a href="missing.html">x</a>'))
        result = self.run_checker(self.root)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('duplicate id a', result.stdout)
        self.assertIn('missing.html', result.stdout)

    def test_working_copy_is_skipped(self):
        self.write('index.html', page('<p id="here">ok</p>'))
        self.write('cll-weasyprint.html', '<not html')
        result = self.run_checker(self.root)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn('files=1 bad=0', result.stdout)

    def test_usage(self):
        result = self.run_checker()
        self.assertEqual(result.returncode, 2)


if __name__ == '__main__':
    unittest.main()
