#!/usr/bin/env python3
"""Exercise the actual workflow blocks and helpers without rendering the book."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import itertools
import json
import os
from pathlib import Path
import subprocess
import tempfile
import textwrap
import threading
import unittest

ROOT = Path(__file__).resolve().parent.parent
FORMATS = ['html', 'epub', 'pdf', 'pdf-weasyprint', 'pdf-typst', 'pdf-context']
COMMIT = 'a' * 40


def workflow():
    return json.loads(subprocess.check_output([
        'ruby', '-ryaml', '-rjson', '-e',
        'puts JSON.generate(YAML.safe_load(File.read(ARGV[0])))',
        str(ROOT/'.github/workflows/build.yml')], text=True))


def python_body(script):
    return textwrap.dedent(script.split("python3 - <<'PYTHON'\n", 1)[1].split('PYTHON\n', 1)[0])


class FakeAPI(BaseHTTPRequestHandler):
    state = 'empty'
    requests = []

    def do_GET(self):
        type(self).requests.append((self.path, self.headers.get('Authorization')))
        status, data = 200, {}
        if self.headers.get('Authorization') != 'Bearer fixture-job-token':
            status = 401
        elif self.state == 'error':
            status = 503
        elif self.path == '/repos/test/private':
            data = {'has_pages': self.state != 'disabled'}
        elif self.path == '/repos/test/private/pages':
            if self.state in ('disabled', 'inconsistent'):
                status = 404
            elif self.state == 'pages-error':
                status = 403
            else:
                data = {'build_type': 'legacy' if self.state == 'legacy' else 'workflow'}
        elif self.path == '/repos/test/private/branches/pages':
            if self.state == 'missing':
                status = 404
            elif self.state == 'branch-error':
                status = 500
            else:
                data = {'commit': {'sha': COMMIT}}
        elif self.path == '/repos/test/private/contents/pages/versions.tsv?ref=' + COMMIT:
            if self.state == 'published':
                data = {'type': 'file'}
            else:
                status = 500 if self.state == 'marker-error' else 404
        else:
            status = 400
        self.send_response(status)
        self.end_headers()
        self.wfile.write(json.dumps(data).encode())

    def log_message(self, *args):
        pass


class BuildActions(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workflow = workflow()
        cls.build_steps = cls.workflow['jobs']['build']['steps']
        cls.early = next(s for s in cls.build_steps if s.get('id') == 'guard')
        cls.late = cls.workflow['jobs']['deploy']['steps'][0]
        cls.server = ThreadingHTTPServer(('127.0.0.1', 0), FakeAPI)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join()

    def environment(self, **updates):
        return dict(os.environ, GH_TOKEN='fixture-job-token',
                    GITHUB_API_URL=f'http://127.0.0.1:{self.server.server_port}',
                    GITHUB_REPOSITORY='test/private', BUILD_PAGES_PREVIEW='', **updates)

    def test_workflow_selection(self):
        code = python_body(next(s for s in self.build_steps if s.get('id') == 'formats')['run'])
        with tempfile.TemporaryDirectory() as tmp:
            output, summary = Path(tmp)/'output', Path(tmp)/'summary'
            for bits in itertools.product([False, True], repeat=len(FORMATS)):
                selected = [f for f, bit in zip(FORMATS, bits) if bit]
                with self.subTest(selected=selected):
                    output.write_text('')
                    summary.write_text('')
                    env = dict(os.environ, INPUTS=json.dumps(dict(zip(FORMATS, bits))),
                               GITHUB_OUTPUT=str(output), GITHUB_STEP_SUMMARY=str(summary))
                    run = subprocess.run(['python3', '-c', code], env=env, capture_output=True, text=True)
                    self.assertEqual(run.returncode == 0, bool(selected), run.stderr)
                    if selected:
                        self.assertEqual(output.read_text(), 'list=' + ' '.join(selected) + '\n')
                    else:
                        self.assertIn('Select at least one output format.', run.stdout)
                        self.assertIn('Select at least one output format.', summary.read_text())

    def test_authenticated_guard_and_readiness(self):
        for state, policy, allowed, success in [
            ('published', '', False, True), ('missing', '', True, True),
            ('empty', 'auto', True, True), ('disabled', '', False, True),
            ('legacy', '', False, True), ('inconsistent', '', False, False),
            ('pages-error', '', False, False), ('error', '', False, False),
            ('branch-error', '', False, False), ('marker-error', '', False, False),
            ('published', 'allow', False, False), ('error', 'allow', False, False),
            ('published', 'deny', False, True), ('missing', 'deny', False, True),
            ('missing', 'typo', False, False),
        ]:
            with self.subTest(state=state, policy=policy):
                FakeAPI.state, FakeAPI.requests = state, []
                env = self.environment()
                env['BUILD_PAGES_PREVIEW'] = policy
                run = subprocess.run(['bash', str(ROOT/'scripts/build-preview-guard.sh')], env=env, capture_output=True, text=True)
                self.assertEqual(run.returncode == 0, success, run.stderr)
                self.assertEqual(run.stdout.startswith('Preview allowed:'), allowed)
                self.assertTrue(all(auth == 'Bearer fixture-job-token' for _, auth in FakeAPI.requests))
                if policy in ('deny', 'allow', 'typo'):
                    self.assertEqual(FakeAPI.requests, [])
                if state == 'published' and not policy:
                    self.assertIn('published book site', run.stdout)
                if state in ('disabled', 'legacy'):
                    self.assertIn('Settings > Pages > Source', run.stdout)

    def run_block(self, block, env):
        with tempfile.TemporaryDirectory() as tmp:
            output, summary = Path(tmp)/'output', Path(tmp)/'summary'
            output.write_text('')
            summary.write_text('')
            env = dict(env, GITHUB_OUTPUT=str(output), GITHUB_STEP_SUMMARY=str(summary))
            run = subprocess.run(['bash', '-e', '-o', 'pipefail', '-c', block], cwd=ROOT,
                                 env=env, capture_output=True, text=True)
            return run, output.read_text(), summary.read_text()

    def test_early_guard_wiring_and_late_transition(self):
        # Both trust boundaries run the same checks, but deployment has no checkout.
        early_code = python_body((ROOT/'scripts/build-preview-guard.sh').read_text())
        self.assertEqual(early_code, python_body(self.late['run']))
        for preview, formats in [('false', 'html'), ('true', 'pdf')]:
            FakeAPI.state, FakeAPI.requests = 'error', []
            run, output, summary = self.run_block(self.early['run'], self.environment(PREVIEW=preview, FORMATS=formats))
            self.assertEqual(run.returncode, 0, run.stderr)
            self.assertEqual(output, 'preview=false\n')
            self.assertIn('Preview skipped:', summary)
            self.assertEqual(FakeAPI.requests, [])
        FakeAPI.state = 'empty'
        run, output, _ = self.run_block(self.early['run'], self.environment(PREVIEW='true', FORMATS='html'))
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertIn('preview=true\n', output)
        # Release protection can appear while the build or approval is pending.
        FakeAPI.state = 'published'
        run, output, summary = self.run_block(self.late['run'], self.environment())
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertEqual(output, 'deploy=false\n')
        self.assertIn('published book site', summary)
        for state in ['disabled', 'legacy', 'error', 'marker-error', 'pages-error']:
            FakeAPI.state = state
            run, output, summary = self.run_block(self.late['run'], self.environment())
            self.assertNotIn('deploy=true', output)
            self.assertEqual(run.returncode == 0, state in ['disabled', 'legacy'], run.stderr)
        FakeAPI.state = 'empty'
        run, output, _ = self.run_block(self.late['run'], self.environment())
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertIn('deploy=true\n', output)
        FakeAPI.state = 'error'
        run, output, summary = self.run_block(self.early['run'], self.environment(PREVIEW='true', FORMATS='html'))
        self.assertNotEqual(run.returncode, 0)
        self.assertEqual(output, 'preview=false\n')
        self.assertIn('::error::Build stopped: the preview guard failed.', run.stdout)
        self.assertIn('Clear preview to build without it.', summary)

    def test_workflow_pins_permissions_and_conditions(self):
        tool = ROOT/'scripts/test-build-workflow.rb'
        subprocess.run(['ruby', str(tool)], check=True)
        source = (ROOT/'.github/workflows/build.yml').read_text()
        # These mutations must be rejected, not merely accepted for real input.
        for before, after in [
            ("needs.build.outputs.preview == 'true'", 'true'),
            ("steps.late_guard.outputs.deploy == 'true'", 'true'),
            ("success() && steps.guard.outputs.preview == 'true'", 'true'),
            ('pages: read #', 'pages: write #'),
            ('retention-days: 14', 'retention-days: 90'),
            ('actions/checkout@9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0', 'actions/checkout@main'),
        ]:
            with self.subTest(before=before), tempfile.TemporaryDirectory() as tmp:
                fixture = Path(tmp)/'mutated.yml'
                fixture.write_text(source.replace(before, after, 1))
                result = subprocess.run(['ruby', str(tool), str(fixture)], capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)

    def fixture(self, p, empty=False):
        (p/'scripts').mkdir()
        (p/'build').mkdir()
        version = p/'scripts/build-version.sh'
        version.write_text('#!/bin/bash\necho test+abc\n')
        version.chmod(0o755)
        (p/'bin').mkdir()
        git = p/'bin/git'
        git.write_text('#!/bin/bash\necho ' + COMMIT + '\n')
        git.chmod(0o755)
        mock = '''#!/bin/bash
set -eu
echo "$0 $*" >> commands
[ "${EMPTY_OUTPUT:-}" != true ] || exit 0
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
        context.write_text('#!/bin/bash\necho "./run_context_container.sh" >> commands\n[ "${EMPTY_OUTPUT:-}" = true ] || echo pdf > build/cll-context.pdf\n')
        context.chmod(0o755)
        return dict(os.environ, PATH=str(p/'bin')+':'+os.environ['PATH'], EMPTY_OUTPUT=str(empty).lower())

    def test_dispatch(self):
        expected = {
            'html': ['./cll_build -n -T xhtml_sections', './cll_build -n -T xhtml_nochunks'],
            'epub': ['./cll_build -n -T epub'],
            'pdf': ['./cll_build -n -T pdf'],
            'pdf-weasyprint': ['./scripts/install-weasyprint.sh ', './cll_build -n -T pdf_weasyprint'],
            'pdf-typst': ['./scripts/install_typst.sh build/typst-tools', './cll_build -n -T pdf_typst'],
            'pdf-context': ['./run_context_container.sh'],
        }
        for selected in [[f] for f in FORMATS] + [FORMATS]:
            with self.subTest(selected=selected), tempfile.TemporaryDirectory() as tmp:
                p = Path(tmp)
                env = self.fixture(p)
                subprocess.run(['bash', str(ROOT/'scripts/build-selected-formats.sh'), ' '.join(selected), 'out'], cwd=p, env=env, check=True)
                self.assertEqual(sorted(x.name for x in (p/'out').iterdir()), sorted(selected))
                self.assertEqual((p/'commands').read_text().splitlines(), [c for f in selected for c in expected[f]])
                for f in selected:
                    if f == 'html':
                        self.assertEqual(sorted(x.name for x in (p/'out/html').iterdir()), ['index.html','xhtml_no_chunks','xhtml_section_chunks'])
                        page = (p/'out/html/index.html').read_text()
                        for href in ['xhtml_section_chunks/index.html', 'xhtml_no_chunks/index.html']:
                            self.assertIn('href="'+href+'"', page)
                            self.assertTrue((p/'out/html'/href).is_file())
                        self.assertIn('test+abc', page)
                        self.assertIn(COMMIT, page)
                    else:
                        name={'epub':'cll.epub','pdf':'cll.pdf'}.get(f, 'cll-'+f.removeprefix('pdf-')+'.pdf')
                        self.assertEqual([x.name for x in (p/'out'/f).iterdir()], [name])

    def test_missing_output_and_unknown_format(self):
        for fmt in FORMATS + ['unknown']:
            with self.subTest(fmt=fmt), tempfile.TemporaryDirectory() as tmp:
                p=Path(tmp)
                env=self.fixture(p, empty=True)
                run=subprocess.run(['bash', str(ROOT/'scripts/build-selected-formats.sh'), fmt, 'out'], cwd=p, env=env, text=True, capture_output=True)
                self.assertNotEqual(run.returncode, 0)
                self.assertIn('Unknown format:' if fmt == 'unknown' else 'Missing or empty output:', run.stderr)

    def test_partial_failure_summary(self):
        code = python_body(next(s for s in self.build_steps if s.get('name', '').startswith('Summarize outputs'))['run'])
        env = dict(os.environ, FORMATS='pdf-typst pdf-context', STEPS=json.dumps({
            'build_pdf_typst': {'outcome': 'success'}, 'upload_pdf_typst': {'outcome': 'success'}, 'build_pdf_context': {'outcome': 'failure'}}),
            GITHUB_SERVER_URL='https://github.com', GITHUB_REPOSITORY='test/private', GITHUB_RUN_ID='123')
        with tempfile.TemporaryDirectory() as tmp:
            summary = Path(tmp)/'summary'
            env['GITHUB_STEP_SUMMARY'] = str(summary)
            run = subprocess.run(['python3', '-c', code], env=env, capture_output=True, text=True)
            self.assertNotEqual(run.returncode, 0)
            self.assertIn('cll-pdf-typst', summary.read_text())
            self.assertIn('Not available: pdf-context (failure)', summary.read_text())
            self.assertIn('::error::Selected formats failed: pdf-context', run.stdout)


if __name__ == '__main__':
    unittest.main()
