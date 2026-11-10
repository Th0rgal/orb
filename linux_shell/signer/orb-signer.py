#!/usr/bin/env python3
"""orb-signer (Linux): Touch ID (fprintd) + Polkit approval key signer for Orb.

Mirrors macos_shell/signer/main.swift CLI and JSON wire protocol:
  orb-signer status                     -> {"available": "true"|"false", "kind": ..., "label": ...}
  orb-signer auth --reason R            -> {"authenticated": "true"}
  orb-signer create --key PATH          -> {"public_key": "<base64 SPKI DER>"}
  orb-signer public --key PATH          -> {"public_key": "<base64 SPKI DER>"}
  orb-signer sign --key PATH --reason R -> stdin payload, {"signature": "<base64 DER>"}
  orb-signer serve --key PATH           -> base64 payload lines on stdin, JSON reply lines on stdout
"""
import base64
import getpass
import json
import os
import shutil
import subprocess
import sys
import time
import uuid


def find_bin(name: str, extra_paths: tuple[str, ...] = ()) -> str | None:
    found = shutil.which(name)
    if found:
        return found
    user = getpass.getuser()
    candidates = (
        *extra_paths,
        f"/etc/profiles/per-user/{user}/bin/{name}",
        f"/run/current-system/sw/bin/{name}",
        f"/usr/bin/{name}",
        f"/bin/{name}",
    )
    for c in candidates:
        if c and os.path.isfile(c) and os.access(c, os.X_OK):
            return c
    return None


OPENSSL = find_bin("openssl", (os.environ.get("ORB_OPENSSL_BIN", ""),))
PKCHECK = find_bin("pkcheck")
CLAMSHELL = find_bin("omarchy-hw-laptop-closed")


def emit(obj: dict[str, str]) -> None:
    sys.stdout.write(json.dumps(obj, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def fail(msg: str, code: int = 1) -> "Never":
    sys.stderr.write(msg + "\n")
    sys.stderr.flush()
    sys.exit(code)


def lid_closed() -> bool:
    if not CLAMSHELL:
        return False
    try:
        return subprocess.run([CLAMSHELL], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=2).returncode == 0
    except Exception:
        return False


def fprintd_enrolled() -> tuple[bool, str | None]:
    fplist = find_bin("fprintd-list")
    fpverify = find_bin("fprintd-verify")
    if not (fplist and fpverify):
        return False, None
    try:
        r = subprocess.run([fplist, getpass.getuser()], capture_output=True, text=True, timeout=5)
        ok = r.returncode == 0 and (
            " - #" in r.stdout or ("Fingerprints for user" in r.stdout and "has no fingers" not in r.stdout)
        )
        return ok, fpverify
    except Exception:
        return False, None


def polkit_available() -> bool:
    if not PKCHECK:
        return False
    has_session = bool(
        os.environ.get("WAYLAND_DISPLAY")
        or os.environ.get("DISPLAY")
        or os.environ.get("XDG_RUNTIME_DIR")
        or os.path.isdir(f"/run/user/{os.getuid()}")
    )
    return has_session


def proc_subject() -> str:
    try:
        stat = open("/proc/self/stat", encoding="utf-8").read()
        start_time = stat.rsplit(")", 1)[1].split()[19]
        return f"{os.getpid()},{start_time},{os.getuid()}"
    except Exception:
        return str(os.getpid())


def verify_polkit(reason: str) -> tuple[bool, int, str]:
    if not polkit_available() or not PKCHECK:
        return False, 3, "Touch ID / Polkit authentication is not available in this session"
    clean = " ".join((reason or "Authenticate").splitlines()).strip()[:240]
    try:
        r = subprocess.run(
            [
                PKCHECK,
                "--action-id",
                "org.freedesktop.policykit.exec",
                "--process",
                proc_subject(),
                "--allow-user-interaction",
                "--details",
                "polkit.message",
                f"Orb: {clean}",
            ],
            capture_output=True,
            text=True,
            timeout=60,
        )
        if r.returncode == 0:
            return True, 0, ""
        err = ((r.stderr or "") + " " + (r.stdout or "")).strip()
        low = err.lower()
        if r.returncode == 2 or "dismissed" in low or "cancel" in low:
            return False, 2, "Authentication cancelled"
        return False, 1, f"Authentication failed: {err or 'not authorized'}"
    except subprocess.TimeoutExpired:
        return False, 2, "Authentication timed out"
    except Exception as exc:
        return False, 1, f"Authentication error: {exc}"


def verify_user(reason: str) -> tuple[bool, int, str]:
    ok_fp, fpverify = fprintd_enrolled()
    if ok_fp and fpverify and not lid_closed():
        try:
            r = subprocess.run([fpverify], capture_output=True, text=True, timeout=35)
            out = (r.stdout or "") + "\n" + (r.stderr or "")
            if r.returncode == 0 and "verify-match" in out:
                return True, 0, ""
            if "verify-no-match" in out:
                if polkit_available():
                    return verify_polkit(reason)
                return False, 1, "Touch ID: fingerprint did not match"
            if polkit_available():
                return verify_polkit(reason)
            return False, 2, "Touch ID: authentication cancelled"
        except subprocess.TimeoutExpired:
            return False, 2, "Touch ID: timed out"
        except Exception as exc:
            if polkit_available():
                return verify_polkit(reason)
            return False, 1, f"Touch ID: {exc}"
    return verify_polkit(reason)


def pubkey_spki_b64(pem_path: str) -> str:
    if not OPENSSL:
        fail("openssl binary not found on PATH", 3)
    r = subprocess.run(
        [OPENSSL, "pkey", "-in", pem_path, "-pubout", "-outform", "DER"],
        capture_output=True,
        check=True,
    )
    return base64.b64encode(r.stdout).decode("ascii")


def grace_eligible(payload_bytes: bytes) -> bool:
    try:
        lines = payload_bytes.decode("utf-8").split("\n")
        if len(lines) < 6:
            return False
        route = lines[2].split(" ")
        if len(route) != 2 or route[0] != "POST":
            return False
        parts = [p for p in route[1].split("/") if p]
        if len(parts) != 5 or parts[:3] != ["api", "bitwarden", "requests"]:
            return False
        uuid.UUID(parts[3])
        return parts[4] in ("approve", "reject")
    except Exception:
        return False


def main() -> None:
    args = sys.argv[1:]
    if not args:
        fail("usage: orb-signer create|public|sign|auth|status|serve --key PATH")
    cmd = args[0]

    def opt(name: str) -> str | None:
        for i, a in enumerate(args):
            if a == name and i + 1 < len(args):
                return args[i + 1]
        return None

    if cmd == "status":
        ok_fp, _ = fprintd_enrolled()
        if ok_fp and bool(OPENSSL):
            emit({"available": "true", "kind": "touch_id", "label": "Touch ID"})
        elif polkit_available() and bool(OPENSSL):
            emit({"available": "true", "kind": "passcode", "label": "Touch ID or Password"})
        else:
            emit({"available": "false", "kind": "none", "label": "Unavailable"})
        sys.exit(0)

    if cmd == "auth":
        reason = (opt("--reason") or "Authenticate").strip() or "Authenticate"
        ok, code, msg = verify_user(reason)
        if not ok:
            fail(msg, code)
        emit({"authenticated": "true"})
        sys.exit(0)

    key_path = opt("--key")
    if not key_path:
        fail("--key is required")

    def sign_payload(payload_bytes: bytes, skip_prompt: bool = False) -> tuple[str | None, int, str]:
        if not OPENSSL:
            return None, 3, "openssl binary not found"
        try:
            text = payload_bytes.decode("utf-8")
            lines = text.split("\n")
            summary = lines[-1] if lines else ""
            if not text.startswith("paloma-approval-v1\n") or not summary:
                return None, 1, "Not a Paloma approval payload"
        except Exception:
            return None, 1, "Not a Paloma approval payload"
        if not os.path.isfile(key_path):
            return None, 4, f"No approval key at {key_path}"
        if not skip_prompt:
            ok, code, msg = verify_user(summary)
            if not ok:
                return None, code, msg
        try:
            r = subprocess.run(
                [OPENSSL, "dgst", "-sha256", "-sign", key_path, "-binary"],
                input=payload_bytes,
                capture_output=True,
                check=True,
            )
            return base64.b64encode(r.stdout).decode("ascii"), 0, ""
        except Exception as exc:
            return None, 1, f"Signing failed: {exc}"

    if cmd == "create":
        ok_fp, _ = fprintd_enrolled()
        if not OPENSSL or not (ok_fp or polkit_available()):
            fail("Touch ID or Polkit authentication is not available on this host", 3)
        parent = os.path.dirname(os.path.abspath(key_path))
        os.makedirs(parent, mode=0o700, exist_ok=True)
        gen = subprocess.run(
            [OPENSSL, "ecparam", "-name", "prime256v1", "-genkey", "-noout"],
            capture_output=True,
            check=True,
        )
        fd = os.open(key_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
        try:
            os.fchmod(fd, 0o600)
            os.write(fd, gen.stdout)
            os.fsync(fd)
        finally:
            os.close(fd)
        emit({"public_key": pubkey_spki_b64(key_path)})
    elif cmd == "public":
        if not os.path.isfile(key_path):
            fail(f"No approval key at {key_path}", 4)
        emit({"public_key": pubkey_spki_b64(key_path)})
    elif cmd == "sign":
        payload = sys.stdin.buffer.read()
        sig, code, msg = sign_payload(payload, skip_prompt=False)
        if sig is None:
            fail(msg, code)
        emit({"signature": sig})
    elif cmd == "serve":
        try:
            grace = min(max(int(opt("--grace") or "300"), 0), 3600)
        except ValueError:
            grace = 300
        held_at: float | None = None
        for raw_line in sys.stdin:
            now = time.time()
            if held_at is not None and (now - held_at) > grace:
                held_at = None
            try:
                payload = base64.b64decode(raw_line.strip(), validate=True)
            except Exception:
                emit({"error": "Invalid request", "code": "1"})
                continue
            eligible = grace_eligible(payload)
            skip = bool(eligible and held_at is not None and grace > 0)
            sig, code, msg = sign_payload(payload, skip_prompt=skip)
            if sig is not None:
                if eligible and held_at is None and grace > 0:
                    held_at = time.time()
                elif not eligible:
                    held_at = None
                reply = {"signature": sig}
                if held_at is not None:
                    reply["grace_until"] = str(int(held_at + grace))
                emit(reply)
            else:
                held_at = None
                emit({"error": msg, "code": str(code)})
    else:
        fail(f"unknown command {cmd}")


if __name__ == "__main__":
    main()
