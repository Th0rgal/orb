"""Drive the same mission-menu fixture in a packaged Linux client using real pointer input.

Run live_writes.py --sidebar-menu with webkit, hybrid or leanui. OCR reads the
private compositor's pixels so the check also exercises the actual menu layout.
"""
import contextlib
import json
import os
from pathlib import Path
import socket
import sqlite3
import subprocess
import tempfile
import time
import uuid

from archive_race import archive_relay
from wayland_ocr import read_words


def exercise(root, tmp, api, graphical, click, process, wait, stack, client_kind):
    fixture = json.loads((root / 'shared/orb-spec/fixtures/linux-mission-menu.json').read_text())
    for project in [fixture['project'], fixture['destination']]:
        api('/api/projects', project)
    def create(title):
        return api('/api/control/missions', {'title': title, 'project': fixture['project']['slug'],
                                             'backend': 'codex'})['id']
    a, b = create(fixture['openMission']), create(fixture['contextMission'])
    def status(mid):
        return api('/api/control/missions/' + mid)['status']
    package = os.environ.get('ORB_PACKAGED_TEST_BINARY')
    if package:
        flag = {'webkit': '--webkit', 'hybrid': '--leanui-hybrid', 'leanui': '--leanui'}[client_kind]
        cmd = [str(Path(package).resolve(strict=True)), flag]
    else:
        if client_kind == 'hybrid':
            raise ValueError('hybrid requires ORB_PACKAGED_TEST_BINARY pointing to the package launcher')
        variable = 'ORB_LEANUI_TEST_BINARY' if client_kind == 'leanui' else 'ORB_WEBKIT_TEST_BINARY'
        binary = Path(os.environ[variable])
        cmd = [str(binary.resolve(strict=True))]
        if client_kind == 'leanui' and binary.name in ('orb', 'orb-desktop'):
            cmd.append('--leanui')
    home = tmp / 'home'
    graphical.update(HOME=str(home), XDG_DATA_HOME=str(home/'data'), XDG_CONFIG_HOME=str(home/'config'),
                     XDG_CACHE_HOME=str(home/'cache'), GDK_BACKEND='wayland')
    client = stack.enter_context(contextlib.ExitStack())
    def launch():
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            env = dict(graphical, ORB_LOCALD_PORT=str(sock.getsockname()[1]))
        client.enter_context(process(cmd, env, tmp))
    config_path = tmp / 'connection.json'
    config = json.loads(config_path.read_text())
    config['api_url'], gate = stack.enter_context(archive_relay(config['api_url'], b))
    initial = dict(config, token="expired") if client_kind == "leanui" else config
    config_path.write_text(json.dumps(initial))
    launch()
    sidebar = '10,100 200x560'
    header = '220,0 630x43'
    def words(geometry):
        image = subprocess.check_output(['grim', '-t', 'ppm', '-g', geometry, '-'], env=graphical)
        return read_words(image, geometry)

    def locate(label, geometry):
        return next(((x, y) for word, x, y in words(geometry) if word == label.lower()), None)
    def see(label, geometry=sidebar):
        return wait('visible ' + label, lambda: locate(label, geometry))
    def open_project():
        def reveal():
            if locate(fixture['openMission'], sidebar):
                return True
            project = locate('menu', sidebar)
            if project:
                click(20, project[1])
                try:
                    return wait('expanded project roster', lambda: locate(fixture['openMission'], sidebar), 3)
                except TimeoutError:
                    return False
        wait('visible open mission in project', reveal)
    def action_menu(expected, choose, target_region=sidebar, target=None):
        x, y = see(target or fixture['contextMission'], target_region)
        click(x, y, 'button3')
        if client_kind == 'leanui':
            regions = [f'{x+20},{min(y,535)} 165x175']
        else:
            # WebKit opens its menu at the pointer. The GTK popover can open above the row.
            regions = [f'{max(0,x-12)},{min(y-8,510)} 220x185', f'{max(0,x-38)},{max(0,y-207)} 170x185']
        labels = {'rename':'rename', 'move':'move', 'archive':'archive', 'restore':'restore',
                  'copy-id':'copy', 'settings':'settings'}
        def actions_in(geo):
            visible = words(geo)
            first = next((i for i, (word, _, _) in enumerate(visible) if word == 'rename'), None)
            if first is None:
                return None
            hits = {}
            last_y = None
            for action in expected:
                match = next((i for i in range(first,len(visible)) if visible[i][0] == labels[action] or
                              (action == 'move' and visible[i][0] == 'moveto')), None)
                if match is None:
                    return None
                _, x, y = visible[match]
                if last_y is not None and not 12 <= y - last_y <= 54:
                    return None
                hits[action] = (x, y)
                last_y = y
                first = match + 1
            return hits
        def rows():
            return next((hits for region in regions if (hits := actions_in(region))), None)
        try:
            hits = wait('ordered context actions ' + ', '.join(expected), rows)
        except TimeoutError as error:
            with tempfile.NamedTemporaryFile(prefix=f'orb-{client_kind}-menu-', suffix='.png', delete=False) as frame:
                subprocess.run(['grim', '-t', 'png', '-'], stdout=frame, env=graphical, check=True)
            raise AssertionError(f'{choose} for {target or fixture["contextMission"]} at {(x, y)}: {frame.name}') from error
        if choose == 'dismiss':
            subprocess.run(['wtype', '-k', 'Escape'], env=graphical, check=True)
            wait('context menu dismissed', lambda: rows() is None)
        elif client_kind != 'leanui' and choose == 'rename':
            # Rename receives focus when the GTK menu opens.
            subprocess.run(['wtype', '-k', 'Return'], env=graphical, check=True)
        else:
            click(*hits[choose])
    if client_kind == "leanui":
        def needs_connection():
            labels = {word for word, _, _ in words('0,0 1000x700')}
            return 'unavailable' in labels or {'sign', 'core'} <= labels
        wait('visible disconnected state', needs_connection)
        replacement = tmp / "reconnected.json"
        replacement.write_text(json.dumps(config))
        replacement.replace(config_path)
    open_project()
    click(*see(fixture['openMission']))
    see(fixture['openMission'], header)
    if client_kind == 'leanui':
        # The selected mission moves into the freed sidebar space.
        click(26, 20)
        see(fixture['openMission'], '0,0 220x43')
        assert locate(fixture['contextMission'], sidebar) is None
        subprocess.run(['wtype', '-M', 'ctrl', '-k', 'b', '-m', 'ctrl'], env=graphical, check=True)
        see(fixture['openMission'], header)
        see(fixture['contextMission'], sidebar)
    if package:
        from sidebar_backdrop import measure
        backdrop = measure(graphical)
        print(json.dumps({'client': client_kind, 'sidebar_backdrop_delta': backdrop}), flush=True)
        assert 0 < backdrop < 255, 'sidebar must transmit part of the compositor backdrop'
    action_menu(fixture['activeActions'], 'dismiss')
    see(fixture['openMission'], header)
    if client_kind != 'leanui':
        action_menu(fixture['activeActions'], 'rename')
        def rename_open():
            tree = json.loads(subprocess.check_output(['swaymsg', '-t', 'get_tree'], env=graphical))
            def includes_dialog(node):
                return node.get('name') == 'Rename conversation' or any(
                    includes_dialog(child) for child in node.get('nodes', []) + node.get('floating_nodes', []))
            return includes_dialog(tree)
        wait('rename dialog opened', rename_open)
        subprocess.run(['wtype', '-M', 'ctrl', '-k', 'a', '-m', 'ctrl', 'Draft'], env=graphical, check=True)
        subprocess.run(['wtype', '-k', 'Escape'], env=graphical, check=True)
        wait('rename dialog dismissed', lambda: not rename_open())
        see(fixture['openMission'], header)
        assert api('/api/control/missions/' + b)['title'] == fixture['contextMission']
        title = fixture['contextMission']
        for replacement, key in [('Violet', 'Return'), (fixture['contextMission'], 'KP_Enter')]:
            action_menu(fixture['activeActions'], 'rename', target=title)
            wait('rename dialog opened', rename_open)
            subprocess.run(['wtype', '-M', 'ctrl', '-k', 'a', '-m', 'ctrl', replacement], env=graphical, check=True)
            subprocess.run(['wtype', '-k', key], env=graphical, check=True)
            wait('rename accepted', lambda: not rename_open() and api('/api/control/missions/' + b)['title'] == replacement)
            see(replacement)
            see(fixture['openMission'], header)
            title = replacement
    # The client has already read B as idle when its Archive POST reaches
    # the relay. Activate B directly through Core before forwarding that POST.
    db_path, = tmp.rglob('missions.db')
    receipt = {}
    def snapshot(label):
        with contextlib.closing(sqlite3.connect(db_path.as_uri() + '?mode=ro', uri=True)) as db:
            started = time.time_ns()
            row = db.execute('SELECT status, (SELECT count(*) FROM mission_runs WHERE mission_id=m.id) '
                              'FROM missions m WHERE id=?', (b,)).fetchone()
            receipt[label + '_read_unix_ns'] = [started, time.time_ns()]
            receipt[label] = row
    def before_archive():
        receipt['post_held_unix_ns'] = time.time_ns()
        snapshot('idle')
        assert receipt['idle'] == ('awaiting_user', 0), receipt
        api('/api/control/message', {'mission_id': b, 'content': 'disposable refusal check',
                                     'client_message_id': str(uuid.uuid4())})
        snapshot('before_guard')
        assert receipt['before_guard'] == ('active', 0), receipt
        receipt['post_released_unix_ns'] = time.time_ns()
    def after_archive(code, payload, key):
        receipt['reply_read_unix_ns'] = time.time_ns()
        receipt.update(status=code, error=json.loads(payload).get('error'), idempotency_key=key)
        snapshot('after_guard')
    gate.arm(before_archive, after_archive)
    action_menu(fixture['activeActions'], 'archive')
    gate.result()
    assert receipt['idempotency_key'] and receipt['status'] == 409, receipt
    assert receipt['error'] == 'mission_running' and receipt['after_guard'] == ('active', 0), receipt
    print(json.dumps({'client': client_kind, 'viewed': a, 'target': b, 'ui_archive': receipt}), flush=True)
    # In the 1000x700 test output LeanUI places its 440x40 warning just
    # above the 104px composer. Isolate it from the streaming transcript.
    refusal_region = '552,548 440x40' if client_kind == 'leanui' else '0,0 1000x700'
    # WebKit renders the Core conflict detail, LeanUI its native refusal.
    expected = 'stop or finish this agent before archiving it' if client_kind == 'leanui' else 'before changing'
    observed = {}
    with tempfile.NamedTemporaryFile(prefix=f'orb-{client_kind}-refusal-', suffix='.png',
                                     delete=False) as frame:
        def refusal_visible():
            pixels = subprocess.check_output(['grim', '-s', '1', '-t', 'png', '-'], env=graphical)
            frame.seek(0)
            frame.write(pixels)
            frame.truncate()
            frame.flush()
            observed.clear()
            for region, phrase in [(refusal_region, expected), (header, fixture['openMission'].lower()),
                                   (sidebar, fixture['contextMission'].lower())]:
                observed[region] = ' '.join(word for word, _, _ in read_words(pixels, region, full_frame=True))
                if phrase not in observed[region]:
                    return False
            return True
        try:
            wait('visible refusal: ' + expected, refusal_visible)
        except TimeoutError as error:
            raise AssertionError(f'Refusal OCR in {refusal_region}: {observed!r}; frame {frame.name}') from error
    see(fixture['openMission'], header)
    see(fixture['contextMission'])
    assert status(b) == 'active' and status(a) == 'awaiting_user'
    print(json.dumps({'client': client_kind, 'viewed': a, 'target': b,
                      'visible_refusal': expected, 'frame': frame.name, 'target_status': 'active'}), flush=True)
    api('/api/control/missions/' + b + '/cancel', {})
    wait('context mission stopped', lambda: status(b) == 'interrupted')
    gate.armed.clear()
    action_menu(fixture['activeActions'], 'archive')
    wait('context mission archived', lambda: status(b) == 'acknowledged')
    see(fixture['openMission'], header)
    assert status(a) == 'awaiting_user'
    wait('context mission left active roster', lambda: locate(fixture['contextMission'], sidebar) is None)
    client.close()
    launch()
    see('Archived')
    if not locate(fixture['openMission'], header):
        open_project()
        click(*see(fixture['openMission']))
    see(fixture['openMission'], header)
    archived = see('Archived')
    assert status(b) == 'acknowledged'
    click(*archived)
    below_archive = f'10,{archived[1]+10} 200x{660-archived[1]-10}'
    action_menu(fixture['archivedActions'], 'restore', below_archive)
    wait('context mission restored', lambda: status(b) == 'paused')
    see(fixture['openMission'], header)
    assert status(a) == 'awaiting_user'
    print(json.dumps({'client': client_kind, 'viewed': a, 'target': b,
                      'archive': 'acknowledged', 'restore': 'paused', 'refusal': 'active', 'ui_archive': receipt}))
