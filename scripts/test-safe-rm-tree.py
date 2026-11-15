#!/usr/bin/env python3
"""The recursive-delete helper refuses every bad input (issue #271)."""
from pathlib import Path
import os
import subprocess
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parent.parent
HELPER = SOURCE / 'scripts/safe-rm-tree.sh'


class SafeRmTreeTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='cll-safe-rm-')
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name).resolve()
        self.root = self.base / 'root'
        self.root.mkdir()
        self.outside = self.base / 'outside'
        self.outside.mkdir()
        (self.outside / 'victim.txt').write_text('keep')

    def run_helper(self, *args, env=None):
        return subprocess.run(
            ['bash', str(HELPER), *map(str, args)],
            text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            env=env)

    def tree(self, name='tree'):
        path = self.root / name
        (path / 'sub').mkdir(parents=True)
        (path / 'sub/file.txt').write_text('data')
        return path

    def assert_refused(self, *args, env=None):
        result = self.run_helper(*args, env=env)
        self.assertEqual(result.returncode, 2, result.stdout)

    def test_normal_delete(self):
        tree = self.tree()
        result = self.run_helper('--root', self.root, tree)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn(f'removing {tree}', result.stdout)
        self.assertFalse(tree.exists())

    def test_missing_path_is_fine(self):
        result = self.run_helper('--root', self.root, self.root / 'nope')
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_refusals(self):
        tree = self.tree()
        home = self.base / 'home'
        home.mkdir()
        env = dict(os.environ, HOME=str(home))
        repo = self.base / 'repo'
        repo.mkdir()
        (repo / '.git').write_text('gitdir: elsewhere')
        cases = [
            ('empty ROOT', ('--root', '', tree), None),
            ('slash ROOT', ('--root', '/', 'tmp'), None),
            ('HOME ROOT', ('--root', home, home / 'x'), env),
            ('repo ROOT', ('--root', repo, repo / 'x'), None),
            ('missing ROOT', ('--root', self.base / 'gone', 'x'), None),
            ('empty PATH', ('--root', self.root, ''), None),
            ('glob PATH', ('--root', self.root, f'{self.root}/*'), None),
            ('outside PATH', ('--root', self.root, self.outside / 'victim.txt'), None),
            ('dotdot escape', ('--root', self.root,
                               f'{self.root}/../outside/victim.txt'), None),
            ('PATH equals ROOT', ('--root', self.root, self.root), None),
            ('PATH equals ROOT slash', ('--root', self.root, f'{self.root}/'), None),
        ]
        for name, args, case_env in cases:
            with self.subTest(name=name):
                self.assert_refused(*args, env=case_env)
        self.assertTrue(tree.exists())
        self.assertEqual((self.outside / 'victim.txt').read_text(), 'keep')

    def test_one_bad_path_deletes_nothing(self):
        tree = self.tree()
        self.assert_refused('--root', self.root, tree, self.outside)
        self.assertTrue(tree.exists())

    def test_symlinked_parent_pointing_outside_is_refused(self):
        (self.root / 'link').symlink_to(self.outside, target_is_directory=True)
        self.assert_refused('--root', self.root, self.root / 'link/victim.txt')
        self.assertEqual((self.outside / 'victim.txt').read_text(), 'keep')

    def test_control_characters_are_refused(self):
        # A trailing newline must not retarget the delete at the sibling
        # without the newline (round 2, Astra L1).
        plain = self.tree('plain')
        newline_root = self.base / 'root\n'
        (newline_root / 'plain').mkdir(parents=True)
        (newline_root / 'plain/file.txt').write_text('data')
        self.assert_refused('--root', newline_root, newline_root / 'plain')
        self.assertTrue((newline_root / 'plain/file.txt').exists())
        self.assertTrue((plain / 'sub/file.txt').exists())
        leaf = self.root / 'leaf\n'
        leaf.mkdir()
        sibling = self.tree('leaf')
        self.assert_refused('--root', self.root, leaf)
        self.assert_refused('--root', self.root, f'{self.root}/tab\tname')
        self.assertTrue(leaf.exists())
        self.assertTrue((sibling / 'sub/file.txt').exists())

    def test_symlink_path_is_unlinked_and_target_kept(self):
        link = self.root / 'link'
        link.symlink_to(self.outside / 'victim.txt')
        result = self.run_helper('--root', self.root, link)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertFalse(link.is_symlink())
        self.assertEqual((self.outside / 'victim.txt').read_text(), 'keep')


if __name__ == '__main__':
    unittest.main()
