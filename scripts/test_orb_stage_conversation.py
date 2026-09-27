import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
import uuid

spec = importlib.util.spec_from_file_location('stage', Path(__file__).with_name('orb_stage_conversation.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class ArchiveTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.uploads = self.root / 'uploads'
        self.workspace = self.root / 'workspace'
        self.workspace.mkdir()
        self.identifier = str(uuid.uuid4())
        self.directory = self.uploads / self.identifier
        self.directory.mkdir(parents=True)
        self.part = self.directory / 'events.jsonl.0'
        self.part.write_text('🕊 complete tool output\n')
        self.manifest = self.directory / 'conversation.json'
        self.manifest.write_text(json.dumps({'event_parts': [str(self.part)]}))
        self.cwd = Path.cwd()
        os.chdir(self.workspace)
    def tearDown(self):
        os.chdir(self.cwd)
        self.temp.cleanup()
    def test_stages_inside_workspace_and_retries_without_overwriting(self):
        for _ in range(2):
            module.stage(str(self.uploads), self.identifier)
        target = self.workspace / '.paloma/conversation' / self.identifier
        manifest = json.loads((target / 'conversation.json').read_text())
        self.assertEqual((self.workspace / manifest['event_parts'][0]).read_bytes(), self.part.read_bytes())
    def test_rejects_upload_traversal(self):
        self.manifest.write_text(json.dumps({'event_parts': [str(self.root / 'secret')]}))
        with self.assertRaises(ValueError): module.stage(str(self.uploads), self.identifier)
    def test_refuses_workspace_symlink(self):
        (self.workspace / '.paloma').symlink_to(self.root, target_is_directory=True)
        with self.assertRaises(OSError): module.stage(str(self.uploads), self.identifier)
        self.assertFalse((self.root / 'conversation').exists())
    def test_refuses_source_symlink(self):
        self.part.unlink()
        self.part.symlink_to(self.manifest)
        with self.assertRaises(OSError): module.stage(str(self.uploads), self.identifier)

if __name__ == '__main__': unittest.main()
