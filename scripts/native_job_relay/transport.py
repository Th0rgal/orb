"""Dev transport for an already admitted native job. No profile or process execution."""
import argparse
import asyncio
import enum
import http.client
import json
import os
import socket
import ssl
import time


class Destination(str, enum.Enum):
    OAUTH = "oauth2.googleapis.com"
    USERINFO = "www.googleapis.com"
    CLOUD_CODE = "cloudcode-pa.googleapis.com"
    DAILY_CLOUD_CODE = "daily-cloudcode-pa.googleapis.com"


async def read_frame(reader):
    line = await reader.readuntil(b"\n")
    if len(line) > 4096:
        raise ValueError("oversized admission")
    frame = json.loads(line)
    if not isinstance(frame, dict):
        raise ValueError("invalid admission")
    return frame


def admission(core_port, claim):
    """Consult authenticated Core on loopback. Never follow redirects."""
    conn = http.client.HTTPConnection("127.0.0.1", core_port, timeout=1)
    try:
        body = {k: claim[k] for k in ("job", "node", "owner", "account", "revision")}
        conn.request("POST", "/api/native/antigravity/relay-admission", json.dumps(body),
                     {"Content-Type": "application/json", "Authorization": "Bearer " + claim["node_token"],
                      "X-Orb-Job-Grant": claim["grant"]})
        reply = conn.getresponse()
        if reply.status != 200:
            raise PermissionError("admission denied")
        result = json.loads(reply.read(1024))
        return int(result["expires"]), int(result["route_generation"])
    finally:
        conn.close()


async def copy(reader, writer):
    while data := await reader.read(16384):
        writer.write(data)
        await writer.drain()


async def first_completed(*operations):
    tasks = [asyncio.create_task(op) for op in operations]
    try:
        complete, _ = await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
        for task in complete:
            task.result()
    finally:
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)


async def client_hello(reader, destination):
    # Inspect the native ClientHello without completing a TLS handshake or
    # presenting a certificate. The original bytes go to the provider.
    seen = []
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    def inspect(_ssl, name, _ctx):
        seen.append(name)
        return ssl.ALERT_DESCRIPTION_ACCESS_DENIED
    ctx.set_servername_callback(inspect)
    incoming = ssl.MemoryBIO()
    parser = ctx.wrap_bio(incoming, ssl.MemoryBIO(), server_side=True)
    wire = bytearray()
    while not seen:
        header = await reader.readexactly(5)
        length = int.from_bytes(header[3:], "big")
        if header[0] != 22 or not 0 < length <= 16384 or len(wire) + length + 5 > 65536:
            raise ValueError("expected TLS ClientHello")
        record = header + await reader.readexactly(length)
        wire.extend(record)
        incoming.write(record)
        try:
            parser.do_handshake()
        except ssl.SSLWantReadError:
            continue
        except ssl.SSLError:
            if seen != [destination.value]:
                raise ValueError("unexpected TLS server name") from None
    return wire


async def socks_connect(reader, writer, destination, account, password):
    writer.write(b"\x05\x01\x02")
    if await reader.readexactly(2) != b"\x05\x02":
        raise PermissionError("relay authentication required")
    username = ("antigravity/" + account).encode()
    secret = password.encode()
    writer.write(bytes([1, len(username)]) + username + bytes([len(secret)]) + secret)
    if await reader.readexactly(2) != b"\x01\x00":
        raise PermissionError("relay denied")
    name = destination.value.encode()
    writer.write(bytes([5, 1, 0, 3, len(name)]) + name + b"\x01\xbb")
    status = await reader.readexactly(4)
    if status != bytes([5, 0, 0, 1]):
        raise ConnectionError("account relay unavailable")
    await reader.readexactly(6)


class AccountTransport:
    """One account relay credential, held only on Core's trusted host."""
    def __init__(self, core_port, account, relay_port, password):
        self.core_port = core_port
        self.account = account
        self.relay_port = relay_port
        self.password = password
        self.connections = 0

    async def handle(self, reader, writer):
        if self.connections >= 32:
            writer.close()
            return
        self.connections += 1
        try:
            claim = await asyncio.wait_for(read_frame(reader), 3)
            destination = Destination(claim["destination"])
            if claim["account"] != self.account:
                raise PermissionError("wrong relay account")
            current = await asyncio.to_thread(admission, self.core_port, claim)
            expires, _ = current
            lifetime = expires - time.time()
            if lifetime <= 0:
                raise PermissionError("expired")
            async def monitor():
                while True:
                    await asyncio.sleep(.25)
                    if await asyncio.to_thread(admission, self.core_port, claim) != current:
                        raise PermissionError("grant changed")

            async def stream():
                upstream, out = await asyncio.wait_for(asyncio.open_connection("127.0.0.1", self.relay_port), 3)
                try:
                    await asyncio.wait_for(socks_connect(upstream, out, destination, self.account, self.password), 3)
                    writer.write(b"OK\n")
                    await writer.drain()
                    hello = await asyncio.wait_for(client_hello(reader, destination), 5)
                    if await asyncio.to_thread(admission, self.core_port, claim) != current:
                        raise PermissionError("grant changed")
                    out.write(hello)
                    await out.drain()
                    await first_completed(copy(reader, out), copy(upstream, writer))
                finally:
                    out.transport.abort()

            await asyncio.wait_for(first_completed(monitor(), stream()), lifetime)
        except (OSError, ValueError, KeyError, TypeError, EOFError, http.client.HTTPException,
                asyncio.LimitOverrunError, asyncio.TimeoutError):
            pass
        finally:
            self.connections -= 1
            writer.transport.abort()


async def node_connection(reader, writer, context, host, port, claim):
    """The supervisor supplies a listener accessible only inside this job boundary."""
    outer = None
    try:
        async def setup():
            nonlocal outer
            version, count = await reader.readexactly(2)
            if version != 5 or 0 not in await reader.readexactly(count):
                raise ValueError("unsupported SOCKS negotiation")
            writer.write(b"\x05\x00")
            if await reader.readexactly(4) != bytes([5, 1, 0, 3]):
                raise ValueError("expected a DNS destination")
            size = (await reader.readexactly(1))[0]
            dest = Destination((await reader.readexactly(size)).decode("ascii"))
            if await reader.readexactly(2) != b"\x01\xbb":
                raise ValueError("HTTPS port required")
            channel, outer = await asyncio.open_connection(host, port, ssl=context, server_hostname=host)
            outer.write(json.dumps(dict(claim, destination=dest.value)).encode() + b"\n")
            await outer.drain()
            if await channel.readexactly(3) != b"OK\n":
                raise PermissionError("denied")
            writer.write(bytes([5, 0, 0, 1]) + bytes(6))
            await writer.drain()
            return channel
        channel = await asyncio.wait_for(setup(), 8)
        await first_completed(copy(reader, outer), copy(channel, writer))
    except (OSError, ValueError, EOFError, asyncio.TimeoutError):
        pass
    finally:
        if outer is not None:
            outer.transport.abort()
        writer.transport.abort()


async def main(args):
    # Pass only an already bound listener and a supervisor-owned config pipe.
    # Neither reusable node nor account relay credentials enter the mission.
    with os.fdopen(args.config_fd) as handle:
        cfg = json.load(handle)
    listener = socket.socket(fileno=args.listen_fd)
    if args.role == "core":
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(cfg["cert"], cfg["key"])
        transport = AccountTransport(cfg["core_port"], cfg["account"], cfg["relay_port"], cfg["relay_password"])
        server = await asyncio.start_server(transport.handle, sock=listener, ssl=ctx, ssl_handshake_timeout=4, limit=8192)
    else:
        ctx = ssl.create_default_context(cafile=cfg.get("ca"))
        async def handle(r, w):
            await node_connection(r, w, ctx, cfg["host"], cfg["port"], cfg["claim"])
        server = await asyncio.start_server(handle, sock=listener, limit=8192)
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("role", choices=("core", "node"))
    parser.add_argument("--listen-fd", type=int, required=True)
    parser.add_argument("--config-fd", type=int, required=True)
    asyncio.run(main(parser.parse_args()))
