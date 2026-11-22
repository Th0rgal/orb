#!/usr/bin/env python3
"""Exercise the Core profile tunnel with a synthetic VPN gateway, without an account."""
import asyncio
import ssl
from unittest.mock import patch

from native_job_relay.supervisor import profile_transport
from native_job_relay.transport import Destination, local_profile_connection


def hello(host):
    outgoing = ssl.MemoryBIO()
    tls = ssl.create_default_context().wrap_bio(ssl.MemoryBIO(), outgoing, server_hostname=host)
    try:
        tls.do_handshake()
    except ssl.SSLWantReadError:
        return outgoing.read()
    raise AssertionError("expected ClientHello")


async def connect(adapter, host, server_name=None, target_port=443):
    reader, writer = await asyncio.open_connection("127.0.0.1", adapter.sockets[0].getsockname()[1])
    try:
        writer.write(b"\x05\x01\x00")
        assert await reader.readexactly(2) == b"\x05\x00"
        name = host.encode()
        writer.write(bytes([5, 1, 0, 3, len(name)]) + name + target_port.to_bytes(2))
        if not server_name:
            assert await reader.read() == b""
            return
        assert await reader.readexactly(10) == bytes([5, 0, 0, 1]) + bytes(6)
        payload = hello(server_name)
        writer.write(payload)
        result = await reader.read()
        if host == server_name:
            assert result == b"observed"
            return payload
        else:
            assert not result
    finally:
        writer.close()
        await writer.wait_closed()


async def main():
    forwarded = []
    destinations = []
    for invalid in [None, 0, -1, True, 65536]:
        try:
            profile_transport(invalid)
        except ValueError:
            continue
        raise AssertionError("unverified gateway accepted")

    async def gateway(reader, writer):
        try:
            assert await reader.readexactly(3) == b"\x05\x01\x00"
            writer.write(b"\x05\x00")
            assert await reader.readexactly(4) == b"\x05\x01\x00\x03"
            length = (await reader.readexactly(1))[0]
            destinations.append((await reader.readexactly(length)).decode())
            assert await reader.readexactly(2) == b"\x01\xbb"
            writer.write(b"\x05\x00\x00\x04" + bytes(18))
            data = await reader.read(65536)
            if data:
                forwarded.append(data)
                writer.write(b"observed")
                await writer.drain()
        finally:
            writer.close()

    async with await asyncio.start_server(gateway, "127.0.0.1", 0) as vpn:
        port = vpn.sockets[0].getsockname()[1]
        async with await asyncio.start_server(
                lambda r, w: local_profile_connection(r, w, port), "127.0.0.1", 0) as adapter:
            await connect(adapter, "example.invalid")
            await connect(adapter, Destination.USERINFO.value, target_port=80)
            assert not destinations
            await connect(adapter, Destination.CLOUD_CODE.value, "example.invalid")
            assert not forwarded
            for dest in Destination:
                assert await connect(adapter, dest.value, dest.value) == forwarded[-1]
            assert len(forwarded) == len(Destination)
            assert destinations == [Destination.CLOUD_CODE.value] + [dest.value for dest in Destination]
    outbound = []
    original = asyncio.open_connection
    async def verified_peer(reader, writer):
        if await reader.read(65536):
            writer.write(b"observed")
            await writer.drain()
        writer.close()

    async with await asyncio.start_server(verified_peer, "127.0.0.1", 0) as upstream:
        async def intercept(host, port):
            if host != "127.0.0.1":
                outbound.append((host, port))
                assert host in {d.value for d in Destination} and port == 443
                return await original("127.0.0.1", upstream.sockets[0].getsockname()[1])
            return await original(host, port)
        with patch.object(asyncio, "open_connection", intercept):
            async with await asyncio.start_server(
                    lambda r, w: local_profile_connection(r, w, None, direct=True), "127.0.0.1", 0) as adapter:
                host = Destination.USERINFO.value
                await connect(adapter, host, host)
                await connect(adapter, "outside.invalid")
                await connect(adapter, host, "outside.invalid")
                assert outbound == [(host, 443), (host, 443)]
            # A verified port which has ceased listening must fail closed.
            async with await asyncio.start_server(
                    lambda r, w: local_profile_connection(r, w, port), "127.0.0.1", 0) as adapter:
                await connect(adapter, host)
                assert outbound == [(host, 443), (host, 443)]
    for invalid_route in ({"direct": True, "verified_port": 1234},
                          {"direct": True, "verified_port": None, "relay_password": "fixture"},
                          {"direct": 1, "verified_port": None}):
        try:
            profile_transport(**invalid_route)
        except ValueError:
            continue
        raise AssertionError("ambiguous native route accepted")
    print("Core profile: TLS forwarded unchanged for each assigned Google destination; Direct retained its SNI restrictions and failed VPN did not use Direct")


if __name__ == "__main__":
    asyncio.run(asyncio.wait_for(main(), 10))
