#!/usr/bin/env python3
"""Self-test for scripts/lint-parallel-text.py (issue #348)."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
LINT = ROOT / 'scripts' / 'lint-parallel-text.py'

CASES = [
    ('ok-plain',
     '<appendix xml:id="volume-chrestomathy"><section><informaltable role="parallel-text"><tr><td>a</td></tr></informaltable></section></appendix>',
     0, None),
    ('ok-multi-token-and-spaces',
     '<appendix xml:id="volume-chrestomathy"><section><informaltable role=" noborder  parallel-text "><tr><td>a</td></tr></informaltable></section></appendix>',
     0, None),
    ('ok-inside-example-without-role',
     '<appendix xml:id="volume-chrestomathy"><example><title>t</title><informaltable><tr><td>a</td></tr></informaltable></example></appendix>',
     0, None),
    ('ok-other-chapter-informaltable',
     '<chapter xml:id="c1"><informaltable><tr><td>a</td></tr></informaltable></chapter>',
     0, None),
    ('ok-comment-and-entity',
     '<appendix xml:id="volume-chrestomathy"><!-- <informaltable/> --><para>a&ndash;b</para></appendix>',
     0, None),
    ('fail-missing-role',
     '<appendix xml:id="volume-chrestomathy"><section><informaltable><tr><td>a</td></tr></informaltable></section></appendix>',
     1, 'must carry role="parallel-text"'),
    ('fail-substring-role',
     '<appendix xml:id="volume-chrestomathy"><section><informaltable role="not-parallel-text"><tr><td>a</td></tr></informaltable></section></appendix>',
     1, 'must carry role="parallel-text"'),
    ('fail-wrong-element',
     '<appendix xml:id="volume-chrestomathy"><table role="parallel-text"><tr><td>a</td></tr></table></appendix>',
     1, "belongs on <informaltable>"),
    ('fail-outside-chrestomathy',
     '<chapter xml:id="c1"><informaltable role="parallel-text"><tr><td>a</td></tr></informaltable></chapter>',
     1, 'only effective inside'),
    ('fail-other-appendix',
     '<appendix xml:id="appendix-changes"><informaltable role="parallel-text"><tr><td>a</td></tr></informaltable></appendix>',
     1, 'only effective inside'),
    ('fail-literal-nbsp-separator',
     '<appendix xml:id="volume-chrestomathy"><section><informaltable role="parallel-text\u00a0noborder"><tr><td>a</td></tr></informaltable></section></appendix>',
     1, 'must carry role="parallel-text"'),
    ('fail-numeric-nbsp-separator',
     '<appendix xml:id="volume-chrestomathy"><section><informaltable role="parallel-text&#160;noborder"><tr><td>a</td></tr></informaltable></section></appendix>',
     1, 'must carry role="parallel-text"'),
    ('fail-undeclared-named-nbsp-separator',
     '<appendix xml:id="volume-chrestomathy"><section><informaltable role="parallel-text&nbsp;noborder"><tr><td>a</td></tr></informaltable></section></appendix>',
     1, 'must carry role="parallel-text"'),
    ('fail-declared-named-nbsp-separator',
     '<!DOCTYPE appendix [<!ENTITY nbsp "&#160;">]><appendix xml:id="volume-chrestomathy"><section><informaltable role="parallel-text&nbsp;noborder"><tr><td>a</td></tr></informaltable></section></appendix>',
     1, 'must carry role="parallel-text"'),
]


class LintParallelTextTests(unittest.TestCase):
    def test_cases(self):
        with tempfile.TemporaryDirectory(prefix='cll-pt-lint-') as temp:
            for name, xml, want_rc, want_msg in CASES:
                with self.subTest(case=name):
                    path = Path(temp) / f'{name}.xml'
                    path.write_text(xml, encoding='utf-8')
                    res = subprocess.run([sys.executable, str(LINT), str(path)],
                                         capture_output=True, text=True)
                    self.assertEqual(res.returncode, want_rc, res.stderr)
                    if want_msg:
                        self.assertIn(want_msg, res.stderr)


if __name__ == '__main__':
    unittest.main()
