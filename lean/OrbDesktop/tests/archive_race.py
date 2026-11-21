"""Loopback relay for the packaged Archive test. Only the armed status POST is gated."""
import contextlib
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import select
import threading
from urllib.parse import urlsplit


@contextlib.contextmanager
def archive_relay(upstream_url, mission):
    upstream = urlsplit(upstream_url)
    assert upstream.hostname == '127.0.0.1'
    path = f'/api/control/missions/{mission}/status'
    gate = ArchiveGate()

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def forward(self):
            body = self.rfile.read(int(self.headers.get('Content-Length', 0)))
            headers = {k: v for k, v in self.headers.items() if k.lower() != 'connection'}
            upgrade = self.headers.get('Upgrade')
            headers['Connection'] = 'Upgrade' if upgrade else 'close'
            with contextlib.closing(http.client.HTTPConnection(upstream.hostname, upstream.port)) as core:
                guarded = (self.command == 'POST' and self.path == path and gate.armed.is_set()
                           and json.loads(body).get('status') == 'acknowledged')
                try:
                    if guarded:
                        gate.before()
                    core.request(self.command, self.path, body or None, headers)
                    if guarded:
                        response = core.getresponse()
                        payload = response.read()
                        gate.after(response.status, payload, self.headers.get('Idempotency-Key'))
                        self.send_response_only(response.status)
                        for name, value in response.getheaders():
                            if name.lower() not in {'connection', 'transfer-encoding', 'content-length'}:
                                self.send_header(name, value)
                        self.send_header('Content-Length', str(len(payload)))
                        self.end_headers()
                        self.wfile.write(payload)
                        return
                    # Preserve the wire response, including streaming and upgraded connections.
                    while True:
                        ready, _, _ = select.select([self.connection, core.sock], [], [])
                        for source in ready:
                            packet = source.recv(65536)
                            if not packet:
                                return
                            target = core.sock if source is self.connection else self.connection
                            target.sendall(packet)
                except Exception as exc:
                    if guarded:
                        gate.error = exc
                    elif not isinstance(exc, (BrokenPipeError, ConnectionResetError)):
                        raise
                finally:
                    if guarded:
                        gate.done.set()

        do_GET = do_POST = do_PATCH = do_DELETE = do_OPTIONS = do_PUT = do_HEAD = forward

    with ThreadingHTTPServer(('127.0.0.1', 0), Handler) as server:
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            yield f'http://127.0.0.1:{server.server_port}', gate
        finally:
            server.shutdown()
            thread.join()


class ArchiveGate:
    def __init__(self):
        self.armed = threading.Event()
        self.done = threading.Event()
        self.error = None

    def arm(self, before, after):
        self.before = before
        self.after = after
        self.armed.set()

    def result(self):
        if not self.done.wait(10):
            raise AssertionError('No completed UI Archive POST reached the relay')
        if self.error:
            raise self.error
