# Mission API

All endpoints require authentication via `Authorization: Bearer <token>` header.

## Create a Mission

```
POST /api/control/missions
```

**Body** (all optional):
```json
{
  "title": "My Mission",
  "workspace_id": "uuid",
  "agent": "code-reviewer",
  "model_override": "anthropic/claude-sonnet-4-20250514",
  "backend": "opencode"
}
```

`backend` can be `"opencode"`, `"claudecode"`, `"codex"`, `"antigravity"`, or
`"grok"`. If omitted, the server uses `DEFAULT_BACKEND` or the first detected
CLI in priority order: Claude Code, OpenCode, Grok, Codex, then Antigravity.

**Response**: `Mission` object (see below).

## Load/Switch to a Mission

```
POST /api/control/missions/:id/load
```

Loads the mission into the active control session. Required before sending messages.

## Send a Message

```
POST /api/control/message
```

**Body**:
```json
{
  "content": "Your message here",
  "agent": "optional-agent-override",
  "client_message_id": "optional-uuid-for-idempotent-retries"
}
```

**Response**:
```json
{
  "id": "uuid",
  "queued": false
}
```

`queued: true` means another message is being processed.

`client_message_id` is optional but recommended for slow or unreliable networks.
When supplied, the backend uses it as the user-message id and ignores duplicate
retries with the same id.

## Cancel Current Execution

```
POST /api/control/cancel
```

Cancels the currently running agent task.

## Cancel a Specific Mission

```
POST /api/control/missions/:id/cancel
```

## Set Mission Status

```
POST /api/control/missions/:id/status
```

**Body**:
```json
{
  "status": "completed"
}
```

Statuses: `pending`, `active`, `completed`, `failed`, `interrupted`.

## Get Mission Events (History)

```
GET /api/control/missions/:id/events?view=history&limit=100&before_seq=1234
```

**Query params** (all optional):
- `types`: comma-separated event types to filter
- `view`: typed preset, one of `transcript`, `trace`, `history`, or `all`
- `limit`: max events to return
- `since_seq`: return events after a stored sequence number
- `before_seq`: return events before a stored sequence number

The response includes `X-Total-Events` and `X-Max-Sequence` headers when event
sequence metadata is available.

**Response**: Array of `StoredEvent` ordered by sequence:
```json
[
  {
    "id": 1,
    "mission_id": "uuid",
    "sequence": 1,
    "event_type": "user_message",
    "timestamp": "2025-01-13T10:00:00Z",
    "content": "...",
    "metadata": {}
  }
]
```

## Snapshot-First Mission Loading

Use this endpoint for initial mission paint:

```
GET /api/control/missions/:id/snapshot
```

It returns mission metadata, the latest history events, event counts, child
mission summary, and running state in one payload. Clients should use this for
first paint, then use `/events` for pagination and delta catch-up.

Event visibility categories:
- `history`: transcript-visible messages plus thinking/tool/text operation rows
- `transcript`: `user_message`, `assistant_message`, canonical assistant rows
- `trace`: `thinking`, `tool_call`, `tool_result`, `text_delta`, `text_op`, errors, command/runtime status
- `debug`: diagnostics and backend protocol noise

**Response**:
```json
{
  "mission": { "id": "uuid", "status": "active" },
  "events": [
    {
      "id": 1,
      "mission_id": "uuid",
      "sequence": 1,
      "event_type": "user_message",
      "content": "Question"
    }
  ],
  "event_counts": { "user_message": 1, "assistant_message": 1, "thinking": 4 },
  "visibility_counts": { "history": 6 },
  "total_events": 6,
  "latest_sequence": 12,
  "child_missions": [],
  "running": null
}
```

Fetch history and pagination with:

```
GET /api/control/missions/:id/events?view=history&since_seq=0&limit=200
```

`/events` supports `view=transcript|trace|history|all`, explicit `types`,
`limit`, `since_seq`, and `before_seq`, and includes
`X-Total-Events` / `X-Max-Sequence` headers.

## Stream Events (SSE)

```
GET /api/control/stream
```

Server-Sent Events stream for real-time updates. Events have `event:` and `data:` fields.

**Event types**:
- `status` — control state changed (`idle`, `running`, `waiting_for_tool`)
- `user_message` — user message received
- `assistant_message` — agent response complete
- `thinking` — agent reasoning (streaming)
- `tool_call` — tool invocation
- `tool_result` — tool result
- `error` — error occurred
- `mission_status_changed` — mission status updated

**Example SSE event**:
```
event: assistant_message
data: {"id":"uuid","content":"Done!","success":true,"cost_cents":5,"model":"claude-sonnet-4-20250514"}
```

## Other Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/api/control/missions` | GET | List missions |
| `/api/control/missions/:id` | GET | Get mission details |
| `/api/control/missions/:id` | DELETE | Delete mission |
| `/api/control/missions/:id/snapshot` | GET | Get first-paint mission payload |
| `/api/control/missions/:id/events` | GET | Get historical mission events and pagination |
| `/api/control/missions/:id/tree` | GET | Get agent tree for mission |
| `/api/control/missions/current` | GET | Get current active mission |
| `/api/control/missions/:id/resume` | POST | Resume interrupted mission |
| `/api/control/progress` | GET | Get execution progress |

## Automations

Automations trigger commands based on intervals, webhooks, or agent events.

### List Mission Automations

```
GET /api/control/missions/:id/automations
```

**Response**: Array of `Automation` objects.

### List All Active Automations

```
GET /api/control/automations
```

**Response**: Array of `Automation` objects across all missions.

### Create an Automation

```
POST /api/control/missions/:id/automations
```

**Body**:
```json
{
  "command_source": {"type": "library", "name": "my-command"},
  "trigger": {"type": "interval", "seconds": 300},
  "variables": {"key": "value"},
  "retry_config": {
    "max_retries": 3,
    "retry_delay_seconds": 60,
    "backoff_multiplier": 2.0
  },
  "start_immediately": false
}
```

Both `command_source` and `trigger` are internally tagged: a `"type"`
discriminator selects the variant and its fields sit alongside it.

**Trigger types**:
- `{"type": "interval", "seconds": 300}` — Run every N seconds
- `{"type": "cron", "expression": "0 8 * * *", "timezone": "Europe/Paris"}` — Cron schedule (timezone defaults to UTC)
- `{"type": "webhook", "config": {"webhook_id": "optional-uuid"}}` — Trigger via webhook
- `{"type": "agent_finished"}` — Trigger after each agent turn completes

**Command sources**:
- `{"type": "library", "name": "command-name"}` — Use a library command
- `{"type": "local_file", "path": "scripts/run.sh"}` — Command from a file in the mission workspace
- `{"type": "inline", "content": "echo hello"}` — Inline shell command

**Response**: `Automation` object.

### Get Automation

```
GET /api/control/automations/:id
```

**Response**: `Automation` object.

### Update Automation

```
PATCH /api/control/automations/:id
```

**Body** (all fields optional):
```json
{
  "command_source": {"type": "library", "name": "new-command"},
  "trigger": {"type": "interval", "seconds": 600},
  "variables": {"key": "new-value"},
  "retry_config": {"max_retries": 5},
  "active": false
}
```

**Response**: Updated `Automation` object.

### Delete Automation

```
DELETE /api/control/automations/:id
```

**Response**: `204 No Content` on success.

### Get Automation Executions

```
GET /api/control/automations/:id/executions
```

**Response**: Array of `AutomationExecution` objects.

### Get Mission Automation Executions

```
GET /api/control/missions/:id/automation-executions
```

**Response**: Array of `AutomationExecution` objects for all automations on a mission.

## Automation Object

```json
{
  "id": "uuid",
  "mission_id": "uuid",
  "command_source": {"type": "library", "name": "my-command"},
  "trigger": {"type": "interval", "seconds": 300},
  "variables": {"key": "value"},
  "active": true,
  "created_at": "2025-01-13T10:00:00Z",
  "last_triggered_at": "2025-01-13T10:05:00Z",
  "retry_config": {
    "max_retries": 3,
    "retry_delay_seconds": 60,
    "backoff_multiplier": 2.0
  }
}
```

## AutomationExecution Object

```json
{
  "id": "uuid",
  "automation_id": "uuid",
  "mission_id": "uuid",
  "triggered_at": "2025-01-13T10:05:00Z",
  "trigger_source": "interval",
  "status": "success",
  "webhook_payload": null,
  "variables_used": {"key": "value"},
  "completed_at": "2025-01-13T10:05:05Z",
  "error": null,
  "retry_count": 0
}
```

**Execution statuses**: `pending`, `running`, `success`, `failed`, `cancelled`, `skipped`.

## Mission Object

```json
{
  "id": "uuid",
  "status": "active",
  "title": "My Mission",
  "workspace_id": "uuid",
  "workspace_name": "my-workspace",
  "agent": "code-reviewer",
  "model_override": null,
  "backend": "opencode",
  "history": [],
  "created_at": "2025-01-13T10:00:00Z",
  "updated_at": "2025-01-13T10:05:00Z"
}
```
