#!/usr/bin/env bash
# Harden Ubuntu GitHub Actions runners against transient Azure DNS (`168.63.129.16`)
# lookup drops ("Temporary failure resolving 'azure.archive.ubuntu.com'") during
# large apt-get bursts (WebKitGTK / Playwright --with-deps).
set -euo pipefail

printf 'Acquire::Retries "5";\nAcquire::ForceIPv4 "true";\n' \
  | sudo tee /etc/apt/apt.conf.d/80-ci-retries >/dev/null

if [ -d /etc/systemd ]; then
  sudo mkdir -p /etc/systemd/resolved.conf.d
  printf '[Resolve]\nDNS=1.1.1.1 8.8.8.8\nFallbackDNS=1.0.0.1 8.8.4.4\n' \
    | sudo tee /etc/systemd/resolved.conf.d/ci-dns.conf >/dev/null
  sudo systemctl restart systemd-resolved 2>/dev/null || true
fi

sudo python3 - <<'PY'
import json, socket, urllib.request

hosts = ["azure.archive.ubuntu.com", "archive.ubuntu.com", "security.ubuntu.com"]
with open("/etc/hosts", "r", encoding="utf-8") as f:
    existing = f.read()

lines = []
for h in hosts:
    if f" {h}" in existing or f"\t{h}" in existing:
        continue
    ip = None
    try:
        req = urllib.request.Request(
            f"https://1.1.1.1/dns-query?name={h}&type=A",
            headers={"Accept": "application/dns-json"},
        )
        with urllib.request.urlopen(req, timeout=4) as resp:
            data = json.load(resp)
            ip = next((a["data"] for a in data.get("Answer", []) if a.get("type") == 1), None)
    except Exception:
        ip = None
    if not ip:
        try:
            ip = socket.gethostbyname(h)
        except OSError:
            ip = None
    if ip:
        lines.append(f"{ip} {h}\n")

if lines:
    with open("/etc/hosts", "a", encoding="utf-8") as f:
        f.writelines(lines)
PY
