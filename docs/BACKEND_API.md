# Backend API

All endpoints require authentication via `Authorization: Bearer <token>` header.

## List Backends

```
GET /api/backends
```

**Response**:
```json
[
  {"id": "opencode", "name": "OpenCode"},
  {"id": "claudecode", "name": "Claude Code"},
  {"id": "codex", "name": "Codex"},
  {"id": "antigravity", "name": "Antigravity CLI"},
  {"id": "grok", "name": "Grok Build"}
]
```

## Get Backend

```
GET /api/backends/:id
```

**Response**:
```json
{"id": "opencode", "name": "OpenCode"}
```

## List Backend Agents

```
GET /api/backends/:id/agents
```

**Response**:
```json
[{"id": "build", "name": "build"}, {"id": "plan", "name": "plan"}]
```

## Get Backend Config

```
GET /api/backends/:id/config
```

**Response**:
```json
{
  "id": "opencode",
  "name": "OpenCode",
  "enabled": true,
  "settings": {
    "base_url": "http://127.0.0.1:4096",
    "default_agent": "build",
    "permissive": true
  }
}
```

For `claudecode`, `settings` includes `api_key_configured` and optional fields
like `default_model`. Grok and Antigravity settings include an optional `cli_path`
to select their native CLI binary. Antigravity uses this override for both model
discovery and mission execution; the path must exist in the target execution
environment.

## Update Backend Config

```
PUT /api/backends/:id/config
```

**Body**:
```json
{
  "enabled": true,
  "settings": {
    "base_url": "http://127.0.0.1:4096",
    "default_agent": "build",
    "permissive": true
  }
}
```

Claude Code accepts `api_key` in `settings` to store it securely in the secrets
vault. Grok and Antigravity accept `cli_path` to override the CLI binary path
(for example, `{"cli_path": "/opt/antigravity/bin/agy"}` for Antigravity).

**Response**:
```json
{
  "ok": true,
  "message": "Backend configuration updated."
}
```
