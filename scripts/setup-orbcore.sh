#!/usr/bin/env bash
# Provision https://orbcore.thomas.md as a direct (grey-cloud, non-Cloudflare-proxied)
# dual-stack (A + AAAA) HTTP/2 + HTTP/3 QUIC TLS endpoint for Orb Core on agent-core.
#
# Run as root on agent-core (or via `ssh agent-core 'bash -s' < scripts/setup-orbcore.sh`).
# Never prints secret values.

set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/root/.local/bin:${PATH:-}"

DOMAIN="${ORBCORE_DOMAIN:-orbcore.thomas.md}"
ZONE_NAME="${ORBCORE_ZONE:-thomas.md}"
UPSTREAM_PORT="${ORBCORE_UPSTREAM_PORT:-3000}"
FRONTEND_PORT="${ORBCORE_FRONTEND_PORT:-3001}"

log() {
    printf '[orbcore] %s\n' "$*"
}

die() {
    printf '[orbcore] ERROR: %s\n' "$*" >&2
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
    if [[ -z "$bws_token" && -r /root/.sandboxed-sh/settings.json && -r /root/.sandboxed-sh/private_key ]]; then
        bws_token="$(python3 - <<'PY' 2>/dev/null || true
import base64, json
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
key = bytes.fromhex(open("/root/.sandboxed-sh/private_key").read().strip())
enc = ((json.load(open("/root/.sandboxed-sh/settings.json")).get("bitwarden") or {}).get("encrypted_access_token") or "").strip()
if enc.startswith("<encrypted") and "</encrypted>" in enc:
    b64 = enc.split('">', 1)[1].rsplit("</encrypted>", 1)[0]
    raw = base64.b64decode(b64)
    sys_tok = AESGCM(key).decrypt(raw[:12], raw[12:], None).decode().strip()
    print(sys_tok, end="")
PY
)"
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

PUBLIC_IPV4="${ORBCORE_IPV4:-$(curl -4 -fsSL https://ifconfig.me || ip -4 route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n 1)}"
[[ -n "$PUBLIC_IPV4" ]] || die "Could not determine public IPv4 of host"
PUBLIC_IPV6="${ORBCORE_IPV6:-$(ip -6 addr show scope global 2>/dev/null | awk '/inet6/ && !/temporary/ {sub(/\/.*/, "", $2); print $2; exit}')}"
log "Target host IPv4=${PUBLIC_IPV4} IPv6=${PUBLIC_IPV6:-none} for ${DOMAIN} (DNS-only / grey cloud)"

CF_TOKEN="$(resolve_cf_token || true)"
[[ -n "$CF_TOKEN" ]] || die "CLOUDFLARE_API_TOKEN not found in env, /etc/sandboxed-sh/*.env, or Bitwarden"

ZONE_RESP="$(curl -fsSL -H "Authorization: Bearer ${CF_TOKEN}" \
    -H "Content-Type: application/json" \
    "https://api.cloudflare.com/client/v4/zones?name=${ZONE_NAME}" || true)"

ZONE_ID="$(printf '%s' "$ZONE_RESP" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d.get("success") and d.get("result")
sys.stdout.write(d["result"][0]["id"])
')" || die "Cloudflare zone lookup failed for ${ZONE_NAME}"

upsert_dns_record() {
    local rtype="$1" rname="$2" rcontent="$3"
    [[ -n "$rcontent" ]] || return 0
    local existing rec_id payload
    existing="$(curl -fsSL -H "Authorization: Bearer ${CF_TOKEN}" \
        -H "Content-Type: application/json" \
        "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records?type=${rtype}&name=${rname}")"
    rec_id="$(printf '%s' "$existing" | python3 -c '
import json, sys
res = (json.load(sys.stdin).get("result") or [])
if res:
    sys.stdout.write(res[0]["id"])
')"
    payload="$(python3 -c '
import json, sys
print(json.dumps({
    "type": sys.argv[1],
    "name": sys.argv[2],
    "content": sys.argv[3],
    "ttl": 120,
    "proxied": False,
    "comment": "Orb Core direct HTTP/3 + HTTP/2 endpoint (grey cloud, no 100s timeout)"
}))
' "$rtype" "$rname" "$rcontent")"
    if [[ -n "$rec_id" ]]; then
        log "Updating Cloudflare ${rtype} ${rname} -> ${rcontent} (proxied=false)"
        curl -fsSL -X PUT -H "Authorization: Bearer ${CF_TOKEN}" -H "Content-Type: application/json" \
            --data "$payload" "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records/${rec_id}" >/dev/null
    else
        log "Creating Cloudflare ${rtype} ${rname} -> ${rcontent} (proxied=false)"
        curl -fsSL -X POST -H "Authorization: Bearer ${CF_TOKEN}" -H "Content-Type: application/json" \
            --data "$payload" "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records" >/dev/null
    fi
}

upsert_dns_record "A" "$DOMAIN" "$PUBLIC_IPV4"
upsert_dns_record "AAAA" "$DOMAIN" "$PUBLIC_IPV6"
unset CF_TOKEN

CERT_DIR="/etc/letsencrypt/live/${DOMAIN}"
NGINX_AVAIL="/etc/nginx/sites-available/${DOMAIN}"
NGINX_ENABLED="/etc/nginx/sites-enabled/${DOMAIN}"
mkdir -p /var/www/html

if [[ ! -f "${CERT_DIR}/fullchain.pem" ]]; then
    log "Issuing ECDSA P-256 Let's Encrypt certificate for ${DOMAIN}"
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

    for _ in {1..15}; do
        resolved="$(dig +short "${DOMAIN}" @1.1.1.1 | head -n 1 || true)"
        [[ "$resolved" == "$PUBLIC_IPV4" ]] && break
        sleep 2
    done

    certbot certonly --webroot -w /var/www/html \
        -d "${DOMAIN}" \
        --key-type ecdsa --elliptic-curve secp256r1 \
        --non-interactive \
        --agree-tos \
        --register-unsafely-without-email \
        --keep-until-expiring
fi

log "Writing HTTP/2 + HTTP/3 QUIC nginx config ${NGINX_AVAIL}"
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
    listen 443 ssl;
    listen [::]:443 ssl;
    listen 443 quic;
    listen [::]:443 quic;
    http2 on;
    http3 on;
    quic_gso on;
    server_name ${DOMAIN};

    ssl_certificate     ${CERT_DIR}/fullchain.pem;
    ssl_certificate_key ${CERT_DIR}/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;
    ssl_session_cache   shared:SSL:10m;
    ssl_session_timeout 1d;

    add_header Alt-Svc 'h3=":443"; ma=86400' always;
    client_max_body_size 11G;

    location ~ ^/api/(console/ws|workspaces/[^/]+/shell|desktop/stream|monitoring/ws|control/(ws|sync))$ {
        proxy_pass http://127.0.0.1:${UPSTREAM_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
        proxy_buffering off;
    }

    location ~ ^/api/.*/(stream|events)$ {
        proxy_pass http://127.0.0.1:${UPSTREAM_PORT};
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_buffering off;
        proxy_cache off;
        chunked_transfer_encoding on;
        proxy_read_timeout 86400s;
    }

    location /v1/ {
        proxy_pass http://127.0.0.1:${UPSTREAM_PORT};
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_cache off;
        chunked_transfer_encoding on;
        proxy_connect_timeout 30s;
        proxy_send_timeout 600s;
        proxy_read_timeout 600s;
    }

    location /api/ {
        proxy_pass http://127.0.0.1:${UPSTREAM_PORT};
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_request_buffering off;
        proxy_buffering off;
    }

    location /hermes-remote/ {
        proxy_pass http://127.0.0.1:${UPSTREAM_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_cache off;
        chunked_transfer_encoding on;
        proxy_connect_timeout 30s;
        proxy_send_timeout 600s;
        proxy_read_timeout 600s;
    }

    location / {
        proxy_pass http://127.0.0.1:${FRONTEND_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

ln -sfn "$NGINX_AVAIL" "$NGINX_ENABLED"
nginx -t
systemctl reload nginx
curl --resolve "${DOMAIN}:443:${PUBLIC_IPV4}" -fsSL "https://${DOMAIN}/api/health" >/dev/null
log "Verified https://${DOMAIN}/api/health TLS + HTTP/2 + HTTP/3 Alt-Svc!"
