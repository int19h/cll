#!/usr/bin/env python3
"""Keep inline spaces through the production Nokogiri parsers."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
EXPECTED = {
    'quotes': "the error-correction quotes lo'ai, sa'ai, and le'ai",
    'connective': 'ga nai - gi',
}
XHTML = '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Transitional//EN" "dtd/xhtml1-transitional.dtd">
<html xmlns="http://www.w3.org/1999/xhtml"><head><meta http-equiv="Content-Type" content="text/html; charset=UTF-8" /><title>Spaces</title></head><body>
<p id="quotes"><a class="indexterm" id="index"/>the <span><em>error-correction quotes</em></span> <span>lo'ai</span>, sa'ai, and le'ai</p>
<table><tr><td id="connective"><span>ga</span> <span>nai</span> - <span>gi</span></td></tr></table>
</body></html>'''
DOCBOOK = '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE book SYSTEM "dtd/docbook-5.0.dtd">
<book xmlns="http://docbook.org/ns/docbook"><chapter><title>Spaces</title>
<para xml:id="quotes"><anchor xml:id="index"/>the <phrase><emphasis>error-correction quotes</emphasis></phrase> <phrase>lo'ai</phrase>, sa'ai, and le'ai</para>
<informaltable><tr><td xml:id="connective"><phrase>ga</phrase> <phrase>nai</phrase> - <phrase>gi</phrase></td></tr></informaltable>
</chapter></book>'''


def samples(document):
    root = ET.fromstring(document)
    return {e.get('id', e.get('{http://www.w3.org/XML/1998/namespace}id')):
            ''.join(e.itertext()) for e in root.iter()
            if e.get('id', e.get('{http://www.w3.org/XML/1998/namespace}id')) in EXPECTED}


class NokogiriSpaces(unittest.TestCase):
    def test_production_parsers(self):
        with tempfile.TemporaryDirectory(prefix='cll-nokogiri-spaces-') as temporary:
            directory = Path(temporary)
            shutil.copytree(ROOT / 'dtd', directory / 'dtd')
            for name, sample in (
                ('xml_prince_postprocess.rb', XHTML),
                ('xhtml_postprocess_cleanup_file.rb', XHTML),
                ('xml_preprocess.rb', DOCBOOK),
            ):
                with self.subTest(script=name):
                    source = directory / 'sample.xml'
                    source.write_text(sample)
                    self.assertEqual(samples(sample), EXPECTED)
                    env = os.environ.copy()
                    if name == 'xhtml_postprocess_cleanup_file.rb':
                        # This check is the unformatted write. Indent is tested
                        # in scripts/test-html-format.rb (issue #207).
                        env['CLL_HTML_FORMAT'] = 'none'
                    result = subprocess.run(
                        ['ruby', str(ROOT / 'scripts' / name), str(source)],
                        cwd=ROOT, capture_output=True, check=True, env=env,
                    )
                    self.assertEqual(samples(result.stdout), EXPECTED)
                    if name == 'xhtml_postprocess_cleanup_file.rb':
                        before = directory / 'before.html'
                        after = directory / 'after.html'
                        before.write_text(sample)
                        after.write_bytes(result.stdout)
                        guard = subprocess.run(
                            ['ruby', str(ROOT / 'scripts/html_whitespace_guard.rb'),
                             '--strict', str(before), str(after)],
                            cwd=ROOT, capture_output=True, text=True,
                        )
                        self.assertEqual(guard.returncode, 0, guard.stderr)
                    if name == 'xml_prince_postprocess.rb':
                        body = ET.fromstring(result.stdout).find('{*}body')
                        self.assertEqual(body.text, '\n')


if __name__ == '__main__':
    subprocess.run(['ruby', '-rnokogiri', '-e',
                    'puts "Nokogiri #{Nokogiri::VERSION}, libxml2 #{Nokogiri::LIBXML_LOADED_VERSION}"'],
                   check=True)
    unittest.main()
