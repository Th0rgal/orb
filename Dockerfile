# =============================================================================
# sandboxed.sh — All-in-One Docker Image
# =============================================================================
# Multi-stage build: Pure Lean 4 Core backend + runtime with AI CLIs
# Formerly known as "Open Agent"
#
# Build:   docker build -t sandboxed-sh .
# Run:     docker compose up
# =============================================================================

# ---------------------------------------------------------------------------
# Stage 1: Lean 4 builder (zero Rust / Cargo)
# ---------------------------------------------------------------------------
FROM debian:bookworm-slim AS lean-builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential git libssl-dev libsqlite3-dev zstd ca-certificates curl \
    && rm -rf /var/lib/apt/lists/* \
    && LEAN_ARCHIVE="/tmp/lean-4.35.0-linux.tar.zst" \
    && LEAN_SHA256="7289597a44543246c9227b8cae501767e095ce17f6d448b95fc4a8dc97268f6d" \
    && curl --retry 5 --retry-all-errors -fsSL \
       "https://github.com/leanprover/lean4/releases/download/v4.35.0/lean-4.35.0-linux.tar.zst" \
       -o "$LEAN_ARCHIVE" \
    && echo "${LEAN_SHA256}  ${LEAN_ARCHIVE}" | sha256sum -c - \
    && mkdir -p /opt/lean-4.35.0 \
    && tar --zstd -xf "$LEAN_ARCHIVE" --strip-components=1 -C /opt/lean-4.35.0 \
    && rm -f "$LEAN_ARCHIVE"
ENV PATH="/opt/lean-4.35.0/bin:${PATH}"

WORKDIR /build

COPY lean/ lean/
COPY shared/ shared/
COPY catalog/ catalog/
COPY scripts/ scripts/

ARG LEAN_BINARIES="sandboxed-sh desktop-mcp workspace-mcp automation-manager-mcp sandboxed-mcp"
RUN mkdir -p /out \
    && ./scripts/build_orb_bins.sh --out-dir /out $(printf -- '--only %s ' $LEAN_BINARIES)

# ---------------------------------------------------------------------------
# Stage 2: Runtime (Ubuntu 24.04 for native debootstrap support)
# ---------------------------------------------------------------------------
FROM ubuntu:24.04 AS runtime

ENV DEBIAN_FRONTEND=noninteractive

# -- Core system deps --------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
    git curl jq sqlite3 libsqlite3-0 libssl3t64 zstd unzip openssh-client ca-certificates gnupg python3 python3-yaml caddy \
    # nspawn / container workspaces
    systemd-container debootstrap \
    # Wayland app streaming and automation
    sway grim wtype wlrctl wf-recorder wayvnc cage imagemagick \
    tesseract-ocr at-spi2-core \
    fonts-liberation fonts-dejavu fonts-noto \
    # Chromium
    chromium-browser \
    && rm -rf /var/lib/apt/lists/* \
    # Add plucky (25.04) script for future Ubuntu releases
    && ln -sf gutsy /usr/share/debootstrap/scripts/plucky

# -- Node.js 20 (for Claude Code CLI & MCP servers) ----------------------------
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# -- Bun (preferred package manager for global installs + bunx) ---------------
RUN curl -fsSL https://bun.sh/install | bash \
    && install -m 0755 /root/.bun/bin/bun /usr/local/bin/bun \
    && install -m 0755 /root/.bun/bin/bunx /usr/local/bin/bunx

# Caddy uses Ubuntu's signed security/update archives. The separate Cloudsmith
# index is signed by an expired key; signature verification must stay enabled.

# -- Copy native Lean 4 binaries from builder --------------------------------
COPY --from=lean-builder /out/ /usr/local/bin/

# -- Pre-install AI harness CLIs (optional — agents still work if these fail) -
# Uses bun for global installs (faster than npm, and our preferred package manager)
ENV PATH="/root/.bun/bin:/root/.cache/.bun/bin:${PATH}"
RUN bun install -g @anthropic-ai/claude-code@latest \
    && echo "[docker] Claude Code CLI installed: $(claude --version 2>/dev/null || echo 'unknown')" \
    || echo "[docker] WARNING: Claude Code CLI install failed (will be installed on first mission)"
RUN curl -fsSL https://opencode.ai/install | bash -s -- --no-modify-path \
    && install -m 0755 /root/.opencode/bin/opencode /usr/local/bin/opencode \
    && echo "[docker] OpenCode CLI installed: $(opencode --version 2>/dev/null || echo 'unknown')" \
    || echo "[docker] WARNING: OpenCode CLI install failed (will be installed on first mission)"
RUN curl -fsSL https://x.ai/cli/install.sh | GROK_BIN_DIR=/usr/local/bin bash \
    && echo "[docker] Grok Build CLI installed: $(grok --version 2>/dev/null || echo 'unknown')" \
    || echo "[docker] WARNING: Grok Build CLI install failed (will be installed on first mission)"
# Isolate Python dependencies from the system interpreter. This version is
# exercised by the native ACP session/tool/resume contract tests.
RUN apt-get update && apt-get install -y --no-install-recommends python3-venv \
    && rm -rf /var/lib/apt/lists/* \
    && python3 -m venv /opt/mistral-vibe \
    && /opt/mistral-vibe/bin/pip install --no-cache-dir mistral-vibe==2.19.1 \
    && ln -s /opt/mistral-vibe/bin/vibe /usr/local/bin/vibe \
    && ln -s /opt/mistral-vibe/bin/vibe-acp /usr/local/bin/vibe-acp

# -- Caddy config + entrypoint -----------------------------------------------
COPY docker/Caddyfile /etc/caddy/Caddyfile
RUN caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
COPY docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# -- Working directories ------------------------------------------------------
RUN mkdir -p /root/.sandboxed-sh /root/.claude /root/work/screenshots

# -- Environment defaults -----------------------------------------------------
ENV HOST=127.0.0.1 \
    PORT=3000 \
    WORKING_DIR=/root \
    DEV_MODE=false \
    DESKTOP_ENABLED=true \
    DESKTOP_RESOLUTION=1920x1080 \
    GIT_TERMINAL_PROMPT=0

EXPOSE 80
VOLUME ["/root/.sandboxed-sh", "/root/.claude"]

ENTRYPOINT ["/entrypoint.sh"]
