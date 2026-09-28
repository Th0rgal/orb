# Paloma Telegram Roadmap

Long-term roadmap for making Paloma a quiet Telegram operations aide for
Sandboxed.sh.

The goal is not to build a second dashboard in chat. Telegram should be the
smallest useful surface for awareness, steering, and timely answers while the
dashboard remains the full control plane.

## Product North Star

Paloma should feel like a trusted operations aide:

- She tells Thomas what changed since he last checked.
- She alerts Thomas only when something matters.
- She lets Thomas steer long-running agents from Telegram.
- She can answer or help Benjamin in shared chats, but never expose secrets or
  grant mission control to anyone except Thomas.
- She learns notification preferences from direct feedback and from implicit
  signals (what Thomas replies to vs. ignores).
- She handles useful media without turning Telegram into a noisy file dump.

## User Model

### Thomas

Owner. Full control from DM only.

Thomas can:

- Check status across missions.
- See what changed since his last Telegram or dashboard session.
- Steer existing missions.
- Start small worker missions.
- Answer agent questions from Telegram.
- Receive proactive alerts.
- Teach Paloma alert preferences (explicitly via commands, implicitly via
  reply/ignore behaviour).

### Benjamin

Trusted friend/helper. Limited interaction in shared chats.

Benjamin can:

- Ask high-level questions in allowed shared chats.
- Receive safe summaries when Paloma decides it is useful.
- Trigger helpful context from Paloma when the answer saves Thomas time.

Benjamin cannot:

- DM Paloma to control Thomas's missions.
- Start, stop, steer, or inspect private missions.
- Access secrets, raw logs, private prompts, file paths, credentials, or
  sensitive workspace details.

### Everyone Else

Ignored by default unless explicitly allowed.

## Architectural Principles

Three principles drive the design:

1. **Telegram is a chat, not a notification stream.** The unit of
   communication is a conversation per mission, not an alert per event. Each
   active mission gets one persistent, in-place-updated message — a card — that
   reflects current state.
2. **Interrupts are earned, not default.** A new message that pings the user is
   a budgeted resource. Most events update the mission card silently or roll
   into a digest. Only deliberately-classified-as-important events page the
   user.
3. **Decisions are auditable.** Every send / suppress / downgrade is logged
   with rationale, so Thomas can see why Paloma stayed quiet — or why she
   didn't.

## Communication Channels

Every mission event flows through a pipeline that picks exactly one channel:

| Channel        | Vehicle                              | Latency | User cost                  |
| -------------- | ------------------------------------ | ------- | -------------------------- |
| Mission Card   | edit pinned per-mission message      | seconds | none — ambient             |
| Interrupt      | new message, notification on         | seconds | high — interrupts the user |
| Digest         | one composed message per cadence     | hours   | low — read on demand       |
| Silent log     | DB only                              | —       | none                       |

## Components

### 1. MissionCard service

One Telegram message per active mission, edited in place via `editMessageText`.

Responsibilities:

- Maintain `(mission_id) → (chat_id, message_id, content_hash, anchor_ts)`.
- Render mission status (emoji, title, current step, last assistant message
  truncated to a few lines).
- Inline buttons: Reply, Open in dashboard, Mute mission, Acknowledge.
- Re-render on displayable events; only call `editMessageText` when the content
  hash changes.
- Debounce edits at ~2 seconds per mission to respect Telegram's ~1 edit/sec
  per-chat rate limit.
- 48-hour re-anchor: when the anchor message exceeds Telegram's edit window,
  post a fresh card and quote-reply the old one. Once per 48 hours max.
- Auto-archive on mission completion (stops updating; final status emoji
  shown).

### 2. Significance classifier

Decides the channel for each incoming event.

Pipeline:

1. **Hard rules** (deterministic, no LLM):
   - `MissionFailed`, `MissionFinished`, `AwaitingUser` → interrupt candidate.
   - `AssistantMessage`, `ToolCall`, `StatusChanged` while Active → card
     update.
   - Heartbeats, low-level tool events → silent.
2. **Cooldown / budget check**: interrupt candidates must clear per-mission and
   per-class cooldown.
3. **LLM gate** (only for candidates that survive cooldown): a small model
   (Haiku) gets recent interaction history and user prefs and returns
   `{decision, rationale}` where decision ∈ `{send, downgrade_to_card,
   downgrade_to_digest}`.

The LLM call is bounded by the cooldown — at most a handful per hour total
across all missions.

### 3. Delivery policy

Sits between "we want to send" and "actually call Telegram".

- **Quiet hours**: default 23:00–08:00 user-local. Interrupts queue for the
  next morning. Events flagged `severity=critical` (e.g. production deploy
  failure) can override.
- **Per-user rate ceiling**: default 1 interrupt/hour, 4/day for non-critical.
  Excess → digest.
- **Per-mission backoff**: 0m → 30m → 2h → 8h → 24h. Resets on (a) user reply
  to that mission, (b) status change, (c) explicit `/resume`.
- **Cross-mission dedup**: collapse multiple awaiting-input alerts within a
  short window into one combined interrupt.

### 4. Digest composer

Runs at the end of quiet hours and on `/digest`. Composes a single message from
queued alerts via an LLM that knows what was sent recently, current mission
states, and user prefs.

Output is a short summary with clickable per-mission deep links, not a list of
individual alerts.

### 5. Conversational memory

Per-user rolling store: last ~50 alerts with `{mission_id, class,
content_summary, sent_at, user_replied, user_reacted}` plus an inferred
preference summary.

Exposed to the LLM gate as context. Enables implicit learning: if Thomas
ignores a class of alerts, the classifier downgrades them automatically without
any configuration.

### 6. Owner control plane

Two surfaces sharing one `paloma_user_preferences` table:

- **Telegram commands**: `/quiet 22-08`, `/mute mission <id>`, `/only
  failures`, `/digest now`.
- **Dashboard panel**: same settings plus visualization of alert history with
  rationale ("why did/didn't you send this?").

Paloma also surfaces preference suggestions proactively, e.g. after a noisy
night: "I sent 11 alerts overnight and you replied to none. Mute overnight by
default? [Yes / Only failures / No]". This converts annoyance into a permanent
fix.

## Decision Pipeline

```text
event
  -> MissionCard.render_if_changed()              [always; ambient]
  -> SignificanceClassifier.classify(event)
       hard rules -> {silent | card_only | interrupt_candidate | digest_candidate}
  -> if interrupt_candidate:
       Cooldown.check()      -> fail -> digest
       Budget.check()        -> fail -> digest
       QuietHours.check()    -> fail -> digest (unless critical)
       LLM.gate(event, history, prefs) -> {send | card_only | digest}
  -> if send: Telegram.send_interrupt() + alert_history.record(decision, rationale)
  -> if digest: enqueue
```

All decisions write to `paloma_alert_history` with rationale.

## Existing Telegram plumbing

Webhook and command intake stay as today:

```text
Telegram webhook
  -> /api/telegram/webhook/:channel_id
  -> TelegramBridge
  -> ControlCommand::UserMessage
  -> mission runner
  -> AgentEvent stream
```

The new pipeline replaces the path from `AgentEvent stream` onward. The
current `paloma::planner` + `paloma::policy` per-event alert path is removed
once the new pipeline is in production.

## Data Model

New tables:

### `paloma_mission_card`

- `mission_id` PK
- `chat_id`
- `message_id`
- `content_hash`
- `anchor_ts`
- `last_edit_ts`
- `version`

### `paloma_cooldown_state`

- `(mission_id, class)` PK
- `last_sent_at`
- `next_eligible_at`
- `backoff_step`

### `paloma_user_preferences`

- `telegram_user_id` PK
- `timezone`
- `quiet_hours_start`
- `quiet_hours_end`
- `max_interrupts_per_hour`
- `max_interrupts_per_day`
- `alert_class_overrides` JSON  -- per-class on/off/digest-only
- `mission_overrides` JSON      -- per-mission mute / pin
- `digest_cadence`
- `failure_override_quiet` BOOL

### `paloma_alert_history`

- `id` PK
- `telegram_user_id`
- `mission_id`
- `class`
- `channel`  -- card | interrupt | digest | silent
- `content_summary`
- `sent_at`
- `user_replied_at`
- `user_reacted`
- `suppressed_reason`
- `classifier_decision`
- `classifier_rationale`

### `paloma_conversation_memory`

- `telegram_user_id` PK
- `recent_alerts_json`        -- rolling ~50
- `inferred_preferences_summary`
- `updated_at`

Existing tables retained:

- `telegram_users` (roles)
- `telegram_user_cursors` (for `/status` delta)
- `telegram_mission_subscriptions` (interest, used as input to the classifier)
- `telegram_agent_questions` (input-needed routing)

Removed:

- `event_kind` bucket-ID hack in `planner.rs` (cadence moves to
  `paloma_cooldown_state`).
- Ad-hoc 30-minute bucketing in `policy.rs`.

## Delivery Rules

### Owner DM

Allowed:

- Full mission control.
- Status summaries.
- Steering.
- Agent questions.
- Worker creation.
- Media and files.

Protected:

- Secrets redacted by default.
- Dangerous actions may be gated later; first version focuses on answering
  agent questions rather than broad approval workflows.

### Shared Chats

Allowed only when:

- Thomas or Benjamin is in the chat.
- The chat is allowlisted.
- The message is directly relevant.
- The answer is safe after redaction.
- Paloma's intervention is likely to save time.

Paloma should usually stay silent.

### Friend-Safe Output

Shared-chat answers must pass a safety filter before sending.

Default deny:

- Secrets and tokens.
- Raw logs.
- Private prompts or instructions.
- File paths.
- Credentials.
- Full mission transcripts.
- Sensitive personal data.
- Unreviewed external links or generated files.

Default allow:

- High-level project status.
- Publicly safe summaries.
- Non-sensitive calendar availability if Thomas explicitly enables it.
- Helpful answers that save Thomas time.

## Minimal Command Set

Keep the command surface intentionally small:

| Command       | Purpose                                                  |
| ------------- | -------------------------------------------------------- |
| `/status`     | Delta summary since Thomas last checked.                 |
| `/missions`   | Compact list of active/interested missions.              |
| `/summary`    | Succinct summary of one mission or the current situation.|
| `/send`       | Send a steering message to a mission or selected agent.  |
| `/approve`    | Answer agent questions/options from Telegram.            |
| `/quiet`      | Set or clear quiet hours.                                |
| `/mute`       | Mute a mission or alert class.                           |
| `/digest`     | Force the digest now.                                    |

Natural replies to Paloma alerts and inline-button taps on mission cards
should work whenever possible, so commands are fallbacks rather than the main
UX.

## Status / Missions / Summary UX

`/status` returns a delta summary, e.g.:

```text
3 meaningful changes since you last checked.

1. Verity proof mission unblocked after the worker found the missing invariant.
2. PR #1914 is waiting for your answer about scope.
3. Keel UI worker failed screenshot validation twice; likely CSS overflow.
```

`/missions` is compact:

```text
Active missions

High interest
- Verity proof layer: running, last progress 18m ago
- Keel OS MVP: awaiting user

Other
- 4 workers running
- 2 completed since last status
```

`/summary` picks a sensible target (reply context > selected mission >
high-interest active). Default length is terse.

## Steering / Approval UX

`/send` supports natural targets:

```text
/send latest focus on tests and report only blockers
/send verity spawn a small worker to inspect docs
```

Natural replies to alerts and mission cards are preferred:

```text
Focus it on tests first.
Stop this mission.
```

Paloma confirms the target only when ambiguous.

`/approve` is the fallback for answering agent questions. The primary surface
is the mission card's inline buttons or a natural reply.

## Media Roadmap

### Phase A

- Forward mission `shared_files` to Telegram.
- Send images as photos when safe.
- Send reports and non-image files as documents.
- Include captions with origin mission and short context.

### Phase B

- Treat inbound Telegram files as mission attachments, not just temp paths.
- Persist attachment metadata.
- Show attachments in dashboard mission history.
- Add OCR for images and screenshots.
- Add transcription for voice notes.

### Phase C

- Generate compact status cards as images.
- Send graph/image summaries for complex mission states.
- Support media bundles when a mission produces multiple artifacts.

Voice is lowest priority.

## Safety Rules

Hard requirements:

- Only Thomas can control missions.
- Benjamin can interact only in allowlisted shared chats.
- No one except Thomas can DM-control Paloma.
- Redact secrets before Telegram delivery.
- Do not send raw logs to shared chats.
- Do not expose private prompts, internal instructions, or file paths to
  friends.
- Treat generated files as private unless explicitly shared.

Future approval gates can cover deploy, push, merge, external messages,
spending money, and sharing files. The first version should not overbuild
approvals.

## Implementation Phases

Each phase is shippable independently. Phase 1 + Phase 2 together fix the
overnight-spam class of bugs even without any LLM involvement.

### Phase 1 — MissionCard service

Build the rolling per-mission message. Keep the old alert path running in
parallel; each event updates both the card and the existing alert pipeline.
Validate the card UX with a few real missions.

Definition of Done:

- [x] `paloma_mission_card` table created and migrated.
- [x] New mission → card posted to owner DM; `message_id` persisted.
- [x] Mission events update the card via `editMessageText` only when content
      hash changes (`mission_card::content_hash`).
- [x] Edits debounced at ~2 seconds per mission. The card-refresh job runs on
      the existing scheduler tick (`TELEGRAM_SCHEDULE_POLL_INTERVAL = 2s`); the
      hash-skip path means a flood of mission events collapses to at most one
      `editMessageText` per tick per changed mission.
- [partial] Card includes inline buttons. `CardButton` enum and `buttons_for`
      defined for all four labels. **Open in dashboard** is wired as a real
      URL button (works today when `SANDBOXED_PUBLIC_URL` is set, no callback
      handler needed). **Reply / Mute mission / Acknowledge** require
      `callback_query` webhook routing, which lands in Phase 5 (owner control
      plane) — deferred deliberately to keep Phase 1 scoped to the rolling
      message itself.
- [x] 48-hour re-anchor implemented. When `anchor_ts` is ≥47h old, the next
      refresh posts a fresh card and the row's `message_id` is replaced.
      Reply-quoting the old anchor is a UX nice-to-have left for follow-up;
      it's not required for correctness.
- [x] Finished missions auto-archive: terminal status renders `card.archived =
      true`, which the bridge persists via `archive_paloma_mission_card`. The
      next tick skips archived rows entirely.
- [x] Backfill: active missions at deploy time get a card on their next event
      (the scheduler scans missions every tick and posts a card when none
      exists, skipping missions that are already terminal at first sight).
- [blocked] Manual verification: a long-running mission shows one card that
      updates, not multiple messages. **Blocked** on live Telegram credentials
      (`TELEGRAM_API_ID`, `TELEGRAM_API_HASH`, `TELEGRAM_PHONE`,
      `TELEGRAM_CHAT`) not present in this environment.

### Phase 2 — Cooldown, preferences, quiet hours

Per-mission cooldown table, exponential backoff, quiet hours. Drop the
30-minute bucket hack from `event_kind`. At end of phase the spam is fixed.

Definition of Done:

- [x] `paloma_cooldown_state` and `paloma_user_preferences` tables created
      (additions in `mission_store/sqlite.rs`).
- [x] Bucket-ID removed from `event_kind`; cooldown owns cadence
      (`planner::alert_event_kind_at` collapses `mission_long_running` to a
      single key).
- [x] Exponential backoff (0m → 30m → 2h → 8h → 24h) implemented
      (`paloma::cooldown::BACKOFF_LADDER`) and reset on user reply / status
      change. Reset is triggered at the existing alert-acknowledgement sites
      and, more importantly, directly inside
      `SqliteMissionStore::update_mission_status_with_reason` so any status
      transition automatically wipes cooldown rows for that mission.
- [x] Per-user quiet hours respected; non-critical interrupts queue; criticals
      override (`paloma::preferences::is_quiet_hours` +
      `critical_overrides_quiet`, integrated in `flush_pending_paloma_digest`
      via `paloma_preference_suppression_reason`).
- [x] Per-user rate ceiling enforced. Defaults: 1/hour, 4/day for non-critical
      (`PalomaUserPreferences::default_for`); failure-class alerts can
      override when `failure_override_quiet` is set.
- [x] Per-mission dedup in the digest collapses multiple pending alerts for
      the same mission into one entry (`digest::dedupe_by_mission`), fixing
      the "2 mission updates: same mission listed twice" pattern. Full
      cross-mission `awaiting_user` collapse into a single composed
      interrupt is a Phase 6 concern (LLM-composed digest).
- [x] Verified against a simulated overnight run: ≤4 alerts per mission for a
      single long-running mission over a 7.5h window, vs. the ~14 the old
      bucket approach produced
      (`cooldown::tests::simulated_overnight_run_produces_only_a_handful_of_alerts`).

#### Phase 1+2 verification log

- Unit tests added in this phase: `paloma::mission_card` (10 tests),
  `paloma::cooldown` (6 tests), `paloma::preferences` (10 tests),
  `paloma::digest` (4 dedup tests).
- SQLite roundtrip tests added: card upsert/touch/archive, cooldown
  upsert/reset, preferences upsert + sent-count window, cooldown reset on
  mission status change.
- Full library test suite: 869 passing, 0 failing, 2 ignored (unchanged).
- `cargo fmt --all --check` clean.
- Live Telegram smoke (`scripts/telegram_user_smoke.py`): **not run** —
  requires `TELEGRAM_API_ID` / `TELEGRAM_API_HASH` / `TELEGRAM_PHONE` /
  `TELEGRAM_CHAT` credentials that aren't present in this environment.

### Phase 3 — Significance classifier (rules) + audit log

Replace ad-hoc checks in `policy.rs` / `planner.rs` with the explicit pipeline.
Add `paloma_alert_history` and the dashboard view of rationale.

Definition of Done:

- [ ] `paloma_alert_history` records every event with channel + rationale +
      suppressed_reason.
- [ ] Hard-rule classifier replaces the existing alert decision code; old
      `planner.rs` per-event alert path removed.
- [ ] Dashboard panel lists last 100 alert decisions with mission filter and
      rationale.
- [ ] Unit tests cover each hard rule and cooldown edge case.
- [ ] No regressions: every alert previously sent for a known mission set is
      still produced (verified against a staging replay).

### Phase 4 — LLM gate + conversational memory

Wire the LLM gate for interrupt candidates that pass cooldown. Build the
conversational memory store.

Definition of Done:

- [ ] `paloma_conversation_memory` rolls last ~50 alerts per user.
- [ ] `brain.rs` calls Haiku for interrupt candidates with prefs + memory in
      the prompt; uses prompt caching for the system prompt.
- [ ] LLM returns `{decision, rationale}`; rationale persisted to
      `alert_history`.
- [ ] Fallback on LLM failure: send (safe default), log failure.
- [ ] LLM call rate observed ≤ 20/hour across all missions in production.
- [ ] Verified: an ignored alert class gets downgraded by the LLM within 3
      consecutive ignores.

### Phase 5 — Owner control plane

Telegram commands and dashboard preferences UI. Proactive suggestions.

Definition of Done:

- [ ] `/quiet`, `/mute mission`, `/only failures`, `/digest now` implemented
      and persist to `paloma_user_preferences`.
- [ ] Dashboard panel exposes `paloma_user_preferences` with edit controls.
- [ ] Dashboard alert-history view is filterable by mission and channel.
- [ ] Proactive preference suggestion sent once when ignore-rate exceeds
      threshold (e.g. ≥5 unanswered interrupts in 24h).
- [ ] Verified: Thomas can change quiet hours via Telegram and the next
      overnight respects them.

### Phase 6 — Digest composer rewrite

Replace the current per-alert digest with an LLM-composed summary.

Definition of Done:

- [ ] Digest composer takes queued alerts + active missions + recent activity
      → single composed message via Haiku.
- [ ] Digest runs at end of quiet hours and on `/digest`.
- [ ] Digest contains clickable per-mission deep links to the dashboard.
- [ ] Verified: a night with 10 queued alerts produces one digest message, not
      10.

## Testing Strategy

Three test layers.

### Unit tests

Cover:

- Hard-rule classifier branches.
- Cooldown / backoff math.
- Quiet-hours timezone handling.
- Card content-hash change detection.
- Redaction.
- Preference feedback parsing.
- Delta summary cursor logic.

### Local / backend integration tests

Cover:

- SQLite migrations for the new tables.
- Card render → edit debounce → Telegram call boundary.
- Cooldown table state transitions across simulated event streams.
- Cross-mission interrupt dedup.
- LLM gate with a stubbed model (decision + rationale persisted).
- Webhook update dedup.
- Agent question routing.

### Live Telegram smoke tests

Use `scripts/telegram_user_smoke.py` with a real Telegram user session.

Required environment:

```bash
export TELEGRAM_API_ID=...
export TELEGRAM_API_HASH=...
export TELEGRAM_PHONE=...
export TELEGRAM_CHAT=...
export TELEGRAM_FROM_USER=ana_lfgbot
```

Example:

```bash
python3 scripts/telegram_user_smoke.py \
  --chat "$TELEGRAM_CHAT" \
  --send "/status" \
  --watch-seconds 60 \
  --print-history
```

Per phase, smoke must verify:

- The phase's primary surface works from Thomas's account.
- Non-owner behaviour is denied.
- No secrets appear in Telegram output.
- DB state changed as expected.

The production bot token stays server-side; do not print tokens in logs.

## Open Questions

- Card UX: one card per mission, or one consolidated "active missions" message
  that updates as a list? Per-mission threads cleanly but clutters chat over
  time; list is tidy but loses reply-threading per mission. Default lean:
  per-mission card with auto-archive on completion.
- LLM gate failure mode: default to send (safe) or suppress (quiet)? Default
  lean: send, with a hard cooldown floor that's strictly better than today.
- Migration: backfill cards for active missions at deploy time, or only
  forward-going? Default lean: backfill on the next event after deploy.
- Multi-user prefs: do we expect anyone besides Thomas to have full owner
  prefs? If yes, dashboard prefs UI needs a per-user view.
- Should dashboard activity advance the same cursor as Telegram `/status`, or
  should dashboard and Telegram have separate "briefed" cursors?
- Should Paloma DM Thomas before answering Benjamin in a shared chat when the
  answer depends on private context?

## Suggested First Slice

Phase 1 + Phase 2 together. The card service kills the spam by giving events a
non-interrupt destination; cooldowns + quiet hours kill the residual.
Everything after that is quality and intelligence improvements on top of a
clean foundation.

## Simple Goal Prompt

Use this with an agent:

```text
/goal Implement the Paloma Telegram roadmap in docs/archive/PALOMA_TELEGRAM_ROADMAP.md, starting with Phase 1 (MissionCard service) and Phase 2 (cooldown, preferences, quiet hours) which together eliminate the current overnight-alert spam. Continue phase by phase, each one shippable independently. Keep the UX simple: one bot, Thomas-only mission control, per-mission rolling card as the default channel, interrupts only when classified as important, daily digest for the rest, safe limited shared-chat behavior for Benjamin. For every completed feature, add focused tests and run live Telegram smoke tests with scripts/telegram_user_smoke.py from my Telegram account when credentials are available. Do not print bot tokens or secrets. Before marking a phase done, walk its Definition of Done checklist against code, tests, production config, and Telegram smoke results; keep going until each item is genuinely verified or clearly marked blocked with the exact missing credential/config.
```
