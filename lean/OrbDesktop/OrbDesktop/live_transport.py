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

    def request(self, path, cap=4 << 20, body=None, key=None, method=None, deadline=6):
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
        signal.alarm(deadline)
        try:
            with self.opener.open(req, timeout=deadline if deadline > 6 else 4) as response:
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


def run_mutation(binding, action, mid):
    try:
        mutate(binding, action, mid)
        return 0
    except MissionNotIdle:
        return 2
    except urllib.error.HTTPError as error:
        with error:
            if action in ('create', 'send') and error.code in (400, 403):
                try:
                    detail = json.loads(error.read(4096)).get('error')
                except (ValueError, AttributeError):
                    detail = None
                if action == 'create' and error.code == 403 and detail == 'core_target_forbidden_for_member':
                    return 5
                if isinstance(detail, str) and detail.partition(':')[0] in (
                        'remote_goal_unsupported', 'remote_goal_followup_unsupported'):
                    return 3 if action == 'create' else 4
        return 1
    except Exception:
        return 1


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


def account_path(account):
    if not isinstance(account, str) or not account or account in ('.', '..') or len(account) > 256:
        raise ValueError('invalid provider account')
    return '/api/ai/providers/' + urllib.parse.quote(account, safe='')


def valid_country(value):
    return isinstance(value, str) and re.fullmatch('[A-Z]{2}', value) is not None


def vpn_options(route):
    mode = route['mode']
    if mode not in ('direct', 'vpn') or not isinstance(route.get('can_configure'), bool):
        raise ValueError('invalid account route')
    selected = '' if mode == 'direct' else route['country']
    if mode == 'vpn' and not valid_country(selected):
        raise ValueError('invalid route country')
    status = route['status']
    if status == 'verified':
        detail = ' · '.join(['Verified exit', selected, route['server'], ', '.join(route['exits'])])
    elif status == 'blocked':
        detail = selected + ' · ' + (route.get('message') or 'The VPN route is unavailable.')
    elif status == 'direct' and not selected:
        detail = 'Direct'
    else:
        raise ValueError('invalid account route status')
    yield ('', '', 'Account connection', detail)
    if route['can_configure']:
        countries = route['countries']
        if not isinstance(countries, list) or not all(valid_country(country) for country in countries):
            raise ValueError('invalid country choices')
        for country in dict.fromkeys(['', *([selected] if selected else []), *countries]):
            picked = country == selected
            caption = 'Retry verification' if picked and status == 'blocked' else 'Selected' if picked else ''
            action = 'vpn' if not picked or status == 'blocked' else ''
            yield (action, country, 'AirVPN · ' + country if country else 'Direct', caption)


def router_options(settings):
    allowed = settings['allowed']
    if not isinstance(allowed, bool):
        raise ValueError('invalid alternative-router setting')
    yield ('routers', 'off' if allowed else 'on', 'Alternative routers',
           'Allowed · OpenCode and other routed clients' if allowed else 'Off · Native Antigravity only')


def account_route_rows(c, account, antigravity):
    base = account_path(account)
    sections = [('vpn', 'Account connection', vpn_options)]
    if antigravity:
        sections.append(('alternative-routers', 'Alternative routers', router_options))
    for suffix, title, options in sections:
        try:
            rows = list(options(c.get(base + '/' + suffix)))
        except urllib.error.HTTPError as error:
            with error:
                if error.code == 401:
                    raise
                if error.code in (403, 404):
                    continue
            rows = [('refresh', '', title, 'Could not load. Retry')]
        except (OSError, ValueError, KeyError, TypeError):
            rows = [('refresh', '', title, 'Could not load. Retry')]
        yield from rows


def save_account_route(c, account, action, value):
    base = account_path(account)
    if action == 'vpn':
        if value and not valid_country(value):
            raise ValueError('invalid country choice')
        body = {'mode': 'vpn', 'country': value} if value else {'mode': 'direct'}
        # Core verifies both exit addresses and waits for the new AirVPN session.
        result = c.request(base + '/vpn', body=body, method='PUT', deadline=120)
        if not isinstance(result, dict) or result.get('mode') != body['mode'] or (value and result.get('country') != value):
            raise ValueError('unconfirmed account connection')
    elif action == 'routers':
        if value not in ('off', 'on'):
            raise ValueError('invalid router choice')
        body = {'allowed': value == 'on'}
        result = c.request(base + '/alternative-routers', body=body, method='PUT')
        if not isinstance(result, dict) or result.get('allowed') is not body['allowed']:
            raise ValueError('unconfirmed router setting')
    else:
        raise ValueError('unknown route setting')


def account_routes(binding, account, provider, action, value):
    c = Connection()
    if c.binding != binding:
        return
    confirmed = True
    if action:
        try:
            save_account_route(c, account, action, value)
        except (ValueError, OSError):
            confirmed = False
    rows = list(account_route_rows(c, account, provider == 'antigravity'))
    c.check()
    print('routes' if confirmed else 'unconfirmed')
    if not rows:
        rows = [('', '', 'Account connection', 'Routing controls are unavailable for this account on this Core.')]
    for row in rows:
        print('\t'.join(map(label, ('D', *row))))


def mutate(binding, action, mid):
    c = Connection()
    if c.binding != binding:
        raise ValueError('connection changed')
    key = str(uuid.uuid4())
    if action in ('use-provider', 'skip-provider'):
        enabled = action == 'use-provider'
        path = account_path(mid) + '/preference'
        row = c.request(path, body={'enabled': enabled}, method='PUT')
        if row.get('id') != mid or row.get('user_enabled') is not enabled:
            raise ValueError('unconfirmed provider preference')
        return
    if action.startswith('bulk-'):
        return bulk_write(c, action.removeprefix('bulk-'), key)
    if action == 'create':
        payload = sys.stdin.buffer.read().decode()
        directory, separator, settings = payload.partition('\0')
        values = (settings if separator else payload).split('\t', 6)
        body = {'title': 'New mission'}
        if separator and directory:
            if not directory.startswith('/'):
                raise ValueError('expected an absolute working directory')
            body['working_directory'] = directory
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


def list_directories(binding, machine, path):
    c = Connection()
    if c.binding != binding:
        raise ValueError('connection changed')
    quote = urllib.parse.quote
    prefix = '/api' if machine == 'core' else '/api/remote-nodes/' + quote(machine, safe='')
    rows = c.request(prefix + '/fs/list?' + urllib.parse.urlencode({'path': path or '.'}), deadline=18)
    if not isinstance(rows, list):
        raise ValueError('invalid folder list')
    print('directories')
    for row in sorted(rows, key=lambda item: str(item.get('name', '')).casefold()):
        name, full = row.get('name'), row.get('path')
        if (row.get('kind') == 'dir' and name and name not in ('.', '..') and isinstance(full, str)
                and full.startswith('/') and full.isprintable()):
            print('D', full, label(name), sep='\t')


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
    if 'antigravity' in by_id:
        yield ('native-antigravity',)
    for backend in ('claudecode', 'codex', 'grok', 'opencode', 'vibe'):
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


def native_models(binding, machine):
    c = Connection()
    if c.binding != binding or not machine:
        return
    query = '' if machine == 'core' else '?' + urllib.parse.urlencode({'node_id': machine})
    pairs = c.request('/api/providers/antigravity-models' + query, deadline=20)
    rows = []
    if not isinstance(pairs, list):
        raise ValueError('invalid native catalog')
    for pair in pairs:
        if not isinstance(pair, list) or len(pair) != 2:
            raise ValueError('invalid native model entry')
        ident, name = pair
        if not isinstance(ident, str) or not ident or label(ident) != ident or not isinstance(name, str):
            raise ValueError('invalid native model')
        rows.append(('N', ident, label(name) or ident))
    c.check()
    print('native-models')
    for row in rows:
        print('\t'.join(row))


def launch_machine_rows(fleet, administrative, harness):
    capability = fleet.get('remote_launch') or {}
    if fleet['enabled'] is not True or capability.get('typed') is not True:
        return
    if harness and harness not in (capability.get('harnesses') or []):
        return
    if capability.get('proxy_url_configured') is False and harness in (capability.get('requires_proxy_harnesses') or []):
        return
    for node in fleet['nodes']:
        ident = node['id']
        if not isinstance(ident, str) or not ident or label(ident) != ident:
            raise ValueError('invalid node identifier')
        labels = {v.strip().lower() for v in node.get('labels', [])}
        admin_only = (node.get('admin_only') or node.get('core_colocated') or 'admin-only' in labels or
                      ident in ('core', 'agent-core', 'dgx-spark-admin'))
        manual_admin = administrative and ident == 'dgx-spark-admin' and {'administration', 'manual-only'} <= labels
        if (admin_only and not administrative) or (node.get('cordoned') and not manual_admin):
            continue
        if node['status'] not in ('online', 'degraded') or harness in (node.get('quarantined_harnesses') or []):
            continue
        if ident != 'core':
            yield ('R', ident, node.get('display_name') or ident)


def launch_machines(binding, role, harness):
    c = Connection()
    if c.binding != binding:
        return
    rows = list(launch_machine_rows(c.request('/api/remote-nodes', deadline=15), role == 'admin', harness))
    c.check()
    print('machines')
    for row in rows:
        print('\t'.join(map(label, row)))


def provider_inventory(binding):
    c = Connection()
    if c.binding != binding:
        return
    accounts = read_snapshot(lambda: c.get('/api/ai/providers'))
    if isinstance(accounts, dict):
        accounts = accounts['providers']
    if not isinstance(accounts, list):
        raise ValueError('invalid providers')
    rows = []
    for account in accounts:
        ident = account['id']
        if not isinstance(ident, str) or not ident or label(ident) != ident:
            raise ValueError('invalid account identifier')
        name = account.get('label') or account.get('name') or ident
        category = account.get('provider_type_name') or account.get('provider_type')
        rows.append(('A', ident, name, category, str(int(account.get('user_enabled', True))),
                     str(int(account.get('globally_enabled', account['enabled']))), account.get('provider_type', '')))
    c.check()
    print('accounts')
    for row in rows:
        print('\t'.join(map(label, row)))


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
    rows += [('P', p['slug'], p.get('title') or p['slug'], p.get('objective'), p.get('color')) for p in projects]
    rows += [('M', *(m.get(k) for k in ('id','title','project','track','model','model_override',
                                        'status','updated_at','created_at','short_description')), *mission_settings(m), *mission_hierarchy(m))
             for m in missions if re.fullmatch(r'[A-Za-z0-9_-]{1,128}', m['id'])]
    rows += [('N', *(m.get(k) for k in ('id','name','role','provider','cpu_ram','size','state',
                                        'status','expires_at','cost','active_missions'))) for m in machines]
    c.check()
    return rows


def read_snapshot(read, attempts=None):
    delay = 1
    while True:
        try:
            return read()
        except (urllib.error.URLError, TimeoutError) as error:
            if isinstance(error, urllib.error.HTTPError):
                if error.code not in (408, 429, 500, 502, 503, 504):
                    raise
                error.close()
            if attempts is not None:
                attempts -= 1
                if attempts == 0:
                    raise
            time.sleep(delay)
            delay = min(30, 2 * delay)


def roster():
    c = Connection()
    rows = read_snapshot(lambda: roster_rows(c, include_archived=True), attempts=2)
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
    rows = read_snapshot(lambda: list(catalog_rows(c, rules)))
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
        line = sys.stdin.readline()
        if not line.endswith('\n'):
            return
        tracked = set(filter(None, line.rstrip('\n').split(',')))
    if not all(re.fullmatch(r'[A-Za-z0-9_-]{1,128}', i) for i in tracked):
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
                tracked.update(found)
                # A full sampled row owns its metadata. Displaced authorized
                # missions keep their last row until an explicit denial.
                visible = ['\x1c'.join(map(label, row)) for row in rows if row[0] in ('P', 'M', 'N')]
                visible.extend('K\x1c' + ident for ident in sorted(tracked - found))
                checked = time.monotonic()
            current = ['sample', visible.copy(), None]
            if mid and mid in tracked:
                try:
                    current[2] = projection(c, mid)
                except urllib.error.HTTPError as error:
                    if error.code not in (403, 404):
                        raise
                    visible = [row for row in visible if row.split('\x1c', 2)[:2] not in (['K', mid], ['M', mid])]
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
            keys = '=' if last is not None and current[1] == last[1] else '+' + '\x1f'.join(current[1])
            if isinstance(current[2], list):
                title, status, text = current[2]
                fields = ('B', keys, title, status, text.replace('\n', '\x1e').replace('\t', '\x1f'))
            else:
                fields = ('R', keys)
            print('\t'.join(fields), flush=True)
            last = current
        time.sleep(1)
