#!/usr/bin/env python3
"""Managed machines end-to-end check against a deployed Core.

Gated: refuses to run unless BOAT_E2E=1. Run on the Core host:

    BOAT_E2E=1 python3 scripts/managed_machines_e2e.py \
        --api http://127.0.0.1:3000 --env-file /etc/open_agent/open_agent.env

Steps: spawn a `small` machine (20 min TTL) -> assert it enrolled and is
online -> heartbeat visible in /api/remote-nodes -> run a trivial raw job on
it through a mission -> destroy -> ledger closed -> reconcile reports no
orphans and no tagged boat sandbox is still running. Prints JSON evidence.
Never prints tokens.
"""
import argparse, base64, hashlib, hmac, json, os, re, sys, time, urllib.request, urllib.error


def jwt(env_file):
    secret = None
    for line in open(env_file):
        m = re.match(r"\s*(?:export\s+)?JWT_SECRET=(.*)", line)
        if m:
            secret = m.group(1).strip().strip("\"'")
    if not secret:
        sys.exit("JWT_SECRET missing")
    b = lambda x: base64.urlsafe_b64encode(x).rstrip(b"=")
    now = int(time.time())
    h = b(json.dumps({"typ": "JWT", "alg": "HS256"}, separators=(",", ":")).encode())
    p = b(json.dumps({"sub": "e2e", "usr": "e2e", "iat": now, "exp": now + 3600}, separators=(",", ":")).encode())
    s = b(hmac.new(secret.encode(), h + b"." + p, hashlib.sha256).digest())
    return (h + b"." + p + b"." + s).decode()


class Api:
    def __init__(self, base, token):
        self.base, self.token = base.rstrip("/"), token

    def call(self, method, path, body=None, timeout=60):
        req = urllib.request.Request(
            self.base + path, method=method,
            data=json.dumps(body).encode() if body is not None else None,
            headers={"Authorization": "Bearer " + self.token, "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                raw = r.read()
                return r.status, (json.loads(raw) if raw else None)
        except urllib.error.HTTPError as e:
            raw = e.read()
            try:
                return e.code, json.loads(raw)
            except Exception:
                return e.code, raw.decode(errors="replace")[:500]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--api", default="http://127.0.0.1:3000")
    ap.add_argument("--env-file", default="/etc/open_agent/open_agent.env")
    ap.add_argument("--size", default="small")
    ap.add_argument("--keep", action="store_true", help="do not destroy (debug)")
    args = ap.parse_args()
    if os.environ.get("BOAT_E2E") != "1":
        print("skipped: set BOAT_E2E=1")
        return 0
    api = Api(args.api, jwt(args.env_file))
    ev = {"started_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
    t0 = time.time()
    st, m = api.call("POST", "/api/managed-machines",
                     {"size": args.size, "ttl_minutes": 20, "reason": "BOAT_E2E integration test"}, timeout=480)
    ev["spawn_status"], ev["spawn_seconds"] = st, round(time.time() - t0, 1)
    if st != 201:
        print(json.dumps({**ev, "error": m}, indent=2))
        return 1
    mid, node = m["id"], m["node_id"]
    ev.update(machine_id=mid, provider_id=m.get("provider_id"), node_id=node, state=m["state"])
    ok = m["state"] == "online"
    try:
        st, fleet = api.call("GET", "/api/remote-nodes")
        nv = next((n for n in fleet.get("nodes", []) if n["id"] == node), None)
        ev["fleet_entry"] = {k: nv.get(k) for k in ("status", "version", "protocol_version", "capacity_total", "labels", "lean_runtime_ready")} if nv else None
        ok = ok and nv is not None and nv.get("status") == "online"
        st, mission = api.call("POST", "/api/control/missions", {
            "title": f"managed e2e job on {node}", "remote_node_id": node,
            "remote_command": "echo managed-e2e-ok && hostname && nproc && free -g | head -2 && (lake --version || true)",
            "remote_async": True})
        ev["mission_create_status"] = st
        mission_id = (mission or {}).get("id")
        ev["mission_id"] = mission_id
        out = ""
        for _ in range(60):
            time.sleep(3)
            st, mm = api.call("GET", f"/api/control/missions/{mission_id}")
            status = (mm or {}).get("status")
            if status and status not in ("active", "pending"):
                break
        st, evs = api.call("GET", f"/api/control/missions/{mission_id}/events?limit=20")
        out = json.dumps(evs)[-4000:]
        ev["mission_status"] = status
        ev["job_output_has_marker"] = "managed-e2e-ok" in out
        ok = ok and ev["job_output_has_marker"]
    finally:
        if not args.keep:
            st, d = api.call("DELETE", f"/api/managed-machines/{mid}", timeout=120)
            ev["destroy_status"] = st
            closed = False
            for _ in range(30):
                st, d = api.call("GET", f"/api/managed-machines/{mid}")
                if d.get("ledger_closed"):
                    closed = True
                    break
                time.sleep(4)
            ev["final"] = {k: d.get(k) for k in ("state", "cost_usd", "cost_is_metered", "ledger_closed", "destroy_reason")}
            st, rec = api.call("POST", "/api/managed-machines/reconcile", {}, timeout=120)
            ev["reconcile"] = rec
            st, lst = api.call("GET", "/api/managed-machines")
            ev["live_after"] = [x["id"] for x in lst.get("machines", []) if x["state"] not in ("destroyed", "failed")]
            ok = ok and closed and d.get("state") == "destroyed" and not (rec or {}).get("orphans_stopped") and mid not in ev["live_after"]
    ev["ok"] = bool(ok)
    print(json.dumps(ev, indent=2))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
