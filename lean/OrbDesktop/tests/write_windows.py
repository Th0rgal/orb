"""Deterministic disposable-Core regressions for pre-spawn Stop and uncertain Send."""
import concurrent.futures
import contextlib
import json
import os
from pathlib import Path
import shutil
import socket
import sqlite3
import tempfile
import urllib.error
import urllib.request
import uuid

from live_writes import ROOT, process, wait


def check(tmp, mode):
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0))
        port = s.getsockname()[1]
    token = ''

    def api(path, body=None):
        req = urllib.request.Request(f'http://127.0.0.1:{port}' + path,
            data=None if body is None else json.dumps(body).encode(),
            headers={'Content-Type': 'application/json', 'Authorization': 'Bearer ' + token})
        with urllib.request.urlopen(req, timeout=15) as response:
            return json.load(response)

    def login():
        return api('/api/auth/login', {'password': ''})['token']

    launches, gate, entered = (tmp / p for p in ('launches', 'release', 'entered'))
    for name, script in [('codex', f'echo $$ >> "{launches}"\nexec sleep 90'),
                         ('git', f'case "$*" in *--show-toplevel*) touch "{entered}"; '
                          f'while test ! -e "{gate}"; do sleep .05; done;; esac\nexec "{shutil.which("git")}" "$@"')]:
        (tmp / name).write_text('#!/bin/sh\n' + script + '\n')
        (tmp / name).chmod(0o700)
    gate.touch()
    (tmp / 'home').mkdir()
    env = dict(PATH=f'{tmp}:{os.environ["PATH"]}', HOME=str(tmp / 'home'), HOST='127.0.0.1', PORT=str(port),
               LD_LIBRARY_PATH=os.getenv('LD_LIBRARY_PATH', ''), WORKING_DIR=str(tmp), DEV_MODE='true')
    with contextlib.ExitStack() as stack:
        def start():
            return stack.enter_context(process([ROOT / 'target/release/orb-core'], env, tmp))
        def reap():
            for pid in launches.read_text().splitlines() if launches.exists() else []:
                with contextlib.suppress(ProcessLookupError):
                    os.kill(int(pid), 15)
        stack.callback(reap)
        server = start()
        token = wait('login', login)
        mid = api('/api/control/missions', {'title': 'write-window'})['id']
        path = '/api/control/missions/' + mid
        key = str(uuid.uuid4())
        def send():
            return api('/api/control/message', {'mission_id': mid, 'client_message_id': key,
                       'content': 'window', 'queue_followup': True})
        if mode == 'stop':
            entered.unlink(missing_ok=True)
            gate.unlink()
            with concurrent.futures.ThreadPoolExecutor(1) as pool:
                sent = pool.submit(send)
                try:
                    wait('checkpoint before pid registration', entered.exists)
                    assert not launches.exists() and api(path)['status'] == 'active'
                    assert api(path + '/cancel', {})['ok']
                    api(path + '/status', {'status': 'acknowledged'})
                finally:
                    gate.touch()
                sent.result(timeout=15)
            # The shell can exec the CLI just after the HTTP send returns.
            # A late child remains observable even if its parent has returned.
            import time
            deadline = time.monotonic() + 2
            while not launches.exists() and time.monotonic() < deadline:
                time.sleep(.02)
            assert api(path)['status'] == 'acknowledged' and not launches.exists(), 'late launch after Stop'
        else:
            db = tmp / '.sandboxed-sh/idempotency_keys.db'
            with sqlite3.connect(db) as conn:
                conn.execute("CREATE TRIGGER fail_receipt BEFORE UPDATE ON idempotency_keys WHEN NEW.phase='committed' BEGIN SELECT RAISE(ABORT,'receipt fault'); END")
            try:
                send()
                raise AssertionError('missing receipt failure')
            except urllib.error.HTTPError as e:
                assert e.code == 500 and json.load(e)['error'] == 'message_receipt_unconfirmed'
            wait('child started', lambda: launches.exists() and launches.stat().st_size)
            pid = launches.read_text().strip()
            api(path + '/cancel', {})
            server.terminate()
            server.wait(8)
            start()
            token = wait('restart', login)
            try:
                send()
                raise AssertionError('uncertain Send was accepted again')
            except urllib.error.HTTPError as e:
                assert e.code == 409 and json.load(e)['error'] == 'message_outcome_uncertain'
            messages = [m for m in api(path + '/events') if m['event_type'] == 'user_message']
            assert len(messages) == 1 and launches.read_text().splitlines() == [pid]
        print(f'{mode}: PASS {mid}', flush=True)


if __name__ == '__main__':
    import sys
    for mode in sys.argv[1:] or ('stop', 'receipt'):
        with tempfile.TemporaryDirectory(prefix='orb-write-window-') as d:
            check(Path(d), mode)
