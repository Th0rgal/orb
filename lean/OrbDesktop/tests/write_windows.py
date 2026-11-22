"""Deterministic disposable-Core regressions for pre-spawn Stop and uncertain Send."""
import concurrent.futures
import contextlib
import json
import os
import re
from pathlib import Path
import shutil
import select
import socket
import sqlite3
import tempfile
import urllib.error
import urllib.request
import uuid

from live_writes import ROOT, process, wait
from remote_write_probe import check_remote_append, check_scoped_queue_replay, observe_node


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
            trace = ['strace', '-f', '-yy', '-e', 'trace=close', '-o', str(tmp / 'closes')] if mode == 'fd' else []
            return stack.enter_context(process(trace + [ROOT / 'target/release/orb-core'], env, tmp))
        def reap():
            for pid in launches.read_text().splitlines() if launches.exists() else []:
                with contextlib.suppress(ProcessLookupError):
                    os.kill(int(pid), 15)
        stack.callback(reap)
        submissions = observe_node(stack, env) if mode in ("remote-append", "remote-queue-replay") else []
        server = start()
        token = wait('login', login)
        mid = api('/api/control/missions', {'title': 'write-window', 'backend': 'claudecode' if mode in ('pipe','fd','retire','stop-archive') else 'codex'})['id']
        path = '/api/control/missions/' + mid
        key = str(uuid.uuid4())
        def send():
            return api('/api/control/message', {'mission_id': mid, 'client_message_id': key,
                       'content': 'window' * (50000 if mode in ('pipe','fd') else 1), 'queue_followup': True})
        def refused(call, error):
            try:
                call()
            except urllib.error.HTTPError as e:
                body = json.load(e)
                assert e.code == 409 and body['error'] == error, body
                return body
            raise AssertionError('expected refusal: ' + error)

        if mode == 'group-stop':
            import signal
            import sys
            import time
            childfile = tmp / 'grandchild'
            term = tmp / 'leader-stopped'
            (tmp / 'codex').write_text(f'''#!{sys.executable}
import os, signal
from pathlib import Path
def retire(*_):
    Path({str(term)!r}).touch()
    os._exit(0)
signal.signal(signal.SIGTERM, retire)
if os.fork() == 0:
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    os.close(1)
    Path({str(childfile)!r}).write_text(str(os.getpid()))
signal.alarm(8)
while True:
    signal.pause()
''')
            send()
            child = int(wait('descendant ready', lambda: childfile.exists() and childfile.read_text()))
            fd = os.pidfd_open(child)
            exited = select.poll()
            exited.register(fd, select.POLLIN)
            try:
                with concurrent.futures.ThreadPoolExecutor(2) as pool:
                    first = pool.submit(api, path + '/cancel', {})
                    deadline = time.monotonic() + 5
                    while not term.exists() and time.monotonic() < deadline:
                        time.sleep(0.001)
                    assert term.exists() and not first.done(), 'missed the Stop grace period'
                    second = pool.submit(api, path + '/cancel', {})
                    assert first.result(timeout=5)['ok'] and second.result(timeout=5)['ok']
                assert exited.poll(400), 'successful Stop left a TERM-resistant descendant running'
            finally:
                with contextlib.suppress(ProcessLookupError):
                    signal.pidfd_send_signal(fd, signal.SIGKILL)
                os.close(fd)
        elif mode == 'remote-append':
            check_remote_append(tmp, api, mid, submissions)
        elif mode == 'remote-queue-replay':
            def restart(while_stopped):
                nonlocal token
                server.terminate()
                server.wait(8)
                while_stopped()
                start()
                token = wait('restart', login)
            check_scoped_queue_replay(tmp, api, mid, submissions, restart)
        elif mode == 'busy':
            send()
            wait('first PID', lambda: launches.exists() and launches.stat().st_size)
            key = str(uuid.uuid4())
            refusal = refused(send, 'local_run_busy')
            assert refusal['id'] == key and refusal['message_accepted'] is False and refusal['queued'] is False
            api(path + '/cancel', {})
            assert refused(send, 'local_run_busy') == refusal
            assert len(launches.read_text().splitlines()) == 1
            assert len([e for e in api(path + '/events') if e['event_type'] == 'user_message']) == 1
        elif mode in ('retire', 'stop-archive'):
            claude = tmp / 'claude'
            # Signal handler proves retirement has started, while the same pidfd
            # remains live until the test releases the child.
            entered.unlink(missing_ok=True)
            gate.unlink()
            (tmp / 'git').unlink()
            import sys
            claude.write_text(f'#!{sys.executable}\nimport os, signal, time\nfrom pathlib import Path\n'
                              f'def retiring(*_):\n Path({str(entered)!r}).touch()\n'
                              f' while not Path({str(gate)!r}).exists(): time.sleep(.001)\n raise SystemExit\n'
                              f'signal.signal(signal.SIGTERM, retiring)\nwith open({str(launches)!r}, "a") as f: print(os.getpid(), file=f)\nsignal.pause()\n')
            claude.chmod(0o700)
            send()
            pid = int(wait('warm PID', lambda: launches.exists() and launches.read_text().strip()))
            fd = os.pidfd_open(pid); stack.callback(os.close, fd)
            exited = select.poll(); exited.register(fd, select.POLLIN)
            if mode == 'stop-archive':
                import time
                db_path, = tmp.rglob('missions.db')
                with contextlib.closing(sqlite3.connect(db_path.as_uri() + '?mode=ro', uri=True)) as db, concurrent.futures.ThreadPoolExecutor(1) as pool:
                    stopped = pool.submit(api, path + '/cancel', {})
                    try:
                        deadline = time.monotonic() + 5
                        while not entered.exists() and time.monotonic() < deadline: time.sleep(.001)
                        assert entered.exists() and not exited.poll(0)
                        assert db.execute('SELECT status FROM missions WHERE id=?', (mid,)).fetchone() == ('interrupted',)
                        refused(lambda: api(path + '/status', {'status':'acknowledged'}), 'mission_running')
                        assert not exited.poll(0), 'Archive reply did not bracket a live child'
                    finally:
                        gate.touch()
                    assert stopped.result(timeout=5)['ok'] and exited.poll(1000)
                assert api(path + '/status', {'status':'acknowledged'})['ok']
                print(f'{mode}: PASS {mid}', flush=True)
                return
            key = str(uuid.uuid4())
            with concurrent.futures.ThreadPoolExecutor(1) as pool:
                replacement = pool.submit(send)
                try:
                    wait('TERM delivered', entered.exists)
                    refused(lambda: api(path + '/status', {'status':'acknowledged'}), 'mission_running')
                    assert not exited.poll(0) and api(path)['status'] != 'acknowledged'
                finally:
                    gate.touch()
                replacement.result(timeout=10)
            assert exited.poll(1000)
            api(path + '/cancel', {})
        elif mode in ('pipe','fd'):
            import sys
            (tmp / 'git').unlink()
            entered.unlink(missing_ok=True)
            claude = tmp / 'claude'
            # A pipe may be full with a partially occupied page on either 4K or 16K kernels.
            claude.write_text(f'#!{sys.executable}\nimport os, select, time\n'
                              f'open({str(launches)!r}, "w").write(str(os.getpid()))\n'
                              'writer = os.open("/proc/self/fd/0", os.O_WRONLY | os.O_NONBLOCK)\n'
                              'poller = select.poll()\npoller.register(writer, select.POLLOUT)\n'
                              'while poller.poll(0): time.sleep(.02)\n'
                              f'open({str(entered)!r}, "w").close()\nwhile True: time.sleep(1)\n')
            claude.chmod(0o700)
            with concurrent.futures.ThreadPoolExecutor(2) as pool:
                sent = pool.submit(send)
                try:
                    wait('unread prompt in bounded pipe', entered.exists)
                    assert not sent.done()
                    pidfd = os.pidfd_open(int(launches.read_text()))
                    stdout = os.readlink(f'/proc/{int(launches.read_text())}/fd/1')
                    if mode == 'fd':
                        traced, = Path(f'/proc/{server.pid}/task/{server.pid}/children').read_text().split()
                        corefds = Path('/proc') / traced / 'fd'
                        number, = [f.name for f in corefds.iterdir() if os.path.realpath(f).endswith(stdout)]
                        before = len((tmp / 'closes').read_bytes())
                    stack.callback(os.close, pidfd)
                    poll = select.poll(); poll.register(pidfd, select.POLLIN)
                    assert not poll.poll(0)
                    assert pool.submit(api, path + '/cancel', {}).result(timeout=5)['ok']
                    assert poll.poll(1000), 'Stop acknowledged with live warm child'
                finally:
                    reap()
                refused(lambda: sent.result(timeout=5), 'local_delivery_not_confirmed')
            assert api(path)['status'] == 'interrupted'
            if mode == 'fd':
                trace = (tmp / 'closes').read_bytes()[before:].decode(errors='replace')
                assert f'close({number}<{stdout}>' in trace, 'missing reader close'
                assert not re.search(rf'close\({number}\)\s+= -1 EBADF', trace), 'Stop and reader both closed warm stdout'
        elif mode == 'completion':
            send()
            old = int(wait('old launch', lambda: launches.exists() and launches.read_text().strip()))
            entered.unlink(missing_ok=True)
            gate.unlink()
            try:
                os.kill(old, 15)
                wait('old completion at post-turn checkpoint', entered.exists)
                (tmp / 'git').unlink()
                api('/api/control/message', {'mission_id': mid, 'content': 'replacement', 'client_message_id': str(uuid.uuid4())})
                wait('replacement PID', lambda: len(launches.read_text().splitlines()) == 2)
                fd = os.pidfd_open(int(launches.read_text().splitlines()[1])); stack.callback(os.close, fd)
                exited = select.poll(); exited.register(fd, select.POLLIN)
            finally:
                gate.touch()
            import time
            until = time.monotonic() + 2
            while time.monotonic() < until:
                assert api(path)['status'] == 'active' and not exited.poll(0)
                time.sleep(.05)
            assert not any(e['event_type'] == 'error' for e in api(path + '/events')), 'obsolete completion appended a transcript error'
            assert api(path + '/cancel', {})['ok'] and exited.poll(1000)
        elif mode in ('stop', 'activation', 'archive-activation', 'archive-registration', 'supersede'):
            if mode in ('activation', 'archive-activation'):
                skill = tmp / 'library/skills/check-window'
                skill.mkdir(parents=True)
                (skill / 'SKILL.md').write_text('---\nname: check-window\naudience: mission\n---\nfixture\n')
                tool = tmp / 'base64'
                tool.write_text(f'#!/bin/sh\ntouch "{entered}"\nwhile test ! -e "{gate}"; do sleep .05; done\nexec /usr/bin/base64 "$@"\n')
                tool.chmod(0o700)
                (tmp / 'git').unlink()
            entered.unlink(missing_ok=True)
            gate.unlink()
            with concurrent.futures.ThreadPoolExecutor(1) as pool:
                sent = pool.submit(send)
                try:
                    wait('checkpoint before pid registration', entered.exists)
                    assert not launches.exists()
                    assert any(m['event_type'] == 'user_message' for m in api(path + '/events'))
                    if mode == 'stop': assert api(path)['status'] == 'active'
                    if mode == 'supersede':
                        # First git invocation is already paused in the wrapper;
                        # later checkpoints resolve the real git executable.
                        (tmp / 'git').unlink()
                        api('/api/control/message', {'mission_id': mid, 'client_message_id': str(uuid.uuid4()), 'content': 'new generation'})
                        child = int(wait('new generation launched', lambda: launches.exists() and launches.read_text().strip()))
                        fd = os.pidfd_open(child); stack.callback(os.close, fd)
                        exited = select.poll(); exited.register(fd, select.POLLIN)
                        assert not exited.poll(0)
                    else:
                        if mode == 'archive-registration':
                            db_path, = tmp.rglob('missions.db')
                            with contextlib.closing(sqlite3.connect(db_path.as_uri() + '?mode=ro', uri=True)) as db:
                                query = 'SELECT status,(SELECT count(*) FROM mission_runs WHERE mission_id=m.id) FROM missions m WHERE id=?'
                                assert db.execute(query, (mid,)).fetchone() == ('active', 0)
                                refused(lambda: api(path + '/status', {'status':'acknowledged'}), 'mission_running')
                                assert db.execute(query, (mid,)).fetchone() == ('active', 0)
                            assert api(path + '/cancel', {})['ok']
                        if not mode.startswith('archive-'):
                            assert api(path + '/cancel', {})['ok']
                        api(path + '/status', {'status': 'acknowledged'})
                finally:
                    gate.touch()
                refused(lambda: sent.result(timeout=15), 'local_delivery_not_confirmed')
            if mode == 'supersede':
                assert api(path + '/cancel', {})['ok']
                assert exited.poll(1000) and launches.read_text().splitlines() == [str(child)], 'wrong generation owned PID'
                print(f'{mode}: PASS {mid}', flush=True)
                return
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
    for mode in sys.argv[1:] or ('stop', 'receipt', 'activation', 'pipe', 'archive-activation', 'archive-registration', 'supersede', 'completion', 'fd', 'busy', 'retire', 'stop-archive', 'remote-append', 'remote-queue-replay', 'group-stop'):
        with tempfile.TemporaryDirectory(prefix='orb-write-window-') as d:
            check(Path(d), mode)
