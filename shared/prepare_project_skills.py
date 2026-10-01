"""Prepare native discovery links to a live project replica, never a snapshot.

Invoked before every launch/resume by Orb, Core, and the remote job wrapper.
No credentials or harness configuration are read or written here.
"""
import fcntl
import json
import hashlib
import shutil
import os
from pathlib import Path
import re
import sys
import tempfile
import subprocess
import shlex

NATIVE = {
    "codex": ".agents/skills",
    "claudecode": ".claude/skills",
    "opencode": ".opencode/skills",
    "gemini": ".gemini/skills",
    "grok": ".grok/skills",
}
ALIASES = {
    "codex": (".agents/skills", ".codex/skills"),
    "claudecode": (".claude/skills",),
    "opencode": (".opencode/skills", ".opencode/skill", ".claude/skills", ".agents/skills"),
    "gemini": (".gemini/skills", ".agents/skills"),
    "grok": (".grok/skills", ".agents/skills", ".claude/skills"),
}
MANIFEST = ".orb-project-skills.json"


def read_state(directory):
    path = directory / MANIFEST
    if path.is_symlink():
        raise ValueError(f"Managed skill manifest is a symlink: {path}")
    if not path.exists():
        return {"source": None, "entries": {}, "copies": {}}
    state = json.loads(path.read_text())
    if state.get("version") != 1 or not isinstance(state.get("entries"), dict):
        raise ValueError(f"Invalid managed skill manifest: {path}")
    for relative, target in state["entries"].items():
        path = Path(relative)
        if not any(relative.startswith(p + "/") for p in NATIVE.values()) or len(path.parts) != 3 or str(path) != relative or not re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", path.name) or len(path.name) > 64 or not isinstance(target, str):
            raise ValueError(f"Invalid managed skill entry: {relative}")
    state.setdefault("copies", {})
    if not isinstance(state["copies"], dict) or any(p not in state["entries"] for p in state["copies"]):
        raise ValueError(f"Invalid managed skill copies: {path}")
    return state


def fingerprint(path):
    result = {}
    for item in sorted(path.rglob("*")):
        if item.is_symlink():
            raise ValueError(f"Supporting skill file must not be a symlink: {item}")
        if item.is_file():
            result[str(item.relative_to(path))] = hashlib.sha256(item.read_bytes()).hexdigest()
    return result


def safe_parents(cwd, relative):
    parent = cwd
    for part in Path(relative).parts[:-1]:
        parent = parent / part
        if parent.is_symlink() or (parent.exists() and not parent.is_dir()):
            raise ValueError(f"Native skill parent must be a real directory: {parent}")


def owns_entry(directory, state, relative, target):
    safe_parents(directory, relative)
    if state["entries"].get(relative) != target:
        return False
    path = directory / relative
    copy = state["copies"].get(relative)
    return ((copy is not None and path.is_dir() and not path.is_symlink() and fingerprint(path) == copy)
            or (copy is None and path.is_symlink() and os.readlink(path) == target))


def prepare(source, cwd, harness, verify=True, cleanup_only=False, discovery_roots=(), _refresh_roots=True):
    cwd = Path(cwd).resolve(strict=True)
    source = str(Path(source).resolve(strict=True)) if source else None
    if source and cwd.is_relative_to(Path(source)) and any(Path(source).glob("skills/*/SKILL.md")):
        raise ValueError("Choose a working directory outside the synchronized project files; native discovery entries must not be synchronized as source files.")
    # A moved mission still exposes its private directory to native discovery.
    # Refresh its owned copies and cleanup before locking the new cwd; nesting
    # directory locks would deadlock concurrent moves in opposite directions.
    discovery_roots = tuple(dict.fromkeys((*(Path(root).resolve(strict=True) for root in discovery_roots), *cwd.parents)))
    if _refresh_roots:
        # Reconcile each root once, outermost first, without nested locks or
        # recursive ancestor refreshes. Native scanners also walk ancestors.
        for directory in sorted(discovery_roots, key=lambda path: len(path.parts)):
            if directory != cwd:
                owned = read_state(directory)
                if owned["entries"] and owned["source"] == source:
                    prepare(source, directory, harness, verify=False, cleanup_only=cleanup_only, _refresh_roots=False)
    lock_path = cwd / ".orb-project-skills.lock"
    fd = os.open(lock_path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "r+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        state = read_state(cwd)
        # Harnesses can discover skills in ancestor directories. Do not allow
        # an Orb-managed parent project to contaminate this project either.
        for directory in (cwd, *cwd.parents):
            owned = read_state(directory)
            if owned["entries"] and owned["source"] != source:
                raise ValueError(f"{directory} contains skills belonging to another project. Choose a separate working directory (outside that directory).")

        skills = {}
        adapters = {}
        root = Path(source) / "skills" if source else None
        if root and root.is_symlink():
            raise ValueError(f"Project skills directory must not be a symlink: {root}")
        if root and root.exists():
            for folder in sorted(root.iterdir()):
                if folder.is_symlink():
                    raise ValueError(f"Project skill folder must not be a symlink: {folder}")
                skill = folder / "SKILL.md"
                if not folder.is_dir() or not skill.exists():
                    continue
                if skill.is_symlink():
                    raise ValueError(f"Project SKILL.md must not be a symlink: {skill}")
                if not re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", folder.name) or len(folder.name) > 64:
                    raise ValueError(f"Rename {folder}: skill names must be lowercase letters, numbers and hyphens (at most 64 characters).")
                text = skill.read_text(encoding="utf-8")
                header = re.match(r"\A---\r?\n(.*?)\r?\n---(?:\r?\n|$)", text, re.S)
                if not header:
                    # Preserve plain Markdown verbatim in an adapted native
                    # copy. Its instructions explicitly direct edits home.
                    description = next((line.strip().lstrip("# ") for line in text.splitlines() if line.strip()), f"Project skill {folder.name}")
                    adapters[folder.name] = f"---\nname: {folder.name}\ndescription: {json.dumps(description[:1024])}\n---\n\nSource: {skill}. Edit the synchronized source and its supporting files there; this is a generated discovery copy.\n\n{text}"
                if header:
                    try:
                        import yaml
                    except ImportError:
                        raise ValueError("Install PyYAML for Python 3 on the execution machine (python3-yaml on Debian/Ubuntu), then retry project skill preparation.") from None
                    try:
                        metadata = yaml.safe_load(header[1])
                    except yaml.YAMLError as error:
                        raise ValueError(f"Invalid YAML frontmatter in {skill}: {error}. Fix the YAML and retry.") from None
                    if not isinstance(metadata, dict) or not isinstance(metadata.get("name"), str) or metadata["name"] != folder.name or not isinstance(metadata.get("description"), str) or not metadata["description"].strip():
                        raise ValueError(f"Set frontmatter name: {folder.name} and a nonempty string description: in {skill}.")
                elif text.startswith(("---\n", "---\r\n")):
                    raise ValueError(f"Unclosed YAML frontmatter in {skill}. Add its closing --- delimiter and retry.")
                fingerprint(folder)
                skills[folder.name] = str(folder)
        if skills and harness not in NATIVE:
            raise ValueError(f"{harness} has no supported project skill discovery mechanism. Select Codex, Claude Code, OpenCode, Gemini or Grok, or remove project skills.")

        entries = state["entries"].copy()
        desired = {f"{NATIVE[harness]}/{name}": target for name, target in skills.items()} if harness in NATIVE and not cleanup_only else {}
        # Other harnesses can scan previously used native aliases. Retained
        # generated copies must all reflect the source before this launch.
        if not cleanup_only:
            desired.update({relative: skills[Path(relative).name] for relative in state["copies"] if Path(relative).name in skills})
        stale = {relative: target for relative, target in entries.items() if Path(relative).name not in skills}
        # Preflight every mutation before touching anything. A replaced managed
        # link is now user-owned: never remove or overwrite it.
        for relative, target in {**entries, **desired}.items():
            safe_parents(cwd, relative)
            path = cwd / relative
            if os.path.lexists(path):
                expected = entries.get(relative)
                copy = state["copies"].get(relative)
                owned = expected and ((copy is not None and path.is_dir() and not path.is_symlink() and fingerprint(path) == copy) or (copy is None and path.is_symlink() and os.readlink(path) == expected))
                if not owned:
                    raise ValueError(f"Skill name collision at {path}. Rename the project skill or move the existing user-managed entry; Orb will not overwrite it.")
        # Compatible discovery aliases can contain a different skill with the
        # same native name (notably Library's .opencode/skill). Be explicit
        # instead of silently relying on harness-specific precedence.
        for name, target in (skills.items() if not cleanup_only else ()):
            for discovery_root in discovery_roots:
                discovery_root = Path(discovery_root).resolve(strict=True)
                for alias in ALIASES.get(harness, ()):
                    path = discovery_root / alias / name
                    if discovery_root != cwd and os.path.lexists(path):
                        owned = read_state(discovery_root)
                        if owned["source"] == source and owns_entry(discovery_root, owned, f"{alias}/{name}", target):
                            continue
                        raise ValueError(f"Skill name collision at {path}. Rename the project skill; Orb will preserve the per-mission native skill.")
            for alias in ALIASES.get(harness, ()):
                relative = f"{alias}/{name}"
                path = cwd / relative
                if relative in desired or not os.path.lexists(path):
                    continue
                if entries.get(relative) != target:
                    raise ValueError(f"Skill name collision at {path}. Rename the project skill; Orb will preserve the existing native skill.")

        def save():
            with tempfile.NamedTemporaryFile(mode="w", dir=cwd, prefix=".orb-project-skills-", delete=False) as file:
                temporary = file.name
                json.dump(state, file)
                file.flush()
                os.fsync(file.fileno())
            os.replace(temporary, cwd / MANIFEST)

        state.update(version=1, source=source)
        if not entries and not desired:
            return {"skills": 0, "source": source}
        for relative in stale:
            path = cwd / relative
            if os.path.lexists(path):
                if relative in state["copies"]:
                    shutil.rmtree(path)
                else:
                    path.unlink()
            state["entries"].pop(relative)
            state["copies"].pop(relative, None)
            save()
        if cleanup_only:
            return {"skills": len(skills), "source": source}
        for relative, target in desired.items():
            path = cwd / relative
            content = adapters.get(Path(relative).name)
            if content is None and relative not in state["copies"] and os.path.lexists(path):
                continue
            path.parent.mkdir(parents=True, exist_ok=True)
            if content is None and not os.path.lexists(path):
                state["entries"][relative] = target
                save()  # interrupted link creation is recoverable
                try:
                    path.symlink_to(target, target_is_directory=True)
                    continue
                except OSError:
                    # Some filesystems disallow links. Generate a native copy
                    # with an explicit source notice instead of losing skills.
                    content = (Path(target) / "SKILL.md").read_text()
            if content is None:
                content = (Path(target) / "SKILL.md").read_text()
            if Path(relative).name not in adapters:
                split = re.match(r"(---\r?\n.*?\r?\n---(?:\r?\n|$))(.*)", content, re.S)
                content = f"{split[1]}\nSource: {target}/SKILL.md. Edit the synchronized source; this is a generated discovery copy.\n{split[2]}"
            stage = Path(tempfile.mkdtemp(dir=cwd, prefix=".orb-skill-"))
            try:
                shutil.copytree(target, stage, dirs_exist_ok=True)
                (stage / "SKILL.md").write_text(content)
                # Record the new content before installing it; on interruption
                # a missing owned entry can safely be rebuilt on the next turn.
                if os.path.lexists(path):
                    if path.is_symlink():
                        path.unlink()
                    else:
                        shutil.rmtree(path)
                state["entries"][relative] = target
                state["copies"][relative] = fingerprint(stage)
                save()
                os.replace(stage, path)
            finally:
                if stage.exists():
                    shutil.rmtree(stage)
        if skills and harness in ("grok", "gemini") and verify:
            # These harnesses silently omit workspace skills when the folder
            # is untrusted. Listing must confirm discovery before launching.
            binary = os.environ.get("ORB_PROJECT_SKILLS_HARNESS_BIN", harness)
            # Runner availability checks can select an absolute binary or a
            # runtime command such as `bun /path/to/gemini.js`.
            command = [binary] if Path(binary).is_file() else shlex.split(binary)
            arguments = command + (["--cwd", str(cwd), "inspect", "--json"] if harness == "grok" else ["skills", "list", "--all"])
            inspection = subprocess.run(arguments, cwd=cwd, capture_output=True, text=True, timeout=20)
            label = "Grok" if harness == "grok" else "Gemini"
            if inspection.returncode:
                raise ValueError(f"{label} could not inspect project skills. Update its CLI and check its project configuration before retrying.")
            if harness == "grok":
                discovered = json.loads(inspection.stdout)
                names = {entry.get("name") for entry in discovered.get("skills", []) if isinstance(entry, dict) and entry.get("enabled") is not False and entry.get("disabled") is not True}
            else:
                names = set(re.findall(r"^([a-z0-9-]+) \[Enabled\]", inspection.stdout, re.M))
            if not set(skills).issubset(names):
                raise ValueError(f"{label} did not discover the prepared project skills. Trust this working directory in {label} and enable its project skills, then retry. Orb will not change your trust configuration.")
        return {"skills": len(skills), "source": source}


if __name__ == "__main__":
    try:
        source, harness, *directory = sys.argv[1:]
        print(json.dumps(prepare(source or None, directory[0] if directory else os.getcwd(), harness, cleanup_only=os.environ.get("ORB_PROJECT_SKILLS_CLEANUP_ONLY") == "1", discovery_roots=json.loads(os.environ.get("ORB_PROJECT_SKILLS_DISCOVERY_ROOTS", "[]")))))
    except Exception as error:
        print(f"Prepare project skills: {error} Fix the project files or working directory and retry; your draft is kept.", file=sys.stderr)
        sys.exit(78)
