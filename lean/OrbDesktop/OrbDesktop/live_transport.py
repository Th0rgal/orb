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

    def request(self, path, cap=4 << 20, body=None, key=None):
        self.check()
        base, token = self.creds
        req = urllib.request.Request(base + path, headers={'Authorization': 'Bearer ' + token,
                                                           'Accept': 'application/json', 'Cache-Control': 'no-cache'})
        if body is not None:
            req.data = json.dumps(body).encode()
            req.add_header('Content-Type', 'application/json')
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


def mutate(binding, action, mid):
    c = Connection()
    if c.binding != binding:
        raise ValueError('connection changed')
    key = str(uuid.uuid4())
    if action == 'create':
        row = c.request('/api/control/missions', body={'title': 'New mission'}, key=key)
        if not re.fullmatch(r'[A-Za-z0-9_-]{1,128}', row['id']):
            raise ValueError('invalid mission')
        print('\t'.join(map(label, [row['id'], 'New mission', row['status']])))
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
    elif action == 'restore':
        row = c.get(path + '?include_history=false')
        if row['id'] != mid or row['status'] != 'acknowledged' or (row.get('execution') or {}).get('state') == 'running':
            raise ValueError('mission not archived')
        c.request(path + '/status', body={'status': 'paused'}, key=key)
    elif action == 'copy-id':
        import subprocess
        subprocess.run(['wl-copy', '--type', 'text/plain'], input=mid.encode(), check=True)
    elif action == 'archive':
        row = c.get(path + '?include_history=false')
        if row['id'] != mid or (row.get('execution') or {}).get('state') == 'running' or row['status'] not in (
                'awaiting_user', 'completed', 'interrupted', 'failed', 'blocked', 'paused', 'cancelled'):
            raise ValueError('mission not idle')
        c.request(path + '/status', body={'status': 'acknowledged'}, key=key)
    else:
        raise ValueError('unknown action')


def label(v):
    return ''.join(c if c.isprintable() else ' ' for c in str(v or '')[:512])


def roster_rows(c):
    projects = c.get('/api/projects')['projects']
    missions = c.get('/api/control/missions?limit=200')
    machines = c.get('/api/machines')
    if not all(isinstance(x, list) for x in (projects, missions, machines)):
        raise ValueError('invalid roster')
    rows = [('C', c.binding)]
    rows += [('P', p['slug'], p.get('title') or p['slug'], p.get('objective')) for p in projects]
    rows += [('M', *(m.get(k) for k in ('id','title','project','track','model','model_override',
                                        'status','updated_at','created_at','short_description')))
             for m in missions if re.fullmatch(r'[A-Za-z0-9_-]{1,128}', m['id'])]
    rows += [('N', *(m.get(k) for k in ('id','name','role','provider','cpu_ram','size','state',
                                        'status','expires_at','cost','active_missions'))) for m in machines]
    c.check()
    return rows


def roster():
    for row in roster_rows(Connection()):
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
        tracked = set(filter(None, sys.stdin.readline(26001).strip().split(',')))
    if len(tracked) > 200 or not all(re.fullmatch(r'[A-Za-z0-9_-]{1,128}', i) for i in tracked):
        return
    if c.binding != binding or (mid and not re.fullmatch(r'[A-Za-z0-9_-]{1,128}', mid)):
        return  # EOF invalidates the old roster; never request with a new identity
    last, failures, checked = None, 0, None
    visible = []
    while True:
        c.check()
        try:
            if checked is None or time.monotonic() - checked >= 5:
                rows = roster_rows(c)
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
                visible = [kind + ':' + label(ident) for kind, ident, *_ in rows if kind in ('P','N')]
                visible += ['M:' + i for i in sorted(tracked)]
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
