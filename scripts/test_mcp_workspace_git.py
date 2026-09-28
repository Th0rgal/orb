import json
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).with_name("mcp_workspace_git.py")


class WorkspaceGitTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repo = self.root / "repo"
        self.repo.mkdir()
        self.git("init", "-b", "main")
        self.git("config", "user.email", "fixture@example.invalid")
        self.git("config", "user.name", "Fixture")
        (self.repo / "file").write_text("base\n")
        self.git("add", "file")
        self.git("commit", "-m", "base")

    def git(self, *args):
        return subprocess.check_output(["git", "-C", str(self.repo), *args], stderr=subprocess.STDOUT).decode().strip()

    def operation(self, operation, **args):
        result = subprocess.run(["python3", str(SCRIPT), json.dumps({"operation": operation, "repo_path": "repo", **args})], cwd=self.root, capture_output=True, text=True)
        return result.returncode, json.loads(result.stdout)

    def test_create_remove_and_preserve_dirty_worktree(self):
        code, receipt = self.operation("create_worktree", path="worker", branch="worker")
        self.assertEqual(code, 0, receipt)
        (self.root / "worker" / "untracked").write_text("keep")
        code, _ = self.operation("remove_worktree", path="worker")
        self.assertNotEqual(code, 0)
        self.assertTrue((self.root / "worker" / "untracked").is_file())
        (self.root / "worker" / "untracked").unlink()
        code, receipt = self.operation("remove_worktree", path="worker")
        self.assertEqual(code, 0, receipt)
        self.assertFalse((self.root / "worker").exists())

    def test_paths_and_flags_cannot_escape(self):
        for arguments in [dict(path="../escape", branch="worker"), dict(path="worker", branch="--detach")]:
            code, _ = self.operation("create_worktree", **arguments)
            self.assertNotEqual(code, 0)
        (self.root / "escape").symlink_to(self.root.parent, target_is_directory=True)
        code, _ = self.operation("create_worktree", path="escape/new", branch="worker")
        self.assertNotEqual(code, 0)

    def test_merge_has_commit_evidence_and_does_not_checkout(self):
        self.git("checkout", "-b", "feature")
        (self.repo / "extra").write_text("feature\n")
        self.git("add", "extra")
        self.git("commit", "-m", "feature")
        code, _ = self.operation("merge_branch", source_branch="feature", target_branch="main")
        self.assertNotEqual(code, 0)
        self.assertEqual(self.git("branch", "--show-current"), "feature")
        self.git("checkout", "main")
        code, receipt = self.operation("merge_branch", source_branch="feature", target_branch="main", delete_source=True)
        self.assertEqual(code, 0, receipt)
        self.assertTrue(receipt["merged"])
        self.assertTrue(receipt["source_deleted"])
        self.assertEqual(receipt["commit"], self.git("rev-parse", "HEAD"))

    def test_conflicting_merge_is_aborted(self):
        self.git("checkout", "-b", "feature")
        (self.repo / "file").write_text("feature\n")
        self.git("commit", "-am", "feature")
        self.git("checkout", "main")
        (self.repo / "file").write_text("main\n")
        self.git("commit", "-am", "main")
        before = self.git("rev-parse", "HEAD")
        code, receipt = self.operation("merge_branch", source_branch="feature", target_branch="main")
        self.assertEqual(code, 0, receipt)
        self.assertFalse(receipt["merged"])
        self.assertTrue(receipt["aborted"])
        self.assertEqual(receipt["conflicted_files"], ["file"])
        self.assertEqual(self.git("rev-parse", "HEAD"), before)
        self.assertEqual(self.git("status", "--porcelain"), "")


if __name__ == "__main__":
    unittest.main()
