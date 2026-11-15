#!/usr/bin/env python3
"""Refusals and normal deletes of scripts/safe_rmtree.py (issue #271).

Run: python3 scripts/test-safe-rmtree.py
"""
import contextlib
import io
import os
import tempfile
import unittest
from pathlib import Path

from safe_rmtree import safe_rmtree


class SafeRmtreeTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='cll-safe-rmtree-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.outside_temporary = tempfile.TemporaryDirectory(prefix='cll-safe-outside-')
        self.addCleanup(self.outside_temporary.cleanup)
        self.outside = Path(self.outside_temporary.name).resolve()

    def make_tree(self, base):
        tree = base / 'tree'
        (tree / 'nested').mkdir(parents=True)
        (tree / 'nested' / 'file.txt').write_text('keep-or-remove')
        return tree

    def remove(self, path, root):
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            safe_rmtree(path, root)
        return stderr.getvalue()

    def test_normal_delete_inside_root(self):
        tree = self.make_tree(self.root)
        output = self.remove(tree, self.root)
        self.assertFalse(tree.exists())
        self.assertTrue(self.root.exists())
        self.assertIn(f'removing {tree}', output)

    def test_nested_delete_and_string_paths(self):
        tree = self.make_tree(self.root / 'a' / 'b')
        self.remove(str(tree), str(self.root))
        self.assertFalse(tree.exists())
        self.assertTrue((self.root / 'a' / 'b').exists())

    def test_missing_path_is_fine(self):
        self.remove(self.root / 'missing', self.root)
        self.assertTrue(self.root.exists())

    def test_file_inside_root_is_removed(self):
        victim = self.root / 'file.txt'
        victim.write_text('x')
        self.remove(victim, self.root)
        self.assertFalse(victim.exists())

    def test_symlink_path_is_unlinked_and_target_kept(self):
        target = self.make_tree(self.outside)
        link = self.root / 'link'
        link.symlink_to(target, target_is_directory=True)
        self.remove(link, self.root)
        self.assertFalse(link.is_symlink())
        self.assertEqual((target / 'nested' / 'file.txt').read_text(), 'keep-or-remove')

    def test_refusals_delete_nothing(self):
        tree = self.make_tree(self.root)
        outside_tree = self.make_tree(self.outside)
        repo_root = self.root / 'repo'
        (repo_root / '.git').mkdir(parents=True)
        (repo_root / 'tree').mkdir()
        link = self.root / 'escape'
        link.symlink_to(self.outside, target_is_directory=True)
        cases = [
            ('empty root', tree, ''),
            ('root is Path empty', tree, Path('')),
            ('root is a dot', tree, '.'),
            ('root has a newline', tree, f'{self.root}\n'),
            ('root has a control character', tree, f'{self.root}\x07'),
            ('root is /', tree, '/'),
            ('root is home', tree, Path.home()),
            ('root is a repository root', repo_root / 'tree', repo_root),
            ('root does not exist', tree, self.root / 'missing-root'),
            ('root is a file', tree, tree / 'nested' / 'file.txt'),
            ('empty path', '', self.root),
            ('path is Path empty', Path(''), self.root),
            ('path ends in a dot', f'{tree}/.', self.root),
            ('path ends in dot-dot', f'{tree}/..', self.root),
            ('path has a newline', f'{tree}\n', self.root),
            ('path has a control character', f'{self.root}/tr\x07ee', self.root),
            ('path is root', self.root, self.root),
            ('path outside root', outside_tree, self.root),
            ('dot-dot escape', self.root / '..' / self.outside.name / 'tree',
             self.root),
            ('parent symlink points outside', link / 'tree', self.root),
        ]
        for label, path, root in cases:
            with self.subTest(label=label):
                with self.assertRaises(ValueError):
                    self.remove(path, root)
        self.assertTrue((tree / 'nested' / 'file.txt').exists())
        self.assertTrue((outside_tree / 'nested' / 'file.txt').exists())
        self.assertTrue((repo_root / 'tree').exists())

    def test_empty_path_root_does_not_become_the_working_folder(self):
        tree = self.make_tree(self.root)
        previous = os.getcwd()
        os.chdir(self.root)
        self.addCleanup(os.chdir, previous)
        with self.assertRaises(ValueError):
            self.remove(tree, Path(''))
        self.assertTrue((tree / 'nested' / 'file.txt').exists())

    def test_glob_paths_are_refused(self):
        tree = self.make_tree(self.root)
        for pattern in ('*', 'tr?e', 'tr[ee]'):
            with self.subTest(pattern=pattern):
                with self.assertRaises(ValueError):
                    self.remove(self.root / pattern, self.root)
        self.assertTrue(tree.exists())


if __name__ == '__main__':
    unittest.main()
