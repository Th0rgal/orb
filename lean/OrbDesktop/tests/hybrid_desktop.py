"""Drive Classic and the embedded LeanUI sidebar against one disposable member account.

Build orb-locald, orb-desktop-native, linux_shell/{orb-desktop,orb-sidebar-host.so} and
orb/dist. Requires the Sway, grim, OCR and virtual input tools used by live_writes.py.
ORB_WEBKIT_TEST_BINARY and ORB_HYBRID_TEST_BINARY can point to packaged launchers.
"""
import contextlib
import json
import os
import shutil
import socket
import subprocess
import tempfile
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

from live_writes import ROOT, process, wait
from wayland_ocr import read_words
from wayland_pointer import Pointer


MISSIONS = [dict(id=f'aaaaaaaa-0000-4000-8000-00000000000{i}', title=title, project='orchard',
                 backend='codex', status=status, history=[], created_at='2026-10-01T10:00:00Z',
                 updated_at='2026-10-01T11:00:00Z') for i, (title, status) in enumerate([('Copper', 'awaiting_user'), ('Plum', 'completed')])]
PROVIDER = dict(provider='boat', display_name='Indigo Fleet', configured=True, enabled=True,
                user_enabled=True, sizes=[], effective_enabled=True)
TOKEN = 'fixture-member'


class Fixture(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def end_headers(self):
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Headers', '*')
        self.send_header('Access-Control-Expose-Headers', '*')
        super().end_headers()

    def do_OPTIONS(self):
        self.send_response(204)
        self.end_headers()

    def do_GET(self):
        url = urlsplit(self.path)
        path = url.path
        if path == '/observe':
            self.server.observed = json.loads(parse_qs(url.query)['state'][0])
            self.send_response(204)
            self.end_headers()
            return
        if self.headers.get('Authorization') != 'Bearer ' + TOKEN:
            self.send_error(401)
            return
        self.server.reads.add(path)
        body = {}
        headers = {}
        if path == '/api/auth/me':
            body = dict(auth_mode='multi_user', user=dict(id='member', username='member', role='member'))
        elif path == '/api/projects':
            body = dict(projects=[dict(slug='orchard', title='Orchard')])
        elif path in ('/api/control/missions', '/api/projects/orchard/missions'):
            body = [] if parse_qs(url.query).get('status') == ['acknowledged'] else MISSIONS
        elif path.startswith('/api/control/missions/'):
            mid = path.split('/')[4]
            mission = next((m for m in MISSIONS if m['id'] == mid), {})
            if path.endswith(('/events', '/open', '/snapshot')):
                turns = ['Inspect the orchard', 'Amber blossom', 'Check again', 'Violet harvest'] if mission == MISSIONS[0] else ['Second project mission', 'Plum harvest']
                body = [dict(id=i, sequence=i, event_id=f'e{i}', event_type='user_message' if i % 2 else 'assistant_message',
                             timestamp=f'2026-10-01T10:0{i}:00Z', content=t) for i, t in enumerate(turns, 1)]
                headers = {'X-Orb-Events-Protocol': '1', 'X-Has-More': 'false', 'X-Max-Sequence': str(len(body))}
                if path.endswith('/snapshot'):
                    body = dict(profile='presentation', events=body[-1:], revision=len(body))
                elif path.endswith('/open'):
                    since = int(parse_qs(url.query).get('since_seq', [0])[0])
                    body = dict(protocol=1, mission=mission, events=body[since:], spine=body, queue=[],
                                max_seq=len(body), has_more=False, page_max_seq=len(body))
            elif path.count('/') == 4:
                body = mission
        elif path == '/api/managed-machines':
            body = dict(enabled=True, machines=[], sizes=[], providers=[PROVIDER],
                        budget=dict(active=0, max_concurrent=2, spent_today_usd=0, daily_cap_usd=10))
        elif path == '/api/managed-machines/providers':
            body = dict(providers=[PROVIDER])
        elif path == '/api/remote-nodes':
            body = dict(nodes=[])
        elif path.endswith('/files'):
            body = dict(entries=[])
        elif path == '/api/providers/backend-models':
            body = dict(backends={})
        elif path in ('/api/backends', '/api/model-routing/chains') or path.endswith('/queue'):
            body = []
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        for k, v in headers.items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(json.dumps(body).encode())


# Read the mounted production components. All input comes from the compositor.
PROBE = """
let previous = '';
setInterval(() => {
  const visible = selector => !!document.querySelector(selector)?.getClientRects().length;
  const editor = document.querySelector('.new-agent textarea');
  const rect = editor?.getBoundingClientRect();
  const conversation = [...document.querySelectorAll('main .scroll')].filter(el => el.getClientRects().length).map(el => el.innerText).join(' ');
  const state = JSON.stringify({
    native: window.__ORB_NATIVE_CHROME__ === true && typeof window.__ORB_NATIVE_NAV__ === "function",
    heading: document.querySelector('.tb-title')?.innerText,
    newAgent: visible('.new-agent'), settings: visible('.settings-body'),
    local: visible('.local-machine button') && document.querySelector('.local-machine').innerText.includes('This computer'),
    personal: visible('[role=switch][aria-label="Use Indigo Fleet for my missions"]:enabled'),
    global: visible('[role=switch][aria-label="Enable Indigo Fleet globally"]'),
    rawAwaiting: document.querySelector('main')?.innerText.includes('awaiting_user'),
    earlier: conversation.includes('Amber blossom'), latest: conversation.includes('Violet harvest'),
    plum: conversation.includes('Plum harvest'), search: visible('[data-testid=conversation-search-dialog]'),
    width: innerWidth, editor: rect?.width ? [rect.x+rect.width/2,rect.y+rect.height/2] : null,
    typing: document.activeElement === editor && editor?.value.includes('Native focus')
  });
  if (previous !== state) { previous = state; new Image().src = ENDPOINT + '?state=' + encodeURIComponent(state); }
}, 80);
"""


def run():
    with tempfile.TemporaryDirectory() as directory, contextlib.ExitStack() as stack:
        tmp = Path(directory)
        http = stack.enter_context(ThreadingHTTPServer(('127.0.0.1', 0), Fixture))
        http.observed, http.reads = {}, set()
        threading.Thread(target=http.serve_forever, daemon=True).start()
        stack.callback(http.shutdown)
        base = 'http://127.0.0.1:' + str(http.server_port)
        dist = tmp/'dist'
        shutil.copytree(os.environ.get('ORB_DIST_DIR', ROOT/'orb/dist'), dist)
        index = dist/'index.html'
        index.chmod(0o600)  # The copied Nix store file is read-only.
        with index.open('a') as html:
            html.write('<script>' + PROBE.replace('ENDPOINT', json.dumps(base+'/observe')) + '</script>')
        (tmp/'connection.json').write_text(json.dumps(dict(api_url=base, token=TOKEN)))
        env = dict(os.environ, HOME=directory, XDG_RUNTIME_DIR=directory, XDG_DATA_HOME=str(tmp/'data'),
                   XDG_CACHE_HOME=str(tmp/'cache'), XDG_CONFIG_HOME=str(tmp/'config'), ORB_STATE_DIR=directory,
                   GDK_BACKEND='wayland', ORB_NATIVE_CHROME='1', ORB_DIST_DIR=str(dist),
                   ORB_LOCALD_TOKEN='isolated-desktop-fixture-000000000000', ORB_LOCALD_BIN=os.environ.get('ORB_LOCALD_BIN', str(ROOT/'target/debug/orb-locald')),
                   WLR_BACKENDS='headless', WLR_RENDERER='pixman', WLR_LIBINPUT_NO_DEVICES='1')
        env.pop('ORB_DEV_URL', None)
        (tmp/'sway.conf').write_text('output * mode 1000x700\ndefault_border none\nxwayland disable\n')
        stack.enter_context(process(['sway', '-c', tmp/'sway.conf'], env, tmp))
        env['WAYLAND_DISPLAY'] = wait('private Wayland display', lambda: next((p.name for p in tmp.glob('wayland-*') if p.is_socket()), None))
        env['SWAYSOCK'] = str(wait('private Sway IPC', lambda: next(tmp.glob('sway-ipc.*.sock'), None)))
        pointer = Pointer(env)
        stack.callback(pointer.close)
        stack.enter_context(process(['wtype', '-k', 'Shift_L', '-s', '120000'], env, tmp))
        for mode in ['classic', 'hybrid']:
            cmd = [os.environ.get('ORB_WEBKIT_TEST_BINARY', ROOT/'linux_shell/orb-desktop')] if mode == 'classic' else (
                [os.environ['ORB_HYBRID_TEST_BINARY']] if 'ORB_HYBRID_TEST_BINARY' in os.environ else
                [ROOT/'target/debug/orb-desktop-native', '--gtk-sidebar-host', ROOT/'linux_shell/orb-sidebar-host.so'])
            with socket.socket() as port:
                port.bind(('127.0.0.1', 0))
                env['ORB_LOCALD_PORT'] = str(port.getsockname()[1])
            http.observed = {}
            http.reads.clear()
            with process(cmd, env, tmp) as client:
                def check(label, predicate):
                    def poll():
                        if client.poll() is not None:
                            raise RuntimeError(f'{mode} exited with {client.returncode}')
                        return predicate()
                    try:
                        return wait(mode + ' ' + label, poll)
                    except TimeoutError as error:
                        if os.environ.get('ORB_TEST_SCREENSHOT'):
                            subprocess.run(['grim', os.environ['ORB_TEST_SCREENSHOT']], env=env, check=True)
                        raise AssertionError(f'{error}: {http.observed}, sidebar={list(words())}, reads={sorted(http.reads)}') from error

                def see(field):
                    check(field, lambda: http.observed.get(field))

                def projection():
                    request = urllib.request.Request('http://127.0.0.1:' + env['ORB_LOCALD_PORT'] + '/__orb_rpc',
                        data=b'{"command":"native_chrome_get_rows","args":{}}',
                        headers={'X-Orb-Token':env['ORB_LOCALD_TOKEN'], 'Content-Type':'application/json'})
                    with urllib.request.urlopen(request, timeout=2) as response:
                        return json.load(response)['result']

                def row(label):
                    return next((r for r in projection()['rows'] if r['title'].lower() == label), None)

                def words():
                    pointer.move(750, 650)
                    time.sleep(.1)
                    area = '0,30 219x670'
                    image = subprocess.check_output(['grim', '-t', 'ppm', '-g', area, '-'], env=env)
                    return {word: (x, y) for word, x, y in read_words(image, area)}

                def click(word):
                    pointer.click(*check('sidebar ' + word, lambda: words().get(word)))

                see('native')
                check('Machines in the shared sidebar projection', lambda: row('machines'))
                click('machines')
                see('local')
                see('personal')
                check('selected Machines row', lambda: (row('machines') or {}).get('selected'))
                assert not http.observed['global']
                click('settings')
                see('settings')
                check('selected Settings footer', lambda: projection()['footer']['selected'])
                click('back')
                if not check('project', lambda: row('orchard'))['expanded']:
                    click('orchard')
                if mode == 'hybrid':
                    check('expanded project', lambda: row('orchard')['expanded'])
                    click('orchard')
                    check('collapsed project with native focus', lambda: not row('orchard')['expanded'])
                    subprocess.run(['wtype', '-k', 'Return'], env=env, check=True)
                    check('keyboard project activation', lambda: row('orchard')['expanded'])
                    subprocess.run(['wtype','-M','ctrl','-M','shift','-k','f','-m','shift','-m','ctrl'], env=env, check=True)
                    see('search')
                    subprocess.run(['wtype', '-k', 'Escape'], env=env, check=True)
                click('copper')
                see('earlier')
                see('latest')
                check('selected first mission', lambda: (row('copper') or {}).get('selected'))
                click('plum')
                see('plum')
                check('selected second mission', lambda: (row('plum') or {}).get('selected'))
                assert not http.observed['earlier']
                click('copper')
                see('earlier')
                see('latest')
                check('reopened waiting mission', lambda: (row('copper') or {}).get('selected'))
                assert http.observed['rawAwaiting'] is False
                click('new')
                see('newAgent')
                check('selected New Agent row', lambda: (row('new agent') or {}).get('selected'))
                x, y = check('composer', lambda: http.observed.get('editor'))
                pointer.click(round(1000 - http.observed['width'] + x), round(y))
                subprocess.run(['wtype', 'Native focus'], env=env, check=True)
                see('typing')
                subprocess.run(['wtype','-M','ctrl','-M','shift','-k','f','-m','shift','-m','ctrl'], env=env, check=True)
                see('search')
                subprocess.run(['wtype', '-k', 'Escape'], env=env, check=True)
                if mode == 'hybrid':
                    before = http.observed['width']
                    divider = 1000 - before - 1
                    pointer.drag((divider, 440), (divider + 90, 440))
                    check('resized WebKit pane', lambda: http.observed['width'] < before - 50)
                    click('machines')
                    see('personal')
                tree = json.loads(subprocess.check_output(['swaymsg','-rt','get_tree'], env=env))
                def windows(node):
                    return int(node.get('app_id') == 'orb-desktop') + sum(windows(n) for n in node['nodes']+node['floating_nodes'])
                assert windows(tree) == 1
                assert '/api/control/missions/' + MISSIONS[0]['id'] + '/open' in http.reads
                print(mode, 'passed account, provider controls, both missions, earlier turns, settings, new agent and search', flush=True)


if __name__ == '__main__':
    run()
