"""Forward desktop traffic to disposable Core, losing a successful Send reply."""
from contextlib import contextmanager
from http.client import HTTPConnection
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import threading


@contextmanager
def proxy(port):
    attempts = []

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def forward(self):
            data = self.rfile.read(int(self.headers.get('Content-Length', 0)))
            upstream = HTTPConnection('127.0.0.1', port, timeout=8)
            try:
                upstream.request(self.command, self.path, data or None, dict(self.headers))
                response = upstream.getresponse()
                payload = response.read()
                if self.command == 'POST' and self.path == '/api/control/message' and response.status == 200:
                    attempts.append(json.loads(data)['client_message_id'])
                    if len(attempts) == 1:
                        return  # no headers or body reach the desktop
                self.send_response(response.status)
                self.send_header('Content-Length', str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)
            finally:
                upstream.close()

        do_GET = do_POST = forward

    with ThreadingHTTPServer(('127.0.0.1', 0), Handler) as server:
        thread = threading.Thread(target=server.serve_forever)
        thread.start()
        try:
            yield f'http://127.0.0.1:{server.server_port}', attempts
        finally:
            server.shutdown()
            thread.join()
