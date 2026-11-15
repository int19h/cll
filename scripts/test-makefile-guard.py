#!/usr/bin/env python3
"""The pages Makefile refuses folder variables that would let clean or a
recipe delete outside the build folders (issue #271, review round 2).

Each case runs make in a scratch checkout with a sentinel source file.
Refused cases must fail before any recipe runs and keep the sentinel.

Run: python3 scripts/test-makefile-guard.py
"""
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
MAKEFILE = HERE / "Makefile"
HELPER = HERE / "safe-rm-tree.sh"

fails = 0


def check(what, cond):
    global fails
    if cond:
        print(f"ok   {what}")
    else:
        print(f"FAIL {what}")
        fails += 1


def scratch(base, name, build_link=None):
    root = base / name
    (root / "scripts").mkdir(parents=True)
    (root / "chapters").mkdir()
    (root / ".git").mkdir()
    shutil.copy(MAKEFILE, root / "scripts" / "Makefile")
    shutil.copy(HELPER, root / "scripts" / "safe-rm-tree.sh")
    sentinel = root / "chapters" / "source.xml"
    sentinel.write_text("source")
    (root / "coverage" / "build").mkdir(parents=True)
    if build_link is None:
        (root / "build").mkdir()
    else:
        (root / "build").symlink_to(build_link, target_is_directory=True)
    return root, sentinel


def make(root, *args, dry=False):
    cmd = ["make"] + (["-n"] if dry else []) + [
        "-f", "scripts/Makefile", "chapters=chapters/source.xml",
        *args, "clean"]
    env = dict(os.environ, PWD=str(root))
    return subprocess.run(cmd, cwd=root, env=env, capture_output=True, text=True)


def main():
    with tempfile.TemporaryDirectory() as td:
        t = Path(td).resolve()

        # Refusals: real clean, sentinel must survive.
        cases = []

        root, s = scratch(t, "linkdot", build_link=".")
        cases.append(("build -> . link", root, s, ["builddir=build"]))

        root, s = scratch(t, "dot")
        cases.append(("builddir=.", root, s, ["builddir=."]))

        root, s = scratch(t, "chapters")
        cases.append(("builddir=chapters", root, s, ["builddir=chapters"]))

        root, s = scratch(t, "twowords")
        cases.append(("two-word builddir", root, s, ["builddir=build extra"]))

        root, s = scratch(t, "slash")
        cases.append(("builddir=/", root, s, ["builddir=/"]))

        root, s = scratch(t, "outside")
        cases.append(("outside builddir, no flag", root, s,
                      [f"builddir={t}/elsewhere"]))

        root, s = scratch(t, "override")
        cases.append(("internal variable override", root, s,
                      ["builddir=chapters", f"_builddir_res={root}/build"]))

        root, s = scratch(t, "parent")
        cases.append(("parent of checkout, even with flag", root, s,
                      ["builddir=..", "ALLOW_OUTSIDE_BUILDDIR=yes"]))

        root, s = scratch(t, "linkchapters", build_link="chapters")
        cases.append(("build -> chapters link", root, s,
                      ["builddir=coverage/build"]))

        root, s = scratch(t, "copyhome")
        cases.append(("copydir is home", root, s,
                      ["builddir=build", f"copydir={Path.home()}",
                       "ALLOW_OUTSIDE_BUILDDIR=yes"]))

        for what, root, s, args in cases:
            res = make(root, *args)
            check(f"refuses {what}", res.returncode != 0 and s.exists())

        # Allowed: dry run only, so nothing is deleted here either.
        root, s = scratch(t, "normal")
        res = make(root, "builddir=build", dry=True)
        check("allows builddir=build", res.returncode == 0 and s.exists())

        sep = t / "separate-build"
        sep.mkdir()
        root, s = scratch(t, "linksep", build_link=str(sep))
        res = make(root, "builddir=build", dry=True)
        check("allows build -> separate folder link",
              res.returncode == 0 and s.exists())

        root, s = scratch(t, "flagged")
        res = make(root, f"builddir={t}/elsewhere",
                   "ALLOW_OUTSIDE_BUILDDIR=yes", dry=True)
        check("allows outside builddir with ALLOW_OUTSIDE_BUILDDIR=yes",
              res.returncode == 0 and s.exists())

        root, s = scratch(t, "covbuild")
        res = make(root, "builddir=coverage/build", dry=True)
        check("allows builddir=coverage/build", res.returncode == 0)

        # A file name with a space under build/ must not split into a
        # second path relative to the checkout.
        root, s = scratch(t, "spacefile")
        (root / "build" / "a b").write_text("junk")
        (root / "b").write_text("keep")
        res = make(root, "builddir=build")
        check("clean handles a file name with a space",
              res.returncode == 0 and s.exists() and (root / "b").exists()
              and not (root / "build" / "a b").exists())

        # With the flag, clean also walks the outside builddir itself.
        root, s = scratch(t, "flagclean")
        ext = t / "extbuild"
        ext.mkdir()
        (ext / "junk").write_text("junk")
        res = make(root, f"builddir={ext}", "ALLOW_OUTSIDE_BUILDDIR=yes")
        check("clean walks a flagged outside builddir",
              res.returncode == 0 and s.exists() and not (ext / "junk").exists())

        root, s = scratch(t, "trailing")
        res = make(root, "builddir=build/", dry=True)
        check("allows builddir=build/ (trailing slash)", res.returncode == 0)

    print("FAILURES" if fails else "all ok")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
