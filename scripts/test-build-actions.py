#!/usr/bin/env python3
"""Exercise guard failures and format dispatch without rendering the book."""
import itertools
import json
import os
from pathlib import Path
import subprocess
import tempfile
import textwrap
import unittest

ROOT = Path(__file__).resolve().parent.parent

class BuildActions(unittest.TestCase):
    def test_workflow_selection(self):
        workflow = (ROOT/'.github/workflows/build.yml').read_text()
        code = textwrap.dedent(workflow.split("python3 - <<'PYTHON'\n", 1)[1].split('          PYTHON', 1)[0])
        formats = ['html', 'epub', 'pdf', 'pdf-weasyprint', 'pdf-typst', 'pdf-context']
        with tempfile.TemporaryDirectory() as tmp:
            output, summary = Path(tmp)/'output', Path(tmp)/'summary'
            for bits in itertools.product([False, True], repeat=len(formats)):
                selected = [f for f, bit in zip(formats, bits) if bit]
                with self.subTest(selected=selected):
                    output.write_text('')
                    summary.write_text('')
                    env = dict(os.environ, INPUTS=json.dumps(dict(zip(formats, bits))),
                               GITHUB_OUTPUT=str(output), GITHUB_STEP_SUMMARY=str(summary))
                    run = subprocess.run(['python3', '-c', code], env=env, capture_output=True, text=True)
                    self.assertEqual(run.returncode == 0, bool(selected))
                    if selected:
                        self.assertEqual(output.read_text(), 'list=' + ' '.join(selected) + '\n')
                    else:
                        self.assertIn('Select at least one output format.', run.stdout)
                        self.assertIn('Select at least one output format.', summary.read_text())

    def test_guard(self):
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp)
            git = p / 'git'
            git.write_text('''#!/bin/bash
case "$1" in
ls-remote) [ "$STATE" != error ] || exit 1; [ "$STATE" = missing ] || echo 'abc refs/heads/pages' ;;
fetch) [ "$STATE" != fetch-error ] ;;
ls-tree) [ "$STATE" != tree-error ] || exit 1; [ "$STATE" != published ] || echo pages/versions.tsv ;;
esac
''')
            git.chmod(0o755)
            for state, override, allowed, success in [
                ('published', '', False, True), ('missing', '', True, True),
                ('empty', 'auto', True, True), ('error', '', False, False),
                ('fetch-error', '', False, False), ('tree-error', '', False, False),
                ('published', 'allow', True, True), ('missing', 'deny', False, True),
                ('missing', 'typo', False, False),
            ]:
                with self.subTest(state=state, override=override):
                    env = dict(os.environ, PATH=f'{p}:'+os.environ['PATH'], STATE=state, BUILD_PAGES_PREVIEW=override)
                    run = subprocess.run(['bash', str(ROOT/'scripts/build-preview-guard.sh')], env=env, capture_output=True, text=True)
                    self.assertEqual(run.returncode == 0, success)
                    self.assertEqual(run.stdout.startswith('Preview allowed:'), allowed)

    def test_dispatch(self):
        formats = ['html', 'epub', 'pdf', 'pdf-weasyprint', 'pdf-typst', 'pdf-context']
        for selected in [[f] for f in formats] + [formats]:
            with self.subTest(selected=selected), tempfile.TemporaryDirectory() as tmp:
                p = Path(tmp)
                (p/'scripts').mkdir()
                (p/'build').mkdir()
                version = p/'scripts/build-version.sh'
                version.write_text('#!/bin/bash\necho test+abc\n')
                version.chmod(0o755)
                mock = '''#!/bin/bash
set -eu
echo "$0 $*" >> commands
case "$*" in
*pdf_weasyprint*) echo pdf > build/cll-weasyprint.pdf ;;
*pdf_typst*) echo pdf > build/cll-typst.pdf ;;
*pdf*) echo pdf > build/cll.pdf ;;
*epub*) echo epub > build/cll.epub ;;
*xhtml_sections*) mkdir -p build/xhtml_section_chunks; echo html > build/xhtml_section_chunks/index.html ;;
*xhtml_nochunks*) mkdir -p build/xhtml_no_chunks; echo html > build/xhtml_no_chunks/index.html ;;
esac
'''
                for name in ['cll_build', 'scripts/install-weasyprint.sh', 'scripts/install_typst.sh']:
                    f=p/name
                    f.write_text(mock)
                    f.chmod(0o755)
                context = p/'run_context_container.sh'
                context.write_text('#!/bin/bash\necho context >> commands\necho pdf > build/cll-context.pdf\n')
                context.chmod(0o755)
                subprocess.run(['bash', str(ROOT/'scripts/build-selected-formats.sh'), ' '.join(selected), 'out'], cwd=p, check=True)
                self.assertEqual(sorted(x.name for x in (p/'out').iterdir()), sorted(selected))
                for f in selected:
                    if f == 'html':
                        self.assertEqual(sorted(x.name for x in (p/'out/html').iterdir()), ['cll-test+abc-html.tar.gz','index.html','xhtml_no_chunks','xhtml_section_chunks'])
                    else:
                        name={'epub':'cll.epub','pdf':'cll.pdf'}.get(f, 'cll-'+f.removeprefix('pdf-')+'.pdf')
                        self.assertEqual([x.name for x in (p/'out'/f).iterdir()], [name])

if __name__ == '__main__':
    unittest.main()
