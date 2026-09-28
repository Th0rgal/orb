"""Bounded Git operations, executed inside the selected mission workspace.

Input is one JSON argument. The working directory is supplied by the trusted
workspace launcher, never selected from an arbitrary Core path by the caller.
"""
import fcntl
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


def operate(request):
    root = Path.cwd().resolve()

    def path(value):
        candidate = (root / value).resolve()
        if not candidate.is_relative_to(root):
            raise ValueError("Path leaves the mission workspace")
        return candidate

    repo = path(request.get("repo_path") or ".")

    def git(*args, check=True):
        # File-backed output prevents a hook or helper from filling RAM.
        with tempfile.TemporaryFile() as output:
            child = subprocess.Popen(
                ["git", "-C", str(repo), *args], stdout=output,
                stderr=subprocess.STDOUT, start_new_session=True,
                env={**os.environ, "GIT_TERMINAL_PROMPT": "0"},
            )
            try:
                code = child.wait(timeout=120)
            except subprocess.TimeoutExpired:
                import signal
                os.killpg(child.pid, signal.SIGKILL)
                child.wait()
                raise ValueError("Git operation timed out; inspect repository before retrying")
            output.seek(0)
            text = output.read(16384).decode("utf-8", errors="replace")
        if check and code:
            raise ValueError("Git failed: " + text)
        return code, text.strip()

    def branch(value):
        if not value or value.startswith("-"):
            raise ValueError("Invalid branch")
        git("check-ref-format", "--branch", value)
        return value

    git("rev-parse", "--is-inside-work-tree")
    _, common = git("rev-parse", "--path-format=absolute", "--git-common-dir")
    if not Path(common).resolve().is_relative_to(root):
        raise ValueError("Repository metadata leaves the mission workspace")
    # Serialize MCP Git mutations on the actual repository, including sibling
    # worktrees. Native Git still enforces its own index/ref locks.
    with open(Path(common) / "sandboxed-mcp.lock", "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        name = request["operation"]
        result = {"repo_path": str(repo), "operation": name}
        _, origin = git("remote", "get-url", "origin", check=False)
        import re
        identity = re.search(r"github\.com[:/]([^/?#]+/[^/?#]+?)(?:\.git)?$", origin)
        result["repository"] = identity.group(1) if identity else str(repo)
        if name == "create_worktree":
            destination = path(request["path"])
            if destination == root or destination.exists():
                raise ValueError("Worktree destination must be new and inside the mission workspace")
            source = branch(request["branch"])
            exists, _ = git("show-ref", "--verify", "--quiet", "refs/heads/" + source, check=False)
            if exists == 0:
                git("worktree", "add", "--", str(destination), source)
            elif exists == 1:
                base = request.get("base") or "HEAD"
                _, commit = git("rev-parse", "--verify", "--end-of-options", base + "^{commit}")
                git("worktree", "add", "-b", source, "--", str(destination), commit)
            else:
                raise ValueError("Cannot inspect the requested branch")
            result.update(path=str(destination), branch=source, success=True)
        elif name == "remove_worktree":
            destination = path(request["path"])
            if destination in (root, repo):
                raise ValueError("Cannot remove the mission root or primary checkout")
            # Preserve uncommitted files: no implicit --force.
            git("worktree", "remove", "--", str(destination))
            result.update(path=str(destination), success=True)
        elif name == "merge_branch":
            source = branch(request["source_branch"])
            target = branch(request["target_branch"])
            _, head = git("symbolic-ref", "--short", "HEAD")
            if head != target:
                raise ValueError("Repository must already be on the target branch")
            _, dirty = git("status", "--porcelain")
            if dirty:
                raise ValueError("Merge requires a clean checkout")
            _, before = git("rev-parse", "HEAD")
            code, output = git("merge", "--no-edit", "--", source, check=False)
            result.update(merged=code == 0, source_branch=source, target_branch=target,
                          before_commit=before, output=output)
            if code:
                _, conflicts = git("diff", "--name-only", "--diff-filter=U")
                abort, _ = git("merge", "--abort", check=False)
                result.update(conflicted_files=conflicts.splitlines(), aborted=abort == 0)
            else:
                _, result["commit"] = git("rev-parse", "HEAD")
                if request.get("push"):
                    code, output = git("push", "origin", "refs/heads/" + target, check=False)
                    result.update(pushed=code == 0, push_output=output)
                if request.get("delete_source"):
                    code, output = git("branch", "-d", "--", source, check=False)
                    result.update(source_deleted=code == 0, delete_output=output)
        else:
            raise ValueError("Unknown workspace operation")
        return result


if __name__ == "__main__":
    try:
        print(json.dumps(operate(json.loads(sys.argv[1]))))
    except Exception as error:
        print(json.dumps({"success": False, "error": str(error)[:16384]}))
        sys.exit(1)
