# Android Dashboard Simulator Test Plan

This plan is written for an LLM or human tester driving the Android app through
an Android Emulator with `adb`. The app exposes stable **testTags** that
uiautomator surfaces as `resource-id`, so all interactions in this plan are by
ID, not coordinates or text. Selectors live in
[`app/.../ui/TestTags.kt`](app/src/main/java/sh/sandboxed/dashboard/ui/TestTags.kt);
renaming any tag requires updating this plan in the same change.

Helpers used throughout (`dump_ui`, `find_tag`, `tap_tag`, `type_into_tag`,
`wait_for`, `screenshot`, `record_result`, `on_case_fail`, `summarise_results`)
are defined in [`test-helpers.sh`](test-helpers.sh).

## Scope

Validate the native Android dashboard at `android_dashboard/` against a running
Core backend:

- First-run server configuration and auth gate.
- Bottom-tab navigation: Control, Missions, Terminal, Files, More.
- Secondary screens: Workspaces, Desktop, Tasks, Runs, FIDO approvals, Settings.
- Control flows: mission creation, streaming messages, mission switcher,
  automations, queue/resume/cancel/delete UI where data exists.
- WebSocket/SSE behavior: terminal, control stream, reconnect/error states.
- Persistence, rotation, background/foreground, and crash-free behavior.

Do not use production data unless explicitly authorized. Prefer a disposable
local or staging backend.

## Express vs Full

| Tag | Cases | When to run |
|---|---|---|
| `@smoke` | 1, 2, 3, 6, 10, 17 | Per-PR gate. Cold launch → sign in → tabs → mission stream → terminal Send → crash sweep. |
| `@full` | 1–17 | Nightly / release qualification. |
| `@manual` | upload/download, biometric prompt | Human required; skip in automation. |

## Required Tools

- Android Studio or Android command-line tools.
- One running Android Emulator, API 33 or newer required; API 35 or newer preferred.
- `adb` on `PATH`.
- Java 17.
- A reachable Core backend.

## Environment

```bash
export APP_ID=sh.sandboxed.dashboard
export RUN_ID="llm-android-$(date +%Y%m%d-%H%M%S)"
export ARTIFACT_DIR="$PWD/android_dashboard/test-artifacts/$RUN_ID"
mkdir -p "$ARTIFACT_DIR"

# Same URL works for both the test machine (`curl`) and the emulator app, as
# long as it is reachable from inside the emulator. For a local backend, use
# http://10.0.2.2:3000 in BACKEND_URL_APP — the host is reachable from the
# emulator at 10.0.2.2.
export BACKEND_URL_HOST="http://127.0.0.1:3000"
export BACKEND_URL_APP="http://10.0.2.2:3000"

# Optional: only set when a test backend uses password auth.
export SANDBOXED_TEST_PASSWORD=""

source android_dashboard/test-helpers.sh
```

## Preflight

```bash
adb version | tee "$ARTIFACT_DIR/adb-version.txt"
emulator -list-avds | tee "$ARTIFACT_DIR/avd-names.txt"

# Unlock the user. A locked Direct Boot user makes `am start` look broken even
# when the manifest is fine.
adb wait-for-device
adb shell input keyevent KEYCODE_WAKEUP
adb shell wm dismiss-keyguard
adb shell dumpsys user | tee "$ARTIFACT_DIR/user-state.txt" \
  | grep -q "RUNNING_LOCKED" && {
    echo "ENV_BLOCKED: emulator user RUNNING_LOCKED" \
      | tee "$ARTIFACT_DIR/locked-user-blocker.txt"
    exit 1
  }
```

## Backend

Probe `/api/health` once. The response selects which auth case to run; mark
GitHub auth as `N/A` if `github_enabled=false`.

```bash
curl -fsS "$BACKEND_URL_HOST/api/health" | tee "$ARTIFACT_DIR/health.json"

if [ -n "${SANDBOXED_TEST_PASSWORD:-}" ]; then
  export BACKEND_TOKEN=$(
    curl -fsS -X POST "$BACKEND_URL_HOST/api/auth/login" \
      -H 'content-type: application/json' \
      -d "{\"password\":\"$SANDBOXED_TEST_PASSWORD\"}" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("token",""))'
  )
  [ -n "$BACKEND_TOKEN" ] && echo "token acquired" > "$ARTIFACT_DIR/token-state.txt"
fi
```

Do not write credentials to artifact filenames or anywhere under
`$ARTIFACT_DIR/`. If a disposable local backend is desired:
`cp -n .env.example .env && docker compose up -d --build` — `DEV_MODE=true`
skips the login form.

## Build And Install

```bash
( cd android_dashboard && ./gradlew :app:assembleDebug )
adb install -r android_dashboard/app/build/outputs/apk/debug/app-debug.apk \
  | tee "$ARTIFACT_DIR/install.txt"
adb shell pm clear "$APP_ID"
adb shell am start -W -n "$APP_ID/.MainActivity" | tee "$ARTIFACT_DIR/am-start.txt"
screenshot 00-launch.png
adb logcat -c
```

If `am-start.txt` matches `Error type|does not exist|Exception|Status: error`,
collect launch diagnostics (`dumpsys user`, `dumpsys window`,
`dumpsys package $APP_ID`, `logcat -d -t 1000`, `apkanalyzer manifest print`)
before opening any test case.

## Selector contract: tap by testTag, not by coordinates or visible text

The app calls `Modifier.semantics { testTagsAsResourceId = true }` at its
root, so every `Modifier.testTag("foo")` lands as `resource-id="foo"` in
`uiautomator dump`. Always select by tag:

```bash
tap_tag control.composer.send
type_into_tag control.composer.input "Reply with exactly android smoke $RUN_ID"
```

Tap-by-text and tap-by-coordinate fall back to brittle fuzzy matching (the
"Sign in" title vs. button collision burned a round-trip in earlier runs).
Resist them — if a tag is missing for something you need, add it to
`TestTags.kt` in the same commit as the test change.

## Polling, not sleeping

Replace fixed `sleep` with `wait_for`:

```bash
tap_tag auth.login.submit
wait_for tag nav.tab.control 10 \
  || { record_result 02 "Auth gate" fail APP_FAIL "login did not progress"; exit 1; }
```

`wait_for` polls every 0.5 s up to the supplied timeout. Reserve fixed sleeps
for things that genuinely have no observable signal (e.g. a frame counter
that needs a few seconds of stream to tick).

## Text entry caveats

`adb shell input text` is fragile:

- **Spaces**: replace with `%s` (`type_into_tag` does this for you).
- **Quotes**: avoid. The emulator interprets `"`, `'`, and `` ` `` in
  unpredictable ways across builds.
- **Newlines**: send via `adb shell input keyevent KEYCODE_ENTER`, not `\n`.
- **`$`**: shell-expand on the host first, never inside the device.
- **Soft keyboard**: hide it before tapping a footer/toolbar button.
  `type_into_tag` already sends `KEYCODE_BACK` after typing for this reason.

For markers in test data, prefer alphanumeric + dashes:

```text
Mission prompt:      Reply with exactly android smoke $RUN_ID
Automation command:  Say android automation smoke $RUN_ID
Terminal command:    echo android terminal smoke $RUN_ID
Workspace name:      $RUN_ID-workspace
Folder name:         $RUN_ID-folder
```

## On-failure trap

Each case sets a trap that auto-captures a screenshot, UI dump, and the last
800 logcat lines if any command in the case fails:

```bash
set -eE
CASE=06; trap 'on_case_fail "$CASE"' ERR
```

Pair every case with `record_result` so `results.jsonl` is complete:

```bash
record_result "$CASE" "Control: new mission" pass
# or
record_result "$CASE" "Files: workspace listing" fail APP_FAIL "list returned 12 items, screen showed 0"
```

`summarise_results` prints a markdown table and pass/fail totals at the end of
the run.

## Test cases

### 1. First-run configuration  `@smoke`

`pm clear` followed by `am start` shows the config sheet. On a re-run without a
clear (cached settings present), the URL field may already be gone — handle
both. Note: the URL field is pre-filled with `https://` on a fresh launch;
`type_into_tag` clears it first, so don't add another `https://` prefix.

```bash
set -eE; CASE=01; trap 'on_case_fail "$CASE"' ERR
if wait_for tag auth.url.field 3; then
  type_into_tag auth.url.field "$BACKEND_URL_APP"
  tap_tag auth.url.continue
fi
# Either the login form (auth required), the main nav (auth disabled or token
# cached), or — if the field was absent — we're already past the gate.
if wait_for tag auth.login.submit 8 || wait_for tag nav.tab.control 8; then
  record_result $CASE "First-run config" pass
else
  record_result $CASE "First-run config" fail APP_FAIL "stuck after Continue"
  exit 1
fi
```

Pass when `auth.login.submit` (auth required) or `nav.tab.control`
(auth disabled or already authenticated) appears within 8 s.

### 2. Auth gate  `@smoke`

Run only the variant indicated by `health.json`. Skip if the previous case
already landed on the main nav (token cached across `pm clear` is unlikely but
re-runs without a clear hit this path).

```bash
set -eE; CASE=02; trap 'on_case_fail "$CASE"' ERR
if wait_for tag nav.tab.control 3; then
  record_result $CASE "Auth (already authenticated)" pass
elif [ "$(jq -r .auth_mode "$ARTIFACT_DIR/health.json")" = "disabled" ]; then
  wait_for tag nav.tab.control 8 \
    && record_result $CASE "Auth disabled" pass \
    || record_result $CASE "Auth disabled" fail APP_FAIL "nav did not render"
elif [ "$(jq -r .auth_mode "$ARTIFACT_DIR/health.json")" = "single_tenant" ]; then
  type_into_tag auth.login.password "$SANDBOXED_TEST_PASSWORD"
  tap_tag auth.login.submit
  wait_for tag nav.tab.control 10 \
    && record_result $CASE "Single-tenant auth" pass \
    || record_result $CASE "Single-tenant auth" fail APP_FAIL "login did not progress"
elif [ "$(jq -r .auth_mode "$ARTIFACT_DIR/health.json")" = "multi_user" ]; then
  type_into_tag auth.login.username "$TEST_USERNAME"
  type_into_tag auth.login.password "$SANDBOXED_TEST_PASSWORD"
  tap_tag auth.login.submit
  wait_for tag nav.tab.control 10 \
    && record_result $CASE "Multi-user auth" pass \
    || record_result $CASE "Multi-user auth" fail APP_FAIL "login did not progress"
fi
```

**Sentinel for a known auth-gate regression:** if the screen renders only a
centered `ProgressBar` (the `FullscreenSpinner`) and nothing else, the
`AuthGate` is stuck in the `RESOLVING` phase. This historically reproduced
during rapid rotation + network flap. The Activity is alive (`pidof $APP_ID`
returns a PID) but `uiautomator dump` exposes only `android:id/content` and a
single `ProgressBar` node. `am force-stop` + relaunch clears it. Classify as
`APP_FAIL` and capture `dumpsys dropbox --print data_app_crash` even if
`logcat` looks clean.

If `github_enabled=true`, also exercise the deep-link handler from outside the
app — this proves the callback parses and does not crash:

```bash
adb shell am start -a android.intent.action.VIEW \
  -d "sandboxed://auth/callback?token=synthetic-token&exp=4102444800" \
  -p "$APP_ID"
```

### 3. Bottom navigation smoke  `@smoke`

```bash
set -eE; CASE=03; trap 'on_case_fail "$CASE"' ERR
for tab in control history terminal files more; do
  tap_tag "nav.tab.$tab"
  wait_for tag "nav.tab.$tab" 3
done
record_result $CASE "Bottom nav smoke" pass
```

Spot-check at least one tag unique to each tab while you are there:
`control.composer.send`, `history.search`, `terminal.send`, `files.up`,
`more.tile.settings`.

### 4. Settings persistence

```bash
set -eE; CASE=04; trap 'on_case_fail "$CASE"' ERR
tap_tag nav.tab.more
tap_tag more.tile.settings
tap_tag settings.test_save
wait_for label "Connected" 10 \
  || { record_result $CASE "Test & save" fail APP_FAIL "no Connected status"; exit 1; }

# Probe backend list to choose a non-selected backend deterministically.
PRIMARY=$(curl -fsS "$BACKEND_URL_HOST/api/backends" \
  -H "authorization: Bearer $BACKEND_TOKEN" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["id"])')
tap_tag "settings.backend.$PRIMARY"

# Relaunch and confirm the choice persists.
adb shell am force-stop "$APP_ID"
adb shell am start -W -n "$APP_ID/.MainActivity"
wait_for tag nav.tab.more 8
tap_tag nav.tab.more
tap_tag more.tile.settings
wait_for tag "settings.backend.$PRIMARY" 5 \
  && record_result $CASE "Settings persistence" pass \
  || record_result $CASE "Settings persistence" fail APP_FAIL "backend choice did not persist"
```

Do not tap `settings.sign_out` unless the case is supposed to log out — it
will force you back through Case 2.

### 5. Workspaces

```bash
set -eE; CASE=05; trap 'on_case_fail "$CASE"' ERR
tap_tag nav.tab.more; tap_tag more.tile.workspaces
tap_tag workspaces.create
tap_tag workspaces.new.type.host
# Create must be disabled with empty path.
wait_for label "Host workspaces require a path." 3 \
  || { record_result $CASE "Host validation" fail APP_FAIL "missing validation copy"; exit 1; }
tap_tag workspaces.new.cancel
record_result $CASE "Workspaces" pass
```

Disposable-backend only: optionally type a name and create a container
workspace, then delete it via API in cleanup.

### 6. Control — new mission and streaming  `@smoke`

Prerequisite: at least one workspace and one configured backend
(verify via `/api/workspaces` and `/api/backends`).

```bash
set -eE; CASE=06; trap 'on_case_fail "$CASE"' ERR
tap_tag nav.tab.control
tap_tag control.topbar.new_mission
wait_for tag control.new_mission.create 8
tap_tag control.new_mission.create

type_into_tag control.composer.input \
  "Reply with exactly android smoke $RUN_ID"
tap_tag control.composer.send

# Assistant should echo the marker; budget for cold model.
wait_for label "android smoke $RUN_ID" 60 \
  && record_result $CASE "Mission streaming" pass \
  || record_result $CASE "Mission streaming" fail BACKEND_FAIL "no marker after 60 s"

# Persistence check: kill and relaunch.
adb shell am force-stop "$APP_ID"
adb shell am start -n "$APP_ID/.MainActivity"
wait_for label "android smoke $RUN_ID" 10 \
  || record_result $CASE "Mission relaunch" fail APP_FAIL "mission did not restore"
```

If the assistant returns a backend-side error (e.g. *"Claude Code CLI 'claude'
not found"*) classify as `BACKEND_FAIL` and capture
`/api/backends` + `/api/workspaces` JSON next to the artifact for triage.

### 7. Mission switcher

```bash
set -eE; CASE=07; trap 'on_case_fail "$CASE"' ERR
tap_tag control.topbar.missions
wait_for tag control.switcher.search 5
type_into_tag control.switcher.search "$RUN_ID"
# Either a row appears or the empty-result UI is reached — both pass; crash fails.
tap_tag control.switcher.close
record_result $CASE "Mission switcher" pass
```

Queue/Workers UI is only exercised when a long-running mission is active.
Mark `N/A` if the test mission completes immediately.

### 8. Automations

Prerequisite: a current mission exists (Case 6 completed).

```bash
set -eE; CASE=08; trap 'on_case_fail "$CASE"' ERR
tap_tag control.topbar.automations
tap_tag automations.add
type_into_tag automations.new.command "Say android automation smoke $RUN_ID"
tap_tag automations.new.create
wait_for label "every 60s" 5 \
  || { record_result $CASE "Automations create" fail APP_FAIL "row not visible"; exit 1; }
# Clean up so we don't leak smoke automations.
# (Row exposes a generic Delete content-desc; use find_tag once a per-row tag exists.)
record_result $CASE "Automations" pass
```

### 9. Missions history

```bash
set -eE; CASE=09; trap 'on_case_fail "$CASE"' ERR
tap_tag nav.tab.history
for f in all active interrupted completed failed; do
  tap_tag "history.filter.$f"
  sleep 0.3   # purely visual settle; no API
done
type_into_tag history.search "$RUN_ID"
wait_for label "$RUN_ID" 3 || true   # may match zero — both states are valid
tap_tag history.refresh
record_result $CASE "Missions history" pass
```

### 10. Terminal WebSocket  `@smoke`

```bash
set -eE; CASE=10; trap 'on_case_fail "$CASE"' ERR
tap_tag nav.tab.terminal
wait_for label "connected" 10 \
  || { record_result $CASE "Terminal connect" fail BACKEND_FAIL "WebSocket did not connect"; exit 1; }
type_into_tag terminal.input "echo android terminal smoke $RUN_ID"
tap_tag terminal.send
wait_for label "android terminal smoke $RUN_ID" 6 \
  && record_result $CASE "Terminal Send" pass \
  || record_result $CASE "Terminal Send" fail APP_FAIL "marker not in output"
```

If `wait_for` times out, immediately confirm the backend itself can echo the
marker by opening `/api/console/ws` from the host with the same token —
that distinguishes `APP_FAIL` (client) from `BACKEND_FAIL` (PTY).

### 11. Files

```bash
set -eE; CASE=11; trap 'on_case_fail "$CASE"' ERR
tap_tag nav.tab.files

# API-first sanity: list what the screen should show.
EXPECT=$(curl -fsS "$BACKEND_URL_HOST/api/fs/list?path=." \
  -H "authorization: Bearer $BACKEND_TOKEN" | python3 -c \
  'import json,sys; print(len(json.load(sys.stdin)))')
wait_for tag files.path 5
sleep 2  # give the LazyColumn time to render rows after the API response
# The screen should render at least one row when EXPECT > 0. Count Delete
# action labels — each rendered row exposes exactly one, so it's a reliable
# proxy. Counting "folder"/"file" tokens picks up tooltips/subtitle nodes too.
dump_ui "$ARTIFACT_DIR/$CASE-files.txt" > /dev/null
ROWS=$(grep -c "Delete" "$ARTIFACT_DIR/$CASE-files.txt" || true)
if [ "$EXPECT" -gt 0 ] && [ "$ROWS" -lt 1 ]; then
  record_result $CASE "Files listing" fail APP_FAIL "API returned $EXPECT items, screen rendered $ROWS"
  exit 1
fi

tap_tag files.new_folder
type_into_tag files.new_folder.name "$RUN_ID-folder"
tap_tag files.new_folder.create

# The backend rejects mkdir with a leading "/" (path traversal). Tag-driven
# creation lets us assert without scraping copy.
sleep 2
NEW=$(curl -fsS "$BACKEND_URL_HOST/api/fs/list?path=." \
  -H "authorization: Bearer $BACKEND_TOKEN" \
  | python3 -c "import json,sys; data=json.load(sys.stdin); print(any(e['name']=='$RUN_ID-folder' for e in data))")
[ "$NEW" = "True" ] \
  && record_result $CASE "Files mkdir" pass \
  || record_result $CASE "Files mkdir" fail CONTRACT_FAIL "folder did not appear on backend"
```

Upload/download remain `@manual` (Android DocumentsUI picker).

### 12. More: Tasks and Runs

```bash
set -eE; CASE=12; trap 'on_case_fail "$CASE"' ERR
tap_tag nav.tab.more; tap_tag more.tile.tasks
tap_tag tasks.refresh
wait_for label "No subtasks running" 3 || wait_for label "iterations" 3 \
  || { record_result $CASE "Tasks empty/populated" fail APP_FAIL "neither state visible"; exit 1; }

tap_tag nav.tab.more; tap_tag more.tile.runs
tap_tag runs.refresh
wait_for label "No runs recorded" 3 || wait_for label "$" 3 \
  || { record_result $CASE "Runs empty/populated" fail APP_FAIL "neither state visible"; exit 1; }

record_result $CASE "Tasks & Runs" pass
```

### 13. FIDO approvals

```bash
set -eE; CASE=13; trap 'on_case_fail "$CASE"' ERR
tap_tag nav.tab.more; tap_tag more.tile.fido
tap_tag fido.always_biometric          # toggle on
tap_tag fido.always_biometric          # toggle off
tap_tag fido.add_rule
tap_tag fido.new.match.all
tap_tag fido.new.expiry.24h
tap_tag fido.new.add
wait_for label "Any SSH key" 4 \
  || { record_result $CASE "FIDO add rule" fail APP_FAIL "rule not created"; exit 1; }

# Relaunch and confirm rule persisted.
adb shell am force-stop "$APP_ID"
adb shell am start -n "$APP_ID/.MainActivity"
wait_for tag nav.tab.more 8
tap_tag nav.tab.more; tap_tag more.tile.fido
wait_for label "Any SSH key" 5 \
  && record_result $CASE "FIDO persistence" pass \
  || record_result $CASE "FIDO persistence" fail APP_FAIL "rule lost on relaunch"
```

Live biometric prompt is `@manual` — needs an enrolled biometric on the AVD.

### 14. Desktop stream

```bash
set -eE; CASE=14; trap 'on_case_fail "$CASE"' ERR
tap_tag nav.tab.more; tap_tag more.tile.desktop

# Find a display the backend is actually running. Skip if none.
DISPLAY=$(curl -fsS "$BACKEND_URL_HOST/api/desktop/sessions" \
  -H "authorization: Bearer $BACKEND_TOKEN" \
  | python3 -c 'import json,sys; ss=json.load(sys.stdin).get("sessions",[]); ok=[s for s in ss if s.get("process_running")]; print(ok[0]["display"] if ok else "")')
if [ -z "$DISPLAY" ]; then
  record_result $CASE "Desktop stream" blocked ENV_BLOCKED "no live display sessions"
  exit 0
fi

tap_tag "desktop.display.${DISPLAY#:}"
wait_for label "frames" 8
# Frame counter should advance — sample twice 2 s apart.
FRAMES_A=$(dump_ui "$ARTIFACT_DIR/$CASE-a.txt" \
  | grep -oE "[0-9]+ frames" | head -1 | awk '{print $1}')
sleep 2
FRAMES_B=$(dump_ui "$ARTIFACT_DIR/$CASE-b.txt" \
  | grep -oE "[0-9]+ frames" | head -1 | awk '{print $1}')
[ "${FRAMES_B:-0}" -gt "${FRAMES_A:-0}" ] \
  && record_result $CASE "Desktop frames" pass \
  || record_result $CASE "Desktop frames" fail BACKEND_FAIL "frame count did not advance ($FRAMES_A → $FRAMES_B)"

tap_tag desktop.key.return
tap_tag desktop.key.esc
tap_tag desktop.retry  # only fires if an error banner is visible — safe no-op otherwise
```

### 15. Rotation and lifecycle

```bash
set -eE; CASE=15; trap 'on_case_fail "$CASE"' ERR
adb shell settings put system accelerometer_rotation 0
for tab in control terminal files more; do
  tap_tag "nav.tab.$tab"
  adb shell settings put system user_rotation 1; sleep 2
  screenshot "$CASE-$tab-landscape.png"
  adb shell settings put system user_rotation 0; sleep 1
done
adb shell input keyevent KEYCODE_HOME; sleep 1
adb shell am start -n "$APP_ID/.MainActivity"
wait_for tag nav.tab.control 8 \
  && record_result $CASE "Rotation + lifecycle" pass \
  || record_result $CASE "Rotation + lifecycle" fail APP_FAIL "nav missing after foreground"
```

### 16. Network resilience

```bash
set -eE; CASE=16; trap 'on_case_fail "$CASE"' ERR
adb shell svc wifi disable; adb shell svc data disable
for tab in control history terminal files; do tap_tag "nav.tab.$tab"; sleep 1; done
adb shell svc wifi enable; adb shell svc data enable
tap_tag nav.tab.terminal
wait_for label "connected" 30 \
  && record_result $CASE "Network resilience" pass \
  || record_result $CASE "Network resilience" fail APP_FAIL "did not reconnect after restore"
```

### 17. Crash sweep  `@smoke`

```bash
adb logcat -d -t 3000 > "$ARTIFACT_DIR/logcat.txt"
adb shell dumpsys dropbox --print data_app_crash > "$ARTIFACT_DIR/dropbox-crash.txt" 2>/dev/null || true
if grep -E "ANR in sh\\.sandboxed\\.dashboard|Process: sh\\.sandboxed\\.dashboard|Process sh\\.sandboxed\\.dashboard .* has died" "$ARTIFACT_DIR/logcat.txt"; then
  record_result 17 "Crash sweep" fail APP_FAIL "crash markers present"
else
  record_result 17 "Crash sweep" pass
fi
screenshot final.png
```

`AndroidRuntime` log lines from `uiautomator` are harmless noise — only flag
the process name `sh.sandboxed.dashboard`.

**On failure, get the full stack from DropBox.** Android logcat is a small
ring buffer; under load (Telecom spam, WiFi state transitions) the OS can
evict the actual `at …` frames between when the crash logs and when you dump
them. The system's `DropBoxManager` preserves a structured copy of every
`data_app_crash` for ~24 h. The stack lives there even when logcat shows just
`FATAL EXCEPTION: main` with no body:

```bash
adb shell dumpsys dropbox --print data_app_crash | less
```

Each entry has `Process:`, `PID:`, build info, the full stack with
`Caused by:` chains, and a `Suppressed:` line that names the originating
coroutine context (e.g. `StandaloneCoroutine{Cancelling}@…,
Dispatchers.Main.immediate`) — invaluable for tracing which
`viewModelScope.launch { … }` site went uncaught.

## Output

```bash
summarise_results | tee "$ARTIFACT_DIR/REPORT.md"
```

`results.jsonl` is the canonical, machine-readable record:

```json
{"case":"06","name":"Mission streaming","status":"pass","classification":null,"note":null}
{"case":"11","name":"Files mkdir","status":"pass","classification":null,"note":null}
{"case":"15","name":"Rotation + lifecycle","status":"fail","classification":"APP_FAIL","note":"nav missing after foreground"}
```

CI gates the smoke set by counting `status:fail|@smoke` in `results.jsonl`.

## Cleanup

- Delete `$RUN_ID-folder` and any uploaded smoke files from Files.
- Delete test automations and the test FIDO rule.
- Delete test missions **only** on a disposable backend.
- `adb shell pm clear "$APP_ID"` is appropriate for a clean re-run.

## Failure classification

- `APP_FAIL`: Android UI crash, incorrect state, broken navigation, persistence
  bug, unreadable layout, or unhandled client exception.
- `BACKEND_FAIL`: backend endpoint returns invalid data, 5xx, auth mismatch, or
  missing capability required by the feature.
- `CONTRACT_FAIL`: client and backend each behave consistently with their own
  assumptions, but the API contract is ambiguous or mismatched (e.g. path
  encoding).
- `ENV_BLOCKED`: emulator, credentials, provider auth, desktop stream, FIDO
  request source, or file picker unavailable.
- `N/A`: feature intentionally not enabled for this backend.

Every non-pass case must include a one-line `note` in `record_result` and at
least one of `<case>-fail.{png,xml,logcat.txt}` in the artifact dir (the
`on_case_fail` trap handles this for you).

## Diagnostics cheat sheet

When something goes wrong, work through these in order — each one was load-
bearing for at least one historical investigation.

| Symptom | First check |
|---|---|
| Screen blank but `pidof $APP_ID` non-empty | UI dump shows only `android:id/content` + `ProgressBar` → AuthGate stuck in RESOLVING. `am force-stop` + relaunch to confirm. |
| `tap_tag X` fails but `text="X"` is visible | The widget is a Compose `FilterChip` whose modifier doesn't surface the testTag. Wrap the chip in `Box(Modifier.tag(X)) { FilterChip(...) }` in the screen. |
| `FATAL EXCEPTION: main` in logcat but no stack frames | logcat ring buffer evicted them. Run `adb shell dumpsys dropbox --print data_app_crash` for the structured copy. |
| Crash stack ends at `RealCall$AsyncCall.run` | OkHttp dispatcher-thread crash. Almost always an uncaught network error from a `viewModelScope.launch { … }` site without `runCatching`. The `Suppressed:` line names the offending coroutine context. |
| Filed listing shows the path header but no rows | Compare the screen count to `curl /api/fs/list?path=.` *after* a `sleep 2` for the LazyColumn. If they disagree, classify as `APP_FAIL`. |
| `type_into_tag` produces concatenated junk | The field had a placeholder/prior value. `type_into_tag` clears via `MOVE_END + 80 DEL`; if that's not enough, raise the count in `test-helpers.sh`. |
| Tab tap "succeeds" but next tap fails | Configuration change in flight. Insert `wait_for tag <known tag on the target screen>` between taps. |

Pieces of state and data that survive `pm clear` and can confound re-runs:

- DropBox crash entries — those age out on their own (~24 h). Old fatals can
  trip Case 17 if you `grep` blindly across a long window. The case as
  written greps `logcat.txt` produced by `logcat -d -t 3000` (current
  buffer), not DropBox, so this is safe — but if you swap the grep target,
  filter on a fresh PID first.
- DNS resolver cache — disable wifi/data, re-enable, expect `getaddrinfo`
  warm-up. Case 16 gives up to 40 s on reconnect; tune if your network is
  slower.
- Emulator user lock — see Preflight.
