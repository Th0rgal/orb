"""Run the installed Linux clients on a private Sway compositor.

python3 lean/OrbDesktop/tests/account_handoff.py
ORB_LEANUI_TEST_BINARY can point at a built orb-desktop-native. In that case
ORB_ACCOUNT_LAUNCHER selects the packaged launcher that accepts --webkit.
Requires sway and wtype. All accounts, credentials and Core responses are fixtures.
"""
import contextlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import secrets
import subprocess
import tempfile
import threading
import time

from live_writes import process, wait


def main():
    password = secrets.token_urlsafe(24)
    expired = threading.Event()
    form_ready = threading.Event()
    signed_in = threading.Event()
    recovered = threading.Event()

    class Core(BaseHTTPRequestHandler):
        def reply(self, data, status=200):
            self.send_response(status)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Access-Control-Allow-Origin', self.headers.get('Origin', '*'))
            self.send_header('Access-Control-Allow-Headers', '*')
            self.end_headers()
            self.wfile.write(json.dumps(data).encode())

        def do_OPTIONS(self):
            self.reply({})

        def do_GET(self):
            agent = self.headers.get('User-Agent', '')
            if self.path == '/api/health':
                if 'AppleWebKit' in agent:
                    form_ready.set()
                return self.reply({'auth_required': True, 'auth_mode': 'multi_user'})
            if self.headers.get('Authorization') != 'Bearer replacement-fixture':
                if self.path == '/api/projects':
                    expired.set()
                return self.reply({}, 401)
            if self.path in ('/api/auth/me', '/api/auth/status'):
                if self.path == '/api/auth/me' and 'Python' in agent:
                    recovered.set()
                return self.reply({'user': {'id': 'ben', 'username': 'Ben', 'role': 'member'},
                                   'authenticated': True, 'auth_required': True, 'auth_mode': 'multi_user'})
            if self.path == '/api/projects':
                return self.reply({'projects': []})
            self.reply({} if self.path == '/api/control/inbox-state' else [])

        def do_POST(self):
            if self.path != '/api/auth/login':
                return self.reply({}, 404)
            login = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
            if login != {'username': 'Ben', 'password': password}:
                return self.reply({}, 401)
            signed_in.set()
            self.reply({'token': 'replacement-fixture'})

        def log_message(self, *_):
            pass

    with tempfile.TemporaryDirectory() as folder, ThreadingHTTPServer(('127.0.0.1', 0), Core) as server:
        tmp = Path(folder)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        with contextlib.ExitStack() as stack:
            stack.callback(server.shutdown)
            state = tmp / 'connection.json'
            endpoint = f'http://127.0.0.1:{server.server_port}'
            state.write_text(json.dumps({'api_url': endpoint, 'token': 'expired-fixture'}))
            config = tmp / 'sway.conf'
            config.write_text('output * mode 1000x700\nxwayland disable\n')
            env = dict(os.environ, HOME=folder, XDG_RUNTIME_DIR=folder, ORB_STATE_DIR=folder,
                       XDG_CONFIG_HOME=str(tmp / 'config'), XDG_DATA_HOME=str(tmp / 'data'),
                       XDG_CACHE_HOME=str(tmp / 'cache'),
                       WLR_BACKENDS='headless', WLR_RENDERER='pixman', WLR_LIBINPUT_NO_DEVICES='1')
            stack.enter_context(process(['sway', '-c', config], env, tmp))
            env['WAYLAND_DISPLAY'] = wait('Sway', lambda: next((p.name for p in tmp.glob('wayland-*') if p.is_socket()), None))
            binary = os.environ.get('ORB_LEANUI_TEST_BINARY')
            stack.enter_context(process([binary] if binary else ['orb-desktop', '--leanui'], env, tmp))
            assert expired.wait(15), 'native client did not attempt the expired connection'
            # Keep a virtual keyboard present while wtype sends individual events.
            stack.enter_context(process(['wtype', '-k', 'Shift_L', '-s', '60000'], env, tmp))
            time.sleep(0.8)

            def keys(*args):
                subprocess.run(['wtype', *args], env=env, check=True)

            keys('-M', 'ctrl', '-k', 'comma', '-m', 'ctrl', '-s', '400', '-k', 'Return')
            assert form_ready.wait(20), 'account form did not probe the fixture Core'
            keys('-s', '700', '-k', 'Tab', '-k', 'Tab')
            subprocess.run(['wtype', '-'], input=b'Ben', env=env, check=True)
            keys('-k', 'Tab')
            subprocess.run(['wtype', '-'], input=password.encode(), env=env, check=True)
            keys('-k', 'Return')
            assert signed_in.wait(10), 'Core did not receive the expected multi-user login'
            assert recovered.wait(30), 'native client did not read the new authenticated identity'
            assert json.loads(state.read_text()) == {'api_url': endpoint, 'token': 'replacement-fixture'}
    print('Native Settings keyboard handoff, shared sign-in, and native recovery passed.')


if __name__ == '__main__':
    main()
