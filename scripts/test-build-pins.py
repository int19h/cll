#!/usr/bin/env python3
"""Reject changing base images, package archives, and ConTeXt installers."""
from pathlib import Path
import re
import unittest
import subprocess
import tempfile
import hashlib
import os
import tarfile

ROOT = Path(__file__).resolve().parents[1]


class BuildPinsTest(unittest.TestCase):
    def test_base_images_and_packages(self):
        for name in ['Dockerfile', 'Dockerfile.weasyprint', 'Dockerfile.context']:
            with self.subTest(file=name):
                text = (ROOT / name).read_text()
                for source in re.findall(r'^FROM (\S+)', text, re.M):
                    if source != 'build-base':
                        self.assertRegex(source, r'@sha256:[0-9a-f]{64}$')
                self.assertIn('https://snapshot.ubuntu.com/ubuntu/20261027T000000Z/', text)
                self.assertIn('APT::Update::Error-Mode=any', text)
                self.assertNotIn('trusted=yes', text)
                self.assertNotIn('Verify-Peer=false', text)

    def test_context_rejects_wrong_archive_before_extraction(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            archives = directory / 'archives'
            archives.mkdir()
            (archives / 'context-source.tar.gz').write_bytes(b'wrong archive')
            result = subprocess.run(
                ['bash', str(ROOT / 'scripts/install-context.sh'),
                 str(directory / 'install'), str(archives)],
                capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('FAILED', result.stdout)
            self.assertFalse((directory / 'install/tex/texmf-context/tex').exists())

    def test_context_standalone_configuration(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            archives = directory / 'archives'
            archives.mkdir()
            source = directory / 'source'
            files = {
                'web2c/contextcnf.lua': 'return {}\n',
                'tex/context/base/mkiv/context.mkiv':
                    '\\edef\\contextversion{2026.10.25 20:06}\n',
                'source/luametatex/CMakeLists.txt': '',
            }
            for name in ['context.lua', 'context.lmt', 'mtxrun.lua', 'mtxrun.lmt']:
                files['scripts/context/lua/' + name] = ''
            for name, content in files.items():
                path = source / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(content)
            fonts = directory / 'fonts'
            fonts.mkdir()
            (fonts / 'font.txt').write_text('fixture font')
            for name, tree in [('context-source', source), ('context-fonts', fonts)]:
                with tarfile.open(archives / (name + '.tar.gz'), 'w:gz') as archive:
                    archive.add(tree, arcname=name)
            script = (ROOT / 'scripts/install-context.sh').read_text()
            for key, name in [('context', 'context-source'), ('fonts', 'context-fonts')]:
                digest = hashlib.sha256((archives / (name + '.tar.gz')).read_bytes()).hexdigest()
                script = re.sub(key + r'_sha256=[0-9a-f]{64}', key + '_sha256=' + digest, script)
            # Replace only fixture input hashes and the privileged metadata destination.
            script = script.replace('/usr/local/share/cll', str(directory / 'metadata'))
            installer = directory / 'install.sh'
            installer.write_text(script)
            tools = directory / 'tools'
            tools.mkdir()
            engine = directory / 'engine'
            engine.write_text('#!/bin/sh\n'
                              'root=$(cd "$(dirname "$0")/../../.." && pwd)\n'
                              'test -f "$root/tex/texmf-context/web2c/texmfcnf.lua" || exit 1\n'
                              'echo "current version: 2026.10.25 20:06"\n')
            cmake = tools / 'cmake'
            cmake.write_text('#!/usr/bin/env python3\n'
                             'import os, pathlib, shutil, sys\n'
                             'if "-B" in sys.argv:\n'
                             '    output = pathlib.Path(sys.argv[sys.argv.index("-B") + 1])\n'
                             '    shutil.copyfile(os.environ["FIXTURE_ENGINE"], output / "luametatex")\n')
            cmake.chmod(0o755)
            environment = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ['PATH'],
                               FIXTURE_ENGINE=str(engine))
            result = subprocess.run(['bash', str(installer), str(directory / 'install'), str(archives)],
                                    env=environment, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertTrue((directory / 'install/platform-bin/context').is_file())
            self.assertIn('2026.10.25 20:06',
                          (directory / 'metadata/context-sources.txt').read_text())

    def test_context_sources(self):
        text = (ROOT / 'Dockerfile.context').read_text()
        self.assertNotIn('CONTEXT_INSTALLER_BASE', text)
        self.assertNotIn('sh install.sh', text)
        script = (ROOT / 'scripts/install-context.sh').read_text()
        self.assertIn('sha256sum -c -', script)
        self.assertIn('contextgarden/context/', script)
        self.assertIn('contextgarden/context-distribution-fonts/', script)
        self.assertIn('2026.10.25 20:06', script)


if __name__ == '__main__':
    unittest.main()
