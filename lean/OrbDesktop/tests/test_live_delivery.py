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
from unittest.mock import ANY, Mock, call, patch

PKG = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PKG / 'OrbDesktop'))
import live_transport as live


QUERY = (PKG.parent / 'OrbCore/OrbCore/current_bubble.sql').read_text()

# Reconstruction (labeled as such in the PR) of the reported live gap: an earlier
# assistant turn followed by a canonical turn whose content is a fenced Mermaid
# graph with an S --Approve--> T edge and a Revise branch. Node shapes are varied
# (rounded/pill/diamond) so the replay can observe them; the driver asserts the
# rendered labels, shapes and edge directions without assuming any widget ids.
MERMAID_TURN = ('```mermaid\ngraph LR\n'
                '  S[Spec] -->|Approve| T(Build)\n'
                '  T -->|Revise| R{Fix}\n```')

MERMAID_BACKEDGE = ('```mermaid\ngraph LR\n'
                    '  Draft[Design spec] --> Review[Code review]\n'
                    '  Review -->|Approve| Deploy[Canary deploy]\n'
                    '  Deploy --> Verify[Verify release]\n'
                    '  Review -->|Revise| Draft\n```')

MERMAID_CYCLE = ('```mermaid\ngraph LR\n'
                 '  A[Alpha] -->|Ship| B[Beta]\n'
                 '  B[Beta] -->|Return| A[Alpha]\n```')

MD_TURN = ('# Release notes\n'
           '\n'
           '**Bold start** and *a soft italic* plus `inline code` here.\n'
           '\n'
           '- First bullet\n'
           '- Second bullet\n'
           '\n'
           'Docs at [the guide](https://example.test/guide).\n'
           '\n'
           '```python\n'
           'print("hi")\n'
           '```\n')


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

        completed_reads = 0
        partial = False

        class Core(BaseHTTPRequestHandler):
            def reply(self, body, code=200):
                self.send_response(code)
                self.end_headers()
                self.wfile.write(json.dumps(body).encode())

            def do_GET(self):
                nonlocal completed_reads
                if self.path == '/api/auth/me':
                    self.reply({'user': {'username': self.headers['Authorization'].split()[1]}})
                elif self.path == live.INBOX_PATH:
                    self.reply(states[self.headers['Authorization'].split()[1]])
                elif self.path == '/api/control/missions?status=completed&limit=100':
                    completed_reads += 1
                    if partial and completed_reads > 1:
                        self.reply([], 206)
                    else:
                        self.reply([mission])
                elif partial and completed_reads and self.path == '/api/control/missions?limit=200&include_ancestors=true':
                    self.reply([dict(id='next-roster', status='active')])
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
                partial, completed_reads = True, 0
                states['bob'] = {'_versions': {}}
                subprocess.run(['lean', '--run', 'tests/LiveDelivery.lean', 'inbox', 'partial'],
                               cwd=PKG, check=True, timeout=30, env={**os.environ, 'ORB_STATE_DIR': root})
                self.assertEqual(states['bob'], {'_versions': {}})
            server.shutdown()

    def test_inbox_reads_bounded_windows_with_irrelevant_archive(self):
        rules = json.loads((PKG.parents[1] / 'orb/src/projectHistoryRules.json').read_text())
        old = dict(id='question', project='p', status='awaiting_user', callback_parent_mission_id='controller')
        parent = dict(id='controller', project='p', status='completed')
        query = '/api/control/missions?project=p&limit=200'
        for count in (200, 18600):
            history = [dict(id=f'archive-{i}', status='acknowledged', project='p') for i in range(count)] + [old, parent]
            pages = {query + '&all=true': history[:200], query: [old, parent],
                     '/api/control/missions?status=completed&limit=100': [],
                     live.INBOX_PATH: {'preferences': {'includeAutonomous': True}}}
            calls = []
            elapsed = 0
            def get(path, cap, *, deadline):
                nonlocal elapsed
                calls.append(path)
                self.assertGreater(deadline, 0)
                result = pages[path]
                elapsed += 0.1 + len(result) * 0.001
                return result
            with patch.object(live.time, 'monotonic', side_effect=lambda: elapsed):
                result = live.inbox_snapshot(Mock(get=get), [{'slug': 'p'}], '', rules, roster=[])
            self.assertEqual([r[1] for r in result if r[0] == 'U'], ['question', 'controller'])
            self.assertEqual(calls, [live.INBOX_PATH, query + '&all=true', query, '/api/control/missions?status=completed&limit=100'])
            self.assertAlmostEqual(elapsed, 0.603)

    def test_project_windows_resume_and_are_reused_after_publication(self):
        rules = json.loads((PKG.parents[1] / 'orb/src/projectHistoryRules.json').read_text())
        rules['pageSize'] = 1
        projects = [{'slug': str(i)} for i in range(7)]
        elapsed = 0
        paths = []
        def get(path, cap, *, deadline):
            nonlocal elapsed
            self.assertGreaterEqual(deadline, 1)
            elapsed += 1
            paths.append(path)
            if path.endswith('&all=true'):
                return [dict(id=path, status='acknowledged', tags=['archived'])]
            return {} if path == live.INBOX_PATH else []
        c = Mock(get=get)
        windows = live.InboxWindows()
        with patch.object(live.time, 'monotonic', side_effect=lambda: elapsed):
            for _ in range(4):
                with self.assertRaises(TimeoutError):
                    live.inbox_snapshot(c, projects, '', rules, windows, [])
            self.assertEqual(live.inbox_snapshot(c, projects, '', rules, windows, []), [('I', 'enabled')])
            project_reads = [p for p in paths if '?project=' in p]
            self.assertEqual(len(project_reads), 14)
            self.assertEqual(len(set(project_reads)), 14)
            paths.clear()
            self.assertEqual(live.inbox_snapshot(c, projects, '', rules, windows, []), [('I', 'enabled')])
            self.assertEqual(paths, [live.INBOX_PATH, '/api/control/missions?status=completed&limit=100'])
            paths.clear()
            live.inbox_snapshot(c, projects[:1], '', rules, windows, [])
            self.assertEqual(len([p for p in paths if '?project=' in p]), 2)

    def test_incomplete_window_preserves_badge_and_retries_with_fresh_receipts(self):
        c = Mock(binding='bound')
        windows = live.InboxWindows()
        rules = json.loads((PKG.parents[1] / 'orb/src/projectHistoryRules.json').read_text())
        old = dict(id='a', project='p', status='completed', updated_at='2026-01-01T00:00:00Z')
        child = dict(id='b', project='p', status='awaiting_user', callback_parent_mission_id='missing')
        query = '/api/control/missions?project=p&limit=200'
        completed = '/api/control/missions?status=completed&limit=100'
        ancestor = '/api/control/missions/missing?include_history=false'
        current = '/api/control/missions?limit=200&include_ancestors=true'
        project_list = [{'slug': 'p'}]
        pages = {live.INBOX_PATH: {'preferences': {'includeAutonomous': True}},
                 '/api/projects': {'projects': project_list}, '/api/machines': [],
                 query + '&all=true': [old], query: [old], current: [child], completed: [old]}
        def get(path, *args, **kwargs):
            if path == ancestor:
                raise live.urllib.error.HTTPError(path, 404, 'missing', {}, None)
            return pages[path]
        c.get.side_effect = get
        def sample():
            return [r[:2] for r in live.roster_rows(c, rules=rules, inbox_for='', inbox_windows=windows)
                    if r[0] in ('I', 'U')]
        self.assertEqual(sample(), [('I', 'enabled'), ('U', 'b'), ('U', 'a')])
        windows.project_refresh_at = 0
        pages[completed] = {'partial': True}
        self.assertEqual(sample(), [('I', 'refreshing')])
        # The roster now has a newer response than the buffered project record.
        pages[current] = [dict(old, status='running', updated_at='2026-02-01T00:00:00Z'), child]
        pages[live.INBOX_PATH]['seen:b'] = 1
        pages[completed] = [old]
        c.get.reset_mock()
        self.assertEqual(sample(), [('I', 'enabled')])
        self.assertNotIn(query, [args.args[0] for args in c.get.call_args_list])
        self.assertIn(call(ancestor, 8 << 20, deadline=ANY), c.get.call_args_list)

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
            connection.return_value.creds = ('https://fixture.test', 'private')
            connection.return_value.get.return_value = {'user': {'username': 'Ben'}}
            live.roster()
        self.assertEqual(output.getvalue().splitlines(), ['C\tbinding', 'P\tsource\tSource\t', 'A\thttps://fixture.test\tBen'])
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
        direct = {'can_configure': True, 'countries': ['NL', 'FI', 'NL'], 'mode': 'direct', 'status': 'direct', 'saved': True}
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
            self.assertEqual(rows, [
                ('refresh', '', 'Account connection',
                 'AirVPN · NL · Verified exit · fixture · 192.0.2.1 · VPN routing is unavailable for this credential.'),
                ('refresh', '', 'Alternative routers', 'Could not load. Retry'),
            ])
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
            self.assertIn('Verified exit · fixture · 192.0.2.35', saved)
            self.assertIn('D\t\tNL\tAirVPN · NL\tSelected', saved)
            c.binding = 'thomas'
            live.account_routes('thomas', 'shared/account', 'openai', '', '')
            self.assertEqual(output.getvalue(), saved * 2)
            self.assertEqual(c.request.call_count, 1)

    def test_account_vpn_matches_shared_fixture(self):
        spec = json.loads((PKG.parents[1] / 'shared/orb-spec/fixtures/account-vpn.json').read_text())
        self.assertGreater(len(spec['routes']), 0)
        self.assertGreater(len(spec['invalid_routes']), 0)

        for case in spec['routes']:
            with self.subTest(route=case['name']):
                route = live.account_vpn_route(case['payload'])
                self.assertIsNotNone(route)
                view = live.account_vpn_view(route, case['native'])
                self.assertEqual(view, case['view'])

                rows = list(live.vpn_options(case['payload'], case['native']))
                header_row, *choice_rows = rows
                expected = case['view']
                self.assertEqual(header_row[2], 'Account connection')
                self.assertEqual(header_row[0], 'refresh' if not expected['editable'] else '')
                if expected['status']:
                    self.assertIn(expected['status'], header_row[3])
                if expected['notice']:
                    self.assertIn(expected['notice'], header_row[3])
                if not expected['status'] and not expected['notice']:
                    self.assertEqual(header_row[3], 'AirVPN · ' + expected['selected'] if expected['selected'] else 'Direct')

                if expected['editable']:
                    self.assertEqual([r[1] for r in choice_rows], ['', *expected['countries']])
                    self.assertEqual([r[2] for r in choice_rows],
                                     ['Direct', *('AirVPN · ' + c for c in expected['countries'])])
                    for action, value, _, detail in choice_rows:
                        if value == expected['selected']:
                            if expected['retry']:
                                self.assertEqual((action, detail), ('vpn', 'Retry verification'))
                            elif not value and expected['confirm_direct']:
                                self.assertEqual((action, detail), ('vpn', 'Confirm Direct route'))
                            else:
                                self.assertEqual((action, detail), ('', 'Selected'))
                        else:
                            self.assertEqual((action, detail), ('vpn', ''))
                else:
                    self.assertEqual(choice_rows, [])

                retry_rows = [r for r in rows if r[3] == 'Retry verification']
                self.assertEqual(len(retry_rows), 1 if (expected['editable'] and expected['retry']) else 0)

                with patch.object(live, 'Connection') as conn, contextlib.redirect_stdout(io.StringIO()) as out:
                    c = conn.return_value
                    c.binding = 'ben'
                    c.get.side_effect = [case['payload'], {'allowed': False}] if case['native'] else [case['payload']]
                    live.account_routes('ben', 'acct', 'antigravity' if case['native'] else 'openai', '', '')
                lines = out.getvalue().splitlines()
                self.assertEqual(lines[0], 'routes\tpoll' if expected['poll'] else 'routes')

        for idx, payload in enumerate(spec['invalid_routes']):
            with self.subTest(invalid_route=idx, payload=payload):
                self.assertIsNone(live.account_vpn_route(payload))
                with self.assertRaises(ValueError):
                    list(live.vpn_options(payload))
                c = Mock(get=Mock(return_value=payload))
                rows, should_poll = live.account_route_state(c, 'acct', False)
                self.assertEqual(rows, [('refresh', '', 'Account connection', 'Could not load. Retry')])
                self.assertFalse(should_poll)

        for case in spec['writes']:
            self.assertEqual(live.account_vpn_write(case['country']), case['body'])

        for case in spec['read_errors']:
            self.assertEqual(live.missing_account_setting(case['status'], case['body'], case['path']),
                             case['missing_endpoint'])

        for case in spec['router_access']:
            self.assertEqual(live.alternative_router_access(case['payload']), case['allowed'])

    def test_pending_route_reread_interval_and_settle_unit(self):
        awaiting = {'countries': ['NL'], 'can_configure': True, 'mode': 'vpn', 'country': 'NL',
                    'status': 'blocked', 'reason': 'vpn_awaiting_verification',
                    'message': 'Waiting for exit verification.'}
        stopped = {'countries': ['NL'], 'can_configure': True, 'mode': 'vpn', 'country': 'NL',
                   'status': 'blocked', 'reason': 'vpn_tunnel_stopped',
                   'message': 'The VPN tunnel stopped. Retry verification to start a new one.'}
        verified = {'countries': ['NL'], 'can_configure': True, 'mode': 'vpn', 'country': 'NL',
                    'status': 'verified', 'server': 'Alkaid', 'exits': ['192.0.2.20']}

        with patch.object(live, 'Connection') as conn, patch.object(live.time, 'sleep') as sleep:
            c = conn.return_value
            c.binding = 'ben'
            c.get.side_effect = [awaiting, awaiting, stopped, awaiting, verified]
            c.request.return_value = awaiting

            def run(action='', value='', poll=''):
                out = io.StringIO()
                with contextlib.redirect_stdout(out):
                    live.account_routes('ben', 'acct', 'openai', action, value, poll)
                return out.getvalue().splitlines()

            first = run()
            sleep.assert_not_called()
            self.assertEqual(first[0], 'routes\tpoll')
            self.assertIn('D\t\tNL\tAirVPN · NL\tSelected', first)
            self.assertFalse(any('Retry verification' in line for line in first))

            still_pending = run(poll='poll')
            sleep.assert_called_once_with(live.ACCOUNT_VPN_POLL_SECONDS)
            self.assertEqual(live.ACCOUNT_VPN_POLL_SECONDS, 5)
            self.assertEqual(still_pending[0], 'routes\tpoll')
            self.assertFalse(any('Retry verification' in line for line in still_pending))

            failed = run(poll='poll')
            self.assertEqual([c.args[0] for c in sleep.call_args_list], [5, 5])
            self.assertEqual(failed[0], 'routes')
            self.assertIn('D\tvpn\tNL\tAirVPN · NL\tRetry verification', failed)

            retried = run(action='vpn', value='NL', poll='poll')
            self.assertEqual([c.args[0] for c in sleep.call_args_list], [5, 5])
            c.request.assert_called_once_with('/api/ai/providers/acct/vpn',
                                              body={'mode': 'vpn', 'country': 'NL'}, method='PUT', deadline=120)
            self.assertEqual(retried[0], 'routes\tpoll')
            self.assertFalse(any('Retry verification' in line for line in retried))

            settled = run(poll='poll')
            self.assertEqual([c.args[0] for c in sleep.call_args_list], [5, 5, 5])
            self.assertEqual(settled[0], 'routes')
            self.assertIn('D\t\t\tAccount connection\tVerified exit · Alkaid · 192.0.2.20', settled)
            self.assertIn('D\t\tNL\tAirVPN · NL\tSelected', settled)

    def test_pending_account_route_rereads_until_settled_over_core_wire(self):
        awaiting = {'countries': ['NL'], 'can_configure': True, 'mode': 'vpn', 'country': 'NL',
                    'status': 'blocked', 'reason': 'vpn_awaiting_verification',
                    'message': 'Waiting for exit verification.'}
        stopped = {'countries': ['NL'], 'can_configure': True, 'mode': 'vpn', 'country': 'NL',
                   'status': 'blocked', 'reason': 'vpn_tunnel_stopped',
                   'message': 'The VPN tunnel stopped. Retry verification to start a new one.'}
        verified = {'countries': ['NL'], 'can_configure': True, 'mode': 'vpn', 'country': 'NL',
                    'status': 'verified', 'server': 'Alkaid', 'exits': ['192.0.2.20']}
        vpn_gets = []
        vpn_puts = []
        responses = [awaiting, stopped, awaiting, verified]

        class Core(BaseHTTPRequestHandler):
            def reply(self, body, code=200):
                self.send_response(code)
                self.end_headers()
                self.wfile.write(json.dumps(body).encode())

            def do_GET(self):
                if self.path == '/api/auth/me':
                    self.reply({'user': {'username': 'Ben'}})
                elif self.path == '/api/projects':
                    self.reply({'projects': []})
                elif self.path == '/api/machines':
                    self.reply([])
                elif self.path == '/api/ai/providers':
                    self.reply({'providers': [{'id': 'acct', 'name': 'OpenAI', 'provider_type': 'openai',
                                               'enabled': True, 'user_enabled': True}]})
                elif self.path == '/api/ai/providers/acct/vpn':
                    idx = min(len(vpn_gets), len(responses) - 1)
                    vpn_gets.append(time.monotonic())
                    self.reply(responses[idx])
                elif self.path == '/api/backends':
                    self.reply({'backends': []})
                elif self.path == '/api/providers/backend-models':
                    self.reply({'backends': {}})
                elif self.path == '/api/model-routing/chains':
                    self.reply([])
                else:
                    self.reply([])

            def do_PUT(self):
                if self.path != '/api/ai/providers/acct/vpn':
                    self.send_error(404)
                    return
                body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                vpn_puts.append(body)
                self.reply(awaiting)

            def log_message(self, *_):
                pass

        with ThreadingHTTPServer(('127.0.0.1', 0), Core) as server, tempfile.TemporaryDirectory() as root:
            threading.Thread(target=server.serve_forever, daemon=True).start()
            try:
                (Path(root) / 'connection.json').write_text(json.dumps(dict(
                    api_url=f'http://127.0.0.1:{server.server_port}', token='fixture')))
                subprocess.run(['lean', '-j', '1', '-M', '1024', '--run', 'tests/LiveDelivery.lean', 'account-vpn-poll'],
                               cwd=PKG, env={**os.environ, 'ORB_STATE_DIR': root}, check=True, timeout=45)
            finally:
                server.shutdown()

        self.assertEqual(len(vpn_gets), 4)
        self.assertEqual(vpn_puts, [{'mode': 'vpn', 'country': 'NL'}])
        self.assertGreaterEqual(vpn_gets[1] - vpn_gets[0], 4.5)
        self.assertGreaterEqual(vpn_gets[3] - vpn_gets[2], 4.5)

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
        paths, tokens, cold_polls = [], [], []
        db = fixture()
        if mode == 'mermaid-turn':
            # Two-turn live case: turn one is already persisted when the client
            # attaches; the handler stages the follow-up turn across later polls.
            db.execute("DELETE FROM mission_events WHERE mission_id='a'")
            db.execute("INSERT INTO mission_events VALUES(NULL,'a',1,1,'user_message',?,'{}','')",
                       (json.dumps({'content': 'PRIVATE', 'queued': False}),))
            db.execute("INSERT INTO mission_events VALUES(NULL,'a',2,2,'assistant_message_canonical',?,'{}','')",
                       (json.dumps({'content': 'Amber blossom'}),))
        if mode == 'mermaid-backedge':
            # The controller-reported graph: the Review -> Draft back edge and its
            # Revise label must render even though it routes backwards across the
            # rank columns, and Review (two labelled outgoing edges) must show
            # both Approve and Revise.
            db.execute("DELETE FROM mission_events WHERE mission_id='a'")
            db.execute("INSERT INTO mission_events VALUES(NULL,'a',1,1,'assistant_message',?,'{}','')",
                       (json.dumps({'content': MERMAID_BACKEDGE, 'queued': False}),))
        if mode == 'mermaid-cycle':
            # The review's exact two-node bidirectional cycle: both directions must
            # render as separate actual paths with clear labels and arrowheads at
            # opposite targets.
            db.execute("DELETE FROM mission_events WHERE mission_id='a'")
            db.execute("INSERT INTO mission_events VALUES(NULL,'a',1,1,'assistant_message',?,'{}','')",
                       (json.dumps({'content': MERMAID_CYCLE, 'queued': False}),))
        if mode == 'markdown-turn':
            # A live turn that first streams a single markdown line, then completes
            # into a multi-line markdown document with lists, links, inline styles
            # and a non-mermaid code fence. Both stream shapes must render without
            # their literal markers.
            db.execute("DELETE FROM mission_events WHERE mission_id='a'")
            db.execute("INSERT INTO mission_events VALUES(NULL,'a',1,1,'assistant_message',?,'{}','')",
                       (json.dumps({'content': 'Amber blossom', 'queued': False}),))
        if mode == 'cold-recover':
            # Cold open with persisted turns, then a transient unavailable window
            # (a projection no client can parse), then the same text again. The
            # client must restore the earlier turns from the persisted timeline
            # instead of losing them for good after the wipe.
            db.execute("DELETE FROM mission_events WHERE mission_id='a'")
            db.execute("UPDATE missions SET status='completed' WHERE id='a'")
            for seq, kind, content in (
                    (1, 'user_message', 'PRIVATE'), (2, 'assistant_message', 'Amber blossom'),
                    (3, 'user_message', 'PRIVATE'), (4, 'assistant_message', 'Cold ember glow')):
                db.execute("INSERT INTO mission_events VALUES(NULL,'a',?,?,?,?,'{}','')",
                           (seq, seq, kind, json.dumps({'content': content, 'queued': False})))
        if mode == 'cold-open':
            # Completed mission in the real Core persistence shape: delivered user
            # prompts and assistant turns stored as plain assistant_message, with the
            # final turn also replaced by its canonical form. The history projection
            # must cover all three event types, keep one copy of the canonical
            # replacement and yield the newest turn to the live bubble. A third turn
            # streams live, but only after the driver has observed and asserted the
            # cold-open render (marker file).
            db.execute("DELETE FROM mission_events WHERE mission_id='a'")
            db.execute("UPDATE missions SET status='completed' WHERE id='a'")
            for seq, kind, content in (
                    (1, 'user_message', 'PRIVATE'), (2, 'assistant_message', 'Amber blossom'),
                    (3, 'user_message', 'PRIVATE'), (4, 'assistant_message', MERMAID_TURN),
                    (5, 'assistant_message_canonical', MERMAID_TURN)):
                db.execute("INSERT INTO mission_events VALUES(NULL,'a',?,?,?,?,'{}','')",
                           (seq, seq, kind, json.dumps({'content': content, 'queued': False})))
        if mode in ('long-paging', 'older-403', 'paging-degraded-recover', 'stale-older-race'):
            # >1,000-row persisted mission: initial /open serves only the newest
            # 200 tail rows + 80 spine rows (280 total), and earlier rows page in
            # on demand via /events?before_seq=...&view=transcript&limit=200.
            db.execute("DELETE FROM mission_events WHERE mission_id='a'")
            db.execute("UPDATE missions SET status='completed' WHERE id='a'")
            for seq in range(1, 1051):
                kind = 'user_message' if seq % 2 == 1 else 'assistant_message'
                content = f'Turn {seq:04d}'
                db.execute("INSERT INTO mission_events VALUES(NULL,'a',?,?,?,?,'{}','')",
                           (seq, seq, kind, json.dumps({'content': content, 'queued': False})))
        degraded_sent = threading.Event()
        older_started = threading.Event()
        unavailable_sent = threading.Event()
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
                if path == '/api/auth/me':
                    result = {'user': {'username': 'Ben' if tokens[-1] == 'Bearer fixture' else 'Alice'}}
                elif path == '/api/projects':
                    result = {'projects': [dict(slug='p', title='Project title', objective='Objective', color='blue')]}
                elif path == '/api/control/missions?limit=200&include_ancestors=true':
                    if mode == 'project-first' and paths.count(path) > 1:
                        release_project.wait(8)
                    if mode == 'unavailable':
                        self.send_response(302)
                        self.send_header('Location', '/redirect')
                        self.end_headers()
                        return
                    if mode == 'idle-session' and paths.count(path) > 1:
                        self.send_error(401)
                        return
                    ids = ('a',) if (mode == 'idle-share' and paths.count(path) > 2) or \
                        (mode == 'share-403' and paths.count(path) > 1) else ('a','b')
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
                elif path == '/api/control/missions?status=completed&limit=100':
                    result = []
                elif mode == 'project-first' and path.startswith('/api/control/missions?project=p&'):
                    result = [dict(id='older', project='p', status='completed', tags=['archived'])]
                elif path == live.INBOX_PATH:
                    result = {'_versions': {}}
                elif mode == 'project-lag' and path.startswith('/api/control/missions?project=p&'):
                    project_started.set()
                    release_project.wait(8)
                    result = []
                elif path.startswith('/api/control/missions?project=p&') or path == '/api/machines':
                    result = []
                elif path.split('?')[0] == a + '/open':
                    # Real Core open bundle: mission detail, first events page and the
                    # older transcript spine, read from the same mission_events rows
                    # the bubble reads. The client filters transcript event types.
                    rows = db.execute(
                        "SELECT id, COALESCE(NULLIF(seq,0),sequence), event_type, payload, content"
                        " FROM mission_events WHERE mission_id='a'"
                        " ORDER BY COALESCE(NULLIF(seq,0),sequence) DESC, id DESC LIMIT 200").fetchall()
                    events_page = []
                    for row in reversed(rows):
                        payload = json.loads(row[3]) if row[3] else {}
                        content = payload.get('content') if isinstance(payload.get('content'), str) else row[4]
                        events_page.append(dict(id=row[0], mission_id='a', sequence=row[1],
                                                event_type=row[2], content=content))
                    spine_page = []
                    spine_has_more = False
                    spine_next_cursor = None
                    if events_page:
                        oldest_tail = events_page[0]['sequence']
                        spine_rows = db.execute(
                            "SELECT id, COALESCE(NULLIF(seq,0),sequence), event_type, payload, content"
                            " FROM mission_events WHERE mission_id='a' AND COALESCE(NULLIF(seq,0),sequence) < ?"
                            " ORDER BY COALESCE(NULLIF(seq,0),sequence) DESC, id DESC LIMIT 81",
                            (oldest_tail,)).fetchall()
                        spine_has_more = len(spine_rows) > 80
                        for row in reversed(spine_rows[:80]):
                            payload = json.loads(row[3]) if row[3] else {}
                            content = payload.get('content') if isinstance(payload.get('content'), str) else row[4]
                            spine_page.append(dict(id=row[0], mission_id='a', sequence=row[1],
                                                   event_type=row[2], content=content))
                        if spine_has_more and spine_page:
                            spine_next_cursor = spine_page[0]['sequence']
                    result = dict(protocol=1, mission=dict(id='a'), events=events_page, spine=spine_page,
                                  queue=[], max_seq=events_page[-1]['sequence'] if events_page else 0,
                                  has_more=spine_has_more, spine_has_more=spine_has_more,
                                  spine_next_cursor=spine_next_cursor,
                                  next_cursor=spine_next_cursor, page_max_seq=None, reset=False)
                elif path.split('?')[0] == a + '/events':
                    if mode == 'older-403':
                        self.send_error(403)
                        return
                    if mode == 'stale-older-race':
                        older_started.set()
                        deadline = time.monotonic() + 8
                        while time.monotonic() < deadline and not (Path(root) / 'stale-race-cleared').exists():
                            time.sleep(0.02)
                    qs = live.urllib.parse.parse_qs(live.urllib.parse.urlsplit(path).query)
                    before_seq = int(qs.get('before_seq', ['0'])[0])
                    limit = int(qs.get('limit', ['200'])[0])
                    older_rows = db.execute(
                        "SELECT id, COALESCE(NULLIF(seq,0),sequence), event_type, payload, content"
                        " FROM mission_events WHERE mission_id='a' AND COALESCE(NULLIF(seq,0),sequence) < ?"
                        " ORDER BY COALESCE(NULLIF(seq,0),sequence) DESC, id DESC LIMIT ?",
                        (before_seq, limit + 1)).fetchall()
                    has_more = len(older_rows) > limit
                    page_slice = list(reversed(older_rows[:limit]))
                    # Deliberately include the boundary row at seq == before_seq to prove
                    # cross-page deduplication by event/row ID and exclusive cursor handling.
                    overlap = db.execute(
                        "SELECT id, COALESCE(NULLIF(seq,0),sequence), event_type, payload, content"
                        " FROM mission_events WHERE mission_id='a' AND COALESCE(NULLIF(seq,0),sequence) = ? LIMIT 1",
                        (before_seq,)).fetchone()
                    if overlap:
                        page_slice.append(overlap)
                    events_out = []
                    for row in page_slice:
                        payload = json.loads(row[3]) if row[3] else {}
                        content = payload.get('content') if isinstance(payload.get('content'), str) else row[4]
                        events_out.append(dict(id=row[0], mission_id='a', sequence=row[1],
                                               event_type=row[2], content=content))
                    next_cursor = events_out[0]['sequence'] if (has_more and events_out) else None
                    self.send_response(200)
                    self.send_header('X-Has-More', 'true' if has_more else 'false')
                    if next_cursor is not None:
                        self.send_header('X-Next-Cursor', str(next_cursor))
                    self.end_headers()
                    try:
                        self.wfile.write(json.dumps(events_out).encode())
                    except (BrokenPipeError, ConnectionResetError):
                        pass
                    return
                elif path.split('?')[0] in (a + events, b + events):
                    mid = path.split('/')[-2]
                    presence = path.endswith('?presence=1')
                    if mid == 'a' and mode == 'cold-recover' and paths.count(path) == 2:
                        # Core unreachable for one poll: a projection reply that no
                        # client can parse, exactly like the access-loss window.
                        self.send_response(200)
                        self.end_headers()
                        try:
                            self.wfile.write(b'{not json')
                        except (BrokenPipeError, ConnectionResetError):
                            pass
                        return
                    if mid == 'a' and mode == 'paging-degraded-recover' and \
                            (Path(root) / 'paging-paged-one').exists() and not degraded_sent.is_set():
                        degraded_sent.set()
                        for seq, kind in ((1051, 'user_message'), (1052, 'assistant_message')):
                            db.execute("INSERT INTO mission_events VALUES(NULL,'a',?,?,?,?,'{}','')",
                                       (seq, seq, kind, json.dumps({'content': f'Turn {seq:04d}', 'queued': False})))
                        self.send_error(503)
                        return
                    if mid == 'a' and mode == 'stale-older-race' and older_started.is_set() and not unavailable_sent.is_set():
                        unavailable_sent.set()
                        for seq, kind in ((1051, 'user_message'), (1052, 'assistant_message')):
                            db.execute("INSERT INTO mission_events VALUES(NULL,'a',?,?,?,?,'{}','')",
                                       (seq, seq, kind, json.dumps({'content': f'Turn {seq:04d}', 'queued': False})))
                        self.send_response(200)
                        self.end_headers()
                        try:
                            self.wfile.write(b'{not json')
                        except (BrokenPipeError, ConnectionResetError):
                            pass
                        return
                    if mid == 'a' and mode == 'stale-older-race' and unavailable_sent.is_set() and \
                            not (Path(root) / 'stale-race-cleared').exists():
                        self.send_error(503)
                        return
                    if mid == 'a' and mode == 'markdown-turn' and paths.count(path) == 2:
                        # Stream the single markdown line first.
                        db.execute("UPDATE mission_events SET payload=? WHERE mission_id='a' AND seq=1",
                                   (json.dumps({'content': '**Ember glow**', 'queued': False}),))
                    elif mid == 'a' and mode == 'markdown-turn' and paths.count(path) >= 4:
                        # Then complete the turn into the full markdown document.
                        db.execute("UPDATE mission_events SET payload=? WHERE mission_id='a' AND seq=1",
                                   (json.dumps({'content': MD_TURN, 'queued': False}),))
                    if mode == 'access-loss' and mid == 'b' and 2 <= paths.count(path) <= 4:
                        # Core unreachable: a projection reply that no client can parse.
                        self.send_response(200)
                        self.end_headers()
                        try:
                            self.wfile.write(b'{not json')
                        except (BrokenPipeError, ConnectionResetError):
                            pass
                        return
                    if mode == 'project-lag' and mid == 'b':
                        project_started.wait(3)
                    if mode == 'selected-session' and mid == 'b' and paths.count(path) > 1:
                        self.send_error(401)
                        return
                    if mid == 'a' and mode == 'mermaid-turn':
                        # Stage the follow-up turn one event at a time so the client sees
                        # the real projection sequence: turn, boundary, new canonical turn.
                        if paths.count(path) == 2:
                            db.execute("INSERT INTO mission_events VALUES(NULL,'a',3,3,'user_message',?,'{}','')",
                                       (json.dumps({'content': 'PRIVATE', 'queued': False}),))
                        elif paths.count(path) >= 3 and not db.execute(
                                "SELECT 1 FROM mission_events WHERE mission_id='a' AND seq=4").fetchone():
                            db.execute("INSERT INTO mission_events VALUES(NULL,'a',4,4,'assistant_message_canonical',?,'{}','')",
                                       (json.dumps({'content': MERMAID_TURN}),))
                    elif mid == 'a' and paths.count(path) > 1:
                        db.execute("UPDATE missions SET title='Updated', status='awaiting_user' WHERE id='a'")
                        db.execute("UPDATE mission_events SET payload=json_set(payload,'$.queued',json('false')) WHERE mission_id='a' AND seq=3")
                    if mid == 'a' and mode == 'cold-open' and (Path(root) / 'cold-open-observed').exists():
                        # Turn boundary first, then the new canonical turn, so the
                        # client sees the real projection sequence after cold open.
                        cold_polls.append(path)
                        if len(cold_polls) == 1 and not db.execute(
                                "SELECT 1 FROM mission_events WHERE mission_id='a' AND seq=6").fetchone():
                            db.execute("INSERT INTO mission_events VALUES(NULL,'a',6,6,'user_message',?,'{}','')",
                                       (json.dumps({'content': 'PRIVATE', 'queued': False}),))
                        elif len(cold_polls) >= 3 and not db.execute(
                                "SELECT 1 FROM mission_events WHERE mission_id='a' AND seq=7").fetchone():
                            db.execute("INSERT INTO mission_events VALUES(NULL,'a',7,7,'assistant_message_canonical',?,'{}','')",
                                       (json.dumps({'content': 'Ripened fruit'}),))
                    if mid == 'b' and ((mode == 'revoke' and paths.count(path) > 1) or mode == 'idle-share'):
                        db.execute('DELETE FROM mission_shares')
                    if mid == 'b' and mode == 'share-403' and paths.count(path) > 1:
                        # Permission revoked after one successful projection.
                        self.send_error(403)
                        return
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
                               cwd=PKG, env={**os.environ, 'ORB_STATE_DIR': root,
                                             'ORB_TEST_MERMAID': MERMAID_TURN,
                                             'ORB_TEST_BACKEDGE': MERMAID_BACKEDGE,
                                             'ORB_TEST_CYCLE': MERMAID_CYCLE,
                                             'ORB_TEST_MARKDOWN': MD_TURN}, check=True, timeout=45)
                if mode in ('reconnect', 'settings-switch'):
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
                elif mode == 'mermaid-turn':
                    # The follow-up turn must be staged through at least three polls
                    # (turn, boundary, canonical) and mission b stays unpolled.
                    self.assertGreaterEqual(paths.count(a + events), 3)
                    self.assertNotIn(b + events, paths)
                elif mode == 'cold-open':
                    # One bounded /open read populates the cold open; the third
                    # turn must stage across later polls; mission b stays unpolled.
                    self.assertEqual(paths.count(a + '/open'), 1)
                    self.assertGreaterEqual(paths.count(a + events), 3)
                    self.assertNotIn(b + events, paths)
                    self.assertFalse(any(p.split('?')[0] == b + '/events' for p in paths))
                elif mode == 'cold-recover':
                    # The malformed window passes before the fresh projection and
                    # the persisted archive is re-read exactly once on recovery.
                    self.assertEqual(paths.count(a + '/open'), 2)
                    self.assertGreaterEqual(paths.count(a + events), 3)
                    self.assertNotIn(b + events, paths)
                elif mode == 'long-paging':
                    # Fast initial open: /open runs once, and the 4 older /events pages
                    # (771 -> 571 -> 371 -> 171 -> 1) are fetched on demand.
                    self.assertEqual(paths.count(a + '/open'), 1)
                    page_paths = [p for p in paths if p.startswith(a + '/events?')]
                    self.assertEqual(page_paths, [
                        a + '/events?before_seq=771&view=transcript&limit=200',
                        a + '/events?before_seq=571&view=transcript&limit=200',
                        a + '/events?before_seq=371&view=transcript&limit=200',
                        a + '/events?before_seq=171&view=transcript&limit=200',
                    ])
                    self.assertNotIn(b + events, paths)
                elif mode == 'older-403':
                    # On-demand older page 403 revokes the mission and stops polling it.
                    self.assertEqual(paths.count(a + '/open'), 1)
                    self.assertEqual(len([p for p in paths if p.startswith(a + '/events?')]), 1)
                    self.assertNotIn(b + events, paths)
                elif mode == 'paging-degraded-recover':
                    # Initial /open + degraded-recovery /open; one on-demand older page kept intact.
                    self.assertEqual(paths.count(a + '/open'), 2)
                    page_paths = [p for p in paths if p.startswith(a + '/events?')]
                    self.assertEqual(page_paths, [a + '/events?before_seq=771&view=transcript&limit=200'])
                    self.assertNotIn(b + events, paths)
                elif mode == 'stale-older-race':
                    # Initial /open + post-unavailable recovery /open; stale before_seq=771 cancelled/rejected.
                    self.assertEqual(paths.count(a + '/open'), 2)
                    self.assertGreaterEqual(len([p for p in paths if p.startswith(a + '/events?')]), 1)
                    self.assertNotIn(b + events, paths)
                elif mode == 'mermaid-backedge':
                    # The driver renders and asserts from the first bubble; mission
                    # b stays unpolled.
                    self.assertGreaterEqual(paths.count(a + events), 1)
                    self.assertNotIn(b + events, paths)
                elif mode == 'mermaid-cycle':
                    # The driver renders and asserts the bidirectional cycle from
                    # the first bubble; mission b stays unpolled.
                    self.assertGreaterEqual(paths.count(a + events), 1)
                    self.assertNotIn(b + events, paths)
                elif mode == 'markdown-turn':
                    # The single line and the completed document stage across later
                    # polls; mission b stays unpolled.
                    self.assertGreaterEqual(paths.count(a + events), 4)
                    self.assertNotIn(b + events, paths)
                elif mode == 'access-loss':
                    # The malformed window must pass before the fresh projection; the
                    # bubble is polled repeatedly and mission a stays unpolled.
                    self.assertGreaterEqual(paths.count(b + events), 5)
                    self.assertFalse(any(p.split('?')[0] == a + events for p in paths))
                elif mode == 'share-403':
                    # One success, then permission denial: the reader stops there and
                    # never polls the revoked mission again.
                    self.assertEqual(paths.count(b + events), 2)
                elif mode in ('page-two', 'null-retry', 'start-running', 'project-lag'):
                    self.assertIn(b + events, paths)
                elif mode in ('idle-identity', 'before-open', 'unavailable', 'denied', 'idle-session', 'project-first'):
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

    def test_project_cards_arrive_before_delayed_global_roster(self):
        self.run_wire('project-first')

    def test_conversation_updates_while_expanded_project_read_is_pending(self):
        self.run_wire('project-lag')

    def test_revocation(self):
        self.run_wire('revoke')

    def test_access_loss_replays_one_visible_copy(self):
        self.run_wire('access-loss')

    def test_permission_loss_leaves_roster_without_earlier_text(self):
        self.run_wire('share-403')

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

    def test_cold_open_history_yields_the_newest_persisted_turn_to_the_live_bubble(self):
        conn = Mock(binding='bound')
        conn.get.return_value = dict(
            protocol=1, mission=dict(id='a'),
            events=[
                dict(sequence=4, event_type='assistant_message_canonical', content='graph LR'),
                dict(sequence=2, event_type='assistant_message_canonical', content='Amber blossom'),
                dict(sequence=3, event_type='user_message', content='PRIVATE'),
                dict(sequence=5, event_type='tool_call', content='PRIVATE'),
                dict(sequence=1, event_type='assistant_message', content='Seed turn'),
                dict(sequence=7, event_type='assistant_message', content='graph LR'),
            ],
            spine=[dict(sequence=6, event_type='assistant_message_canonical', content='Oldest spine page turn')],
        )
        # Delivered user prompts render with the You marker, both assistant event
        # representations appear, and a canonical event with no matching plain turn
        # is its own distinct turn.
        self.assertEqual(live.history_turns(conn, 'a', 'graph LR'),
                         ['Seed turn', 'Amber blossom', 'You: PRIVATE', 'graph LR',
                          'Oldest spine page turn'])
        self.assertEqual(conn.get.call_args.args[0], '/api/control/missions/a/open')
        # The newest persisted turn is the plain form at sequence 7, so only a
        # bubble text matching it is yielded; an older bubble text keeps everything.
        self.assertEqual(live.history_turns(conn, 'a', 'Oldest spine page turn'),
                         ['Seed turn', 'Amber blossom', 'You: PRIVATE', 'graph LR',
                          'Oldest spine page turn', 'graph LR'])
        # Canonical replacement of the turn the bubble already shows: the deduped
        # copy is yielded to the live bubble instead of duplicating it.
        conn.get.return_value = dict(
            protocol=1, mission=dict(id='a'),
            events=[
                dict(sequence=1, event_type='user_message', content='First prompt'),
                dict(sequence=2, event_type='assistant_message', content='Ripened'),
                dict(sequence=3, event_type='assistant_message_canonical', content='Ripened'),
            ],
            spine=[])
        self.assertEqual(live.history_turns(conn, 'a', 'Ripened'), ['You: First prompt'])
        self.assertEqual(live.history_turns(conn, 'a', ''), ['You: First prompt', 'Ripened'])
        # Two genuinely distinct turns with identical visible text stay separate;
        # the canonical event claims the latest unclaimed plain turn only.
        conn.get.return_value = dict(
            protocol=1, mission=dict(id='a'),
            events=[
                dict(sequence=1, event_type='user_message', content='First prompt'),
                dict(sequence=2, event_type='assistant_message', content='Ripened'),
                dict(sequence=3, event_type='assistant_message', content='Ripened'),
                dict(sequence=4, event_type='assistant_message_canonical', content='Ripened'),
            ],
            spine=[])
        self.assertEqual(live.history_turns(conn, 'a', 'Ripened'),
                         ['You: First prompt', 'Ripened'])
        self.assertEqual(live.history_turns(conn, 'a', ''),
                         ['You: First prompt', 'Ripened', 'Ripened'])
        # An oversized response or a 5xx degrades to an empty archive, but 401/403
        # must propagate: the caller's access-revoked path clears prior content
        # instead of silently keeping a stale transcript.
        conn.get.side_effect = live.ResponseTooLarge('too large')
        self.assertEqual(live.history_turns(conn, 'a', ''), [])
        conn.get.side_effect = live.urllib.error.HTTPError('x', 500, '', {}, None)
        self.assertEqual(live.history_turns(conn, 'a', ''), [])
        for code in (401, 403):
            conn.get.side_effect = live.urllib.error.HTTPError('x', code, '', {}, None)
            with self.assertRaises(live.urllib.error.HTTPError):
                live.history_turns(conn, 'a', '')
        conn.get.side_effect = None
        for broken in ({'error': 'invalid timeline'}, {'events': 'not a list', 'spine': []},
                       {'events': [dict(sequence=1, event_type='assistant_message_canonical')], 'spine': []},
                       [dict(sequence=1, event_type='assistant_message_canonical', content='x')]):
            conn.get.return_value = broken
            self.assertEqual(live.history_turns(conn, 'a', ''), [])

    def test_history_pages_the_older_spine_on_demand_without_fixed_ceiling(self):
        # U5a: SPINE_MAX_PAGES=3 ceiling is gone. Initial /open loads fast in one
        # request and advertises (has_more, next_cursor); older pages load on demand
        # with exclusive before-cursor paging, ID dedup, stuck-cursor protection,
        # and 401/403 propagation.
        self.assertFalse(hasattr(live, 'SPINE_MAX_PAGES'))
        conn = Mock(binding='bound')
        conn.get.return_value = dict(
            protocol=1, mission=dict(id='a'),
            events=[dict(id='e9', sequence=9, event_type='assistant_message', content='Newest')],
            spine=[
                dict(id='e8', sequence=8, event_type='assistant_message', content='Spine one'),
                dict(id='e7', sequence=7, event_type='assistant_message', content='Spine two'),
            ],
            spine_has_more=True, spine_next_cursor=7)
        entries, has_more, next_cursor = live.history_page(conn, 'a', 'Newest')
        self.assertEqual([t for _, t, _ in entries], ['Spine two', 'Spine one'])
        self.assertTrue(has_more)
        self.assertEqual(next_cursor, 7)
        conn.get_page.assert_not_called()

        # On-demand page 1: repeats boundary row seq=7 (overlapping page); exclusive
        # cursor + ID dedup keep only the older row (seq=6) and advance cursor to 6.
        conn.get_page.side_effect = [
            ([dict(id='e6', sequence=6, event_type='assistant_message', content='Older page one'),
              dict(id='e6', sequence=6, event_type='assistant_message', content='Older page one duplicate'),
              dict(id='e7', sequence=7, event_type='assistant_message', content='Spine two')],
             {'x-has-more': 'true', 'x-next-cursor': '6'}),
            ([dict(id='e5', sequence=5, event_type='user_message', content='Oldest')],
             {'x-has-more': 'false'}),
        ]
        p1, more1, cur1 = live.older_history_page(conn, 'a', 7)
        self.assertEqual([(tid, txt) for tid, txt, _ in p1], [('id:e6', 'Older page one')])
        self.assertTrue(more1)
        self.assertEqual(cur1, 6)
        p2, more2, cur2 = live.older_history_page(conn, 'a', cur1)
        self.assertEqual([(tid, txt) for tid, txt, _ in p2], [('id:e5', 'You: Oldest')])
        self.assertFalse(more2)
        self.assertIsNone(cur2)
        cursors = [call.args[0] for call in conn.get_page.call_args_list]
        self.assertEqual(cursors, ['/api/control/missions/a/events?before_seq=7&view=transcript&limit=200',
                                   '/api/control/missions/a/events?before_seq=6&view=transcript&limit=200'])

        # A cursor that stops advancing halts cleanly instead of looping forever.
        conn.get_page.reset_mock()
        conn.get_page.side_effect = [
            ([dict(id='e6', sequence=6, event_type='assistant_message', content='Older page one')],
             {'x-has-more': 'true', 'x-next-cursor': '6'}),
        ]
        stuck_entries, stuck_more, stuck_cur = live.older_history_page(conn, 'a', 6)
        self.assertEqual(stuck_entries, [])
        self.assertFalse(stuck_more)
        self.assertIsNone(stuck_cur)

        # 401 and 403 must still re-raise on older page fetches.
        conn.get_page.reset_mock()
        for code in (401, 403):
            conn.get_page.side_effect = live.urllib.error.HTTPError('http://localhost', code, '', {}, None)
            with self.assertRaises(live.urllib.error.HTTPError) as ctx:
                live.older_history_page(conn, 'a', 7)
            self.assertEqual(ctx.exception.code, code)

        # fetch_older_turns maps 403/404 -> D, 500 -> HE (retryable), and re-raises 401.
        for code, expected in ((403, 'D\n'), (404, 'D\n'), (500, 'HE\n')):
            with patch.object(live, 'Connection') as factory:
                c = factory.return_value
                c.binding = 'bound'
                c.get_page.side_effect = live.urllib.error.HTTPError('http://localhost', code, '', {}, None)
                out = io.StringIO()
                with contextlib.redirect_stdout(out):
                    live.fetch_older_turns('a', 'bound', '7')
                self.assertEqual(out.getvalue(), expected)
        with patch.object(live, 'Connection') as factory:
            c = factory.return_value
            c.binding = 'bound'
            c.get_page.side_effect = live.urllib.error.HTTPError('http://localhost', 401, '', {}, None)
            with self.assertRaises(live.urllib.error.HTTPError) as ctx:
                live.fetch_older_turns('a', 'bound', '7')
            self.assertEqual(ctx.exception.code, 401)

    def test_large_transcript_loads_initial_window_fast_and_pages_to_turn_1(self):
        # 1,200 persisted turns: initial /open loads 280 rows in 1 request, then 5
        # on-demand pages walk all the way back to turn 1 with zero duplicates or drops.
        total_rows = 1200
        all_rows = [
            dict(id=f'evt-{seq}', sequence=seq,
                 event_type='user_message' if seq % 2 == 1 else 'assistant_message',
                 content=f'Turn {seq:04d}')
            for seq in range(1, total_rows + 1)
        ]
        conn = Mock(binding='bound')
        conn.get.return_value = dict(
            protocol=1, mission=dict(id='a'),
            events=all_rows[1000:],   # 1001..1200 (200 rows)
            spine=all_rows[920:1000], # 921..1000 (80 rows)
            spine_has_more=True, spine_next_cursor=921)

        def fake_get_page(path):
            qs = live.urllib.parse.parse_qs(live.urllib.parse.urlsplit(path).query)
            before = int(qs['before_seq'][0])
            limit = int(qs['limit'][0])
            older = [r for r in all_rows if r['sequence'] < before]
            page = older[-limit:]
            has_more = len(older) > limit
            # Inject an overlapping boundary row to verify dedup.
            boundary = [r for r in all_rows if r['sequence'] == before]
            headers = {'x-has-more': 'true' if has_more else 'false'}
            if has_more and page:
                headers['x-next-cursor'] = str(page[0]['sequence'])
            return (page + boundary, headers)

        conn.get_page.side_effect = fake_get_page

        # Fast initial window: 1 /open call, 0 /events calls.
        entries, has_more, cursor = live.history_page(conn, 'a', '')
        self.assertEqual(conn.get.call_count, 1)
        self.assertEqual(conn.get_page.call_count, 0)
        self.assertEqual(len(entries), 280)
        self.assertTrue(has_more)
        self.assertEqual(cursor, 921)

        # Page all the way back to turn 1 on demand.
        seen_ids = {tid for tid, _, _ in entries}
        collected = list(entries)
        pages_fetched = 0
        while has_more and cursor is not None:
            older_entries, has_more, cursor = live.older_history_page(conn, 'a', cursor)
            pages_fetched += 1
            deduped = []
            for item in older_entries:
                self.assertNotIn(item[0], seen_ids)
                seen_ids.add(item[0])
                deduped.append(item)
            collected = deduped + collected

        self.assertEqual(pages_fetched, 5)  # 920 rows at 200/page -> 5 pages
        self.assertEqual(len(collected), total_rows)
        expected = [
            f'You: Turn {seq:04d}' if seq % 2 == 1 else f'Turn {seq:04d}'
            for seq in range(1, total_rows + 1)
        ]
        self.assertEqual([txt for _, txt, _ in collected], expected)

    def test_long_transcript_pages_to_turn_1_without_duplicates_or_layout_jump(self):
        self.run_wire('long-paging')

    def test_older_page_403_revokes_and_clears_transcript(self):
        self.run_wire('older-403')

    def test_degraded_recovery_preserves_paged_older_turns_and_scroll_anchor(self):
        self.run_wire('paging-degraded-recover')

    def test_stale_older_fetch_cancelled_and_rejected_across_unavailable_recovery(self):
        self.run_wire('stale-older-race')

    def test_two_turn_live_keeps_history_and_renders_mermaid(self):
        self.run_wire('mermaid-turn')

    def test_cold_open_repopulates_persisted_history_and_streams_onward(self):
        self.run_wire('cold-open')

    def test_unavailable_window_keeps_the_persisted_archive(self):
        self.run_wire('cold-recover')

    def test_back_edge_and_both_labels_render(self):
        self.run_wire('mermaid-backedge')

    def test_two_node_cycle_renders_opposite_arrowheads(self):
        self.run_wire('mermaid-cycle')

    def test_markdown_renders_without_literal_markers(self):
        self.run_wire('markdown-turn')

    def test_credential_rotation(self):
        self.run_wire('identity')

    def test_rotation_after_bootstrap(self):
        self.run_wire('before-open')

    def test_settings_recovers_after_account_switch(self):
        self.run_wire('settings-switch')

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

    def test_native_send_distinguishes_busy_goal_refusal_and_another_receipt(self):
        key = 'fd1bb40a-51e4-47c7-a55d-5b0cae729598'
        for code, payload, expected in [
                (409, {'id': key, 'message_accepted': False, 'error': 'local_run_busy'}, 2),
                (400, {'error': 'remote_goal_followup_unsupported'}, 4),
                (200, {'id': 'another-receipt'}, 1),
                (200, {'id': key, 'message_accepted': True}, 0)]:
            with self.subTest(code=code, payload=payload), patch.object(live, 'Connection') as factory:
                conn = factory.return_value
                conn.binding = 'bound'
                if code == 200:
                    conn.request.return_value = payload
                else:
                    conn.request.side_effect = live.urllib.error.HTTPError('http://localhost', code, '', {},
                                                                           io.BytesIO(json.dumps(payload).encode()))
                with patch.object(sys, 'stdin', io.TextIOWrapper(io.BytesIO(b'test message'))):
                    self.assertEqual(live.run_mutation('bound', 'send', 'mission', key), expected)
                self.assertEqual(conn.request.call_args.kwargs['body']['client_message_id'], key)

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
        calls = []
        def retry_page(path):
            calls.append(path)
            if path == query + '&offset=2' and calls.count(path) == 1:
                raise TimeoutError()
            return pages[path]
        with patch.object(connection, 'get', side_effect=retry_page), patch.object(live.time, 'sleep'):
            self.assertEqual(live.roster_rows(connection, expanded=['p'], rules=rules), loaded)
        self.assertEqual(calls.count(query + '&all=true'), 1)
        self.assertEqual(calls.count(query + '&offset=2'), 2)
        pages[query + '&offset=2'] = None
        with self.assertRaises(ValueError):
            live.roster_rows(connection, expanded=['p'], rules=rules)

    def test_project_frame_precedes_unrelated_reads_and_reconciles_removal(self):
        query = '/api/control/missions?project=now&limit=200'
        members = [dict(id=str(i), project='now', status='completed') for i in range(53)]
        members[-1]['tags'] = ['archived']
        pages = {'/api/projects': {'projects': [{'slug': 'now'}]}, query + '&all=true': members,
                 query: members, '/api/control/missions?limit=200&include_ancestors=true': members[:52],
                 '/api/control/missions?status=acknowledged&limit=100': [], '/api/machines': []}
        reads = []
        def get(path):
            reads.append(path)
            time.sleep(0.02)
            return pages[path]
        c = Mock(binding='bound', get=get)
        rules = json.loads((PKG.parents[1] / 'orb/src/projectHistoryRules.json').read_text())
        frames = []
        def publish(rows):
            frames.append((rows, list(reads)))
        full = live.roster_rows(c, True, ['now'], rules, publish)
        early, first_reads = frames.pop()
        self.assertEqual(first_reads, ['/api/projects', query + '&all=true'])
        self.assertEqual([r for r in early if r[0] == 'G'], [r for r in full if r[0] == 'G'])
        self.assertEqual(len([r for r in early if r[0] == 'M']), 53)
        self.assertEqual(next(r for r in early if r[:2] == ('M', '52'))[-1], '1')
        first_cycle = list(reads)
        reads.clear()
        members.pop()
        full = live.roster_rows(c, True, ['now'], rules)
        self.assertEqual(reads, first_cycle)
        self.assertCountEqual(reads, pages.keys() - {query})
        self.assertNotIn('52', next(r for r in full if r[0] == 'G')[2:])
        c.check.side_effect = ValueError('connection changed')
        with self.assertRaises(ValueError):
            live.roster_rows(c, True, ['now'], rules, publish)
        self.assertFalse(frames)

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

    def test_u6a_live_create_ime_send_stop_archive_and_separate_client_read(self):
        """U6a deterministic live-writes E2E against a persistent SQLite mock Core:
        Create with IME/Unicode, Send follow-up with IME/Unicode, refuse busy Archive,
        Stop running turn, Archive, restart mock Core, and verify via a separate Core client."""
        expected_initial = 'Launch U6a 日本語 🚀'
        expected_followup = 'Follow-up café 漢字テスト ✓'
        with tempfile.TemporaryDirectory(prefix='orb-u6a-mock-') as root:
            db_path = Path(root) / 'core.db'

            def init_db():
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
                return conn

            def start_mock_core():
                db = init_db()
                lock = threading.Lock()
                state = {'counter': 0, 'turn1_polls': 0}

                def next_seq(mid):
                    row = db.execute(
                        'SELECT COALESCE(MAX(sequence), 0) FROM mission_events WHERE mission_id=?',
                        (mid,),
                    ).fetchone()
                    return (row[0] or 0) + 1

                def add_event(mid, kind, content, payload_extra=None):
                    seq = next_seq(mid)
                    payload = {'content': content, **(payload_extra or {})}
                    db.execute(
                        'INSERT INTO mission_events(mission_id,seq,sequence,event_type,payload,metadata,content) VALUES(?,?,?,?,?,?,?)',
                        (mid, seq, seq, kind, json.dumps(payload), '{}', content),
                    )
                    db.commit()
                    return seq

                class MockCore(BaseHTTPRequestHandler):
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
                        if self.headers.get('Authorization') != 'Bearer u6a-token':
                            self.reply({'error': 'unauthorized'}, 401)
                            return
                        path = self.path
                        base_path = path.split('?')[0]
                        with lock:
                            if base_path == '/api/auth/me':
                                self.reply({'user': {'username': 'u6a-tester'}})
                                return
                            if base_path == '/api/projects':
                                self.reply({'projects': [{'slug': 'source', 'title': 'Source', 'objective': '', 'color': 'blue'}]})
                                return
                            if base_path == '/api/machines':
                                self.reply([{'id': 'core', 'name': 'orb-core', 'state': 'online', 'status': 'online'}])
                                return
                            if base_path == live.INBOX_PATH:
                                self.reply({'_versions': {}})
                                return
                            if base_path == '/api/control/missions':
                                rows = db.execute('SELECT id,title,status,project,backend,stopped_turns FROM missions').fetchall()
                                self.reply([
                                    dict(id=r[0], title=r[1], status=r[2], project=r[3], backend=r[4], stopped_turns=r[5])
                                    for r in rows
                                ])
                                return
                            if base_path.startswith('/api/control/missions/'):
                                rest = base_path.removeprefix('/api/control/missions/')
                                parts = rest.split('/')
                                mid = parts[0]
                                row = db.execute(
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
                                    ev_rows = db.execute(
                                        'SELECT id,sequence,event_type,content FROM mission_events WHERE mission_id=? ORDER BY sequence ASC, id ASC',
                                        (mid,),
                                    ).fetchall()
                                    self.reply([
                                        dict(id=e[0], mission_id=mid, sequence=e[1], event_type=e[2], content=e[3])
                                        for e in ev_rows
                                    ])
                                    return
                                if sub == 'open':
                                    ev_rows = db.execute(
                                        'SELECT id,sequence,event_type,content FROM mission_events WHERE mission_id=? ORDER BY sequence ASC, id ASC',
                                        (mid,),
                                    ).fetchall()
                                    events = [
                                        dict(id=e[0], mission_id=mid, sequence=e[1], event_type=e[2], content=e[3])
                                        for e in ev_rows
                                    ]
                                    self.reply(dict(
                                        protocol=1, mission=dict(id=mid), events=events, spine=[],
                                        queue=[], max_seq=events[-1]['sequence'] if events else 0,
                                        has_more=False, spine_has_more=False, spine_next_cursor=None,
                                        next_cursor=None, page_max_seq=None, reset=False,
                                    ))
                                    return
                                if sub == 'current-bubble':
                                    # Deterministic staged assistant turn progression on poll:
                                    # after Create, complete Turn 1 so the UI transitions to awaiting_user.
                                    if row[2] == 'active' and not db.execute(
                                        "SELECT 1 FROM mission_events WHERE mission_id=? AND event_type='assistant_message'",
                                        (mid,),
                                    ).fetchone():
                                        state['turn1_polls'] += 1
                                        if state['turn1_polls'] >= 1:
                                            add_event(mid, 'assistant_message', 'Turn 1 reply', {'queued': False})
                                            db.execute("UPDATE missions SET status='awaiting_user' WHERE id=?", (mid,))
                                            db.commit()
                                    # After follow-up user_message (seq >= 3), stream Turn 2 while staying active.
                                    user_count = db.execute(
                                        "SELECT COUNT(*) FROM mission_events WHERE mission_id=? AND event_type='user_message'",
                                        (mid,),
                                    ).fetchone()[0]
                                    if row[2] == 'active' and user_count >= 2 and not db.execute(
                                        "SELECT 1 FROM mission_events WHERE mission_id=? AND event_type='text_delta'",
                                        (mid,),
                                    ).fetchone():
                                        add_event(mid, 'text_delta', 'Turn 2 streaming...', {'queued': False})
                                    qrow = db.execute(
                                        QUERY, {'1': mid, '2': '0', '3': 'owner', '4': '0'},
                                    ).fetchone()
                                    if not qrow:
                                        self.reply({'error': 'not_found'}, 404)
                                        return
                                    self.reply(dict(id=mid, title=qrow[0], status=qrow[1], text=qrow[2]))
                                    return
                            self.reply({'error': 'not_found'}, 404)

                    def do_POST(self):
                        if self.headers.get('Authorization') != 'Bearer u6a-token':
                            self.reply({'error': 'unauthorized'}, 401)
                            return
                        data = self.read_json()
                        with lock:
                            if self.path == '/api/control/missions':
                                state['counter'] += 1
                                mid = f"m-u6a-{state['counter']}"
                                prompt = data.get('prompt', '')
                                title = data.get('title') or 'New mission'
                                project = data.get('project') or ''
                                backend = data.get('backend') or 'codex'
                                db.execute(
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
                                row = db.execute('SELECT status FROM missions WHERE id=?', (mid,)).fetchone()
                                if not row:
                                    self.reply({'error': 'not_found'}, 404)
                                    return
                                if not db.execute('SELECT 1 FROM seen_messages WHERE client_message_id=?', (cid,)).fetchone():
                                    db.execute('INSERT INTO seen_messages VALUES(?,?)', (cid, mid))
                                    add_event(mid, 'user_message', content, {'queued': False})
                                    db.execute("UPDATE missions SET status='active' WHERE id=?", (mid,))
                                    db.commit()
                                self.reply({'id': cid, 'message_accepted': True})
                                return
                            if self.path.startswith('/api/control/missions/') and self.path.endswith('/cancel'):
                                mid = self.path.removeprefix('/api/control/missions/').removesuffix('/cancel')
                                row = db.execute('SELECT status FROM missions WHERE id=?', (mid,)).fetchone()
                                if not row:
                                    self.reply({'error': 'not_found'}, 404)
                                    return
                                db.execute(
                                    "UPDATE missions SET status='interrupted', stopped_turns=stopped_turns+1 WHERE id=?",
                                    (mid,),
                                )
                                add_event(mid, 'turn_stopped', 'stopped by user', {'queued': False})
                                self.reply({'ok': True, 'status': 'interrupted'})
                                return
                            if self.path.startswith('/api/control/missions/') and self.path.endswith('/status'):
                                mid = self.path.removeprefix('/api/control/missions/').removesuffix('/status')
                                row = db.execute('SELECT status FROM missions WHERE id=?', (mid,)).fetchone()
                                if not row:
                                    self.reply({'error': 'not_found'}, 404)
                                    return
                                if data.get('status') == 'acknowledged' and row[0] == 'active':
                                    self.reply({'error': 'mission_running'}, 409)
                                    return
                                db.execute('UPDATE missions SET status=? WHERE id=?', (data['status'], mid))
                                db.commit()
                                self.reply({'ok': True, 'status': data['status']})
                                return
                            self.reply({'error': 'not_found'}, 404)

                    def log_message(self, *_):
                        pass

                server = ThreadingHTTPServer(('127.0.0.1', 0), MockCore)
                threading.Thread(target=server.serve_forever, daemon=True).start()
                return server, db

            # Phase 1: run LeanUI live-writes client against the mock Core server.
            server1, db1 = start_mock_core()
            try:
                url1 = f'http://127.0.0.1:{server1.server_port}'
                (Path(root) / 'connection.json').write_text(json.dumps(dict(api_url=url1, token='u6a-token')))
                subprocess.run(
                    ['lean', '-j', '1', '-M', '1024', '--run', 'tests/LiveDelivery.lean', 'u6a-live-writes'],
                    cwd=PKG,
                    env={**os.environ, 'ORB_STATE_DIR': root},
                    check=True,
                    timeout=45,
                )
            finally:
                server1.shutdown()
                server1.server_close()
                db1.close()

            created_id = (Path(root) / 'u6a-created-id').read_text().strip()
            self.assertEqual(created_id, 'm-u6a-1')

            # Phase 2: restart mock Core on the same SQLite DB and verify via a SEPARATE Core HTTP client.
            server2, db2 = start_mock_core()
            try:
                def independent_client_get(path):
                    req = live.urllib.request.Request(
                        f'http://127.0.0.1:{server2.server_port}' + path,
                        headers={'Authorization': 'Bearer u6a-token', 'Accept': 'application/json'},
                    )
                    with live.urllib.request.urlopen(req, timeout=5) as resp:
                        return json.load(resp)

                mission = independent_client_get(f'/api/control/missions/{created_id}')
                self.assertEqual(mission['id'], created_id)
                self.assertEqual(mission['status'], 'acknowledged')
                self.assertEqual(mission['stopped_turns'], 1)

                events = independent_client_get(f'/api/control/missions/{created_id}/events')
                user_messages = [e['content'] for e in events if e['event_type'] == 'user_message']
                stopped_events = [e for e in events if e['event_type'] == 'turn_stopped']
                self.assertEqual(user_messages, [expected_initial, expected_followup])
                self.assertEqual(len(stopped_events), 1)
            finally:
                server2.shutdown()
                server2.server_close()
                db2.close()

    def test_sql_bounds_current_text_and_scopes_reader(self):
        with contextlib.closing(fixture()) as db:
            db.execute("DELETE FROM mission_events WHERE event_type='assistant_message_canonical'")
            self.assertEqual(db.execute(QUERY, {'1':'a','2':'0','3':'owner','4':'0'}).fetchone()[2], 'X' * 65537)
            self.assertEqual(db.execute(QUERY, {'1':'a','2':'0','3':'owner','4':'1'}).fetchone()[2], '')
            self.assertIsNone(db.execute(QUERY, {'1':'a','2':'0','3':'other','4':'1'}).fetchone())


if __name__ == '__main__':
    unittest.main()
