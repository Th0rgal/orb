#!/usr/bin/env python3
"""Provision development identity from a private JSON stream; never log credentials.

Core resolves Bitwarden; nodes receive only the selected development credentials.
The managed root stays outside mission directories and transferable project data.
"""
from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import pwd
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request
import urllib.error
import uuid

FIELDS = ("GITHUB_TOKEN", "GITHUB_SSH_PRIVATE_KEY", "GITHUB_SSH_PUBLIC_KEY",
          "GIT_SIGNING_PRIVATE_KEY", "PALOMA_SSH_PRIVATE_KEY", "PALOMA_SSH_PUBLIC_KEY")
FINGERPRINT = "30EAE29B6766A7A70A4DEB4BF480B9A3F84BE648"
SSH_FINGERPRINT = "SHA256:sjqEzn4AF7dPpBvNPK5bfJ0sAsIk7qKxrp4PbF5Ekd0"
ADMIN_FINGERPRINT = "SHA256:DudUQO4SLLQgsBYmLgkd8aUNSWg7jeLqG/TUiO7/E10"


def run(argv, *, data=None, env=None, cwd=None, timeout=60):
    p = subprocess.run(argv, input=data, text=True, capture_output=True,
                       env=env, cwd=cwd, timeout=timeout)
    if p.returncode:
        # stderr may contain credentials, URLs or environment values.
        raise RuntimeError(f"{Path(argv[0]).name} failed (exit {p.returncode})")
    return p.stdout


def write(path, value, mode=0o600):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    with open(path, "w", encoding="utf-8") as f:
        os.fchmod(f.fileno(), mode)
        f.write(value)


def atomic_json(path, value):
    tmp = path.with_name(path.name + ".tmp-" + uuid.uuid4().hex)
    write(tmp, json.dumps(value, indent=2) + "\n")
    os.replace(tmp, path)


def validate_bundle(bundle):
    if set(bundle) != {"secrets", "known_hosts", "ssh_hosts", "library_revision", "skill"}:
        raise ValueError("unexpected bundle fields")
    secrets = bundle["secrets"]
    if set(secrets) != set(FIELDS) or any(not isinstance(secrets[k], str) or not secrets[k].strip() for k in FIELDS):
        raise ValueError("development secrets missing or unexpected")
    if not bundle["known_hosts"].strip():
        raise ValueError("verified known_hosts required")
    for public in ["GITHUB_SSH_PUBLIC_KEY", "PALOMA_SSH_PUBLIC_KEY"]:
        if "PRIVATE KEY" in secrets[public] or not secrets[public].startswith("ssh-ed25519 "):
            raise ValueError("expected an Ed25519 public key")
    for host in bundle["ssh_hosts"]:
        if set(host) != {"alias", "hostname", "user"}:
            raise ValueError("invalid SSH host")
        if any(not v or any(c.isspace() for c in v) for v in host.values()):
            raise ValueError("invalid SSH host value")


def github_login(token):
    req = urllib.request.Request("https://api.github.com/user", headers={
        "Authorization": "Bearer " + token, "User-Agent": "sandboxed-development-identity"})
    with urllib.request.urlopen(req, timeout=20) as r:
        login = json.load(r)["login"]
    if login != "Th0rgal":
        raise ValueError("unexpected GitHub identity")
    return login


def default_root():
    return Path(pwd.getpwuid(os.getuid()).pw_dir) / ".config/sandboxed-sh/development-identity"


def profile_env(root, parent=None):
    root = Path(root).resolve()
    generation = (root / "current").resolve(strict=True)
    env = dict(os.environ if parent is None else parent)
    if sys.platform == "darwin":
        nix_bin = Path(pwd.getpwuid(os.getuid()).pw_dir) / ".nix-profile/bin"
        if (nix_bin / "git").is_file():
            env["PATH"] = str(nix_bin) + ":" + env.get("PATH", "/usr/bin:/bin")
    token = (generation / "github-token").read_text().strip()
    for key in ["GH_TOKEN", "GITHUB_TOKEN", "GIT_AUTHOR_NAME", "GIT_AUTHOR_EMAIL",
                "GIT_COMMITTER_NAME", "GIT_COMMITTER_EMAIL", "GIT_CONFIG_PARAMETERS"]:
        env.pop(key, None)
    env.update(GH_TOKEN=token, GITHUB_TOKEN=token, GH_CONFIG_DIR=str(generation / "gh"),
               GNUPGHOME=str(generation / "gnupg"),
               GIT_SSH_COMMAND="ssh -F " + shlex.quote(str(generation / "ssh/config")),
               SANDBOXED_DEVELOPMENT_IDENTITY=str(root))
    # Append after existing credentials/read-only policy, without deleting it.
    n = int(env.get("GIT_CONFIG_COUNT", "0"))
    env[f"GIT_CONFIG_KEY_{n}"] = "include.path"
    env[f"GIT_CONFIG_VALUE_{n}"] = str(generation / "gitconfig")
    env["GIT_CONFIG_COUNT"] = str(n + 1)
    return env


def activation(root):
    """Shell hook reads the current generation per command, never embeds a token."""
    current = shlex.quote(str(root.resolve() / "current"))
    prefix = ""
    if sys.platform == "darwin":
        nix_bin = Path(pwd.getpwuid(os.getuid()).pw_dir) / ".nix-profile/bin"
        if (nix_bin / "git").is_file():
            prefix = 'export PATH=' + shlex.quote(str(nix_bin)) + ':"$PATH"\n'
    return prefix + f'''# Managed by sandboxed.sh development_identity.py; safe to source.
_sdi_current={current}
if [ -r "$_sdi_current/github-token" ]; then
  export GH_TOKEN="$(cat "$_sdi_current/github-token")"
  export GITHUB_TOKEN="$GH_TOKEN"
  export GH_CONFIG_DIR="$_sdi_current/gh"
  export GNUPGHOME="$_sdi_current/gnupg"
  export GIT_SSH_COMMAND="ssh -F $_sdi_current/ssh/config"
  unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_CONFIG_PARAMETERS
  _sdi_n=${{GIT_CONFIG_COUNT:-0}}
  case "$_sdi_n" in *[!0-9]*|'') _sdi_n=0;; esac
  export "GIT_CONFIG_KEY_$_sdi_n=include.path"
  export "GIT_CONFIG_VALUE_$_sdi_n=$_sdi_current/gitconfig"
  export GIT_CONFIG_COUNT=$((_sdi_n + 1))
  export SANDBOXED_DEVELOPMENT_IDENTITY={shlex.quote(str(root.resolve()))}
fi
unset _sdi_current _sdi_n
'''


def prepare_skills(root, directory):
    """Install only the common managed skill; leave project skill selection alone."""
    source = (root / "current/skill").resolve(strict=True)
    directory = Path(directory)
    for relative in [".agents/skills", ".claude/skills", ".codex/skills", ".opencode/skills"]:
        dest = directory / relative / "development-identity"
        dest.parent.mkdir(parents=True, exist_ok=True)
        if dest.is_symlink():
            if dest.resolve() == source: continue
            if "development-identity" not in str(dest.resolve()):
                raise ValueError("existing skill link belongs to another source")
            dest.unlink()
        elif dest.exists():
            # A Library-selected or user-managed copy has priority over our
            # discovery link. Never delete it or block a mission on this helper.
            continue
        dest.symlink_to(source, target_is_directory=True)
    receipt = json.loads((source.parent / "receipt.json").read_text())
    atomic_json(directory / ".paloma/development-identity.json", receipt)


def managed_block(path, block):
    begin, end = "# >>> sandboxed development identity >>>", "# <<< sandboxed development identity <<<"
    old = path.read_text() if path.exists() else ""
    if begin in old:
        start = old.index(begin); finish = old.index(end, start) + len(end)
        new = old[:start] + begin + "\n" + block + "\n" + end + old[finish:]
    else:
        new = old.rstrip() + "\n\n" + begin + "\n" + block + "\n" + end + "\n"
    if old != new:
        if path.exists():
            backup = path.with_name(path.name + ".before-development-identity")
            if not backup.exists(): shutil.copy2(path, backup)
        tmp = path.with_name(path.name + ".identity-tmp")
        write(tmp, new, 0o600)
        os.replace(tmp, path)


def install_hooks(root, local=False, companion=None):
    hook = shlex.quote(str(root.resolve() / "activate.sh"))
    if local:
        home = Path(pwd.getpwuid(os.getuid()).pw_dir)
        # Existing Orb builds run their tools in private ~/.orb workspaces.
        # The native companion wrapper below covers arbitrary checkout paths.
        block = f'case "$PWD" in "$HOME"/.orb/*) [ ! -r {hook} ] || . {hook};; esac'
        for filename in [".zshenv", ".bash_profile", ".bashrc"]:
            managed_block(home / filename, block)
    elif os.geteuid() == 0:
        block = "# Only fleet execution accounts; no operator shell takeover.\n"
        for username in ["sandboxed-node", "spark-admin"]:
            try:
                node = pwd.getpwnam(username)
            except KeyError:
                continue
            node_hook = shlex.quote(str(Path(node.pw_dir) / ".config/sandboxed-sh/development-identity/activate.sh"))
            block += f'if [ "$(id -u)" = "{node.pw_uid}" ] && [ -r {node_hook} ]; then\n  . {node_hook}\nfi\n'
        write(Path("/etc/profile.d/sandboxed-development-identity.sh"), block, 0o644)
    if companion:
        companion = Path(companion)
        original = companion.with_name(companion.name + ".identity-native")
        marker = b"# sandboxed-development-identity-wrapper"
        if companion.exists() and marker not in companion.read_bytes()[:200]:
            # An operator/deployer may have installed a newer native binary.
            native_tmp = original.with_name(original.name + ".new")
            shutil.copy2(companion, native_tmp)
            os.replace(native_tmp, original)
        if not original.exists(): raise ValueError("native companion missing")
        body = "#!/bin/sh\n# sandboxed-development-identity-wrapper\n"
        body += 'if [ "$1" = launch ]; then\n'
        body += "  exec " + shlex.join([sys.executable, str(Path(__file__).resolve()), "run", "--", str(original)]) + ' "$@"\nfi\n'
        body += "exec " + shlex.quote(str(original)) + ' "$@"\n'
        tmp = companion.with_name(companion.name + ".identity-new")
        write(tmp, body, 0o755); os.replace(tmp, companion)
    return {"hooks_installed": True, "local": local, "companion": str(companion) if companion else None}


def verify(root, network=True):
    env = profile_env(root)
    generation = (Path(root) / "current").resolve()
    login = github_login(env["GH_TOKEN"]) if network else "not-probed"
    with tempfile.TemporaryDirectory(prefix="identity-verify-") as d:
        run(["git", "init", "-q", d], env=env)
        run(["git", "commit", "-q", "--allow-empty", "-m", "Development identity verification"], env=env, cwd=d)
        signature = run(["git", "log", "-1", "--format=%G? %GF %an <%ae>"], env=env, cwd=d).strip()
        if FINGERPRINT not in signature or "agent@thomas.md" not in signature or signature[0] not in "GU":
            raise RuntimeError("commit signature/identity verification failed")
        run(["git", "verify-commit", "HEAD"], env=env, cwd=d)
    if network:
        r = subprocess.run(["ssh", "-F", str(generation / "ssh/config"), "-T", "git@github.com"], capture_output=True, text=True, timeout=25)
        if "Hi Th0rgal! You've successfully authenticated" not in r.stdout + r.stderr:
            raise RuntimeError("GitHub SSH authentication failed")
        run(["git", "ls-remote", "git@github.com:Th0rgal/sandboxed.sh.git", "HEAD"], env=env)
        run(["git", "ls-remote", "https://github.com/Th0rgal/sandboxed.sh.git", "HEAD"], env=env)
        if shutil.which("gh"):
            if run(["gh", "api", "user", "--jq", ".login"], env=env).strip() != "Th0rgal":
                raise RuntimeError("gh identity mismatch")
        else:
            raise RuntimeError("gh is missing")
    return {"user": pwd.getpwuid(os.getuid()).pw_name, "login": login,
            "signing_fingerprint": FINGERPRINT, "ssh_fingerprint": SSH_FINGERPRINT,
            "signed_commit": "verified", "library_revision": json.loads((generation / "receipt.json").read_text())["library_revision"]}


def prepare_generation(root, bundle):
    root = root.resolve()
    # Keep GnuPG's Unix socket pathname below platform limits.
    stage = root / ("g-" + uuid.uuid4().hex[:12])
    stage.mkdir(mode=0o700)
    s = bundle["secrets"]
    try:
        write(stage / "github-token", s["GITHUB_TOKEN"])
        for private, name in [("GITHUB_SSH_PRIVATE_KEY", "github"), ("PALOMA_SSH_PRIVATE_KEY", "paloma")]:
            write(stage / "ssh" / name, s[private].rstrip() + "\n")
            public = run(["ssh-keygen", "-y", "-P", "", "-f", str(stage / "ssh" / name)])
            expected = s[private.replace("PRIVATE", "PUBLIC")].split()[:2]
            if public.split()[:2] != expected:
                raise RuntimeError("SSH private/public key mismatch")
            write(stage / "ssh" / (name + ".pub"), public)
            fp = run(["ssh-keygen", "-lf", str(stage / "ssh" / (name + ".pub"))])
            if (SSH_FINGERPRINT if name == "github" else ADMIN_FINGERPRINT) not in fp:
                raise RuntimeError("unexpected SSH fingerprint")
        write(stage / "ssh/known_hosts", bundle["known_hosts"])
        ssh = f"Host github.com\n  User git\n  IdentityFile {stage}/ssh/github\n"
        for host in bundle["ssh_hosts"]:
            ssh += f"Host {host['alias']} {host['hostname']}\n  HostName {host['hostname']}\n  User {host['user']}\n  IdentityFile {stage}/ssh/paloma\n"
        ssh += f"Host *\n  IdentitiesOnly yes\n  BatchMode yes\n  StrictHostKeyChecking yes\n  UserKnownHostsFile {stage}/ssh/known_hosts\n  ConnectTimeout 10\n"
        write(stage / "ssh/config", ssh)
        gpg = stage / "gnupg"
        gpg.mkdir(mode=0o700)
        run(["gpg", "--homedir", str(gpg), "--batch", "--import"], data=s["GIT_SIGNING_PRIVATE_KEY"])
        keys = run(["gpg", "--homedir", str(gpg), "--batch", "--with-colons", "--list-secret-keys"])
        if FINGERPRINT not in keys:
            raise RuntimeError("unexpected GPG fingerprint")
        write(gpg / "gpg.conf", "batch\npinentry-mode loopback\n")
        write(stage / "gpg-sign", "#!/bin/sh\nexec gpg --homedir " + shlex.quote(str(gpg)) + ' --batch --pinentry-mode loopback "$@"\n', 0o700)
        helper = "#!/bin/sh\n[ \"$1\" = get ] || exit 0\nhost=\nprotocol=\nwhile IFS= read -r line; do\n case \"$line\" in host=*) host=${line#host=};; protocol=*) protocol=${line#protocol=};; esac\ndone\n[ \"$host\" = github.com ] && [ \"$protocol\" = https ] || exit 0\nprintf 'username=Th0rgal\\npassword='\ncat " + shlex.quote(str(stage / "github-token")) + "\nprintf '\\n'\n"
        write(stage / "git-credential", helper, 0o700)
        write(stage / "gitconfig", f'''[user]
    name = Thomas Marchand (agent)
    email = agent@thomas.md
    signingkey = {FINGERPRINT}
[commit]
    gpgsign = true
[tag]
    gpgsign = true
[gpg]
    format = openpgp
    program = {stage}/gpg-sign
[core]
    sshCommand = ssh -F {stage}/ssh/config
    excludesFile = {stage}/gitignore
[credential "https://github.com"]
    helper =
    helper = {stage}/git-credential
''')
        write(stage / "gitignore", "\n".join([f"/{d}/development-identity" for d in [".agents/skills", ".claude/skills", ".codex/skills", ".opencode/skills"]]) + "\n/.paloma/development-identity.json\n")
        write(stage / "gh/hosts.yml", "github.com:\n    user: Th0rgal\n    git_protocol: ssh\n    oauth_token: " + json.dumps(s["GITHUB_TOKEN"]) + "\n")
        write(stage / "skill/SKILL.md", bundle["skill"])
        atomic_json(stage / "receipt.json", {"created_at": int(time.time()), "library_revision": bundle["library_revision"], "signing_fingerprint": FINGERPRINT})
        return stage
    except Exception:
        shutil.rmtree(stage, ignore_errors=True)
        raise


def install(root, bundle, network=True):
    validate_bundle(bundle)
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    root.chmod(0o700)
    with open(root / ".lock", "a") as lock:
        os.chmod(root / ".lock", 0o600)
        fcntl.flock(lock, fcntl.LOCK_EX)
        encoded = json.dumps(bundle, sort_keys=True).encode()
        # Private change marker only; never include credential hashes in reports.
        digest = hashlib.sha256(encoded).hexdigest()
        marker = root / ".bundle-digest"
        write(root / "activate.sh", activation(root))
        write(root / "launch", "#!/bin/sh\nexec " + shlex.join([sys.executable, str(Path(__file__).resolve()), "run", "--root", str(root.resolve()), "--"]) + ' "$@"\n', 0o700)
        if marker.exists() and marker.read_text() == digest and (root / "current").exists():
            report = verify(root, network)
            atomic_json(root / "status.json", {"last_success": int(time.time()), "library_revision": bundle["library_revision"]})
            return {"changed": False, **report}
        stage = prepare_generation(root, bundle)
        # Verify through a separate pointer before changing the active generation.
        candidate = root / ("candidate-" + uuid.uuid4().hex)
        candidate.mkdir(mode=0o700)
        (candidate / "current").symlink_to(stage)
        try:
            report = verify(candidate, network)
        except Exception:
            shutil.rmtree(stage, ignore_errors=True)
            raise
        finally:
            shutil.rmtree(candidate, ignore_errors=True)
        link = root / ("current-" + uuid.uuid4().hex)
        link.symlink_to(stage)
        os.replace(link, root / "current")
        write(marker, digest)
        atomic_json(root / "status.json", {"last_success": int(time.time()), "library_revision": bundle["library_revision"]})
        # Retain prior generations: running processes may still reference them.
        return {"changed": True, **report}


def export_bundle(config):
    p = subprocess.run(config["bitwarden_command"], capture_output=True, text=True, timeout=60)
    if p.returncode:
        raise RuntimeError("Bitwarden read failed; keeping current credentials")
    values = {x["key"]: x["value"] for x in json.loads(p.stdout)}
    selected = {k: values[k] for k in FIELDS}
    bundle = {"secrets": selected, "known_hosts": Path(config["known_hosts"]).read_text(),
              "ssh_hosts": config["ssh_hosts"], "library_revision": config["library_revision"],
              "skill": Path(config["skill"]).read_text()}
    validate_bundle(bundle)
    github_login(selected["GITHUB_TOKEN"])
    return bundle


def core_request(config, method, path, body=None):
    """Core-only owner session; never distributed to execution machines."""
    def request(token):
        data = None if body is None else json.dumps(body).encode()
        req = urllib.request.Request(config["api_url"] + path, data=data, method=method,
                                     headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=180) as r:
            return json.load(r)
    token_file = Path(config["api_token_file"])
    try:
        return request(token_file.read_text().strip())
    except (FileNotFoundError, urllib.error.HTTPError) as e:
        if isinstance(e, urllib.error.HTTPError) and e.code not in (401, 403): raise
    rows = json.loads(run(config["bitwarden_command"]))
    password = next(x["value"] for x in rows if x["key"] == "DASHBOARD_PASSWORD")
    req = urllib.request.Request(config["api_url"] + "/api/auth/login",
                                 data=json.dumps({"password": password}).encode(),
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=30) as r: token = json.load(r)["token"]
    write(token_file, token)
    return request(token)


def stage_containers(config, bundle):
    reports = []
    for workspace in core_request(config, "GET", "/api/workspaces"):
        if workspace.get("workspace_type") != "container" or workspace.get("status") != "ready": continue
        filesystem = Path(workspace["path"]).resolve()
        if not (filesystem / "usr/bin/python3").exists():
            reports.append({"workspace": workspace["name"], "status": "missing-python"})
            continue
        script = filesystem / "usr/local/lib/sandboxed-sh/development_identity.py"
        write(script, Path(config["script"]).read_text(), 0o755)
        managed = filesystem / "root/.config/sandboxed-sh/development-identity"
        managed.mkdir(parents=True, exist_ok=True, mode=0o700)
        # Provision at the next launch, from inside the actual container.
        # No host absolute path is written into its GPG or Git configuration.
        digest = hashlib.sha256(json.dumps(bundle, sort_keys=True).encode()).hexdigest()
        marker = managed / ".bundle-digest"
        if not marker.exists() or marker.read_text() != digest:
            atomic_json(managed / ".pending-bundle.json", bundle)
        hook = '''if [ -r /root/.config/sandboxed-sh/development-identity/activate.sh ]; then
  . /root/.config/sandboxed-sh/development-identity/activate.sh
fi
'''
        write(filesystem / "etc/profile.d/sandboxed-development-identity.sh", hook, 0o644)
        companion = filesystem / "usr/local/bin/sandboxed-mcp"
        if companion.exists():
            original = companion.with_name(companion.name + ".identity-native")
            if b"# sandboxed-development-identity-wrapper" not in companion.read_bytes()[:200]:
                shutil.copy2(companion, original)
            body = '''#!/bin/sh
# sandboxed-development-identity-wrapper
if [ "$1" = launch ]; then
  exec /usr/bin/python3 /usr/local/lib/sandboxed-sh/development_identity.py run -- /usr/local/bin/sandboxed-mcp.identity-native "$@"
fi
exec /usr/local/bin/sandboxed-mcp.identity-native "$@"
'''
            tmp = companion.with_name(companion.name + ".identity-new")
            write(tmp, body, 0o755); os.replace(tmp, companion)
        if (managed / ".pending-bundle.json").exists():
            result = core_request(config, "POST", f"/api/workspaces/{workspace['id']}/exec", {
                "command": "/usr/bin/python3 /usr/local/lib/sandboxed-sh/development_identity.py run -- /usr/bin/true",
                "cwd": "/root", "timeout_secs": 120})
            if result.get("exit_code") != 0:
                reports.append({"workspace": workspace["name"], "status": "pending-retry"})
                continue
        reports.append({"workspace": workspace["name"], "status": "current"})
    return reports


def sync(config, apply):
    bundle = export_bundle(config)
    if not apply:
        return {"source": "Bitwarden", "login": "Th0rgal", "targets": [t["name"] for t in config["targets"]]}
    reports, failed = [], []
    for t in config["targets"]:
        command = [config["python"], config["script"], "apply", "--root", t["root"]]
        if t.get("user"):
            command = ["sudo", "-n", "-u", t["user"], "-H"] + command
        if t.get("ssh"):
            command = ["ssh", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=10", "-i", config["ssh_identity"], t["ssh"], shlex.join(command)]
        try:
            out = run(command, data=json.dumps(bundle), timeout=180)
            reports.append({"target": t["name"], **json.loads(out)})
        except Exception as error:
            failed.append({"target": t["name"], "error": type(error).__name__})
    containers = stage_containers(config, bundle) if config.get("api_url") else []
    failed.extend({"target": t["workspace"], "error": t["status"]} for t in containers if t["status"] != "current")
    if failed:
        print(json.dumps({"ok": reports, "failed": failed}))
        raise RuntimeError("one or more identity targets failed")
    return {"ok": reports, "containers": containers}


def apply_pending(root):
    pending = root / ".pending-bundle.json"
    if not pending.exists(): return
    data = pending.read_text()
    install(root, json.loads(data))
    # A newer reconciliation may have replaced the pending generation.
    if pending.exists() and pending.read_text() == data: pending.unlink()


def pull(config, root):
    command = ["ssh", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
               "-o", "ConnectTimeout=10", "-i", config["ssh_identity"], config["source_ssh"],
               shlex.join([config["remote_python"], config["remote_script"], "export", "--config", config["remote_config"]])]
    bundle = json.loads(run(command, timeout=90))
    return install(root, bundle)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("action", choices=["apply", "check", "verify", "run", "sync", "export", "hooks", "prepare", "pull"])
    p.add_argument("--root", type=Path, default=default_root())
    p.add_argument("--config", type=Path)
    p.add_argument("--apply", action="store_true")
    p.add_argument("--offline", action="store_true", help="skip network checks (tests only)")
    p.add_argument("--local", action="store_true")
    p.add_argument("--companion", type=Path)
    args, command = p.parse_known_args()
    if args.action == "run":
        if command[:1] == ["--"]: command = command[1:]
        if not command: raise ValueError("command required")
        apply_pending(args.root)
        prepare_skills(args.root, Path.cwd())
        os.execvpe(command[0], command, profile_env(args.root))
    elif args.action == "hooks":
        report = install_hooks(args.root, args.local, args.companion)
    elif args.action == "prepare":
        prepare_skills(args.root, Path.cwd())
        report = {"prepared": True}
    elif args.action == "apply":
        report = install(args.root, json.load(sys.stdin), not args.offline)
    elif args.action == "verify":
        report = verify(args.root, not args.offline)
    elif args.action == "check":
        report = {"configured": (args.root / "current/receipt.json").exists(), "root": str(args.root)}
    elif args.action == "pull":
        report = pull(json.loads(args.config.read_text()), args.root)
    elif args.action == "export":
        if sys.stdout.isatty(): raise ValueError("export requires a pipe; never display credentials")
        print(json.dumps(export_bundle(json.loads(args.config.read_text()))))
        return
    else:
        report = sync(json.loads(args.config.read_text()), args.apply)
    print(json.dumps(report))


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        # No exception text: third-party errors may include credentials.
        detail = str(e) if isinstance(e, RuntimeError) else type(e).__name__
        print("development-identity: " + detail + "; previous credentials retained", file=sys.stderr)
        sys.exit(1)
