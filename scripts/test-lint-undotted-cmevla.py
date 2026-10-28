#!/usr/bin/env python3
"""Exercise dotside lint with live elements and source line numbers."""
import pathlib
import subprocess
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).with_name('lint-undotted-cmevla.py')


class DotsideTests(unittest.TestCase):
    def lint(self, xml, name='fixture.xml'):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / name
            path.write_text(xml, encoding='utf-8')
            return subprocess.run(['python3', str(SCRIPT), str(path)], text=True, capture_output=True)

    def test_comments_and_literal_markup(self):
        result = self.lint('''<chapter><!-- <jbo>la djan klama</jbo> -->
<![CDATA[<jbo>la djan klama</jbo>]]>
<para>&lt;jbo&gt;la djan klama&lt;/jbo&gt;</para></chapter>''')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_live_elements_and_lines(self):
        for tag in ('jbo', 'jbophrase', 'valsi'):
            result = self.lint(f'<chapter>\n<{tag} role="test">la <emphasis>djan</emphasis> klama</{tag}></chapter>')
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertIn(':2: undotted cmevla? «la djan»', result.stdout)

    def test_dotted_names_and_entities(self):
        result = self.lint('<chapter><jbo>la .djan. klama &ndash; la cribe</jbo></chapter>')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_comments_do_not_consume_allowance(self):
        result = self.lint('<chapter><!-- <jbo>la djan</jbo> --><jbo>la djan</jbo></chapter>', '11.xml')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()
