#!/usr/bin/env python3
"""Test release labels against real lightweight and annotated Git tags."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class VersionTests(unittest.TestCase):
    def test_tagged_untagged_and_exported_sources(self):
        scratch = ROOT / 'build/version-tests'
        scratch.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch) as directory:
            repo = Path(directory)
            (repo / 'scripts').mkdir()
            shutil.copy2(ROOT / 'scripts/build-version.sh', repo / 'scripts')
            (repo / '.env').write_text('VERSION="colojban-1.3.5+dev"\n')
            env = {k: v for k, v in os.environ.items() if k != 'CLL_BUILD_VERSION'}
            env.update(GIT_AUTHOR_NAME='Test', GIT_AUTHOR_EMAIL='test@example.invalid',
                       GIT_COMMITTER_NAME='Test', GIT_COMMITTER_EMAIL='test@example.invalid')

            def run(*args, **kwargs):
                return subprocess.run(args, cwd=repo, env=env, capture_output=True,
                                      text=True, check=True, **kwargs).stdout.strip()

            run('git', 'init', '-q')
            run('git', 'add', '.')
            run('git', 'commit', '-qm', 'Fixture')
            commit = run('git', 'rev-parse', '--short=7', 'HEAD')
            self.assertEqual(run('scripts/build-version.sh'), 'colojban-1.3.5+' + commit)
            # An untagged draft still identifies its source, even without +dev.
            (repo / '.env').write_text('VERSION="colojban-1.3.5"\n')
            self.assertEqual(run('scripts/build-version.sh'), 'colojban-1.3.5+' + commit)
            run('git', 'tag', 'unrelated')
            run('git', 'tag', 'v1.3.4')
            self.assertEqual(run('scripts/build-version.sh'), 'colojban-1.3.5+' + commit)
            run('git', 'tag', 'v1.3.5')
            self.assertEqual(run('scripts/build-version.sh'), 'colojban-1.3.5')
            (repo / '.env').write_text('VERSION="colojban-1.3.5+dev"\n')
            self.assertEqual(run('scripts/build-version.sh'), 'colojban-1.3.5')
            run('git', 'tag', '-d', 'v1.3.5')
            run('git', 'tag', '-a', 'v1.3.5', '-m', 'Release')
            self.assertEqual(run('scripts/build-version.sh'), 'colojban-1.3.5')
            run('git', 'commit', '--allow-empty', '-qm', 'Next')
            self.assertEqual(run('scripts/build-version.sh'),
                             'colojban-1.3.5+' + run('git', 'rev-parse', '--short=7', 'HEAD'))
            # Stop Git from falling back to the enclosing worktree after export.
            shutil.rmtree(repo / '.git')
            env['GIT_CEILING_DIRECTORIES'] = str(repo.parent)
            with self.assertRaises(subprocess.CalledProcessError):
                run('scripts/build-version.sh')
            env['CLL_BUILD_VERSION'] = 'colojban-1.3.5+1234567'
            self.assertEqual(run('scripts/build-version.sh'), env['CLL_BUILD_VERSION'])

    def test_clean_preserves_installed_runtime(self):
        scratch = ROOT / 'build/version-tests'
        scratch.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch) as directory:
            repo = Path(directory).resolve()
            (repo / 'coverage/build').mkdir(parents=True)
            tools = repo / 'build/weasyprint-tools'
            tools.mkdir(parents=True)
            runtime = tools / 'installed-runtime'
            runtime.write_text('keep')
            output = repo / 'build/cll-weasyprint.pdf'
            output.write_text('remove')
            subprocess.run(['make', '-f', str(ROOT / 'scripts/Makefile'),
                            f'PWD={repo}', f'builddir={repo / "build"}', 'chapters=', 'clean'],
                           check=True, capture_output=True, text=True)
            self.assertEqual(runtime.read_text(), 'keep')
            self.assertFalse(output.exists())


if __name__ == '__main__':
    unittest.main()
