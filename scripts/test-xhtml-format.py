#!/usr/bin/env python3
"""Keep inline text through the production formatting command."""
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
SAMPLE = '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Transitional//EN" "dtd/xhtml1-transitional.dtd">
<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Spaces</title></head><body>
<p id="quotes"><a class="indexterm" id="index"/>the <span><em>error-correction quotes</em></span> <span>lo'ai</span>, sa'ai, and le'ai</p>
<table><tr><td id="connective"><span>ga</span> <span>nai</span> - <span>gi</span></td></tr></table>
</body></html>'''
EXPECTED = {
    'quotes': "the error-correction quotes lo'ai, sa'ai, and le'ai",
    'connective': 'ga nai - gi',
}


def text_by_id(document):
    root = ET.fromstring(document)
    return {e.get('id'): ''.join(e.itertext())
            for e in root.iter() if e.get('id') in EXPECTED}


class XhtmlFormat(unittest.TestCase):
    def test_production_pass_preserves_text(self):
        with tempfile.TemporaryDirectory(prefix='cll-format-') as temporary:
            directory = Path(temporary)
            shutil.copytree(ROOT / 'dtd', directory / 'dtd')
            sample = directory / 'sample.html'
            sample.write_text(SAMPLE)
            self.assertEqual(text_by_id(SAMPLE), EXPECTED)
            for name in ('cleanup',):
                script = ROOT / f'scripts/xhtml_postprocess_{name}.sh'
                commands = re.findall(r'^\s*(xmllint\s+[^\n]+)', script.read_text(), re.M)
                self.assertEqual(len(commands), 1, script)
                arguments = shlex.split(commands[0].split('>')[0])
                self.assertEqual(arguments[-1], '$file')
                # This assertion also catches a regression with newer libxml2,
                # whose no-DTD whitespace heuristic no longer loses this space.
                self.assertIn('--loaddtd', arguments, script)
                result = subprocess.run(arguments[:-1] + [str(sample)],
                                        cwd=directory, check=True, capture_output=True)
                self.assertEqual(text_by_id(result.stdout), EXPECTED, name)
                sample.write_bytes(result.stdout)


if __name__ == '__main__':
    subprocess.run(['xmllint', '--version'], check=True)
    unittest.main()
