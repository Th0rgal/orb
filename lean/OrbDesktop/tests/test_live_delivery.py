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

    def test_saved_session_recovers_inside_the_window(self):
        self.run_wire('reconnect')

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
                if mode == 'reconnect' and tokens[-1] == 'Bearer fixture':
                    self.send_error(401)
                    return
                if path == '/api/projects':
                    result = {'projects': [dict(slug='p', title='Project title', objective='Objective', color='blue')]}
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
                    if mode == 'start-running' and paths.count(path) == 1:
                        result[-1]['status'] = 'pending'
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
                elif mode in ('page-two', 'null-retry', 'start-running'):
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

    def test_new_agent_sends_the_first_prompt_in_the_create_request(self):
        prompt = 'First line\tcontains a tab.\nSecond line.'
        payload = '\t'.join(['core', 'codex', 'model', '', 'supervised', 'now', prompt])
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
            self.assertNotIn('remote_node_id', request.kwargs['body'])

    def test_child_precedes_parent_in_live_roster(self):
        child = dict(id='child', folder='notes/today', parent_mission_id='launch',
                     callback_parent_mission_id='callback', tags=['fork-of:source'],
                     superseded_by_mission_id='next')
        pages = {'/api/projects': {'projects': []}, '/api/machines': [],
                 '/api/control/missions?limit=200': [child]}
        connection = type('Fixture', (), {'binding': 'bound', 'check': lambda _: None,
                                          'get': lambda _, path: pages[path]})()
        for missions in ([child], [child, dict(id='launch')]):
            pages['/api/control/missions?limit=200'] = missions
            projected = next(row for row in live.roster_rows(connection) if row[0] == 'M')
            self.assertEqual(projected[16:], ('notes/today', 'launch', 'callback', 'source', 'next'))

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
                live.poll('a', 'bound', {'a'})
        self.assertEqual(out.getvalue(), 'B\t+M\x1ca\x1cTitle\tTitle\tactive\tPublic\n')

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
