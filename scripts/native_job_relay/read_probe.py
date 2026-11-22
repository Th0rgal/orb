"""Trusted dev helper for one explicit, tool-free Google generation. Output is a bounded receipt."""
import asyncio
import contextlib
import json
import os
from pathlib import Path
import pwd
import re
import secrets
import shutil
import ssl
import stat
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from native_job_relay.holder import directory, private_state
from native_job_relay.profile import start_profile
from native_job_relay.supervisor import profile_transport
from native_job_relay.transport import Destination, socks_connect


async def userinfo(packet):
    reader, writer = await asyncio.open_connection("127.0.0.1", packet["relay_port"])
    try:
        await socks_connect(reader, writer, Destination.USERINFO, packet["account"], packet["relay_password"])
        host = Destination.USERINFO.value
        await writer.start_tls(ssl.create_default_context(), server_hostname=host)
        request = ("GET /oauth2/v2/userinfo HTTP/1.1\r\nHost: " + host + "\r\nConnection: close\r\n"
                   "Authorization: Bearer " + packet["access_token"] + "\r\n\r\n")
        writer.write(request.encode())
        await writer.drain()
        # Read the status only. The profile identity returned in the body stays private.
        status = (await reader.readline()).split()
        return int(status[1]) if len(status) >= 2 and status[0].startswith(b"HTTP/") else 0
    finally:
        writer.transport.abort()


def read_log_tail(home, limit=524288):
    try:
        fd = os.open("probe.log", os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=home)
    except OSError:
        return b""
    with os.fdopen(fd, "rb") as log:
        info = os.fstat(log.fileno())
        if not stat.S_ISREG(info.st_mode):
            return b""
        log.seek(max(0, info.st_size - limit))
        return log.read(limit)


def classification(result, diagnostic, log):
    # Whitelist terms, never forward provider text, identifiers, account names or URLs.
    terminal = (json.dumps({k: result.get(k) for k in ("error", "message", "response", "reason", "code")}).encode()
                + diagnostic).lower()
    cases = [("account_verification", (b"verify your account", b"account verification", b"validation_required",
                                       b"validation required", b"accounts.google.com/signin/continue")),
             ("consumer_eligibility", (b"not eligible", b"ineligible", b"does not have access", b"not available for")),
             ("terms", (b"terms of service", b"terms acceptance")),
             ("region", (b"country", b"region not supported", b"location is not supported")),
             ("insufficient_scope", (b"insufficient authentication scopes", b"insufficient_scope", b"access_token_scope_insufficient")),
             ("disabled_api", (b"service_disabled", b"api has not been used", b"api is disabled")),
             ("project_permission", (b"permission on project", b"permission to use project", b"consumer_invalid")),
             ("model_access", (b"permission to access model", b"do not have access to this model", b"model not available"))]
    reason = next((label for label, markers in cases if any(m in terminal for m in markers)), "unspecified")
    tags = [(b"streamgeneratecontent","generation"), (b"/oauth2/v2/userinfo","userinfo"),
            (b"fetchuserinfo","fetch_user_info"), (b"loadcodeassist","load_code_assist"),
            (b"fetchavailablemodels","catalog"), (b"eligib","headless_eligibility")]
    phase = next((label for marker,label in tags if marker in terminal), "unknown")
    failure_lines = [line.lower() for line in log.splitlines() if re.search(
        rb"(?i)\b403\b|permission_denied|not eligible|verify your account|validation_required", line)]
    log_phases = {label for marker,label in tags if any(marker in line for line in failure_lines)}
    if reason == "unspecified":
        reason = next((label for label, markers in cases if any(m in line for m in markers for line in failure_lines)), reason)
    code = next((name for name in ("PERMISSION_DENIED", "UNAUTHENTICATED", "RESOURCE_EXHAUSTED", "NOT_FOUND")
                 if name.encode().lower() in terminal), "unspecified")
    http = next((n for n in (401,403,429,400,404) if re.search(rb"\b" + str(n).encode() + rb"\b", terminal)), 0)
    return terminal, dict(phase=phase, native_code=code, native_http=http, reason=reason,
                          observed_phase=next(iter(log_phases)) if len(log_phases) == 1 else "unknown")


def main():
    if os.geteuid() or len(sys.argv) != 3:
        return 1
    runtime, username = Path(sys.argv[1]), sys.argv[2]
    identity = pwd.getpwnam(username)
    packet = json.loads(sys.stdin.buffer.readline(65536))
    if packet["model"] not in ("gemini-4-carbon-high", "gemini-4-neon-high"):
        return 1
    nonce = "ORB-" + secrets.token_hex(8)
    with contextlib.ExitStack() as stack:
        temp = Path(stack.enter_context(tempfile.TemporaryDirectory(dir=runtime)))
        (temp / "sessions").mkdir(mode=0o700)
        home = private_state(stack, temp, "probe", identity.pw_uid, identity.pw_gid)
        ipc = directory(stack, temp)
        image = directory(stack, runtime / "profile-image")
        ns, port = stack.enter_context(profile_transport(packet["relay_port"], relay_account=packet["account"],
                                                          relay_password=packet["relay_password"]))
        def launch(model, catalog=False):
            return start_profile(shutil.which("nsenter"), shutil.which("bwrap"), image, home, ipc, ns, port,
                                 identity.pw_uid, identity.pw_gid, packet["access_token"], model,
                                 workspace=False, catalog=catalog, diagnostic=True)
        child = launch(packet["model"], catalog=True)
        try:
            listing, diagnostic = child.communicate(timeout=15)
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait()
            print('{"result":"catalog_timeout"}')
            return 1
        ids = set(re.findall(rb"(?<![a-z0-9-])gemini-4-(?:neon|carbon)(?:-[a-z0-9]+)*(?![a-z0-9-])", listing.lower()))
        family = packet["model"].removesuffix("-high")
        selected = next((m for m in (packet["model"], family) if m.encode() in ids), None)
        if child.returncode or not selected:
            reason = "catalog_unavailable" if child.returncode else "model_not_in_catalog"
            text = (listing + diagnostic).lower()
            if b"bwrap:" in text or b"nsenter:" in text or b"setpriv:" in text:
                reason = "catalog_isolation_unavailable"
            elif b"error while loading shared libraries" in text:
                reason = "catalog_library_unavailable"
            elif b"401" in text or b"unauthenticated" in text or b"login" in text or b"log in" in text:
                reason = "catalog_authentication_required"
            elif b"403" in text or b"permission_denied" in text:
                reason = "catalog_provider_denied"
            elif b"connect" in text or b"proxy" in text or b"timeout" in text or b"certificate" in text:
                reason = "catalog_transport_unavailable"
            print(json.dumps({"result":reason,"code":child.returncode}))
            return 1
        try:
            identity_status = asyncio.run(asyncio.wait_for(userinfo(packet), 8))
        except (ValueError, OSError, asyncio.TimeoutError, EOFError):
            identity_status = 0
        child = launch(selected)
        prompt = "Reply with exactly this text and no other content: " + nonce
        message = {"event": "user", "message": {"role":"user","content":prompt}}
        try:
            out, diagnostic = child.communicate(json.dumps(message).encode() + b"\n", timeout=55)
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait()
            print('{"result":"timeout"}')
            return 1
        note = read_log_tail(home)
    # Raw CLI output can contain an OAuth challenge. Only classify it locally.
    if len(out) > 1024 * 1024:
        print('{"result":"oversized_response"}')
        return 1
    events = [json.loads(line) for line in out.splitlines() if line]
    result = next((e.get("result", {}) for e in reversed(events) if e.get("event") == "result"), {})
    raw, detail = classification(result, diagnostic, note)
    if child.returncode == 0 and result.get("status") == "SUCCESS" and result.get("response", "").strip() == nonce:
        kind = "verified"
    elif detail["native_code"] == "PERMISSION_DENIED" or detail["native_http"] == 403 or b"ineligible" in raw:
        kind = "provider_denied"
    elif b"authentication" in raw or b"not logged in" in raw or b"unauthenticated" in raw:
        kind = "authentication_required"
    elif b"quota" in raw or b"429" in raw:
        kind = "quota"
    elif b"model" in raw and (b"not found" in raw or b"not available" in raw):
        kind = "model_unavailable"
    else:
        kind = "native_error" if child.returncode else "response_mismatch"
    print(json.dumps({"result":kind,"cli_exit":child.returncode,"native_terminal":bool(result),"selected":selected,"userinfo_status":identity_status, **detail}))
    return 0 if kind == "verified" else 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (KeyError, OSError, RuntimeError, ValueError):
        print('{"result":"probe_unavailable"}')
        sys.exit(1)
