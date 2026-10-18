"""Tests for shared/prepare_library_skills.{py,sh} (remote Library skill copies)."""
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
PROGRAM = (ROOT / 'shared/prepare_library_skills.py').read_text()
WRAPPER = (ROOT / 'shared/prepare_library_skills.sh').read_text()
PROJECT_PROGRAM = (ROOT / 'shared/prepare_project_skills.py').read_text()
PROJECT_WRAPPER = (ROOT / 'shared/prepare_project_skills.sh').read_text()


def make_archive(path, files, extra=None):
    with tarfile.open(path, 'w:gz') as archive:
        for name, content in sorted(files.items()):
            data = content.encode()
            info = tarfile.TarInfo(name)
            info.size = len(data)
            archive.addfile(info, io.BytesIO(data))
        for info in extra or ():
            archive.addfile(info)
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def skill_files(*names):
    files = {}
    for name in names:
        files[f'skills/{name}/SKILL.md'] = f'---\nname: {name}\ndescription: Library {name}\n---\nbody\n'
        files[f'skills/{name}/references/a.md'] = 'ref'
    return files


class LibrarySkillsTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name).resolve()
        self.cwd = self.base / 'work'
        self.cwd.mkdir()
        self.env = {**os.environ, 'XDG_CACHE_HOME': str(self.base / 'cache'), 'HOME': str(self.base)}

    def run_script(self, mode, harness='claudecode', archive='', sha='', path=None):
        return subprocess.run(
            ['sh', '-c', WRAPPER, 'sandboxed-library-skills', mode, harness, str(archive), sha, PROGRAM],
            cwd=self.cwd, env={**self.env, **({'PATH': path} if path is not None else {})},
            capture_output=True, text=True,
        )

    def archive(self, *names, extra=None):
        path = self.base / f'lib-{"-".join(names) or "empty"}-{len(extra or ())}.tar.gz'
        return path, make_archive(path, skill_files(*names), extra)

    def manifest(self):
        return json.loads((self.cwd / '.sandboxed-library-skills.json').read_text())

    def test_install_is_idempotent_and_tracked(self):
        path, sha = self.archive('alpha', 'beta')
        for _ in range(2):
            result = self.run_script('install', 'claudecode', path, sha)
            self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.cwd / '.claude/skills/alpha/references/a.md').read_text(), 'ref')
        self.assertEqual(sorted(self.manifest()['entries']), ['.claude/skills/alpha', '.claude/skills/beta'])
        self.assertTrue((self.base / 'cache/sandboxed-sh/library-skills' / sha / 'skills/alpha/SKILL.md').is_file())
        # The cache serves later installs even when the upload is gone.
        path.unlink()
        self.assertEqual(self.run_script('install', 'codex', path, sha).returncode, 0)
        self.assertTrue((self.cwd / '.agents/skills/alpha/SKILL.md').is_file())
        self.assertFalse((self.cwd / '.claude/skills/alpha').exists())

    def test_cleanup_removes_dropped_skills_and_never_user_dirs(self):
        path, sha = self.archive('alpha', 'beta')
        self.run_script('install', 'claudecode', path, sha)
        user = self.cwd / '.claude/skills/mine'
        user.mkdir()
        (user / 'SKILL.md').write_text('user')
        # A user edit makes an owned copy user-owned: kept, forgotten.
        (self.cwd / '.claude/skills/beta/SKILL.md').write_text('edited')
        path2, sha2 = self.archive('gamma')
        result = self.run_script('install', 'claudecode', path2, sha2)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.cwd / '.claude/skills/alpha').exists())
        self.assertEqual((self.cwd / '.claude/skills/beta/SKILL.md').read_text(), 'edited')
        self.assertTrue((user / 'SKILL.md').exists())
        self.assertTrue((self.cwd / '.claude/skills/gamma/SKILL.md').exists())
        self.assertEqual(list(self.manifest()['entries']), ['.claude/skills/gamma'])
        self.assertEqual(self.run_script('cleanup').returncode, 0)
        self.assertFalse((self.cwd / '.claude/skills/gamma').exists())
        self.assertTrue((user / 'SKILL.md').exists())
        self.assertEqual(self.manifest()['entries'], {})

    def test_existing_name_wins_with_notice(self):
        project = self.cwd / '.claude/skills/alpha'
        project.mkdir(parents=True)
        (project / 'SKILL.md').write_text('project copy')
        path, sha = self.archive('alpha', 'beta')
        result = self.run_script('install', 'claudecode', path, sha)
        self.assertEqual(result.returncode, 0)
        self.assertIn('already exists', result.stderr)
        self.assertEqual((project / 'SKILL.md').read_text(), 'project copy')
        self.assertEqual(list(self.manifest()['entries']), ['.claude/skills/beta'])

    def test_project_skill_wins_in_prefix_order(self):
        source = self.base / 'project'
        folder = source / 'skills/alpha'
        folder.mkdir(parents=True)
        (folder / 'SKILL.md').write_text('# Project alpha\nproject\n')
        path, sha = self.archive('alpha', 'beta')
        # Turn 1 installs Library alpha before the project defined one.
        self.run_script('install', 'claudecode', path, sha)
        for _ in range(2):
            self.assertEqual(self.run_script('cleanup').returncode, 0)
            project = subprocess.run(
                ['sh', '-c', PROJECT_WRAPPER, 'orb-project-skills', str(source), 'claudecode', PROJECT_PROGRAM],
                cwd=self.cwd, env=self.env, capture_output=True, text=True,
            )
            if 'PyYAML' in project.stderr:
                self.skipTest('PyYAML is not installed')
            self.assertEqual(project.returncode, 0, project.stderr)
            result = self.run_script('install', 'claudecode', path, sha)
            self.assertIn('already exists', result.stderr)
        self.assertIn('Project alpha', (self.cwd / '.claude/skills/alpha/SKILL.md').read_text())
        self.assertTrue((self.cwd / '.claude/skills/beta/SKILL.md').is_file())

    def unsafe(self, info):
        path, sha = self.archive('alpha', extra=[info])
        result = self.run_script('install', 'claudecode', path, sha)
        self.assertEqual(result.returncode, 0)
        self.assertIn('skipped', result.stderr)
        self.assertFalse((self.cwd / '.claude/skills/alpha').exists())
        self.assertFalse((self.base / 'cache/sandboxed-sh/library-skills' / sha).exists())
        self.assertFalse((self.base / 'escape').exists())

    def test_rejects_parent_traversal(self):
        info = tarfile.TarInfo('skills/alpha/../../../../escape')
        self.unsafe(info)

    def test_rejects_absolute_members(self):
        info = tarfile.TarInfo(str(self.base / 'escape'))
        self.unsafe(info)

    def test_rejects_links(self):
        link = tarfile.TarInfo('skills/alpha/link')
        link.type = tarfile.SYMTYPE
        link.linkname = '/etc/passwd'
        self.unsafe(link)
        hard = tarfile.TarInfo('skills/alpha/hard')
        hard.type = tarfile.LNKTYPE
        hard.linkname = 'skills/alpha/SKILL.md'
        self.unsafe(hard)

    def test_hash_mismatch_installs_nothing(self):
        path, _ = self.archive('alpha')
        result = self.run_script('install', 'claudecode', path, '0' * 64)
        self.assertEqual(result.returncode, 0)
        self.assertIn('hash mismatch', result.stderr)
        self.assertFalse((self.cwd / '.claude/skills/alpha').exists())

    def test_missing_python_is_a_notice_not_a_failure(self):
        bin_dir = self.base / 'bin'
        bin_dir.mkdir()
        for tool in ('sh', 'echo', '['):
            real = subprocess.run(['sh', '-c', f'command -v {tool}'], capture_output=True, text=True).stdout.strip()
            if real.startswith('/'):
                os.symlink(real, bin_dir / tool)
        result = subprocess.run(
            ['/bin/sh', '-c', WRAPPER, 'sandboxed-library-skills', 'install', 'codex', '/x.tar.gz', 'a' * 64, PROGRAM],
            cwd=self.cwd, env={'PATH': str(bin_dir)}, capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 0)
        self.assertIn('python3 is not installed', result.stderr)


if __name__ == '__main__':
    unittest.main()
