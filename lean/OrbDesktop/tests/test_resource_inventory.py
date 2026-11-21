"""Run the embedded reader and native views against a loopback-only Core fixture."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import unittest


class ResourceInventory(unittest.TestCase):
    def test_native_overview(self):
        missions = [dict(id=k, title=k.upper(), status='active', vcpu=2, b_tok_per_h=0.5)
                    for k in 'abc']
        populated = dict(inference=dict(pools=[dict(label='Pool', current_b_tok_per_h=0,
                                                    est_usd_per_h=0)]),
                         compute=dict(sources=[dict(label='Node', active_vcpu=2, total_vcpu=8,
                                                    est_usd_per_h=1.5)]), missions=missions)
        empty = dict(inference=dict(pools=[]), compute=dict(sources=[]), missions=[])
        reads = []

        class Core(BaseHTTPRequestHandler):
            def do_GET(self):
                if self.path.startswith('/api/resources/overview?'):
                    reads.append((self.path, self.headers['Authorization']))
                    body = overview
                elif self.path.startswith('/api/control/missions?limit='):
                    body = missions
                elif self.path == '/api/control/inbox-state':
                    body = {}
                elif self.path == '/api/projects':
                    body = dict(projects=[])
                else:
                    body = []
                self.send_response(200)
                self.end_headers()
                self.wfile.write(json.dumps(body).encode())

            def log_message(self, *_):
                pass

        with ThreadingHTTPServer(('127.0.0.1', 0), Core) as server, tempfile.TemporaryDirectory() as root:
            threading.Thread(target=server.serve_forever, daemon=True).start()
            (Path(root) / 'connection.json').write_text(json.dumps(
                dict(api_url=f'http://127.0.0.1:{server.server_port}', token='fixture')))
            for mode, overview in [('populated', populated), ('empty', empty), ('failed', {})]:
                with self.subTest(mode=mode):
                    subprocess.run(['lean', '--run', 'tests/ResourceInventory.lean', mode],
                                   cwd=Path(__file__).resolve().parents[1], check=True, timeout=30,
                                   env={**os.environ, 'ORB_STATE_DIR': root})
            self.assertEqual(reads, [(f'/api/resources/overview?range={window}', 'Bearer fixture')
                                     for window in ['6h', '30m'] * 6])
            server.shutdown()


if __name__ == '__main__':
    unittest.main()
