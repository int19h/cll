#!/usr/bin/env python3
"""Exercise extraction with live XML and the chrestomathy layout."""
import pathlib
import subprocess
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).with_name('extract-examples.py')


class ExtractionTests(unittest.TestCase):
    def extract(self, xml, name='fixture.xml'):
        with tempfile.TemporaryDirectory(dir='/tmp') as directory:
            path = pathlib.Path(directory) / name
            path.write_text(xml, encoding='utf-8')
            result = subprocess.run(['python3', str(SCRIPT), str(path)], text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            return [line.split('\t')[1:] for line in result.stdout.splitlines()]

    def test_attributes_and_comments(self):
        self.assertEqual(self.extract('''<chapter>
<jbo role="pronunciation">mi klama</jbo>
<jbo valid="iffy">do klama</jbo><jbo valid="false">mi</jbo>
<!-- <jbo>la djan klama</jbo><jbophrase>hidden</jbophrase> -->
<![CDATA[<jbo>also hidden</jbo>]]>
<jbophrase role="test">ko klama</jbophrase></chapter>'''),
                         [['jbo-0', 'mi klama'], ['jbo-1', 'do klama'], ['jbo-2', 'mi'], ['phrase-0', 'ko klama']])

    def test_example_ids_and_inline_text(self):
        self.assertEqual(self.extract('''<chapter><example role="test" xml:id="c1e1">
<jbo>mi<emphasis> klama</emphasis> [vau]</jbo><jbo valid="iffy">do -- klama</jbo>
</example><jbo>zoi gy. a--b gy.</jbo><jbophrase>&lt;mi&gt; &amp; &ndash; &InvisibleTimes;</jbophrase></chapter>'''),
                         [['c1e1#0', 'mi klama vau'], ['c1e1#1', 'do klama'],
                          ['jbo-2', 'zoi gy. a--b gy.'], ['phrase-0', '<mi> & \u2062']])

    def test_chrestomathy(self):
        self.assertEqual(self.extract('''<chapter><section role="text" xml:id="passage">
<table><tr><td>lu mi</td><td>English</td></tr>
<!-- <tr><td>hidden</td></tr> -->
<tr><td><emphasis>klama</emphasis> li'u</td><td>English</td></tr></table>
</section></chapter>''', 'a01.xml'), [['passage', "lu mi klama li'u"]])


if __name__ == '__main__':
    unittest.main()
