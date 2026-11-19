#!/usr/bin/env python3
"""Unique container names and per-run image selection (issue #297).

Two builds from different checkouts must not stop each other: each run gets
its own container name, only that run's container is ever removed (by its
immutable ID, also on interruption), and each run starts the container by
the image ID its own build returned, so sharing one image tag is safe.
A signal to the launcher PID alone stops the build at once and exits with
the signal status.
"""

import os
import shlex
import shutil
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

# The stub engine below is written into the scratch directory by StubRun.
# It logs each call, sleeps interruptibly in build and run, tracks one
# marker per container ID, rejects an occupied container name, and fails
# a test that calls the engine kill command (cleanup uses stop and rm).
STUB_ENGINE = """\
#!/usr/bin/env bash
log() { printf '%s\\n' "$*" >> "$STUB_LOG"; }
log "call $*"
op=$1
shift || true
on_engine_signal() {
  # Stop the sleep at once: an orphaned sleep would inherit the checkout
  # lock and block the next run.
  [ -n "$sp" ] && kill "$sp" 2>/dev/null
  log "$1-signal"
  exit 143
}
case "$op" in
  info) exit 0 ;;
  --version) echo "docker version 99-stub"; exit 0 ;;
  tag) exit 0 ;;
  kill) log "UNEXPECTED engine kill $*"; exit 1 ;;
  build)
    iidfile=
    while [ $# -gt 0 ]; do
      case "$1" in
        --iidfile) iidfile=$2; shift 2 ;;
        *) shift ;;
      esac
    done
    trap 'on_engine_signal build' TERM INT HUP
    log build-start
    sleep "${STUB_BUILD_SLEEP:-0}" & sp=$!
    wait "$sp"
    rc=$?
    log "build-end rc=$rc"
    [ -n "$iidfile" ] && printf '%s' "${STUB_IMAGE_ID:-stub-image-id}" > "$iidfile"
    exit "$rc" ;;
  run)
    name=; cidfile=
    while [ $# -gt 0 ]; do
      case "$1" in
        --name) name=$2; shift 2 ;;
        --cidfile) cidfile=$2; shift 2 ;;
        *) shift ;;
      esac
    done
    id="cid-$name"
    if [ -e "$STUB_DIR/$id.marker" ]; then
      log "run-rejected-occupied $name"
      exit 125
    fi
    [ -n "$cidfile" ] && printf '%s' "$id" > "$cidfile"
    trap 'on_engine_signal run' TERM INT HUP
    log run-start
    if [ -t 0 ]; then log run-stdin-tty; else log run-stdin-notty; fi
    touch "$STUB_DIR/$id.marker"
    sleep "${STUB_RUN_SLEEP:-20}" & sp=$!
    wait "$sp"
    rc=$?
    log "run-end rc=$rc"
    if [ -n "${STUB_RUN_RC:-}" ]; then
      exit "$STUB_RUN_RC"
    fi
    exit "$rc" ;;
  stop)
    id=
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        *) id=$1; shift ;;
      esac
    done
    log "stop $id"
    rm -f "$STUB_DIR/$id.marker"
    exit 0 ;;
  rm)
    id=
    while [ $# -gt 0 ]; do
      case "$1" in
        -*) shift ;;
        *) id=$1; shift ;;
      esac
    done
    log "rm $id"
    rm -f "$STUB_DIR/$id.marker"
    exit 0 ;;
esac
exit 0
"""


def bash_lines(*statements, env_extra=None):
    # The caller's CLL_CONTAINER_NAME never leaks into these checks; the
    # override test sets it explicitly.
    env = {k: v for k, v in os.environ.items()
           if k != 'CLL_CONTAINER_NAME'}
    env.update(env_extra or {})
    script = '. "{}"\n{}\n'.format(HELPER, '\n'.join(statements))
    return subprocess.run(['bash', '-c', script], capture_output=True,
                          text=True, env=env, check=True).stdout.strip()


def container_name(directory, override=None):
    env_extra = {'CLL_CONTAINER_NAME': override} if override else {}
    return bash_lines('cll_container_name "$CLL_T_DIR"', env_extra={
        **env_extra, 'CLL_T_DIR': directory})


def valid_container_name(name):
    out = bash_lines(
        'if cll_valid_container_name "$CLL_T_NAME"; then echo valid; else echo invalid; fi',
        env_extra={'CLL_T_NAME': name})
    return out == 'valid'


def make_launcher_tree(parent, dockerfile_lines=('FROM example/base\n',)):
    # A minimal second checkout for the collision and image-identity
    # tests: the launcher locates its checkout from its own path, so each
    # tree gets its own build folder and lock. CLL_BUILD_VERSION skips
    # build-version.sh's Git lookup (the script still runs and exits 0 on
    # the variable).
    tree = Path(parent)
    (tree / 'scripts').mkdir(parents=True, exist_ok=True)
    shutil.copy2(ROOT / 'run_container.sh', tree / 'run_container.sh')
    for name in ('container-names.sh', 'build-version.sh'):
        shutil.copy2(ROOT / 'scripts' / name, tree / 'scripts' / name)
    (tree / 'Dockerfile').write_text(''.join(dockerfile_lines))
    return tree


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
            self.assertTrue(valid_container_name(name))

    def test_caller_override(self):
        self.assertEqual(container_name('/worktrees/one', 'my-special-name'),
                         'my-special-name')
        self.assertTrue(valid_container_name('my-special-name'))
        self.assertTrue(valid_container_name('a0-_.-9'))
        for bad in ('-leading-hyphen', 'has space', 'has/slash',
                    '.leading-dot'):
            self.assertFalse(valid_container_name(bad), bad)


class StubRun:
    """One run_container.sh run against the stub engine in a scratch dir."""

    def __init__(self, scratch, tree=ROOT, out_name='stdout.txt',
                 truncate_log=True, **env_extra):
        self.work = Path(scratch)
        self.tree = Path(tree)
        self.log = self.work / 'engine.log'
        if truncate_log or not self.log.exists():
            self.log.write_text('')
        self.stub = self.work / 'stub-engine.sh'
        self.stub.write_text(STUB_ENGINE)
        self.stub.chmod(self.stub.stat().st_mode | stat.S_IXUSR)
        env = {k: v for k, v in os.environ.items()
               if k != 'CLL_CONTAINER_NAME'}
        env['CONTAINER_BIN'] = str(self.stub)
        env['CLL_BUILD_VERSION'] = 'test'
        env['STUB_LOG'] = str(self.log)
        env['STUB_DIR'] = str(self.work)
        env['TMPDIR'] = str(self.work)
        env.update(env_extra)
        self.out_path = self.work / out_name
        self.output = self.out_path.open('w')
        self.proc = subprocess.Popen(
            ['bash', str(self.tree / 'run_container.sh')],
            stdout=self.output, stderr=subprocess.STDOUT,
            env=env, cwd=str(self.tree), start_new_session=True, text=True)
        self.pid = self.proc.pid

    def wait_for(self, snippet, timeout=30, count=1):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            if self.log.read_text().count(snippet) >= count:
                return True
            time.sleep(0.05)
        return False

    def calls(self):
        return [line for line in self.log.read_text().splitlines()
                if line.startswith('call ')]

    def log_text(self):
        return self.log.read_text()

    def markers(self):
        return sorted(p.name for p in self.work.glob('*.marker'))

    def temp_files(self):
        # The launcher keeps its container ID, image ID and build log in
        # one private directory. It must be gone when the run ends.
        return sorted(p.name for p in self.work.glob('cll-run*'))

    def abort(self):
        # Never leave a launcher holding the checkout lock for the next test.
        try:
            if self.proc.poll() is None:
                os.killpg(self.pid, signal.SIGKILL)
                self.proc.wait(timeout=15)
        finally:
            self.output.close()

    def finish(self, sig=None):
        try:
            if sig is not None:
                os.kill(self.pid, sig)
            return self.proc.wait(timeout=30)
        finally:
            # wait() returning means the launcher exited; otherwise kill
            # what is left so no lock is held for the next test.
            if self.proc.poll() is None:
                self.abort()
            else:
                self.output.close()


EXPECTED_SIGNAL_RC = {
    signal.SIGINT: -signal.SIGINT,
    signal.SIGTERM: -signal.SIGTERM,
    signal.SIGHUP: -signal.SIGHUP,
}


def assert_no_engine_kill(testcase, run):
    testcase.assertFalse(
        any(line.startswith('call kill') for line in run.calls()),
        '\n'.join(run.calls()))


class SignalTests(unittest.TestCase):
    def test_pid_signal_during_build(self):
        for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            with self.subTest(signal=sig):
                with tempfile.TemporaryDirectory(dir=SCRATCH) as directory:
                    run = StubRun(directory, STUB_BUILD_SLEEP='30',
                                  STUB_RUN_SLEEP='1')
                    self.assertTrue(run.wait_for('build-start'),
                                    'stub never started the image build')
                    time.sleep(1)
                    t0 = time.monotonic()
                    rc = run.finish(sig=sig)
                    elapsed = time.monotonic() - t0
                    self.assertEqual(rc, EXPECTED_SIGNAL_RC[sig])
                    self.assertLess(elapsed, 15,
                                    'launcher did not stop promptly')
                    # No container ever existed, and no book build starts
                    # after a stop during the image build.
                    self.assertFalse(
                        any('call run' in line for line in run.calls()),
                        '\n'.join(run.calls()))
                    assert_no_engine_kill(self, run)
                    self.assertEqual(run.markers(), [])
                    self.assertEqual(run.temp_files(), [])

    def test_pid_signal_during_run(self):
        for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            with self.subTest(signal=sig):
                with tempfile.TemporaryDirectory(dir=SCRATCH) as directory:
                    name = 'cll_sigtest_%d' % sig
                    run = StubRun(directory, STUB_BUILD_SLEEP='0',
                                  STUB_RUN_SLEEP='30',
                                  CLL_CONTAINER_NAME=name)
                    self.assertTrue(run.wait_for('run-start'),
                                    'stub never started the container')
                    time.sleep(1)
                    t0 = time.monotonic()
                    rc = run.finish(sig=sig)
                    elapsed = time.monotonic() - t0
                    self.assertEqual(rc, EXPECTED_SIGNAL_RC[sig])
                    self.assertLess(elapsed, 15,
                                    'launcher did not stop promptly')
                    log = run.log_text()
                    # The trap stops and removes only this run's container,
                    # tracked by the ID the engine recorded.
                    self.assertIn('stop cid-%s' % name, log, log)
                    self.assertIn('rm cid-%s' % name, log, log)
                    assert_no_engine_kill(self, run)
                    self.assertFalse(
                        any(line in ('call rm cll_build', 'call kill cll_build')
                            for line in run.calls()),
                        log)
                    self.assertEqual(run.markers(), [])
                    self.assertEqual(run.temp_files(), [])

    def test_group_signal_during_run(self):
        with tempfile.TemporaryDirectory(dir=SCRATCH) as directory:
            name = 'cll_grouptest'
            run = StubRun(directory, STUB_BUILD_SLEEP='0',
                          STUB_RUN_SLEEP='30', CLL_CONTAINER_NAME=name)
            self.assertTrue(run.wait_for('run-start'),
                            'stub never started the container')
            time.sleep(1)
            os.killpg(run.pid, signal.SIGINT)
            rc = run.proc.wait(timeout=30)
            run.output.close()
            self.assertEqual(rc, -signal.SIGINT)
            self.assertEqual(run.markers(), [])
            self.assertIn('stop cid-%s' % name, run.log_text(),
                          run.log_text())

    def test_run_gets_terminal_stdin(self):
        # Under a pseudoterminal the launcher passes -t, and the engine
        # must see a terminal on its own standard input rather than
        # /dev/null (Docker refuses -t with a non-terminal stdin).
        if shutil.which('script') is None:
            self.skipTest('script(1) missing')
        with tempfile.TemporaryDirectory(dir=SCRATCH) as directory:
            work = Path(directory)
            stub = work / 'stub-engine.sh'
            stub.write_text(STUB_ENGINE)
            stub.chmod(stub.stat().st_mode | stat.S_IXUSR)
            log = work / 'engine.log'
            log.write_text('')
            env = {k: v for k, v in os.environ.items()
                   if k != 'CLL_CONTAINER_NAME'}
            env.update(CONTAINER_BIN=str(stub), CLL_BUILD_VERSION='test',
                       STUB_LOG=str(log), STUB_DIR=str(work),
                       TMPDIR=str(work), STUB_BUILD_SLEEP='0',
                       STUB_RUN_SLEEP='1')
            assignments = ' '.join(
                '%s=%s' % (key, shlex.quote(value))
                for key, value in env.items())
            command = '%s bash %s' % (
                assignments, shlex.quote(str(ROOT / 'run_container.sh')))
            result = subprocess.run(
                ['script', '-qec', command, '/dev/null'],
                cwd=str(ROOT), capture_output=True, text=True, timeout=120)
            self.assertEqual(result.returncode, 0, result.stdout)
            run_calls = [line for line in log.read_text().splitlines()
                         if line.startswith('call run ')]
            self.assertEqual(len(run_calls), 1, log.read_text())
            self.assertIn(' -t ', run_calls[0], run_calls[0])
            self.assertIn('run-stdin-tty', log.read_text())

    def test_failed_run_exits_with_its_status(self):
        with tempfile.TemporaryDirectory(dir=SCRATCH) as directory:
            run = StubRun(directory, STUB_BUILD_SLEEP='0',
                          STUB_RUN_SLEEP='1', STUB_RUN_RC='3')
            rc = run.finish()
            self.assertEqual(rc, 3)
            self.assertEqual(run.markers(), [])

    def test_invalid_override_rejected_before_engine(self):
        for bad in ('-leading-hyphen', 'has space', 'has/slash',
                    'review-name\n', 'review-name\n\n'):
            with self.subTest(name=bad):
                with tempfile.TemporaryDirectory(dir=SCRATCH) as directory:
                    run = StubRun(directory, CLL_CONTAINER_NAME=bad)
                    rc = run.finish()
                    self.assertEqual(rc, 2)
                    self.assertEqual(run.calls(), [])

    def test_valid_override_runs_to_completion(self):
        with tempfile.TemporaryDirectory(dir=SCRATCH) as directory:
            name = 'my-run_2.0'
            run = StubRun(directory, STUB_BUILD_SLEEP='0',
                          STUB_RUN_SLEEP='1', CLL_CONTAINER_NAME=name)
            rc = run.finish()
            self.assertEqual(rc, 0)
            lines = '\n'.join(run.calls())
            self.assertIn('--name %s' % name, lines, lines)
            self.assertIn('--cidfile', lines, lines)
            self.assertEqual(run.markers(), [])

    def test_shared_name_rejected_by_engine(self):
        # Each tree is its own checkout with its own build folder and lock,
        # so both runs reach the engine; it rejects the second container
        # with an occupied name while the first run is unaffected.
        with tempfile.TemporaryDirectory(dir=SCRATCH) as parent:
            a_tree = make_launcher_tree(Path(parent) / 'a')
            b_tree = make_launcher_tree(Path(parent) / 'b')
            with tempfile.TemporaryDirectory(dir=SCRATCH) as directory:
                # Both runs share the stub engine state; only their
                # checkouts (and so build folders and locks) differ.
                first = StubRun(directory, tree=a_tree,
                                STUB_BUILD_SLEEP='0',
                                STUB_RUN_SLEEP='30',
                                CLL_CONTAINER_NAME='shared-name')
                self.assertTrue(first.wait_for('run-start'),
                                'first run never started the container')
                second = StubRun(directory, tree=b_tree,
                                 out_name='second-stdout.txt',
                                 STUB_BUILD_SLEEP='0',
                                 STUB_RUN_SLEEP='30',
                                 CLL_CONTAINER_NAME='shared-name')
                rc = second.finish()
                self.assertEqual(rc, 125)
                self.assertIn('run-rejected-occupied shared-name',
                              second.log_text(), second.log_text())
                self.assertIsNone(first.proc.poll())
                self.assertEqual(first.markers(),
                                 ['cid-shared-name.marker'])
                rc = first.finish(sig=signal.SIGTERM)
                self.assertEqual(rc, -signal.SIGTERM)
                self.assertEqual(first.markers(), [])

    def test_concurrent_runs_use_their_own_image_id(self):
        # Two checkouts with different Dockerfiles share one image tag, but
        # each run starts the container by the ID its own build returned.
        with tempfile.TemporaryDirectory(dir=SCRATCH) as parent:
            a_tree = make_launcher_tree(
                Path(parent) / 'a',
                ['FROM example/base\n', 'ENV TREE=a\n'])
            b_tree = make_launcher_tree(
                Path(parent) / 'b',
                ['FROM example/base\n', 'ENV TREE=b\n'])
            with tempfile.TemporaryDirectory(dir=SCRATCH) as directory:
                first = StubRun(directory, tree=a_tree,
                                STUB_BUILD_SLEEP='1',
                                STUB_RUN_SLEEP='10',
                                STUB_IMAGE_ID='img-aaa',
                                CLL_CONTAINER_NAME='img-run-a')
                second = StubRun(directory, tree=b_tree,
                                 out_name='second-stdout.txt',
                                 truncate_log=False,
                                 STUB_BUILD_SLEEP='1',
                                 STUB_RUN_SLEEP='10',
                                 STUB_IMAGE_ID='img-bbb',
                                 CLL_CONTAINER_NAME='img-run-b')
                self.assertTrue(first.wait_for('run-start'),
                                'first run never started the container')
                self.assertTrue(second.wait_for('run-start', count=2),
                                'second run never started the container')
                # Both containers run at the same time under one tag.
                self.assertIsNone(first.proc.poll())
                self.assertIsNone(second.proc.poll())
                log = second.log_text()
                for name, image in (('img-run-a', 'img-aaa'),
                                    ('img-run-b', 'img-bbb')):
                    own = [line for line in log.splitlines()
                           if line.startswith('call run ') and name in line]
                    self.assertEqual(len(own), 1, log)
                    self.assertIn(' %s ' % image, own[0], own[0])
                self.assertEqual(first.finish(), 0)
                self.assertEqual(second.finish(), 0)
                self.assertEqual(first.markers(), [])
                self.assertEqual(second.markers(), [])

    def test_second_run_in_same_checkout_fails_fast(self):
        with tempfile.TemporaryDirectory(dir=SCRATCH) as directory:
            first = StubRun(directory, STUB_BUILD_SLEEP='30',
                            STUB_RUN_SLEEP='1')
            self.assertTrue(first.wait_for('build-start'),
                            'first run never started the image build')
            second = StubRun(directory, out_name='second-stdout.txt',
                             STUB_BUILD_SLEEP='30', STUB_RUN_SLEEP='1')
            rc = second.finish()
            self.assertEqual(rc, 1)
            self.assertFalse(
                any('call build' in line for line in second.calls()),
                '\n'.join(second.calls()))
            self.assertIn('Another build already uses',
                          second.out_path.read_text())
            rc = first.finish(sig=signal.SIGTERM)
            self.assertEqual(rc, -signal.SIGTERM)


if __name__ == '__main__':
    SCRATCH.mkdir(parents=True, exist_ok=True)
    unittest.main()
