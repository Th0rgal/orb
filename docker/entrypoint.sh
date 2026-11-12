#!/bin/bash
set -e

# =============================================================================
# Orb Core — Docker Entrypoint
# Starts: Lean 4 Core backend (orb-core), Caddy (PID 1)
# =============================================================================

cleanup() {
    echo "[entrypoint] shutting down..."
    kill "$BACKEND_PID" 2>/dev/null || true
    wait
}
trap cleanup SIGTERM SIGINT

# -- Git / SSH setup ----------------------------------------------------------
# SSH keys may be mounted read-only from the host. Set up a writable
# known_hosts and pre-populate with GitHub/GitLab keys if needed.
if [ -d /root/.ssh ]; then
    KNOWN_HOSTS="/root/.ssh/known_hosts"
    # If the mount is read-only, use a writable location
    if ! touch "$KNOWN_HOSTS" 2>/dev/null; then
        KNOWN_HOSTS="/root/.ssh_known_hosts"
        cp /root/.ssh/known_hosts "$KNOWN_HOSTS" 2>/dev/null || true
        export GIT_SSH_COMMAND="ssh -o UserKnownHostsFile=$KNOWN_HOSTS"
    fi
    # Add common forge host keys if missing
    if ! grep -q "github.com" "$KNOWN_HOSTS" 2>/dev/null; then
        echo "[entrypoint] adding GitHub/GitLab SSH host keys"
        ssh-keyscan -t ed25519,rsa github.com gitlab.com >> "$KNOWN_HOSTS" 2>/dev/null || true
    fi
fi

# Desktop sessions are started on demand by desktop-mcp/tools as isolated
# headless Wayland compositors. The container entrypoint intentionally does not
# start a shared desktop.


# -- Start Lean 4 Core backend ------------------------------------------------
case "$(printf '%s' "${DEV_MODE:-false}" | tr '[:upper:]' '[:lower:]')" in
    1|true|t|yes|y|on)
        case "$(printf '%s' "${ALLOW_INSECURE_REMOTE_DEV_AUTH:-false}" | tr '[:upper:]' '[:lower:]')" in
            1|true|t|yes|y|on)
                echo "[entrypoint] WARNING: DEV_MODE=true with ALLOW_INSECURE_REMOTE_DEV_AUTH=true disables authentication behind Caddy :80. Ensure container port 80 is published only on 127.0.0.1." >&2
                ;;
            *)
                echo "[entrypoint] ERROR: Refusing to start container with DEV_MODE=true because Caddy listens on :80 across container interfaces. Set ALLOW_INSECURE_REMOTE_DEV_AUTH=true only when publishing port 80 strictly on 127.0.0.1." >&2
                exit 1
                ;;
        esac
        ;;
esac

echo "[entrypoint] starting orb-core backend on ${HOST:-127.0.0.1}:${PORT:-3000}"
orb-core &
BACKEND_PID=$!

# Wait for backend to become healthy before starting Caddy
echo "[entrypoint] waiting for backend health..."
for i in $(seq 1 30); do
    if ! kill -0 "$BACKEND_PID" 2>/dev/null; then
        echo "[entrypoint] ERROR: orb-core backend exited during startup (check DASHBOARD_PASSWORD / JWT_SECRET / DEV_MODE configuration)" >&2
        wait "$BACKEND_PID" || exit $?
        exit 1
    fi
    if curl -sf http://127.0.0.1:${PORT:-3000}/api/health >/dev/null 2>&1; then
        echo "[entrypoint] backend ready"
        break
    fi
    if [ "$i" -eq 30 ]; then
        echo "[entrypoint] WARNING: backend not healthy after 15s, continuing anyway"
    fi
    sleep 0.5
done

# -- Start Caddy (foreground — PID 1) ----------------------------------------
echo "[entrypoint] starting Caddy reverse proxy on :80"
exec caddy run --config /etc/caddy/Caddyfile --adapter caddyfile
