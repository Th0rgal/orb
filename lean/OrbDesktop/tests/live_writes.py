"""Run from the checkout: python3 lean/OrbDesktop/tests/live_writes.py

Use orb-core from the same revision as the client. Set ORB_CORE_TEST_BINARY to the packaged Core or build it with scripts/build_orb_bins.sh --only orb-core.
The test uses Sway and wtype, plus grim to observe the composer in the mouse workflow. Only the external model harness is replaced with a deterministic transcript producer; all mission writes go through the launched desktop and real Core.
"""
import contextlib
import json
import os
from pathlib import Path
import secrets
import signal
import sys
import socket
import subprocess
import tempfile
import time
import urllib.request

import wayland_ime
from wayland_pointer import Pointer

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
def process(args, env, cwd, stdin=None):
    child = subprocess.Popen(args, cwd=cwd, env=env, stdin=stdin, start_new_session=True)
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


def run(tmp, mouse=False, menu_client=None):
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
    harness.write_text(f"#!{sys.executable}\n" + r"""import json
import time

for i in range(300):
    text = "Transcript line %03d " % i + ("steady output " * 5)
    item = {"id": str(i), "type": "agent_message", "text": text + "\n"}
    print(json.dumps({"type": "item.completed", "item": item}), flush=True)
    time.sleep(.12)
""")
    harness.chmod(0o700)
    env = dict(PATH=f'{tmp}:{os.environ["PATH"]}', HOME=str(home), HOST='127.0.0.1', PORT=str(port),
               LD_LIBRARY_PATH=os.getenv('LD_LIBRARY_PATH', ''), WORKING_DIR=str(tmp), DEV_MODE='true')
    core = [Path(os.environ.get('ORB_CORE_TEST_BINARY', ROOT / 'target/release/orb-core')).resolve(strict=True)]
    with contextlib.ExitStack() as stack:
        server = stack.enter_context(process(core, env, tmp))
        token = wait('disposable Core login', login)
        (tmp / 'connection.json').write_text(json.dumps({'api_url': base, 'token': token}))
        assert api('/api/control/missions') == []
        if mouse and menu_client is None:
            api('/api/projects', {'slug': 'menu-test', 'title': 'Menu test'})
            api('/api/projects', {'slug': 'source', 'title': 'Source project'})
        config = tmp / 'sway.conf'
        config.write_text('output * mode 1000x700\ndefault_border none\nxwayland disable\n')
        graphical = dict(os.environ, XDG_RUNTIME_DIR=str(tmp), WLR_BACKENDS='headless', WLR_RENDERER='pixman',
                         WLR_LIBINPUT_NO_DEVICES='1', ORB_STATE_DIR=str(tmp))
        stack.enter_context(process(['sway', '-c', config], graphical, tmp))
        graphical['WAYLAND_DISPLAY'] = wait('private compositor', lambda: next((p.name for p in tmp.glob('wayland-*') if p.is_socket()), None))
        graphical['SWAYSOCK'] = str(wait('sway IPC', lambda: next(tmp.glob('sway-ipc.*.sock'), None)))

        def sway(*args):
            return subprocess.check_output(['swaymsg', '-r', *args], env=graphical)

        if mouse:
            pointer = Pointer(graphical)
            stack.callback(pointer.close)
            click = pointer.click
        if menu_client is not None:
            from linux_sidebar_menu import exercise
            return exercise(ROOT, tmp, api, graphical, click, process, wait, stack, menu_client)
        binary = os.environ.get('ORB_LEANUI_TEST_BINARY')
        client = [str(Path(binary).resolve(strict=True))] if binary else [ROOT / 'scripts/orb_desktop_dev.sh', '--leanui']
        if binary and Path(binary).name == 'orb-desktop':
            client.append('--leanui')
        desktop = stack.enter_context(process(client, graphical, ROOT))
        wait('native window', lambda: b'"orb-desktop"' in sway('-t', 'get_tree'), 300)
        stack.enter_context(process(['wtype', '-k', 'Shift_L', '-s', '120000'], graphical, tmp))
        time.sleep(.5)
        def keys(*args):
            subprocess.run(['wtype', '-s', '200', *args], check=True, env=graphical)
        def crop(geometry):
            return subprocess.check_output(['grim', '-t', 'ppm', '-g', geometry, '-'], env=graphical)

        def composer_frame():
            return crop('700,615 24x24')

        if mouse:
            empty_frame = composer_frame()
            click(74, 214)   # open Source project
            click(264, 53)   # choose the Core machine explicitly
            click(302, 114)
            empty_choice_row = crop('366,106 56x16')
            click(348, 53)   # select Codex from the live catalog
            wait('live harness choices', lambda: crop('366,106 56x16') != empty_choice_row)
            click(360, 114)
            click(80, 50)  # Create mission in the sidebar
        else:
            keys('-k', 'Tab', '-s', '200', '-k', 'Return')
        created = wait('created mission', lambda: api('/api/control/missions'))
        assert len(created) == 1
        mid = created[0]['id']
        path = '/api/control/missions/' + mid
        if mouse:
            mission = api(path)
            assert mission['project'] == 'source' and mission['backend'] == 'codex', mission['id']
            assert not mission.get('remote_job') and not any(t.startswith('remote-node:') for t in mission['tags'])
            assert api('/api/machines')[0]['id'] == 'core'
        typed, committed = 'u6a ' + secrets.token_hex(5) + ' ', '日本語'
        time.sleep(.5)
        if mouse:
            wait('visible composer', lambda: composer_frame() != empty_frame)
            click(540, 626)
            keys(typed)
        else:
            keys(*(['-k', 'Tab'] * 4), '-s', '300', typed)
        wayland_ime.commit(committed, graphical)
        time.sleep(.25)
        if mouse:
            click(946, 626)
        else:
            keys('-k', 'Tab', '-k', 'Tab', '-k', 'Return')

        def observed():
            row = api(path)
            messages = [m for m in api(path + '/events') if m['event_type'] == 'user_message' and m['mission_id'] == mid]
            if row['id'] == mid and [m['content'] for m in messages] == [typed + committed] and row['status'] == 'active':
                return row, messages[0]

        active, message = wait('exact submitted text on active mission', observed)
        def streamed_events():
            return [e for e in api(path + '/events') if e['event_type'] == 'text_delta' and
                    e['mission_id'] == mid and (e.get('content') or '').startswith('Transcript line')]

        if mouse:
            def transcript_frame():
                return subprocess.check_output(['grim', '-t', 'ppm', '-g', '300,110 300x155', '-'], env=graphical)

            wait('assistant output reached Core', lambda: len(streamed_events()) >= 45)
            time.sleep(1.5)
            bottom = transcript_frame()
            pointer.scroll(620, 330, -10000)
            top = wait('wheel scrolled transcript', lambda: frame if (frame := transcript_frame()) != bottom else None)
            initial = len(streamed_events())
            wait('assistant continued during reader scroll', lambda: len(streamed_events()) >= initial + 18)
            assert transcript_frame() == top, 'reader position jumped while new assistant text arrived'
            pointer.scroll(620, 330, 10000)
            wait('wheel returned to live output', lambda: transcript_frame() != top)
        time.sleep(1.5)  # wait for the desktop status subscription
        if mouse:
            click(946, 626)
        else:
            keys('-k', 'Return')
        stopped = wait('hosted stop', lambda: (r if (r := api(path))['status'] == 'interrupted' else None))
        time.sleep(1.5)
        if mouse:
            # The newly created row precedes the original roster. The anchored
            # menu opens at the secondary click, independent of transcript focus.
            action_row = '89,152 72x23'
            rendered = None

            def open_actions():
                nonlocal rendered
                if rendered is not None:
                    wait('previous menu dismissed', lambda: crop(action_row) != rendered)
                before = crop(action_row)
                click(75, 143, 'button3')
                rendered = wait('visible mission actions', lambda: frame if (frame := crop(action_row)) != before else None)
            # Keep the same virtual keyboard while the popup owns focus.
            # Connecting another keyboard inside the popup sends a focus leave.
            with process(['wtype', '-k', 'Shift_L', '-', '-k', 'End', ' renamed', '-s', '120000'],
                         graphical, tmp, stdin=subprocess.PIPE) as keyboard:
                with keyboard.stdin:
                    open_actions()
                    click(128, 164)
                    original_title = crop('100,151 176x26')
                # EOF releases wtype's stdin barrier with its existing keymap.
                wait('edited rename field', lambda: crop('100,151 176x26') != original_title)
                click(128, 194)
            wait('renamed mission', lambda: api(path)['title'].endswith(' renamed'))
            open_actions()
            click(128, 194)
            click(128, 194)
            wait('moved mission', lambda: api(path).get('project') == 'menu-test')
            open_actions()
            click(128, 284)  # Mission settings
            click(128, 254)  # Effort
            click(128, 194)  # Low
            wait('mission effort saved through context menu', lambda: api(path).get('model_effort') == 'low')
            open_actions()
            click(128, 224)  # Archive follows Move to
        else:
            backend = stopped.get('backend')
            selector_count = 2 + int(backend in ('codex', 'antigravity', 'claudecode')) + int(backend == 'claudecode')
            keys(*(['-k', 'Tab'] * (2 + selector_count)), '-k', 'Return')
        wait('archive', lambda: api(path)['status'] == 'acknowledged')
        server.terminate()
        server.wait(8)
        stack.enter_context(process(core, env, tmp))
        token = wait('Core restart', login)
        archived = api(path)
        assert archived['id'] == stopped['id'] == active['id'] == mid and archived['status'] == 'acknowledged'
        restored = None
        if mouse:
            desktop.terminate()
            desktop.wait(5)
            stack.enter_context(process(client, graphical, ROOT))
            wait('reopened native window', lambda: b'"orb-desktop"' in sway('-t', 'get_tree'))
            time.sleep(1.5)
            click(75, 245)  # Archived group in the otherwise empty roster
            click(75, 277, 'button3')
            click(128, 358)  # Restore follows Rename and Move to
            wait('restored archived mission after desktop restart', lambda: api(path)['status'] == 'paused')
            restored = api(path)['status']
        print(json.dumps(dict(id=mid, submitted=message['content'], message_id=message['event_id'], running=active['status'], stopped=stopped['status'],
                              after_restart=archived['status'], restored=restored), ensure_ascii=False))


if __name__ == '__main__':
    with tempfile.TemporaryDirectory(prefix='orb-u6a-') as directory:
        if sys.argv[1:2] == ['--sidebar-menu']:
            if sys.argv[2:] not in (['webkit'], ['leanui']):
                raise SystemExit("usage: live_writes.py --sidebar-menu {webkit,leanui}")
            run(Path(directory), mouse=True, menu_client=sys.argv[2])
        else:
            run(Path(directory), mouse="--mouse" in sys.argv)
