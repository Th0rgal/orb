"""Replay the Cloud destination with a loopback Core and a synthetic binding."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import unittest


class CloudDestination(unittest.TestCase):
    def test_cloud_destination(self):
        requests = []
        accounts = [
            dict(id='cursor', provider='cursor_cloud', label='Team', available=True,
                 capabilities=dict(follow_up=True, cancel=True)),
            dict(id='grok', provider='grok_bot', label='Trial', available=False, reason='Reconnect'),
        ]

        class Core(BaseHTTPRequestHandler):
            def reply(self, payload, status=200):
                self.send_response(status)
                self.end_headers()
                self.wfile.write(json.dumps(payload).encode())

            def do_GET(self):
                nonlocal fail, stopped, fail_send
                requests.append(('GET', self.path, self.headers.get('Authorization')))
                if self.path.startswith('/api/control/missions?'):
                    fail, stopped, fail_send = True, False, True
                    rows = [dict(id='plain', backend='codex', title='Local'),
                            dict(id='proof', backend='cloud_cursor', title='Cloud proof')]
                    self.reply([] if empty else rows)
                elif self.path == '/api/cloud/accounts':
                    if fail and not empty:
                        fail = False
                        self.reply({}, 503)
                    else:
                        self.reply([] if empty else accounts)
                elif self.path == '/api/control/missions/proof/cloud':
                    self.reply(dict(mission_id='proof', selection=dict(provider='cursor_cloud', account='cursor'),
                                    turns=[dict(prompt='Prove one plus one', result='Two.', external_id='turn',
                                                phase='reconnect_required' if stopped else 'running')]))
                elif self.path == '/api/projects':
                    self.reply(dict(projects=[dict(slug='demo', title='Demo')]))
                elif self.path == '/api/control/inbox-state':
                    self.reply({})
                else:
                    self.reply([])

            def do_POST(self):
                nonlocal stopped, fail_send
                body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                requests.append(('POST', self.path, self.headers.get('Authorization'), body))
                if self.path == '/api/control/message' and fail_send:
                    fail_send = False
                    self.reply({}, 503)
                    return
                if self.path == '/api/control/missions':
                    self.reply(dict(id='new-proof'))
                    return
                if self.path == '/api/control/missions/proof/cloud/cancel':
                    stopped = True
                self.reply(dict(message_accepted=True))

            def log_message(self, *_):
                pass

        with ThreadingHTTPServer(('127.0.0.1', 0), Core) as server, tempfile.TemporaryDirectory() as root:
            threading.Thread(target=server.serve_forever, daemon=True).start()
            (Path(root) / 'connection.json').write_text(json.dumps(
                dict(api_url=f'http://127.0.0.1:{server.server_port}', token='fixture')))
            fail, stopped, fail_send = False, False, False
            for empty in [True, False]:
                subprocess.run(['lean', '--run', 'tests/CloudDestination.lean', 'empty' if empty else 'active'],
                               cwd=Path(__file__).resolve().parents[1], check=True, timeout=60,
                               env={**os.environ, 'ORB_STATE_DIR': root})
            server.shutdown()
        self.assertTrue(all(r[2] == 'Bearer fixture' for r in requests))
        writes = [r for r in requests if r[0] == 'POST']
        self.assertEqual([r[1] for r in writes], ['/api/control/missions', '/api/control/message', '/api/control/message', '/api/control/missions/proof/cloud/cancel'] * 2)
        for launch in writes[::4]:
            self.assertEqual(launch[3]['cloud'], dict(provider='cursor_cloud', account='cursor'))
            self.assertEqual((launch[3]['project'], launch[3]['prompt']), ('demo', 'Fixture task'))
        for failed, send in zip(writes[1::4], writes[2::4]):
            self.assertEqual(failed[3], send[3])
            self.assertEqual((send[3]['mission_id'], send[3]['content']), ('proof', 'why?'))
            self.assertTrue(send[3]['client_message_id'])


if __name__ == '__main__':
    unittest.main()
