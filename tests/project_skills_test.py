"""Filesystem/ownership tests, deliberately separate from native discovery evidence."""
import importlib.util
import json
import multiprocessing
from pathlib import Path
import shutil
import subprocess
from types import SimpleNamespace
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('project_skills', Path(__file__).parents[1] / 'shared/prepare_project_skills.py')
skills = importlib.util.module_from_spec(spec)
spec.loader.exec_module(skills)


def concurrent_prepare(source, cwd, harness):
    skills.prepare(source, cwd, harness, verify=False)


class ProjectSkillsTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.source = self.base / 'project'
        self.source.mkdir()
        self.cwd = self.base / 'work'
        self.cwd.mkdir()

    def skill(self, name='orb-marker', body=None):
        folder = self.source / 'skills' / name
        (folder / 'references').mkdir(parents=True)
        (folder / 'SKILL.md').write_text(body if body is not None else f'---\nname: {name}\ndescription: Report the disposable Orb marker\n---\nRead references/marker.md and report its marker.\n')
        (folder / 'references/marker.md').write_text('ORB-PROJECT-SKILLS-7E981')
        return folder

    def prepare(self, harness='codex'):
        return skills.prepare(str(self.source), str(self.cwd), harness, verify=False)

    def test_links_references_and_edits_use_originals_for_each_native_path(self):
        original = self.skill()
        for harness, native in skills.NATIVE.items():
            self.prepare(harness)
            exposed = self.cwd / native / original.name
            self.assertTrue(exposed.is_symlink())
            self.assertEqual(exposed.resolve(), original)
            reference = exposed / 'references/marker.md'
            reference.write_text('edited through link')
            self.assertEqual((original / 'references/marker.md').read_text(), 'edited through link')

    def test_add_rename_delete_cleans_all_previously_used_harness_paths(self):
        old = self.skill()
        for harness in skills.NATIVE:
            self.prepare(harness)
        old.rename(old.with_name('renamed'))
        (old.with_name('renamed') / 'SKILL.md').write_text('A renamed plain Markdown skill.')
        self.prepare()
        for native in skills.NATIVE.values():
            self.assertFalse((self.cwd / native / 'orb-marker').is_symlink())
        shutil.rmtree(self.source / 'skills')
        self.prepare('chatgpt_ui')
        self.assertEqual(json.loads((self.cwd / skills.MANIFEST).read_text())['entries'], {})

    def test_cleanup_phase_removes_stale_entries_before_library_takes_old_name(self):
        old = self.skill('old')
        self.prepare('claudecode')
        shutil.rmtree(old)
        self.skill('new')
        skills.prepare(str(self.source), str(self.cwd), 'claudecode', verify=False, cleanup_only=True)
        self.assertFalse((self.cwd / '.claude/skills/old').is_symlink())
        self.assertFalse((self.cwd / '.claude/skills/new').exists())
        library = self.cwd / '.claude/skills/old'
        library.mkdir()
        (library / 'SKILL.md').write_text('Library owns the old name')
        self.prepare('claudecode')
        self.assertEqual((library / 'SKILL.md').read_text(), 'Library owns the old name')

    def test_per_mission_skill_roots_are_checked_for_custom_cwd(self):
        self.skill()
        mission = self.base / 'mission'
        for harness, alias in [('codex', '.codex/skills'), ('claudecode', '.claude/skills')]:
            entry = mission / alias / 'orb-marker'
            entry.mkdir(parents=True)
            (entry / 'SKILL.md').write_text('Library skill')
            with self.assertRaisesRegex(ValueError, 'per-mission native skill'):
                skills.prepare(str(self.source), str(self.cwd), harness, verify=False, discovery_roots=[mission])
            self.assertFalse((self.cwd / skills.NATIVE[harness] / 'orb-marker').exists())
            self.assertEqual((entry / 'SKILL.md').read_text(), 'Library skill')

    def test_preserves_user_configuration_and_skills(self):
        self.skill()
        for native in skills.NATIVE.values():
            parent = self.cwd / native
            (parent / 'personal').mkdir(parents=True)
            (parent / 'personal/SKILL.md').write_text('personal')
            (parent.parent / 'config').write_text('user configuration')
        self.prepare()
        shutil.rmtree(self.source / 'skills')
        self.prepare()
        for native in skills.NATIVE.values():
            self.assertEqual((self.cwd / native / 'personal/SKILL.md').read_text(), 'personal')
            self.assertEqual((self.cwd / native).parent.joinpath('config').read_text(), 'user configuration')

    def test_collision_fails_before_cleanup_or_writes(self):
        old = self.skill('old')
        self.prepare()
        shutil.rmtree(old)
        self.skill('collision')
        collision = self.cwd / '.agents/skills/collision'
        collision.mkdir()
        (collision / 'SKILL.md').write_text('user skill')
        with self.assertRaisesRegex(ValueError, 'collision'):
            self.prepare()
        self.assertTrue((self.cwd / '.agents/skills/old').is_symlink())
        self.assertEqual((collision / 'SKILL.md').read_text(), 'user skill')

    def test_native_discovery_never_pollutes_the_synchronized_source_tree(self):
        self.skill()
        with self.assertRaisesRegex(ValueError, 'outside the synchronized project files'):
            skills.prepare(str(self.source), str(self.source), 'codex')
        self.assertFalse((self.source / '.orb-project-skills.lock').exists())
        self.assertFalse((self.source / '.agents').exists())

    def test_invalid_native_frontmatter_fails_before_exposing_skills(self):
        original = self.skill()
        for description in ['""', "''", 'null', '[]', '"unclosed', '|']:
            (original / 'SKILL.md').write_text(f'---\nname: orb-marker\ndescription: {description}\n---\nInstructions')
            with self.assertRaisesRegex(ValueError, 'nonempty string description'):
                self.prepare()
            self.assertFalse((self.cwd / '.agents/skills/orb-marker').exists())
        (original / 'SKILL.md').write_text('---\nname: orb-marker\ndescription: |\n  A multiline description.\n---\nInstructions')
        self.assertEqual(self.prepare()['skills'], 1)

    def test_compatible_native_name_collisions_are_explicit(self):
        self.skill()
        collision = self.cwd / '.opencode/skill/orb-marker'
        collision.mkdir(parents=True)
        (collision / 'SKILL.md').write_text('Library or user-managed skill')
        with self.assertRaisesRegex(ValueError, 'collision'):
            self.prepare('opencode')
        self.assertEqual((collision / 'SKILL.md').read_text(), 'Library or user-managed skill')

    def test_modified_managed_entry_is_preserved(self):
        self.skill()
        self.prepare()
        entry = self.cwd / '.agents/skills/orb-marker'
        entry.unlink()
        entry.mkdir()
        (entry / 'SKILL.md').write_text('replacement user skill')
        shutil.rmtree(self.source / 'skills')
        with self.assertRaisesRegex(ValueError, 'collision'):
            self.prepare()
        self.assertEqual((entry / 'SKILL.md').read_text(), 'replacement user skill')

    def test_projects_sharing_cwd_and_nested_cwd_fail_without_leaking(self):
        self.skill()
        self.prepare()
        other = self.base / 'other'
        other.mkdir()
        nested = self.cwd / 'nested'
        nested.mkdir()
        for directory in (self.cwd, nested):
            with self.assertRaisesRegex(ValueError, 'another project'):
                skills.prepare(str(other), str(directory), 'codex')
            with self.assertRaisesRegex(ValueError, 'another project'):
                skills.prepare(None, str(directory), 'codex')
        separate = self.base / 'separate'
        separate.mkdir()
        self.assertEqual(skills.prepare(str(other), str(separate), 'codex')['skills'], 0)

    def test_plain_markdown_adaptation_preserves_content_supporting_files_and_source(self):
        original = self.skill(body='# Orb marker\nRead references/marker.md.\n')
        self.prepare()
        copy = self.cwd / '.agents/skills/orb-marker'
        self.assertFalse(copy.is_symlink())
        body = (copy / 'SKILL.md').read_text()
        self.assertIn(str(original / 'SKILL.md'), body)
        self.assertTrue(body.endswith((original / 'SKILL.md').read_text()))
        self.assertEqual((copy / 'references/marker.md').read_bytes(), (original / 'references/marker.md').read_bytes())
        (original / 'references/marker.md').write_text('new marker')
        self.prepare()
        self.assertEqual((copy / 'references/marker.md').read_text(), 'new marker')
        (copy / 'SKILL.md').write_text('user modified copy')
        with self.assertRaisesRegex(ValueError, 'collision'):
            self.prepare()

    def test_unsupported_links_fall_back_to_source_labelled_refreshed_copies(self):
        original = self.skill()
        with patch.object(Path, 'symlink_to', side_effect=OSError('unsupported')):
            self.prepare()
        copy = self.cwd / '.agents/skills/orb-marker'
        self.assertFalse(copy.is_symlink())
        self.assertIn(str(original), (copy / 'SKILL.md').read_text())
        (original / 'SKILL.md').write_text((original / 'SKILL.md').read_text() + '\nEdited original.\n')
        self.prepare()
        self.assertIn('Edited original.', (copy / 'SKILL.md').read_text())

    def test_unsupported_harness_fails_only_when_skills_exist(self):
        self.assertEqual(self.prepare('chatgpt_ui')['skills'], 0)
        self.skill()
        for harness in ('unknown', 'chatgpt_ui'):
            with self.assertRaisesRegex(ValueError, 'no supported'):
                self.prepare(harness)

    def test_grok_fails_clearly_when_trust_or_configuration_hides_skills(self):
        self.skill()
        with patch.object(skills.subprocess, 'run', return_value=SimpleNamespace(returncode=0, stdout='{"skills": []}')):
            with self.assertRaisesRegex(ValueError, 'Trust this working directory'):
                skills.prepare(str(self.source), str(self.cwd), 'grok')
        with patch.object(skills.subprocess, 'run', return_value=SimpleNamespace(returncode=0, stdout='{"skills": [{"name": "orb-marker"}]}')):
            self.assertEqual(skills.prepare(str(self.source), str(self.cwd), 'grok')['skills'], 1)

    def test_gemini_requires_enabled_native_discovery_and_preserves_trust_settings(self):
        self.skill()
        with patch.object(skills.subprocess, 'run', return_value=SimpleNamespace(returncode=0, stdout='Built-in skills only')):
            with self.assertRaisesRegex(ValueError, 'Trust this working directory in Gemini'):
                skills.prepare(str(self.source), str(self.cwd), 'gemini')
        with patch.object(skills.subprocess, 'run', return_value=SimpleNamespace(returncode=0, stdout='orb-marker [Enabled] [Project]')):
            self.assertEqual(skills.prepare(str(self.source), str(self.cwd), 'gemini')['skills'], 1)
        self.assertFalse((self.cwd / '.gemini/settings.json').exists())

    def test_shell_wrapper_allows_skill_free_projects_without_python(self):
        program = Path(__file__).parents[1] / 'shared/prepare_project_skills.sh'
        result = subprocess.run(['/bin/sh', '-c', program.read_text(), 'orb-project-skills', str(self.source), 'codex', 'unused', str(self.cwd)], env={'PATH': '/nonexistent'}, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.skill()
        result = subprocess.run(['/bin/sh', '-c', program.read_text(), 'orb-project-skills', str(self.source), 'codex', 'unused', str(self.cwd)], env={'PATH': '/nonexistent'}, capture_output=True, text=True)
        self.assertEqual(result.returncode, 78)
        self.assertIn('Install it on the execution machine', result.stderr)

    def test_symlinked_parent_or_supporting_file_is_not_followed(self):
        original = self.skill()
        outside = self.base / 'outside'
        outside.mkdir()
        (self.cwd / '.agents').symlink_to(outside)
        with self.assertRaisesRegex(ValueError, 'real directory'):
            self.prepare()
        (self.cwd / '.agents').unlink()
        (original / 'references/escape').symlink_to(outside)
        with self.assertRaisesRegex(ValueError, 'must not be a symlink'):
            self.prepare()

    def test_concurrent_preparation_is_serialized_without_config_changes(self):
        self.skill()
        processes = [multiprocessing.Process(target=concurrent_prepare, args=(str(self.source), str(self.cwd), harness)) for harness in skills.NATIVE]
        for process in processes:
            process.start()
        for process in processes:
            process.join(10)
            self.assertEqual(process.exitcode, 0)
        state = json.loads((self.cwd / skills.MANIFEST).read_text())
        self.assertEqual(len(state['entries']), len(skills.NATIVE))
        for relative in state['entries']:
            self.assertTrue((self.cwd / relative).is_symlink())


if __name__ == '__main__':
    unittest.main()
