"""Local authenticated Core wire fixtures; LEAN_PATH must contain the built Core module."""
import contextlib
import io
import json
import os
import sqlite3
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from unittest.mock import patch

PKG = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PKG / 'OrbDesktop'))
import live_transport as live


QUERY = (PKG.parent / 'OrbCore/OrbCore/current_bubble.sql').read_text()


def fixture():
    db = sqlite3.connect(':memory:', check_same_thread=False)
    db.executescript('''CREATE TABLE missions(id,title,status,owner_user_id,history_json);
      CREATE TABLE mission_shares(mission_id,user_id);
      CREATE TABLE mission_events(id INTEGER PRIMARY KEY,mission_id,seq INTEGER,sequence INTEGER,event_type,payload,metadata,content);
      INSERT INTO missions VALUES('a','a','active','owner','PRIVATE'),('b','b','active','other','PRIVATE');
      INSERT INTO mission_shares VALUES('b','owner');''')
    def add(seq, kind, mid, payload):
        db.execute('INSERT INTO mission_events VALUES(NULL,?,?,?,?,?,?,?)',
                   (mid, seq, seq, kind, json.dumps(payload), '{}', ''))
    add(1, 'text_delta', 'a', {'content': 'X' * (5 << 20)})
    add(2, 'assistant_message_canonical', 'a', {'content': 'canonical'})
    for n in range(3, 24):
        add(n, 'user_message', 'a', {'content': 'PRIVATE', 'queued': True})
    add(1, 'assistant_message', 'b', {'content': 'second\n\tλ🙂\x1e\x1f\n'})
    return db


class Delivery(unittest.TestCase):
    def run_wire(self, mode):
        paths, tokens = [], []
        db = fixture()
        events = '/current-bubble'
        a, b = ('/api/control/missions/' + m for m in ('a', 'b'))

        class Core(BaseHTTPRequestHandler):
            def do_GET(self):
                path = self.path
                paths.append(path)
                tokens.append(self.headers.get('Authorization'))
                if path == '/api/projects':
                    result = {'projects': [dict(slug='p', title='Project title', objective='Objective')]}
                elif path == '/api/control/missions?limit=200':
                    if mode == 'unavailable':
                        self.send_response(302)
                        self.send_header('Location', '/redirect')
                        self.end_headers()
                        return
                    if mode == 'idle-session' and paths.count(path) > 1:
                        self.send_error(401)
                        return
                    ids = ('a',) if mode == 'idle-share' and paths.count(path) > 2 else ('a','b')
                    if mode in ('page-two', 'idle-page-two') and paths.count(path) > 1:
                        ids = ['a'] + [f'new-{i}' for i in range(199)]
                    result = [dict(id=m, title=m, status='active') for m in ids]
                    if mode == 'null-retry' and paths.count(path) == 2:
                        result = None
                    if mode == 'null-retry' and paths.count(path) == 3:
                        self.send_error(503)
                        return
                elif path == '/api/machines':
                    result = []
                elif path.split('?')[0] in (a + events, b + events):
                    mid = path.split('/')[-2]
                    presence = path.endswith('?presence=1')
                    if mode == 'selected-session' and mid == 'b' and paths.count(path) > 1:
                        self.send_error(401)
                        return
                    if mid == 'a' and paths.count(path) > 1:
                        db.execute("UPDATE missions SET title='Updated', status='awaiting_user' WHERE id='a'")
                        db.execute("UPDATE mission_events SET payload=json_set(payload,'$.queued',json('false')) WHERE mission_id='a' AND seq=3")
                    if mid == 'b' and ((mode == 'revoke' and paths.count(path) > 1) or mode == 'idle-share'):
                        db.execute('DELETE FROM mission_shares')
                    row = db.execute(QUERY, {'1': mid, '2': '0', '3': 'owner', '4': '1' if presence else '0'}).fetchone()
                    if not row:
                        self.send_error(404)
                        return
                    result = dict(id=mid,title=row[0],status=row[1],text=row[2])
                    if mode == 'oversize' and mid == 'b' and paths.count(path) > 1:
                        result['text'] = 'x' * (5 << 20)
                else:
                    self.send_error(404)
                    return
                self.send_response(200)
                self.end_headers()
                try:
                    self.wfile.write(json.dumps(result).encode())
                except (BrokenPipeError, ConnectionResetError):
                    pass  # over-cap response deliberately not consumed

            def log_message(self, *_):
                pass

        with ThreadingHTTPServer(('127.0.0.1', 0), Core) as server, tempfile.TemporaryDirectory() as root:
            threading.Thread(target=server.serve_forever, daemon=True).start()
            try:
                for filename, token in [('connection.json', 'fixture'), ('rotated', 'changed')]:
                    (Path(root) / filename).write_text(json.dumps(dict(
                        api_url='', apiUrl=f'http://127.0.0.1:{server.server_port}', token=token)))
                subprocess.run(['lean', '-j', '1', '-M', '1024', '--run', 'tests/LiveDelivery.lean', mode],
                               cwd=PKG, env={**os.environ, 'ORB_STATE_DIR': root}, check=True, timeout=20)
                self.assertTrue(all(t == 'Bearer fixture' for t in tokens))
                self.assertNotIn('/redirect', paths)
                self.assertNotIn(a, paths)
                self.assertNotIn(b, paths)
                if mode in ('idle-share', 'idle-page-two'):
                    self.assertIn(b + events + '?presence=1', paths)
                    self.assertNotIn(b + events, paths)
                elif mode in ('page-two', 'null-retry'):
                    self.assertIn(b + events, paths)
                elif mode in ('idle-identity', 'before-open', 'unavailable', 'idle-session'):
                    self.assertFalse(any(p.startswith(a) or p.startswith(b) for p in paths))
                else:
                    # Scheduling can allow an extra valid sample on slow CI.
                    # Retirement, not an exact wall-clock request count, matters.
                    self.assertGreaterEqual(paths.count(a + events), 2)
                    self.assertGreaterEqual(paths.count(b + events), 2 if mode == 'revoke' else 1)
                    self.assertFalse(any(p.startswith(a) for p in paths[paths.index(b + events):]))
                    if mode == 'leave':
                        self.assertEqual(paths.count(b + events), 1)
            finally:
                server.shutdown()
                db.close()

    def test_revocation(self):
        self.run_wire('revoke')

    def test_idle_share_loss(self):
        self.run_wire('idle-share')

    def test_selected_page_two(self):
        self.run_wire('page-two')

    def test_unselected_page_two(self):
        self.run_wire('idle-page-two')

    def test_null_and_failed_refresh_retry(self):
        self.run_wire('null-retry')

    def test_idle_session_loss(self):
        self.run_wire('idle-session')

    def test_selected_session_loss(self):
        self.run_wire('selected-session')

    def test_oversized_bubble_preserves_roster(self):
        self.run_wire('oversize')

    def test_credential_rotation(self):
        self.run_wire('identity')

    def test_rotation_after_bootstrap(self):
        self.run_wire('before-open')

    def test_rotation_without_selection(self):
        self.run_wire('idle-identity')

    def test_navigation_stops_network_polling(self):
        self.run_wire('leave')

    def test_failed_bootstrap_and_redirect(self):
        self.run_wire('unavailable')

    def test_coalesces_before_ipc(self):
        class Connection:
            binding = 'bound'

            def check(self):
                pass

            def get(self, path, cap):
                return dict(id='a', title='Title', status='active', text='Public')

        out = io.StringIO()
        with patch.object(live, 'roster_rows', return_value=[('M','a','PRIVATE')]), patch.object(live, 'Connection', Connection), patch.object(live.time, 'sleep', side_effect=[None, KeyboardInterrupt]), contextlib.redirect_stdout(out):
            with self.assertRaises(KeyboardInterrupt):
                live.poll('a', 'bound', {'a'})
        self.assertEqual(out.getvalue(), 'B\tM:a\tTitle\tactive\tPublic\n')

    def test_rejects_foreign_projection(self):
        class Connection:
            def get(self, path, cap):
                return dict(id='b',title='b',status='active',text='foreign')
        with self.assertRaises(ValueError):
            live.projection(Connection(), 'a')

    def test_sql_bounds_current_text_and_scopes_reader(self):
        with contextlib.closing(fixture()) as db:
            db.execute("DELETE FROM mission_events WHERE event_type='assistant_message_canonical'")
            self.assertEqual(db.execute(QUERY, {'1':'a','2':'0','3':'owner','4':'0'}).fetchone()[2], 'X' * 65537)
            self.assertEqual(db.execute(QUERY, {'1':'a','2':'0','3':'owner','4':'1'}).fetchone()[2], '')
            self.assertIsNone(db.execute(QUERY, {'1':'a','2':'0','3':'other','4':'1'}).fetchone())


if __name__ == '__main__':
    unittest.main()
