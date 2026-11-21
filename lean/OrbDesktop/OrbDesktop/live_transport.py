"""Embedded native client. stdout is private projection IPC, never diagnostics."""
import hashlib
import json
import os
import re
import signal
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid


CURRENT_MISSION_LIMIT = 200
ARCHIVED_MISSION_LIMIT = 100
TRACKED_MISSION_LIMIT = CURRENT_MISSION_LIMIT + ARCHIVED_MISSION_LIMIT


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args):
        return None


def request_timeout(*_):
    raise TimeoutError('request deadline')


def credentials():
    root = os.getenv('ORB_STATE_DIR', '').strip() or os.path.expanduser('~/.orb')
    with open(os.path.join(root, 'connection.json'), 'rb') as f:
        raw = f.read(65537)
    if len(raw) > 65536:
        raise ValueError('invalid connection')
    config = json.loads(raw)
    base = next(v.strip().rstrip('/') for k in ('api_url', 'apiUrl', 'endpoint')
                if isinstance(v := config.get(k), str) and v.strip())
    url = urllib.parse.urlsplit(base)
    if (url.scheme != 'https' and not (url.scheme == 'http' and url.hostname in
            ('localhost', '::1', '127.0.0.1'))) or not url.hostname or url.username is not None or url.query or url.fragment:
        raise ValueError('invalid endpoint')
    token = config['token']
    if not isinstance(token, str) or not token.strip() or not token.isprintable():
        raise ValueError('missing connection')
    return base, token


class Connection:
    def __init__(self):
        self.creds = credentials()
        self.binding = hashlib.sha256(json.dumps(self.creds).encode()).hexdigest()
        self.opener = urllib.request.build_opener(NoRedirect())

    def check(self):
        if credentials() != self.creds:
            raise ValueError('connection changed')

    def get(self, path, cap=4 << 20):
        return self.request(path, cap)

    def request(self, path, cap=4 << 20, body=None, key=None, method=None):
        self.check()
        base, token = self.creds
        req = urllib.request.Request(base + path, method=method, headers={'Authorization': 'Bearer ' + token,
                                                           'Accept': 'application/json', 'Cache-Control': 'no-cache'})
        if body is not None:
            req.data = json.dumps(body).encode()
            req.add_header('Content-Type', 'application/json')
        if key:
            req.add_header('Idempotency-Key', key)
        # A socket timeout alone is an idle timeout. Also bound total wall time
        # for DNS / continuously trickling responses. This helper is standalone.
        previous = signal.signal(signal.SIGALRM, request_timeout)
        signal.alarm(6)
        try:
            with self.opener.open(req, timeout=4) as response:
                data = response.read(cap + 1)
        finally:
            signal.alarm(0)
            signal.signal(signal.SIGALRM, previous)
        self.check()
        if len(data) > cap:
            raise ValueError('response too large')
        return json.loads(data) if data or body is None else None


class MissionNotIdle(ValueError):
    pass


def change_status(c, action, mid, key):
    path = '/api/control/missions/' + mid
    if action == 'archive':
        row = c.get(path + '?include_history=false')
        if row['id'] != mid:
            raise ValueError('unexpected mission')
        if (row.get('execution') or {}).get('state') == 'running' or row['status'] not in (
                'awaiting_user', 'completed', 'interrupted', 'failed', 'blocked', 'paused', 'cancelled'):
            raise MissionNotIdle('mission not idle')
        try:
            c.request(path + '/status', body={'status': 'acknowledged'}, key=key)
        except urllib.error.HTTPError as error:
            # The status endpoint returns 409 when a run starts after our read.
            if error.code == 409:
                error.close()
                raise MissionNotIdle('mission started before archive') from error
            raise
    elif action == 'restore':
        row = c.get(path + '?include_history=false')
        if row['id'] != mid or row['status'] != 'acknowledged' or (row.get('execution') or {}).get('state') == 'running':
            raise ValueError('mission not archived')
        c.request(path + '/status', body={'status': 'paused'}, key=key)


def bulk_write(c, kind, key):
    project, *ids = sys.stdin.buffer.read().decode().split('\n')
    if not ids or len(set(ids)) != len(ids) or not all(re.fullmatch(r'[A-Za-z0-9_-]{1,128}', i) for i in ids):
        raise ValueError('invalid mission selection')
    if kind == 'move':
        receipt = c.request('/api/control/missions/move', body={'mission_ids': ids, 'project': project,
                            'folder': '', 'approval_policy': 'check'}, key=key)
        moved = {r['mission_id'] for r in receipt['moved'] if r['project'] == project}
        if not set(ids) <= moved:
            raise ValueError('incomplete placement receipt')
        for mid in moved:
            print('ok\t' + mid)
        return
    if kind not in ('archive', 'restore', 'delete'):
        raise ValueError('unknown bulk action')
    for mid in ids:
        try:
            if kind == 'delete':
                # Core must explicitly refuse deletion when a selected root has
                # unconfirmed descendants or a running turn.
                result = c.request('/api/control/missions/' + mid, method='DELETE', key=key + '-' + mid)
                deleted = result.get('deleted_ids', [])
                if mid not in deleted:
                    raise ValueError('unconfirmed deletion')
            else:
                change_status(c, kind, mid, key + '-' + mid)
                deleted = [mid]
            for ident in deleted:
                print('ok\t' + ident)
        except (urllib.error.HTTPError, urllib.error.URLError, ValueError, TimeoutError):
            print('failed\t' + mid)


def mutate(binding, action, mid):
    c = Connection()
    if c.binding != binding:
        raise ValueError('connection changed')
    key = str(uuid.uuid4())
    if action.startswith('bulk-'):
        return bulk_write(c, action.removeprefix('bulk-'), key)
    if action == 'create':
        values = sys.stdin.buffer.read().decode().split('\t', 6)
        body = {'title': 'New mission'}
        if len(values) == 7:
            prompt = values.pop()
            if not prompt.strip():
                raise ValueError('missing initial prompt')
            body.update(prompt=prompt, title=' '.join(prompt.split())[:80])
        if values != ['']:
            if len(values) not in (5, 6):
                raise ValueError('invalid launch settings')
            # Core runs locally. A remote-node tag would queue this turn for a nonexistent worker.
            if values[0] == 'core':
                values[0] = ''
            fields = ('remote_node_id', 'backend', 'model_override', 'model_effort', 'permission_mode', 'project')
            body.update((k, v) for k, v in zip(fields, values) if v and
                        (k != 'permission_mode' or values[1] == 'claudecode'))
        row = c.request('/api/control/missions', body=body, key=key)
        if not re.fullmatch(r'[A-Za-z0-9_-]{1,128}', row['id']):
            raise ValueError('invalid mission')
        print('\t'.join(map(label, [row['id'], row.get('title') or 'New mission', row['status'], *mission_settings(row), row.get('project')])))
        return
    if not re.fullmatch(r'[A-Za-z0-9_-]{1,128}', mid):
        raise ValueError('invalid mission')
    path = '/api/control/missions/' + mid
    if action == 'send':
        receipt = c.request('/api/control/message', body={'mission_id': mid, 'content': sys.stdin.buffer.read().decode(),
                            'queue_followup': True, 'client_message_id': key}, key='msg:' + mid + ':' + key)
        if not receipt.get('id') or receipt.get('message_accepted') is False:
            raise ValueError('message not accepted')
    elif action == 'stop':
        c.request(path + '/cancel', body={}, key=key)
    elif action == 'settings':
        field, machine, backend, model, effort, permission = sys.stdin.buffer.read().decode().split('\t')
        if field == 'permission':
            c.request(path + '/permission-mode', body={'mode': permission}, key=key)
        else:
            patch = {'backend': {'backend': backend, 'model_override': model, 'model_effort': ''},
                     'model': {'model_override': model}, 'effort': {'model_effort': effort}}[field]
            c.request(path + '/settings', body={**patch, 'resume': False}, key=key, method='PATCH')
        actual = c.get(path + '?include_history=false')
        if actual['id'] != mid:
            raise ValueError('unexpected mission')
        print('\t'.join(map(label, mission_settings(actual))))
    elif action == 'rename':
        title = sys.stdin.buffer.read().decode().strip()
        if not title or len(title) > 200:
            raise ValueError('invalid title')
        c.request(path + '/title', body={'title': title}, key=key)
    elif action == 'move':
        project = sys.stdin.buffer.read().decode()
        receipt = c.request('/api/control/missions/move', body={'mission_ids': [mid],
                            'project': project, 'folder': '', 'approval_policy': 'check'}, key=key)
        moved = [r['mission_id'] for r in receipt['moved'] if r['project'] == project]
        if mid not in moved:
            raise ValueError('placement not confirmed')
        print('\n'.join(moved))
    elif action == 'copy-id':
        import subprocess
        subprocess.run(['wl-copy', '--type', 'text/plain'], input=mid.encode(), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
    elif action in ('archive', 'restore'):
        change_status(c, action, mid, key)
    else:
        raise ValueError('unknown action')


def label(v):
    return ''.join(c if c.isprintable() else ' ' for c in str(v or '')[:512])


def mission_settings(m):
    return (m.get('remote_node_id') or (m.get('remote_job') or {}).get('node_id') or
            next((t.removeprefix('remote-node:') for t in m.get('tags', []) if t.startswith('remote-node:')), 'core'),
            m.get('backend'), m.get('model_override') or m.get('model'),
            m.get('model_effort'), m.get('permission_mode') or 'supervised')


def mission_hierarchy(m):
    tags = m.get('tags') or []
    fork = next((tag[8:] for tag in tags if tag.startswith('fork-of:')), '')
    if not fork and (m.get('title') or '').lower().endswith(' · fork'):
        fork = m.get('parent_mission_id')
    return (m.get('folder'), m.get('parent_mission_id'), m.get('callback_parent_mission_id'),
            fork, m.get('superseded_by_mission_id'))


def visible_model_options(backend, options, rules):
    available = {(m.get('value'), m.get('provider_id')) for m in options}
    for option in options:
        value = option.get('value') or ''
        namespace, slash, model = value.partition('/')
        provider = namespace if backend == 'opencode' and slash else rules['harnessProvider'].get(backend)
        successor = rules['modelSuccessors'].get(provider, {}).get(model if slash else value)
        if successor and (not slash or namespace == provider):
            candidate = namespace + '/' + successor if slash else successor
            if (candidate, option.get('provider_id')) in available:
                continue
        yield option


def catalog_rows(c, rules):
    backends = c.get('/api/backends')
    if isinstance(backends, dict):
        backends = backends['backends']
    models = c.get('/api/providers/backend-models')['backends']
    chains = c.get('/api/model-routing/chains')
    by_id = {b['id']: b.get('name') or b['id'] for b in backends}
    chain_ids = {k for chain in chains for k in (chain['id'], chain['id'].removeprefix('builtin/'))}
    for backend in ('claudecode', 'codex', 'grok', 'opencode', 'antigravity', 'vibe'):
        if backend not in by_id:
            continue
        options = models.get(backend, [])
        if backend == 'opencode':
            options = ([{'value': chain['id'], 'label': 'Routing — ' + chain['name']} for chain in chains]
                       + [m for m in options if m.get('value', '').removeprefix('builtin/') not in chain_ids
                          and not m.get('label', '').startswith('Routing — ')])
        for option in visible_model_options(backend, options, rules):
            if option.get('value'):
                yield ('H', backend, by_id[backend], option['value'], option.get('label') or option['value'])


def roster_rows(c, include_archived=False):
    projects = c.get('/api/projects')['projects']
    missions = c.get(f'/api/control/missions?limit={CURRENT_MISSION_LIMIT}')
    machines = c.get('/api/machines')
    if not all(isinstance(x, list) for x in (projects, missions, machines)):
        raise ValueError('invalid roster')
    if include_archived:
        try:
            archived = c.get(f'/api/control/missions?status=acknowledged&limit={ARCHIVED_MISSION_LIMIT}')
            known = {r['id'] for r in missions}
            missions += [r for r in archived if r.get('status') == 'acknowledged' and r['id'] not in known]
        except urllib.error.HTTPError as error:
            if error.code != 404:
                raise
    rows = [('C', c.binding)]
    rows += [('P', p['slug'], p.get('title') or p['slug'], p.get('objective')) for p in projects]
    rows += [('M', *(m.get(k) for k in ('id','title','project','track','model','model_override',
                                        'status','updated_at','created_at','short_description')), *mission_settings(m), *mission_hierarchy(m))
             for m in missions if re.fullmatch(r'[A-Za-z0-9_-]{1,128}', m['id'])]
    rows += [('N', *(m.get(k) for k in ('id','name','role','provider','cpu_ram','size','state',
                                        'status','expires_at','cost','active_missions'))) for m in machines]
    c.check()
    return rows


def roster():
    c = Connection()
    # Retry the initial snapshot once. The subscription that handles later
    # network interruptions starts only after this snapshot succeeds.
    try:
        rows = roster_rows(c, include_archived=True)
    except (urllib.error.URLError, TimeoutError) as error:
        if isinstance(error, urllib.error.HTTPError):
            if error.code not in (408, 429, 502, 503, 504):
                raise
            error.close()
        time.sleep(1)
        rows = roster_rows(c, include_archived=True)
    for row in rows:
        print('\t'.join(map(label, row)))


def recover_roster():
    """Wait for a valid saved session and a complete roster after disconnection."""
    delay = 1
    while True:
        try:
            roster()
            return
        except (OSError, ValueError, KeyError, StopIteration, TypeError):
            time.sleep(delay)
            delay = min(30, 2 * delay)


def catalog(binding, rules):
    c = Connection()
    if c.binding != binding:
        return
    rows = list(catalog_rows(c, rules))
    c.check()
    for row in rows:
        print('\t'.join(map(label, row)))


def projection(c, mid, presence=False):
    path = '/api/control/missions/' + mid + '/current-bubble'
    obj = c.get(path + ('?presence=1' if presence else ''), 1 << 20)
    if obj['id'] != mid or not all(isinstance(obj[k], str) for k in ('title', 'status', 'text')) or len(obj['text']) > 65537:
        raise ValueError('invalid projection')
    return [label(obj['title']), label(obj['status']), ''.join(ch for ch in obj['text'] if ch in '\n\t' or ch.isprintable())]


def poll(mid, binding, tracked=None):
    c = Connection()
    if tracked is None:
        line = sys.stdin.readline(TRACKED_MISSION_LIMIT * 129 + 1)
        if not line.endswith('\n'):
            return
        tracked = set(filter(None, line.rstrip('\n').split(',')))
    if len(tracked) > TRACKED_MISSION_LIMIT or not all(re.fullmatch(r'[A-Za-z0-9_-]{1,128}', i) for i in tracked):
        return
    if c.binding != binding or (mid and not re.fullmatch(r'[A-Za-z0-9_-]{1,128}', mid)):
        return  # EOF invalidates the old roster; never request with a new identity
    last, failures, checked = None, 0, None
    visible = []
    while True:
        c.check()
        try:
            if checked is None or time.monotonic() - checked >= 5:
                rows = roster_rows(c, include_archived=True)
                found = {r[1] for r in rows if r[0] == 'M'}
                # A sorted, limited list is positive evidence only. For every
                # absent tracked ID require an explicit per-mission denial.
                for missing in sorted(tracked - found - {mid}):
                    try:
                        projection(c, missing, presence=True)
                    except urllib.error.HTTPError as error:
                        if error.code == 401:
                            raise
                        if error.code in (403, 404):
                            tracked.discard(missing)
                    except (urllib.error.URLError, TimeoutError, ValueError, KeyError, TypeError):
                        pass  # unknown for this ID, continue checking the others
                visible = ['P:' + label(ident) for kind, ident, *_ in rows if kind == 'P']
                visible += ['N:' + '\x1c'.join(map(label, row[1:])) for row in rows if row[0] == 'N']
                visible += ['M:' + i for i in sorted(tracked)]
                # Project status for other visible rows too. The selected bubble
                # carries a newer per-mission read and remains its own authority.
                visible += ['S:' + r[1] + ':' + r[7] for r in rows if r[0] == 'M'
                            and r[1] in tracked and r[1] != mid and len(r) > 7
                            and isinstance(r[7], str) and re.fullmatch(r'[a-z_]+', r[7])]
                checked = time.monotonic()
            current = ['sample', visible.copy(), None]
            if mid and 'M:' + mid in visible:
                try:
                    current[2] = projection(c, mid)
                except urllib.error.HTTPError as error:
                    if error.code not in (403, 404):
                        raise
                    visible.remove('M:' + mid)
                    tracked.discard(mid)
                    current[1] = visible.copy()
                except (ValueError, KeyError, TypeError):
                    # A malformed/oversized bubble is not a roster revocation.
                    current[2] = 'unavailable'
        except (urllib.error.URLError, TimeoutError, ValueError, KeyError, TypeError) as error:
            c.check()
            if isinstance(error, urllib.error.HTTPError) and error.code in (401, 403):
                raise
            # Null/malformed pages, partial reads and temporary errors are not
            # an authoritative empty roster. Retry without publishing removals.
            failures = min(5, failures + 1)
            time.sleep(failures)
            continue
        c.check()
        failures = 0
        if current != last:
            # Projection strips control characters except transcript newlines
            # and tabs. Reserve RS/US to encode those without a JSON runtime.
            keys = '\x1f'.join(current[1])
            if isinstance(current[2], list):
                title, status, text = current[2]
                fields = ('B', keys, title, status, text.replace('\n', '\x1e').replace('\t', '\x1f'))
            else:
                fields = ('R', keys)
            print('\t'.join(fields), flush=True)
            last = current
        time.sleep(1)
