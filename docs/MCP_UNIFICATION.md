# Unified MCP implementation and validation

This work is in progress. The backend and suffixed companion are deployed to
development only. Production cutover and the complete live harness/provider
matrix remain unvalidated.

`sandboxed-mcp` is the stdio client. Core owns the catalogue, authorization and
execution under `/api/mcp`. Profiles are executor, coordinator and operator.
Executor sessions require a mission; they may address that mission and its
direct children, including cloud missions using the owner's account quotas.

Mutations require an idempotency key. Core records intent in `projects.db` and
returns an action ID before dispatch. `get_action` reports the tool result.
Tool completion is distinct from the referenced mission/job's completion.
On restart, queued actions remain queued; dispatches whose outcomes are unknown
become `reconciliation_required` rather than being blindly replayed.
An operator can settle an uncertain receipt with `reconcile_action`, supplying
target evidence in the original mission/project scope. Reconciliation never
replays work. `cancel_action` atomically cancels only work still queued.

The stdio transport permits eight concurrent requests. Cancelling an MCP wait
does not cancel accepted work. Frames are bounded to 1 MiB before allocation.
Session revocation and mission scope are checked again before queued dispatch.

The trusted launcher exchanges an owner login for a one-hour `mcp1.` credential.
That credential cannot call ordinary API routes or mint broader grants. Active
mission sessions renew with identical privileges. The client refreshes its
private credential file atomically so a client restart can reuse the renewal.
Harness processes receive per-process MCP overlays, not shared config-file edits.

Orb builds its companion with `python3 orb/scripts/build-mcp.py`. Tauri stages
it as a native sidecar; development stages it beside the native executable.
An explicitly configured absolute `SANDBOXED_MCP_BIN` is also supported. Node
launches expect `/usr/local/bin/sandboxed-mcp` to be installed before cutover.

Gemini CLI is retired. Use Antigravity with the execution user's native
`agy` login; nodes use `SANDBOXED_NODE_ANTIGRAVITY_HOME`. Historical Gemini
validation notes below describe the former implementation, not a supported harness.

## Coordinated cutover

1. Build the backend, node and `sandboxed-mcp` on Linux. Build Orb's macOS
   companion independently; never install the macOS artifact on a node.
2. Deploy the new Core through the guarded deploy path. Keep the previous
   binaries/configuration available until verification completes.
3. With the Hermes Python environment, run `scripts/migrate_unified_mcp.py`
   using `--config`, `--binary`, `--api-url`, and a private
   `--owner-token-file`. The script exchanges the trusted owner's credential,
   compares the installed catalogue with Core, checks the actual client,
   and atomically replaces only Hermes's owned MCP server. On readiness
   failure it restores the prior configuration and credential. No secret is
   printed or passed as a command-line value.
4. Install the matching `project-manager`, `controllers-policy` and
   `sandboxed-sh-missions` runtime skills, then restart `hermes-assistant`.
   Verify the running child uses `sandboxed-mcp` and can read capabilities
   and an action receipt. Repeat separately with suffixed dev binaries.
5. Roll out the node companion and packaged Orb. Once no process or active
   config references either legacy binary, remove those installed binaries.
   Do not use a command-only migration or leave an alias as a fallback.

The cutover script's HTTP/subprocess integration tests cover successful
migration and rollback with/without a previous scoped credential. The
Core/Hermes production cutover and fleet companion rollout completed on
2026-09-27; see the production receipt below. Packaged Orb rollout and retirement
of legacy binaries/configuration references remain separate release gates.

## Remaining release gates

- Complete packaged Orb rollout and retire legacy binaries after checking all remaining consumers. Core/Hermes migration and fleet companions are deployed.
- Complete node/client task-board scheduling, desktop-owned workspace operations,
  native desktop child placement. Validate remote durable jobs against live
  nodes: node routing, retry identity, lost-submit observation, logs and
  cancellation now pass fixture integration tests. Standalone
  create/remove/merge now follow Core/node placement, with bounded Git output,
  clean-worktree protection and explicit conflict receipts. The HTTP integration
  test executes a real Git operation through a fixture node and proves retry
  does not repeat it. This is not a live fleet validation.
  Core task-board worktree creation now uses the same workspace executor and
  passes a real Git/board registration test.
- Verify all Core wrappers, remote launchers and Orb session recovery tests.
- Gemini live validation was explicitly waived by the operator.
- Exercise five harnesses on Core, old-agent and local; capability absence or
  blocked authentication is not a passing test.
- Exercise real ChatGPT, GrokBot and Cursor cloud lifecycles, retry, reconnect,
  cancellation, expiry, revocation and crash recovery on dedicated test missions.
- Verify Verity continuity read-only. Its last observed remote run stopped at
  the node's 7,200-second timeout; do not mistake that for MCP test success.
- Guarded production cutover, Hermes restart, node/Orb companion rollout and
  24-hour observation. Preserve current missions and concurrent cloud changes.

## Validation checkpoint (2026-09-26)

- Orb: 557 web tests passed (one skipped); 75 native tests passed (four ignored).
- Full Linux run: 2,640 passed, zero failed, six ignored. Subsequent remote-job
  changes passed seven integration tests, all 35 durable-job tests, and all 119
  MCP tests on Linux. Core task-board changes also passed the eight-test Linux integration suite.
- 119 MCP tests and seven Core integration tests passed: durable action retry,
  HTTP scope/auth, post-transfer child placement, actual Git execution through
  a node, refusal to run a remote workspace job on Core, remote job lifecycle,
  and observation after a lost node response without resubmission.
- Seven machine-transfer tests passed after adding the workspace mutation lock.
- Four Git helper tests passed: clean/dirty removal, path/flag rejection,
  merge evidence and conflict abort.
- No production cutover or complete live harness/provider matrix has been
  completed. old-agent has the new MCP companion, but still lacks Gemini.

### Development deployment and canary preparation

The debug Linux backend and `sandboxed-mcp-dev` are installed on Core's dev
instance (port 3002). The installed client passes `--check` using a private
operator session and reports the 67-tool operator catalogue. The latest Linux
MCP suite passes 120 tests. Owner credentials are not passed on command lines.
Production binaries and Hermes configuration have not been replaced.

Initial real-launch attempts exposed pre-dispatch conditions: an occupied
default workspace, then the system filesystem's 150 GiB emergency reserve.
Those action receipts were reconciled as rejected after inspecting Core's
responses and confirming no mission existed. An initial bind mount changed
the first test workspace's recorded filesystem identity; the runner correctly
refused it. That mount was removed and a new workspace was registered after
mounting the storage volume. These refusals are not harness test passes.

The dedicated test workspace is `3843290a-9794-4d6c-87f0-43b5cebbe849` at
`/var/lib/sandboxed-sh-dev/unified-mcp-storage-smoke`, temporarily bind-mounted
from `/srv/sandboxed-storage/staging/unified-mcp-dev-smoke`. Keep the mount while
tests run; stop only test missions and retire their workspace before unmounting.
The original test workspace `986f53b7-adf8-4d5c-a237-10f0c6f5fdb2` is back on
its original filesystem. Its failed canary is
`e4ca5667-8d9f-4f98-aea7-ac962576ae12`.

### Live checkpoint (2026-09-26, 21:45 UTC)

Validated by actual tool-call receipts, not only assistant statements:

| Placement | Harness | Mission | Result |
|---|---|---|---|
| Core dev | Codex | `13d755e7-789e-441b-9f06-d330e93e09dd` | executor identity and mission match |
| Core dev | Claude Code | `903f4496-8fb3-453b-8824-5c723d7041e6` | executor identity and mission match |
| Core dev | OpenCode | `52a3cc62-3cc7-4df8-9b27-d8e197ab6a2a` | passed with `builtin/fast`; initial Anthropic quota refusal |
| old-agent | Claude Code | `eb893015-ad19-4b2f-929e-fe9322cf063a` | native JSONL contains successful capabilities call |
| old-agent | OpenCode | `45487bb2-af36-4474-bd87-1c72e4d018cf` | node log contains completed `sandboxed_get_capabilities`, matching identity |

Remote durable job `385dd3be-8a7a-540a-a59d-d9cc06f2e055` retained its identity
and result across the dev Core restart. Replaying its action key returned the
same action. Cancellation of `d3101f97-b72e-50cc-9fdc-b5db8df83c7f` was acknowledged
by the node; the command's post-sleep marker never ran.

On the isolated cloud-check service (loopback 3012), Cursor mission
`7ba18baa-e664-4ec2-b6a8-1ab5829efda0` and GrokBot mission
`b52d0b7f-94c2-4426-8d1d-39c3294e1ec9` recalled their initial marker on a second
turn after service restart. Their external identities stayed unchanged and
repeated creation/follow-up keys did not create extra turns.

Remaining live failures:

- Core Gemini's Google login returns `UNSUPPORTED_CLIENT`. No usable Gemini API
  credential was found; a user question is pending. This is not a passing test.
- Core Grok login is unusable. Grok 1.x also ignores MCP definitions supplied
  through `GROK_CONFIG`. The local wrapper now injects the server into ACP
  `session/new` and `session/load`. Its non-ACP path fails explicitly until a
  supported headless bridge exists; do not roll this wrapper out to node Grok.
- old-agent Codex initially rejected a bare GPT model ID. Routing is fixed in
  dev; the subsequent attempt receives HTTP 502 and still does not pass.
- ChatGPT mission `675e5476-afa6-47d3-9207-e031c01e97e0` remains
  `submission_uncertain`. Do not repeat that submission. A non-submitting UI
  probe reached the authenticated composer, but a later distinct test request
  failed the account activation gate. No ChatGPT lifecycle success is claimed.

The new local cloud receipt reader returns paginated turns and bounded Unicode
text slices; it omits prompts by default and removes provider artifact/branch
payloads from polling responses. Full values are scrubbed before slicing to
avoid leaking credential fragments. The three coordinator skills document the
pagination contract. These latest changes and the Grok ACP fix are not deployed.
Local validation: 124 MCP tests pass, and five subprocess runtime tests pass.

Operational state: dev runs build10; old-agent's MCP companion is build9, with
its node daemon unchanged. Cloud-check uses dedicated build10 binaries and a
`95-unified-mcp.conf` ExecStart override. Stop that validation service and remove
the override when validation finishes; retain receipts. Production Core, Hermes
and Orb have not been cut over.

Rollback correction: an early backup inside the rsync destination was removed
by `--delete`. The original pre-task dev binary is no longer available there.
Build9 rollback binaries and the pre-old-agent dev environment now reside outside
the sync tree in `/var/backups/sandboxed-sh/unified-mcp-dev-20260926/`. Never keep
rollback artifacts inside a source tree synchronized with `--delete`.

### Follow-up checkpoint (2026-09-26, 21:58 UTC)

Dev now runs build12, including bounded cloud receipt reads, Grok ACP injection,
and MCP `readOnlyHint`/`destructiveHint` annotations derived from Core's mutation
policy. Production, old-agent's companion, and cloud-check have not changed in
this follow-up. Build10 rollback binaries were retained outside the sync tree.
125 MCP tests pass on macOS and Linux; the five executable runtime tests also
pass on Linux. An additional large-history test proves that a default read of
one turn stays under 5 KB with 100 turns containing 100,000-character prompts,
results and artifacts. A local-only allocation improvement avoids cloning the
whole turn list when slicing; its two targeted tests pass.

Standalone macOS validation used a private executor grant for the idle dev
canary `13d755e7-789e-441b-9f06-d330e93e09dd`; it did not resume that mission or
claim to validate Orb's placement/lifecycle:

- Claude Code successfully called `mcp__sandboxed__get_capabilities`; the actual
  tool result identifies executor/dev and the expected mission. Reported test
  cost was $0.255402, including global CLI context and cache creation.
- Codex initially denied the read-only MCP call under `approval_policy=never`.
  After adding Core's read-only annotations, the same policy succeeded. The
  native result is `completed` with the matching identity. The turn reports
  37,115 input tokens, 30,208 cached input tokens, and 102 output tokens. These
  counts include local Codex configuration/skills; they are not a claim that
  the MCP response alone consumed that amount, or that it has zero cost.
- Local Grok's `models` command explicitly reports unauthenticated. A second
  user question requests login; no credential was copied or invented.

Read-only Verity check still shows `blocked`, last updated 18:04:29 UTC, with
old-agent job `74be2556-e750-4d1b-a506-1f42dc68806d` failing after 7,200 seconds.
There is no evidence of resumed progress.

### Cancellation and unattended-action checks (2026-09-27 local time)

Cursor's third test turn (`run-7a0a1a24-8b0c-4c8b-a8cf-d97a810a542f`) was observed
running, cancellation was requested through MCP, and the provider then reported
`cancelled` with no final result. Action `ef7cf5e6-bfc4-423a-ae2c-b09dc93edd00`
records the request. The MCP cancellation adapter has since been corrected:
accepting a cancellation request no longer claims process termination. Both
cloud and native callers receive `cancel_requested`, `termination_confirmed=false`,
and the read tool needed to confirm the target's terminal state. Grok additionally
validates the pinned protobuf cancellation response: `hadActiveRun` is a boolean,
and an empty JSON object is its documented false default. Malformed values or
unrelated response envelopes are rejected. Unit tests cover both safeguards; live Grok verification is
still pending at this checkpoint.

Codex's `default_tools_approval_mode=auto` still blocked an unattended mutation
under `approval_policy=never`. The installed CLI accepted `approve` for this
specific server. A real scoped test then successfully ran `start_workspace_job`,
followed its action, and read job `e54d063d-1884-5ec5-86d3-85665c7a5799`: exit 0,
stdout `MCP_LOCAL_MUTATION_OK`. The launcher now injects that setting only for
`sandboxed`, after verifying the executor identity. It does not change the
harness's global approval policy. Core continues to authorize every operation.

Both standalone test grants were revoked and their private local credential
files removed. An installed-client `--check` proved a revoked grant is rejected.
The standalone OpenCode attempt stayed silent for over two minutes without
creating a native session. It was stopped through the launcher's SIGTERM path;
both launcher and child exited. This is not a local OpenCode pass.

Cloud reads now default to the latest turn, preserving current-state semantics.
History starts explicitly at `offset=0`; continuation uses the returned cursors.
This prevents a completed first turn from masking a running subsequent turn.


### Hosted progress versus completion

A real Grok Bot test sent “Starting the 60-second sleep…” while its command was
still running. The old connector incorrectly marked that first message as the
completed response, preventing cancellation through Core. The installed desktop
0.58.0 protobuf contract and a read-only `WatchGrokBotTranscripts` probe confirmed
that the provider exposes a separate live-state snapshot. During the command,
the snapshot contained the test agent with `isRunning=true`; at idle, the
snapshot omitted the agent. The connector now retains intermediate results as
partial and waits for an inactive snapshot before declaring response completion.
The Connect stream has frame/total-size limits and a ten-second deadline. EOF,
transport loss, deltas without a full snapshot, and malformed values never
establish completion. Six local Grok tests pass; deployment/live verification
of this latest change is pending at this checkpoint.

The protocol also confirmed that `InterruptGrokBotAgentRun` returns
`{hadActiveRun:true}` followed by `{}` once inactive: the protobuf boolean's
false default is legitimately omitted. The direct test interrupted only Bot
`b52d0b7f-94c2-4426-8d1d-39c3294e1ec9`; it is not a passing MCP cancellation test,
because the old Core record had already incorrectly marked that turn complete.

Cursor passed continuation after confirmed cancellation: its fourth turn,
`run-72337870-62b8-4a0f-8e4c-bf135c931ccb`, returned `PALOMA_MCP_926` on the same
external agent. The new default cloud receipt returned only the latest turn
(index 2 of 3 at the cancellation checkpoint), in 2,004 serialized bytes.

Build16 is currently installed on dev and the isolated cloud-check service.
Production/Orb/Hermes and old-agent's companion remain unchanged. The one-hour
cloud-check operator grant expired naturally and was rejected with HTTP 401;
a fresh grant was then minted through the trusted owner boundary without
persisting the owner JWT.

### Build17 verification and cleanup (2026-09-27)

Development runs build17. Its full Linux library suite passed: 2,660 tests,
zero failures, six ignored. The macOS companion was rebuilt and staged by
`orb/scripts/build-mcp.py`; this is not installation into the live Orb app.

Grok Bot's corrected lifecycle passed against the dedicated Bot
`b52d0b7f-94c2-4426-8d1d-39c3294e1ec9`: an intermediate “Starting.” result stayed
`running`, MCP cancellation acknowledged only the request, and a subsequent
provider read confirmed `cancelled`. A follow-up then returned `PALOMA_MCP_926`
on the same Bot. Repeating its idempotency key returned the same action
`ba507487-26e5-455e-9edc-83d08df601c8` without another turn.

The distinct ChatGPT activation-gate rejection was reconciled as not accepted;
no mission had been created. The earlier submission-uncertain mission
`675e5476-afa6-47d3-9207-e031c01e97e0` remains unresolved and was not resubmitted.

The isolated cloud-check service has been restored to inactive. Its temporary
ExecStart override was removed, and its operator grant revoked and local
credential file deleted. A separate read-only check confirmed inactive state
and both files absent. Test receipts and dedicated build artifacts remain.
Production and Hermes remain untouched; old-agent still has the earlier
companion. The complete native matrix, live Orb verification, ChatGPT recovery,
remote/client board support, production cutover and observation remain gates.

### Subsequent local validation (2026-09-27)

Native runtime entry points now reject an absent or blank authenticated owner
before workspace preparation or launch. Offline config generation still permits
an absent owner. No fallback identity is invented. The dedicated regression test
passes on macOS, and all 101 dispatch-admission tests pass on Linux with this
guard. This change is not yet in the installed build17 binaries.

A real standalone Gemini 0.61.0 attempt on macOS failed with
`UNSUPPORTED_CLIENT`, matching Core's Google OAuth failure. It produced no tool
result. Its temporary executor grant was revoked and the local credential file
deleted. Gemini remains unvalidated; this is not evidence of working MCP access.

The macOS admission suite exposed attachment-path failures that do not occur on
Linux: traversal rejected Apple's `/var` and `/tmp` system aliases, and folder
enumeration depended on Linux `/proc/self/fd`. The local correction recognizes
only the exact root-owned Apple aliases into `/private` and uses `fdopendir` on
macOS. Workspace symlinks remain forbidden, including ancestor replacement
attacks; traversal remains attached to open directory descriptors and bounded by
the existing file/count/depth limits. Post-fix validation passes: 15 attachment
tests on macOS, 14 on Linux, and all 101 dispatch-admission tests on macOS
(including the three that failed before the path correction). Formatting and
diff whitespace checks pass. These backend changes do not constitute live Orb
app verification and have not replaced the installed build17 binaries.

## Live validation checkpoint — 2026-09-27

Gemini live validation is waived by the operator. Production cutover and
commit/push remain pending.

- Orb native integration: Codex, Claude, OpenCode and Grok completed real MCP
  identity/capability calls and resumed the same native session with a remembered
  marker. These are native integration tests, not rendered UI acceptance tests.
- Linux library suite: 2,668 passed, zero failed, six ignored (build 20).
- Remote Codex on old-agent reached the canonical Core OAuth account through
  the native Responses proxy and completed its MCP call. A spurious native
  goal-cleared event then marked this ordinary turn blocked; the Python helper
  fix passes six protocol tests but still needs a rebuilt live retest.
- ChatGPT's existing Core profile is authenticated. A direct browser probe
  reaches the composer without sending a message. Empty bootstrap pages had
  incorrectly been reported as authentication failure. Driver tests cover the
  corrected transport classification. Explicit service launch-mode plumbing is
  being validated; a probe is not yet a completed cloud lifecycle.
- Orb xAI re-authentication exposed an obsolete CLIProxy flag. The installed
  CLI advertises `-xai-login`; the corrected mapping passes its unit tests.
  Remote native Grok authentication remains unvalidated.
- Production binaries/configuration and the single ChatGPT test profile have
  private rollback copies. No production cutover has occurred.

Build 22 follow-up: old-agent Codex mission
`c2a0d0fc-cc42-4529-81c8-f759e0e49f81` now completes normally, with the
expected MCP tool call and no health errors. ChatGPT mission
`3b9a4aad-a11e-4e82-a76b-2025f4d44a45` completed its first response and,
after restarting the isolated service, completed a follow-up in the same
external conversation `/c/6ab8be53-412c-83eb-854b-0c3c17ff90a2`. The follow-up
recalled the original marker without receiving it again. Replaying the same
follow-up action key returned the original receipt; the execution has exactly
two turns. This validates existing-profile authentication, conversation
continuity and action deduplication, not token accounting (usage is unavailable
from this connector), artifact downloads, or all recovery conditions.

## Production deployment — 2026-09-27

Core build 23 was installed through `/api/system/deploy` (source snapshot
`9cb1528736f8`). The existing guard counted a desktop-owned Orb turn as a
server turn; the operator verified that all active missions were client-owned
and no native harness process ran on Core before using the guarded override.
Orb continued reporting healthy activity after the restart.

The backend and MCP installed hashes match the Linux build. Hermes migrated
to `/usr/local/bin/sandboxed-mcp`, with a scoped coordinator credential and
57 advertised tools, and was restarted. Both its loopback readiness check and
the public HTTPS MCP check pass. The three coordinator skills were installed.
The executor companion is installed on Core, Ashur, Babylon, Nippur,
old-agent and Spark (native ARM build); each exposes 20 executor tools.

ChatGPT `launch_mode=direct` is persisted through the production configuration
API. The profile health probe now reports all 12 pool profiles healthy (only
the primary profile was re-probed during this deployment). Production canary
`98f2e5f6-8c1d-44b1-9bd0-d87c957ba9c3` completed two turns in the same external
conversation, recalling the first-turn marker; replaying the follow-up key
returned the same action. This is not a token-accounting or full pool load test.

A subsequent native canary exposed an admission defect: cloud conversations
were incorrectly considered native workspace occupants. A targeted regression
fix excludes the three cloud backend kinds while retaining native occupancy
protection; final patch validation/deployment is recorded below when complete.

Final server patch: build 24 / source snapshot `fe08605a12c4` deployed through
the guarded endpoint. Both cloud-exclusion and native-occupancy regression
tests passed. Installed backend SHA-256:
`f5e2b58ab1b4319b5b5c9ce1369b2024ab09157b4d0ba5531a2df166df404d74`.
Hermes was restarted again and its 57-tool scoped readiness check passed.
All seven registered node endpoints remained online (Spark compute/admin share
the ARM companion).

Production native canary `c64af238-2e9f-4882-81e6-d20bdfdb1a44` on old-agent
completed both initial and post-restart turns, each with a real MCP call and
the expected mission identity; the health report contains no recent errors.
Rejected preflight attempts were explicitly reconciled as rejected, not replayed
as uncertain submissions. Rollback artifacts remain under
`/var/backups/sandboxed-sh/unified-mcp-prod-20260927` on Core.

The ChatGPT production canary also completed its third turn after the final
Core restart, preserving the same external conversation and recalling the
original marker. Temporary operator testing credentials were revoked after
saving the final receipts. This completes the server deployment checkpoint;
packaged Orb rollout, Git publication and the broader remaining gates above
are not claimed complete by this checkpoint.
