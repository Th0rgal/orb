"""Run in a disposable Linux guest with only lo, Core, agy, and a fixture CA."""
import argparse
import asyncio
import contextlib
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import secrets
import socket
import sqlite3
import ssl
import subprocess
import sys
import tempfile
import time
from uuid import uuid4
from urllib.parse import unquote, urlsplit

from antigravity_fixture_node import NODE_ID, request
from test_native_owner_core import core
from native_job_relay.supervisor import node_transport
from native_job_relay.transport import Destination, admission, copy, first_completed

HOST = Destination.DAILY_CLOUD_CODE.value
BRIDGE = Path(__file__).parent / "native_job_relay/transport.py"


def port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


@contextmanager
def adapter(role, cfg):
    with socket.socket() as listener, tempfile.TemporaryFile() as config:
        listener.bind(("127.0.0.1", 0))
        listener.listen()
        config.write(json.dumps(cfg).encode())
        config.seek(0)
        proc = subprocess.Popen([sys.executable, "-I", str(BRIDGE), role, "--listen-fd", str(listener.fileno()),
                                 "--config-fd", str(config.fileno())], pass_fds=(listener.fileno(), config.fileno()),
                                env={"PATH": os.defpath})
        try:
            yield listener.getsockname()[1]
        finally:
            proc.terminate()
            proc.wait(timeout=5)


@contextmanager
def account_listener(driver, gateway):
    # The existing native relay fixture allocates the verified gateway for account d.
    proc = subprocess.Popen([driver, "relay", str(gateway), str(gateway)], text=True,
                            stdin=subprocess.PIPE, stdout=subprocess.PIPE, env={"PATH": os.defpath})
    try:
        print(secrets.token_hex(32), file=proc.stdin, flush=True)
        urls = [urlsplit(proc.stdout.readline().strip()) for _ in range(5)]
        assigned, = [url for url in urls if unquote(url.username or "") == "antigravity/d"]
        assert assigned.hostname == "127.0.0.1" and assigned.port and assigned.password
        yield assigned.port, assigned.password
    finally:
        proc.stdin.close()
        proc.wait(timeout=10)


async def exercise(args, root, db, core_port, claim, mission, short_grant):
    password = secrets.token_hex(20)
    salt = secrets.token_hex(16)
    verifier = hashlib.pbkdf2_hmac("sha256", password.encode(), salt.encode(), 100000).hex()
    db.execute("INSERT INTO users(id,username,password_hash,role) VALUES(?,'ledger-owner',?,'member')",
               (claim["owner"], f"pbkdf2-sha256$100000${salt}${verifier}"))
    db.execute("INSERT INTO missions(id,project,status,backend,owner_user_id,placement_job_id) VALUES(?,'tests','active','antigravity',?,?)",
               (mission, claim["owner"], claim["job"]))
    db.execute("INSERT INTO remote_node_jobs(job_id,node_id,mission_id,state) VALUES(?,?,?,'running')",
               (claim["job"], NODE_ID, mission))
    db.commit()
    status, body = request(core_port, "", "POST", "/api/auth/login", {"username": "ledger-owner", "password": password})
    assert status == 200
    operator = json.loads(body)["token"]
    origin_hits = []
    origin_sni = []
    relay_hits = []
    direct_hits = []
    async def direct(r, w):
        direct_hits.append(1)
        w.close()

    ledger_command = "pwd > ledger.receipt"
    request_ledger = False

    async def origin(r, w):
        nonlocal request_ledger
        try:
            head = await r.readuntil(b"\r\n\r\n")
            line = head.splitlines()[0]
            origin_hits.append(line)
            if line.startswith(b"GET /live "):
                w.write(b"HTTP/1.1 200 OK\r\nContent-Length: 64\r\n\r\nx")
                await w.drain()
                if await r.read(1) == b"!":
                    w.write(b"y")
                    await w.drain()
                    await r.read()
            else:
                payload = {"candidates":[{"index":0, "finishReason":"STOP",
                            "content":{"role":"model", "parts":[{"text":"ledger complete"}]}}]}
                if request_ledger and b":streamGenerateContent" in line:
                    request_ledger = False
                    payload["candidates"][0]["content"]["parts"] = [{"functionCall": {"name": "run_command",
                        "args": {"CommandLine": ledger_command, "WaitMsBeforeAsync": 5000,
                                 "toolSummary": "Record fixture ledger directory"}}}]
                data = ("data: " + json.dumps(payload) + "\n\n").encode()
                w.write(b"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\nContent-Length: " +
                        str(len(data)).encode() + b"\r\n\r\n" + data)
                await w.drain()
        except (OSError, EOFError):
            pass
        finally:
            w.close()

    tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    tls.load_cert_chain(args.cert, args.key)
    tls.set_servername_callback(lambda _sock, name, _ctx: origin_sni.append(name))
    model = await asyncio.start_server(origin, "127.0.0.1", 0, ssl=tls)
    trap = await asyncio.start_server(direct, "127.0.0.2", 443)
    async def account_relay(r, w):
        out = None
        try:
            assert await r.readexactly(3) == bytes([5, 1, 0])
            w.write(bytes([5, 0]))
            async def field():
                return await r.readexactly((await r.readexactly(1))[0])
            assert await r.readexactly(4) == bytes([5, 1, 0, 3])
            assert await field() == HOST.encode()
            assert await r.readexactly(2) == b"\x01\xbb"
            relay_hits.append(1)
            upstream, out = await asyncio.open_connection("127.0.0.1", model.sockets[0].getsockname()[1])
            w.write(bytes([5, 0, 0, 1]) + bytes(6))
            await first_completed(copy(r, out), copy(upstream, w))
        except (EOFError, OSError):
            pass
        finally:
            w.close()
            if out:
                out.close()

    relay = await asyncio.start_server(account_relay, "127.0.0.1", 0)
    ca = ssl.create_default_context(cafile=args.cert)
    front_ca = ssl.create_default_context(cafile=args.front_cert)
    async with relay, trap, model, contextlib.AsyncExitStack() as stack:
        assigned_port, password = stack.enter_context(account_listener(args.driver, relay.sockets[0].getsockname()[1]))
        with adapter("core", dict(core_port=core_port, account=claim["account"], relay_port=assigned_port,
                                  relay_password=password,cert=args.front_cert,key=args.front_key)) as front:
            async def attempt(change):
                r,w = await asyncio.open_connection("127.0.0.1", front, ssl=front_ca)
                w.write(json.dumps({**claim, "destination": HOST, **change}).encode() + b"\n")
                await w.drain()
                try:
                    response = await asyncio.wait_for(r.readline(), 3)
                    assert response == b"", response
                finally:
                    w.close()

            for change in ({"job": str(uuid4())}, {"account":"other"}, {"owner":"other"}, {"node":"other"},
                           {"revision":2}, {"node_token":"wrong"}, {"grant":"orb-agy-v1_wrong"},
                           {"destination":"unlisted.invalid"}, {"destination":"127.0.0.1"}):
                await attempt(change)
            assert not relay_hits
            print("9 rejected requests; account-relay connects=0", flush=True)
            db.execute("UPDATE native_owner_enrollments SET revision=2")
            db.commit()
            await attempt({"revision":2})
            db.execute("UPDATE native_owner_enrollments SET revision=1")
            db.commit()
            print("old grant with updated enrollment revision denied", flush=True)
            with adapter("node", dict(host="127.0.0.1",port=front,ca=args.front_cert,claim=claim)) as local:
                async def socks_request(host, target_port):
                    reader, writer = await asyncio.open_connection("127.0.0.1", local)
                    writer.write(bytes([5, 1, 0]))
                    assert await reader.readexactly(2) == bytes([5, 0])
                    writer.write(bytes([5, 1, 0, 3, len(host)]) + host.encode() + target_port.to_bytes(2, "big"))
                    return reader, writer

                for host, target_port in ((HOST, 80), ("unlisted.invalid", 443)):
                    reader, writer = await socks_request(host, target_port)
                    assert await asyncio.wait_for(reader.read(1), 3) == b""
                    writer.close()
                assert not relay_hits
                reader, writer = await socks_request(HOST, 443)
                assert len(await reader.readexactly(10)) == 10
                # Accept the fixture origin certificate even for the wrong name here.
                # The transport itself must stop these bytes before the origin.
                negative_ca = ssl.create_default_context(cafile=args.cert)
                negative_ca.check_hostname = False
                try:
                    await writer.start_tls(negative_ca, server_hostname="unlisted.invalid")
                except (ConnectionError, ssl.SSLError):
                    pass
                else:
                    raise AssertionError("unlisted SNI completed a handshake")
                finally:
                    writer.close()
                assert not origin_sni and not origin_hits
                print("unlisted SOCKS host, port 80 and mismatched inner TLS SNI denied", flush=True)
                cfg = dict(host="127.0.0.1", port=front, ca=args.front_cert, claim=claim)
                namespace, private_port = stack.enter_context(node_transport(cfg))
                namespace_id = os.readlink(f"/proc/self/fd/{namespace}")
                profile = Path(stack.enter_context(tempfile.TemporaryDirectory()))
                os.chown(profile, 16001, 16001)
                settings = profile / ".gemini/antigravity-cli/settings.json"
                settings.parent.mkdir(parents=True)
                settings.write_text('{"modelProvider":"gemini"}')
                for path in settings.parents:
                    if path == profile:
                        break
                    os.chown(path, 16001, 16001)
                os.chown(settings, 16001, 16001)
                env = dict(PATH=os.defpath, HOME=str(profile), TMPDIR=str(profile), SSL_CERT_FILE=args.cert,
                           GOOGLE_GEMINI_BASE_URL="https://" + HOST, GEMINI_API_KEY="fixture",
                           HTTPS_PROXY=f"socks5://127.0.0.1:{private_port}", HTTP_PROXY=f"socks5://127.0.0.1:{private_port}",
                           TERM="dumb", NO_PROXY="")
                async def native_turn(model, timeout, sid=None):
                    proc = await asyncio.create_subprocess_exec(
                        sys.executable, str(Path(__file__).with_name("test_antigravity_job_egress.py")), "job",
                        str(namespace), args.agy, "--model", model, "--mode", "accept-edits",
                        "--settings", json.dumps({"permissions": {"allow": [f"command({ledger_command})"]}}),
                        *(["--conversation", sid] if sid else []), "--output-format", "stream-json",
                        "--print-timeout", f"{timeout}s", "--print=Read the disposable ledger", cwd=profile, env=env, pass_fds=(namespace,),
                        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
                    try:
                        events, _ = await asyncio.wait_for(proc.communicate(), timeout + 15)
                    finally:
                        if proc.returncode is None:
                            proc.kill()
                            await proc.wait()
                    return next(json.loads(line)["result"] for line in events.splitlines() if "result" in json.loads(line))

                conversations = {}
                for model_name in ("gemini-4-carbon-high", "gemini-4-neon-high"):
                    ledger = profile / "ledger.receipt"
                    ledger.unlink(missing_ok=True)
                    request_ledger = True
                    initial = await native_turn(model_name, 45)
                    assert initial["status"] == "SUCCESS" and ledger.read_text().strip() == str(profile)
                    assert ledger.stat().st_uid == 16001
                    sid = initial["conversation_id"]
                    assert sid
                    conversations[model_name] = sid
                    followup = await native_turn(model_name, 30, sid)
                    assert followup["status"] == "SUCCESS" and followup["conversation_id"] == sid
                    print(f"{model_name}: native workspace file uid=16001; same conversation resumed", flush=True)
                assert any(b":streamGenerateContent" in hit for hit in origin_hits)
                assert relay_hits and not direct_hits

                async def open_live(port):
                    r,w = await asyncio.open_connection("127.0.0.1",port)
                    w.write(bytes([5,1,0]))
                    assert await r.readexactly(2) == bytes([5,0])
                    w.write(bytes([5,1,0,3,len(HOST)])+HOST.encode()+b"\x01\xbb")
                    assert await r.readexactly(10) == bytes([5,0,0,1])+bytes(6)
                    await w.start_tls(ca,server_hostname=HOST)
                    w.write(b"GET /live HTTP/1.1\r\nHost: "+HOST.encode()+b"\r\n\r\n")
                    await r.readuntil(b"\r\n\r\n")
                    assert await r.readexactly(1)==b"x"
                    return r,w

                sibling = dict(claim, grant=short_grant)
                sibling_digest = hashlib.sha256(short_grant.encode()).hexdigest()
                db.execute("UPDATE mission_proxy_tokens SET expires_at_epoch=? WHERE token_sha256=?",
                           (int(time.time()) + 4, sibling_digest))
                db.commit()
                with adapter("node", dict(host="127.0.0.1",port=front,ca=args.front_cert,claim=sibling)) as short:
                    r,w = await open_live(short)
                    assert await asyncio.wait_for(r.read(1),6)==b""
                    w.close()
                    await attempt({"grant":sibling["grant"]})
                print("grant expiry closed established TLS; reconnect denied", flush=True)
                r,w = await open_live(local)
                relay.close()
                before = len(origin_hits)
                await attempt({})
                for model_name, sid in conversations.items():
                    blocked = await native_turn(model_name, 12, sid)
                    assert blocked["status"] in ("ERROR", "CANCELLED") and blocked["conversation_id"] == sid
                    assert len(origin_hits) == before and not direct_hits
                    print(f"{model_name}: gateway unavailable; resume {blocked['status']}; origin delta=0; direct hits=0", flush=True)
                w.write(b"!")
                await w.drain()
                assert await asyncio.wait_for(r.readexactly(1), 3) == b"y"
                status, body = await asyncio.to_thread(request, core_port, operator, "POST",
                                                       "/api/control/missions/" + mission + "/cancel", {})
                assert status == 200, (status, body)
                assert await asyncio.wait_for(r.read(1), 3) == b""
                w.close()
                await attempt({})
                try:
                    await asyncio.to_thread(admission, core_port, claim)
                except PermissionError:
                    pass
                else:
                    raise AssertionError("cancelled grant still admitted by Core")
                print("Core cancellation closed established TLS; reconnect denied", flush=True)
                assert not direct_hits

    assert not profile.exists()
    assert not Path(f"/proc/self/fd/{namespace}").exists()
    for proc in Path("/proc").glob("[0-9]*"):
        try:
            current = os.readlink(proc / "ns/net")
            assert current != namespace_id, "job process survived teardown"
            for fd in (proc / "fd").iterdir():
                try:
                    assert os.readlink(fd) != namespace_id, "namespace descriptor survived teardown"
                except FileNotFoundError:
                    continue
        except (ProcessLookupError, FileNotFoundError, PermissionError):
            continue
    print("supervisor teardown: temporary profile removed; job namespace released", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for arg in ("core","driver","agy","cert","key","front-cert","front-key"):
        parser.add_argument("--"+arg,required=True,type=lambda p:str(Path(p).resolve()))
    args = parser.parse_args()
    assert set(os.listdir("/sys/class/net")) == {"lo"}
    assert socket.gethostbyname(HOST)=="127.0.0.2"
    with tempfile.TemporaryDirectory() as root:
        claim = dict(node=NODE_ID,job=str(uuid4()),owner=str(uuid4()),account="d",revision=1,
                     node_token=secrets.token_hex(32))
        mission = str(uuid4())
        grants = subprocess.check_output([args.driver, "job-relay-grants", str(Path(root)/".sandboxed-sh"),
            claim["owner"], mission, claim["job"]], text=True, env={"HOME":root,"PATH":os.defpath,"LEAN_NUM_THREADS":"2"}).splitlines()
        claim["grant"], short_grant = grants
        assert all(token.startswith("orb-agy-v1_") for token in grants)
        target = port()
        env = dict(PATH=os.defpath, HOME=root, WORKING_DIR=root, HOST="127.0.0.1", PORT=str(target),
                   DEV_MODE="false", ORB_INSTANCE="dev", DASHBOARD_PASSWORD=secrets.token_hex(20),JWT_SECRET=secrets.token_hex(32),
                   LEAN_NUM_THREADS="2", FIXTURE_NODE_TOKEN=claim["node_token"],
                   SANDBOXED_REMOTE_NODES=json.dumps([dict(id=NODE_ID,base_url="http://127.0.0.2:1",
                        token_env="FIXTURE_NODE_TOKEN",dedicated_owner_id=claim["owner"])]))
        with core(args.core,env), sqlite3.connect(Path(root)/".sandboxed-sh/missions.db") as db:
            asyncio.run(exercise(args, root, db, target, claim, mission, short_grant))


if __name__=="__main__":
    main()
