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
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from unittest.mock import Mock, call, patch

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
    def test_shared_mission_distinct_read_state(self):
        states = {u: {'_versions': {}} for u in ('alice', 'bob')}
        mission = dict(id='shared', title='Result', status='completed', updated_at='2026-01-01T00:00:00Z')

        class Core(BaseHTTPRequestHandler):
            def reply(self, body, code=200):
                self.send_response(code)
                self.end_headers()
                self.wfile.write(json.dumps(body).encode())

            def do_GET(self):
                if self.path == live.INBOX_PATH:
                    self.reply(states[self.headers['Authorization'].split()[1]])
                elif self.path == '/api/control/missions?all=true&limit=1000&offset=0':
                    self.reply([mission])
                elif self.path == '/api/projects':
                    self.reply({'projects': []})
                else:
                    self.reply([])

            def do_PUT(self):
                if self.path != live.INBOX_PATH + '/seen/shared':
                    self.send_error(404)
                    return
                state = states[self.headers['Authorization'].split()[1]]
                data = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                version = state['_versions'].get('seen:shared', 0)
                if version != data['expectedVersion']:
                    self.reply({}, 409)
                    return
                state.update({'seen:shared': data['stamp'], '_versions': {'seen:shared': version + 1}})
                self.reply({'ok': True})

            def log_message(self, *_):
                pass

        with ThreadingHTTPServer(('127.0.0.1', 0), Core) as server:
            threading.Thread(target=server.serve_forever, daemon=True).start()
            url = f'http://127.0.0.1:{server.server_port}'
            def rows():
                return [[str(v) for v in row[:4]] for row in live.inbox_snapshot(live.Connection(), [], '')
                        if row[0] == 'U']
            with patch.object(live, 'credentials', return_value=(url, 'alice')) as creds:
                alice = live.Connection().binding
                entry, = rows()
                self.assertEqual(entry, ['U', 'shared', '1767225600000', '0'])
                with patch.object(sys, 'stdin', io.StringIO('1767225600000 0')):
                    self.assertEqual(live.run_mutation(alice, 'inbox-read', 'shared'), 0)
                self.assertEqual(rows(), [])
                creds.return_value = (url, 'bob')
                self.assertEqual(rows(), [entry])
                self.assertEqual(live.run_mutation(alice, 'inbox-read', 'shared'), 1)
                self.assertEqual(states['bob'], {'_versions': {}})
                creds.return_value = (url, 'alice')
                mission['updated_at'] = '2026-01-01T00:01:00Z'
                self.assertEqual(rows(), [['U', 'shared', '1767225660000', '1']])
                with patch.object(sys, 'stdin', io.StringIO('1767225600000 0')):
                    self.assertEqual(live.run_mutation(alice, 'inbox-read', 'shared'), 1)
                self.assertEqual(len(rows()), 1)
            # Exercise the actual Lean bootstrap, rendered focus order and embedded writer.
            states['alice'] = {'_versions': {}}
            with tempfile.TemporaryDirectory() as root:
                for user, action in [('alice', 'read'), ('bob', 'open')]:
                    (Path(root) / 'connection.json').write_text(json.dumps(dict(api_url=url, token=user)))
                    subprocess.run(['lean', '--run', 'tests/LiveDelivery.lean', 'inbox', action],
                                   cwd=Path(__file__).resolve().parents[1], check=True, timeout=30,
                                   env={**os.environ, 'ORB_STATE_DIR': root})
                    self.assertEqual(states[user]['seen:shared'], 1767225660000)
            server.shutdown()

    def test_inbox_io_bound_and_paging(self):
        projects = [{'slug': str(i)} for i in range(7)]
        def summaries(n):
            return [dict(id=str(i), project=str(i % 7), status='completed') for i in range(n)]
        for n in (6, 881, 1001):
            pages = summaries(n)
            calls = []
            class Core:
                def get(self, path, cap, *, deadline):
                    calls.append((path, deadline))
                    if path == live.INBOX_PATH:
                        return {}
                    offset = (len(calls) // 2 - 1) * 1000
                    expected_path = f'/api/control/missions?all=true&limit=1000&offset={offset}'
                    assert path == expected_path
                    return pages[offset:offset + 1000]
            scan = live.InboxScan()
            self.assertEqual(live.INBOX_READ_SECONDS, 4)
            with patch.object(live.time, 'monotonic', side_effect=[0, 0, 1.5] * 2):
                result = live.inbox_snapshot(Core(), projects, '', scan)
                self.assertEqual([budget for _, budget in calls], [4, 2.5])
                if n == 1001:
                    self.assertEqual(result, [('I', 'refreshing')])
                    result = live.inbox_snapshot(Core(), projects, '', scan)
            self.assertEqual(sum(r[0] == 'U' for r in result), n)
            self.assertEqual(scan.offset, 0)
            self.assertFalse(scan.rows)

    def test_slow_or_oversize_page_retries_same_offset_on_next_refresh(self):
        scan = live.InboxScan()
        with patch.object(live, 'Connection') as client:
            c = client.return_value
            c.get.side_effect = [{}, live.ResponseTooLarge(), {}, []]
            with self.assertRaises(live.ResponseTooLarge):
                live.inbox_snapshot(c, [], '', scan)
            self.assertEqual(c.get.call_count, 2)
            self.assertEqual(live.inbox_snapshot(c, [], '', scan), [('I', 'enabled')])
            self.assertEqual(c.get.call_args.args[0], '/api/control/missions?all=true&limit=500&offset=0')

    def test_slow_inbox_http_response_respects_shared_deadline(self):
        entered = threading.Event()
        release = threading.Event()
        class Core(BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(200)
                self.end_headers()
                if self.path == live.INBOX_PATH:
                    self.wfile.write(b'{}')
                else:
                    entered.set()
                    release.wait(3)
            def log_message(self, *_):
                pass
        with ThreadingHTTPServer(('127.0.0.1', 0), Core) as server:
            threading.Thread(target=server.serve_forever, daemon=True).start()
            creds = (f'http://127.0.0.1:{server.server_port}', 'fixture')
            try:
                with patch.object(live, 'credentials', return_value=creds), patch.object(live, 'INBOX_READ_SECONDS', 0.4):
                    start = time.monotonic()
                    with self.assertRaises(TimeoutError):
                        live.inbox_snapshot(live.Connection(), [], '')
                    self.assertTrue(entered.is_set())
                    self.assertLess(time.monotonic() - start, 1.5)
            finally:
                release.set()
                server.shutdown()

    def test_inbox_deadline_expires_before_second_get(self):
        with patch.object(live, 'Connection') as client, patch.object(
                live.time, 'monotonic', side_effect=[100, 100, 104]):
            client.return_value.get.return_value = {}
            with self.assertRaises(TimeoutError):
                live.inbox_snapshot(client.return_value, [], '')
            client.return_value.get.assert_called_once()

    def test_inbox_preferences_response_time_and_order(self):
        base = dict(status='completed', updated_at='2026-01-01T00:00:00Z')
        missions = [dict(base, id='ready'), dict(base, id='question', status='waiting_user'),
                    dict(base, id='worker', parent_mission_id='ready'),
                    dict(base, id='later', last_output_at='2026-01-01T00:01:00Z'),
                    dict(base, id='viewed', first_viewed_at=base['updated_at'])]
        def ids(state):
            return [row[1] for row in live.inbox_rows(missions, state) if row[0] == 'U']
        self.assertEqual(ids({}), ['question', 'later', 'ready'])
        self.assertIn('worker', ids({'preferences': {'includeAutonomous': True}}))
        self.assertIn('viewed', ids({'seen:viewed': -1767225600000}))
        self.assertEqual(ids({'preferences': {'inboxEnabled': False}}), [])

    def test_bootstrap_recovers_after_initial_timeout(self):
        snapshot = [('C', 'binding'), ('P', 'source', 'Source', '')]
        with patch.object(live, 'Connection') as connection, patch.object(
                live, 'roster_rows', side_effect=[TimeoutError(), snapshot]) as read, patch.object(
                live.time, 'sleep'), contextlib.redirect_stdout(io.StringIO()) as output:
            live.roster()
        self.assertEqual(output.getvalue().splitlines(), ['C\tbinding', 'P\tsource\tSource\t'])
        self.assertEqual(read.call_count, 2)
        for call in read.call_args_list:
            self.assertEqual(call.args, (connection.return_value,))
            self.assertEqual(call.kwargs, {'include_archived': True})

    def test_bootstrap_rejects_expired_login_without_retry(self):
        denied = live.urllib.error.HTTPError('http://localhost', 401, 'Unauthorized', {}, None)
        self.addCleanup(denied.close)
        with patch.object(live, 'Connection'), patch.object(
                live, 'roster_rows', side_effect=denied) as read, self.assertRaises(live.urllib.error.HTTPError):
            live.roster()
        read.assert_called_once()

    def test_launchable_remote_nodes_are_independent_of_personal_vms(self):
        def node(ident, **fields):
            return {'id': ident, 'status': 'online', **fields}
        fleet = {'enabled': True, 'remote_launch': {'typed': True, 'harnesses': ['codex']}, 'nodes': [
            node('uruk', display_name='Uruk'), node('core'), node('admin', labels=['admin-only']),
            node('maintenance', cordoned=True), node('down', status='offline'),
            node('quarantined', quarantined_harnesses=['codex']),
            node('dgx-spark-admin', cordoned=True, labels=['manual-only', 'administration'])]}
        with patch.object(live, 'Connection') as conn, contextlib.redirect_stdout(io.StringIO()) as output:
            c = conn.return_value
            c.binding = 'ben'
            c.request.return_value = fleet
            live.launch_machines('thomas', 'admin', 'codex')
            c.request.assert_not_called()
            live.launch_machines('ben', 'member', 'codex')
            c.request.assert_called_once_with('/api/remote-nodes', deadline=15)
            c.check.assert_called_once()
        self.assertEqual(output.getvalue().splitlines(), ['machines', 'R\turuk\tUruk'])
        permitted = [r[1] for r in live.launch_machine_rows(fleet, True, 'codex')]
        self.assertEqual(permitted, ['uruk', 'admin', 'dgx-spark-admin'])
        self.assertEqual(list(live.launch_machine_rows({**fleet, 'remote_launch': {}}, True, '')), [])

    def test_picker_uses_the_harness_and_proxy_capabilities_reported_by_core(self):
        fleet = {'enabled': True, 'nodes': [{'id': 'uruk', 'status': 'online'}],
                 'remote_launch': {'typed': True, 'harnesses': ['antigravity', 'codex'],
                                   'requires_proxy_harnesses': ['codex'], 'proxy_url_configured': False}}
        def rows(harness):
            return list(live.launch_machine_rows(fleet, False, harness))
        self.assertEqual(rows('opencode'), [])
        self.assertEqual(rows('codex'), [])
        self.assertEqual(rows('antigravity'), [('R', 'uruk', 'uruk')])
        self.assertEqual(rows(''), [('R', 'uruk', 'uruk')])
        fleet['remote_launch']['proxy_url_configured'] = True
        self.assertEqual(rows('codex'), [('R', 'uruk', 'uruk')])

    def test_provider_inventory_projects_only_the_current_users_display_fields(self):
        accounts = [{'id': 'test-member', 'name': 'Gemini', 'label': 'Work', 'provider_type_name': 'Google',
                     'enabled': True, 'user_enabled': False, 'account_email': 'private@example.test',
                     'credential': 'PRIVATE'}, {'id': 'second', 'name': 'Cloud', 'provider_type': 'custom',
                     'enabled': False, 'user_enabled': True}]
        with patch.object(live, 'Connection') as conn, contextlib.redirect_stdout(io.StringIO()) as output:
            conn.return_value.binding = 'ben'
            conn.return_value.get.return_value = {'providers': accounts}
            live.provider_inventory('thomas')
            conn.return_value.get.assert_not_called()
            live.provider_inventory('ben')
        self.assertEqual(output.getvalue().splitlines(), [
            'accounts', 'A\ttest-member\tWork\tGoogle\t0\t1\t', 'A\tsecond\tCloud\tcustom\t1\t0\tcustom'])

    def test_account_connection_rechecks_both_settings_after_one_failed_write(self):
        direct = {'can_configure': True, 'countries': ['NL', 'FI', 'NL'], 'mode': 'direct', 'status': 'direct'}
        with patch.object(live, 'Connection') as conn, contextlib.redirect_stdout(io.StringIO()) as output:
            c = conn.return_value
            c.binding = 'ben'
            c.request.side_effect = TimeoutError()
            c.get.side_effect = [direct, {'allowed': False}]
            live.account_routes('ben', 'A/B', 'antigravity', 'routers', 'on')
            c.request.assert_called_once_with('/api/ai/providers/A%2FB/alternative-routers',
                                              body={'allowed': True}, method='PUT')
            self.assertEqual([call.args[0] for call in c.get.call_args_list],
                             ['/api/ai/providers/A%2FB/vpn', '/api/ai/providers/A%2FB/alternative-routers'])
        rows = output.getvalue().splitlines()
        self.assertEqual(rows[0], 'unconfirmed')
        self.assertIn('D\t\t\tDirect\tSelected', rows)
        self.assertEqual(rows.count('D\tvpn\tNL\tAirVPN · NL\t'), 1)
        self.assertIn('D\trouters\ton\tAlternative routers\tOff · Native Antigravity only', rows)

    def test_account_settings_keep_independent_sections_and_skip_unauthorized_controls(self):
        read_only = {'can_configure': False, 'countries': ['NL'], 'mode': 'vpn', 'country': 'NL',
                     'status': 'verified', 'server': 'fixture', 'exits': ['192.0.2.1']}
        with patch.object(live, 'Connection') as conn:
            c = conn.return_value
            c.get.side_effect = [read_only, live.urllib.error.HTTPError('x', 503, 'Unavailable', {}, None)]
            rows = list(live.account_route_rows(c, 'ok', True))
            self.assertEqual(rows, [('', '', 'Account connection', 'Verified exit · NL · fixture · 192.0.2.1'),
                                    ('refresh', '', 'Alternative routers', 'Could not load. Retry')])
            c.get.side_effect = [live.urllib.error.HTTPError('x', code, 'Unavailable', {}, None) for code in (403, 404)]
            self.assertEqual(list(live.account_route_rows(c, 'shared', True)), [])
            c.binding = 'thomas'
            c.get.reset_mock()
            live.account_routes('ben', 'ok', 'antigravity', 'vpn', 'FI')
            c.get.assert_not_called()
            c.request.assert_not_called()

    def test_blocked_selected_country_can_retry_and_direct_requires_confirmation(self):
        blocked = {'can_configure': True, 'countries': ['FI'], 'mode': 'vpn', 'country': 'NL',
                   'status': 'blocked', 'message': 'Tunnel unavailable.'}
        rows = list(live.vpn_options(blocked))
        self.assertIn(('vpn', 'NL', 'AirVPN · NL', 'Retry verification'), rows)
        self.assertIn(('vpn', '', 'Direct', ''), rows)
        with patch.object(live, 'Connection') as conn:
            c = conn.return_value
            c.request.return_value = blocked
            with self.assertRaises(ValueError):
                live.save_account_route(c, 'account', 'vpn', '')
            c.request.assert_called_once_with('/api/ai/providers/account/vpn', body={'mode': 'direct'}, method='PUT', deadline=120)
            c.request.reset_mock()
            with self.assertRaises(ValueError):
                live.save_account_route(c, 'account', 'vpn', 'NL/FI')
            c.request.assert_not_called()

    def test_two_sessions_read_the_same_shared_route_without_enabling_the_account(self):
        with patch.object(live, 'Connection') as conn, contextlib.redirect_stdout(io.StringIO()) as output:
            c = conn.return_value
            shared = dict(mode='vpn', country='NL', status='verified', server='fixture',
                          exits=['192.0.2.35'], countries=['NL'], can_configure=True)
            c.binding = 'ben'
            c.request.return_value = shared
            c.get.return_value = shared
            live.account_routes('ben', 'shared/account', 'openai', 'vpn', 'NL')
            c.request.assert_called_once_with('/api/ai/providers/shared%2Faccount/vpn',
                body={'mode': 'vpn', 'country': 'NL'}, method='PUT', deadline=120)
            saved = output.getvalue()
            self.assertIn('Verified exit · NL · fixture · 192.0.2.35', saved)
            c.binding = 'thomas'
            live.account_routes('thomas', 'shared/account', 'openai', '', '')
            self.assertEqual(output.getvalue(), saved * 2)
            self.assertEqual(c.request.call_count, 1)

    def test_provider_toggle_requires_the_selected_account_receipt(self):
        with patch.object(live, 'Connection') as conn:
            conn.return_value.binding = 'ben'
            request = conn.return_value.request
            request.return_value = {'id': 'other', 'user_enabled': False}
            with self.assertRaises(ValueError):
                live.mutate('ben', 'skip-provider', 'gemini-work')
            request.return_value = {'id': 'gemini-work', 'user_enabled': False}
            live.mutate('ben', 'skip-provider', 'gemini-work')
            request.assert_called_with('/api/ai/providers/gemini-work/preference',
                                       body={'enabled': False}, method='PUT')

    def test_native_catalog_probes_the_selected_destination_and_rechecks_identity(self):
        with patch.object(live, 'Connection') as conn:
            c = conn.return_value
            c.binding = 'ben'
            c.request.return_value = [['gemini-4-neon', 'Neon']]
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                live.native_models('ben', 'node a')
            c.request.assert_called_once_with('/api/providers/antigravity-models?node_id=node+a', deadline=20)
            self.assertEqual(out.getvalue().splitlines(), ['native-models', 'N\tgemini-4-neon\tNeon'])
            c.request.return_value = []
            c.check.side_effect = ValueError('connection changed')
            out = io.StringIO()
            with contextlib.redirect_stdout(out), self.assertRaises(ValueError):
                live.native_models('ben', 'core')
            self.assertEqual(out.getvalue(), '')
            c.request.assert_called_with('/api/providers/antigravity-models', deadline=20)
            c.check.side_effect = None
            for bad in ({}, ['xx'], [['x\ty', 'name']]):
                c.request.return_value = bad
                with contextlib.redirect_stdout(out), self.assertRaises(ValueError):
                    live.native_models('ben', 'core')
            self.assertEqual(out.getvalue(), '')

    def test_catalog_recovers_without_reopening_the_window(self):
        denied = live.urllib.error.HTTPError('http://localhost', 503, 'Unavailable', {}, None)
        rows = [('H', 'antigravity', 'Antigravity', 'gemini-4-neon', 'Neon')]
        with patch.object(live, 'Connection') as conn, patch.object(
                live, 'catalog_rows', side_effect=[denied, TimeoutError(), rows]), patch.object(
                live.time, 'sleep') as sleep, contextlib.redirect_stdout(io.StringIO()) as output:
            conn.return_value.binding = 'binding'
            live.catalog('binding', {})
        self.assertEqual(output.getvalue().splitlines(), ['\t'.join(rows[0])])
        self.assertEqual([call.args[0] for call in sleep.call_args_list], [1, 2])

    def test_stop_appears_when_the_roster_and_bubble_both_report_active(self):
        self.run_wire('start-running')

    def test_recovery_reports_changed_reason_without_server_details(self):
        denied = live.urllib.error.HTTPError('http://localhost', 401, 'private response', {}, None)
        with patch.object(live, 'roster', side_effect=[FileNotFoundError(), denied]), patch.object(
                live.time, 'sleep') as sleep, contextlib.redirect_stdout(io.StringIO()) as out:
            live.recover_roster('missing')
        sleep.assert_called_once_with(1)
        self.assertEqual(out.getvalue(), 'F\tsignin\n')

    def test_invalid_saved_session_is_reported_without_echoing_contents(self):
        with tempfile.TemporaryDirectory() as home, patch.dict(os.environ, ORB_STATE_DIR=home):
            Path(home, 'connection.json').write_text('["private"]')
            with contextlib.redirect_stdout(io.StringIO()) as out:
                live.recover_roster('')
            self.assertEqual(out.getvalue(), 'F\tinvalid\n')

    def test_denied_account_has_its_own_window_state(self):
        self.run_wire('denied')

    def test_saved_session_recovers_inside_the_window(self):
        self.run_wire('reconnect')

    def run_wire(self, mode):
        paths, tokens = [], []
        db = fixture()
        project_started = threading.Event()
        release_project = threading.Event()
        events = '/current-bubble'
        a, b = ('/api/control/missions/' + m for m in ('a', 'b'))

        class Core(BaseHTTPRequestHandler):
            def do_GET(self):
                path = self.path
                paths.append(path)
                tokens.append(self.headers.get('Authorization'))
                if mode == 'denied':
                    self.send_error(403)
                    return
                if mode == 'reconnect' and tokens[-1] == 'Bearer fixture':
                    self.send_error(401)
                    return
                if path == '/api/projects':
                    result = {'projects': [dict(slug='p', title='Project title', objective='Objective', color='blue')]}
                elif path == '/api/control/missions?limit=200&include_ancestors=true':
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
                    if mode == 'start-running' and paths.count(path) == 1:
                        result[-1]['status'] = 'pending'
                    if mode == 'null-retry' and paths.count(path) == 2:
                        result = None
                    if mode == 'null-retry' and paths.count(path) == 3:
                        self.send_error(503)
                        return
                elif path.startswith('/api/control/missions?all=true&limit='):
                    result = []
                elif path == live.INBOX_PATH:
                    result = {'_versions': {}}
                elif mode == 'project-lag' and path.startswith('/api/control/missions?project=p&'):
                    project_started.set()
                    release_project.wait(8)
                    result = []
                elif path.startswith('/api/control/missions?project=p&') or path == '/api/machines':
                    result = []
                elif path.split('?')[0] in (a + events, b + events):
                    mid = path.split('/')[-2]
                    presence = path.endswith('?presence=1')
                    if mode == 'project-lag' and mid == 'b':
                        project_started.wait(3)
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
                if mode == 'reconnect':
                    first = tokens.index('Bearer changed')
                    self.assertGreater(first, 0)
                    self.assertTrue(all(t == 'Bearer changed' for t in tokens[first:]))
                    return
                self.assertTrue(all(t == 'Bearer fixture' for t in tokens))
                self.assertNotIn('/redirect', paths)
                self.assertNotIn(a, paths)
                self.assertNotIn(b, paths)
                if mode in ('idle-share', 'idle-page-two'):
                    self.assertIn(b + events + '?presence=1', paths)
                    self.assertNotIn(b + events, paths)
                elif mode in ('page-two', 'null-retry', 'start-running', 'project-lag'):
                    self.assertIn(b + events, paths)
                elif mode in ('idle-identity', 'before-open', 'unavailable', 'denied', 'idle-session'):
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
                release_project.set()
                server.shutdown()
                db.close()

    def test_conversation_updates_while_expanded_project_read_is_pending(self):
        self.run_wire('project-lag')

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

    def test_model_successor_requires_the_same_provider(self):
        rules = json.loads((PKG.parents[1]/'orb/src/modelSuccessors.json').read_text())
        models = [{'value':'openai/gpt-6-sol', 'provider_id':'local'},
                  {'value':'openai/gpt-6.2-sol', 'provider_id':'other'}]
        self.assertEqual(list(live.visible_model_options('opencode', models, rules)), models)
        models[1]['provider_id'] = 'local'
        self.assertEqual(list(live.visible_model_options('opencode', models, rules)), models[1:])

    def test_goal_refusals_keep_server_text_out_of_the_notice(self):
        for action, reason, expected in [
                ('create', 'remote_goal_unsupported: detail', 3),
                ('send', 'remote_goal_followup_unsupported: detail', 4),
                ('create', 'unrelated error', 1),
                ('rename', 'remote_goal_unsupported: detail', 1)]:
            body = io.BytesIO(json.dumps({'error': reason}).encode())
            error = live.urllib.error.HTTPError('http://localhost', 400, '', {}, body)
            with self.subTest(action=action, reason=reason), patch.object(live, 'mutate', side_effect=error):
                self.assertEqual(live.run_mutation('binding', action, 'm'), expected)

    def test_folder_browser_uses_selected_machine_and_preserves_absolute_paths(self):
        for machine, route in [('core', '/api'), ('uruk', '/api/remote-nodes/uruk')]:
            with self.subTest(machine=machine), patch.object(live, 'Connection') as factory:
                conn = factory.return_value
                conn.binding = 'bound'
                conn.request.return_value = [
                    dict(kind='file', path='/work/a.txt', name='a.txt'),
                    dict(kind='dir', path='/work/My Folder', name='My Folder')]
                output = io.StringIO()
                with contextlib.redirect_stdout(output):
                    live.list_directories('bound', machine, '/work/a & b')
                conn.request.assert_called_once_with(route + '/fs/list?path=%2Fwork%2Fa+%26+b', deadline=18)
                self.assertEqual(output.getvalue().splitlines(), ['directories', 'D\t/work/My Folder\tMy Folder'])

    def test_new_agent_sends_the_first_prompt_in_the_create_request(self):
        prompt = 'First line\tcontains a tab.\nSecond line.'
        directory = '/home/ben/work/Project With Spaces'
        payload = directory + '\0' + '\t'.join(['core', 'codex', 'model', '', 'supervised', 'now', prompt])
        with patch.object(live, 'Connection') as factory, patch.object(live.sys, 'stdin') as stdin:
            stdin.buffer = io.BytesIO(payload.encode())
            connection = factory.return_value
            connection.binding = 'bound'
            connection.request.return_value = dict(id='new-agent', title='First line', status='active')
            with contextlib.redirect_stdout(io.StringIO()):
                live.mutate('bound', 'create', '')
            connection.request.assert_called_once()
            request = connection.request.call_args
            self.assertEqual(request.args, ('/api/control/missions',))
            self.assertEqual(request.kwargs['body']['prompt'], prompt)
            self.assertEqual(request.kwargs['body']['project'], 'now')
            self.assertEqual(request.kwargs['body']['working_directory'], directory)
            self.assertNotIn('remote_node_id', request.kwargs['body'])

    def test_restore_clears_archive_tag_without_changing_completed_work(self):
        path = '/api/control/missions/worker'
        c = Mock()
        c.get.return_value = dict(id='worker', status='completed', tags=['archived'])
        live.change_status(c, 'restore', 'worker', 'key')
        self.assertEqual(c.request.call_args_list, [call(path + '/archive', body={'archived': False}, key='key-tag')])
        c.reset_mock()
        c.get.return_value['status'] = 'acknowledged'
        live.change_status(c, 'restore', 'worker', 'key')
        self.assertEqual(c.request.call_args_list, [
            call(path + '/archive', body={'archived': False}, key='key-tag'),
            call(path + '/status', body={'status': 'paused'}, key='key')])

    def test_expanded_project_restores_older_active_worker_and_its_controller(self):
        query = '/api/control/missions?project=p&limit=2'
        def row(mid, status, **fields):
            return dict(id=mid, project='p', status=status, **fields)
        old = row('old', 'completed')
        child = row('child', 'active', parent_mission_id='controller')
        history = [row('new', 'completed'), row('archived', 'acknowledged')]
        pages = {live.INBOX_PATH: {}, query + '&all=true': history, query: [history[0], old],
                 query + '&offset=2': [child, row('side', 'active', tags=['btw-parent:child'])],
                 query + '&offset=4': [], '/api/control/missions/controller?include_history=false': row('controller', 'completed'),
                 '/api/projects': {'projects': [{'slug': 'p'}]}, '/api/machines': [],
                 '/api/control/missions?limit=200&include_ancestors=true': [old]}
        connection = type('Fixture', (), {'binding': 'bound', 'check': lambda _: None, 'get': lambda _, path: pages[path]})()
        rules = json.loads((PKG.parents[1] / 'orb/src/projectHistoryRules.json').read_text())
        rules['pageSize'] = 2
        initial = live.roster_rows(connection)
        self.assertEqual([r[1] for r in initial if r[0] == 'M'], ['old'])
        loaded = live.roster_rows(connection, expanded=['p'], rules=rules)
        self.assertIn(('G', 'p', 'archived', 'child', 'controller', 'new'), loaded)
        self.assertIn('old', [r[1] for r in loaded if r[0] == 'M'])
        pages[query + '&offset=2'] = None
        with self.assertRaises(ValueError):
            live.roster_rows(connection, expanded=['p'], rules=rules)

    def test_child_precedes_parent_in_live_roster(self):
        child = dict(id='child', folder='notes/today', parent_mission_id='launch',
                     callback_parent_mission_id='callback', tags=['fork-of:source', 'archived'],
                     superseded_by_mission_id='next')
        pages = {live.INBOX_PATH: {}, '/api/projects': {'projects': []}, '/api/machines': [],
                 '/api/control/missions?limit=200&include_ancestors=true': [child]}
        connection = type('Fixture', (), {'binding': 'bound', 'check': lambda _: None,
                                          'get': lambda _, path: pages[path]})()
        for missions in ([child], [child, dict(id='launch')]):
            pages['/api/control/missions?limit=200&include_ancestors=true'] = missions
            projected = next(row for row in live.roster_rows(connection) if row[0] == 'M')
            self.assertEqual(projected[16:], ('notes/today', 'launch', 'callback', 'source', 'next', '1'))

    def test_live_reader_accepts_both_full_roster_pages(self):
        ids = [str(i).zfill(128) for i in range(300)]
        rows = [('M', mid) for mid in ids]
        conn = type('Connection', (), {'binding': 'bound', 'check': lambda self: None})
        out = io.StringIO()
        with patch.object(live, 'Connection', conn), patch.object(live, 'roster_rows', return_value=rows) as roster, patch.object(live.sys, 'stdin', io.StringIO(','.join(ids) + '\n')), patch.object(live.time, 'sleep', side_effect=KeyboardInterrupt), contextlib.redirect_stdout(out):
            with self.assertRaises(KeyboardInterrupt):
                live.poll('', 'bound')
        self.assertTrue(roster.call_args.kwargs['include_archived'])
        self.assertEqual(set(out.getvalue().strip().split('\t')[1].removeprefix('+').split('\x1f')), {'M\x1c' + mid for mid in ids})

    def test_coalesces_before_ipc(self):
        class Connection:
            binding = 'bound'

            def check(self):
                pass

            def get(self, path, cap):
                return dict(id='a', title='Title', status='active', text='Public')

        out = io.StringIO()
        with patch.object(live, 'roster_rows', return_value=[('M','a','Title')]), patch.object(live, 'Connection', Connection), patch.object(live.time, 'sleep', side_effect=[None, KeyboardInterrupt]), contextlib.redirect_stdout(out):
            with self.assertRaises(KeyboardInterrupt):
                live.poll_bubble('a', 'bound')
        self.assertEqual(out.getvalue(), 'B\tTitle\tactive\tPublic\n')

    def test_unselected_status_changes_reach_sidebar(self):
        class Connection:
            binding = 'bound'
            def check(self):
                pass

        def rows(status):
            return [('M', 'b', 'Title', '', '', '', '', status)]

        out = io.StringIO()
        with patch.object(live, 'Connection', Connection), patch.object(live, 'roster_rows', side_effect=[rows('active'), rows('paused')]), patch.object(live.time, 'monotonic', side_effect=[0, 6, 6]), patch.object(live.time, 'sleep', side_effect=[None, KeyboardInterrupt]), contextlib.redirect_stdout(out):
            with self.assertRaises(KeyboardInterrupt):
                live.poll('', 'bound', {'b'})
        self.assertEqual(out.getvalue().rstrip('\n').split('\n'),
                         ['R\t+' + '\x1c'.join(rows(status)[0]) for status in ('active', 'paused')])

    def test_machine_status_updates_without_id_change(self):
        conn = type('Connection', (), {'binding': 'bound', 'check': lambda self: None})
        def rows(status):
            return [('N', 'node', 'Name\twith separator', '', '', '', '', '', status, '', '', 0)]
        out = io.StringIO()
        with patch.object(live, 'Connection', conn), patch.object(
                live, 'roster_rows', side_effect=[rows('online'), rows('offline')]), patch.object(
                live.time, 'monotonic', side_effect=[0, 6, 6]), patch.object(
                live.time, 'sleep', side_effect=[None, KeyboardInterrupt]), contextlib.redirect_stdout(out):
            with self.assertRaises(KeyboardInterrupt):
                live.poll('', 'bound', set())
        records = [line.removeprefix('R\t+N\x1c').split('\x1c') for line in out.getvalue().strip().split('\n')]
        self.assertEqual([(r[0], r[1], r[7]) for r in records],
                         [('node', 'Name with separator', 'online'), ('node', 'Name with separator', 'offline')])

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
