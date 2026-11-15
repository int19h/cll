#!/usr/bin/env python3
"""build.sh refuses a build link into the checkout before it cleans
(issue #271, review round 3, Astra R2).

Each case runs the real build.sh in a scratch checkout with the
container launcher, chcon and restorecon stubbed. The launcher records
its call and exits 1, so nothing is built or copied.

Run: python3 scripts/test-build-sh.py
"""
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent

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
    (root / "bin").mkdir()
    shutil.copy(REPO / "build.sh", root / "build.sh")
    shutil.copy(HERE / "safe-rm-tree.sh", root / "scripts" / "safe-rm-tree.sh")
    (root / "scripts" / "safe-rm-tree.sh").chmod(0o755)
    sentinel = root / "chapters" / "source.xml"
    sentinel.write_text("source")
    for stub in ("chcon", "restorecon"):
        p = root / "bin" / stub
        p.write_text("#!/bin/bash\nexit 0\n")
        p.chmod(0o755)
    launcher = root / "run_container.sh"
    launcher.write_text(
        "#!/bin/bash\necho called >> \"$CONTAINER_LOG\"\nexit 1\n")
    launcher.chmod(0o755)
    if build_link is None:
        (root / "build").mkdir()
    else:
        (root / "build").symlink_to(build_link, target_is_directory=True)
    return root, sentinel


def run_build_sh(root):
    env = dict(os.environ, PWD=str(root),
               PATH=f"{root}/bin:{os.environ['PATH']}",
               CONTAINER_LOG=str(root / "container.log"), HOME=str(root))
    return subprocess.run(["bash", "build.sh"], cwd=root, env=env,
                          capture_output=True, text=True)


def main():
    with tempfile.TemporaryDirectory() as td:
        t = Path(td).resolve()

        # Astra's case: build -> chapters must delete nothing and must
        # not reach the container launcher.
        root, s = scratch(t, "linkchapters", build_link="chapters")
        res = run_build_sh(root)
        check("build -> chapters: source survives", s.exists())
        check("build -> chapters: container not called",
              not (root / "container.log").exists())
        check("build -> chapters: build.sh exits nonzero",
              res.returncode != 0)

        # build -> . (the checkout itself) likewise.
        root, s = scratch(t, "linkdot", build_link=".")
        res = run_build_sh(root)
        check("build -> .: source survives and container not called",
              s.exists() and not (root / "container.log").exists()
              and res.returncode != 0)

        # A parent of the checkout likewise.
        root, s = scratch(t, "linkparent", build_link="..")
        res = run_build_sh(root)
        check("build -> ..: source survives and container not called",
              s.exists() and not (root / "container.log").exists()
              and res.returncode != 0)

        # Normal case: a real build folder is emptied, then the
        # container launcher runs.
        root, s = scratch(t, "normal")
        (root / "build" / "junk").write_text("junk")
        res = run_build_sh(root)
        check("normal build folder is emptied and container called",
              s.exists() and not (root / "build" / "junk").exists()
              and (root / "container.log").exists())

        # Supported case: build -> a separate folder outside the
        # checkout is emptied, then the container launcher runs.
        sep = t / "separate-build"
        sep.mkdir()
        (sep / "junk").write_text("junk")
        root, s = scratch(t, "linksep", build_link=str(sep))
        res = run_build_sh(root)
        check("build -> separate folder is emptied and container called",
              s.exists() and not (sep / "junk").exists()
              and (root / "container.log").exists())

    print("FAILURES" if fails else "all ok")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
