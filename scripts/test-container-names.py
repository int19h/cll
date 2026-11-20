#!/usr/bin/env python3
"""Unique container names and per-run image selection (issue #297).

Two builds from different checkouts must not stop each other: each run gets
its own container name, only that run's container is ever removed (found by
name, verified by its cll.run label, also on interruption), and each run
starts the container by the image ID its own build returned, so sharing one
image tag is safe. The launcher never reads a file the engine wrote; it
asks the engine for the image ID and the label instead.
A signal to the launcher PID alone stops the build at once and exits with
the signal status.
"""

import os
import re
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
# marker per container ID, rejects an occupied container name, fails a test
# that calls the engine kill command (cleanup uses stop and rm), and
# simulates a tag store like Docker's containerd one: an image is dropped
# as soon as its last tag moves, so removing a run tag only untags a shared
# image. A test can hold a run at its start with STUB_RUN_HOLD until the
# named gate file appears.
STUB_ENGINE = """\
#!/usr/bin/env bash
log() { printf '%s\\n' "$*" >> "$STUB_LOG"; }
tagkey() { printf '%s' "$1" | tr -c 'A-Za-z0-9' '_'; }
have_image() { [ -e "$STUB_DIR/images/$1" ]; }
# An image reference names exactly one tag after the last slash: the tag
# starts with a letter, digit or underscore and holds only letters,
# digits, _, . and -. Anything else fails the call, as a real engine
# (and Docker's invalid reference format error) would.
valid_ref() {
  local after tag
  after=${1##*/}
  case "$after" in
    *:*:*) return 1 ;;
    *:*) ;;
    *) return 1 ;;
  esac
  tag=${after#*:}
  case "$tag" in
    ""|*[!A-Za-z0-9_.-]*) return 1 ;;
  esac
  case "$tag" in
    [A-Za-z0-9_]*) return 0 ;;
  esac
  return 1
}
log "call $*"
op=$1
shift || true
# The launchers scope container commands as `container inspect`, while
# `stop` and `rm` stay bare, exactly as the real engines accept both.
if [ "$op" = container ]; then
  op=$1
  shift || true
fi
on_engine_signal() {
  # Stop the sleep at once: an orphaned sleep would inherit the checkout
  # lock and block the next run.
  [ -n "$sp" ] && kill "$sp" 2>/dev/null
  log "$1-signal"
  exit 143
}
# Containers live in by-id/<full ID> holding "<name> <label>";
# by-name/<name> holds the running container's full ID. Like the real
# engines, the stub resolves stop/rm by the ID it is given: removing the
# bare name instead would hit whatever container took the name afterwards.
remove_container() {
  # Delete the container $1 by its full ID, freeing its name if set.
  rm -f "$STUB_DIR/by-id/$1"
  for f in "$STUB_DIR"/by-name/*; do
    [ -e "$f" ] || continue
    [ "$(cat "$f")" = "$1" ] && rm -f "$f"
  done
}
case "$op" in
  info) exit 0 ;;
  --version) echo "docker version 99-stub"; exit 0 ;;
  tag)
    if valid_ref "$3"; then exit 0; fi
    log "tag-invalid $3"
    exit 1 ;;
  inspect)
    # usage: container inspect --format FMT NAME — report "<full ID>
    # <label>" for the container currently called NAME, or nothing when
    # no such container or label exists. One call returns both, so the
    # cleanup can check ownership and act without a name race.
    name=
    for token in "$@"; do name=$token; done
    if [ -e "$STUB_DIR/by-name/$name" ]; then
      cid=$(cat "$STUB_DIR/by-name/$name")
      if [ -e "$STUB_DIR/by-id/$cid" ]; then
        printf '%s %s' "$cid" "$(cat "$STUB_DIR/by-id/$cid")"
      fi
    fi
    exit 0 ;;
  image)
    # usage: image inspect --format FMT TAG — report the tagged image ID,
    # or fail when the tag moved or never existed.
    tag=; skip=
    for token in "$@"; do
      if [ -n "$skip" ]; then skip=; continue; fi
      case "$token" in
        inspect) continue ;;
        --format) skip=1; continue ;;
        -*) continue ;;
        *) tag=$token ;;
      esac
    done
    if [ -n "${STUB_IMAGE_INSPECT_RC:-}" ]; then
      log "image-inspect-failed $tag"
      exit "$STUB_IMAGE_INSPECT_RC"
    fi
    key=$(tagkey "$tag")
    if [ -n "$tag" ] && [ -e "$STUB_DIR/tags/$key" ]; then
      cat "$STUB_DIR/tags/$key"
      exit 0
    fi
    log "image-no-such-tag $tag"
    exit 1 ;;
  kill) log "UNEXPECTED engine kill $*"; exit 1 ;;
  build)
    iidfile=; tags=
    while [ $# -gt 0 ]; do
      case "$1" in
        --iidfile) iidfile=$2; shift 2 ;;
        -t) tags="$tags $2"; shift 2 ;;
        -*) shift ;;
        *) shift ;;
      esac
    done
    trap 'on_engine_signal build' TERM INT HUP
    log build-start
    sleep "${STUB_BUILD_SLEEP:-0}" & sp=$!
    wait "$sp"
    rc=$?
    log "build-end rc=$rc"
    if [ -n "${STUB_BUILD_RC:-}" ]; then
      exit "$STUB_BUILD_RC"
    fi
    iid="${STUB_IMAGE_ID:-stub-image-id}"
    [ -n "$iidfile" ] && printf '%s' "$iid" > "$iidfile"
    # Retagging moves each tag; an image whose last tag moves is dropped,
    # as in Docker's containerd store.
    for tag in $tags; do
      if ! valid_ref "$tag"; then
        log "build-invalid-tag $tag"
        exit 1
      fi
      key=$(tagkey "$tag")
      if [ -e "$STUB_DIR/tags/$key" ] && [ "$(cat "$STUB_DIR/tags/$key")" != "$iid" ]; then
        old=$(cat "$STUB_DIR/tags/$key")
        other=
        for f in "$STUB_DIR"/tags/*; do
          [ -e "$f" ] || continue
          [ "$(cat "$f")" = "$old" ] && [ "$f" != "$STUB_DIR/tags/$key" ] && other=1
        done
        if [ -z "$other" ]; then
          log "image-dropped $old"
          rm -f "$STUB_DIR/images/$old"
        fi
      fi
      mkdir -p "$STUB_DIR/tags"
      printf '%s' "$iid" > "$STUB_DIR/tags/$key"
    done
    mkdir -p "$STUB_DIR/images"
    touch "$STUB_DIR/images/$iid"
    exit "$rc" ;;
  run)
    if [ -n "${STUB_RUN_HOLD:-}" ]; then
      while [ ! -e "$STUB_RUN_HOLD" ]; do sleep 0.2; done
    fi
    # The image is the argument right before the container command; flags
    # and their values are never split or glob-expanded while scanning.
    name=; label_id=; image=; prev=; want=; rm_flag=
    for token in "$@"; do
      case "$want" in
        --name) name=$token; want=; prev=$token; continue ;;
        --label)
          case "$token" in
            cll.run=*) label_id=${token#cll.run=} ;;
          esac
          want=; prev=$token; continue ;;
      esac
      case "$token" in
        --name|--label) want=$token; continue ;;
        --rm) rm_flag=1 ;;
      esac
      if [ "$token" = "./scripts/container-command.sh" ]; then
        image=$prev
        break
      fi
      prev=$token
    done
    if [ -e "$STUB_DIR/by-name/$name" ]; then
      log "run-rejected-occupied $name"
      exit 125
    fi
    if ! have_image "$image"; then
      log "run-no-such-image $image"
      exit 125
    fi
    cid="$name-$$-$RANDOM"
    mkdir -p "$STUB_DIR/by-name" "$STUB_DIR/by-id"
    printf '%s' "$cid" > "$STUB_DIR/by-name/$name"
    printf '%s' "$label_id" > "$STUB_DIR/by-id/$cid"
    trap 'on_engine_signal run' TERM INT HUP
    log run-start
    if [ -t 0 ]; then log run-stdin-tty; else log run-stdin-notty; fi
    sleep "${STUB_RUN_SLEEP:-20}" & sp=$!
    wait "$sp"
    rc=$?
    log "run-end rc=$rc"
    # Like a real engine, --rm removes the container when it stops, before
    # the launcher's cleanup runs. A signalled run never reaches this: its
    # trap exits at once, leaving the container for the cleanup to stop.
    if [ -n "$rm_flag" ]; then
      remove_container "$cid"
      log "run-auto-removed $cid"
    fi
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
    # The launchers run with --rm, so stopping frees the name at once; the
    # stopped container itself is gone too. A test can hold the matching
    # rm with STUB_RM_HOLD to let a successor take the freed name first.
    if [ -e "$STUB_DIR/by-id/$id" ]; then
      remove_container "$id"
    elif [ -e "$STUB_DIR/by-name/$id" ]; then
      remove_container "$(cat "$STUB_DIR/by-name/$id")"
    fi
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
    if [ -n "${STUB_RM_HOLD:-}" ]; then
      while [ ! -e "$STUB_RM_HOLD" ]; do sleep 0.2; done
    fi
    # Like a real engine, resolve the argument: a full ID deletes that
    # container, a name deletes the container currently holding it.
    if [ -e "$STUB_DIR/by-id/$id" ]; then
      remove_container "$id"
    elif [ -e "$STUB_DIR/by-name/$id" ]; then
      remove_container "$(cat "$STUB_DIR/by-name/$id")"
    fi
    exit 0 ;;
  rmi)
    # A test can fail the first rmi per run with STUB_RMI_FAIL_ONCE: the
    # launcher must retry and still remove its run tag, as a real engine
    # can refuse the untag for a moment after --rm auto-removal.
    if [ -n "${STUB_RMI_FAIL_ONCE:-}" ] && [ ! -e "$STUB_DIR/rmi-failed" ]; then
      touch "$STUB_DIR/rmi-failed"
      log "rmi-failed-once $*"
      exit 1
    fi
    for token in "$@"; do
      case "$token" in
        -*) continue ;;
      esac
      key=$(tagkey "$token")
      if [ -e "$STUB_DIR/tags/$key" ]; then
        old=$(cat "$STUB_DIR/tags/$key")
        rm -f "$STUB_DIR/tags/$key"
        other=
        for f in "$STUB_DIR"/tags/*; do
          [ -e "$f" ] || continue
          [ "$(cat "$f")" = "$old" ] && other=1
        done
        if [ -z "$other" ]; then
          log "image-dropped $old"
          rm -f "$STUB_DIR/images/$old"
        else
          log "image-untagged $old"
        fi
      fi
    done
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


class StubEngineTests(unittest.TestCase):
    def test_rejects_invalid_image_references(self):
        # The round 5 bug (a second colon, as in repo:tag:run-PID) must
        # fail in the stub too, not only on real engines.
        bad = ['localhost/cll-weasyprint:abc:run-1',
               'localhost/cll-weasyprint:bad tag',
               'localhost/cll-weasyprint:',
               'localhost/cll-weasyprint:-bad',
               'localhost/cll-weasyprint']
        good = ['lojban/cll_build:latest',
                'localhost/cll-weasyprint:abc-run-1',
                'localhost/cll-typst:abc123_-.-9']
        with tempfile.TemporaryDirectory(dir=SCRATCH) as directory:
            work = Path(directory)
            stub = work / 'stub-engine.sh'
            stub.write_text(STUB_ENGINE)
            stub.chmod(stub.stat().st_mode | stat.S_IXUSR)
            log = work / 'engine.log'
            for tag in bad + good:
                log.write_text('')
                env = dict(os.environ)
                env.update(STUB_LOG=str(log), STUB_DIR=str(work),
                           STUB_IMAGE_ID='img-x', STUB_BUILD_SLEEP='0',
                           TMPDIR=str(work))
                iid = work / 'image-id'
                if iid.exists():
                    iid.unlink()
                result = subprocess.run(
                    [str(stub), 'build', '-t', tag,
                     '--iidfile', str(iid), '-f', 'Dockerfile', '.'],
                    capture_output=True, text=True, env=env)
                if tag in good:
                    self.assertEqual(result.returncode, 0, tag)
                    self.assertEqual(iid.read_text(), 'img-x', tag)
                else:
                    self.assertNotEqual(result.returncode, 0, tag)
                    self.assertIn('build-invalid-tag', log.read_text())


def make_launcher_tree(parent, dockerfile_lines=('FROM example/base\n',),
                       launcher='run_container.sh'):
    # A minimal second checkout for the collision and image-identity
    # tests: the launcher locates its checkout from its own path, so each
    # tree gets its own build folder and lock. CLL_BUILD_VERSION skips
    # build-version.sh's Git lookup (the script still runs and exits 0 on
    # the variable).
    tree = Path(parent)
    (tree / 'scripts').mkdir(parents=True, exist_ok=True)
    shutil.copy2(ROOT / launcher, tree / launcher)
    for name in ('container-names.sh', 'build-version.sh'):
        shutil.copy2(ROOT / 'scripts' / name, tree / 'scripts' / name)
    (tree / 'Dockerfile').write_text(''.join(dockerfile_lines))
    (tree / 'Dockerfile.weasyprint').write_text(''.join(dockerfile_lines))
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

    def __init__(self, scratch, tree=ROOT, script='run_container.sh',
                 out_name='stdout.txt', truncate_log=True, **env_extra):
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
            ['bash', str(self.tree / script)],
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
        # Every full container ID the stub still tracks. Empty means the
        # run left nothing behind.
        by_id = self.work / 'by-id'
        if not by_id.exists():
            return []
        return sorted(p.name for p in by_id.iterdir())

    def named(self):
        # Map each live container name to its cll.run label.
        out = {}
        by_name = self.work / 'by-name'
        by_id = self.work / 'by-id'
        if by_name.exists():
            for entry in by_name.iterdir():
                label_file = by_id / entry.read_text()
                out[entry.name] = label_file.read_text() \
                    if label_file.exists() else None
        return out

    def tags(self):
        # Every image tag the stub still tracks, by its filesystem key.
        tags_dir = self.work / 'tags'
        if not tags_dir.exists():
            return []
        return sorted(p.name for p in tags_dir.iterdir())

    def run_tags(self):
        # This run's own tags: only run tags hold the '-run-' marker the
        # launchers put between the shared tag and the unique suffix (the
        # key turns its hyphens into underscores). Shared fixed tags never
        # contain it.
        return sorted(t for t in self.tags() if 'run_' in t)

    def temp_files(self):
        # Each launcher keeps its container ID, image ID and build log in
        # one private directory (cll-run* for Prince, cll-image* for the
        # PDF launchers). It must be gone when the run ends.
        names = sorted(p.name for p in self.work.glob('cll-run*'))
        names += sorted(p.name for p in self.work.glob('cll-image*'))
        return names

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
                    # found by name and verified by its cll.run label.
                    self.assertIn('stop %s' % name, log, log)
                    self.assertIn('rm %s' % name, log, log)
                    assert_no_engine_kill(self, run)
                    self.assertFalse(
                        any(line in ('call rm cll_build', 'call kill cll_build')
                            for line in run.calls()),
                        log)
                    self.assertEqual(run.markers(), [])
                    self.assertEqual(run.temp_files(), [])
                    self.assertEqual(run.run_tags(), [], run.tags())

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
            self.assertIn('stop %s' % name, run.log_text(),
                          run.log_text())

    def test_run_gets_terminal_stdin(self):
        # Under a pseudoterminal the launcher passes -t, and the engine
        # must see a terminal on its own standard input rather than
        # /dev/null (Docker refuses -t with a non-terminal stdin).
        # The environment travels through subprocess, never through a shell
        # command string, so exported functions cannot break the command.
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
            # An exported function must not break the command: it travels
            # in the environment, not in a shell word.
            env['BASH_FUNC_probe_fn%%'] = '() { :; }'
            result = subprocess.run(
                ['script', '-qec', 'bash run_container.sh', '/dev/null'],
                cwd=str(ROOT), capture_output=True, text=True, timeout=120,
                env=env)
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

    def test_missing_image_id_fails_loudly(self):
        # An empty image ID must stop the launcher before any container
        # runs, never start an empty image name.
        with tempfile.TemporaryDirectory(dir=SCRATCH) as directory:
            run = StubRun(directory, STUB_BUILD_SLEEP='0',
                          STUB_IMAGE_INSPECT_RC='1')
            rc = run.finish()
            self.assertEqual(rc, 1)
            self.assertIn('did not report its ID', run.out_path.read_text())
            self.assertFalse(
                any(line.startswith('call run ') for line in run.calls()))
            self.assertIn('image-inspect-failed', run.log_text())
            self.assertEqual(run.markers(), [])
            self.assertEqual(run.temp_files(), [])

    def test_invalid_override_rejected_before_engine(self):
        for bad in ('-leading-hyphen', 'has space', 'has/slash',
                    'review-name\n', 'review-name\n\n'):
            with self.subTest(name=bad):
                with tempfile.TemporaryDirectory(dir=SCRATCH) as directory:
                    run = StubRun(directory, CLL_CONTAINER_NAME=bad)
                    rc = run.finish()
                    self.assertEqual(rc, 2)
                    self.assertEqual(run.calls(), [])

    def test_invalid_override_rejected_by_backend_launchers(self):
        # The WeasyPrint and Typst launchers validate CLL_CONTAINER_NAME
        # exactly as the Prince launcher does: a bad override fails before
        # the first engine call, and no container ever starts.
        for launcher in ('run_weasyprint_container.sh',
                         'run_typst_container.sh'):
            for bad in ('-leading-hyphen', 'has space', 'ends-newline\n'):
                with self.subTest(launcher=launcher, name=bad):
                    with tempfile.TemporaryDirectory(dir=SCRATCH) as parent:
                        tree = make_launcher_tree(
                            Path(parent) / launcher.replace('.sh', ''),
                            launcher=launcher)
                        with tempfile.TemporaryDirectory(
                                dir=SCRATCH) as directory:
                            run = StubRun(directory, tree=tree,
                                          script=launcher,
                                          STUB_BUILD_SLEEP='0',
                                          STUB_RUN_SLEEP='0',
                                          CLL_CONTAINER_NAME=bad)
                            rc = run.finish()
                            self.assertEqual(rc, 2)
                            self.assertEqual(run.calls(), [])
                            self.assertEqual(run.markers(), [])

    def test_valid_override_runs_to_completion(self):
        with tempfile.TemporaryDirectory(dir=SCRATCH) as directory:
            name = 'my-run_2.0'
            run = StubRun(directory, STUB_BUILD_SLEEP='0',
                          STUB_RUN_SLEEP='1', CLL_CONTAINER_NAME=name)
            rc = run.finish()
            self.assertEqual(rc, 0)
            lines = '\n'.join(run.calls())
            log = run.log_text()
            self.assertIn('--name %s' % name, lines, lines)
            self.assertIn('--label cll.run=', lines, lines)
            self.assertNotIn('--cidfile', log, log)
            self.assertNotIn('--iidfile', log, log)
            self.assertEqual(run.markers(), [])

    def test_normal_run_leaves_no_run_tag(self):
        # With --rm the engine removes the container itself when the run
        # ends, before the launcher's cleanup runs; the run tag must still
        # be gone in every launcher. The shared fixed tag stays.
        for launcher in ('run_container.sh', 'run_weasyprint_container.sh',
                         'run_typst_container.sh'):
            with self.subTest(launcher=launcher):
                with tempfile.TemporaryDirectory(dir=SCRATCH) as parent:
                    tree = make_launcher_tree(
                        Path(parent) / launcher.replace('.sh', ''),
                        launcher=launcher) if launcher != 'run_container.sh' \
                        else ROOT
                    with tempfile.TemporaryDirectory(
                            dir=SCRATCH) as directory:
                        run = StubRun(directory, tree=tree, script=launcher,
                                      STUB_BUILD_SLEEP='0',
                                      STUB_RUN_SLEEP='1')
                        rc = run.finish()
                        self.assertEqual(rc, 0, run.out_path.read_text())
                        self.assertEqual(run.markers(), [])
                        self.assertEqual(run.run_tags(), [],
                                         run.tags())
                        self.assertEqual(len(run.tags()), 1, run.tags())

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
                self.assertEqual(len(first.markers()), 1)
                self.assertIn('shared-name', first.named())
                rc = first.finish(sig=signal.SIGTERM)
                self.assertEqual(rc, -signal.SIGTERM)
                self.assertEqual(first.markers(), [])

    def test_successor_removal_race_uses_full_id(self):
        # A is cancelled while its cleanup's stop calls the stub; B takes
        # the name before the rm. A must remove its own full ID and leave
        # B's container running.
        with tempfile.TemporaryDirectory(dir=SCRATCH) as parent:
            a_tree = make_launcher_tree(Path(parent) / 'a')
            b_tree = make_launcher_tree(Path(parent) / 'b')
            with tempfile.TemporaryDirectory(dir=SCRATCH) as directory:
                hold = Path(directory) / 'hold-rm'
                first = StubRun(directory, tree=a_tree,
                                STUB_BUILD_SLEEP='0',
                                STUB_RUN_SLEEP='30',
                                STUB_RM_HOLD=str(hold),
                                CLL_CONTAINER_NAME='race-name')
                self.assertTrue(first.wait_for('run-start'),
                                'first run never started the container')
                first_a = first.named()
                self.assertIn('race-name', first_a)
                tag_a = first_a['race-name']
                cid_a = first.markers()
                self.assertEqual(len(cid_a), 1)
                cid_a = cid_a[0]
                # Cancel A so its cleanup is waiting inside the rm call,
                # after its stop already freed the name.
                first.proc.send_signal(signal.SIGTERM)
                self.assertTrue(first.wait_for('call rm -f %s' % cid_a),
                                'cleanup never removed its own ID: %s'
                                % first.log_text())
                # B takes the freed name while A is still stopping it.
                second = StubRun(directory, tree=b_tree,
                                 out_name='second-stdout.txt',
                                 STUB_BUILD_SLEEP='0',
                                 STUB_RUN_SLEEP='30',
                                 CLL_CONTAINER_NAME='race-name')
                self.assertTrue(second.wait_for('run-start'),
                                'second run never started: %s'
                                % second.log_text())
                hold.write_text('go')
                self.assertEqual(first.finish(), -signal.SIGTERM)
                live = second.named()
                self.assertIn('race-name', live,
                              'successor container was removed: %s'
                              % second.log_text())
                self.assertNotEqual(live['race-name'], tag_a)
                # With the old remove-by-name, A's rm would have taken the
                # successor's name instead and the assertion above fails.
                second.finish(sig=signal.SIGTERM)
                self.assertEqual(second.markers(), [])
                self.assertEqual(second.run_tags(), [], second.tags())

    def test_rmi_retry_removes_run_tag(self):
        # The first untag can fail (a real engine can hold the image for
        # a moment after --rm auto-removal); the launcher retries and the
        # run tag is still gone at exit.
        with tempfile.TemporaryDirectory(dir=SCRATCH) as directory:
            run = StubRun(directory, STUB_BUILD_SLEEP='0',
                          STUB_RUN_SLEEP='1', STUB_RMI_FAIL_ONCE='1')
            rc = run.finish()
            self.assertEqual(rc, 0)
            self.assertIn('rmi-failed-once', run.log_text())
            self.assertGreaterEqual(
                run.log_text().count('call rmi '), 2,
                run.log_text())
            self.assertEqual(run.markers(), [])

    def test_cleanup_needs_nonempty_matching_tag(self):
        # Unit test of cll_cleanup_container's guards: with no run tag (an
        # exit before the tag exists) an unlabelled same-named foreign
        # container must survive. The old code compared the empty tag with
        # the empty label and removed it by name. With a matching nonempty
        # tag the run's own container is still removed, by its full ID.
        with tempfile.TemporaryDirectory(dir=SCRATCH) as directory:
            work = Path(directory)
            (work / 'by-id').mkdir()
            (work / 'by-name').mkdir()
            (work / 'by-id' / 'foreign-cid').write_text('')
            (work / 'by-name' / 'lone-wolf').write_text('foreign-cid')
            (work / 'by-id' / 'own-cid').write_text('mytag')
            (work / 'by-name' / 'mine').write_text('own-cid')
            stub = work / 'stub-engine.sh'
            stub.write_text(STUB_ENGINE)
            stub.chmod(stub.stat().st_mode | stat.S_IXUSR)
            env = {k: v for k, v in os.environ.items()
                   if k != 'CLL_CONTAINER_NAME'}
            env.update(STUB_LOG=str(work / 'engine.log'),
                       STUB_DIR=str(work))
            run_cleanup = ('. "{}"; engine=("{}"); '
                           'cll_name="$0"; cll_run_tag="$1"; '
                           'cll_cleanup_container').format(HELPER, stub)
            subprocess.run(['bash', '-c', run_cleanup, 'lone-wolf', ''],
                           check=True, text=True, env=env)
            self.assertTrue((work / 'by-id' / 'foreign-cid').exists())
            self.assertTrue((work / 'by-name' / 'lone-wolf').exists())
            subprocess.run(['bash', '-c', run_cleanup, 'mine', 'mytag'],
                           check=True, text=True, env=env)
            self.assertFalse((work / 'by-id' / 'own-cid').exists())
            self.assertFalse((work / 'by-name' / 'mine').exists())

    def test_lock_conflict_leaves_foreign_container(self):
        # An early exit (lock conflict here) must not touch a container it
        # never owned, even when the override name matches and both sides
        # have an empty run tag. The foreign container must survive.
        with tempfile.TemporaryDirectory(dir=SCRATCH) as directory:
            work = Path(directory)
            (work / 'by-id').mkdir()
            (work / 'by-name').mkdir()
            (work / 'by-id' / 'foreign-cid').write_text('')
            (work / 'by-name' / 'lone-wolf').write_text('foreign-cid')
            first = StubRun(directory, STUB_BUILD_SLEEP='30',
                            STUB_RUN_SLEEP='1',
                            CLL_CONTAINER_NAME='lone-wolf')
            self.assertTrue(first.wait_for('call build '),
                            'first run never reached the build')
            second = StubRun(directory, out_name='second-stdout.txt',
                             STUB_BUILD_SLEEP='0', STUB_RUN_SLEEP='1',
                             CLL_CONTAINER_NAME='lone-wolf')
            rc = second.finish()
            self.assertEqual(rc, 1)
            self.assertFalse(
                any('call build' in line for line in second.calls()),
                '\n'.join(second.calls()))
            self.assertTrue((work / 'by-id' / 'foreign-cid').exists())
            self.assertTrue((work / 'by-name' / 'lone-wolf').exists())
            # SIGTERM, not SIGKILL: the trap must run so the engine child
            # exits and releases the checkout lock for the next test. A
            # SIGKILL would orphan the stub sleep holding the lock.
            first.finish(sig=signal.SIGTERM)

    def test_rebuilt_tag_keeps_other_run_image_alive(self):
        # Docker's store drops an image as soon as its last tag moves.
        # B rebuilds the shared tag while A waits to run; A's own run tag
        # keeps its image alive, so A still starts it.
        with tempfile.TemporaryDirectory(dir=SCRATCH) as parent:
            a_tree = make_launcher_tree(
                Path(parent) / 'a',
                ['FROM example/base\n', 'ENV TREE=a\n'])
            b_tree = make_launcher_tree(
                Path(parent) / 'b',
                ['FROM example/base\n', 'ENV TREE=b\n'])
            with tempfile.TemporaryDirectory(dir=SCRATCH) as directory:
                gate = Path(directory) / 'release-a'
                first = StubRun(directory, tree=a_tree,
                                STUB_BUILD_SLEEP='1',
                                STUB_RUN_SLEEP='5',
                                STUB_IMAGE_ID='img-aaa',
                                STUB_RUN_HOLD=str(gate),
                                CLL_CONTAINER_NAME='img-run-a')
                self.assertTrue(first.wait_for('call run'),
                                'first run never reached its container')
                second = StubRun(directory, tree=b_tree,
                                 out_name='second-stdout.txt',
                                 truncate_log=False,
                                 STUB_BUILD_SLEEP='1',
                                 STUB_RUN_SLEEP='1',
                                 STUB_IMAGE_ID='img-bbb',
                                 CLL_CONTAINER_NAME='img-run-b')
                self.assertEqual(second.finish(), 0)
                log = second.log_text()
                own = [line for line in log.splitlines()
                       if line.startswith('call run ') and 'img-run-b' in line]
                self.assertEqual(len(own), 1, log)
                self.assertIn(' img-bbb ', own[0], own[0])
                self.assertNotIn('run-no-such-image', log, log)
                gate.write_text('')
                self.assertEqual(first.finish(), 0)
                log = first.log_text()
                own = [line for line in log.splitlines()
                       if line.startswith('call run ') and 'img-run-a' in line]
                self.assertEqual(len(own), 1, log)
                self.assertIn(' img-aaa ', own[0], own[0])
                self.assertNotIn('run-no-such-image', log, log)
                self.assertEqual(first.markers(), [])
                self.assertEqual(second.markers(), [])

    def test_image_references_are_valid(self):
        # Every tag the launchers generate has one colon after the last
        # slash and valid tag characters; each build also carries a
        # run-unique tag that names the launcher process and a random
        # value, so PIDs reused across namespaces cannot collide.
        tag_part = re.compile(r'^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$')

        def check(ref):
            self.assertIn('/', ref)
            name, colon, tag = ref.rpartition(':')
            self.assertEqual(colon, ':', ref)
            self.assertNotIn('/', tag, ref)
            self.assertRegex(tag, tag_part)

        def build_tags(lines):
            tags = []
            for line in lines:
                if not line.startswith('call build '):
                    continue
                tokens = line.split(' ')
                i = 2
                while i < len(tokens):
                    if tokens[i] == '-t' and i + 1 < len(tokens):
                        tags.append(tokens[i + 1])
                        i += 2
                    elif tokens[i] in ('--iidfile', '-f', '--target'):
                        i += 2
                    else:
                        i += 1
            return tags

        launchers = (('run_container.sh', 'img-prince'),
                     ('run_weasyprint_container.sh', 'img-weasy'),
                     ('run_typst_container.sh', 'img-typst'))
        with tempfile.TemporaryDirectory(dir=SCRATCH) as parent:
            for launcher, image in launchers:
                with self.subTest(launcher=launcher):
                    tree = make_launcher_tree(
                        Path(parent) / launcher.replace('.sh', ''),
                        launcher=launcher)
                    with tempfile.TemporaryDirectory(dir=SCRATCH) as directory:
                        run = StubRun(directory, tree=tree, script=launcher,
                                      STUB_BUILD_SLEEP='0',
                                      STUB_RUN_SLEEP='1',
                                      STUB_IMAGE_ID=image)
                        self.assertEqual(run.finish(), 0,
                                         run.out_path.read_text())
                        lines = run.log_text().splitlines()
                        tags = build_tags(lines)
                        self.assertEqual(len(tags), 2, lines)
                        self.assertNotEqual(tags[0], tags[1])
                        for tag in tags:
                            check(tag)
                        # The shared tags cannot match: their tag parts
                        # are 'latest' or hex digits, never 'run-...'.
                        run_tags = [tag for tag in tags
                                    if re.search(r'run-%d-[A-Za-z0-9]+$'
                                                 % run.pid, tag)]
                        self.assertEqual(len(run_tags), 1, tags)
                        run_calls = [line for line in lines
                                     if line.startswith('call run ')]
                        self.assertEqual(len(run_calls), 1, lines)
                        self.assertIn(' %s ' % image, run_calls[0])
                        self.assertIn('--label cll.run=', run_calls[0],
                                      run_calls[0])
                        # Nothing the launcher reads comes from an
                        # engine-written file: no --iidfile/--cidfile flags
                        # anywhere, and the image ID comes from
                        # `image inspect`.
                        self.assertFalse(
                            any('--iidfile' in line or '--cidfile' in line
                                for line in lines), lines)
                        self.assertTrue(
                            any(line.startswith('call image inspect ')
                                for line in lines), lines)
                        self.assertEqual(run.temp_files(), [])

    def test_backend_launchers_term_during_build(self):
        # A TERM to the launcher PID alone during the image build stops
        # the build at once for the WeasyPrint and Typst launchers too:
        # no container ever starts and nothing is left behind.
        for launcher in ('run_weasyprint_container.sh',
                         'run_typst_container.sh'):
            with self.subTest(launcher=launcher):
                with tempfile.TemporaryDirectory(dir=SCRATCH) as parent:
                    tree = make_launcher_tree(
                        Path(parent) / launcher.replace('.sh', ''),
                        launcher=launcher)
                    with tempfile.TemporaryDirectory(dir=SCRATCH) as directory:
                        run = StubRun(directory, tree=tree, script=launcher,
                                      STUB_BUILD_SLEEP='30',
                                      STUB_RUN_SLEEP='1')
                        self.assertTrue(run.wait_for('build-start'),
                                        'stub never started the image build')
                        time.sleep(1)
                        t0 = time.monotonic()
                        rc = run.finish(sig=signal.SIGTERM)
                        self.assertEqual(rc, -signal.SIGTERM)
                        self.assertLess(time.monotonic() - t0, 15,
                                        'launcher did not stop promptly')
                        self.assertFalse(
                            any('call run' in line for line in run.calls()),
                            '\n'.join(run.calls()))
                        assert_no_engine_kill(self, run)
                        self.assertEqual(run.markers(), [])
                        self.assertEqual(run.temp_files(), [])

    def test_backend_launchers_failed_build(self):
        # A failed image build stops the WeasyPrint and Typst launchers
        # before any container starts and leaves nothing behind.
        for launcher in ('run_weasyprint_container.sh',
                         'run_typst_container.sh'):
            with self.subTest(launcher=launcher):
                with tempfile.TemporaryDirectory(dir=SCRATCH) as parent:
                    tree = make_launcher_tree(
                        Path(parent) / launcher.replace('.sh', ''),
                        launcher=launcher)
                    with tempfile.TemporaryDirectory(dir=SCRATCH) as directory:
                        run = StubRun(directory, tree=tree, script=launcher,
                                      STUB_BUILD_SLEEP='0',
                                      STUB_BUILD_RC='3')
                        self.assertEqual(run.finish(), 1,
                                         run.out_path.read_text())
                        self.assertFalse(
                            any('call run' in line for line in run.calls()),
                            '\n'.join(run.calls()))
                        self.assertEqual(run.markers(), [])
                        self.assertEqual(run.temp_files(), [])

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

    def test_missing_flock_warns_and_runs(self):
        # Without flock on PATH the launcher warns instead of reporting a
        # busy checkout, and the build still runs.
        with tempfile.TemporaryDirectory(dir=SCRATCH) as directory:
            farm = Path(directory) / 'bin'
            farm.mkdir()
            for entry in Path('/usr/bin').iterdir():
                if entry.name == 'flock':
                    continue
                try:
                    os.symlink(entry, farm / entry.name)
                except OSError:
                    pass
            work = Path(directory) / 'work'
            work.mkdir()
            stub = work / 'stub-engine.sh'
            stub.write_text(STUB_ENGINE)
            stub.chmod(stub.stat().st_mode | stat.S_IXUSR)
            env = {k: v for k, v in os.environ.items()
                   if k != 'CLL_CONTAINER_NAME'}
            env['PATH'] = str(farm)
            env['CONTAINER_BIN'] = str(stub)
            env['CLL_BUILD_VERSION'] = 'test'
            env['STUB_LOG'] = str(work / 'engine.log')
            env['STUB_DIR'] = str(work)
            env['TMPDIR'] = str(work)
            env['STUB_BUILD_SLEEP'] = '0'
            env['STUB_RUN_SLEEP'] = '1'
            out_path = work / 'stdout.txt'
            with out_path.open('w') as out:
                proc = subprocess.Popen(
                    ['bash', str(ROOT / 'run_container.sh')],
                    stdout=out, stderr=subprocess.STDOUT,
                    env=env, cwd=str(ROOT), start_new_session=True)
                rc = proc.wait(timeout=60)
            self.assertEqual(rc, 0, out_path.read_text())
            self.assertIn('flock not found', out_path.read_text())
            run_calls = [line for line in
                         (work / 'engine.log').read_text().splitlines()
                         if line.startswith('call run ')]
            self.assertEqual(len(run_calls), 1)
            self.assertEqual(
                [p.name for p in work.glob('cll-run*')], [])


if __name__ == '__main__':
    SCRATCH.mkdir(parents=True, exist_ok=True)
    unittest.main()
