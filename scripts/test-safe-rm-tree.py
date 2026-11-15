#!/usr/bin/env python3
"""Tests for scripts/safe-rm-tree.sh: every refusal, and the deletes it allows.

Run: python3 scripts/test-safe-rm-tree.py
"""
import os
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
HELPER = HERE / "safe-rm-tree.sh"

fails = 0


def check(what, cond):
    global fails
    if cond:
        print(f"ok   {what}")
    else:
        print(f"FAIL {what}")
        fails += 1


def run(root, *paths):
    return subprocess.run(
        ["bash", str(HELPER), "--root", str(root), *[str(p) for p in paths]],
        capture_output=True, text=True)


def main():
    check("helper exists", HELPER.is_file())
    if not HELPER.is_file():
        return 1
    with tempfile.TemporaryDirectory() as td:
        t = Path(td).resolve()
        root = t / "root"
        root.mkdir()
        victim = root / "victim"
        (victim / "sub").mkdir(parents=True)
        (victim / "sub" / "f.txt").write_text("x")
        outside = t / "outside"
        outside.mkdir()
        (outside / "keep.txt").write_text("x")

        # Refusals: exit 2, delete nothing.
        for what, r, paths in [
            ("empty ROOT", "", [victim]),
            ("ROOT is /", "/", [victim]),
            ("ROOT is HOME", Path.home(), [Path.home() / "no-such-271"]),
            ("empty PATH", root, [""]),
            ("glob PATH", root, [str(root / "vic*")]),
            ("glob ? PATH", root, [str(root / "victi?")]),
            ("glob [ PATH", root, [str(root / "[v]ictim")]),
            (".. escape", root, [root / ".." / "outside"]),
            ("PATH outside ROOT", root, [outside]),
            ("PATH equal to ROOT", root, [root]),
        ]:
            res = run(r, *paths)
            check(f"refuses {what}", res.returncode == 2 and victim.exists()
                  and (outside / "keep.txt").exists())

        # The repo root (a folder holding .git) is refused as ROOT.
        repo = t / "repo"
        (repo / ".git").mkdir(parents=True)
        (repo / "build").mkdir()
        res = run(repo, repo / "build")
        check("refuses repo root as ROOT", res.returncode == 2 and (repo / "build").exists())

        # A symlinked parent that points outside ROOT is refused.
        (root / "escape").symlink_to(outside, target_is_directory=True)
        res = run(root, root / "escape" / "keep.txt")
        check("refuses symlink parent outside ROOT",
              res.returncode == 2 and (outside / "keep.txt").exists())

        # Every PATH is checked before any is deleted.
        good = root / "good"
        good.mkdir()
        res = run(root, good, outside)
        check("one bad PATH deletes nothing", res.returncode == 2 and good.exists())

        # A missing PATH is fine.
        res = run(root, root / "missing")
        check("missing PATH succeeds", res.returncode == 0)

        # A symlink PATH is unlinked; its target is kept.
        link = root / "link"
        link.symlink_to(outside, target_is_directory=True)
        res = run(root, link)
        check("symlink PATH removed, target kept",
              res.returncode == 0 and not link.exists() and not link.is_symlink()
              and (outside / "keep.txt").exists())

        # A normal delete works and says what it removes.
        res = run(root, victim)
        check("normal delete", res.returncode == 0 and not victim.exists())
        check("prints what it removes", "removing" in res.stderr and "victim" in res.stderr)

        # Several PATHs in one call.
        a, b = root / "a", root / "b"
        a.mkdir(); b.mkdir()
        res = run(root, a, b)
        check("several PATHs", res.returncode == 0 and not a.exists() and not b.exists())

    print("FAILURES" if fails else "all ok")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
