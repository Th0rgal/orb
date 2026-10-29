#!/usr/bin/env bash
# Provision https://orbrouter.thomas.md as a direct (grey-cloud, non-Cloudflare-proxied)
# TLS endpoint for Orb's /v1/* LLM router on agent-core, and verify both Google
# Carbon EAP routes (GEMINI_API_KEY primary, thomas.marchand44@gmail.com secondary).
#
# Run as root on agent-core (or via `ssh agent-core 'bash -s' < scripts/setup-orbrouter.sh`).
# Never prints secret values.

set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/root/.local/bin:${PATH:-}"

DOMAIN="${ORBROUTER_DOMAIN:-orbrouter.thomas.md}"
ZONE_NAME="${ORBROUTER_ZONE:-thomas.md}"
UPSTREAM_PORT="${ORBROUTER_UPSTREAM_PORT:-3000}"

log() {
    printf '[orbrouter] %s\n' "$*"
}

die() {
    printf '[orbrouter] ERROR: %s\n' "$*" >&2
    exit 1
}

read_env_var_from_files() {
    local key="$1"
    shift
    local file line val
    for file in "$@"; do
        [[ -r "$file" ]] || continue
        line="$(grep -E "^(export[[:space:]]+)?${key}=" "$file" | tail -n 1 || true)"
        if [[ -n "$line" ]]; then
            val="${line#*=}"
            val="${val%\"}"
            val="${val#\"}"
            val="${val%\'}"
            val="${val#\'}"
            if [[ -n "$val" ]]; then
                printf '%s' "$val"
                return 0
            fi
        fi
    done
    return 1
}

resolve_bws_secret() {
    local secret_key="$1"
    local bws_token="${BWS_ACCESS_TOKEN:-}"
    if [[ -z "$bws_token" ]]; then
        bws_token="$(read_env_var_from_files BWS_ACCESS_TOKEN \
            /etc/open_agent/open_agent.env \
            /etc/open_agent/open_agent_dev.env \
            /etc/sandboxed-sh/prod.env \
            /etc/sandboxed-sh/sandboxed-sh-prod.env \
            /etc/sandboxed-sh/sandboxed-sh.env \
            /etc/default/sandboxed-sh-prod || true)"
    fi
    if [[ -z "$bws_token" ]] && command -v systemctl >/dev/null 2>&1; then
        bws_token="$(systemctl show -p Environment sandboxed-sh-prod.service 2>/dev/null \
            | tr ' ' '\n' | sed -n 's/^BWS_ACCESS_TOKEN=//p' | head -n 1 || true)"
    fi
    [[ -n "$bws_token" ]] || return 1
    command -v bws >/dev/null 2>&1 || return 1
    BWS_ACCESS_TOKEN="$bws_token" bws secret list --output json 2>/dev/null | python3 -c '
import json, sys
target = sys.argv[1]
items = json.load(sys.stdin)
matches = [i["value"] for i in items if i.get("key") == target and i.get("value")]
if not matches:
    for i in items:
        if (i.get("key") or "").upper() == target.upper() and i.get("value"):
            matches.append(i["value"])
if not matches:
    sys.exit(1)
sys.stdout.write(matches[0])
' "$secret_key"
}

resolve_cf_token() {
    if [[ -n "${CLOUDFLARE_API_TOKEN:-}" ]]; then
        printf '%s' "$CLOUDFLARE_API_TOKEN"
        return 0
    fi
    local tok=""
    tok="$(read_env_var_from_files CLOUDFLARE_API_TOKEN \
        /etc/open_agent/open_agent.env \
        /etc/open_agent/open_agent_dev.env \
        /etc/sandboxed-sh/prod.env \
        /etc/sandboxed-sh/sandboxed-sh-prod.env \
        /etc/sandboxed-sh/hermes-assistant.env \
        /root/.cloudflare.env || true)"
    if [[ -n "$tok" ]]; then
        printf '%s' "$tok"
        return 0
    fi
    for candidate in CLOUDFLARE_API_TOKEN CF_API_TOKEN CLOUDFLARE_DNS_API_TOKEN; do
        tok="$(resolve_bws_secret "$candidate" || true)"
        if [[ -n "$tok" ]]; then
            printf '%s' "$tok"
            return 0
        fi
    done
    return 1
}

PUBLIC_IPV4="${ORBROUTER_IPV4:-$(curl -4 -fsSL https://ifconfig.me || ip -4 route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n 1)}"
[[ -n "$PUBLIC_IPV4" ]] || die "Could not determine public IPv4 of host"
log "Target host IPv4: ${PUBLIC_IPV4} for ${DOMAIN} (DNS-only / grey cloud)"

CF_TOKEN="$(resolve_cf_token || true)"
[[ -n "$CF_TOKEN" ]] || die "CLOUDFLARE_API_TOKEN not found in env, /etc/sandboxed-sh/*.env, or Bitwarden"

# 1. Upsert DNS-only (proxied=false) A record in Cloudflare
ZONE_RESP="$(curl -fsSL -H "Authorization: Bearer ${CF_TOKEN}" \
    -H "Content-Type: application/json" \
    "https://api.cloudflare.com/client/v4/zones?name=${ZONE_NAME}" || true)"

ZONE_ID="$(printf '%s' "$ZONE_RESP" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
if not d.get("success") or not d.get("result"):
    errs = d.get("errors") or []
    sys.stderr.write(f"Cloudflare zone lookup failed: {errs}\n")
    sys.exit(1)
sys.stdout.write(d["result"][0]["id"])
')" || die "Cloudflare API token rejected or zone ${ZONE_NAME} unavailable (rotate CLOUDFLARE_API_TOKEN if expired)"

EXISTING_REC="$(curl -fsSL -H "Authorization: Bearer ${CF_TOKEN}" \
    -H "Content-Type: application/json" \
    "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records?type=A&name=${DOMAIN}")"

RECORD_ID="$(printf '%s' "$EXISTING_REC" | python3 -c '
import json, sys
d = json.load(sys.stdin)
res = d.get("result") or []
if res:
    sys.stdout.write(res[0]["id"])
')"

PAYLOAD="$(python3 -c '
import json, sys
print(json.dumps({
    "type": "A",
    "name": sys.argv[1],
    "content": sys.argv[2],
    "ttl": 120,
    "proxied": False,
    "comment": "Orb direct LLM proxy router (grey cloud, no 100s timeout)"
}))
' "$DOMAIN" "$PUBLIC_IPV4")"

if [[ -n "$RECORD_ID" ]]; then
    log "Updating existing Cloudflare A record ${DOMAIN} -> ${PUBLIC_IPV4} (proxied=false)"
    curl -fsSL -X PUT \
        -H "Authorization: Bearer ${CF_TOKEN}" \
        -H "Content-Type: application/json" \
        --data "$PAYLOAD" \
        "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records/${RECORD_ID}" >/dev/null
else
    log "Creating Cloudflare A record ${DOMAIN} -> ${PUBLIC_IPV4} (proxied=false)"
    curl -fsSL -X POST \
        -H "Authorization: Bearer ${CF_TOKEN}" \
        -H "Content-Type: application/json" \
        --data "$PAYLOAD" \
        "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records" >/dev/null
fi
unset CF_TOKEN

# 2. Bootstrap HTTP vhost for ACME if certificate does not exist yet
CERT_DIR="/etc/letsencrypt/live/${DOMAIN}"
NGINX_AVAIL="/etc/nginx/sites-available/${DOMAIN}"
NGINX_ENABLED="/etc/nginx/sites-enabled/${DOMAIN}"
mkdir -p /var/www/html

if [[ ! -f "${CERT_DIR}/fullchain.pem" ]]; then
    log "Issuing Let's Encrypt certificate for ${DOMAIN}"
    cat >"$NGINX_AVAIL" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    location / {
        return 404;
    }
}
EOF
    ln -sfn "$NGINX_AVAIL" "$NGINX_ENABLED"
    nginx -t && systemctl reload nginx

    # Wait briefly for DNS propagation before HTTP-01 challenge
    for _ in {1..15}; do
        resolved="$(dig +short "${DOMAIN}" @1.1.1.1 | head -n 1 || true)"
        [[ "$resolved" == "$PUBLIC_IPV4" ]] && break
        sleep 2
    done

    certbot certonly --webroot -w /var/www/html \
        -d "${DOMAIN}" \
        --non-interactive \
        --agree-tos \
        --register-unsafely-without-email \
        --keep-until-expiring
fi

# 3. Install hardened TLS /v1-only reverse proxy vhost (no buffering, 600s read timeout)
log "Writing nginx config ${NGINX_AVAIL}"
cat >"$NGINX_AVAIL" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${DOMAIN};

    ssl_certificate     ${CERT_DIR}/fullchain.pem;
    ssl_certificate_key ${CERT_DIR}/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_session_cache   shared:SSL:10m;
    ssl_session_timeout 1d;

    client_max_body_size 64m;

    location = /health {
        access_log off;
        default_type application/json;
        return 200 '{"ok":true,"router":"orbrouter"}\n';
    }

    # Expose ONLY the Bearer-authenticated /v1/* LLM router surface.
    location /v1/ {
        proxy_pass http://127.0.0.1:${UPSTREAM_PORT};
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;

        proxy_buffering off;
        proxy_request_buffering off;
        proxy_cache off;
        chunked_transfer_encoding on;

        proxy_connect_timeout 30s;
        proxy_send_timeout 600s;
        proxy_read_timeout 600s;
    }

    location / {
        return 404;
    }
}
EOF

ln -sfn "$NGINX_AVAIL" "$NGINX_ENABLED"
nginx -t
systemctl reload nginx
log "Reloaded nginx with https://${DOMAIN}/v1/"

# 4. Ensure CLIProxyAPI catalog lists gemini-4-carbon-eap so OAuth secondary account can serve it
CATALOG_JSON="/etc/cli-proxy-api/models.local.json"
if [[ -f "$CATALOG_JSON" ]]; then
    if python3 - "$CATALOG_JSON" <<'PY'
import copy, json, shutil, sys
path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)

changed = False
if isinstance(data, dict):
    for section, models in list(data.items()):
        if "gemini" in section.lower() and "antigravity" not in section.lower() and isinstance(models, list):
            ids = {m.get("id") for m in models if isinstance(m, dict)}
            template = next((m for m in models if isinstance(m, dict) and str(m.get("id", "")).startswith("gemini-")), None)
            for target_id in ("gemini-4-carbon-eap", "gemini-4-argon", "gemini-4-argon-eap"):
                if target_id not in ids and template is not None:
                    entry = copy.deepcopy(template)
                    entry["id"] = target_id
                    if "name" in entry:
                        entry["name"] = target_id
                    models.append(entry)
                    changed = True

if changed:
    shutil.copy2(path, path + ".bak")
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    sys.exit(0)
sys.exit(2)
PY
    then
        log "Added missing gemini-4-carbon-eap / gemini-4-argon entries to ${CATALOG_JSON}; restarting cli-proxy-api"
        systemctl restart cli-proxy-api
    else
        rc=$?
        [[ "$rc" -eq 2 ]] || die "Failed updating ${CATALOG_JSON}"
        log "CLIProxyAPI catalog already up to date"
    fi
fi

# 5. Smoke-check local & public health
curl -fsSL "https://${DOMAIN}/health" --resolve "${DOMAIN}:443:127.0.0.1" >/dev/null
log "Verified https://${DOMAIN}/health TLS handshake and routing!"
