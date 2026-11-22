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
import select as polling
import lost_reply
import tempfile
import time
import urllib.request

import wayland_ime
from wayland_pointer import Pointer
from wayland_ocr import read_words

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


def run(tmp, mouse=False, menu_client=None, providers=False, replay=None):
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
    harness.write_text(f"#!{sys.executable}\nimport os\nwith open({str(launches)!r}, 'a') as f: print(os.getpid(), file=f)\n" + r"""import json
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
        if providers:
            admin = token
            password = secrets.token_urlsafe(24)
            api('/api/admin/users', {'username': 'provider-fixture', 'password': password, 'role': 'member'})
            account = api('/api/ai/providers', {'provider_type': 'custom', 'name': 'Indigo',
                          'base_url': base, 'api_key': 'fixture-key', 'enabled': True})['id']
            token = api('/api/auth/login', {'username': 'provider-fixture', 'password': password})['token']
        def occupy(mid):
            api('/api/control/message', {'mission_id': mid, 'content': 'other client'})
            wait('other child registered', lambda: launches.exists() and launches.read_text().strip())
        endpoint, attempts = stack.enter_context(lost_reply.proxy(port, occupy if replay == 'busy' else None)) if replay else (base, [])
        (tmp / 'connection.json').write_text(json.dumps({'api_url': endpoint, 'token': token}))
        assert api('/api/control/missions') == []
        if menu_client is None and not providers:
            api('/api/projects', {'slug': 'menu-test', 'title': 'Menu test'})
            api('/api/projects', {'slug': 'source', 'title': 'Source project'})
        if replay:
            mid = api('/api/control/missions', {'title': 'Indigo', 'project': 'source', 'backend': 'codex'})['id']
        config = tmp / 'sway.conf'
        config.write_text('output * mode 1000x700\ndefault_border none\nxwayland disable\n')
        graphical = dict(os.environ, XDG_RUNTIME_DIR=str(tmp), WLR_BACKENDS='headless', WLR_RENDERER='pixman',
                         WLR_LIBINPUT_NO_DEVICES='1', ORB_STATE_DIR=str(tmp))
        stack.enter_context(process(['sway', '-c', config], graphical, tmp))
        graphical['WAYLAND_DISPLAY'] = wait('private compositor', lambda: next((p.name for p in tmp.glob('wayland-*') if p.is_socket()), None))
        graphical['SWAYSOCK'] = str(wait('sway IPC', lambda: next(tmp.glob('sway-ipc.*.sock'), None)))

        def sway(*args):
            return subprocess.check_output(['swaymsg', '-r', *args], env=graphical)

        if mouse or replay:
            pointer = Pointer(graphical)
            stack.callback(pointer.close)
            click = pointer.click
        stack.enter_context(process(['wtype', '-k', 'Shift_L', '-s', '120000'], graphical, tmp))
        if menu_client is not None:
            from linux_sidebar_menu import exercise
            return exercise(ROOT, tmp, api, graphical, click, process, wait, stack, menu_client)
        binary = os.environ.get('ORB_LEANUI_TEST_BINARY')
        client = [str(Path(binary).resolve(strict=True))] if binary else [ROOT / 'scripts/orb_desktop_dev.sh', '--leanui']
        if binary and Path(binary).name in ('orb', 'orb-desktop'):
            client.append('--leanui')
        desktop = stack.enter_context(process(client, graphical, ROOT))
        wait('native window', lambda: b'"orb-desktop"' in sway('-t', 'get_tree'), 300)
        time.sleep(.5)
        def keys(*args):
            subprocess.run(['wtype', '-s', '200', *args], check=True, env=graphical)
        def crop(geometry):
            return subprocess.check_output(['grim', '-t', 'ppm', '-g', geometry, '-'], env=graphical)

        def widget(label, region):
            return next(((x,y) for word,x,y in read_words(crop(region), region) if word == label), None)
        if providers:
            def preference():
                data = api('/api/ai/providers')
                rows = data['providers'] if isinstance(data, dict) else data
                return next(r for r in rows if r['id'] == account).get('user_enabled', True)
            sidebar, area = '10,30 195x160', '225,32 755x480'
            click(*wait('Inference navigation', lambda: widget('inference', sidebar)))
            click(*wait('provider account', lambda: widget('using', area)))
            wait('skip acknowledged by Core', lambda: preference() is False)
            wait('skip displayed', lambda: widget('skipped', area))
            member = token
            try:
                token = admin
                assert preference() is True
            finally:
                token = member
            keys('-M', 'ctrl', '-k', 'n', '-m', 'ctrl')
            keys('-M', 'ctrl', '-k', '4', '-m', 'ctrl')
            click(*wait('persisted preference', lambda: widget('skipped', area)))
            wait('use acknowledged by Core', preference)
            return
        edit = stack.enter_context(wayland_ime.session(graphical))
        typed, committed = 'Indigo ' + secrets.token_hex(5) + ' ', '日本語'
        sidebar = '10,110 195x305'
        if replay:
            if not widget('indigo', sidebar):
                click(*wait('Source project', lambda: widget('source', sidebar)))
            click(*wait('existing mission', lambda: widget('indigo', sidebar)))
            time.sleep(.5)
            click(540, 626)
            keys(typed)
            edit([(committed, 0, 0)], preedit='未確定')
            keys('-k', 'Tab')  # abandon the preedit before clicking Send
            click(946, 626)
        elif mouse:
            source = wait('Source project', lambda: widget('source', '10,110 195x220'))
            click(*source)
            click(195, source[1])  # Start a draft in that project
            click(*wait('machine picker', lambda: widget('machine', '300,280 300x65')))
            click(*wait('local Core', lambda: widget('orb-core', '300,320 400x200')))
            click(370, 413)  # Harness in the composer toolbar
            choices = '305,400 550x280'
            click(*wait('Codex harness', lambda: widget('codex', choices)))
            # Click the name at the right end of a provider-qualified model row.
            # Previously this visible suffix lay outside the popup hit region.
            click(454, 413)  # Model picker beside the selected Codex harness
            models = '305,395 645x300'
            click(*wait('visible Astra model suffix', lambda: widget('astra', models)))
            click(540, 347)
            keys(typed)
            edit([("日本猫", 0, 0), ("語", len("猫".encode()), 0)])
            # Undo the IME replacement; the next replacement must still see 猫 at the caret.
            keys('-M', 'ctrl', '-k', 'z', '-m', 'ctrl')
            edit([("語", len("猫".encode()), 0)])
            click(881, 413)  # Send at the right edge of the composer toolbar
        else:
            wait('live project roster', lambda: widget('source', sidebar))
            keys('-M', 'ctrl', '-k', 'n', '-m', 'ctrl', '-s', '200', typed)
            edit([(committed, 0, 0)])
            keys('-k', 'Return')
        created = wait('created mission', lambda: api('/api/control/missions'))
        assert len(created) == 1
        mid = created[0]['id']
        path = '/api/control/missions/' + mid
        if replay == 'busy':
            wait('busy refusal', lambda: len(attempts) == 1)
            def messages():
                return [e['content'] for e in api(path + '/events') if e['event_type'] == 'user_message']
            assert messages() == ['other client']
            api(path + '/cancel', {})
            time.sleep(2)
            click(946, 626)
            wait('retained draft delivered', lambda: messages() == ['other client', typed + committed])
            wait('second harness launch', lambda: len(launches.read_text().splitlines()) >= 2)
            assert len(attempts) == len(set(attempts)) == len(launches.read_text().splitlines()) == 2
            api(path + '/cancel', {})
            return
        if mouse:
            mission = api(path)
            assert mission['project'] == 'source' and mission['backend'] == 'codex', mission['id']
            assert mission['model_override'] == 'gpt-6.2-astra', mission['model_override']
            assert not mission.get('remote_job') and not any(t.startswith('remote-node:') for t in mission['tags'])
            assert api('/api/machines')[0]['id'] == 'core'
        def observed():
            row = api(path)
            messages = [m for m in api(path + '/events') if m['event_type'] == 'user_message' and m['mission_id'] == mid]
            if row['id'] == mid and [m['content'] for m in messages] == [typed + committed] and row['status'] == 'active':
                return row, messages[0]

        active, message = wait('exact submitted text on active mission', observed)
        pid = int(wait('one real launch', lambda: launches.exists() and launches.read_text().strip()))
        pidfd = os.pidfd_open(pid)
        stack.callback(os.close, pidfd)
        exited = polling.poll()
        exited.register(pidfd, polling.POLLIN)
        assert not exited.poll(0)
        if replay:
            time.sleep(1.5)
            click(946, 626)
            wait('same logical Send retried', lambda: len(attempts) >= 2)
            assert attempts == [message['event_id']] * 2 and observed()
            assert launches.read_text().splitlines() == [str(pid)]
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
        if mouse or replay:
            click(946, 626)
        else:
            keys('-k', 'Tab', '-k', 'Tab', '-k', 'Return')
        stopped = wait('hosted stop', lambda: (r if (r := api(path))['status'] == 'interrupted' else None))
        assert exited.poll(3000), f'original harness {pid} still alive after Stop'
        time.sleep(1.5)
        if mouse:
            sidebar_region = '10,110 195x305'
            def locate(label, region):
                rows = read_words(crop(region), region)
                return next(((x, y) for text, x, y in rows
                             if text == label or (label == 'move' and text == 'moveto')), None)
            def select(label, region):
                click(*wait('visible ' + label, lambda: locate(label, region)))
            def open_actions():
                x, y = wait('visible mission in project', lambda: locate('indigo', sidebar_region))
                click(x, y, 'button3')
                return f'{x+10},{y} 175x180'
            region = open_actions()
            select('rename', region)
            save_x, save_y = wait('rename field open', lambda: locate('save', region))
            click(save_x, save_y - 30)
            edit([('Indigo edited', len(api(path)['title'].encode()), 0)])
            select('save', region)
            wait('renamed mission', lambda: api(path)['title'] == 'Indigo edited')
            wait('renamed row rendered', lambda: locate('edited', sidebar_region) and not locate('save', region))
            region = open_actions()
            select('move', region)
            select('menu', region)
            wait('moved mission', lambda: api(path).get('project') == 'menu-test')
            # The Core receipt can arrive while the source still shows its old row.
            # Wait for the collapsed destination and both project labels in one frame.
            def moved_out_of_source():
                labels = {word for word, _, _ in read_words(crop(sidebar_region), sidebar_region)}
                return {'menu', 'source'} <= labels and 'indigo' not in labels
            wait('source row removed after move', moved_out_of_source)
            select('menu', sidebar_region)
            region = open_actions()
            select('settings', region)
            select('effort', region)
            select('low', region)
            wait('mission effort saved through context menu', lambda: api(path).get('model_effort') == 'low')
            select('archive', open_actions())
        else:
            # Traverse back to the only live mission. Open its context menu
            # with the keyboard and verify the visible action before invoking it.
            region = '0,75 420x480'
            for _ in range(32):
                keys('-M', 'shift', '-k', 'Tab', '-m', 'shift', '-k', 'Menu')
                words = {word for word, _, _ in read_words(crop(region), region)}
                if {'rename', 'archive'} <= words:
                    break
            else:
                raise AssertionError('keyboard traversal did not reach the mission actions')
            keys('-k', 'Down', '-k', 'Down', '-k', 'Return')
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
            select('archived', sidebar_region)
            select('restore', open_actions())
            wait('restored archived mission after desktop restart', lambda: api(path)['status'] == 'paused')
            restored = api(path)['status']
        print(json.dumps(dict(id=mid, exact_submitted_text=message['content'] == typed + committed, event_sequence=message['sequence'], running=active['status'], stopped=stopped['status'],
                              after_restart=archived['status'], restored=restored), ensure_ascii=False))


if __name__ == '__main__':
    with tempfile.TemporaryDirectory(prefix='orb-u6a-') as directory:
        if sys.argv[1:2] == ['--sidebar-menu']:
            if sys.argv[2:] not in (['webkit'], ['leanui']):
                raise SystemExit("usage: live_writes.py --sidebar-menu {webkit,leanui}")
            run(Path(directory), mouse=True, menu_client=sys.argv[2])
        elif sys.argv[1:] == ["--providers"]:
            run(Path(directory), mouse=True, providers=True)
        elif sys.argv[1:] in (['all'], ['busy']):
            run(Path(directory), replay=sys.argv[1])
        else:
            run(Path(directory), mouse="--mouse" in sys.argv)
