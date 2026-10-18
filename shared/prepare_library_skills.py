"""Install Library skills as native copies on a remote execution machine.

Invoked by the remote job wrapper in the final mission cwd:

    python3 -c PROGRAM cleanup|install HARNESS ARCHIVE SHA256

`cleanup` removes only entries this script installed (tracked in
.sandboxed-library-skills.json with a content fingerprint). `install` also
extracts the archive into a content-addressed cache and copies each skill into
the harness's native skill directory, skipping any name that already exists
(project and user skills win). Library skills are best-effort: callers ignore
failures, so nothing here may block a launch.
"""
import fcntl
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import sys
import tarfile
import tempfile

NATIVE = {
    "antigravity": ".agents/skills",
    "vibe": ".vibe/skills",
    "codex": ".agents/skills",
    "claudecode": ".claude/skills",
    "opencode": ".opencode/skills",
    "grok": ".grok/skills",
}
MANIFEST = ".sandboxed-library-skills.json"
LOCK = ".orb-project-skills.lock"
NAME = re.compile(r"[a-z0-9]+(?:-[a-z0-9]+)*")


def notice(message):
    print(f"Library skills: {message}", file=sys.stderr)


def valid_name(name):
    return bool(NAME.fullmatch(name)) and len(name) <= 64


def fingerprint(path):
    result = {}
    for item in sorted(path.rglob("*")):
        if item.is_symlink():
            return None
        if item.is_file():
            result[str(item.relative_to(path))] = hashlib.sha256(item.read_bytes()).hexdigest()
    return result


def read_state(cwd):
    path = cwd / MANIFEST
    if path.is_symlink():
        raise ValueError(f"manifest is a symlink: {path}")
    if not path.exists():
        return {"version": 1, "entries": {}}
    state = json.loads(path.read_text())
    if state.get("version") != 1 or not isinstance(state.get("entries"), dict):
        raise ValueError(f"invalid manifest: {path}")
    roots = set(NATIVE.values())
    for relative, files in state["entries"].items():
        parts = PurePosixPath(relative).parts
        if len(parts) != 3 or "/".join(parts[:2]) not in roots or not valid_name(parts[2]) or not isinstance(files, dict):
            raise ValueError(f"invalid manifest entry: {relative}")
    return state


def save_state(cwd, state):
    with tempfile.NamedTemporaryFile(mode="w", dir=cwd, prefix=".sandboxed-library-skills-", delete=False) as file:
        json.dump(state, file, sort_keys=True)
        file.flush()
        os.fsync(file.fileno())
        temporary = file.name
    os.replace(temporary, cwd / MANIFEST)


def safe_parents(cwd, relative):
    parent = cwd
    for part in PurePosixPath(relative).parts[:-1]:
        parent = parent / part
        if parent.is_symlink() or (parent.exists() and not parent.is_dir()):
            return False
    return True


def cleanup(cwd, state):
    """Remove owned, unmodified entries. Modified or replaced entries become
    user-owned: they are forgotten, never deleted."""
    for relative, files in sorted(state["entries"].items()):
        path = cwd / relative
        if safe_parents(cwd, relative) and path.is_dir() and not path.is_symlink() and fingerprint(path) == files:
            shutil.rmtree(path)
        elif os.path.lexists(path):
            notice(f"leaving modified {relative} in place (no longer managed)")
    state["entries"] = {}


def safe_members(archive):
    for member in archive.getmembers():
        parts = PurePosixPath(member.name).parts
        if member.name.startswith("/") or ".." in parts or not parts or parts[0] != "skills":
            raise ValueError(f"unsafe archive member: {member.name}")
        if len(parts) >= 2 and not valid_name(parts[1]):
            raise ValueError(f"invalid skill name in archive: {member.name}")
        if not (member.isfile() or member.isdir()):
            raise ValueError(f"archive member is not a regular file: {member.name}")
        yield member


def cache_root():
    base = os.environ.get("XDG_CACHE_HOME") or os.path.join(os.path.expanduser("~"), ".cache")
    return Path(base) / "sandboxed-sh" / "library-skills"


def extract(archive_path, sha):
    if not re.fullmatch(r"[0-9a-f]{64}", sha):
        raise ValueError("invalid archive hash")
    root = cache_root()
    final = root / sha
    if final.is_dir() and not final.is_symlink():
        return final
    data = Path(archive_path).read_bytes()
    if hashlib.sha256(data).hexdigest() != sha:
        raise ValueError("archive hash mismatch")
    root.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(dir=root, prefix=".extract-"))
    try:
        with tarfile.open(archive_path, "r:gz") as archive:
            for member in safe_members(archive):
                target = staging / member.name
                if member.isdir():
                    target.mkdir(parents=True, exist_ok=True)
                    continue
                target.parent.mkdir(parents=True, exist_ok=True)
                source = archive.extractfile(member)
                with open(target, "wb") as out:
                    shutil.copyfileobj(source, out)
        try:
            os.rename(staging, final)
        except OSError:
            if not final.is_dir():
                raise
    finally:
        if staging.exists():
            shutil.rmtree(staging, ignore_errors=True)
    return final


def install(cwd, state, harness, archive_path, sha):
    cleanup(cwd, state)
    native = NATIVE.get(harness)
    if not native:
        notice(f"{harness} has no native skill directory; skipping")
        return
    if not archive_path or not sha:
        return
    skills_dir = extract(archive_path, sha) / "skills"
    if not skills_dir.is_dir():
        return
    for folder in sorted(skills_dir.iterdir()):
        name = folder.name
        if not valid_name(name) or not (folder / "SKILL.md").is_file():
            continue
        relative = f"{native}/{name}"
        if not safe_parents(cwd, relative):
            notice(f"{native} is not a real directory; skipping Library skills")
            return
        destination = cwd / relative
        if os.path.lexists(destination):
            notice(f"{relative} already exists (project or user skill wins); skipping Library copy")
            continue
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copytree(folder, destination, symlinks=False)
        state["entries"][relative] = fingerprint(destination)


def main(argv):
    mode, harness = argv[1], argv[2]
    archive_path = argv[3] if len(argv) > 3 else ""
    sha = argv[4] if len(argv) > 4 else ""
    cwd = Path.cwd().resolve(strict=True)
    if mode == "cleanup" and not (cwd / MANIFEST).exists():
        return 0
    fd = os.open(cwd / LOCK, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "r+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        state = read_state(cwd)
        try:
            if mode == "cleanup":
                cleanup(cwd, state)
            elif mode == "install":
                install(cwd, state, harness, archive_path, sha)
            else:
                raise ValueError(f"unknown mode {mode}")
        finally:
            # Record whatever was installed, even after a partial failure, so
            # every copy stays owned and removable.
            if state["entries"] or (cwd / MANIFEST).exists():
                save_state(cwd, state)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except Exception as error:  # best-effort: report, never block the launch
        notice(f"skipped ({error})")
        sys.exit(0)
