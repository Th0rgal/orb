#!/usr/bin/env python3
"""Build and maintain the boat.dev `orb-node-base` named snapshot (managed machines).

Usage (BOAT_API_KEY is read from the environment and never printed):
  eval "$(~/work/paloma/bin/bws-env BOAT_API_KEY)"
  python3 scripts/managed_image.py build --node-source <git-ref | worktree path>
  python3 scripts/managed_image.py node-binary --node-source <ref|path>
  python3 scripts/managed_image.py refresh-node --binary <path> [--node-version V]
  python3 scripts/managed_image.py smoke [<snapshot>]
  python3 scripts/managed_image.py list
  python3 scripts/managed_image.py stop-all-ours

Every sandbox this tool creates is noEnv, has a TTL, is renamed
`orb-image-build-<purpose>-<ts>` and is stopped (never deleted) when done.
Contract: ~/work/paloma/boat/CONTRACT.md.
"""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
import uuid

API = 'https://boat.dev/api/v1'
REPO = Path(__file__).resolve().parent.parent
IMAGES = REPO / 'deploy' / 'managed-images'
RECIPE = IMAGES / 'orb-node-base.recipe.sh'
SMOKE = IMAGES / 'smoke-test.sh'
BOAT_DIR = Path.home() / 'work' / 'paloma' / 'boat'
ARTIFACTS = BOAT_DIR / 'artifacts'
LEDGER = BOAT_DIR / 'managed-image-ledger.json'
DEFAULT_REPO = Path.home() / 'work' / 'paloma' / 'wt-managed'
ALIAS = 'orb-node-base'
PREFIX = 'orb-image-build-'
STAGE = '/home/user/.orb-stage'
FLEET_HOST = 'root@188.40.69.160'  # ashur, read-only source of x86_64 tool builds
FLEET_TOOLS = ['agy', 'turbo-lean', 'lean-native', 'lean-native-core', 'research-governor', 'research-governor-core']
CERTIFIED_SEARCH_REPO = 'Th0rgal/certified-search'


def log(msg):
    print(f'[managed-image {time.strftime("%H:%M:%S")}] {msg}', flush=True)


def key():
    value = os.environ.get('BOAT_API_KEY', '')
    if not value:
        sys.exit('BOAT_API_KEY not set: eval "$(~/work/paloma/bin/bws-env BOAT_API_KEY)"')
    return value


class BoatError(RuntimeError):
    def __init__(self, status, body):
        super().__init__(f'boat API {status}: {str(body)[:500]}')
        self.status, self.body = status, body


def api(method, path, body=None, headers=None, timeout=120, retries=4):
    data = None if body is None else json.dumps(body).encode()
    for attempt in range(retries + 1):
        req = urllib.request.Request(API + path, data=data, method=method, headers={
            'Authorization': 'Bearer ' + key(), 'Content-Type': 'application/json',
            'User-Agent': 'orb-managed-image', **(headers or {})})
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                raw = resp.read()
                return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as err:
            raw = err.read().decode(errors='replace')
            try:
                parsed = json.loads(raw)
            except ValueError:
                parsed = raw
            retryable = err.code in (429, 502, 503, 504) or (err.code == 500 and method == 'GET') or (
                err.code == 409 and isinstance(parsed, dict)
                and (parsed.get('retryable') or parsed.get('error') in ('idempotency_in_progress', 'boat_starting')))
            # Never retry a command POST on 502: it may already be running.
            if path.endswith('/commands') and method == 'POST' and err.code == 502:
                retryable = False
            if retryable and attempt < retries:
                time.sleep(min(60, 5 * 2 ** attempt))
                continue
            raise BoatError(err.code, parsed) from None
        except (urllib.error.URLError, TimeoutError) as err:
            if attempt < retries and not (method == 'POST' and path.endswith('/commands')):
                time.sleep(5 * 2 ** attempt)
                continue
            raise BoatError(0, str(err)) from None


# ---------------------------------------------------------------- ledger

def ledger():
    try:
        return json.loads(LEDGER.read_text())
    except (OSError, ValueError):
        return {'sandboxes': [], 'snapshots': []}


def ledger_add(kind, item):
    data = ledger()
    data.setdefault(kind, []).append(item)
    LEDGER.parent.mkdir(parents=True, exist_ok=True)
    LEDGER.write_text(json.dumps(data, indent=2))


# ---------------------------------------------------------------- sandboxes

def create_sandbox(purpose, size, from_snapshot=None, ttl=7200):
    ts = time.strftime('%Y%m%d%H%M%S')
    name = f'{PREFIX}{purpose}-{ts}'
    body = {'type': size, 'ttlSeconds': ttl, 'noEnv': True, 'failFast': False}
    if from_snapshot:
        body['from'] = from_snapshot
    resp = api('POST', '/sandboxes', body, headers={'Idempotency-Key': f'orb-image-{purpose}-{uuid.uuid4()}'})
    sid = resp['sandbox']['id']
    ledger_add('sandboxes', {'id': sid, 'name': name, 'size': size, 'from': from_snapshot,
                             'created_at': datetime.datetime.utcnow().isoformat() + 'Z'})
    api('PATCH', f'/sandboxes/{sid}', {'name': name})
    log(f'created {size} sandbox {sid} ({name}){" from " + from_snapshot if from_snapshot else ""}')
    wait_ready(sid)
    return sid


def wait_ready(sid, limit=900):
    deadline = time.time() + limit
    while time.time() < deadline:
        state = api('GET', f'/sandboxes/{sid}')['sandbox']['state']
        if state in ('ready', 'idle', 'running'):
            # The agent may answer a few seconds after `ready`.
            for _ in range(30):
                try:
                    if run(sid, 'true', timeout=30, quiet=True)['exitCode'] == 0:
                        return
                except BoatError:
                    pass
                time.sleep(4)
            return
        if state in ('error', 'cancelled', 'archived', 'archiving'):
            raise RuntimeError(f'sandbox {sid} entered {state}')
        time.sleep(5)
    raise RuntimeError(f'sandbox {sid} not ready after {limit}s')


def stop_sandbox(sid):
    try:
        api('POST', f'/sandboxes/{sid}/stop', {})
        log(f'stop requested for {sid}')
    except BoatError as err:
        if 'archived' in str(err):
            return
        log(f'stop {sid}: {err}')


def run(sid, command, timeout=600, quiet=False):
    resp = api('POST', f'/sandboxes/{sid}/commands', {'command': command, 'timeoutSeconds': timeout},
               timeout=timeout + 60, retries=0)
    if not quiet:
        out = (resp.get('stdout') or '') + (resp.get('stderr') or '')
        if out.strip():
            print(out.rstrip()[-6000:], flush=True)
    return resp


def run_long(sid, command, limit=7200, label='job'):
    """Run detached; stream new output; return exit code."""
    resp = api('POST', f'/sandboxes/{sid}/commands', {'command': command, 'detached': True}, retries=0)
    pid = resp['processId']
    log(f'{label}: detached process {pid}')
    so = se = 0
    deadline = time.time() + limit
    while True:
        try:
            st = api('GET', f'/sandboxes/{sid}/commands/{pid}?stdoutOffset={so}&stderrOffset={se}')
        except BoatError as err:
            log(f'{label}: poll error {err}; retrying')
            time.sleep(15)
            continue
        for chunk in (st.get('stdout'), st.get('stderr')):
            if chunk:
                sys.stdout.write(chunk)
        sys.stdout.flush()
        so, se = st.get('stdoutNextOffset', so), st.get('stderrNextOffset', se)
        if st.get('more'):
            continue
        if not st.get('running') and st.get('status') != 'running':
            code = st.get('exitCode')
            log(f'{label}: exited {code} ({st.get("status")})')
            return code if code is not None else 255
        if time.time() > deadline:
            raise RuntimeError(f'{label} exceeded {limit}s')
        time.sleep(10)


def _signed(sid, kind, path):
    return api('POST', f'/sandboxes/{sid}/files/{kind}', {'path': path, 'ttlSeconds': 3600})['url']


def upload(sid, local, remote):
    local = Path(local)
    url = _signed(sid, 'upload-url', remote)
    size = local.stat().st_size
    for attempt in range(4):
        try:
            with local.open('rb') as fh:
                req = urllib.request.Request(url, data=fh, method='PUT', headers={
                    'Content-Length': str(size), 'Content-Type': 'application/octet-stream'})
                with urllib.request.urlopen(req, timeout=1800) as resp:
                    resp.read()
            log(f'uploaded {local.name} ({size >> 20} MiB) -> {remote}')
            return
        except (urllib.error.URLError, TimeoutError) as err:
            log(f'upload {local.name} failed ({type(err).__name__}); retry')
            time.sleep(10 * (attempt + 1))
    raise RuntimeError(f'upload of {local} failed')


def download(sid, remote, local):
    url = _signed(sid, 'download-url', remote)
    tmp = Path(str(local) + '.part')
    with urllib.request.urlopen(urllib.request.Request(url), timeout=1800) as resp, tmp.open('wb') as fh:
        while chunk := resp.read(1 << 20):
            fh.write(chunk)
    tmp.replace(local)
    log(f'downloaded {remote} -> {local} ({Path(local).stat().st_size >> 20} MiB)')


def usage(sid):
    try:
        u = api('GET', f'/sandboxes/{sid}/usage')
        return u.get('dollars'), u.get('seconds')
    except BoatError:
        return None, None


# ---------------------------------------------------------------- snapshots

def save_snapshot(sid, name):
    try:
        existing = api('GET', f'/named-snapshots/{name}').get('snapshot', {})
    except BoatError as err:
        existing = None if err.status == 404 else {}
    if existing and not (name == ALIAS or name.startswith(ALIAS + '-')):
        raise RuntimeError(f'refusing to overwrite foreign snapshot {name}')
    api('POST', '/named-snapshots', {'sandboxId': sid, 'name': name})
    ledger_add('snapshots', {'name': name, 'sandbox': sid, 'at': datetime.datetime.utcnow().isoformat() + 'Z'})
    log(f'saving named snapshot {name} from {sid}{" (replacing)" if existing else ""}')
    for _ in range(240):
        time.sleep(10)
        snap = api('GET', f'/named-snapshots/{name}').get('snapshot', {})
        status = snap.get('status')
        if status == 'ready' and snap.get('sourceSandboxId') in (None, sid):
            log(f'snapshot {name} ready')
            return snap
        if status == 'failed':
            raise RuntimeError(f'snapshot {name} failed: {snap}')
    raise RuntimeError(f'snapshot {name} still saving after 40 min')


# ---------------------------------------------------------------- inputs

def git(repo, *args):
    return subprocess.run(['git', '-C', str(repo), *args], check=True, capture_output=True, text=True).stdout.strip()


def resolve_source(source):
    """Return (repo, treeish, sha) for a git ref of the default repo or a worktree path."""
    path = Path(source).expanduser()
    if path.is_dir():
        repo = path
        dirty = git(repo, 'stash', 'create')  # includes uncommitted tracked changes, no side effects
        treeish = dirty or 'HEAD'
        sha = git(repo, 'rev-parse', treeish)
        if dirty:
            log(f'worktree {repo} has uncommitted changes; using stash commit {sha[:9]}')
    else:
        repo = DEFAULT_REPO
        sha = git(repo, 'rev-parse', source + '^{commit}')
        treeish = sha
    return repo, treeish, sha


def node_version_for(repo, treeish, sha):
    cargo = git(repo, 'show', f'{treeish}:Cargo.toml')
    version = next(line.split('"')[1] for line in cargo.splitlines() if line.startswith('version'))
    return f'{version}+{sha[:9]}'


BUILD_SCRIPT = r'''set -euo pipefail
exec > >(tee -a /home/user/build.log) 2>&1
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -qq
sudo apt-get install -y -qq --no-install-recommends build-essential pkg-config libssl-dev curl ca-certificates git >/dev/null
if [ ! -x "$HOME/.cargo/bin/cargo" ]; then
  curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain stable >/dev/null
fi
. "$HOME/.cargo/env"
rustc --version
rm -rf "$HOME/src" && mkdir -p "$HOME/src" && tar -xf "$HOME/src.tar" -C "$HOME/src"
cd "$HOME/src"
CARGO_TERM_PROGRESS_WHEN=never cargo build --release --locked --bin sandboxed-node --bin sandboxed-mcp 2>&1 | grep -vE '^\s+(Compiling|Downloaded|Downloading)' || { echo BUILD_FAILED; exit 1; }
install -m755 target/release/sandboxed-node "$HOME/sandboxed-node.out"
install -m755 target/release/sandboxed-mcp "$HOME/sandboxed-mcp.out"
sha256sum "$HOME/sandboxed-node.out" "$HOME/sandboxed-mcp.out"
file "$HOME/sandboxed-node.out" 2>/dev/null || true
echo BUILD_OK
'''


def mcp_path(node_binary):
    """sandboxed-mcp is cached next to sandboxed-node-<sha> as sandboxed-mcp-<sha>."""
    node_binary = Path(node_binary)
    return node_binary.with_name(node_binary.name.replace('sandboxed-node', 'sandboxed-mcp', 1))


def build_node_binary(source, created):
    repo, treeish, sha = resolve_source(source)
    cached = BOAT_DIR / f'sandboxed-node-{sha[:12]}'
    version = node_version_for(repo, treeish, sha)
    if cached.exists() and mcp_path(cached).exists():
        log(f'using cached binaries {cached} (+ {mcp_path(cached).name})')
        return cached, version, sha
    with tempfile.TemporaryDirectory() as tmp:
        tarball = Path(tmp) / 'src.tar'
        subprocess.run(['git', '-C', str(repo), 'archive', '--format=tar', '-o', str(tarball), treeish], check=True)
        sid = create_sandbox('node', 'large', ttl=7200)
        created.append(sid)
        try:
            upload(sid, tarball, '/home/user/src.tar')
            script = Path(tmp) / 'build.sh'
            script.write_text(BUILD_SCRIPT)
            upload(sid, script, '/home/user/build.sh')
            code = run_long(sid, 'bash /home/user/build.sh', limit=5400, label='cargo build')
            if code != 0:
                raise RuntimeError(f'node build failed (exit {code}); see /home/user/build.log in {sid}')
            download(sid, '/home/user/sandboxed-node.out', cached)
            download(sid, '/home/user/sandboxed-mcp.out', mcp_path(cached))
            cached.chmod(0o755)
            mcp_path(cached).chmod(0o755)
        finally:
            stop_sandbox(sid)
    return cached, version, sha


def fleet_tools():
    tarball = ARTIFACTS / 'fleet-tools-x86_64.tar.gz'
    meta = ARTIFACTS / 'fleet-tools.json'
    if not tarball.exists() or not meta.exists():
        ARTIFACTS.mkdir(parents=True, exist_ok=True)
        ssh = ['ssh', '-i', str(Path.home() / '.ssh' / 'paloma'), '-o', 'IdentitiesOnly=yes', FLEET_HOST]
        log(f'copying x86_64 tool builds from {FLEET_HOST} (read-only)')
        with tarball.open('wb') as fh:
            subprocess.run([*ssh, 'cd /usr/local/bin && tar czf - ' + ' '.join(FLEET_TOOLS)], stdout=fh, check=True)
        info = subprocess.run([*ssh, 'cd /usr/local/bin && for b in ' + ' '.join(FLEET_TOOLS) +
                               '; do echo "$b $(sha256sum $b | cut -c1-16) $(date -u -r $b +%FT%TZ) $(case $b in *-core) ;; *) timeout 10 ./$b --version </dev/null 2>/dev/null | head -1;; esac)"; done'],
                              capture_output=True, text=True, check=True).stdout
        tools = {}
        for line in info.splitlines():
            name, digest, mtime, *ver = line.split()
            tools[name] = {'source': f'fleet:{FLEET_HOST.split("@")[1]}:/usr/local/bin/{name}', 'sha256_16': digest,
                           'built_at': mtime, 'version': ' '.join(ver)}
        meta.write_text(json.dumps(tools, indent=2))
    return tarball, json.loads(meta.read_text())


def certified_search():
    env = {k: v for k, v in os.environ.items() if k not in ('GH_TOKEN', 'GITHUB_TOKEN')}
    # Pinned: must match CERTIFIED_SEARCH_COMMIT/SHA256 in the recipe.
    sha = recipe_pin('CERTIFIED_SEARCH_COMMIT')
    path = ARTIFACTS / f'certified-search-{sha[:7]}.tar.gz'
    if not path.exists():
        with path.open('wb') as fh:
            subprocess.run(['gh', 'api', f'repos/{CERTIFIED_SEARCH_REPO}/tarball/{sha}'], stdout=fh, check=True, env=env)
    return path, sha


def recipe_pin(name):
    for line in RECIPE.read_text().splitlines():
        if line.startswith(name + '='):
            return line.split('=', 1)[1].strip()
    raise KeyError(name)


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, 'rb') as fh:
        while chunk := fh.read(1 << 20):
            h.update(chunk)
    return h.hexdigest()


def recipe_sha():
    return hashlib.sha1(b'blob %d\0' % RECIPE.stat().st_size + RECIPE.read_bytes()).hexdigest()


# ---------------------------------------------------------------- steps

def smoke_in(sid):
    upload(sid, SMOKE, '/home/user/smoke-test.sh')
    code = run_long(sid, 'bash /home/user/smoke-test.sh; rc=$?; rm -f /home/user/smoke-test.sh; exit $rc',
                    limit=1800, label='smoke')
    return code == 0


def snapshot_names(sha):
    return [f'{ALIAS}-{time.strftime("%Y%m%d")}-{sha[:7]}', ALIAS]


def cmd_node_binary(args):
    created = []
    try:
        path, version, _ = build_node_binary(args.node_source, created)
        print(json.dumps({'binary': str(path), 'mcp_binary': str(mcp_path(path)), 'node_version': version}))
    finally:
        report(created)


def cmd_build(args):
    created = []
    try:
        binary, version, sha = build_node_binary(args.node_source, created)
        tools_tar, tools = fleet_tools()
        cs_tar, cs_sha = certified_search()
        tools['certified-search'] = {'source': f'github:{CERTIFIED_SEARCH_REPO}', 'commit': cs_sha,
                                     'note': 'CLI = research-governor (built from this repo, copied from fleet)'}
        if sha256_file(cs_tar) != recipe_pin('CERTIFIED_SEARCH_SHA256'):
            raise RuntimeError(f'{cs_tar} does not match the pinned CERTIFIED_SEARCH_SHA256')
        info = {'node_version': version, 'node_commit': sha, 'node_sha256': sha256_file(binary),
                'mcp_sha256': sha256_file(mcp_path(binary)),
                'recipe_sha': recipe_sha(), 'tools': tools}
        sid = create_sandbox('image', 'small', ttl=7200)
        created.append(sid)
        with tempfile.TemporaryDirectory() as tmp:
            bi = Path(tmp) / 'build-info.json'
            bi.write_text(json.dumps(info))
            for local, name in [(binary, 'sandboxed-node'), (mcp_path(binary), 'sandboxed-mcp'), (tools_tar, 'fleet-tools-x86_64.tar.gz'),
                                (cs_tar, 'certified-search.tar.gz'), (bi, 'build-info.json'),
                                (RECIPE, 'recipe.sh')]:
                upload(sid, local, f'{STAGE}/{name}')
        code = run_long(sid, f'cp {STAGE}/recipe.sh /tmp/orb-recipe.sh && bash /tmp/orb-recipe.sh; rc=$?; rm -f /tmp/orb-recipe.sh; exit $rc',
                        limit=3600, label='recipe')
        if code != 0:
            raise RuntimeError(f'recipe failed in {sid}')
        if not smoke_in(sid):
            raise RuntimeError(f'smoke failed in {sid}; alias not moved')
        run(sid, 'rm -rf ~/.bash_history ~/.cache/* /tmp/* 2>/dev/null; sudo journalctl --vacuum-time=1s >/dev/null 2>&1; sync', quiet=True)
        publish(sid, sha, created, verify_snapshot=not args.skip_verify)
    finally:
        report(created)


def cmd_refresh_node(args):
    created = []
    binary = Path(args.binary).expanduser()
    sha = binary.name.rsplit('-', 1)[-1] if binary.name.startswith('sandboxed-node-') else hashlib.sha1(binary.read_bytes()).hexdigest()
    version = args.node_version
    if not version:
        try:
            full = git(DEFAULT_REPO, 'rev-parse', sha + '^{commit}')
            version = node_version_for(DEFAULT_REPO, full, full)
        except subprocess.CalledProcessError:
            version = 'unknown+' + sha[:9]
    try:
        sid = create_sandbox('refresh', 'small', from_snapshot=args.base, ttl=3600)
        created.append(sid)
        mcp = mcp_path(binary)
        if not mcp.exists():
            raise RuntimeError(f'{mcp} missing: run node-binary first (it builds both binaries)')
        upload(sid, binary, f'{STAGE}/sandboxed-node')
        upload(sid, mcp, f'{STAGE}/sandboxed-mcp')
        script = f'''set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
need=()
for p in gh ripgrep fd-find clang llvm lld pkg-config libssl-dev; do
  dpkg -s "$p" >/dev/null 2>&1 || need+=("$p")
done
if [ "${{#need[@]}}" -gt 0 ]; then
  sudo apt-get update -qq || true
  sudo apt-get install -y -qq --no-install-recommends "${{need[@]}}"
fi
[ -x /usr/bin/fdfind ] && sudo ln -sfn /usr/bin/fdfind /opt/orb/bin/fd
echo '{sha256_file(binary)}  {STAGE}/sandboxed-node' | sha256sum -c -
echo '{sha256_file(mcp)}  {STAGE}/sandboxed-mcp' | sha256sum -c -
sudo install -m0755 -o root -g root {STAGE}/sandboxed-node /opt/orb/bin/sandboxed-node
sudo install -m0755 -o root -g root {STAGE}/sandboxed-mcp /opt/orb/bin/sandboxed-mcp
sudo ln -sfn /opt/orb/bin/sandboxed-mcp /usr/local/bin/sandboxed-mcp
sudo python3 -c 'import json,sys,datetime;p="/etc/orb/image-manifest.json";m=json.load(open(p));m["node_version"]=sys.argv[1];m["node_sha256"]=sys.argv[2];m["mcp_sha256"]=sys.argv[3];m["node_refreshed_at"]=datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ");open(p,"w").write(json.dumps(m,indent=2,sort_keys=True))' '{version}' '{sha256_file(binary)}' '{sha256_file(mcp)}'
rm -rf {STAGE}
jq .node_version /etc/orb/image-manifest.json'''
        if run(sid, script, timeout=300)['exitCode'] != 0:
            raise RuntimeError('binary swap failed')
        if not smoke_in(sid):
            raise RuntimeError(f'smoke failed in {sid}; alias not moved')
        publish(sid, sha, created, verify_snapshot=True)
    finally:
        report(created)


def publish(sid, sha, created, verify_snapshot=True):
    """Save the dated snapshot, smoke a fresh sandbox booted from it, then move the alias.

    Boat re-provisions parts of the disk at boot, so only a smoke run from the saved
    snapshot proves the image; the alias moves only after that passes."""
    dated, alias = snapshot_names(sha)
    save_snapshot(sid, dated)
    stop_sandbox(sid)
    if verify_snapshot:
        verify(dated, created)
    save_snapshot(sid, alias)


def verify(snapshot, created):
    sid = create_sandbox('smoke', 'small', from_snapshot=snapshot, ttl=3600)
    created.append(sid)
    try:
        ok = smoke_in(sid)
    finally:
        stop_sandbox(sid)
    if not ok:
        raise RuntimeError(f'smoke from snapshot {snapshot} failed')
    log(f'smoke from snapshot {snapshot} passed')


def cmd_smoke(args):
    created = []
    try:
        verify(args.snapshot, created)
    finally:
        report(created)


def our_sandboxes():
    out, cursor = [], None
    for _ in range(20):
        page = api('GET', '/sandboxes?limit=100' + (f'&cursor={cursor}' if cursor else ''))
        out += [s for s in page.get('sandboxes', []) if (s.get('name') or '').startswith(PREFIX)]
        cursor = (page.get('pageInfo') or {}).get('nextCursor')
        if not cursor:
            break
    return out


def cmd_list(_args):
    for s in our_sandboxes():
        dollars, seconds = usage(s['id'])
        print(f"sandbox {s['id']} {s['name']} {s['state']} ${dollars} {seconds}s")
    for s in api('GET', '/named-snapshots').get('snapshots', []):
        if s.get('name', '').startswith(ALIAS):
            print(f"snapshot {s['name']} {s.get('status')} from {s.get('sourceSandboxId')} {s.get('createdAt') or s.get('updatedAt') or ''}")


def cmd_stop_all_ours(_args):
    for s in our_sandboxes():
        if s['state'] not in ('archived', 'archiving', 'cancelled'):
            stop_sandbox(s['id'])


def report(created):
    for sid in created:
        stop_sandbox(sid)
    total = 0.0
    for sid in created:
        dollars, seconds = usage(sid)
        total += dollars or 0
        log(f'{sid}: ${dollars} ({seconds}s)')
    if created:
        log(f'total spend this run: ${total:.3f}')


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest='cmd', required=True)
    p = sub.add_parser('build')
    p.add_argument('--node-source', default=str(DEFAULT_REPO))
    p.add_argument('--skip-verify', action='store_true', help='skip the smoke run from the saved snapshot')
    p.set_defaults(fn=cmd_build)
    p = sub.add_parser('node-binary')
    p.add_argument('--node-source', default=str(DEFAULT_REPO))
    p.set_defaults(fn=cmd_node_binary)
    p = sub.add_parser('refresh-node')
    p.add_argument('--binary', required=True)
    p.add_argument('--node-version', help='e.g. 1.3.0+<sha>; default derived from the binary name')
    p.add_argument('--base', default=ALIAS)
    p.set_defaults(fn=cmd_refresh_node)
    p = sub.add_parser('smoke')
    p.add_argument('snapshot', nargs='?', default=ALIAS)
    p.set_defaults(fn=cmd_smoke)
    sub.add_parser('list').set_defaults(fn=cmd_list)
    sub.add_parser('stop-all-ours').set_defaults(fn=cmd_stop_all_ours)
    args = parser.parse_args()
    args.fn(args)


if __name__ == '__main__':
    main()
