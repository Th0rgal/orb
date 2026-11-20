"""Drive the same mission-menu fixture in a packaged Linux client using real pointer input.

Run live_writes.py --sidebar-menu leanui or --sidebar-menu webkit. OCR reads the
private compositor's pixels so the check also exercises the actual menu layout.
"""
import contextlib
import csv
import json
import os
from pathlib import Path
import socket
import subprocess
import uuid


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
    binary = os.environ['ORB_LEANUI_TEST_BINARY' if client_kind == 'leanui' else 'ORB_WEBKIT_TEST_BINARY']
    cmd = [str(Path(binary).resolve(strict=True))]
    if client_kind == 'leanui' and Path(binary).name == 'orb-desktop':
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
    launch()
    sidebar = '10,100 200x560'
    header = '220,0 630x43'
    def words(geometry):
        image = subprocess.check_output(['grim', '-t', 'ppm', '-g', geometry, '-'], env=graphical)
        png = subprocess.check_output(['magick', 'ppm:-', '-colorspace', 'gray', '-auto-level',
                                       '-resize', '300%', 'png:-'], input=image)
        result = subprocess.check_output(['tesseract', 'stdin', 'stdout', '--psm', '11', 'tsv'],
                                         input=png, stderr=subprocess.DEVNULL, text=False)
        ox, oy = map(int, geometry.split(' ')[0].split(','))
        return [(r['text'].strip('.,:|…').lower(), ox+(int(r['left'])+int(r['width'])//2)//3,
                 oy+(int(r['top'])+int(r['height'])//2)//3) for r in
                csv.DictReader(result.decode().splitlines(), delimiter='\t') if r['text'].strip()]
    def locate(label, geometry):
        return next(((x, y) for word, x, y in words(geometry) if word == label.lower()), None)
    def see(label, geometry=sidebar):
        return wait('visible ' + label, lambda: locate(label, geometry))
    def open_project():
        if client_kind == 'webkit':
            _, y = see('Menu')
            if not locate(fixture['openMission'], sidebar):
                click(20, y)
    def action_menu(expected, choose):
        x, y = see(fixture['contextMission'])
        click(x, y, 'button3')
        if client_kind == 'leanui':
            geo = f'{x+20},{min(y,535)} 165x175'
        else:
            geo = '68,42 127x600'
        labels = {'rename':'rename', 'move':'move', 'archive':'archive', 'restore':'restore',
                  'copy-id':'copy', 'settings':'settings'}
        def rows():
            visible = words(geo)
            first = next((i for i, (word, _, _) in enumerate(visible) if word == 'rename'), None)
            if first is None:
                return None
            hits = {}
            for action in expected:
                match = next((i for i in range(first,len(visible)) if visible[i][0] == labels[action]), None)
                if match is None:
                    return None
                hits[action] = visible[match][1:]
                first = match + 1
            return hits
        hits = wait('ordered context actions ' + ', '.join(expected), rows)
        click(*hits[choose])
    open_project()
    click(*see(fixture['openMission']))
    see(fixture['openMission'], header)
    action_menu(fixture['activeActions'], 'archive')
    wait('context mission archived', lambda: status(b) == 'acknowledged')
    see(fixture['openMission'], header)
    assert status(a) == 'awaiting_user'
    wait('context mission left active roster', lambda: locate(fixture['contextMission'], sidebar) is None)
    client.close()
    launch()
    open_project()
    click(*see(fixture['openMission']))
    archived = see('Archived')
    assert status(b) == 'acknowledged'
    click(*archived)
    assert see(fixture['contextMission'])[1] > archived[1]
    action_menu(fixture['archivedActions'], 'restore')
    wait('context mission restored', lambda: status(b) == 'paused')
    see(fixture['openMission'], header)
    assert status(a) == 'awaiting_user'
    api('/api/control/message', {'mission_id': b, 'content': 'disposable refusal check',
                                 'client_message_id': str(uuid.uuid4())})
    wait('context mission running', lambda: status(b) == 'active')
    action_menu(fixture['activeActions'], 'archive')
    see('archiving', '0,0 1000x700')
    see(fixture['openMission'], header)
    see(fixture['contextMission'])
    assert status(b) == 'active' and status(a) == 'awaiting_user'
    print(json.dumps({'client': client_kind, 'viewed': a, 'target': b,
                      'archive': 'acknowledged', 'restore': 'paused', 'refusal': 'active'}))
