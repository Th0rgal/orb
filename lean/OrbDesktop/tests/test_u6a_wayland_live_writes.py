"""Deterministic headless Wayland + mock Core live-writes verification (U6a).

Launches the compiled `orb-desktop-native` binary inside a private headless Sway
session against a local SQLite-backed mock Core HTTP server (no external `orb-core`
binary or network required). Exercises real Wayland keyboard (`wtype`) and
`zwp_input_method_v2` -> `zwp_text_input_v3` IME commits (`wayland_ime.py`) for:
  1. New Agent typing + IME/Unicode commit + Create (`POST /api/control/missions`)
  2. Mission Transcript typing + IME/Unicode commit + Send (`POST /api/control/message`)
  3. Stop running turn (`POST /api/control/missions/<id>/cancel`)
  4. Archive stopped mission (`POST /api/control/missions/<id>/status`)
  5. Mock Core restart + separate independent Core HTTP client read verifying the
     new mission ID, exact submitted IME/Unicode texts, stopped turn, and persisted
     archive state.

Run from the repo root or `lean/OrbDesktop`:
    python3 lean/OrbDesktop/tests/test_u6a_wayland_live_writes.py
"""
import contextlib
import json
import os
from pathlib import Path
import shutil
import signal
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TEST_DIR = Path(__file__).resolve().parent
PKG = TEST_DIR.parent
ROOT = PKG.parents[1]
sys.path.insert(0, str(TEST_DIR))

import wayland_ime
from wayland_pointer import Pointer

QUERY = (PKG.parent / 'OrbCore/OrbCore/current_bubble.sql').read_text()


def read_words_png(png_bytes: bytes, geometry: str):
    """Run tesseract TSV directly on a grim PNG crop (upscaling via Pillow if available)."""
    import csv
    import io
    data = png_bytes
    scale = 1
    try:
        from PIL import Image, ImageOps
        img = Image.open(io.BytesIO(png_bytes)).convert('L')
        img = ImageOps.autocontrast(img)
        img = img.resize((img.width * 3, img.height * 3), Image.Resampling.BICUBIC)
        buf = io.BytesIO()
        img.save(buf, format='PNG')
        data = buf.getvalue()
        scale = 3
    except ImportError:
        pass
    result = subprocess.check_output(
        ['tesseract', 'stdin', 'stdout', '--psm', '11', 'tsv'],
        input=data,
        stderr=subprocess.DEVNULL,
        text=False,
    )
    ox, oy = map(int, geometry.split(' ')[0].split(','))
    return [
        (
            r['text'].strip('.,:|…[]()').lower(),
            ox + (int(r['left']) + int(r['width']) // 2) // scale,
            oy + (int(r['top']) + int(r['height']) // 2) // scale,
        )
        for r in csv.DictReader(result.decode().splitlines(), delimiter='\t', quoting=csv.QUOTE_NONE)
        if r['text'].strip()
    ]


def wait(label, check, seconds=25):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        try:
            result = check()
            if result:
                return result
        except (ConnectionError, urllib.error.URLError, subprocess.CalledProcessError, OSError):
            pass
        time.sleep(0.15)
    raise TimeoutError(label)


@contextlib.contextmanager
def managed_process(args, env, cwd):
    child = subprocess.Popen(args, cwd=cwd, env=env, start_new_session=True)
    try:
        yield child
    finally:
        with contextlib.suppress(ProcessLookupError):
            os.killpg(child.pid, signal.SIGTERM)
        try:
            child.wait(3)
        except subprocess.TimeoutExpired:
            with contextlib.suppress(ProcessLookupError):
                os.killpg(child.pid, signal.SIGKILL)
            child.wait()


def start_mock_core(db_path: Path, token: str):
    conn = sqlite3.connect(db_path, check_same_thread=False)
    conn.executescript('''
        CREATE TABLE IF NOT EXISTS missions(
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            status TEXT NOT NULL,
            project TEXT NOT NULL DEFAULT '',
            backend TEXT NOT NULL DEFAULT 'codex',
            owner_user_id TEXT NOT NULL DEFAULT 'owner',
            history_json TEXT NOT NULL DEFAULT '[]',
            stopped_turns INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS mission_shares(
            mission_id TEXT NOT NULL,
            user_id TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS mission_events(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            mission_id TEXT NOT NULL,
            seq INTEGER NOT NULL,
            sequence INTEGER NOT NULL,
            event_type TEXT NOT NULL,
            payload TEXT NOT NULL,
            metadata TEXT NOT NULL DEFAULT '{}',
            content TEXT NOT NULL DEFAULT ''
        );
        CREATE TABLE IF NOT EXISTS seen_messages(
            client_message_id TEXT PRIMARY KEY,
            mission_id TEXT NOT NULL
        );
    ''')
    conn.commit()
    lock = threading.Lock()
    state = {'counter': 0}

    def next_seq(mid):
        row = conn.execute(
            'SELECT COALESCE(MAX(sequence), 0) FROM mission_events WHERE mission_id=?',
            (mid,),
        ).fetchone()
        return (row[0] or 0) + 1

    def add_event(mid, kind, content, extra=None):
        seq = next_seq(mid)
        payload = {'content': content, **(extra or {})}
        conn.execute(
            'INSERT INTO mission_events(mission_id,seq,sequence,event_type,payload,metadata,content) VALUES(?,?,?,?,?,?,?)',
            (mid, seq, seq, kind, json.dumps(payload), '{}', content),
        )
        conn.commit()
        return seq

    class Handler(BaseHTTPRequestHandler):
        def reply(self, body, code=200):
            self.send_response(code)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            try:
                self.wfile.write(json.dumps(body).encode())
            except (BrokenPipeError, ConnectionResetError):
                pass

        def read_json(self):
            length = int(self.headers.get('Content-Length') or '0')
            return json.loads(self.rfile.read(length)) if length else {}

        def do_GET(self):
            if self.headers.get('Authorization') != f'Bearer {token}':
                self.reply({'error': 'unauthorized'}, 401)
                return
            base_path = self.path.split('?')[0]
            with lock:
                if base_path == '/api/auth/me':
                    self.reply({'user': {'username': 'u6a-wayland'}})
                    return
                if base_path == '/api/projects':
                    self.reply({'projects': [{'slug': 'source', 'title': 'Source', 'objective': '', 'color': 'blue'}]})
                    return
                if base_path == '/api/machines':
                    self.reply([{'id': 'core', 'name': 'orb-core', 'state': 'online', 'status': 'online'}])
                    return
                if base_path == '/api/backends':
                    self.reply({'backends': [{'id': 'codex', 'name': 'Codex'}]})
                    return
                if base_path == '/api/providers/backend-models':
                    self.reply({'backends': {'codex': [{'value': 'gpt-6.2-astra', 'label': 'Astra'}]}})
                    return
                if base_path == '/api/model-routing/chains':
                    self.reply([])
                    return
                if base_path == '/api/control/inbox-state':
                    self.reply({'_versions': {}})
                    return
                if base_path == '/api/control/missions':
                    rows = conn.execute('SELECT id,title,status,project,backend,stopped_turns FROM missions').fetchall()
                    self.reply([
                        dict(id=r[0], title=r[1], status=r[2], project=r[3], backend=r[4], stopped_turns=r[5])
                        for r in rows
                    ])
                    return
                if base_path.startswith('/api/control/missions/'):
                    parts = base_path.removeprefix('/api/control/missions/').split('/')
                    mid = parts[0]
                    row = conn.execute(
                        'SELECT id,title,status,project,backend,stopped_turns FROM missions WHERE id=?',
                        (mid,),
                    ).fetchone()
                    if not row:
                        self.reply({'error': 'not_found'}, 404)
                        return
                    if len(parts) == 1:
                        self.reply(dict(
                            id=row[0], title=row[1], status=row[2], project=row[3], backend=row[4],
                            stopped_turns=row[5],
                            execution={'state': 'running' if row[2] == 'active' else 'idle'},
                        ))
                        return
                    sub = parts[1]
                    if sub == 'events':
                        evs = conn.execute(
                            'SELECT id,sequence,event_type,content FROM mission_events WHERE mission_id=? ORDER BY sequence ASC, id ASC',
                            (mid,),
                        ).fetchall()
                        self.reply([dict(id=e[0], mission_id=mid, sequence=e[1], event_type=e[2], content=e[3]) for e in evs])
                        return
                    if sub == 'open':
                        evs = conn.execute(
                            'SELECT id,sequence,event_type,content FROM mission_events WHERE mission_id=? ORDER BY sequence ASC, id ASC',
                            (mid,),
                        ).fetchall()
                        events = [dict(id=e[0], mission_id=mid, sequence=e[1], event_type=e[2], content=e[3]) for e in evs]
                        self.reply(dict(
                            protocol=1, mission=dict(id=mid), events=events, spine=[], queue=[],
                            max_seq=events[-1]['sequence'] if events else 0,
                            has_more=False, spine_has_more=False, spine_next_cursor=None,
                            next_cursor=None, page_max_seq=None, reset=False,
                        ))
                        return
                    if sub == 'current-bubble':
                        if row[2] == 'active' and not conn.execute(
                            "SELECT 1 FROM mission_events WHERE mission_id=? AND event_type='assistant_message'",
                            (mid,),
                        ).fetchone():
                            add_event(mid, 'assistant_message', 'Turn 1 reply', {'queued': False})
                            conn.execute("UPDATE missions SET status='awaiting_user' WHERE id=?", (mid,))
                            conn.commit()
                        user_count = conn.execute(
                            "SELECT COUNT(*) FROM mission_events WHERE mission_id=? AND event_type='user_message'",
                            (mid,),
                        ).fetchone()[0]
                        if row[2] == 'active' and user_count >= 2 and not conn.execute(
                            "SELECT 1 FROM mission_events WHERE mission_id=? AND event_type='text_delta'",
                            (mid,),
                        ).fetchone():
                            add_event(mid, 'text_delta', 'Turn 2 streaming...', {'queued': False})
                        qrow = conn.execute(QUERY, {'1': mid, '2': '0', '3': 'owner', '4': '0'}).fetchone()
                        if not qrow:
                            self.reply({'error': 'not_found'}, 404)
                            return
                        self.reply(dict(id=mid, title=qrow[0], status=qrow[1], text=qrow[2]))
                        return
                self.reply({'error': 'not_found'}, 404)

        def do_POST(self):
            if self.headers.get('Authorization') != f'Bearer {token}':
                self.reply({'error': 'unauthorized'}, 401)
                return
            data = self.read_json()
            with lock:
                if self.path == '/api/control/missions':
                    state['counter'] += 1
                    mid = f"m-wl-{state['counter']}"
                    prompt = data.get('prompt', '')
                    title = data.get('title') or 'New mission'
                    project = data.get('project') or ''
                    backend = data.get('backend') or 'codex'
                    conn.execute(
                        "INSERT INTO missions(id,title,status,project,backend) VALUES(?,?,'active',?,?)",
                        (mid, title, project, backend),
                    )
                    if prompt:
                        add_event(mid, 'user_message', prompt, {'queued': False})
                    self.reply(dict(
                        id=mid, title=title, status='active', project=project, backend=backend,
                        model_override=data.get('model_override') or '',
                        model_effort=data.get('model_effort') or '',
                        permission_mode=data.get('permission_mode') or 'supervised',
                    ))
                    return
                if self.path == '/api/control/message':
                    mid = data['mission_id']
                    cid = data['client_message_id']
                    content = data['content']
                    if not conn.execute('SELECT 1 FROM seen_messages WHERE client_message_id=?', (cid,)).fetchone():
                        conn.execute('INSERT INTO seen_messages VALUES(?,?)', (cid, mid))
                        add_event(mid, 'user_message', content, {'queued': False})
                        conn.execute("UPDATE missions SET status='active' WHERE id=?", (mid,))
                        conn.commit()
                    self.reply({'id': cid, 'message_accepted': True})
                    return
                if self.path.startswith('/api/control/missions/') and self.path.endswith('/cancel'):
                    mid = self.path.removeprefix('/api/control/missions/').removesuffix('/cancel')
                    conn.execute(
                        "UPDATE missions SET status='interrupted', stopped_turns=stopped_turns+1 WHERE id=?",
                        (mid,),
                    )
                    add_event(mid, 'turn_stopped', 'stopped by user', {'queued': False})
                    self.reply({'ok': True, 'status': 'interrupted'})
                    return
                if self.path.startswith('/api/control/missions/') and self.path.endswith('/status'):
                    mid = self.path.removeprefix('/api/control/missions/').removesuffix('/status')
                    row = conn.execute('SELECT status FROM missions WHERE id=?', (mid,)).fetchone()
                    if not row:
                        self.reply({'error': 'not_found'}, 404)
                        return
                    if data.get('status') == 'acknowledged' and row[0] == 'active':
                        self.reply({'error': 'mission_running'}, 409)
                        return
                    conn.execute('UPDATE missions SET status=? WHERE id=?', (data['status'], mid))
                    conn.commit()
                    self.reply({'ok': True, 'status': data['status']})
                    return
                self.reply({'error': 'not_found'}, 404)

        def log_message(self, *_):
            pass

    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, conn


def find_desktop_binary() -> Path:
    env_bin = os.environ.get('ORB_LEANUI_TEST_BINARY')
    if env_bin:
        return Path(env_bin).resolve(strict=True)
    for candidate in (
        PKG / '.lake/build/bin/orb-desktop-native',
        ROOT / 'target/native/orb-desktop-native',
        ROOT / 'target/release/orb-desktop-native',
    ):
        if candidate.is_file():
            return candidate
    raise FileNotFoundError('orb-desktop-native binary not found; set ORB_LEANUI_TEST_BINARY or build lean/OrbDesktop')


def run_wayland_e2e():
    for tool in ('sway', 'swaymsg', 'wtype', 'grim', 'tesseract'):
        if shutil.which(tool) is None:
            raise RuntimeError(f'Missing required graphical test tool: {tool}')
    binary = find_desktop_binary()
    token = 'u6a-wayland-token'
    typed_initial, ime_initial = 'Indigo U6a ', '日本語'
    typed_followup, ime_followup = 'Followup ', '漢字テスト'

    with tempfile.TemporaryDirectory(prefix='orb-u6a-wayland-') as tmp_str:
        tmp = Path(tmp_str)
        db_path = tmp / 'core.db'
        server1, db1 = start_mock_core(db_path, token)
        base1 = f'http://127.0.0.1:{server1.server_port}'

        def api(base, path):
            req = urllib.request.Request(
                base + path,
                headers={'Authorization': f'Bearer {token}', 'Accept': 'application/json'},
            )
            with urllib.request.urlopen(req, timeout=5) as resp:
                return json.load(resp)

        try:
            (tmp / 'connection.json').write_text(json.dumps({'api_url': base1, 'token': token}))
            config = tmp / 'sway.conf'
            config.write_text('output * mode 1000x700\ndefault_border none\nxwayland disable\n')
            graphical = dict(
                os.environ,
                XDG_RUNTIME_DIR=str(tmp),
                WLR_BACKENDS='headless',
                WLR_RENDERER='pixman',
                WLR_LIBINPUT_NO_DEVICES='1',
                ORB_STATE_DIR=str(tmp),
            )
            with contextlib.ExitStack() as stack:
                stack.enter_context(managed_process(['sway', '-c', str(config)], graphical, tmp))
                graphical['WAYLAND_DISPLAY'] = wait(
                    'private compositor',
                    lambda: next((p.name for p in tmp.glob('wayland-*') if p.is_socket()), None),
                )
                graphical['SWAYSOCK'] = str(wait('sway IPC', lambda: next(tmp.glob('sway-ipc.*.sock'), None)))

                def sway(*args):
                    return subprocess.check_output(['swaymsg', '-r', *args], env=graphical)

                def keys(*args):
                    subprocess.run(['wtype', '-s', '150', *args], check=True, env=graphical)

                def crop(geometry):
                    return subprocess.check_output(['grim', '-t', 'png', '-g', geometry, '-'], env=graphical)

                def widget(label, region):
                    return next(((x, y) for word, x, y in read_words_png(crop(region), region) if word == label), None)

                pointer = Pointer(graphical)
                stack.callback(pointer.close)
                stack.enter_context(managed_process(['wtype', '-k', 'Shift_L', '-s', '120000'], graphical, tmp))
                stack.enter_context(managed_process([str(binary)], graphical, ROOT))
                wait('orb-desktop window', lambda: b'"orb-desktop"' in sway('-t', 'get_tree'), 60)
                edit = stack.enter_context(wayland_ime.session(graphical))

                # Wait for live bootstrap to complete (project 'source' visible in sidebar).
                # New Agent composer is auto-focused on connect, so typing + IME commits work immediately!
                wait('live project roster', lambda: widget('source', '10,110 195x305'))
                keys(typed_initial)
                edit([(ime_initial, 0, 0)])
                keys('-k', 'Return')

                created = wait('created mission', lambda: api(base1, '/api/control/missions'))
                assert len(created) == 1, created
                mid = created[0]['id']
                path = f'/api/control/missions/{mid}'

                # Wait for Turn 1 reply to complete and transition to awaiting_user.
                wait('turn 1 completed', lambda: api(base1, path)['status'] == 'awaiting_user')
                time.sleep(1.5)

                # Composer stays focused on the created mission; type + IME commit follow-up and press Return.
                keys(typed_followup)
                edit([('漢字猫', 0, 0), ('テスト', len('猫'.encode()), 0)])
                keys('-k', 'Return')

                wait(
                    'follow-up accepted and active',
                    lambda: (
                        api(base1, path)['status'] == 'active'
                        and len([e for e in api(base1, path + '/events') if e['event_type'] == 'user_message']) == 2
                    ),
                )
                time.sleep(1.5)

                # Tab from composer (1) -> attach (3) -> Stop button (2) -> Return to Stop the running turn.
                keys('-k', 'Tab', '-k', 'Tab', '-k', 'Return')
                wait('turn stopped', lambda: api(base1, path)['status'] == 'interrupted')
                time.sleep(1.5)

                # Right-click the stopped mission row in the sidebar and click Archive in its context menu.
                sidebar_region = '10,110 195x305'
                mx, my = wait('stopped mission row in sidebar', lambda: widget('indigo', sidebar_region))
                pointer.click(mx, my, 'button3')
                menu_region = '0,75 420x480'
                ax, ay = wait('Archive menu item', lambda: widget('archive', menu_region))
                pointer.click(ax, ay)
                wait('mission archived', lambda: api(base1, path)['status'] == 'acknowledged')
        finally:
            server1.shutdown()
            server1.server_close()
            db1.close()

        # Restart mock Core on the same SQLite DB and verify via a SEPARATE independent Core HTTP client.
        server2, db2 = start_mock_core(db_path, token)
        base2 = f'http://127.0.0.1:{server2.server_port}'
        try:
            mission = api(base2, f'/api/control/missions/{mid}')
            events = api(base2, f'/api/control/missions/{mid}/events')
            user_messages = [e['content'] for e in events if e['event_type'] == 'user_message']
            stopped_events = [e for e in events if e['event_type'] == 'turn_stopped']

            assert mission['id'] == mid, mission
            assert mission['status'] == 'acknowledged', mission
            assert mission['stopped_turns'] == 1, mission
            assert user_messages == [typed_initial + ime_initial, typed_followup + ime_followup], user_messages
            assert len(stopped_events) == 1, stopped_events
            print(json.dumps(dict(
                id=mid,
                initial_exact=user_messages[0] == typed_initial + ime_initial,
                followup_exact=user_messages[1] == typed_followup + ime_followup,
                stopped_turns=mission['stopped_turns'],
                after_restart=mission['status'],
            ), ensure_ascii=False))
        finally:
            server2.shutdown()
            server2.server_close()
            db2.close()


if __name__ == '__main__':
    run_wayland_e2e()
