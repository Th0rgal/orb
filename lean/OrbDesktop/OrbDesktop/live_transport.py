"""Embedded native client. stdout is private projection IPC, never diagnostics."""
from datetime import datetime, timedelta, timezone
import hashlib
import json
import os
import re
import signal
import sys
import time
import textwrap
import urllib.error
import urllib.parse
import urllib.request
import uuid


CURRENT_MISSION_LIMIT = 200
ARCHIVED_MISSION_LIMIT = 100
# Page size for on-demand older transcript reads (/events?before_seq=...&view=transcript).
# Initial bootstrap reads only the /open bundle so first paint stays fast; older pages
# load incrementally when the reader nears the top or activates "Load older turns".
OLDER_PAGE_LIMIT = 200
# Bounded skip when a timeline segment contains only non-transcript events.
EMPTY_PAGE_SKIP_LIMIT = 10


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
    if config is None:
        raise FileNotFoundError("no saved connection")
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


class ResponseTooLarge(ValueError):
    pass


class InvalidConnection(ValueError):
    pass


class Connection:
    def __init__(self):
        try:
            self.creds = credentials()
        except (ValueError, KeyError, StopIteration, TypeError, AttributeError) as error:
            raise InvalidConnection() from error
        self.binding = hashlib.sha256(json.dumps(self.creds).encode()).hexdigest()
        self.opener = urllib.request.build_opener(NoRedirect())

    def check(self):
        if credentials() != self.creds:
            raise ValueError('connection changed')

    def get(self, path, cap=4 << 20, *, deadline=6, headers_out=False):
        """The one bounded GET implementation every read goes through. With
        ``headers_out`` it returns ``(json, lowercased headers)`` so event pages can
        read the ``X-Has-More`` / ``X-Next-Cursor`` continuation headers the same way
        the web client drives its older-spine paging."""
        self.check()
        base, token = self.creds
        req = urllib.request.Request(base + path, headers={'Authorization': 'Bearer ' + token,
                                                           'Accept': 'application/json', 'Cache-Control': 'no-cache'})
        previous = signal.signal(signal.SIGALRM, request_timeout)
        signal.setitimer(signal.ITIMER_REAL, deadline)
        try:
            with self.opener.open(req, timeout=deadline if deadline > 6 else 4) as response:
                if response.status == 206 and (path == INBOX_PATH or path.startswith('/api/control/missions?')
                                               or path.endswith('?include_history=false')):
                    raise ValueError('incomplete Core summary response')
                data = response.read(cap + 1)
                page_headers = {name.lower(): value for name, value in response.headers.items()}
        finally:
            signal.alarm(0)
            signal.signal(signal.SIGALRM, previous)
        self.check()
        if len(data) > cap:
            raise ResponseTooLarge('response too large')
        body = json.loads(data) if data else None
        return (body, page_headers) if headers_out else body

    def get_page(self, path, cap=4 << 20, deadline=6):
        return self.get(path, cap, deadline=deadline, headers_out=True)

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
        signal.setitimer(signal.ITIMER_REAL, deadline)
        try:
            with self.opener.open(req, timeout=deadline if deadline > 6 else 4) as response:
                if response.status == 206 and (path == INBOX_PATH or path.startswith('/api/control/missions?')
                                               or path.endswith('?include_history=false')):
                    raise ValueError('incomplete Core summary response')
                data = response.read(cap + 1)
        finally:
            signal.alarm(0)
            signal.signal(signal.SIGALRM, previous)
        self.check()
        if len(data) > cap:
            raise ResponseTooLarge('response too large')
        return json.loads(data) if data or body is None else None


class MissionNotIdle(ValueError):
    pass


def run_mutation(binding, action, mid, message_id=''):
    try:
        mutate(binding, action, mid, message_id)
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
        tagged = 'archived' in (row.get('tags') or [])
        if row['id'] != mid or (not tagged and row['status'] != 'acknowledged') or (row.get('execution') or {}).get('state') == 'running':
            raise ValueError('mission not archived')
        if tagged:
            c.request(path + '/archive', body={'archived': False}, key=key + '-tag')
        if row['status'] == 'acknowledged':
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


ACCOUNT_VPN_POLL_SECONDS = 5


def account_path(account):
    if not isinstance(account, str) or not account or account in ('.', '..') or len(account) > 256:
        raise ValueError('invalid provider account')
    return '/api/ai/providers/' + urllib.parse.quote(account, safe='')


def valid_country(value):
    return isinstance(value, str) and re.fullmatch('[A-Z]{2}', value) is not None


def account_vpn_route(payload):
    """Mirror orb/src/accountVpn.ts `accountVpnRoute`."""
    if not isinstance(payload, dict) or not isinstance(payload.get('countries'), list):
        return None
    mode = payload.get('mode')
    if mode == 'vpn':
        country = payload.get('country')
        return payload if isinstance(country, str) and country else None
    return payload if mode == 'direct' else None


def account_vpn_view(route, native_account=False):
    """Mirror orb/src/accountVpn.ts `accountVpnView`."""
    vpn = route['mode'] == 'vpn'
    selected = route.get('country') if vpn and isinstance(route.get('country'), str) else ''
    offered = [country for country in route['countries'] if isinstance(country, str) and country]
    editable = route.get('can_configure') is True
    blocked = vpn and route.get('status') == 'blocked'
    pending = blocked and route.get('reason') == 'vpn_awaiting_verification'
    countries = list(dict.fromkeys(([selected] if selected else []) + offered))
    if not editable:
        cfg_msg = route.get('configuration_message')
        notice = cfg_msg if isinstance(cfg_msg, str) else 'VPN routing is unavailable for this credential.'
    elif offered:
        notice = ''
    else:
        notice = 'Import a named server profile in AirVPN Settings to enable VPN routing.'
    if vpn and route.get('status') == 'verified':
        server = route.get('server') if isinstance(route.get('server'), str) else ''
        raw_exits = route.get('exits')
        exits = [e for e in raw_exits if isinstance(e, str)] if isinstance(raw_exits, list) else []
        status = f"Verified exit · {server} · {', '.join(exits)}"
    elif blocked:
        msg = route.get('message')
        status = msg if isinstance(msg, str) else 'The VPN route is unavailable.'
    else:
        status = ''
    return {
        'selected': selected,
        'countries': countries,
        'editable': editable,
        'confirm_direct': bool(native_account) and editable and route['mode'] == 'direct' and route.get('saved') is not True,
        'notice': notice,
        'status': status,
        'retry': blocked and not pending,
        'poll': pending,
    }


def account_vpn_write(country):
    return {'mode': 'vpn', 'country': country} if country else {'mode': 'direct'}


def missing_account_setting(status, body, path):
    if status != 404 or not isinstance(body, str):
        return False
    try:
        parsed = json.loads(body)
    except ValueError:
        return False
    return isinstance(parsed, dict) and parsed.get('error') == 'not_found' and parsed.get('path') == path


def alternative_router_access(payload):
    if not isinstance(payload, dict):
        return None
    allowed = payload.get('allowed')
    return allowed if isinstance(allowed, bool) else None


def vpn_options_for_view(view):
    parts = [part for part in (view['status'], view['notice']) if part]
    if not view['editable'] and view['selected']:
        parts.insert(0, 'AirVPN · ' + view['selected'])
    if not parts:
        parts = ['AirVPN · ' + view['selected'] if view['selected'] else 'Direct']
    yield ('refresh' if not view['editable'] else '', '', 'Account connection', ' · '.join(parts))
    if view['editable']:
        for country in ('', *view['countries']):
            picked = country == view['selected']
            if picked:
                if view['retry']:
                    action, caption = 'vpn', 'Retry verification'
                elif not country and view['confirm_direct']:
                    action, caption = 'vpn', 'Confirm Direct route'
                else:
                    action, caption = '', 'Selected'
            else:
                action, caption = 'vpn', ''
            yield (action, country, 'AirVPN · ' + country if country else 'Direct', caption)


def vpn_options(route, native_account=False):
    validated = account_vpn_route(route)
    if validated is None:
        raise ValueError('invalid account route')
    yield from vpn_options_for_view(account_vpn_view(validated, native_account))


def router_options(settings):
    allowed = alternative_router_access(settings)
    if allowed is None:
        raise ValueError('invalid alternative-router setting')
    yield ('routers', 'off' if allowed else 'on', 'Alternative routers',
           'Allowed · OpenCode and other routed clients' if allowed else 'Off · Native Antigravity only')


def account_route_state(c, account, antigravity):
    base = account_path(account)
    sections = [('vpn', 'Account connection', 'vpn')]
    if antigravity:
        sections.append(('alternative-routers', 'Alternative routers', 'routers'))
    rows = []
    should_poll = False
    for suffix, title, kind in sections:
        try:
            payload = c.get(base + '/' + suffix)
            if kind == 'vpn':
                route = account_vpn_route(payload)
                if route is None:
                    raise ValueError('invalid account route')
                view = account_vpn_view(route, antigravity)
                should_poll = view['poll']
                section_rows = list(vpn_options_for_view(view))
            else:
                section_rows = list(router_options(payload))
        except urllib.error.HTTPError as error:
            with error:
                if error.code == 401:
                    raise
                if error.code in (403, 404):
                    continue
            section_rows = [('refresh', '', title, 'Could not load. Retry')]
        except (OSError, ValueError, KeyError, TypeError):
            section_rows = [('refresh', '', title, 'Could not load. Retry')]
        rows.extend(section_rows)
    return rows, should_poll


def account_route_rows(c, account, antigravity):
    rows, _ = account_route_state(c, account, antigravity)
    yield from rows


def save_account_route(c, account, action, value):
    base = account_path(account)
    if action == 'vpn':
        if value and not valid_country(value):
            raise ValueError('invalid country choice')
        body = account_vpn_write(value)
        # Core verifies both exit addresses and waits for the new AirVPN session.
        result = c.request(base + '/vpn', body=body, method='PUT', deadline=120)
        confirmed = account_vpn_route(result)
        if confirmed is None or confirmed['mode'] != body['mode'] or (value and confirmed.get('country') != value):
            raise ValueError('unconfirmed account connection')
    elif action == 'routers':
        if value not in ('off', 'on'):
            raise ValueError('invalid router choice')
        body = {'allowed': value == 'on'}
        result = c.request(base + '/alternative-routers', body=body, method='PUT')
        if alternative_router_access(result) is not body['allowed']:
            raise ValueError('unconfirmed router setting')
    else:
        raise ValueError('unknown route setting')


def account_routes(binding, account, provider, action, value, poll=''):
    if poll == 'poll' and not action:
        time.sleep(ACCOUNT_VPN_POLL_SECONDS)
    c = Connection()
    if c.binding != binding:
        return
    confirmed = True
    if action:
        try:
            save_account_route(c, account, action, value)
        except (ValueError, OSError):
            confirmed = False
    rows, should_poll = account_route_state(c, account, provider == 'antigravity')
    c.check()
    header = 'routes' if confirmed else 'unconfirmed'
    print(header + ('\tpoll' if should_poll else ''))
    if not rows:
        rows = [('', '', 'Account connection', 'Routing controls are unavailable for this account on this Core.')]
    for row in rows:
        print('\t'.join(map(label, ('D', *row))))


def mutate(binding, action, mid, message_id=''):
    c = Connection()
    if c.binding != binding:
        raise ValueError('connection changed')
    key = str(uuid.UUID(message_id)) if action == 'send' else str(uuid.uuid4())
    if action == 'cloud-create':
        attempt, provider, account, project, prompt = sys.stdin.buffer.read().decode().split('\n', 4)
        attempt = attempt or key
        print(attempt, flush=True)
        row = c.request('/api/control/missions', key=attempt, body={
            'idempotency_key': attempt, 'title': prompt[:100], 'prompt': prompt, 'project': project,
            'cloud': {'provider': provider, 'account': account}})
        if not re.fullmatch(r'[A-Za-z0-9_-]{1,128}', row['id']):
            raise ValueError('invalid cloud mission')
        print(row['id'])
        return
    if action == 'inbox-read':
        if not re.fullmatch(r'[A-Za-z0-9_-]{1,128}', mid):
            raise ValueError('invalid mission')
        stamp, version = map(int, sys.stdin.read().split())
        c.request(INBOX_PATH + '/seen/' + mid, method='PUT', body={
            'stamp': stamp, 'expectedVersion': version, 'clientId': key, 'mutationSeq': 1})
        return
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
    if action == 'cloud-cancel':
        c.request(path + '/cloud/cancel', method='POST', body={})
    elif action == 'cloud-send':
        attempt, content = sys.stdin.buffer.read().decode().split('\n', 1)
        if not attempt:
            attempt = key
        print(attempt, flush=True)
        receipt = c.request('/api/control/message', body={'mission_id': mid, 'content': content,
                  'client_message_id': attempt}, key='msg:' + mid + ':' + attempt)
        if receipt.get('message_accepted') is False:
            raise ValueError('message refused')
    elif action == 'send':
        try:
            receipt = c.request('/api/control/message', body={'mission_id': mid, 'content': sys.stdin.buffer.read().decode(),
                                'queue_followup': True, 'client_message_id': key}, key='msg:' + mid + ':' + key)
        except urllib.error.HTTPError as e:
            if e.code == 409:
                refusal = json.loads(e.read(4096))
                if refusal.get('id') == key and refusal.get('message_accepted') is False and refusal.get('error') == 'local_run_busy':
                    raise MissionNotIdle() from e
            raise
        if receipt.get('id') != key or receipt.get('message_accepted') is False:
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


def resource_inventory(binding, window):
    c = Connection()
    if c.binding != binding:
        return
    overview = c.request('/api/resources/overview?' + urllib.parse.urlencode({'range': window}), deadline=30)
    rows = []
    for kind, items in (('Inference', overview['inference']['pools']),
                        ('Compute', overview['compute']['sources']),
                        ('Mission', overview['missions'])):
        if not isinstance(items, list):
            raise ValueError('invalid resource inventory')
        for item in items:
            mission = ''
            if kind == 'Mission':
                mission = item['id']
                if not mission or label(mission) != mission:
                    raise ValueError('invalid mission identifier')
                name = item['title'] or mission
                usage = f"{item['status']} · {item['vcpu']:g} vCPU · {item['b_tok_per_h']:g} B tok/h"
            elif kind == 'Compute':
                name = item['label']
                usage = f"{item['active_vcpu']:g}/{item['total_vcpu']:g} vCPU · ${item['est_usd_per_h']:g}/h"
            else:
                name = item['label']
                usage = f"{item['current_b_tok_per_h']:g} B tok/h · ${item['est_usd_per_h']:g}/h"
            rows.append(('R', mission, f'{kind} · {name}', usage))
    c.check()
    print('resources')
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


INBOX_PATH = '/api/control/inbox-state'
NEEDS_ATTENTION = {'awaiting_user', 'waiting_user', 'failed', 'blocked', 'not_feasible'}
READY = {'completed', 'succeeded', 'paused', 'interrupted'}
MILLISECOND = timedelta(milliseconds=1)


def timestamp_ms(value):
    if not isinstance(value, str) or not value:
        return None
    try:
        instant = datetime.fromisoformat(value.replace('Z', '+00:00'))
        elapsed = instant.astimezone(timezone.utc) - datetime(1970, 1, 1, tzinfo=timezone.utc)
        return elapsed // MILLISECOND
    except (OverflowError, ValueError):
        return None


def response_stamp(m):
    return max(timestamp_ms(m.get(k)) or 0 for k in ('updated_at', 'created_at', 'last_output_at'))


def response_unread(m, state, selected, stamp):
    if selected == m['id']:
        return False
    seen = state.get('seen:' + m['id'])
    if seen is not None and seen < 0 and stamp <= -seen + 1000:
        return True
    if m.get('first_viewed_at'):
        viewed = timestamp_ms(m['first_viewed_at'])
        if viewed is None or stamp <= 0 or viewed + 2000 >= stamp:
            return False
    return seen is None or seen < 0 or seen < stamp


def client_placement(m):
    kind = (m.get('placement_kind') or '').strip()
    if kind:
        return kind == 'client' or kind.startswith('client:')
    return m.get('origin') == 'orb-client' or 'placement:client' in (m.get('tags') or [])


def btw_ids(by_id):
    """Resolve archived or later-page ancestors once, including cyclic legacy links."""
    known = {}
    for mid in by_id:
        path = set()
        current = mid
        while current in by_id and current not in known and current not in path:
            m = by_id[current]
            path.add(current)
            tags = m.get('tags') or []
            if any(t.startswith('btw-parent:') or t == 'btw-subagent' for t in tags):
                known[current] = True
                break
            parent = m.get('parent_mission_id')
            # Core rows have already passed stickHierarchy in the GTK client.
            # isBtwMission falls back to that observed parent even for a fork.
            fork = next((t[8:] for t in tags if t.startswith('fork-of:')), None)
            current = (parent if parent != fork else None) or m.get('callback_parent_mission_id') or parent
        known.update(dict.fromkeys(path, known.get(current, False)))
    return {mid for mid, excluded in known.items() if excluded}


def inbox_rows(missions, state, projects=(), selected=''):
    prefs = state.get('preferences') or {}
    if prefs.get('inboxEnabled') is False:
        return [('I', 'disabled')]
    excluded = btw_ids({m['id']: m for m in missions})
    slugs = {'default', *(p['slug'] for p in projects)}
    failed_parents = set()
    rows = []
    for m in missions:
        mid, status = m['id'], m.get('status')
        if mid in excluded or status not in NEEDS_ATTENTION | READY or (m.get('superseded_by_mission_id') or '').strip():
            continue
        if not re.fullmatch(r'[A-Za-z0-9_-]{1,128}', mid):
            continue
        parent = inbox_parent(m)
        tags = m.get('tags') or []
        stamp = response_stamp(m)
        unread = response_unread(m, state, selected, stamp)
        if prefs.get('includeAutonomous'):
            if parent and unread and status in ('failed', 'blocked', 'not_feasible'):
                failed_parents.add(parent)
        elif (parent or m.get('origin') == 'hermes'
              or re.match(r'you are a sub-?agent\b', (m.get('title') or '').strip(), re.I)
              or any(t.startswith('worker-dispatch:') or t in ('origin:hermes', 'origin:hermes-assistant') for t in tags)):
            continue
        slug = (m.get('project') or '').strip()
        if projects and ((not slug and not client_placement(m)) or (slug or 'default') not in slugs):
            continue
        if status == 'interrupted' and m.get('terminal_reason') == 'usage_limit_wait' and m.get('recovery') is not None:
            continue
        rows.append((status not in NEEDS_ATTENTION, -stamp, mid, unread))
    # Solid's sort preserves input order for equal category and response time.
    rows.sort(key=lambda r: r[:2])
    return [('I', 'enabled')] + [
        ('U', mid, max(1, -negative_stamp), str(state.get('_versions', {}).get('seen:' + mid, 0)))
        for _, negative_stamp, mid, unread in rows if unread or mid in failed_parents]


def inbox_parent(m):
    _, parent, callback, fork, _ = mission_hierarchy(m)
    return (parent if parent != fork else None) or callback


INBOX_READ_SECONDS = 4
INBOX_PROJECT_REFRESH_SECONDS = 30
MISSING_ANCESTOR = object()


class InboxWindows:
    """One subscription owns the staged reads and its last complete project windows."""
    def __init__(self):
        self.last_progress = 0
        self.scope = None
        self.pages = {}
        self.project_sources = None
        self.project_refresh_at = 0


def inbox_with_ancestors(get, rows, known):
    """Match withAncestors: insert fetched parents immediately before their first child."""
    known.update((m['id'], m) for m in rows)
    listed = {m['id'] for m in rows}
    fetched = {}
    frontier = rows
    for _ in range(8):
        wanted = dict.fromkeys(inbox_parent(m) for m in frontier)
        frontier = []
        for mid in wanted:
            if not mid or mid in listed or mid in fetched:
                continue
            if mid not in known:
                try:
                    ancestor = get('/api/control/missions/' + urllib.parse.quote(mid, safe='') + '?include_history=false')
                except urllib.error.HTTPError as error:
                    if error.code not in (403, 404):
                        raise
                    error.close()
                    ancestor = None
                else:
                    if ancestor is MISSING_ANCESTOR:
                        ancestor = None
                    elif not isinstance(ancestor, dict) or ancestor.get('id') != mid:
                        raise ValueError('invalid mission ancestor')
                known[mid] = ancestor
            ancestor = known[mid]
            if ancestor:
                fetched[mid] = ancestor
                frontier.append(ancestor)
        if not frontier:
            break
    ordered = {}
    for row in rows:
        chain = {row['id']: row}
        parent = inbox_parent(row)
        while parent in fetched and parent not in ordered and parent not in chain:
            chain[parent] = fetched[parent]
            parent = inbox_parent(fetched[parent])
        ordered.update(reversed(chain.items()))
    return ordered.values()


def inbox_snapshot(c, projects, selected, rules=None, windows=None, roster=None):
    windows = windows or InboxWindows()
    projects = [p for p in projects if p.get('status') not in ('archived', 'deleted')]
    scope = tuple(p['slug'] for p in projects)
    now = time.monotonic()
    if scope != windows.scope or now - windows.last_progress >= 60:
        windows.pages.clear()
        windows.project_sources = None
        windows.scope = scope
        windows.last_progress = now
    end = now + INBOX_READ_SECONDS

    def read(path):
        remaining = end - time.monotonic()
        if remaining <= 0:
            raise TimeoutError('inbox read deadline')
        return c.get(path, 8 << 20, deadline=remaining)

    def source_read(path):
        if path not in windows.pages:
            collection = path.startswith('/api/control/missions?')
            try:
                data = read(path)
            except urllib.error.HTTPError as error:
                if collection or error.code not in (403, 404):
                    raise
                error.close()
                data = MISSING_ANCESTOR
            else:
                if collection:
                    if not isinstance(data, list) or any(not isinstance(m, dict) or not m.get('id') for m in data):
                        raise ValueError('invalid inbox window')
                elif not isinstance(data, dict) or data.get('id') != urllib.parse.unquote(path.split('?')[0].rsplit('/', 1)[-1]):
                    raise ValueError('invalid mission ancestor')
            windows.pages[path] = data
            windows.last_progress = time.monotonic()
        return windows.pages[path]

    state = read(INBOX_PATH)
    if (not isinstance(state, dict) or not isinstance(state.get('_versions', {}), dict)
            or not isinstance(state.get('preferences') or {}, dict)):
        raise ValueError('invalid inbox state')
    if (state.get('preferences') or {}).get('inboxEnabled') is False:
        windows.pages.clear()
        windows.project_sources = None
        return [('I', 'disabled')]
    refresh_projects = windows.project_sources is None or now >= windows.project_refresh_at
    if refresh_projects:
        hidden = set()
        project_rows = [project_history(source_read, slug, rules, inbox_hidden=hidden) for slug in scope]
    else:
        project_rows, hidden = windows.project_sources
    completed = source_read('/api/control/missions?status=completed&limit=100')
    # Core sorts the page and its context together. Its first 200 non-archived
    # rows are the original page; the other rows can satisfy ancestor lookups.
    known = {m['id']: m for m in roster} if roster is not None else {}
    current = (source_read(f'/api/control/missions?limit={CURRENT_MISSION_LIMIT}') if roster is None else
               [m for m in roster if m.get('status') not in ('acknowledged', 'archived')][:CURRENT_MISSION_LIMIT])
    current = inbox_with_ancestors(source_read, current, known)
    result = project_inbox([*project_rows, completed, current], state, projects, selected, hidden)
    if refresh_projects:
        windows.project_sources = (project_rows, hidden)
        windows.project_refresh_at = time.monotonic() + INBOX_PROJECT_REFRESH_SECONDS
    windows.pages.clear()
    return result


def project_inbox(sources, state, projects, selected, hidden=()):
    by_id = {}
    for source in sources:
        for m in source:
            if m['id'] in hidden:
                continue
            previous = by_id.get(m['id'])
            if previous is None or (timestamp_ms(m.get('updated_at') or m.get('created_at')) or 0) >= (
                    timestamp_ms(previous.get('updated_at') or previous.get('created_at')) or 0):
                by_id[m['id']] = m
    rows = inbox_rows(by_id.values(), state, projects, selected)
    # An off-page Inbox item carries the same summary as a sidebar mission.
    # It enters the sidebar only when its transcript is opened.
    return [(*r, *mission_row(by_id[r[1]])) if r[0] == 'U' else r for r in rows]


def mission_row(m):
    return ('M', *(m.get(k) for k in ('id','title','project','track','model','model_override',
                                      'status','updated_at','created_at','short_description')),
            *mission_settings(m), *mission_hierarchy(m), str(int('archived' in (m.get('tags') or []))))


def project_history(get, slug, rules, *, inbox_hidden=None):
    """Project history plus older open work under the shared desktop policy."""
    page_size = rules['pageSize']
    query = '/api/control/missions?project=' + urllib.parse.quote(slug, safe='') + f'&limit={page_size}'
    history = get(query + '&all=true')
    if not isinstance(history, list):
        raise ValueError('invalid project history')
    known = {row['id']: row for row in history}
    members = dict(known)
    candidates = {}
    cutoff = time.time() - rules['recentDays'] * 86400
    # The open query is a subset of the all-status query. A short all-status
    # page exhausts both collections, including tag-only archives.
    open_limit = rules['openLimit'] if len(history) >= page_size else 0
    for offset in range(0, open_limit, page_size):
        page = get(query + (f'&offset={offset}' if offset else ''))
        if not isinstance(page, list):
            raise ValueError('invalid project page')
        for row in page:
            mid = row['id']
            known.setdefault(mid, row)
            if mid in members:
                continue
            status = row.get('status')
            if status in rules['recent']:
                try:
                    when = datetime.fromisoformat(row.get('updated_at') or row.get('created_at') or '').timestamp()
                except ValueError:
                    continue
                if when < cutoff:
                    continue
            elif status not in rules['live']:
                continue
            candidates[mid] = row
        if len(page) < page_size:
            break
    for mid, row in candidates.items():
        parent = row.get('parent_mission_id') or row.get('callback_parent_mission_id')
        if not parent or parent in members or parent in candidates or row.get('status') in rules['live']:
            members[mid] = row
    if inbox_hidden is not None:
        ordered = sorted(members.values(), key=lambda m: timestamp_ms(m.get('updated_at') or m.get('created_at')) or 0,
                         reverse=True)
        expanded = inbox_with_ancestors(get, ordered, known)
        inbox_hidden.update(btw_ids({mid: m for mid, m in known.items() if m is not None}))
        return [m for m in expanded if m['id'] in members or m.get('project') == slug]
    unavailable = set()
    ancestor_reads = 0
    for row in list(members.values()):
        current = row
        visited = {row['id']}
        while True:
            _, launch, callback, fork, _ = mission_hierarchy(current)
            parent = (launch if launch != fork else None) or callback
            if not parent or parent in visited or parent in unavailable:
                break
            visited.add(parent)
            if parent not in known:
                if ancestor_reads >= rules['openLimit']:
                    raise ValueError('project ancestor limit exceeded')
                ancestor_reads += 1
                try:
                    ancestor = get('/api/control/missions/' + urllib.parse.quote(parent, safe='') + '?include_history=false')
                except urllib.error.HTTPError as error:
                    if error.code not in (403, 404):
                        raise
                    unavailable.add(parent)
                    break
                if not isinstance(ancestor, dict) or ancestor.get('id') != parent:
                    raise ValueError('invalid project ancestor')
                known[parent] = ancestor
            current = known[parent]
            if (current.get('project') or '__unassigned__') == slug:
                members.setdefault(parent, current)
    def visible(row):
        visited = set()
        while row and row['id'] not in visited:
            visited.add(row['id'])
            tags = row.get('tags') or []
            if any(t == 'btw-subagent' or t.startswith('btw-parent:') for t in tags):
                return False
            _, launch, callback, fork, _ = mission_hierarchy(row)
            row = known.get((launch if launch != fork else None) or callback)
        return True
    return [row for row in members.values() if visible(row) and row.get('viewer_role') != 'participant']


def mission_rows(missions):
    return [mission_row(m) for m in missions if re.fullmatch(r'[A-Za-z0-9_-]{1,128}', m['id'])]


def roster_rows(c, include_archived=False, expanded=(), rules=None, publish_project=None, *, inbox_for=None, inbox_windows=None):
    projects = c.get('/api/projects')['projects']
    if not isinstance(projects, list):
        raise ValueError('invalid projects')
    groups = []
    by_project = {}
    def read_project(path):
        return read_snapshot(lambda: c.get(path), attempts=2)

    for slug in dict.fromkeys(expanded):
        if not any(p.get('slug') == slug for p in projects):
            continue
        members = project_history(read_project, slug, rules)
        if slug == 'default':
            members += project_history(read_project, '__unassigned__', rules)
        listed = {m['id']: m for m in members if (m.get('project') or 'default') == slug}
        group = ('G', slug, *sorted(listed))
        groups.append(group)
        by_project.update(listed)
        # Expansion prepends the clicked slug. Previously open projects can
        # refresh in the full sample without delaying the newly opened one.
        if len(groups) == 1 and publish_project:
            c.check()
            publish_project([('partial-projects',), group, *mission_rows(listed.values())])

    def get(path):
        if groups:
            return read_snapshot(lambda: c.get(path), attempts=2)
        return c.get(path)

    missions = get(f'/api/control/missions?limit={CURRENT_MISSION_LIMIT}&include_ancestors=true')
    machines = get('/api/machines')
    if not all(isinstance(x, list) for x in (projects, missions, machines)):
        raise ValueError('invalid roster')
    current = list(missions)
    if include_archived:
        try:
            archived = get(f'/api/control/missions?status=acknowledged&limit={ARCHIVED_MISSION_LIMIT}')
            known = {r['id'] for r in missions}
            missions += [r for r in archived if r.get('status') == 'acknowledged' and r['id'] not in known]
        except urllib.error.HTTPError as error:
            if error.code != 404:
                raise
    rows = [('C', c.binding), *groups]
    if inbox_for is not None:
        try:
            rows += inbox_snapshot(c, projects, inbox_for, rules, inbox_windows, current)
        except urllib.error.HTTPError as error:
            if error.code in (401, 403):
                raise
            error.close()
            rows.append(('I', 'refreshing'))
        except (urllib.error.URLError, TimeoutError, ValueError, KeyError, TypeError):
            rows.append(('I', 'refreshing'))
    if groups:
        by_id = {m['id']: m for m in missions}
        by_id.update(by_project)
        missions = by_id.values()
    rows += [('P', p['slug'], p.get('title') or p['slug'], p.get('objective'), p.get('color')) for p in projects]
    rows += mission_rows(missions)
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


def account_identity(c):
    try:
        me = c.get('/api/auth/me')
    except urllib.error.HTTPError as error:
        if error.code != 404:
            raise
        error.close()
        me = c.get('/api/auth/status')
    if not isinstance(me, dict) or not isinstance(me.get('user') or {}, dict):
        raise ValueError('invalid account response')
    if me.get('authenticated') is False and me.get('auth_required', True):
        raise urllib.error.HTTPError(c.creds[0], 401, 'Sign in required', {}, None)
    return ('A', c.creds[0], (me.get('user') or {}).get('username', ''))


def observe_account(binding):
    # A selected Settings page also detects outages when the roster is retrying.
    time.sleep(3)
    c = Connection()
    if c.binding == binding:
        row = account_identity(c)
        c.check()
        print('\t'.join(map(label, row)))


def roster():
    c = Connection()
    rows = read_snapshot(lambda: roster_rows(c, include_archived=True), attempts=2)
    rows.append(account_identity(c))
    c.check()
    for row in rows:
        print('\t'.join(map(label, row)))


def recover_roster(previous):
    """Wait for a valid saved session and a complete roster after disconnection."""
    delay = 1
    while True:
        try:
            roster()
            return
        except (OSError, ValueError, KeyError, StopIteration, TypeError) as error:
            reason = 'unavailable'
            if isinstance(error, FileNotFoundError):
                reason = 'missing'
            elif isinstance(error, InvalidConnection):
                reason = 'invalid'
            elif isinstance(error, urllib.error.HTTPError):
                reason = {401: 'signin', 403: 'denied'}.get(error.code, reason)
                error.close()
            if reason != previous:
                print('F\t' + reason)
                return
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


def row_identity(r):
    """Stable event/row identifier for cross-page transcript deduplication."""
    rid = r.get('id')
    if rid is not None and str(rid) != '':
        clean = ''.join(ch for ch in str(rid)[:128] if ch.isprintable() and ch not in '\t\r\n')
        if clean:
            return 'id:' + clean
    seq = r.get('sequence')
    if isinstance(seq, int):
        kind = ''.join(ch for ch in str(r.get('event_type') or '')[:48] if ch.isprintable() and ch not in '\t\r\n')
        content_raw = str(r.get('content') or '')
        digest = hashlib.sha256(content_raw.encode('utf-8')).hexdigest()[:12]
        return f'seq:{seq}:{kind}:{digest}'
    return ''


def dedup_event_rows(rows):
    """Keep the first copy of each row by event/row ID and fallback tuple so
    overlapping pages never duplicate a turn."""
    seen_ids = set()
    seen_keys = set()
    unique_rows = []
    for r in rows:
        if not isinstance(r, dict):
            continue
        rid = r.get('id')
        id_key = str(rid) if rid is not None and str(rid) != '' else None
        fallback_key = (r.get('sequence'), r.get('event_type'), r.get('content'))
        if (id_key is not None and id_key in seen_ids) or fallback_key in seen_keys:
            continue
        if id_key is not None:
            seen_ids.add(id_key)
        seen_keys.add(fallback_key)
        unique_rows.append(r)
    return unique_rows


def extract_transcript_turns_with_kinds(rows, first_text=None):
    """Project Core event rows into ascending `(turn_id, text, sequence, kind)` tuples.
    `kind` distinguishes `'u'` (user prompt), `'p'` (unclaimed plain `assistant_message`),
    `'a'` (`assistant_message` already claimed by a canonical in this page), and `'c'`
    (unmatched `assistant_message_canonical` whose plain form may live in an older page).
    When `first_text` matches the newest persisted turn, the live bubble keeps owning it."""
    rows = dedup_event_rows(rows)
    turns = []
    for r in rows:
        kind = r.get('event_type')
        content = r.get('content')
        if kind not in ('user_message', 'assistant_message', 'assistant_message_canonical') \
                or not isinstance(content, str) or not content:
            continue
        content = ''.join(ch for ch in content if ch in '\n\t' or ch.isprintable())
        if content:
            seq = r.get('sequence')
            turns.append((seq if isinstance(seq, int) else 0, seq if isinstance(seq, int) else None,
                          kind, content, row_identity(r)))
    turns.sort(key=lambda item: item[0])
    entries = []
    unclaimed = []
    for _, seq, kind, content, tid in turns:
        if kind == 'user_message':
            entries.append((tid, 'You: ' + content, seq, 'u'))
            continue
        if kind == 'assistant_message':
            unclaimed.append(len(entries))
            entries.append((tid, content, seq, 'p'))
            continue
        claim = next((i for i in reversed(unclaimed) if entries[i][1] == content), None)
        if claim is not None:
            unclaimed.remove(claim)
            ctid, ctxt, cseq, _ = entries[claim]
            entries[claim] = (ctid, ctxt, cseq, 'a')
            continue
        entries.append((tid, content, seq, 'c'))
    if first_text is not None and entries and entries[-1][1] == first_text:
        entries.pop()
    return entries


def extract_transcript_turns(rows, first_text=None):
    """Project Core event rows into ascending `(turn_id, text, sequence)` tuples."""
    return [(tid, text, seq) for tid, text, seq, _ in extract_transcript_turns_with_kinds(rows, first_text)]


def _history_page_raw(c, mid, first_text=''):
    """Initial transcript window from `/open` with per-turn canonical/plain kind tags."""
    try:
        bundle = c.get('/api/control/missions/' + mid + '/open', 8 << 20)
    except urllib.error.HTTPError as error:
        if error.code in (401, 403):
            raise
        error.close()
        return ([], False, None)
    except (urllib.error.URLError, TimeoutError, ValueError, KeyError, TypeError):
        return ([], False, None)
    if not isinstance(bundle, dict):
        return ([], False, None)
    rows = []
    for key in ('events', 'spine'):
        page = bundle.get(key)
        if not isinstance(page, list):
            return ([], False, None)
        rows.extend(page)
    entries = extract_transcript_turns_with_kinds(rows, first_text)
    if isinstance(bundle.get('spine_has_more'), bool):
        has_more = bundle['spine_has_more']
        raw_cursor = bundle.get('spine_next_cursor')
        next_cursor = raw_cursor if has_more and isinstance(raw_cursor, int) else None
    elif bundle.get('has_more') is True and isinstance(bundle.get('next_cursor'), int):
        has_more = True
        next_cursor = bundle['next_cursor']
    else:
        has_more = False
        next_cursor = None
    if not has_more or next_cursor is None:
        has_more, next_cursor = False, None
    return (entries, has_more, next_cursor)


def history_page(c, mid, first_text=''):
    """Initial transcript window from the real `/open` bundle (events + initial
    spine) plus continuation metadata `(entries, has_more, next_cursor)` for
    on-demand older paging. First paint never walks earlier `/events` pages.
    Auth failures are not degradation: 401/403 re-raise so the caller's
    access-revoked path (which clears prior content) still runs."""
    entries, has_more, next_cursor = _history_page_raw(c, mid, first_text)
    return ([(tid, text, seq) for tid, text, seq, _ in entries], has_more, next_cursor)


def history_turns(c, mid, first_text):
    """Completed turns from the initial `/open` window, ascending."""
    entries, _, _ = history_page(c, mid, first_text)
    return [text for _, text, _ in entries]


def _older_history_page_raw(c, mid, before_seq, limit=OLDER_PAGE_LIMIT):
    """Fetch one on-demand older transcript page with per-turn canonical/plain kind tags."""
    cursor = int(before_seq)
    for _ in range(EMPTY_PAGE_SKIP_LIMIT):
        requested = cursor
        page, headers = c.get_page(
            '/api/control/missions/' + mid +
            f'/events?before_seq={requested}&view=transcript&limit={limit}')
        page_rows = page.get('events') if isinstance(page, dict) else page
        if not isinstance(page_rows, list):
            raise ValueError('invalid events page')
        seqs = [r.get('sequence') for r in page_rows
                if isinstance(r, dict) and isinstance(r.get('sequence'), int)]
        # Exclusive before-cursor semantics: a healthy page returns rows older
        # than the cursor it was asked with. A page whose oldest row sits at or
        # after the requested cursor would loop forever, so halt.
        if seqs and min(seqs) >= requested:
            return ([], False, None)
        older_rows = [r for r in page_rows
                      if isinstance(r, dict) and not (isinstance(r.get('sequence'), int) and r['sequence'] >= requested)]
        entries = extract_transcript_turns_with_kinds(older_rows)
        nxt = headers.get('x-next-cursor')
        has_more_hdr = headers.get('x-has-more')
        if has_more_hdr is not None:
            more = str(has_more_hdr).lower() == 'true' and isinstance(nxt, str) and nxt.lstrip('-').isdigit()
            next_cursor = int(nxt) if more else None
        elif isinstance(page, dict) and page.get('has_more') is True and isinstance(page.get('next_cursor'), int):
            more = True
            next_cursor = page['next_cursor']
        else:
            more = False
            next_cursor = None
        if not more or next_cursor is None or next_cursor >= requested:
            return (entries, False, None)
        if entries:
            return (entries, True, next_cursor)
        cursor = next_cursor
    return ([], True, cursor)


def older_history_page(c, mid, before_seq, limit=OLDER_PAGE_LIMIT):
    """Fetch one on-demand older transcript page before `before_seq` using the
    same exclusive before-cursor (`X-Has-More` / `X-Next-Cursor`) the web client
    uses. Returns `(entries, has_more, next_cursor)` with ascending entries.
    Auth failures (401/403) and transient HTTP/transport errors propagate to the
    caller so revocation clears content and 5xx preserves the retryable cursor."""
    entries, has_more, next_cursor = _older_history_page_raw(c, mid, before_seq, limit)
    return ([(tid, text, seq) for tid, text, seq, _ in entries], has_more, next_cursor)


def pack_history_frame(tag, entries, has_more, next_cursor, max_bytes=1 << 20):
    """Pack ascending `(turn_id, text, seq[, kind])` entries into one bounded IPC line.
    If the UTF-8 byte cap trims older entries from the head of a page, advertise their
    boundary sequence as `next_cursor` so no turns are dropped."""
    newest = []
    total = 0
    oldest_kept_seq = None
    trimmed = False
    for entry in reversed(entries):
        if len(entry) >= 4:
            tid, turn, seq, kind = entry[0], entry[1], entry[2], entry[3]
        else:
            tid, turn, seq, kind = entry[0], entry[1], entry[2], 'a'
        packed = tid + '\x1c' + kind + '\x1c' + turn.replace('\n', '\x1e').replace('\t', '\x1f')
        total += len(packed.encode('utf-8')) + 1
        if total > max_bytes and newest:
            trimmed = True
            break
        newest.append(packed)
        if isinstance(seq, int):
            oldest_kept_seq = seq
    newest.reverse()
    if trimmed and oldest_kept_seq is not None:
        has_more = True
        next_cursor = oldest_kept_seq
    flag = '1' if has_more and next_cursor is not None else '0'
    cursor_str = '' if flag == '0' else str(next_cursor)
    return f'{tag}\t{flag}\t{cursor_str}\t' + '\x1d'.join(newest)


def fetch_older_turns(mid, binding, before_seq):
    """One-shot reader for on-demand older transcript pages."""
    c = Connection()
    if c.binding != binding or not re.fullmatch(r'[A-Za-z0-9_-]{1,128}', mid):
        return
    cursor = int(before_seq)
    try:
        entries, has_more, next_cursor = _older_history_page_raw(c, mid, cursor)
    except urllib.error.HTTPError as error:
        if error.code in (403, 404):
            error.close()
            c.check()
            print('D', flush=True)
            return
        if error.code == 401:
            raise
        error.close()
        c.check()
        print('HE', flush=True)
        return
    except (urllib.error.URLError, TimeoutError, ValueError, KeyError, TypeError):
        c.check()
        print('HE', flush=True)
        return
    c.check()
    print(pack_history_frame('HO', entries, has_more, next_cursor), flush=True)


def poll_bubble(mid, binding):
    c = Connection()
    if c.binding != binding or not re.fullmatch(r'[A-Za-z0-9_-]{1,128}', mid):
        return
    previous = None
    pending_history = True
    degraded = False
    while True:
        c.check()
        try:
            title, status, text = projection(c, mid)
            if pending_history or degraded:
                # One bounded atomic bootstrap message: the client applies the initial
                # /open window once per selection instead of blocking first paint on
                # older history requests. After a degraded window the bootstrap repeats
                # once on recovery so a wiped transcript reloads its persisted archive.
                pending_history = False
                degraded = False
                entries, has_more, next_cursor = _history_page_raw(c, mid, text)
                if entries or has_more:
                    print(pack_history_frame('HS', entries, has_more, next_cursor), flush=True)
            fields = ('B', title, status, text.replace('\n', '\x1e').replace('\t', '\x1f'))
        except urllib.error.HTTPError as error:
            if error.code in (403, 404):
                print('D', flush=True)
                return
            if error.code == 401:
                raise
            degraded = True
            fields = None
        except (ValueError, KeyError, TypeError):
            degraded = True
            fields = ('X',)
        except (urllib.error.URLError, TimeoutError):
            degraded = True
            fields = None
        c.check()
        if fields is not None and fields != previous:
            print('\t'.join(fields), flush=True)
            previous = fields
        time.sleep(1)


def poll(mid, binding, tracked=None, rules=None):
    c = Connection()
    if tracked is None:
        line = sys.stdin.readline()
        if not line.endswith('\n'):
            return
        tracked = set(filter(None, line.rstrip('\n').split(',')))
    expanded = sys.stdin.readline().rstrip('\n').split('\t') if rules else []
    expanded = [slug for slug in expanded if slug and slug.isprintable()]
    if not all(re.fullmatch(r'[A-Za-z0-9_-]{1,128}', i) for i in tracked):
        return
    if c.binding != binding or (mid and not re.fullmatch(r'[A-Za-z0-9_-]{1,128}', mid)):
        return  # EOF invalidates the old roster; never request with a new identity
    last, failures, checked = None, 0, None
    published_project = False

    def publish_project(rows):
        nonlocal published_project
        frame = '\x1f'.join('\x1c'.join(map(label, row)) for row in rows)
        c.check()
        print('R\t+' + frame, flush=True)
        tracked.update(row[1] for row in rows if row[0] == 'M')
        published_project = True

    visible = []
    inbox_windows = InboxWindows()
    while True:
        c.check()
        try:
            if checked is None or time.monotonic() - checked >= 5:
                rows = roster_rows(c, include_archived=True, expanded=expanded, rules=rules,
                                   inbox_for=mid, inbox_windows=inbox_windows,
                                   publish_project=publish_project if not published_project else None)
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
                visible = ['\x1c'.join(map(label, row)) for row in rows if row[0] in ('P', 'M', 'N', 'G', 'I', 'U')]
                visible.extend('K\x1c' + ident for ident in sorted(tracked - found))
                checked = time.monotonic()
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
        if visible != last:
            print('R\t+' + '\x1f'.join(visible), flush=True)
            last = visible
        time.sleep(1)


def cloud_inventory(binding, mission):
    c = Connection()
    if c.binding != binding:
        return
    lines = []
    actions = []
    profiles = []
    if mission:
        if not re.fullmatch(r'[A-Za-z0-9_-]{1,128}', mission):
            raise ValueError('invalid mission')
        execution = c.get(f'/api/control/missions/{mission}/cloud')
        if execution['mission_id'] != mission or not isinstance(execution['turns'], list):
            raise ValueError('invalid cloud execution')
        selection = execution['selection']
        try:
            accounts = c.get('/api/cloud/accounts')
            if not isinstance(accounts, list):
                raise ValueError('invalid cloud inventory')
        except urllib.error.HTTPError as error:
            if error.code in (401, 403):
                raise
            error.close()
            accounts = []
            lines.append('Account actions unavailable. Refresh to retry.')
        except (urllib.error.URLError, TimeoutError, ValueError):
            accounts = []
            lines.append('Account actions unavailable. Refresh to retry.')
        account = next((a for a in accounts if a['id'] == selection['account'] and
                        a['provider'] == selection['provider']), {})
        caps = account.get('capabilities', {})
        turns = execution['turns']
        if caps.get('follow_up') is True:
            if not any(t['phase'] in ('submission_uncertain', 'incompatible', 'reconnect_required') for t in turns):
                actions.append('send')
            if caps.get('cancel') is True and any(t['phase'] == 'queued' or (t.get('external_id') and t['phase'] in
                    ('running', 'submitting', 'waiting_user')) for t in turns):
                actions.append('cancel')
        phases = {'queued': 'Queued', 'submitting': 'Starting', 'submission_uncertain': 'Submission needs verification',
                  'running': 'Working', 'waiting_user': 'Waiting for your reply', 'reconnect_required': 'Reconnect account',
                  'response_complete': 'Response complete', 'failed': 'Failed', 'cancel_requested': 'Stopping — awaiting confirmation',
                  'cancelled': 'Stopped', 'incompatible': 'Connector incompatible'}
        for turn in turns:
            for name, value in [('You', turn['prompt']), ('Status', phases.get(turn['phase'], 'Unknown provider state')),
                                ('Agent', turn.get('result')), ('Detail', turn.get('detail'))]:
                if value:
                    for paragraph in (name + ' · ' + value).splitlines():
                        lines.extend(textwrap.wrap(paragraph, width=56))
    else:
        accounts = c.get('/api/cloud/accounts')
        if not isinstance(accounts, list):
            raise ValueError('invalid cloud inventory')
        providers = {'cursor_cloud': 'Cursor Cloud', 'grok_bot': 'Grok Bot', 'hermes': 'Hermes'}
        for account in accounts:
            if not isinstance(account['available'], bool):
                raise ValueError('invalid availability')
            provider = providers.get(account['provider'], account['provider'])
            name = account['label'].removeprefix(provider + ' · ')
            status = 'Available' if account['available'] else account.get('reason') or 'Unavailable'
            lines.append(' · '.join([provider, name, status]))
            if account['available'] and account['provider'] in providers:
                account_id = account['id']
                if not isinstance(account_id, str) or not account_id or label(account_id) != account_id:
                    raise ValueError('invalid account identifier')
                profiles.append((account['provider'], account_id, provider + ' · ' + name))
    c.check()
    print('cloud')
    for profile in profiles:
        print('P\t' + '\t'.join(map(label, profile)))
    for action in actions:
        print('A\t' + action)
    for line in lines:
        print('L\t' + label(line))
