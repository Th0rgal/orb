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
        self.base = Path(self.temp.name).resolve()
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
        for native in set(skills.NATIVE.values()):
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

    def test_moved_cwd_accepts_owned_aliases_and_refreshes_copies(self):
        original = self.skill()
        mission = self.base / 'mission'
        mission.mkdir()
        for mode in ['link', 'adapter', 'fallback']:
            with self.subTest(mode=mode):
                if mode == 'adapter':
                    (original / 'SKILL.md').write_text('Plain instructions.')
                if mode == 'fallback':
                    (original / 'SKILL.md').write_text('---\nname: orb-marker\ndescription: valid\n---\nInstructions')
                    with patch.object(Path, 'symlink_to', side_effect=OSError('links unsupported')):
                        skills.prepare(str(self.source), mission, 'claudecode', verify=False)
                else:
                    skills.prepare(str(self.source), mission, 'claudecode', verify=False)
                config = mission / '.claude/settings.json'
                config.write_text('USER-CONFIG')
                (original / 'SKILL.md').write_text((original / 'SKILL.md').read_text() + '\nUPDATED-INSTRUCTIONS')
                (original / 'references/marker.md').write_text('UPDATED-REFERENCE')
                skills.prepare(str(self.source), self.cwd, 'opencode', verify=False, discovery_roots=[mission])
                for directory, native in [(mission, '.claude/skills'), (self.cwd, '.opencode/skills')]:
                    exposed = directory / native / original.name
                    self.assertIn('UPDATED-INSTRUCTIONS', (exposed / 'SKILL.md').read_text())
                    self.assertEqual((exposed / 'references/marker.md').read_text(), 'UPDATED-REFERENCE')
                self.assertEqual(config.read_text(), 'USER-CONFIG')
                shutil.rmtree(original)
                skills.prepare(str(self.source), self.cwd, 'opencode', verify=False, discovery_roots=[mission])
                self.assertFalse((mission / '.claude/skills/orb-marker').exists())
                self.assertFalse((self.cwd / '.opencode/skills/orb-marker').exists())
                original = self.skill()
                shutil.rmtree(mission)
                mission.mkdir()
                shutil.rmtree(self.cwd)
                self.cwd.mkdir()

    def test_moved_cwd_preserves_replaced_or_other_project_aliases(self):
        original = self.skill()
        mission = self.base / 'mission'
        mission.mkdir()
        skills.prepare(str(self.source), mission, 'claudecode', verify=False)
        entry = mission / '.claude/skills/orb-marker'
        entry.unlink()
        entry.mkdir()
        (entry / 'SKILL.md').write_text('USER-REPLACEMENT')
        with self.assertRaisesRegex(ValueError, 'collision'):
            skills.prepare(str(self.source), self.cwd, 'opencode', verify=False, discovery_roots=[mission])
        self.assertEqual((entry / 'SKILL.md').read_text(), 'USER-REPLACEMENT')
        self.assertFalse((self.cwd / '.opencode').exists())
        shutil.rmtree(entry)
        entry.symlink_to(original, target_is_directory=True)
        state = json.loads((mission / skills.MANIFEST).read_text())
        state['source'] = str(self.base / 'other-project')
        (mission / skills.MANIFEST).write_text(json.dumps(state))
        with self.assertRaisesRegex(ValueError, 'per-mission native skill'):
            skills.prepare(str(self.source), self.cwd, 'opencode', verify=False, discovery_roots=[mission])
        self.assertTrue(entry.is_symlink())
        self.assertFalse((self.cwd / '.opencode').exists())

    def test_unmanaged_ancestor_skill_collisions_preserve_originals(self):
        self.skill()
        nested = self.cwd / 'subdir'
        nested.mkdir()
        for harness, aliases in skills.ALIASES.items():
            for alias in aliases:
                with self.subTest(harness=harness, alias=alias):
                    entry = self.cwd / alias / 'orb-marker'
                    entry.mkdir(parents=True)
                    (entry / 'SKILL.md').write_text('USER-ANCESTOR-SKILL')
                    with self.assertRaisesRegex(ValueError, 'collision'):
                        skills.prepare(str(self.source), nested, harness, verify=False)
                    self.assertEqual((entry / 'SKILL.md').read_text(), 'USER-ANCESTOR-SKILL')
                    self.assertFalse((nested / skills.NATIVE[harness]).exists())
                    shutil.rmtree(entry)

    def test_same_project_ancestor_copies_reconcile_edits_rename_and_deletion(self):
        nested = self.cwd / 'subdir'
        nested.mkdir()
        for fallback in [False, True]:
            with self.subTest(fallback=fallback):
                original = self.skill(body=None if fallback else '# old')
                if fallback:
                    with patch.object(Path, 'symlink_to', side_effect=OSError('links unsupported')):
                        self.prepare('claudecode')
                else:
                    self.prepare('claudecode')
                (original / 'SKILL.md').write_text((original / 'SKILL.md').read_text() + '\n# new')
                (original / 'references/marker.md').write_text('NEW-REFERENCE')
                skills.prepare(str(self.source), nested, 'opencode', verify=False)
                for directory, native in [(self.cwd, '.claude/skills'), (nested, '.opencode/skills')]:
                    self.assertIn('# new', (directory / native / 'orb-marker/SKILL.md').read_text())
                    self.assertEqual((directory / native / 'orb-marker/references/marker.md').read_text(), 'NEW-REFERENCE')
                original.rename(original.with_name('renamed'))
                (original.with_name('renamed') / 'SKILL.md').write_text('# renamed')
                skills.prepare(str(self.source), nested, 'opencode', verify=False)
                for directory in [self.cwd, nested]:
                    for native in set(skills.NATIVE.values()):
                        self.assertFalse((directory / native / 'orb-marker').exists())
                    self.assertIn('# renamed', (directory / '.opencode/skills/renamed/SKILL.md').read_text())
                shutil.rmtree(original.with_name('renamed'))
                skills.prepare(str(self.source), nested, 'opencode', verify=False)
                for directory in [self.cwd, nested]:
                    self.assertEqual(json.loads((directory / skills.MANIFEST).read_text())['entries'], {})

    def test_managed_manifest_traversal_is_refused_before_any_cleanup(self):
        for native in set(skills.NATIVE.values()):
            root = self.cwd / native
            (root / 'personal').mkdir(parents=True)
            (root / 'personal/SKILL.md').write_text('PERSONAL-SKILL')
            config = root.parent / 'config'
            config.write_text('USER-CONFIG')
            for relative in [native + '/..', native + '/./personal', native + '/invalid_name']:
                state = {'version': 1, 'source': None, 'entries': {relative: 'crafted'}, 'copies': {relative: skills.fingerprint(root.parent)}}
                (self.cwd / skills.MANIFEST).write_text(json.dumps(state))
                with self.assertRaisesRegex(ValueError, 'Invalid managed skill entry'):
                    skills.prepare(None, str(self.cwd), 'codex')
                self.assertEqual(config.read_text(), 'USER-CONFIG')
                self.assertEqual((root / 'personal/SKILL.md').read_text(), 'PERSONAL-SKILL')

    def test_preserves_user_configuration_and_skills(self):
        self.skill()
        for native in set(skills.NATIVE.values()):
            parent = self.cwd / native
            (parent / 'personal').mkdir(parents=True)
            (parent / 'personal/SKILL.md').write_text('personal')
            (parent.parent / 'config').write_text('user configuration')
        self.prepare()
        shutil.rmtree(self.source / 'skills')
        self.prepare()
        for native in set(skills.NATIVE.values()):
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
            with self.assertRaisesRegex(ValueError, 'frontmatter'):
                self.prepare()
            self.assertFalse((self.cwd / '.agents/skills/orb-marker').exists())
        (original / 'SKILL.md').write_text('---\nname: orb-marker\ndescription: |\n  A multiline description.\n---\nInstructions')
        self.assertEqual(self.prepare()['skills'], 1)

    def test_yaml_comments_and_blocks_are_parsed_and_invalid_metadata_is_refused(self):
        original = self.skill(body='---\nname: "orb-marker" # project name\ndescription: >\n  A folded description.\nmetadata: {category: review}\n---\nInstructions')
        self.prepare()
        for header in ['name: orb-marker\ndescription: valid\nother: [unclosed', 'name: orb-marker\ndescription: 123', 'name: orb-marker\ndescription: true']:
            (original / 'SKILL.md').write_text('---\n' + header + '\n---\nInstructions')
            with self.assertRaisesRegex(ValueError, 'frontmatter'):
                self.prepare()
        (original / 'SKILL.md').write_text('---\nname: orb-marker\ndescription: valid')
        with self.assertRaisesRegex(ValueError, 'Unclosed YAML frontmatter'):
            self.prepare()

    def test_retained_adapter_copies_refresh_across_harness_discovery_aliases(self):
        original = self.skill(body='Original plain Markdown instructions.')
        self.prepare('claudecode')
        (original / 'SKILL.md').write_text('Updated plain Markdown instructions.')
        (original / 'references/marker.md').write_text('UPDATED-REFERENCE')
        self.prepare('opencode')
        for native in ['.claude/skills', '.opencode/skills']:
            self.assertIn('Updated plain Markdown instructions.', (self.cwd / native / 'orb-marker/SKILL.md').read_text())
            self.assertEqual((self.cwd / native / 'orb-marker/references/marker.md').read_text(), 'UPDATED-REFERENCE')

    def test_retained_filesystem_fallback_copies_refresh_when_switching_harness(self):
        original = self.skill()
        with patch.object(Path, 'symlink_to', side_effect=OSError('links unsupported')):
            self.prepare('claudecode')
        (original / 'SKILL.md').write_text((original / 'SKILL.md').read_text() + '\nUpdated instructions.\n')
        (original / 'references/marker.md').write_text('UPDATED-REFERENCE')
        self.prepare('opencode')
        self.assertIn('Updated instructions.', (self.cwd / '.claude/skills/orb-marker/SKILL.md').read_text())
        self.assertEqual((self.cwd / '.claude/skills/orb-marker/references/marker.md').read_text(), 'UPDATED-REFERENCE')
        self.assertTrue((self.cwd / '.opencode/skills/orb-marker').is_symlink())

    def test_missing_yaml_dependency_is_actionable_and_does_not_expose_skills(self):
        self.skill()
        with patch.dict('sys.modules', {'yaml': None}):
            with self.assertRaisesRegex(ValueError, 'Install PyYAML'):
                self.prepare()
        self.assertFalse((self.cwd / '.agents/skills/orb-marker').exists())

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

    def test_selected_harness_binary_and_runtime_prefix_are_used_for_native_inspection(self):
        self.skill()
        for harness, binary, expected in [
            ('grok', '/custom/grok', ['/custom/grok']),
            ('gemini', 'bun /custom/gemini.js', ['bun', '/custom/gemini.js']),
        ]:
            stdout = json.dumps({'skills': [{'name': 'orb-marker', 'enabled': True}]}) if harness == 'grok' else 'orb-marker [Enabled]'
            with patch.dict('os.environ', {'ORB_PROJECT_SKILLS_HARNESS_BIN': binary}), patch.object(skills.subprocess, 'run', return_value=SimpleNamespace(returncode=0, stdout=stdout)) as run:
                skills.prepare(str(self.source), str(self.cwd), harness)
            self.assertEqual(run.call_args.args[0][:len(expected)], expected)

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
        self.assertEqual(len(state['entries']), len(set(skills.NATIVE.values())))
        for relative in state['entries']:
            self.assertTrue((self.cwd / relative).is_symlink())


if __name__ == '__main__':
    unittest.main()
