# Inbox & Summaries Settings and Token-Saving Policy

## Purpose

Users control Inbox visibility, scope, summary model, and token-saving cadence
from **Settings → Agents → Inbox & summaries** (`inbox-summaries`) across
Desktop, iOS, and Android, backed by synchronized per-user preferences in Core
(`GET/PUT /api/control/inbox-state/preferences`).

**Settings → Notifications** (`inbox-settings`) retains alert delivery toggles
(and links to **Inbox & summaries** for Inbox/model configuration). Clicking the
settings icon inside Inbox opens **Agents → Inbox & summaries** directly.

## Synchronized Preferences

`PUT /api/control/inbox-state/preferences` persists five per-user fields:

| Field | Type | Default | Meaning |
| --- | --- | --- | --- |
| `inboxEnabled` | `bool` | `true` | Master switch for the Inbox view, navigation shortcut, and unread pre-warming. |
| `includeAutonomous` | `bool` | `false` | Include sub-agents and Hermes-launched missions in Inbox and unread counts. |
| `aiSummary` | `bool` | `true` | Whether AI summaries are active (`Off` in the model picker sets `false` while preserving `model` and `summaryMode`). |
| `summaryMode` | `"standard" \| "on_open" \| "eco"` | `"standard"` | When and how eagerly Orb spends tokens on AI summaries. |
| `model` | `string` | `"builtin/smart"` | Trimmed non-empty routing chain or `provider/model` ID. |

### Backward Compatibility & Single-Owner State Rules

1. Missing fields from legacy local storage or older clients normalize to their
   defaults (`inboxEnabled: true`, `includeAutonomous: false`, `aiSummary: true`,
   `summaryMode: "standard"`, `model: "builtin/smart"`). Unrecognized
   `summaryMode` values normalize to `"standard"`.
2. Turning `aiSummary` off (`Off` in the model picker) never overwrites `model`
   or `summaryMode`.
3. Turning `inboxEnabled` off never overwrites `includeAutonomous`, `aiSummary`,
   `summaryMode`, or `model`; re-enabling Inbox restores the user's prior setup.

## Disabling Inbox (`inboxEnabled = false`)

- **Desktop (`orb/src/App.tsx`, `orb/src/TurnRecap.tsx`):**
  - Hides the `Inbox` sidebar button and unread count badge (`inboxCount = 0`).
  - Ignores the `⌘I` / `Ctrl+I` navigation shortcut.
  - Redirects an active `"inbox"` selection to `null` (New Agent).
  - Skips unread candidate computation, transcript prefetching, and background
    digest pre-warming.
  - Suppresses `TurnRecap` rendering and digest requests.
- **iOS (`OrbProjects.swift`, `OrbInbox.swift`) & Android (`OrbProjects.kt`, `OrbInbox.kt`):**
  - Hides the `Projects | Inbox` home switcher and returns home navigation to
    `Projects` if `Inbox` was selected.
  - Skips Inbox digest lookups and network requests.
- **Core (`src/api/ask/inbox.rs`):**
  - `POST /api/control/missions/:id/inbox-digest` returns `409 Conflict`
    (`"Inbox is disabled"`) before reading conversation events or calling a
    model. Core reserves `204 No Content` strictly for `aiSummary = false` so a
    disabled Inbox never flips `aiSummary` off on any client.

## Summary Modes (`summaryMode`)

All clients share the pure admission gate `shouldRequestInboxDigest` (verified
against `shared/orb-spec/fixtures/inbox-summary-policy.json`), and Core enforces
the server-side invariants on `POST /api/control/missions/:id/inbox-digest`:

1. **`"standard"` (Default):**
   - Desktop pre-warms the top unread Inbox missions in the background, requests
     end-of-turn recaps (`TurnRecap`) for settled turns, and throttles live
     streaming refreshes to `60s` (`LIVE_SUMMARY_INTERVAL_MS`).
   - Mobile summarizes settled items when Inbox is opened.
2. **`"on_open"` (When Inbox opens):**
   - Summaries are requested **only** when `surface == "inbox"` (never from
     background polling or `TurnRecap`; `TurnRecap` still displays an exact
     cached digest for free if one already exists).
   - Live/streaming missions (`isLive == true`) are skipped on clients and
     refused by Core (`409 Conflict` unless the exact revision is already cached).
3. **`"eco"` (Opinionated token-saver):**
   - Inherits all `"on_open"` restrictions (`surface == "inbox"`, `!isLive`).
   - Additionally requires **at least 1 hour (`3,600,000 ms`) of inactivity**
     since the mission's latest activity (`nowMs - updatedMs >= 3_600_000`)
     before requesting or generating a summary.
   - Conversations active within the last hour render the zero-token
     deterministic excerpt (`Latest update`) without error labels or retries.
   - Core enforces the same 1-hour quiet window on `mission.updated_at` (with a
     5-second clock-skew tolerance, `3,595s`), serving exact cache hits for free
     and returning `409 Conflict` otherwise.
