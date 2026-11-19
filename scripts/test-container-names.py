#!/usr/bin/env python3
"""Unique container names and content-derived image tags (issue #297).

Two builds from different checkouts must not stop each other: each run gets
its own container name, only that run's container is ever removed (also on
interruption), and different Dockerfiles never share an image tag.
"""

import os
import re
import signal
import stat
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / 'scripts/container-names.sh'
SCRATCH = ROOT / 'build/container-tests'

HEX16 = re.compile(r'^[0-9a-f]{16}$')


def bash_lines(*statements, env_extra=None):
    env = dict(os.environ)
    env.update(env_extra or {})
    script = '. "{}"\n{}\n'.format(HELPER, '\n'.join(statements))
    return subprocess.run(['bash', '-c', script], capture_output=True,
                          text=True, env=env, check=True).stdout.strip()


def container_name(directory, override=None):
    env_extra = {'CLL_CONTAINER_NAME': override} if override else {}
    return bash_lines('cll_container_name "$CLL_T_DIR"', env_extra={
        **env_extra, 'CLL_T_DIR': directory})


def image_tag(dockerfile, context, *extra):
    env = dict(os.environ)
    env['CLL_T_DOCKERFILE'] = str(dockerfile)
    env['CLL_T_CONTEXT'] = str(context)
    script = ('. "{}"\ncll_image_tag "$CLL_T_DOCKERFILE" '
              '"$CLL_T_CONTEXT" "$@"\n'.format(HELPER))
    return subprocess.run(['bash', '-c', script, 'bash', *extra],
                          capture_output=True, text=True, env=env,
                          check=True).stdout.strip()


def make_context(directory, dockerfile_lines, files):
    directory.mkdir(parents=True, exist_ok=True)
    (directory / 'Dockerfile').write_text(''.join(dockerfile_lines))
    for name, content in files.items():
        path = directory / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)


BASE_LINES = [
    'FROM example/base\n',
    'COPY app/server.sh /srv/server.sh\n',
    'COPY data/ /srv/data/\n',
    'RUN echo done\n',
]
BASE_FILES = {
    'app/server.sh': '#!/bin/bash\necho hi\n',
    'data/a.txt': 'alpha\n',
    'data/b.txt': 'beta\n',
}


class ContainerNamesTests(unittest.TestCase):
    def test_names_differ_by_checkout_and_process(self):
        first = container_name('/worktrees/one')
        second = container_name('/worktrees/two')
        self.assertNotEqual(first, second)
        # Two runs from one checkout still differ: the process ID is in the name.
        again = container_name('/worktrees/one')
        self.assertNotEqual(first, again)
        for name in (first, second, again):
            self.assertTrue(name.startswith('cll_build_'), name)
            self.assertNotEqual(name, 'cll_build')
            self.assertRegex(name, r'^cll_build_[0-9a-f]{12}_[0-9]+$')

    def test_caller_override(self):
        self.assertEqual(container_name('/worktrees/one', 'my-special-name'),
                         'my-special-name')

    def test_tags_follow_content(self):
        with tempfile.TemporaryDirectory(dir=SCRATCH) as directory:
            scratch = Path(directory)
            make_context(scratch / 'a', BASE_LINES, BASE_FILES)
            make_context(scratch / 'b', BASE_LINES, BASE_FILES)
            tag_a = image_tag(scratch / 'a/Dockerfile', scratch / 'a', 'prince')
            # Equal contexts share the tag (the image cache is reused).
            self.assertEqual(
                tag_a, image_tag(scratch / 'b/Dockerfile', scratch / 'b', 'prince'))
            self.assertRegex(tag_a, HEX16)
            # A changed copied file changes the tag.
            (scratch / 'b/data/a.txt').write_text('ALPHA\n')
            self.assertNotEqual(
                tag_a, image_tag(scratch / 'b/Dockerfile', scratch / 'b', 'prince'))
            # A changed Dockerfile changes the tag.
            (scratch / 'b/Dockerfile').write_text(
                ''.join(BASE_LINES).replace('echo done', 'echo done now'))
            self.assertNotEqual(
                tag_a, image_tag(scratch / 'b/Dockerfile', scratch / 'b', 'prince'))
            # The build target is part of the tag: one Dockerfile builds
            # several images.
            self.assertNotEqual(
                tag_a, image_tag(scratch / 'a/Dockerfile', scratch / 'a', 'typst'))

    def test_stage_copies_and_remote_adds_need_no_local_file(self):
        lines = BASE_LINES + [
            'COPY --from=builder /out/bin /srv/bin\n',
            'ADD https://example.invalid/ca.pem /etc/ssl/certs/ca.pem\n',
        ]
        with tempfile.TemporaryDirectory(dir=SCRATCH) as directory:
            scratch = Path(directory)
            make_context(scratch / 'a', lines, BASE_FILES)
            make_context(scratch / 'b', BASE_LINES, BASE_FILES)
            # Both hash fine without any local builder output or download.
            self.assertRegex(
                image_tag(scratch / 'a/Dockerfile', scratch / 'a'), HEX16)
            self.assertRegex(
                image_tag(scratch / 'b/Dockerfile', scratch / 'b'), HEX16)

    def test_missing_copy_source_fails(self):
        with tempfile.TemporaryDirectory(dir=SCRATCH) as directory:
            scratch = Path(directory)
            make_context(scratch / 'a', BASE_LINES,
                         {'app/server.sh': 'x\n'})
            result = subprocess.run(
                ['bash', '-c',
                 '. "{}"\ncll_image_tag "$CLL_T_DOCKERFILE" "$CLL_T_CONTEXT"'
                 .format(HELPER)],
                capture_output=True, text=True,
                env={**os.environ,
                     'CLL_T_DOCKERFILE': str(scratch / 'a/Dockerfile'),
                     'CLL_T_CONTEXT': str(scratch / 'a')})
            self.assertNotEqual(result.returncode, 0)

    def test_real_dockerfiles_tag_distinctly(self):
        prince = image_tag(ROOT / 'Dockerfile', ROOT, 'prince')
        typst = image_tag(ROOT / 'Dockerfile', ROOT, 'typst')
        weasy = image_tag(ROOT / 'Dockerfile.weasyprint',
                          ROOT / 'scripts/weasyprint')
        for tag in (prince, typst, weasy):
            self.assertRegex(tag, HEX16)
        self.assertNotEqual(prince, typst)
        self.assertNotEqual(prince, weasy)

    def test_interrupted_run_removes_only_its_container(self):
        with tempfile.TemporaryDirectory(dir=SCRATCH) as directory:
            scratch = Path(directory)
            log = scratch / 'engine.log'
            log.write_text('')
            stub = scratch / 'stub-engine.sh'
            stub.write_text(
                '#!/bin/bash\n'
                'printf \'%s\\n\' "$*" >> "$CLL_STUB_LOG"\n'
                'case "$1" in\n'
                '  info) exit 0 ;;\n'
                '  --version) echo "docker version 99-stub" ;;\n'
                '  build|tag) exit 0 ;;\n'
                '  kill|rm)\n'
                '    name=; for a in "$@"; do name=$a; done\n'
                '    rm -f "$CLL_STUB_DIR/$name.marker" 2>/dev/null || true ;;\n'
                '  run)\n'
                '    prev=; name=\n'
                '    for a in "$@"; do\n'
                '      if [ "$prev" = "--name" ]; then name=$a; fi\n'
                '      prev=$a\n'
                '    done\n'
                '    touch "$CLL_STUB_DIR/$name.marker"\n'
                '    sleep 30 ;;\n'
                'esac\n'
                'exit 0\n')
            stub.chmod(stub.stat().st_mode | stat.S_IXUSR)
            env = dict(os.environ)
            env['CONTAINER_BIN'] = str(stub)
            env['CLL_CONTAINER_NAME'] = 'cll_test_interrupt_297'
            env['CLL_STUB_LOG'] = str(log)
            env['CLL_STUB_DIR'] = str(scratch)
            proc = subprocess.Popen(
                ['bash', str(ROOT / 'run_container.sh')],
                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                env=env, start_new_session=True, text=True)
            try:
                marker = scratch / 'cll_test_interrupt_297.marker'
                for _ in range(100):
                    if marker.exists():
                        break
                    time.sleep(0.2)
                self.assertTrue(marker.exists(),
                                'stub engine never started the container')
                os.killpg(proc.pid, signal.SIGINT)
                proc.communicate(timeout=60)
            finally:
                if proc.poll() is None:
                    os.killpg(proc.pid, signal.SIGKILL)
                    proc.communicate()
            self.assertFalse(marker.exists(),
                             'interrupted run left its container behind')
            lines = log.read_text().splitlines()
            run_lines = [line for line in lines if line.startswith('run ')]
            self.assertTrue(
                any('--name cll_test_interrupt_297' in line
                    for line in run_lines),
                'run did not use the run-owned container name:\n'
                + '\n'.join(lines))
            # The old script killed and removed the fixed name cll_build.
            # This run must never touch that name, and never kill at all.
            self.assertFalse(any(line.startswith('kill ') for line in lines),
                             'run killed a container:\n' + '\n'.join(lines))
            self.assertFalse(any(line in ('kill cll_build', 'rm cll_build')
                                 for line in lines),
                             'run touched the fixed container name:\n'
                             + '\n'.join(lines))
            self.assertTrue(any('rm -f cll_test_interrupt_297' in line
                                for line in lines),
                            'run never removed its own container:\n'
                            + '\n'.join(lines))


if __name__ == '__main__':
    SCRATCH.mkdir(parents=True, exist_ok=True)
    unittest.main()
