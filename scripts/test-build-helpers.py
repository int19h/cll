#!/usr/bin/env python3
"""Failure behavior of the build helpers (issues #80, #110, #232).

The XHTML post-processors must stop when a tool fails and must not replace a
page with an empty file. cll_build must surface a failed scripts/diff_official.
cll_build -j must refresh dictionary/all_words.xml. The Gemfile must record the
gems the Dockerfiles install.

Run: python3 scripts/test-build-helpers.py
"""
import os
import shutil
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CLEANUP = ROOT / "scripts" / "xhtml_postprocess_cleanup.sh"
UPDATER = ROOT / "scripts" / "update_jbovlaste_xml.sh"

PAGE = """<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml"><head><title>T</title></head><body>
<p>keep this sentence</p>
</body></html>
"""

DICTIONARY = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<dictionary>
  <direction from="lojban" to="English">
    <valsi word="coi">
      <definition>hello, a greeting long enough to pass the updater size check.</definition>
    </valsi>
  </direction>
</dictionary>
"""

OTHER_DICTIONARY = DICTIONARY.replace("hello, a greeting", "goodbye, a farewell")

TOOLS = (
    "bash", "dirname", "readlink", "mktemp", "chmod", "mv", "rm", "cp", "stat",
    "diff", "xmllint", "find", "grep", "sed", "sort", "date", "cat", "wget",
)


def write_executable(path, text):
    path.write_text(text)
    path.chmod(0o755)


def tool_bin(directory, overrides):
    """A PATH directory of real tools, with named commands replaced."""
    bindir = directory / "bin"
    if bindir.exists():
        shutil.rmtree(bindir)
    bindir.mkdir()
    names = list(TOOLS)
    for name in overrides:
        if name not in names:
            names.append(name)
    for name in names:
        if name in overrides:
            write_executable(bindir / name, overrides[name])
            continue
        source = shutil.which(name)
        if source:
            os.symlink(source, bindir / name)
    return bindir


def ruby_cat():
    return "#!/bin/bash\ncat \"$2\"\n"


def ruby_fail():
    return "#!/bin/bash\necho 'ruby failed' >&2\nexit 1\n"


def wget_fake():
    return """#!/bin/bash
set -u
printf '%s\\n' "$*" >> "$WGET_LOG"
out=""
prev=""
for arg in "$@"; do
  if [[ "$prev" == "-O" ]]; then
    out=$arg
  fi
  prev=$arg
done
if [[ -n "${WGET_BODY:-}" ]]; then
  cp "$WGET_BODY" "$out"
fi
exit "$WGET_RC"
"""


class PostprocessFailures(unittest.TestCase):
    def run_script(self, script, html_dir, overrides):
        bindir = tool_bin(html_dir, overrides)
        env = os.environ.copy()
        env["PATH"] = str(bindir)
        return subprocess.run(
            ["bash", str(script), str(html_dir)],
            cwd=html_dir,
            env=env,
            capture_output=True,
            text=True,
        )

    def page(self, directory, name="index.html", text=PAGE, mode=0o640):
        path = directory / name
        path.write_text(text)
        path.chmod(mode)
        return path

    def leftovers(self, directory):
        names = []
        for path in directory.rglob("*"):
            if path.is_file() and ".dtd" not in path.parts and path.parent != directory / "bin":
                if path.name != "index.html" and path.name != "notes.txt":
                    if path.suffix not in {".html", ".txt"}:
                        names.append(path.name)
                    elif path.name not in {"index.html", "other.html", "notes.txt"}:
                        names.append(path.name)
        return names

    def test_scripts_parse(self):
        for path in (CLEANUP, UPDATER, ROOT / "scripts" / "diff_official", ROOT / "cll_build"):
            subprocess.run(["bash", "-n", str(path)], check=True)

    def test_missing_ruby_keeps_the_page(self):
        # A named entity other than the five XML ones fails the strict parse
        # now that cleanup does not load a DTD. The original page stays.
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            page = self.page(directory, text=PAGE.replace("keep this sentence", "keep &nbsp; this"))
            before = page.read_bytes()
            result = self.run_script(CLEANUP, directory, {})
            self.assertNotEqual(result.returncode, 0, result.stderr)
            self.assertEqual(page.read_bytes(), before)
            self.assertGreater(page.stat().st_size, 0)
            self.assertEqual(self.leftovers(directory), [])

    def test_failed_ruby_keeps_the_page(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            page = self.page(directory)
            before = page.read_bytes()
            result = self.run_script(CLEANUP, directory, {"ruby": ruby_fail()})
            self.assertNotEqual(result.returncode, 0, result.stderr)
            self.assertEqual(page.read_bytes(), before)
            self.assertEqual(self.leftovers(directory), [])

    def test_cleanup_does_not_call_xmllint(self):
        self.assertNotIn("xmllint", CLEANUP.read_text())

    def test_cleanup_succeeds(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            shutil.copytree(ROOT / "dtd", directory / "dtd")
            page = self.page(directory)
            other = self.page(directory, "other.html", PAGE.replace("keep this sentence", "other sentence"))
            notes = self.page(directory, "notes.txt", "leave me\n", mode=0o644)
            notes_before = notes.read_bytes()
            result = self.run_script(CLEANUP, directory, {"ruby": ruby_cat()})
            self.assertEqual(result.returncode, 0, result.stderr)
            text = page.read_text()
            self.assertEqual(text, PAGE)
            self.assertNotIn("manifest=", text)
            self.assertNotIn("xml:lang=", text)
            self.assertIn("keep this sentence", text)
            self.assertIn("other sentence", other.read_text())
            self.assertNotIn("manifest=", other.read_text())
            self.assertEqual(notes.read_bytes(), notes_before)
            self.assertEqual(stat.S_IMODE(page.stat().st_mode), 0o640)
            self.assertGreater(page.stat().st_size, 0)

    def test_directory_argument_is_required(self):
        result = subprocess.run(["bash", str(CLEANUP)], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)


class DictionaryRefresh(unittest.TestCase):
    def setUp(self):
        self.assertGreater(len(DICTIONARY.encode()), 100)
        self.assertNotEqual(DICTIONARY, OTHER_DICTIONARY)

    def stage(self, temporary):
        root = Path(temporary)
        scripts = root / "scripts"
        scripts.mkdir()
        shutil.copy2(UPDATER, scripts / UPDATER.name)
        (root / "dictionary").mkdir()
        (root / "build").mkdir()
        return root

    def run_updater(self, root, *args, body=None, wget_rc=0):
        bindir = tool_bin(root, {"wget": wget_fake()})
        log = root / "wget.log"
        env = os.environ.copy()
        env["PATH"] = str(bindir)
        env["WGET_LOG"] = str(log)
        env["WGET_RC"] = str(wget_rc)
        env.pop("WGET_BODY", None)
        if body is not None:
            body_path = root / "wget-body.xml"
            body_path.write_text(body)
            env["WGET_BODY"] = str(body_path)
        result = subprocess.run(
            ["bash", str(root / "scripts" / UPDATER.name), *args],
            env=env,
            capture_output=True,
            text=True,
        )
        return result, log

    def test_existing_dictionary_is_reused_until_refresh(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = self.stage(temporary)
            dictionary = root / "dictionary" / "all_words.xml"
            dictionary.write_text(DICTIONARY)
            result, log = self.run_updater(root, str(root / "build"))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(log.exists())
            self.assertIn("cll_build -j", result.stdout)
            self.assertEqual((root / "build" / "jbovlaste.xml").read_text(), DICTIONARY)

    def test_refresh_replaces_the_dictionary_only_after_validation(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = self.stage(temporary)
            dictionary = root / "dictionary" / "all_words.xml"
            dictionary.write_text(DICTIONARY)
            result, log = self.run_updater(
                root, str(root / "build"), "--refresh", body=OTHER_DICTIONARY)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(log.exists())
            self.assertEqual(dictionary.read_text(), OTHER_DICTIONARY)
            self.assertEqual(stat.S_IMODE(dictionary.stat().st_mode), 0o644)
            self.assertEqual((root / "build" / "jbovlaste.xml").read_text(), OTHER_DICTIONARY)
            temps = list((root / "dictionary").glob("all_words.xml.*"))
            self.assertEqual(temps, [])

    def test_missing_dictionary_is_downloaded(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = self.stage(temporary)
            result, log = self.run_updater(root, str(root / "build"), body=DICTIONARY)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(log.exists())
            self.assertEqual((root / "dictionary" / "all_words.xml").read_text(), DICTIONARY)

    def test_failed_download_keeps_the_existing_dictionary(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = self.stage(temporary)
            dictionary = root / "dictionary" / "all_words.xml"
            dictionary.write_text(DICTIONARY)
            before = dictionary.read_bytes()
            result, _log = self.run_updater(
                root, str(root / "build"), "--refresh", body="not saved", wget_rc=1)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("was not changed", result.stderr)
            self.assertEqual(dictionary.read_bytes(), before)
            self.assertEqual(list((root / "dictionary").glob("all_words.xml.*")), [])
            self.assertFalse((root / "build" / "jbovlaste.xml").exists())

    def test_empty_or_invalid_download_keeps_the_existing_dictionary(self):
        cases = {"empty": "", "invalid": "this is not xml\n" * 20}
        for name, body in cases.items():
            with self.subTest(name=name):
                with tempfile.TemporaryDirectory() as temporary:
                    root = self.stage(temporary)
                    dictionary = root / "dictionary" / "all_words.xml"
                    dictionary.write_text(DICTIONARY)
                    before = dictionary.read_bytes()
                    result, _log = self.run_updater(
                        root, str(root / "build"), "--refresh", body=body)
                    self.assertNotEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(dictionary.read_bytes(), before)
                    self.assertEqual(list((root / "dictionary").glob("all_words.xml.*")), [])

    def test_unknown_option_fails_before_download(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = self.stage(temporary)
            result, log = self.run_updater(root, str(root / "build"), "--nope")
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(log.exists())

    def test_usage_without_a_build_directory(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = self.stage(temporary)
            result, _log = self.run_updater(root)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("BUILD_DIR", result.stderr)


class CllBuildStatus(unittest.TestCase):
    def stage(self, temporary, make_rc, diff_rc, update_rc):
        root = Path(temporary)
        shutil.copy2(ROOT / "cll_build", root / "cll_build")
        scripts = root / "scripts"
        scripts.mkdir()
        write_executable(scripts / "record-build-toolchain.sh", "#!/bin/bash\nmkdir -p \"$1\"\n")
        write_executable(
            scripts / "diff_official",
            "#!/bin/bash\necho called > \"$DIFF_LOG\"\nexit \"$DIFF_RC\"\n",
        )
        write_executable(
            scripts / "update_jbovlaste_xml.sh",
            "#!/bin/bash\nprintf '%s\\n' \"$@\" > \"$UPDATE_LOG\"\nexit \"$UPDATE_RC\"\n",
        )
        chapters = root / "chapters"
        chapters.mkdir()
        (chapters / "01.xml").write_text("<chapter/>\n")
        xml = root / "xml"
        xsl = xml / "docbook-xsl-1.78.1"
        xsl.mkdir(parents=True)
        for number in range(1944):
            (xsl / f"f{number}").touch()
        os.symlink(ROOT / "xml" / "docbook-xsl-1.78.1.zip", xml / "docbook-xsl-1.78.1.zip")
        bindir = root / "bin"
        bindir.mkdir()
        write_executable(
            bindir / "make",
            "#!/bin/bash\nprintf '%s\\n' \"$*\" > \"$MAKE_LOG\"\nexit \"$MAKE_RC\"\n",
        )
        write_executable(bindir / "wget", "#!/bin/bash\necho 'wget should not run' >&2\nexit 99\n")
        env = os.environ.copy()
        env["PATH"] = str(bindir) + os.pathsep + env["PATH"]
        env.update({
            "MAKE_LOG": str(root / "make.log"),
            "MAKE_RC": str(make_rc),
            "DIFF_LOG": str(root / "diff.log"),
            "DIFF_RC": str(diff_rc),
            "UPDATE_LOG": str(root / "update.log"),
            "UPDATE_RC": str(update_rc),
        })
        return root, env

    def run_build(self, root, env, *args):
        return subprocess.run(
            ["bash", str(root / "cll_build"), *args],
            cwd=root,
            env=env,
            capture_output=True,
            text=True,
        )

    def test_diff_failure_is_visible(self):
        with tempfile.TemporaryDirectory() as temporary:
            root, env = self.stage(temporary, make_rc=0, diff_rc=9, update_rc=0)
            result = self.run_build(root, env)
            self.assertEqual(result.returncode, 9, result.stderr)
            self.assertIn("scripts/diff_official failed", result.stderr)
            self.assertIn("status 9", result.stderr)
            self.assertIn("-n", result.stderr)
            self.assertTrue((root / "diff.log").exists())
            self.assertIn("xsl already unpacked", result.stdout)

    def test_skip_flag_does_not_run_the_diff(self):
        with tempfile.TemporaryDirectory() as temporary:
            root, env = self.stage(temporary, make_rc=0, diff_rc=9, update_rc=0)
            result = self.run_build(root, env, "-n")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse((root / "diff.log").exists())
            self.assertTrue((root / "make.log").exists())

    def test_make_failure_skips_the_diff(self):
        with tempfile.TemporaryDirectory() as temporary:
            root, env = self.stage(temporary, make_rc=4, diff_rc=0, update_rc=0)
            result = self.run_build(root, env)
            self.assertEqual(result.returncode, 4, result.stderr)
            self.assertIn("BUILD FAILED", result.stderr)
            self.assertFalse((root / "diff.log").exists())

    def test_refresh_flag_fetches_before_make(self):
        with tempfile.TemporaryDirectory() as temporary:
            root, env = self.stage(temporary, make_rc=0, diff_rc=0, update_rc=0)
            result = self.run_build(root, env, "-j", "-n")
            self.assertEqual(result.returncode, 0, result.stderr)
            log = (root / "update.log").read_text().splitlines()
            self.assertEqual(log, ["build", "--refresh"])
            self.assertTrue((root / "make.log").exists())

    def test_refresh_failure_stops_the_build(self):
        with tempfile.TemporaryDirectory() as temporary:
            root, env = self.stage(temporary, make_rc=0, diff_rc=0, update_rc=3)
            result = self.run_build(root, env, "-j", "-n")
            self.assertEqual(result.returncode, 3, result.stderr)
            self.assertFalse((root / "make.log").exists())

    def test_usage_names_the_dictionary_file(self):
        result = subprocess.run(
            ["bash", str(ROOT / "cll_build"), "-h"],
            cwd=ROOT,
            capture_output=True,
            text=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("dictionary/all_words.xml", result.stdout)
        self.assertNotIn("xml/jbovlaste.xml", result.stdout)

    def test_diff_official_failure_is_nonzero(self):
        with tempfile.TemporaryDirectory() as temporary:
            result = subprocess.run(
                ["bash", str(ROOT / "scripts" / "diff_official")],
                cwd=temporary,
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(result.returncode, 0)


class GemPins(unittest.TestCase):
    def test_lockfile_matches_the_docker_pins(self):
        gemfile = (ROOT / "Gemfile").read_text()
        lock = (ROOT / "Gemfile.lock").read_text()
        self.assertIn("gem 'nokogiri', '= 1.18.8'", gemfile)
        self.assertIn("gem 'optimist', '= 3.2.0'", gemfile)
        self.assertIn("gem 'htmlentities', '= 4.3.4'", gemfile)
        self.assertIn("nokogiri (1.18.8-aarch64-linux-gnu)", lock)
        self.assertIn("nokogiri (1.18.8-x86_64-linux-gnu)", lock)
        self.assertIn("optimist (3.2.0)", lock)
        self.assertIn("htmlentities (4.3.4)", lock)
        self.assertNotIn("nokogiri (1.10", lock)
        self.assertNotIn("mini_portile2", lock)
        for platform in ("aarch64-linux", "aarch64-linux-gnu", "x86_64-linux", "x86_64-linux-gnu"):
            self.assertIn(platform, lock)
        self.assertNotIn("2.0.2", lock.split("BUNDLED WITH", 1)[1])
        for name in ("Dockerfile", "Dockerfile.weasyprint", "Dockerfile.context"):
            text = (ROOT / name).read_text()
            self.assertIn(
                "gem install --no-document nokogiri:1.18.8 optimist:3.2.0 htmlentities:4.3.4",
                text,
            )


if __name__ == "__main__":
    unittest.main()
