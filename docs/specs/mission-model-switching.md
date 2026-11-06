# Live & Settled Mission Model Switching

In-place `model_override` switching lets users change the model or routing chain
of an existing conversation across Core workspaces, remote compute nodes, and
local ("This computer") runs without stopping active turns or losing session
continuity.

## Execution semantics

1. **Zero-downtime live switching (`PATCH /api/control/missions/:id/settings`)**:
   - Updating `model_override` (alongside `model_effort`, `service_tier`, or
     `fast_mode`) is permitted in **all** mission statuses — both settled
     (`completed`, `awaiting_user`, `acknowledged`, `interrupted`, `failed`,
     etc.) and live (`active`, `running`, `queued`, `waiting_background`,
     `resuming`, `planning`, etc.).
   - An in-flight turn continues undisturbed on the model it started with.
   - The updated `model_override` is persisted immediately in SQLite with a
     refreshed `updated_at` timestamp, broadcast over the mission SSE stream as
     `mission_settings_updated`, and pushed onto any live `MissionRunner` handle
     so queued follow-ups, `/goal` continuations, and scheduled continuations
     use the new model on the very next turn.
   - `MissionRunner::acquire_durable_run` refreshes mutable run settings
     (`backend_id`, `agent_override`, `model_override`, `model_effort`,
     `fast_mode`, `service_tier`, `config_profile`, `session_id`) from
     `mission_store` before every turn so idle/reused runners never execute with
     stale settings.

2. **OpenCode session continuity (`--session ses_* --model <model>`)**:
   - OpenCode runs one process per turn and resumes conversations via
     `--session <ses_id>`. Changing `--model` between turns on Core, remote
     nodes (`RemoteHarnessPlan::OpenCode`), or local desktop runs
     (`routed_opencode.rs`) resumes the exact same `ses_*` session with zero
     restart or context loss.
   - If `model_override` is cleared to `null`/empty on a remote OpenCode
     continuation, Core resolves the fallback chain ID from `chain_store`
     (defaulting to `"smart"`), never emitting a bare `builtin/` prefix.

## OpenCode model catalog

All clients (Orb Desktop, iOS, Android) present a unified OpenCode model list
from `GET /api/model-routing/chains` and `GET /api/providers/backend-models`:

1. **Routing chains first** (`builtin/<name>`, labeled `Routing — <Name>`), with
   the default chain first.
2. **Direct configured models** (`<provider>/<model>`, labeled
   `<Provider> — <Model>`) from `backends.opencode`, deduplicated against chain
   IDs.

Core's `/v1` OpenAI-compatible proxy (`src/api/proxy.rs`), remote OpenCode
plans (`src/api/control/remote_plan.rs`), and Orb Desktop's local routed runner
(`orb/src-tauri/src/routed_opencode.rs`) accept both `builtin/<chain>` routes
and configured `<provider>/<model>` identifiers.

## Client state ownership & ordering invariants

1. **Always-available dock picker**:
   - The conversation dock renders the model pill as an interactive `<Picker>`
     whenever `models.length > 1` (or when the current `model_override` differs
     from the sole catalog option), regardless of whether the mission is
     actively streaming or settled (`completed` on remote nodes, `interrupted`,
     etc.).
   - While a `PATCH /settings` request is in flight, the button stays mounted
     with `disabled` rather than swapping to a `<span>` (no layout jump),
     applying the chosen `model_override` optimistically and rolling back
     authoritatively (bypassing the optimistic timestamp fence) with an inline
     error if the server rejects it.
   - Interactive picker changes send `resume: false` on `PATCH /settings` so
     changing a next-turn model/effort/speed on a `failed` or `interrupted`
     conversation never silently restarts an agent turn without user input.

2. **Monotonic merge against stale polls (`updated_at` & generation/PATCH fence)**:
   - Sidebar/project polls (`GET /api/control/missions`) and concurrent refresh
     fetches can return snapshots read before an optimistic or just-committed
     `PATCH /settings`.
   - Merging an incoming mission snapshot or `mission_settings_updated` SSE
     event into an open conversation must never overwrite mutable settings
     (`model_override`, `model_effort`, `service_tier`, `fast_mode`, `backend`)
     while a local settings PATCH is pending (tracked per generation) or when a
     refresh started before the latest local settings save, nor when the
     incoming snapshot carries an older `updated_at` than the current state.
   - `mission_settings_updated` SSE events and `PATCH /settings` responses merge
     only mutable settings fields (`backend`, `agent`, `model_override`,
     `model_effort`, `fast_mode`, `service_tier`, `config_profile`,
     `session_id`, and `updated_at` if newer) into the latest in-memory mission
     snapshot while preserving intervening lifecycle/status transitions,
     invalidate any in-flight cached mission reads started before the save, and
     sync upward to the sidebar mission list.
   - When an existing conversation's picker also offers harness transfer,
     in-place automatic model saves run only when the selected harness matches
     the mission's stored `backend`; choosing a destination harness for transfer
     never mutates the source conversation's settings on dismissal.

3. **Pick-then-send ordering**:
   - Selecting a model in the dock and immediately submitting a follow-up
     message awaits any in-flight `PATCH /settings` for that mission before
     dispatching `POST /api/control/message` (or enqueuing/dispatching a local
     turn), guaranteeing the new turn observes the newly selected model.

4. **Local ("This computer") journal & queue parity**:
   - While a local turn's journal sync is pending (`localPending`), Core remains
     the owner of mutable run settings (`model_override`, `model_effort`,
     `service_tier`, `fast_mode`); local journal overlays must preserve Core's
     values rather than reverting to the launch-time journal snapshot.
   - Queued local follow-ups read the mission's latest `model_override` at
     dispatch time so mid-turn model switches take effect on queued messages.
