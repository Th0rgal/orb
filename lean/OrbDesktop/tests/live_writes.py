"""Run from the checkout: python3 lean/OrbDesktop/tests/live_writes.py

Requires scripts/build_orb_bins.sh --only orb-core, the native desktop build dependencies,
Sway and wtype. Only the external model harness is replaced (a waiting child
process); all mission writes go through the launched desktop and real Core.
"""
import contextlib
import json
import os
from pathlib import Path
import secrets
import signal
import socket
import subprocess
import select
import sys
import tempfile
import time
import urllib.request

import wayland_ime
import lost_reply

ROOT = Path(__file__).resolve().parents[3]


def wait(label, check, seconds=20):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        try:
            result = check()
            if result:
                return result
        except (ConnectionError, urllib.error.URLError):
            pass
        time.sleep(.15)
    raise TimeoutError(label)


@contextlib.contextmanager
def process(args, env, cwd):
    child = subprocess.Popen(args, cwd=cwd, env=env, start_new_session=True)
    try:
        yield child
    finally:
        with contextlib.suppress(ProcessLookupError):
            os.killpg(child.pid, signal.SIGTERM)
        try:
            child.wait(3)
        except subprocess.TimeoutExpired:
            os.killpg(child.pid, signal.SIGKILL)
            child.wait()


def run(tmp, mode):
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0))
        port = s.getsockname()[1]
    base = f'http://127.0.0.1:{port}'
    token = ''

    def api(path, body=None):
        req = urllib.request.Request(base + path, data=None if body is None else json.dumps(body).encode(),
                                     headers={'Content-Type': 'application/json', 'Authorization': 'Bearer ' + token})
        with urllib.request.urlopen(req, timeout=3) as r:
            return json.load(r)

    def login():
        return api('/api/auth/login', {'password': ''})['token']

    home = tmp / 'home'
    home.mkdir()
    harness = tmp / 'codex'
    launches = tmp / 'launches'
    harness.write_text(f'#!/bin/sh\necho $$ >> "{launches}"\nexec sleep 120\n')
    harness.chmod(0o700)
    env = dict(PATH=f'{tmp}:{os.environ["PATH"]}', HOME=str(home), HOST='127.0.0.1', PORT=str(port),
               LD_LIBRARY_PATH=os.getenv('LD_LIBRARY_PATH', ''), WORKING_DIR=str(tmp), DEV_MODE='true')
    core = [ROOT / 'target/release/orb-core']
    with contextlib.ExitStack() as stack:
        server = stack.enter_context(process(core, env, tmp))
        token = wait('disposable Core login', login)
        endpoint, attempts = stack.enter_context(lost_reply.proxy(port)) if mode in ('retry', 'all') else (base, [])
        (tmp / 'connection.json').write_text(json.dumps({'api_url': endpoint, 'token': token}))
        assert api('/api/control/missions') == []
        config = tmp / 'sway.conf'
        config.write_text('output * mode 1000x700\ndefault_border none\nxwayland disable\n')
        graphical = dict(os.environ, XDG_RUNTIME_DIR=str(tmp), WLR_BACKENDS='headless', WLR_RENDERER='pixman',
                         WLR_LIBINPUT_NO_DEVICES='1', ORB_STATE_DIR=str(tmp))
        stack.enter_context(process(['sway', '-c', config], graphical, tmp))
        graphical['WAYLAND_DISPLAY'] = wait('private compositor', lambda: next((p.name for p in tmp.glob('wayland-*') if p.is_socket()), None))
        graphical['SWAYSOCK'] = str(wait('sway IPC', lambda: next(tmp.glob('sway-ipc.*.sock'), None)))

        def sway(*args):
            return subprocess.check_output(['swaymsg', '-r', *args], env=graphical)

        stack.enter_context(process([ROOT / 'scripts/orb_desktop_dev.sh', '--leanui'], graphical, ROOT))
        wait('native window', lambda: b'"orb-desktop"' in sway('-t', 'get_tree'), 300)
        stack.enter_context(process(['wtype', '-k', 'Shift_L', '-s', '120000'], graphical, tmp))
        time.sleep(.5)
        def keys(*args):
            subprocess.run(['wtype', '-s', '200', *args], check=True, env=graphical)
        keys('-k', 'Tab', '-s', '200', '-k', 'Return')
        created = wait('created mission', lambda: api('/api/control/missions'))
        assert len(created) == 1
        mid = created[0]['id']
        path = '/api/control/missions/' + mid
        typed, committed = 'u6a ' + secrets.token_hex(5) + ' ', '日本語'
        time.sleep(.5)
        keys(*(['-k', 'Tab'] * 4), '-s', '300', typed)
        wayland_ime.commit(committed, graphical, '未確定' if mode in ('preedit', 'all') else '')
        time.sleep(.25)
        keys('-k', 'Tab', '-k', 'Tab', '-k', 'Return')

        def observed():
            row = api(path)
            messages = [m for m in api(path + '/events') if m['event_type'] == 'user_message' and m['mission_id'] == mid]
            if row['id'] == mid and [m['content'] for m in messages] == [typed + committed] and row['status'] == 'active':
                return row, messages[0]

        active, message = wait('exact submitted text on active mission', observed)
        pid = int(wait('one real launch', lambda: launches.exists() and launches.read_text().strip()))
        pidfd = os.pidfd_open(pid)
        stack.callback(os.close, pidfd)
        exited = select.poll()
        exited.register(pidfd, select.POLLIN)
        assert not exited.poll(0), 'harness already exited before Stop'
        time.sleep(1.5)  # wait for the desktop status subscription
        if mode in ('retry', 'all'):
            if len(attempts) == 1:
                keys('-k', 'Return')  # retry the unconfirmed submission
            wait('same logical Send retried', lambda: len(attempts) >= 2, 4)
            assert attempts == [message['event_id']] * 2, attempts
            assert observed() and launches.read_text().splitlines() == [str(pid)], 'duplicate event or launch'
        keys('-k', 'Return')
        stopped = wait('hosted stop', lambda: (r if (r := api(path))['status'] == 'interrupted' else None))
        assert exited.poll(3000), f'original harness {pid} still alive after Stop'
        time.sleep(1.5)
        keys('-k', 'Tab', '-k', 'Tab', '-k', 'Return')
        wait('archive', lambda: api(path)['status'] == 'acknowledged')
        server.terminate()
        server.wait(8)
        stack.enter_context(process(core, env, tmp))
        token = wait('Core restart', login)
        archived = api(path)
        assert archived['id'] == stopped['id'] == active['id'] == mid and archived['status'] == 'acknowledged'
        print(json.dumps(dict(id=mid, submitted=message['content'], message_id=message['event_id'], running=active['status'], stopped=stopped['status'],
                              after_restart=archived['status'], exited_before_archive=pid, launches=launches.read_text().splitlines(), attempts=attempts), ensure_ascii=False))


if __name__ == '__main__':
    with tempfile.TemporaryDirectory(prefix='orb-u6a-') as directory:
        run(Path(directory), sys.argv[1] if len(sys.argv) == 2 else 'all')
