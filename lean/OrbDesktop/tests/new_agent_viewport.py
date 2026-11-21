"""Replay native New Agent input in private headless Sway. Pass the native executable."""
from contextlib import ExitStack, closing
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading

from live_writes import process, wait
from wayland_ime import session
from wayland_pointer import Pointer


def replay(binary, tmp, stack):
    submissions = []

    class Roster(BaseHTTPRequestHandler):
        def reply(self, data):
            self.send_response(200)
            self.end_headers()
            self.wfile.write(json.dumps(data).encode())

        def do_GET(self):
            if self.path == '/api/auth/me':
                if self.headers.get('Authorization') != 'Bearer fixture':
                    return self.send_error(401)
                self.reply({'user': {'username': 'fixture', 'role': 'member'}})
            elif self.path == '/api/projects':
                self.reply({'projects': []})
            elif self.path.startswith('/api/control/missions?') or self.path == '/api/machines':
                self.reply([])
            else:
                self.send_error(404)

        def do_POST(self):
            if self.path != '/api/control/missions':
                return self.send_error(404)
            submissions.append(json.loads(self.rfile.read(int(self.headers['Content-Length'])))['prompt'])
            self.reply({'id': 'fixture', 'status': 'active'})

        def log_message(self, *args):
            pass

    server = stack.enter_context(ThreadingHTTPServer(('127.0.0.1', 0), Roster))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    stack.callback(server.shutdown)
    (tmp / 'connection.json').write_text(json.dumps({
        'api_url': f'http://127.0.0.1:{server.server_port}', 'token': 'fixture'}))
    config = tmp / 'sway.conf'
    config.write_text('output * mode 1000x700\ndefault_border none\nxwayland disable\n')
    env = dict(os.environ, HOME=str(tmp), ORB_STATE_DIR=str(tmp), XDG_RUNTIME_DIR=str(tmp),
               WLR_BACKENDS='headless', WLR_RENDERER='pixman', WLR_LIBINPUT_NO_DEVICES='1')
    stack.enter_context(process(['sway', '-c', config], env, tmp))
    env['WAYLAND_DISPLAY'] = wait('private compositor', lambda: next(
        (p.name for p in tmp.glob('wayland-*') if p.is_socket()), None))
    env['SWAYSOCK'] = str(wait('sway IPC', lambda: next(tmp.glob('sway-ipc.*.sock'), None)))
    stack.enter_context(process([binary], env, tmp))
    wait('native window', lambda: b'"orb-desktop"' in subprocess.check_output(
        ['swaymsg', '-r', '-t', 'get_tree'], env=env))
    stack.enter_context(process(['wtype', '-k', 'Shift_L', '-s', '120000'], env, tmp))
    pointer = stack.enter_context(closing(Pointer(env)))

    def keys(key, count=1):
        subprocess.run(['wtype', *(['-k', key, '-s', '20'] * count)], check=True, env=env)

    def pixels(region='335,306 290x80'):
        return subprocess.check_output(['grim', '-t', 'ppm', '-g', region, '-'], env=env)

    # The click must focus the editor through the scroll clip.
    pointer.click(540, 347)
    edit = stack.enter_context(session(env))
    draft = '\n'.join(f'Row {i:02d}' for i in range(1, 21))
    blank = pixels()
    edit([(draft, 0, 0)])
    bottom = wait('20-line draft painted', lambda: (p if (p := pixels()) != blank else None))
    toolbar = pixels('318,466 582x24')
    keys('Up', 20)
    top = wait('Up reveals earlier rows', lambda: (p if (p := pixels()) != bottom else None))
    keys('Down', 20)
    wait('Down returns to last row', lambda: pixels() == bottom)
    pointer.scroll(540, 347, -1000)
    wait('wheel reveals first row', lambda: pixels() == top)
    pointer.scroll(540, 347, 1000)
    wait('wheel returns to last row', lambda: pixels() == bottom)
    pointer.scroll(540, 347, -1000)
    wait('wheel leaves caret offscreen', lambda: pixels() == top)

    assert pixels('318,466 582x24') == toolbar, 'toolbar moved during scroll'

    # Wheel did not move the insertion point. A single paragraph now spans
    # multiple visual rows. Insert a marker one displayed row above its end.
    paragraph = ' office café' * 24
    edit([('\n' + paragraph, 0, 0)])
    keys('Up')
    keys('Down')
    edit([('!', 0, 0)])
    keys('Up')
    edit([('|', 0, 0)])
    keys('Return')
    prompt = wait('native Enter submits draft', lambda: submissions and submissions[0])
    assert prompt.replace('|', '') == draft + '\n' + paragraph + '!', repr(prompt)
    prefix, suffix = prompt.split('|')
    assert prefix.startswith(draft + '\n') and 1 < len(suffix) < len(paragraph), repr(prompt)


if __name__ == '__main__':
    with tempfile.TemporaryDirectory() as work, ExitStack() as resources:
        replay(Path(sys.argv[1]).resolve(strict=True), Path(work), resources)
    print('New Agent Wayland viewport replay passed')
