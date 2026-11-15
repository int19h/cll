"""Guarded recursive delete for Python build code (issue #271).

safe_rmtree(path, root) follows the same rules as scripts/safe-rm-tree.sh.
Prefer tempfile.TemporaryDirectory where code only cleans up its own
temporary folder; that needs no helper.
"""
import os
import shutil
import sys
from pathlib import Path

_GLOB_CHARS = ('*', '?', '[')


def _refuse(message):
    raise ValueError(f'safe_rmtree: refusing to remove: {message}')


def safe_rmtree(path, root):
    """Remove path recursively, only when it lies strictly inside root.

    Root must be non-empty, an existing directory after resolution, and
    not '/', the home folder, or a repository root (a folder holding
    '.git'). Path must be non-empty, contain no glob characters, and lie
    strictly inside the resolved root. Path's parent is resolved and its
    last component kept as written, so a symbolic-link path is judged by
    its own location: the link is unlinked and its target is kept. A
    missing path is fine. Every refusal raises ValueError and deletes
    nothing. Each removal prints 'removing PATH' on stderr.
    """
    if root is None or str(root) == '':
        _refuse('root is empty')
    if path is None or str(path) == '':
        _refuse('path is empty')
    if any(char in str(path) for char in _GLOB_CHARS):
        _refuse(f'path contains a glob character: {path}')

    resolved_root = Path(root).resolve()
    if not resolved_root.is_dir():
        _refuse(f'root is not an existing directory: {root}')
    if resolved_root == Path(resolved_root.anchor):
        _refuse('root is /')
    if resolved_root == Path.home().resolve():
        _refuse('root is the home folder')
    if (resolved_root / '.git').exists():
        _refuse(f'root is a repository root: {root}')

    raw_path = Path(path)
    name = raw_path.name
    if name in ('', '.', '..'):
        _refuse(f'path has no final component to remove: {path}')
    candidate = raw_path.parent.resolve() / name
    if candidate == resolved_root or resolved_root not in candidate.parents:
        _refuse(f'path is not strictly inside root: {path}')

    if not os.path.lexists(candidate):
        return
    print(f'removing {path}', file=sys.stderr)
    if candidate.is_symlink() or not candidate.is_dir():
        candidate.unlink()
    else:
        shutil.rmtree(candidate)
