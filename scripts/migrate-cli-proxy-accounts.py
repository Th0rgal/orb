#!/usr/bin/env python3
"""Import usable subscription snapshots after strict proxy ownership is deployed.

Dry-run by default. Tokens never appear in output. Existing proxy files are
preserved by default; --replace-unusable permits replacing stale snapshots.
"""
import argparse
import datetime as dt
import json
import os
from pathlib import Path
import sys
import urllib.error
import urllib.parse
import urllib.request

TYPES = {"anthropic": "claude", "openai": "codex", "xai": "xai", "kimi": "kimi"}


def load(path):
    with Path(path).open() as stream:
        return json.load(stream)


def codex_metadata(paths, oauth):
    for path in paths:
        value = load(path)
        tokens = value.get("tokens", value)
        # Only use metadata from the exact token generation being migrated.
        if tokens.get("refresh_token") == oauth["refresh_token"]:
            if tokens.get("id_token") and tokens.get("account_id"):
                return {key: tokens[key] for key in ("id_token", "account_id")}
    return None


def expiry_ms(value):
    try:
        return int(dt.datetime.fromisoformat(value.get("expired", "").replace("Z", "+00:00")).timestamp() * 1000)
    except (ValueError, TypeError):
        return 0


def plan(rows, existing, codex_paths, device_id, now_ms, replace_unusable=False):
    for row in rows:
        provider = row.get("provider_type")
        oauth = row.get("oauth")
        if provider not in TYPES or not oauth:
            continue
        record = {"id": row["id"], "provider": provider}
        identity = row.get("account_email")
        if row.get("rejected_oauth_refresh_fingerprint"):
            yield record, "reconnect: rejected refresh token", None
            continue
        matches = [a for a in existing if a.get("type") == TYPES[provider] and (
                (identity and a.get("email", "").lower() == identity.lower()) or
                a.get("refresh_token") == oauth.get("refresh_token"))]
        replacement = None
        if matches:
            if replace_unusable and len(matches) == 1 and matches[0].get("_filename") and 0 < expiry_ms(matches[0]) < now_ms - 86400000:
                replacement = matches[0]["_filename"]
            else:
                yield record, "preserve existing proxy login", None
                continue
        if oauth.get("expires_at", 0) <= now_ms or not all(oauth.get(k) for k in ("access_token", "refresh_token")):
            yield record, "reconnect: snapshot expired or incomplete", None
            continue
        value = dict(oauth, type=TYPES[provider], disabled=not row.get("enabled", True))
        value.pop("expires_at")
        value["expired"] = dt.datetime.fromtimestamp(oauth["expires_at"] / 1000, dt.timezone.utc).isoformat()
        if identity:
            value["email"] = identity
        if provider == "openai":
            metadata = codex_metadata(codex_paths, oauth)
            if not metadata:
                yield record, "reconnect: matching Codex identity metadata unavailable", None
                continue
            value.update(metadata)
        if provider == "kimi":
            if not device_id:
                yield record, "reconnect: Kimi device metadata unavailable", None
                continue
            value.update(device_id=device_id, token_type="Bearer")
        value["sandboxed_provider_id"] = row["id"]
        record["file"] = replacement or f'{TYPES[provider]}-sandboxed-{row["id"]}.json'
        if replacement:
            record["replace_unusable"] = True
        yield record, "import", value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--provider-store", type=Path, required=True)
    parser.add_argument("--auth-dir", type=Path, required=True)
    parser.add_argument("--codex-auth", type=Path, action="append", default=[])
    parser.add_argument("--kimi-device-file", type=Path)
    parser.add_argument("--management-url", default="http://127.0.0.1:8317/v0/management")
    parser.add_argument("--replace-unusable", action="store_true", help="Replace a matching proxy snapshot expired more than 24h ago, only with a usable source")
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    url = urllib.parse.urlparse(args.management_url)
    if url.hostname not in ("127.0.0.1", "localhost", "::1") or url.scheme not in ("http", "https"):
        parser.error("management URL must be loopback")
    key = os.environ.get("CLI_PROXY_MANAGEMENT_KEY")
    if args.apply and not key:
        parser.error("--apply requires server-only CLI_PROXY_MANAGEMENT_KEY")
    rows = load(args.provider_store)
    if isinstance(rows, dict):
        rows = list(rows.values())
    existing = [dict(load(path), _filename=path.name) for path in args.auth_dir.glob("*.json") if not path.is_symlink()]
    original = {item["_filename"]: item for item in existing}
    device_id = args.kimi_device_file.read_text().strip() if args.kimi_device_file else None
    now_ms = int(dt.datetime.now(dt.timezone.utc).timestamp() * 1000)
    for record, action, value in plan(rows, existing, args.codex_auth, device_id, now_ms, args.replace_unusable):
        record["action"] = action
        if args.apply and value:
            # Fail closed on colliding filenames; do not overwrite a newer login.
            path = args.auth_dir / record["file"]
            can_replace = record.get("replace_unusable") and not path.is_symlink() and path.exists() and load(path).get("refresh_token") == original[record["file"]].get("refresh_token")
            if path.exists() and not can_replace:
                record["action"] = "preserve existing filename"
            else:
                query = urllib.parse.urlencode({"name": record["file"]})
                request = urllib.request.Request(f'{args.management_url.rstrip("/")}/auth-files?{query}',
                    data=json.dumps(value).encode(), method="POST",
                    headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"})
                # Never print provider response bodies or credential-bearing errors.
                opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
                try:
                    with opener.open(request, timeout=20) as response:
                        response.read()
                except (urllib.error.URLError, OSError):
                    print(json.dumps(dict(record, action="import failed")))
                    return 1
                record["action"] = "imported"
                existing.append(value)
        print(json.dumps(record))
    return 0


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError, TypeError):
        sys.exit("Migration input could not be read or validated; no credentials were printed.")
