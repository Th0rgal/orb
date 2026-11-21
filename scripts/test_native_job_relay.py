"""Run in a disposable Linux guest with only lo, Core, agy, and a fixture CA."""
import argparse
import asyncio
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

from antigravity_fixture_node import NODE_ID, request
from test_native_owner_core import core
from native_job_relay.transport import Destination, copy, first_completed

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


def seed(db, claim, mission, expires):
    digest = hashlib.sha256(claim["grant"].encode()).hexdigest()
    db.execute("INSERT INTO users(id,username,password_hash,role) VALUES(?,?,?,'member')",
               (claim["owner"], "ledger-owner", "fixture"))
    db.execute("INSERT INTO missions(id,project,status,backend,owner_user_id,placement_job_id) VALUES(?,'tests','active','antigravity',?,?)",
               (mission, claim["owner"], claim["job"]))
    db.execute("INSERT INTO ai_providers(id,name,provider_type,created_by_user_id) VALUES(?,'ledger','antigravity',?)",
               (claim["account"], claim["owner"]))
    db.execute("INSERT INTO account_vpn_routes(account_id,country,generation) VALUES(?,'NL',1)", (claim["account"],))
    db.execute("INSERT INTO native_owner_enrollments VALUES(?,?,?,?)",
               (NODE_ID, claim["owner"], claim["account"], claim["revision"]))
    db.execute("INSERT INTO remote_node_jobs(job_id,node_id,mission_id,state) VALUES(?,?,?,'running')",
               (claim["job"], NODE_ID, mission))
    db.execute("INSERT INTO mission_proxy_tokens VALUES(?,?,?,?,0)", (digest, mission, claim["owner"], expires))
    db.execute("INSERT INTO native_antigravity_grants VALUES(?,?,?,'gemini-4-carbon')",
               (digest, claim["job"], claim["account"]))
    db.execute("INSERT INTO native_job_relay_bindings VALUES(?,?,?,1)", (digest, NODE_ID, claim["revision"]))
    db.commit()
    return digest


async def exercise(args, root, db, core_port, claim, operator):
    mission = str(uuid4())
    digest = seed(db, claim, mission, int(time.time()) + 180)
    origin_hits = []
    relay_hits = []
    direct_hits = []
    async def direct(r, w):
        direct_hits.append(1)
        w.close()

    async def origin(r, w):
        try:
            head = await r.readuntil(b"\r\n\r\n")
            line = head.splitlines()[0]
            origin_hits.append(line)
            if line.startswith(b"GET /live "):
                w.write(b"HTTP/1.1 200 OK\r\nContent-Length: 64\r\n\r\nx")
                await w.drain()
                await r.read()
            else:
                payload = {"candidates":[{"index":0, "finishReason":"STOP",
                            "content":{"role":"model", "parts":[{"text":"ledger complete"}]}}]}
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
    password = secrets.token_hex(24)
    model = await asyncio.start_server(origin, "127.0.0.1", 0, ssl=tls)
    trap = await asyncio.start_server(direct, "127.0.0.2", 443)
    async def account_relay(r, w):
        out = None
        try:
            assert await r.readexactly(3) == bytes([5, 1, 2])
            w.write(bytes([5, 2]))
            assert await r.readexactly(1) == b"\x01"
            async def field():
                return await r.readexactly((await r.readexactly(1))[0])
            assert await field() == ("antigravity/" + claim["account"]).encode()
            assert await field() == password.encode()
            w.write(bytes([1, 0]))
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
    async with relay, trap, model:
        with adapter("core", dict(core_port=core_port, account=claim["account"], relay_port=relay.sockets[0].getsockname()[1],
                                  relay_password=password,cert=args.cert,key=args.key)) as front:
            async def attempt(change):
                r,w = await asyncio.open_connection("127.0.0.1", front, ssl=ca)
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
            with adapter("node", dict(host="127.0.0.1",port=front,ca=args.cert,claim=claim)) as local:
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
                try:
                    await writer.start_tls(ca, server_hostname="unlisted.invalid")
                except (ConnectionError, ssl.SSLError):
                    pass
                else:
                    raise AssertionError("unlisted SNI completed a handshake")
                finally:
                    writer.close()
                assert not origin_hits
                print("unlisted SOCKS host, port 80 and mismatched inner TLS SNI denied", flush=True)
                profile = Path(root) / "empty-profile"
                profile.mkdir()
                settings = profile / ".gemini/antigravity-cli/settings.json"
                settings.parent.mkdir(parents=True)
                settings.write_text('{"modelProvider":"gemini"}')
                env = dict(PATH=os.defpath, HOME=str(profile), TMPDIR=str(profile), SSL_CERT_FILE=args.cert,
                           GOOGLE_GEMINI_BASE_URL="https://" + HOST, GEMINI_API_KEY="fixture",
                           HTTPS_PROXY=f"socks5://127.0.0.1:{local}", HTTP_PROXY=f"socks5://127.0.0.1:{local}",
                           TERM="dumb", NO_PROXY="")
                proc = await asyncio.create_subprocess_exec(args.agy,"--model","gemini-4-carbon-high","--output-format","stream-json",
                    "--print=Read the disposable ledger",cwd=profile,env=env,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL)
                try:
                    events,_ = await asyncio.wait_for(proc.communicate(),50)
                finally:
                    if proc.returncode is None:
                        proc.kill()
                        await proc.wait()
                assert proc.returncode == 0 and any(json.loads(line).get("result",{}).get("status")=="SUCCESS"
                                                   for line in events.splitlines()), proc.returncode
                assert any(b":streamGenerateContent" in hit for hit in origin_hits)
                assert relay_hits and not direct_hits
                print("native agy 1.5.14 Carbon SUCCESS; verified provider TLS through assigned account relay; direct hits=0", flush=True)

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

                sibling = dict(claim, grant="orb-agy-v1_" + secrets.token_hex(24))
                sibling_digest = hashlib.sha256(sibling["grant"].encode()).hexdigest()
                db.execute("INSERT INTO mission_proxy_tokens VALUES(?,?,?,?,0)",
                           (sibling_digest, mission, claim["owner"], int(time.time()) + 4))
                db.execute("INSERT INTO native_antigravity_grants SELECT ?,job_id,account_id,model "
                           "FROM native_antigravity_grants WHERE token_sha256=?", (sibling_digest, digest))
                db.execute("INSERT INTO native_job_relay_bindings SELECT ?,node_id,enrollment_revision,route_generation "
                           "FROM native_job_relay_bindings WHERE token_sha256=?", (sibling_digest, digest))
                db.commit()
                with adapter("node", dict(host="127.0.0.1",port=front,ca=args.cert,claim=sibling)) as short:
                    r,w = await open_live(short)
                    assert await asyncio.wait_for(r.read(1),6)==b""
                    w.close()
                    await attempt({"grant":sibling["grant"]})
                print("grant expiry closed established TLS; reconnect denied", flush=True)
                r,w = await open_live(local)
                relay.close()
                await relay.wait_closed()
                before = len(origin_hits)
                await attempt({})
                assert len(origin_hits) == before and not direct_hits
                print("account relay listener stopped with live grant; new connection denied; direct hits=0", flush=True)
                status, body = await asyncio.to_thread(request, core_port, operator, "POST",
                                                       "/api/control/missions/" + mission + "/cancel", {})
                assert status == 200, (status, body)
                assert await asyncio.wait_for(r.read(1), 3) == b""
                w.close()
                await attempt({})
                print("Core cancellation closed established TLS; reconnect denied", flush=True)
                assert not direct_hits


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for arg in ("core","agy","cert","key"):
        parser.add_argument("--"+arg,required=True,type=lambda p:str(Path(p).resolve()))
    args = parser.parse_args()
    assert set(os.listdir("/sys/class/net")) == {"lo"}
    assert socket.gethostbyname(HOST)=="127.0.0.2"
    with tempfile.TemporaryDirectory() as root:
        claim = dict(node=NODE_ID,job=str(uuid4()),owner=str(uuid4()),account="ledger",revision=1,
                     node_token=secrets.token_hex(32),grant="orb-agy-v1_"+secrets.token_hex(24))
        target = port()
        env = dict(PATH=os.defpath, HOME=root, WORKING_DIR=root, HOST="127.0.0.1", PORT=str(target),
                   DEV_MODE="false", ORB_INSTANCE="dev", DASHBOARD_PASSWORD=secrets.token_hex(20),JWT_SECRET=secrets.token_hex(32),
                   LEAN_NUM_THREADS="2", FIXTURE_NODE_TOKEN=claim["node_token"],
                   SANDBOXED_REMOTE_NODES=json.dumps([dict(id=NODE_ID,base_url="http://127.0.0.2:1",
                        token_env="FIXTURE_NODE_TOKEN",dedicated_owner_id=claim["owner"])]))
        with core(args.core,env), sqlite3.connect(Path(root)/".sandboxed-sh/missions.db") as db:
            status, body = request(target, "", "POST", "/api/auth/login", {"username":"admin","password":env["DASHBOARD_PASSWORD"]})
            assert status == 200
            asyncio.run(exercise(args,root,db,target,claim,json.loads(body)["token"]))

if __name__=="__main__":
    main()
