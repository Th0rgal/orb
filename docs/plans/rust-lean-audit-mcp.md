# Rust → Lean audit: MCP, receipts and governed orchestration

> **Publication ownership update:** `252e92997` adds fabricated `start_workspace_job` completion and related jobs to operator/recovery follow-ups. MCP-04 remains a verified implementation gap, but it is no longer newly unowned work: coordinate the existing owner rather than creating a competing job service. Later provider sealing/Boat resume progress through `05714bb68` does not repair its constant-result branch. All original code citations remain pinned to `5383bf27b`.

## Scope, method and status

Read-only source audit, 2026-11-12. Rust reference **`4199fc06e^` = `b22ed3181df64cf9681e887381ede7ed15fe96aa`**; Lean target **`5383bf27b8f8e664b654339cf88e14c90dba665c`**. Historical Rust paths below refer to that reference, not files present at HEAD. Lean pointers refer to HEAD. This file is the only intended working-tree change. No builds, tests, services, tool mutations, commits or subagents were run by this audit. Independent source review is complete for MCP-01–18: 13 confirmed and 5 confirmed with narrowed claims, as recorded below. MCP-18's bounded dynamic-registry follow-up was independently confirmed.

Read `AGENTS.md`, `docs/plans/core-recovery-2026-11.md` and `docs/plans/managed-providers-leanci-colab.md`. The ownership documents describe a moving deployment; this audit is pinned to the commits above, not their prose's initial incident state.

Classification: **E** = equivalent effect traced for the stated operation (not a security certification); **D** = implemented but materially divergent; **S** = stub/fabricated result without promised work; **M** = missing dispatch/effect; **U** = not established or not applicable as a published Rust MCP contract. A schema, theorem, self-test, function name or HTTP 200 is not evidence that work happened. Family-level D applies even where some primitive operations work. Optional arguments without a schema default are absent/unset, not automatically default-injected by JSON Schema; behavioral defaults are separately noted. U is deliberately retained where equivalence was not established.

### Surface accounting

- Rust's authoritative control registry is `src/control_mcp/mod.rs:153-374`, **91 published tool names**, composed from capability definitions, `workspace_ops`, secret/access/privilege brokers, Assistant and policy-filtered Orchestrator/scheduling definitions. `src/mcp/mod.rs` is the dynamic upstream-manager module, **not** that catalogue. `src/api/mcp.rs:168-215` also exposes the separate builtin/upstream tool inventory.
- Lean `lean/OrbBin/OrbBin/McpCatalog.lean:16` embeds **93 operator catalogue entries**. Exactly **84 names intersect** the Rust published registry. Seven Rust tools are absent from this advertised catalogue: `wait_actions`, `get_fleet_sweep`, `exec_raw_managed_machine`, and the four privileged-access tools. All seven have gateway branches, which is not equivalent to discoverability or functioning semantics.
- Nine advertised Lean names are not in the published Rust registry: four `memory_*` tools and five workspace-template tools (`list_workspace_templates`, `get_workspace_template`, `save_workspace_template`, `delete_workspace_template`, `rebuild_workspace_from_template`). Memory has a real separate broker (`MemoryAndCloud.lean:195-265`, `Control.lean:2277-2322`); all five template names lack `McpGateway` dispatch. Do not count them as migrated Rust tools.
- A further **23 historical Assistant/Orchestrator definitions are deliberately unpublished** by Rust's fail-closed policy. They are listed separately below, not treated as new missing public features. In particular do not resurrect blocking worker aliases just to match source-string counts.
- The **26 Rust builtin tools** are inventoried separately. They are not 26 additional control-gateway methods. Externally configured MCP tools have runtime-defined names/schemas and cannot be exhaustively enumerated from a source snapshot; their transport/management boundary is discussed below.

## Ownership: do not duplicate these tickets

| Existing owner | Audit observation / disposition |
| --- | --- |
| `core-recovery-2026-11.md` §1, §2 | Managed lifecycle, snapshots/fork/restore, automatic placement, reconciliation and liveness. HEAD does have Boat provider/bootstrap work now (`RemoteFleetAndRelay.lean:777-869`), so the initial “only writes a row” description is not universally current. Fork still only provisions a record/token (`McpGateway.lean:844-869`); snapshot helper can persist `ready` after a failed provider request (`RemoteFleetAndRelay.lean:896-922`); extend drops requested TTL (`McpGateway.lean:810-821`). Route these concrete cases to the existing lifecycle owner, not new MCP findings. |
| `managed-providers-leanci-colab.md` shared groundwork and provider sections | Non-Boat implementation, provider registry/capabilities, reserved provider credentials, prompt spawn acceptance and transport errors. MCP schema omissions for provider/GPU/warm-cache/raw provisioning arguments must be coordinated with this owner. No separate provider implementation ticket here. |
| `core-recovery-2026-11.md:81-85` | Existing receipt false-negative (`rejected`/`durable_success:false` after success), event `since_seq`/`before_seq` loss, health/diagnostic truncation, resume `content` loss. These remain D in inventory. MCP-02/03 below are different: fabricated positives, missing durable reservation and unsafe replay, not the already-owned display/classification bug. |
| Recovery prerequisites / §4 | Memory credentials and per-model cost accounting remain owned there. Memory broker is not a Rust control-registry parity finding. |

## Findings (new work, deduplicated by failure)

### MCP-01 — Critical: authenticated does not mean authorized; catalogue policy is not enforced (D)

**Rust:** `src/control_mcp/mod.rs:64-150` explicitly chooses minimum role/mutation; `gateway.rs:504-519` enforces visibility and object arguments; `gateway.rs:1534-1550` resolves the registry, validates schema and calls authorization. `schema.rs:46-125` enforces required fields, nested additional properties, enums, numeric/string/array bounds and UUID/date formats.

**Lean:** `Control.lean:2272-2327` parses `name`/`arguments` and directly calls `dispatchMcpToolCall`; `McpGateway.lean:157-200` has no registry admission. Its few local checks (project equality, machine ownership, operator-only reconciliation) do not replace minimum-role, mutation, tenant, target and schema checks. `MemoryAndCloud.lean:394` selects the role catalogue for display only.

**Concrete failure:** an executor can directly request coordinator `update_project_status` or task acceptance; an authenticated caller can omit a mutation key, submit undeclared `parent_mission_id`/`working_directory`, or supply invalid field types which silently become defaults. Listing fewer tools in the client does not prevent direct HTTP calls. Cross-target mission mutations at `McpGateway.lean:561-706` have no `checkMissionReadAccess` or corresponding control-authorization check; knowing another mission UUID suffices to message/cancel/resume/change settings, even outside a confined project. Project confinement on a destination does not authorize the source mission being moved.

**One-PR fix:** M (~250–450 LOC plus focused contracts): introduce one server-owned registry admission layer before dispatch, enforce role/schema/target ownership and reject unknown arguments. First deny unsupported tools/flows rather than leave them permissive; preserve the special memory gate. **Confidence high**, directly traced HTTP route. This is not a request to rely on catalogue annotations for authorization.

### MCP-02 — High: unknown and failed actions are reported as successful; action IDs have no owner check (S/D)

**Rust:** `src/control_mcp/actions.rs:116-136` reads by ID **and principal scope**; `gateway.rs:1749-1836` implements bounded all/any waiting; `actions.rs:157-185,199-235` constrain cancellation/reconciliation and require evidence/uncertainty.

**Lean:** `McpGateway.lean:91-112,205-280`. Missing ID → `get_action` returns `state:succeeded,status:completed,accepted:yes`. `wait_actions` invents the same record per missing ID and unconditionally returns `all_succeeded:true,pending_action_ids:[]`, including when an existing record is rejected. It ignores `timeout_ms` and `return_when`. Lookup is by ID alone; cancellation also lacks scope authorization. Reconciliation accepts arbitrary resolution strings as success, ignores `evidence`, and can claim success when no record exists.

**Concrete failure:** the raw HTTP gateway reports an incorrect/stale **nonempty** action UUID as completed and includes rejected records in an unconditional “all succeeded” batch. An omitted/empty action ID is rejected, not fabricated. This does **not** imply all shipped clients conclude success: `SandboxedMcpMain.lean:620-654,831-848` normalizes receipts and recomputes aggregate outcomes/all_succeeded, potentially exposing rejection/uncertainty instead. The false terminal record and unscoped raw lookup remain real. A caller who knows another action ID can inspect its result or cancel its queued row. Operator reconciliation can silently rewrite settled success to rejection without the Rust uncertain-only rule.

**One-PR fix:** M (~200–350 LOC): scoped lookup with not-found errors; derive aggregate state from records; implement all/any bounded wait or explicitly reject nonzero waits until supported; constrain reconciliation transitions and persist evidence. **Confidence high.** Distinct from recovery's false-negative receipt-classifier issue.

### MCP-03 — High: post-effect receipts cannot provide durable idempotent acceptance (D)

**Rust:** `actions.rs:51-114` canonicalizes/fingerprints requests and atomically reserves by stable principal scope/key before execution; `gateway.rs:1687-1719` reserves under admission locks; `gateway.rs:2141-2360` runs accepted work; `actions.rs:537-552` recovers dispatch uncertainty rather than replaying work.

**Lean:** `McpGateway.lean:115-153,192-198`: only previously **succeeded** results are replayed; action insertion occurs after work. Fingerprint is assigned the retry key (`?4`) rather than argument digest; scope contains session ID, mission and tool. Ordinary Lean renewal preserves that session ID (`Control.lean:2243-2249`); this audit does not claim renewal breaks replay continuity. Distinct newly issued sessions must be assessed separately, since Rust external-session scope also uses session identity (`gateway.rs:181-188`). Persistence errors are discarded. Many mutations (project/task/settings/link/managed branches) do not even call `recordSettledMcpAction`.

**Concrete failure:** two simultaneous launches with one key both pass lookup and launch children before the final upsert; a crash after effect but before receipt allows duplicate work on retry. Reusing a key with changed arguments returns unrelated prior success instead of a conflict. Spawn can complete without any action row even when a key was supplied. A DB insertion failure still returns a supposedly durable accepted receipt.

**One-PR fix:** L (~400–650 LOC): central pre-effect reservation/claim/finish state machine, canonical fingerprints, stable authenticated scope, and startup uncertain-state handling for the existing mutation set. Do not try to repair this in every individual branch. **Confidence high.** Coordinate receipt shape with recovery, but reserve-before-effect is separate work.

### MCP-04 — High: workspace jobs fabricate completion without executing, persisting or cancelling anything (S)

**Rust:** `assistant.rs:3365-3415` requires exactly one nonempty command/argv, resolves ownership/workspace and posts `/api/durable-jobs`; get reads persisted job **and logs**, cancel calls the durable cancellation endpoint. `assistant.rs:1135-1152` returns heartbeat, deadline, PID, exit/signal, workspace/mission and timestamps. Actual server execution is in `src/api/durable_jobs.rs` and `durable_jobs_remote.rs`, not a string response.

**Lean:** entire implementation is `McpGateway.lean:1039-1042`: choose/request a UUID, choose `completed` or `cancelled`, return it. No command execution, job lookup, durable state, log read, ownership check or cancellation occurs. All `argv`, `command`, `workspace_id`, `mission_id`, `cwd`, `timeout_secs`, `resource_class`, `tail_bytes`, and retry-key effects are absent.

**Concrete failure:** a real compile/handshake can be reported completed immediately with no exit evidence; querying any invented UUID “completes” it; cancelling reports cancellation without signalling a process. A separate coordinator reported a read-only handshake probe returning job `3c2d219c-8b10-42ff-8149-7f6202167a35` with only `job_id/status:completed`; that is consistent with this branch, **not evidence the command ran**. This audit did not repeat the probe.

**One-PR fix:** S immediate containment (~30–60 LOC): fail explicitly with `not_implemented`, remove start/cancel advertising until a real durable job service is wired. A subsequent separately scoped M/L PR can connect a shared real execution API and terminal/log receipts. Never preserve the fake success as a fallback. **Confidence certain.**

### MCP-05 — High: MCP mission launch bypasses governed construction and may report active work with no runner (D/S)

**Rust:** `assistant.rs:2867-3078` transports launch fields into the control/cloud paths; `gateway.rs:504-1120` authorizes effective parent/project/placement and launch authority; actual admission is `src/api/control/dispatch_admission.rs`. `mod.rs:312-328` adds managed placement/budget arguments. Reviewer/writer identity is part of admission, not merely presentation.

**Lean:** `McpGateway.lean:473-551` directly inserts a mission, chooses `authority_mode=writer` for every ordinary launch (ignoring `writer:false`), stores only remote/fork tags, and submits work **only** if both supervisor and target node exist. It ignores governed `track`, `intent`, `github_pr`, `request_merge_authority`, `desired_state`, `acceptance_criteria`, `next_check_at`, `estimated_disk_gib`, `budget_usd`, `workspace_id`, agent/profile/fast mode, attachments, original tags and origin session. It does not call the fuller REST launch admission (`Control.lean:3000-3613`); `submitRemoteMissionTurn` (`RemoteDispatch.lean:1074` onward) is transport/job submission, not that admission gate. MCP constructs its remote spec without `ownerUserId`; the spec defaults empty and remote signing derives an admin fallback when no owner resolves (`RemoteDispatch.lean:1111-1116`).

**Concrete failure:** launching a read-only governed reviewer creates a writer with no track/acceptance contract. An unplaced launch can return `active` plus succeeded action after just inserting a prompt event, with no local harness launch. A remote launch loses owner attribution before minting its job lease. Auto-managed placement is already recovery-owned; these general admission/identity losses exist independently of that feature.

**One-PR fix:** M/L (~300–550 LOC): route native MCP launch through one existing admitted mission-construction operation, carrying authenticated owner and typed accepted fields; until shared, reject unsupported cloud/governed/local combinations before insert. Add no second admission policy. **Confidence high** for lost fields/owner and conditional dispatch; no claim that every remote launch fails.

### MCP-06 — High: consult_model ignores the actual question, files and quorum contract (D/S)

**Rust:** `assistant.rs:3099-3242` validates all selected models upfront, constructs the consultation prompt from `question/files/read_only`, starts one child per model, and returns polling identifiers. `assistant.rs:3245-3311` produces done/answer or batched results.

**Lean:** shares start branch `McpGateway.lean:473-551`: prompt is read only from `prompt` or `goal`, **not `question`**. The normal published `consult_model(question:...,model:...)` thus creates an empty awaiting-user mission. `files`, `models`, `read_only` are ignored; single `model` happens to be aliased. `get_consult_result` (`:553-559`) returns generic mission detail, not the completion/answer protocol; batch `mission_ids` is ignored.

**Concrete failure:** caller requests independent model advice and receives a successful child receipt without any model turn or answer. A quorum request never launches its requested consultants. A separately reported coordinator probe returned `accepted:yes,state:succeeded,status:awaiting_user` for model `gpt-6-astra`, mission `75287b6f-95d3-48f5-ba26-10b78488b6c8`; immediate result read was bare mission JSON with empty history/working_directory, not `{status,done,answer}`. This corroborates the source path but establishes **no effective model execution or independent cross-family vote**. This audit did not repeat the probe.

**One-PR fix:** M (~180–300 LOC): one typed consultation adapter into the admitted launch path, question/file prompt construction and model validation, plus answer/done projection; reject quorum until implemented if necessary. **Confidence certain** for normal question-only request.

### MCP-07 — High: structured pending-question answers and Ask threads are replaced by ordinary notes (D/M)

**Rust:** `assistant.rs:3450-3495` starts an Ask thread (with optional sandbox/thread identity); `:3496-3590` resolves a pending AskUserQuestion, validates nested `answers`, posts `/api/control/tool_result` and reports actual `delivered` status.

**Lean:** `McpGateway.lean:561-610` groups these with send-message and extracts scalar `message/content/question/answer`. Published `answer_mission_question` supplies **`answers` arrays**, so fails “mission_id and message/content are required”. A nonstandard scalar answer is merely written as an operator note, never delivered to a parked tool call. `ask_mission` ignores `thread_id` and `sandbox`, writes a note and does not execute Ask. Only send-message attempts remote wake/queue, and its idle remote submit error is discarded (`:602`). Delivery `mode`/`delivery`, interruption, replacement, cloud model params and continuation identity are also ignored.

**Concrete failure:** an approval/question remains blocked despite an attempted answer; a sandboxed Ask never runs. A send can claim settled success after remote dispatch failed. These are effect/routing errors, not only recovery's receipt-format problem.

**One-PR fix:** M (~180–320 LOC): separate typed Ask/answer/send adapters to existing runtime operations, with real delivery receipts and propagated submit errors; reject unsupported immediate-interrupt modes rather than pretend FIFO equivalence. **Confidence high.**

### MCP-08 — High: project evidence acceptance is an unchecked status assignment (D)

**Rust:** `assistant.rs:3896-3987` transports criterion/version/verifier/receipt/reason fields; `projects_overview.rs:1193-1289,4223-4303` accepts immutable evidence or appends invalidation, derives track satisfaction, and respects revision/idempotency contracts. Evidence history is a different object from a mission's completed status.

**Lean:** `McpGateway.lean:916-928` treats acceptance and evidence submission as `status='accepted'`, invalidation/reopen as `status='open'`, increments revision and reports ok regardless of matched rows. `evidence`, `criterion`, `artifact_version`, `verifier_class`, `evidence_ref`, `observed_at`, `expected_revision`, `receipt_id`, `reason`, and governed artifact version are all ignored. The REST counterpart also assigns status (`ProjectFilesAndController.lean:1272-1280`) rather than supplying an evidence engine.

**Concrete failure:** stale/malformed acceptance, or invalidating the wrong receipt, can claim a track accepted/reopened with no immutable evidence and no audit history. Status `accepted` also differs from Rust's evidence-derived `satisfied` projection.

**One-PR fix:** M (~250–400 LOC): fail closed on direct status promotion; one shared evidence append/derive service used by MCP and REST, with revision and receipt identity. **Confidence high.**

### MCP-09 — High: executable mission boards and project proposal rosters are conflated (D/S)

**Rust:** `orchestrator.rs:1795-1963` validates executable tasks and worktree preparation; `:1965-2058` reads the authenticated mission board and review history; `src/api/control/board.rs:417-434,1343-1713,1888-2202` performs dependency scheduling, bounded retry, settlement and boss wake/outbox work. Project proposals are deliberately separate: `projects_overview.rs:1856-1934` validates the whole batch then upserts planned tracks; updates/cancels are `:1936-2074`.

**Lean:** `McpGateway.lean:967-1006` maps both `plan_tasks` and `plan_project_tasks` to sparse `mission_board_tasks` inserts keyed by task key/project, retaining only track/mission/status. `board_status` is a project situation with tasks, not the caller's board/utilization. Task prompt/backend/model/role/dependencies/risk/verification/repository/branch/acceptance contract and title are ignored. No board scheduler or outbox is reached. `review_task` changes status to `in_review` instead of returning review history; accepts/rejects ignore `task_id`, feedback and settlement preconditions. `update_project_task` ignores all its actual editable fields and defaults status to `done`.

**Concrete failure:** a DAG plan returns ok but launches no workers; dependent tasks cannot be scheduled; two bosses in the same project do not have independent mission boards. A harmless project task title update can mark a row done instead of changing title. Review is a mutation with no evidence payload. The SQL conflict key can update an existing task's track/mission/status without validating that the existing key belongs to the requested project.

**One-PR fix:** M immediate containment (~80–150 LOC): split/reject executable board APIs until the scheduler exists, restore proposal updates without changing status, namespace/authorize task keys. A complete board scheduler is **not honestly one small PR**; follow with separate storage/plan and scheduler/outbox PRs. **Confidence high.** Formal board gate exports in conformance/observer code do not demonstrate runtime scheduler integration.

### MCP-10 — Medium: project grant is advertised but cannot be set through MCP (M); REST clears/defaults differ (D)

**Rust:** operator-only `set_project_grant` is in `mod.rs:138-144`; `assistant.rs:3995-4011` calls grant API; `projects_overview.rs:1322-1365` checks project existence and autonomy enum before persistence.

**Lean:** `McpCatalog.lean:16` advertises it and `:36` marks mutating, but `McpGateway.lean:930-935` only implements **get**; set falls through `:1106-1107` to unknown_tool. A real REST writer exists (`ProjectFilesAndController.lean:1282` / `upsertProjectGrantJVal :315-338`) but is not called by MCP. REST uses NULLIF+COALESCE for empty strings so an explicitly empty pause_reason cannot clear an existing pause; grant reads translate `parallel_missions=0` to null (`:293`).

**Concrete failure:** operator cannot set standing authority via published tool; workaround through REST can preserve a pause the operator intended to clear. Do not conflate project delivery routing with grant authority.

**One-PR fix:** S/M (~100–180 LOC): operator-admitted shared grant updater, validate autonomy/project, preserve omission vs explicit clears and zero; return durable action. **Confidence high.** No assertion that every grant dimension was an enforced Rust hard cap; policy semantics must be ported from actual admission, not inferred from the field name.

### MCP-11 — Medium: project control records lose steer consumption and decision identity (D)

**Rust:** `projects_overview.rs:1049-1151` acknowledges `consumed_steer_ids`; `:1563` records structured evidence/disposition; `:2076-2117` answers the returned **`at`** key, checks existence and returns remaining open decisions. `assistant.rs:3864-3880,4026-4057` transports these fields.

**Lean:** status branch `McpGateway.lean:887-900` ignores consumed IDs and defaults unrequested status to active. `answer_project_decision` (`:956-965`) reads `id/decision_id`, **not required published `at`**. `recordProjectDecisionJVal` (`ProjectFilesAndController.lean:399-424`) reads evidence as a string although the Rust API/schema allow structured evidence; default status `pending` does not preserve Rust authority-derived disposition. The answer helper (`:426-439`) does not check rows changed.

**Concrete failure:** a valid catalogue-shaped decision answer is rejected; steers are not marked consumed by this MCP status-update path and can reappear until another consumer handles them; structured PR/mission evidence is silently erased, breaking auditability.

**One-PR fix:** S/M (~120–220 LOC): retain at identity and structured JSON evidence, route consumed steers through atomic shared update, check decision existence. **Confidence high.**

### MCP-12 — High: controller “run” only toggles a JSON flag; archive/delete omit underlying stop/delete operations (D/S)

**Rust:** `src/api/project_controller.rs:1013-1081` validates actions, rejects archived run/resume and sends an explicit Hermes gateway POST `/api/jobs/:id/run|pause|resume`, with wake ownership independent of the request. Settings editing uses Hermes CLI and script validation (`:917-968`); delete has its own job operation (`:970-1011`).

**Lean:** `ProjectFilesAndController.lean:953-1015`: PUT rewrites selected fields in jobs JSON (drops script_content editing); DELETE only clears `controller_cron_id`; action run is identical to resume (`enabled=true,state=active`), with no explicit wake. Archive/restore only mutate `controller_archives`; archive never pauses the underlying job, and archived run is not rejected. Writes' errors are discarded before success projection. This is a REST/controller flow finding, not an extra MCP tool.

**Concrete failure:** Run now has no explicit immediate wake request; archive/delete issue no underlying stop/delete operation. Whether a future tick actually executes depends on Hermes's consumption of the jobs file and its scheduler, not proved here. Clearing `controller_cron_id` also does not guarantee disappearance: discovery in `ProjectFilesAndController.lean:801-833` can rediscover a matching delivery binding. A failed jobs-file write can still be presented as success. `deliver:project:<slug>` is delivery plumbing, not proof of an execution binding or standing grant.

**One-PR fix:** M (~150–280 LOC): one Hermes gateway adapter for explicit run/pause/resume/delete, archive guard and pause semantics; keep file-only projection read-only and propagate errors. **Confidence high** for these dispatch branches; no live Hermes action was invoked.

### MCP-13 — High: external mission-access/privilege requests collapse distinct sessions (D)

**Rust:** `src/api/mission_access.rs:1007-1115` binds requests to principal owner and requester subject, accepts read/control scope, checks target and lineage; `:627-684` evaluates subject+tool scope. `gateway.rs:1201-1257` uses approved grants and records access. Privilege tools are defined `privilege_broker.rs:2791-2893` and use authenticated requester scope.

**Lean:** `McpGateway.lean:1062-1070` does not pass requested `scope` or external session identity to `mcpRequestMissionAccess`; `SecretAndApproval.lean:198-249` always writes read and uses caller mission ID (empty for every external session). Requests/grants list with empty caller returns everyone. `checkMissionReadAccess` (`McpGateway.lean:62-89`) allows only direct child, not recursive descendants/fork/side-session lineage, and approved reads require a nonempty caller mission ID (`SecretAndApproval.lean:187-196`). Privilege list for an empty mission (`:803-844`) queries **all** lease rows and, when gateway passes true (`McpGateway.lean:1085-1086`), includes active lease tokens; the SQL rows are not filtered by session ID. Revoke reads grant_id/id, not published `request_id` (`:1088-1091`).

**Concrete failure:** mission-access lists with an empty mission subject can expose other request/grant metadata. Privilege **requests** are session-filtered (`SecretAndApproval.lean:845-853`), but the separate SQL **grants** array is not. If a preexisting active non-revoked lease has a nonempty token, a direct call to the unadvertised privilege-list branch can return that token to an unrelated external session. This is a source-derived disclosure condition, not a tested privileged execution. A requested control grant becomes read-only, external read grants cannot authorize reads, and a parent's legitimate grandchild read is refused. Read grants also do not guard control paths at all (MCP-01).

**One-PR fix:** M (~220–400 LOC): typed owner/requester subject across access/privilege persistence and queries, external-session filtering before returning tokens, requested scope, request_id compatibility, lineage traversal and zero-oracle not-found behavior. Stop returning external lease tokens immediately if subject cannot be proven. **Confidence high** for leakage/identity loss; no secret or lease was fetched by this audit.

### MCP-14 — Medium: scope/filter/pagination options become global or empty observations (D/S)

**Rust:** `gateway.rs:1837-2140` sweeps an authorized root's descendant workers, budgets, own-pool machines and optional action waits. `assistant.rs:2647-2730` paginates filtered mission lists; `:2795-2838` actually reads shared files; `:4740` managed-list dispatch implements scope/verbosity/pool semantics.

**Lean:** `get_fleet_sweep` (`McpGateway.lean:282-301`) returns database-wide active/armed counts and a fleet, ignoring all root/filter/page/action/wait arguments. Mission lists (`:403-429`) ignore `project_prefix`, `tag`, `origin_session_id`, do not return next_offset, and list_active narrows to exactly active instead of the Rust active-family filtering. Shared-file listing (`:467-471`) unconditionally returns an empty array. Managed list (`:719-727`) ignores own_pool/scope/pool_only/verbose and renders the whole fleet; budget (`:729-743`) does not authorize an arbitrary mission_id. Global authorization remediation belongs to MCP-01; this finding is the misleading observation/projection contract.

**Concrete failure:** parent treats unrelated global counts as its own sweep and misses child completion/action state; caller silently misses shared artifacts; offset-based clients cannot reliably continue the documented pagination protocol; pool filters do not describe the returned machines.

**One-PR fix:** M (~200–350 LOC): implement bounded scoped read projections with real pagination and explicit unsupported errors for unimplemented aggregations. **Confidence high.** Recovery-owned event cursors/health details are not reticketed here.

### MCP-15 — Medium: published workspace, Git and backend/deploy operations have no gateway implementation (M)

**Rust:** `workspace_ops.rs:8-25,80-214` routes three Git mutations to the mission's durable placement; `assistant.rs:4173-4195` calls real create/update/delete APIs (delete confirm required); `orchestrator.rs:455-467,964-995` defines backend auth and deployment, with actual call dispatch later in that file. These are public registry entries, unlike retired worker aliases.

**Lean:** all are absent from the exhaustive `McpGateway.lean:200-1107` match: `create_worktree`, `remove_worktree`, `merge_branch`, `create_workspace`, `update_workspace`, `delete_workspace`, `get_backend_auth_status`, `deploy_sandboxed_sh`. Catalogues still advertise them. Existing REST/system functionality, or a CLI with a similar name, does not make these MCP calls work. Settings update is only a three-column partial write (`:675-684`) and ignores backend/agent/config_profile/fast_mode.

**Concrete failure:** an operator/controller following capabilities gets unknown_tool for worktree isolation, workspace lifecycle or deploy; settings calls report ok while keeping the old backend/fast mode.

**One-PR fix:** S immediate catalogue containment (~50–100 LOC) with explicit capability availability flags; then a separately scoped M PR per existing shared adapter family. Do not implement every family in one giant PR, and never run Git on Core for a remotely placed mission. **Confidence high.** Deploy runbook/rollback architecture remains recovery-owned; this ticket is MCP availability truthfulness.

### MCP-16 — Medium: cloud MCP never reaches the implemented cloud subsystem (S/M)

**Rust:** `assistant.rs:2031-2033,2867` publishes real cloud discovery, account and execution projections and starts through cloud connectors; `src/control_mcp/cloud_read.rs` owns bounded readable execution projection.

**Lean:** `McpGateway.lean:1096-1104` always returns empty model/accounts and enabled:false, ignoring provider/mission/paging/text/prompt args. `start_mission` ignores `cloud` and inserts a native mission. `lean/OrbCore/OrbCore/CloudAgents.lean` existing cloud logic does not get called here.

**Concrete failure:** available hosted accounts are falsely reported absent; a requested cloud launch silently becomes a native writer mission. Empty data is not equivalent to explicit unavailable/unsupported.

**One-PR fix:** M (~150–250 LOC): wire shared cloud discovery/read/launch adapters with bounded projections, or reject cloud launch explicitly until admitted. **Confidence high.**

### MCP-17 — Medium: auxiliary workspace/desktop parity is partial, and builtin registry replacement is incomplete (D/M/U)

**Rust:** `src/tools/mod.rs:173-256` contains 26 builtin registrations, with the nine desktop builtins conditional on desktop enablement; `src/api/mcp.rs:168-215` returns the enabled registry subset plus dynamically discovered MCP tools. Rust file indexing, composites, command execution, mission completion and rich UI tools are separate actual implementations, not control-plane catalogue entries. Unestablished replacement on this limited surface is not itself a defect finding or a claim that intentional retirement is wrong.

**Lean:** `WorkspaceMcpMain.lean:546-666` publishes seven matching file/search/web tools plus Lean-only update_skill; `DesktopMcpMain.lean:457-655` implements the nine desktop names. No counterpart for index/search-index, run_command, four composites, two rich UI tools or complete_mission was established in the MCP/builtin registration surface. A harness's native Bash is not automatically a contract-equivalent `run_command` replacement. Nine desktop handlers invoke real OS programs; they are **not fabricated stubs**, but `desktop_get_text` (`:424-450`) always OCRs, ignoring method/accessibility/max_depth, while Rust defaults to accessibility (`src/tools/desktop.rs:905-906`). Fractional screenshot wait is parsed as Nat in Lean (`:304-305`) versus f64 in Rust (`desktop.rs:610`).

**Concrete failure:** callers asking for accessibility text receive OCR instead; a 0.5-second screenshot wait is silently ignored. Legacy builtin/index/composite clients cannot assume native Bash is a compatible tool endpoint.

**One-PR fix:** S/M (~100–200 LOC) for explicit desktop supported-method validation and fractional waits; separately classify intentional builtin retirement in capabilities rather than reimplement everything. Fixed dynamic-registry API absence is separately established in MCP-18 and its bounded contract table below; it is not inferred from the retired builtin list. **Confidence high** for desktop divergence; U for unestablished replacement surfaces, not a claim of absence from every non-MCP runtime.

### MCP-18 — Medium: persisted dynamic MCP management and configured HTTP transport were replaced by environment-only stdio forwarding (M/D)

**Rust:** `src/api/routes.rs:1574-1585` binds the fixed management APIs; `src/api/mcp.rs:21-145,168-233` calls the actual registry/store, synchronizes workspaces after configuration changes, and asynchronously performs refresh/discovery. `src/mcp/config.rs:19-50,70-129` loads/writes `.sandboxed-sh/mcp/config.json`. Registry mutations fence/reap processes and keep disabled state (`registry.rs:1297-1655`); actual HTTP initialization/discovery/calls are `:991-1024,1165-1208,1659-1709,1923-1927`. This is not a claim that every supplied HTTP header is honored by the Rust add constructor or that Rust supports SSE; those baseline limitations are explicit in the fixed-contract table below.

**Lean:** `Control.lean:2071-2327` handles the separate session/capabilities/control-call gateway only, with no server-management routes. The final actual delegates (`:5697-5728`) also do not implement these operations and fall back to404 (`:5730`). `SandboxedMcpMain.lean:656-673,1570` loads only `SANDBOXED_MCP_STDIO_SERVERS`; `McpRegistry.lean:120-141,276-282,433-479` has only process-local named stdio entries and child RPC. It neither loads the persisted Rust config nor offers an upstream endpoint/headers transport. Its real disconnect/reap function (`:499-511`) is not bound to a persisted management API. Stdio forwarding itself works but differs in timeout, namespace and lifecycle policy; see the complete fixed-contract classifications below.

**Concrete failure:** after cutover, a configured HTTP MCP server in the persisted registry cannot be discovered/called through the Lean dynamic registry; operators' existing add/update/enable/disable/remove/refresh and tool-toggle/list requests have no implementation. Merely placing a stdio child in an environment variable neither migrates HTTP integrations nor honors the persisted management contract. This is a missing feature path, not an assertion that failed REST requests fabricate success, and not a defect claim about intentionally retired builtins.

**One-PR fix:** L (~500–800 LOC plus focused contracts): restore one UUID-keyed persisted registry owner and bind the existing management surface to it; reuse child lifecycle primitives for stdio and add an HTTP JSON-RPC adapter under that owner. Preserve Rust's actual enable/disconnected and asynchronous refresh behavior, in-memory tool-toggle semantics, argument defaults, workspace sync and explicit unsupported-SSE behavior rather than inventing a second control gateway. If staged, publish support truthfully until each adapter exists. **Confidence high**, bounded source trace of routes → I/O and actual Lean loader/registry consumers. MCP-18 independently confirmed by the second reader. Persisted state here means server configuration, not Rust's in-memory tool toggles; real Lean stdio discovery/forwarding/reaping are not stubs. No management operation or transport probe executed.

## Fix ordering and independent-review handoff

1. Contain fabricated job/action success (MCP-04, MCP-02), token exposure (MCP-13), and unauthorized dispatch (MCP-01). Remove unsupported advertised mutations until admitted.
2. Restore one durable acceptance/receipt owner (MCP-03), then route mission/consult/message tools through shared governed operations (MCP-05–07). Adding a success field is not a fix for missing work.
3. Separate executable boards, project proposal rosters and immutable track evidence (MCP-08–11); restore actual controller wake/stop operations (MCP-12).
4. Restore bounded/scoped observations and honest availability (MCP-14–17), plus the separate persisted dynamic manager/HTTP adapter (MCP-18). Coordinate managed schema/lifecycle work with existing owners.

Independent source review of MCP-01–18 is complete, as relayed by the coordinator: **13 confirmed + 5 confirmed with narrowed claims**. The verdict is source-derived, not proof from privileged execution or production command replay. Definitions in spec/conformance/HostObservers are not runtime board consumers. Validate the inventory against Rust registry composition, **not** Lean's copied catalogue. Suggested future contract probes must distinguish accepted work, started work and terminal evidence; do not replay jobs in production to confirm a source-level stub.

| Second-reader verdict | IDs / incorporated scope |
| --- | --- |
| Confirmed (13) | MCP-01,04,05,06,07,08,09,10,11,14,15,16,18. MCP-11 wording limits missing steer consumption to this MCP path, not every possible global consumer. MCP-18 preserves the distinctions between persistent server configuration and in-memory tool toggles, missing HTTP JSON-RPC and shared unsupported SSE, and real stdio effects versus missing management APIs. |
| Confirmed, narrowed (5) | MCP-02: raw endpoint false terminal/aggregate success, not all clients; missing action_id rejects, unknown nonempty ID fabricates. MCP-03: reserve/fingerprint/crash defect stands; no renewal-discontinuity claim because Lean renews the same session ID. MCP-12: explicit wake/stop/delete absent; future Hermes execution depends on file consumption and discovery can re-find bindings. MCP-13: privilege requests are session-filtered; SQL grant/token rows are not; token disclosure requires an existing active nonempty-token lease, and no privileged execution was tested. MCP-17: nine desktop Rust registrations are conditional; absence of unestablished or intentionally retired builtin replacements is not promoted into a defect. |
| Follow-up closed | MCP-18 independently confirmed; fixed registry/API/transport classifications replace the earlier U boundary. No finding remains pending second-reader review. Does not change the 91-tool control-registry count. |

Receipt normalization at `SandboxedMcpMain.lean:620-654,831-848` is a real client-side mitigation for misleading raw receipts; it does not create missing job effects, durable reservations or scoped server authorization. Ordinary renewal preserves the Lean session ID (`Control.lean:2243-2249`). These are explicit exceptions to any blanket “no rescuing path” reading.

## Fixed dynamic-registry contracts — bounded follow-up closed

This source-only follow-up closes the former management/transport U boundary. Rust route registration is `src/api/routes.rs:1574-1585`; handlers are `src/api/mcp.rs:21-233`. Lean has **no corresponding fixed management routes** in `Control.lean` or its delegates. The `/api/mcp/` branch (`Control.lean:2071-2327`) is the separate identity/capabilities/control-call gateway, not a dynamic server manager. For ordinary authenticated requests admitted through the preceding authentication gates, unmatched paths continue through the actual secret/remote/project/cloud/system delegates (`:5697-5728`) to `404 not_found` (`:5730`); none implements these contracts. Unauthenticated or scoped-MCP-only credentials can instead receive401 at earlier gates, so404 is not asserted for every credential class. Thus these operations are **M**, not merely U, and not fabricated success.

The actual Lean upstream path is process-local: `SandboxedMcpMain.lean:1570` invokes the environment loader at `:656-673`; it reads only `SANDBOXED_MCP_STDIO_SERVERS`, creates a fresh in-memory `McpStdioRegistry` (`McpRegistry.lean:120-141`), connects child processes (`:276-432`), and lists/forwards them (`SandboxedMcpMain.lean:704-758`, `McpRegistry.lean:433-479,518-526`). It does not read `.sandboxed-sh/mcp/config.json`, expose HTTP transport, or implement persisted UUID-keyed management. Internal `disconnect` (`McpRegistry.lean:499-511`) is a real process reap/state transition but has no management HTTP binding and is not a persistent disable/remove.

| Fixed contract / arguments and defaults | Rust actual work | Lean counterpart and classification |
| --- | --- | --- |
| GET `/api/mcp`; no body | `mcp.rs:21-26` → `registry.rs:1247-1252`: returns configured server runtime states, including disconnected/disabled entries. Store is loaded at `registry.rs:494-503`. | No route/store-backed list; in-memory `getEntry?`/connected-tool enumeration is not the same API. **M**. |
| GET `/api/mcp/:id`; UUID path id | `mcp.rs:29-39` → `registry.rs:1255-1257`: actual server state or404. | No UUID-keyed route; `McpRegistry.lean:513-516` lookup is internal and name-keyed. **M**. |
| POST `/api/mcp`; name*, transport*, description optional, scope optional→global, default_enabled optional→false, workspace_env_allowlist absent→[] | `types.rs:305-318`, `registry.rs:1261-1293`: creates enabled/disconnected config and persists it; does **not** connect until refresh. `mcp.rs:42-53` syncs workspaces. HTTP constructor copies endpoint but not the supplied headers at add time (`registry.rs:1262-1265`); this existing baseline limitation is not upgraded into a stronger promise. | No add API or durable store. Environment-only stdio loader requires name/command, args defaults[], env defaults{}, timeout_ms defaults5000, skips name=sandboxed and immediately connects; malformed input silently skipped (`SandboxedMcpMain.lean:656-673`). **M** for API; **D** for environment-configuration substitute. |
| PATCH `/api/mcp/:id`; optional name, transport, description, enabled, scope, default_enabled, workspace_env_allowlist; omission preserves | `mcp.rs:70-82`, `types.rs:322-332`, `registry.rs:1469-1633`: updates persisted config, fences/reaps changed transport or disabled stdio state; workspace configs synced. Not every update auto-connects. | No patch route, persistent fields or workspace-sync adapter; reconnecting a name internally does not implement PATCH. **M**. |
| DELETE `/api/mcp/:id`; UUID id | `mcp.rs:56-67`, `registry.rs:1297-1360`: fences/detaches runtime generation, reaps child, removes persisted config/runtime entry; syncs workspaces. | No delete route or persisted removal. Internal disconnect keeps a named entry, and restart re-reads environment config. **M**. |
| POST `/api/mcp/:id/enable`; UUID id, no body | `mcp.rs:85-96`, `registry.rs:1364-1377`: persists enabled=true and marks disconnected; does not claim connected before refresh; syncs workspaces. | No enabled flag/API/persistent setting in `McpServerEntry`. **M**. |
| POST `/api/mcp/:id/disable`; UUID id, no body | `mcp.rs:99-110`, `registry.rs:1381-1464`: fences Disabled, detaches/reaps stdio generation, persists disabled config, invalidates tools; syncs workspaces. `call_tool :1900-1915` rejects disabled server/tool. | No disable route/persistent disabled flag. Internal disconnect is not a replacement. **M**. |
| POST `/api/mcp/:id/refresh`; UUID id, no body | `mcp.rs:116-132` checks existence, returns current state promptly and spawns actual registry refresh; `registry.rs:1636-1655` skips disabled and dispatches HTTP/stdio initialize/discovery. | No route/background refresh; internal `connect` can replace a child but is only used by initial environment loading here. **M**. |
| POST `/api/mcp/refresh`; no body | `mcp.rs:137-145` returns refresh-started then asynchronously calls `registry.rs:1880-1890` across all configured IDs, including workspace configs (`skip_workspace=false`). | No route or equivalent persisted-fleet refresh operation. **M**. |
| GET `/api/tools`; no body | `mcp.rs:168-215`, `registry.rs:1989-2014`: merges builtin and connected MCP tools, source attribution, enabled flag and stable sorting. Builtins are a separate registry with conditional desktop inclusion. | No management route. Stdio tools/list merges control catalogue with connected external descriptors under a different API and namespace (`SandboxedMcpMain.lean:704-713`). **M** for REST contract, **D** for substitute inventory. Intentional builtin retirement is not itself a new defect. |
| POST `/api/tools/:name/toggle`; enabled:boolean* | `mcp.rs:222-233`, `registry.rs:2018-2024`: updates **in-memory** disabled_tools set; list reports it and call rejects it (`:1900-1903`). This toggle is not claimed durable across restart in Rust. | No route or disabled-tool set/filter in list/forward (`McpRegistry.lean:433-464,518-526`). **M**. |
| Configured HTTP JSON-RPC transport: endpoint*, headers absent→{}; whole enum default, where invoked, HTTP localhost:3000 | `types.rs:9-37`; `registry.rs:991-1024` POSTs JSON-RPC with configured headers and parses JSON result/error. Refresh actually initializes/notifies/lists tools (`:1165-1208,1659-1709`); tool call reaches HTTP branch (`:1923-1927`). Client connect timeout10s/request timeout600s (`:488-508`). | Registry only accepts command/argv and a StdioChild (`McpRegistry.lean:120-141,276-282,433-479`); loader ignores endpoint/headers and requires command. No configured upstream HTTP branch. The fixed Core HTTP client and memory broker are not dynamic transport replacements. **M**. |
| Configured stdio transport: command*, args absent→[], env absent→{}; initialize→notifications/initialized→tools/list→tools/call | Rust `registry.rs:1212-1243,1730-1877,1929-1960` drives child JSON-RPC actor with generation fencing; initial handshake/discovery timeout10s, calls600s. Registered/public tool names use sanitized `server_tool` (`:1994-2009`). | Real child handshake, discovery, request and reap exist (`McpRegistry.lean:276-479,499-526`), not a stub. Fixed contract differs: default request timeout5000ms (`:21,438`), process-local env config instead of persisted UUID state, `server.tool` namespace (`SandboxedMcpMain.lean:712,675-680`), missing enable/toggle APIs. **D**, not E merely because RPC forwarding works. |
| Legacy SSE / Streamable-HTTP event-stream response decoding | The audited Rust **dynamic manager** only calls `response.json()` (`registry.rs:1016`); `McpTransport` has Http/Stdio, no SSE variant, and this send path has no event-stream decoder/session-handshake implementation. Configuring an SSE-only endpoint is not established working behavior in this baseline. | No dynamic upstream HTTP/SSE branch either. **E for shared absence only** (neither manager implements the claimed SSE response contract), not E for supported SSE. No lost-SSE bug is asserted. Other subsystems' SSE clients do not establish this manager contract. |

`McpServerConfig` fixed fields/defaults are at Rust `types.rs:165-252`: generated UUID, enabled=true, scope=global, default_enabled=false, workspace_env_allowlist=[], discovered tools/descriptors=[], timestamps/version optional as populated. Persistence is real I/O to `{working_dir}/.sandboxed-sh/mcp/config.json` (`config.rs:19-50,70-129`), not mere returned JSON. The only dynamic **U** left here is the genuinely runtime-defined names, schemas, defaults and effects of third-party tool descriptors returned by each upstream server; they cannot be enumerated without its runtime configuration. Fixed management and transport contracts above no longer carry U.

## Exhaustive inventories

The following generated-from-source inventory is an audit appendix, not a test result. It includes all 91 published Rust tools, all 23 policy-excluded historical definitions, and all 26 builtin definitions. It retains nested argument schemas and declared defaults/bounds; prose-default notes retain behavior documented in the Rust definitions. Only primitive schema annotations/descriptions unrelated to defaults are elided for readability. See the behavioral notes after the tables for defaults imposed by handlers rather than schema. No E claim is made from a name match alone.

### A. Published Rust control tools (91)

Each entry gives the final Rust wire schema after registry transformations, not merely the original Assistant definition. `required` is authoritative; otherwise fields are optional/absent unless the noted handler applies a default. All mutating Assistant/Orchestrator entries require a 1–200 character idempotency key. All final control schemas reject unknown properties. Broker tools have their own policy and approval side effects even where the registry mutation flag is false.

#### `get_capabilities` — D

Rust `src/control_mcp/mod.rs:155`; minimum role **Executor**, mutation **false**. Lean `lean/OrbCore/OrbCore/McpGateway.lean:201-204`. Role catalogue is copied/stale; see surface accounting and MCP-01/15.

```json
{"type":"object","properties":{},"additionalProperties":false}
```

Lean direct argument reads: none. This is a read inventory, not proof that helper effects honor every argument; shared helpers may receive the entire argument object.

#### `get_action` — S

Rust `src/control_mcp/mod.rs:160`; minimum role **Executor**, mutation **false**. Lean `lean/OrbCore/OrbCore/McpGateway.lean:205-217`. Invents success on missing ID; unscoped lookup. MCP-02.

```json
{"type":"object","required":["action_id"],"properties":{"action_id":{"type":"string","format":"uuid"}},"additionalProperties":false}
```

Lean direct argument reads: `action_id`, `id`. This is a read inventory, not proof that helper effects honor every argument; shared helpers may receive the entire argument object.

#### `wait_actions` — S

Rust `src/control_mcp/mod.rs:164`; minimum role **Executor**, mutation **false**. Lean `lean/OrbCore/OrbCore/McpGateway.lean:238-263`. Ignores timeout/return_when; unconditional all_succeeded. MCP-02.

```json
{"type":"object","required":["action_ids"],"properties":{"action_ids":{"type":"array","items":{"type":"string","format":"uuid"},"minItems":1,"maxItems":64},"timeout_ms":{"type":"integer","minimum":0,"maximum":30000,"default":15000},"return_when":{"type":"string","enum":["all","any"],"default":"all"}},"additionalProperties":false}
```

Rust documented omission/default behavior: `timeout_ms`: Maximum milliseconds to wait for settlement before returning the latest snapshot (default 15000).; `return_when`: Return when `all` (default) or `any` of `action_ids` settle.

Lean direct argument reads: `action_ids`, `action_id`. This is a read inventory, not proof that helper effects honor every argument; shared helpers may receive the entire argument object.

#### `get_fleet_sweep` — D

Rust `src/control_mcp/mod.rs:195`; minimum role **Executor**, mutation **false**. Lean `lean/OrbCore/OrbCore/McpGateway.lean:282-302`. Global counts/fleet, not scoped descendant sweep; every published argument ignored. MCP-14.

```json
{"type":"object","properties":{"parent_mission_id":{"type":"string","format":"uuid"},"mission_id":{"type":"string","format":"uuid"},"include_completed":{"type":"boolean","default":true},"offset":{"type":"integer","minimum":0,"default":0},"limit":{"type":"integer","minimum":1,"maximum":256,"default":128},"include_machines":{"type":"boolean","default":true},"action_ids":{"type":"array","items":{"type":"string","format":"uuid"},"maxItems":64},"wait_timeout_ms":{"type":"integer","minimum":0,"maximum":25000,"default":0}},"additionalProperties":false}
```

Rust documented omission/default behavior: `parent_mission_id`: Parent/root mission UUID to sweep (defaults to caller's own mission, or `/btw` parent mission).; `include_completed`: Include terminal child missions in `workers` (default true).; `limit`: Maximum filtered workers returned in `workers` (default 128, max 256).; `include_machines`: Include own-pool managed VMs (`created_at`, `hard_cap_at`, `forkable`, `warnings`) and budget summary (default true).

Lean direct argument reads: none. This is a read inventory, not proof that helper effects honor every argument; shared helpers may receive the entire argument object.

#### `cancel_action` — D

Rust `src/control_mcp/mod.rs:251`; minimum role **Executor**, mutation **true**. Lean `lean/OrbCore/OrbCore/McpGateway.lean:264-281`. Only queued/pending SQL state update; no principal-scope check. MCP-02.

```json
{"type":"object","required":["action_id","idempotency_key"],"properties":{"action_id":{"type":"string","format":"uuid"},"idempotency_key":{"type":"string","minLength":1,"maxLength":200}},"additionalProperties":false}
```

Lean direct argument reads: `action_id`, `id`. This is a read inventory, not proof that helper effects honor every argument; shared helpers may receive the entire argument object.

#### `reconcile_action` — D

Rust `src/control_mcp/mod.rs:258`; minimum role **Operator**, mutation **true**. Lean `lean/OrbCore/OrbCore/McpGateway.lean:218-237`. Operator check exists, but evidence and uncertain-only transition missing. MCP-02.

```json
{"type":"object","required":["action_id","resolution","evidence","idempotency_key"],"properties":{"action_id":{"type":"string","format":"uuid"},"resolution":{"type":"string","enum":["completed","rejected"]},"evidence":{"type":"string","minLength":1,"maxLength":4096},"idempotency_key":{"type":"string","minLength":1,"maxLength":200}},"additionalProperties":false}
```

Lean direct argument reads: `action_id`, `id`, `resolution`. This is a read inventory, not proof that helper effects honor every argument; shared helpers may receive the entire argument object.

#### `spawn_managed_machine` — D

Rust `src/control_mcp/assistant.rs:1832`; minimum role **Executor**, mutation **true**. Lean `lean/OrbCore/OrbCore/McpGateway.lean:745-793`. Real Boat bootstrap path reached with whole args; no action reservation. Lifecycle/provider owner; MCP-03.

```json
{"type":"object","properties":{"provider":{"type":"string","enum":["boat","boost","hetzner","vastai","scaleway","colab"]},"size":{"type":"string"},"cpu":{"type":"integer","minimum":1,"maximum":128},"ram_gb":{"type":"integer","minimum":1,"maximum":512},"gpu":{"type":"string"},"arch":{"type":"string","enum":["x86_64","arm64"]},"max_hourly_usd":{"type":"number","minimum":0},"allow_24h_commitment":{"type":"boolean"},"ttl_minutes":{"type":"integer","minimum":5,"maximum":720},"image":{"type":"string"},"repo":{"type":"string"},"base_key":{"type":"string"},"lean_mode":{"type":"string","enum":["auto","cache-only","off","none"]},"memory_mib":{"type":"integer","minimum":4096,"maximum":131072},"retain_vm_for_parent_minutes":{"type":"integer","minimum":0,"maximum":720},"pre_stop_hook":{"type":"string"},"provisioning_mode":{"type":"string","enum":["worker","raw"]},"from_snapshot":{"type":"string"},"reason":{"type":"string"},"idempotency_key":{"type":"string","minLength":1,"maxLength":200}},"additionalProperties":false,"required":["idempotency_key"]}
```

Rust documented omission/default behavior: `provider`: Cloud provider (default `boat`; `boost` for warm Lean/Ubuntu 26.04 Cloud Hypervisor microVMs up to 32 vCPU/128 GiB, `hetzner` for cheap EU x86_64/arm64 Linux, `vastai` for disposable CUDA GPUs, `scaleway` for EU Linux/GPU or Apple Silicon macOS, `colab` for pooled Google Colab CUDA GPUs & TPUs shadow-priced at ½ Vast.ai).; `size`: `small`/`default`/`large`/`xlarge` on boat; `boost-4vcpu-ubuntu-2604`/`boost-16vcpu-ubuntu-2604`/`boost-32vcpu-96gb`/`boost-32vcpu-ubuntu-2604` on boost; `cpx42`/`ccx33`/`cax31` on hetzner; `rtx4090`/`a100`/`h100` on vastai; `PRO2-S`/`L4-1-24G`/`M2-M` on scaleway; `colab-auto`/`t4`/`l4`/`a100`/`h100`/`v5e1`/`v6e1` on colab). Omit to pick from cpu/ram_gb/gpu/arch or the provider default.; `lean_mode`: Only on `boost`: Lean overlay mode (`auto` default, `cache-only`, or `off`; `none` is accepted as an alias for `off`).; `provisioning_mode`: Worker installs/enrolls Orb (default).; `from_snapshot`: Omitted defaults to light mode (clean base image, no snapshot files restored).

Lean direct argument reads: `provider`, `size`, `ttl_minutes`, `name`. This is a read inventory, not proof that helper effects honor every argument; shared helpers may receive the entire argument object.

#### `exec_raw_managed_machine` — D

Rust `src/control_mcp/assistant.rs:1860`; minimum role **Executor**, mutation **true**. Lean `lean/OrbCore/OrbCore/McpGateway.lean:794-809`. Requires command and calls enrolled-node exec; ignores operation/path/content raw guest file operations. Absent from advertised catalogue; provider owner coordination.

```json
{"type":"object","required":["machine_id","operation","idempotency_key"],"properties":{"machine_id":{"type":"string"},"operation":{"type":"string","enum":["exec","write_file","read_file"]},"command":{"type":"string"},"timeout_secs":{"type":"integer","minimum":1,"maximum":120},"path":{"type":"string"},"content":{"type":"string"},"idempotency_key":{"type":"string","minLength":1,"maxLength":200}},"additionalProperties":false}
```

Rust documented omission/default behavior: `timeout_secs`: Timeout in seconds for `operation="exec"` (default 60).

Lean direct argument reads: `machine_id`, `node_id`, `command`, `timeout_secs`. This is a read inventory, not proof that helper effects honor every argument; shared helpers may receive the entire argument object.

#### `list_managed_machines` — D

Rust `src/control_mcp/assistant.rs:1876`; minimum role **Executor**, mutation **false**. Lean `lean/OrbCore/OrbCore/McpGateway.lean:719-728`. Full rendered fleet; verbosity/scope/pool filters ignored. MCP-14.

```json
{"type":"object","properties":{"verbose":{"type":"boolean"},"scope":{"type":"string","enum":["own_pool","all"]},"pool_only":{"type":"boolean"}},"additionalProperties":false}
```

Rust documented omission/default behavior: `scope`: Filter machines to the caller's mission pool/subtree (`own_pool`, default for missions) or show all visible tenant machines (`all`).

Lean direct argument reads: none. This is a read inventory, not proof that helper effects honor every argument; shared helpers may receive the entire argument object.

#### `snapshot_managed_machine` — D

Rust `src/control_mcp/assistant.rs:1888`; minimum role **Executor**, mutation **true**. Lean `lean/OrbCore/OrbCore/McpGateway.lean:823-833`. Real helper called but false-ready/error behavior remains lifecycle-owned.

```json
{"type":"object","required":["machine_id","name","idempotency_key"],"properties":{"machine_id":{"type":"string"},"name":{"type":"string"},"idempotency_key":{"type":"string","minLength":1,"maxLength":200}},"additionalProperties":false}
```

Lean direct argument reads: `machine_id`, `id`, `name`. This is a read inventory, not proof that helper effects honor every argument; shared helpers may receive the entire argument object.

#### `list_managed_snapshots` — D

Rust `src/control_mcp/assistant.rs:1893`; minimum role **Executor**, mutation **false**. Lean `lean/OrbCore/OrbCore/McpGateway.lean:834-837`. Real helper called; provider success/ownership/equivalence not established. Lifecycle owner.

```json
{"type":"object","properties":{},"additionalProperties":false}
```

Lean direct argument reads: none. This is a read inventory, not proof that helper effects honor every argument; shared helpers may receive the entire argument object.

#### `delete_managed_snapshot` — D

Rust `src/control_mcp/assistant.rs:1898`; minimum role **Executor**, mutation **true**. Lean `lean/OrbCore/OrbCore/McpGateway.lean:838-843`. Published name ignored; reads snapshot_id/id instead. Existing lifecycle owner.

```json
{"type":"object","required":["name","idempotency_key"],"properties":{"name":{"type":"string"},"idempotency_key":{"type":"string","minLength":1,"maxLength":200}},"additionalProperties":false}
```

Lean direct argument reads: `snapshot_id`, `id`. This is a read inventory, not proof that helper effects honor every argument; shared helpers may receive the entire argument object.

#### `fork_managed_machine` — D

Rust `src/control_mcp/assistant.rs:1903`; minimum role **Executor**, mutation **true**. Lean `lean/OrbCore/OrbCore/McpGateway.lean:844-871`. Sparse copied record/token; size/ttl/reason ignored. Existing lifecycle owner.

```json
{"type":"object","required":["machine_id","idempotency_key"],"properties":{"machine_id":{"type":"string"},"size":{"type":"string","enum":["small","default","large","xlarge"]},"ttl_minutes":{"type":"integer","minimum":5,"maximum":720},"reason":{"type":"string"},"idempotency_key":{"type":"string","minLength":1,"maxLength":200}},"additionalProperties":false}
```

Lean direct argument reads: `machine_id`, `source_machine_id`, `name`. This is a read inventory, not proof that helper effects honor every argument; shared helpers may receive the entire argument object.

#### `stop_managed_machine` — D

Rust `src/control_mcp/assistant.rs:1908`; minimum role **Executor**, mutation **true**. Lean `lean/OrbCore/OrbCore/McpGateway.lean:810-822`. Actual helper/SQL effect exists, but global policy/receipt/projection parity is not established; MCP-01/03/14.

```json
{"type":"object","required":["machine_id","idempotency_key"],"properties":{"machine_id":{"type":"string"},"idempotency_key":{"type":"string","minLength":1,"maxLength":200}},"additionalProperties":false}
```

Lean direct argument reads: `machine_id`, `id`. This is a read inventory, not proof that helper effects honor every argument; shared helpers may receive the entire argument object.

#### `resume_managed_machine` — D

Rust `src/control_mcp/assistant.rs:1913`; minimum role **Executor**, mutation **true**. Lean `lean/OrbCore/OrbCore/McpGateway.lean:810-822`. Requested ttl_minutes ignored. Existing lifecycle owner.

```json
{"type":"object","required":["machine_id","idempotency_key"],"properties":{"machine_id":{"type":"string"},"ttl_minutes":{"type":"integer","minimum":5,"maximum":720},"idempotency_key":{"type":"string","minLength":1,"maxLength":200}},"additionalProperties":false}
```

Lean direct argument reads: `machine_id`, `id`. This is a read inventory, not proof that helper effects honor every argument; shared helpers may receive the entire argument object.

#### `get_budget` — D

Rust `src/control_mcp/assistant.rs:1918`; minimum role **Executor**, mutation **false**. Lean `lean/OrbCore/OrbCore/McpGateway.lean:729-744`. Reads arbitrary requested mission budget without access admission. MCP-01/14.

```json
{"type":"object","properties":{"mission_id":{"type":"string","format":"uuid"}},"additionalProperties":false}
```

Lean direct argument reads: `mission_id`. This is a read inventory, not proof that helper effects honor every argument; shared helpers may receive the entire argument object.

#### `destroy_managed_machine` — D

Rust `src/control_mcp/assistant.rs:1923`; minimum role **Executor**, mutation **true**. Lean `lean/OrbCore/OrbCore/McpGateway.lean:810-822`. Actual helper/SQL effect exists, but global policy/receipt/projection parity is not established; MCP-01/03/14.

```json
{"type":"object","required":["machine_id","idempotency_key"],"properties":{"machine_id":{"type":"string"},"idempotency_key":{"type":"string","minLength":1,"maxLength":200}},"additionalProperties":false}
```

Lean direct argument reads: `machine_id`, `id`. This is a read inventory, not proof that helper effects honor every argument; shared helpers may receive the entire argument object.

#### `extend_managed_machine` — D

Rust `src/control_mcp/assistant.rs:1932`; minimum role **Executor**, mutation **true**. Lean `lean/OrbCore/OrbCore/McpGateway.lean:810-822`. ttl_minutes ignored; only machine/action passed to helper. Existing lifecycle owner.

```json
{"type":"object","required":["machine_id","ttl_minutes","idempotency_key"],"properties":{"machine_id":{"type":"string"},"ttl_minutes":{"type":"integer","minimum":5,"maximum":720},"idempotency_key":{"type":"string","minLength":1,"maxLength":200}},"additionalProperties":false}
```

Lean direct argument reads: `machine_id`, `id`. This is a read inventory, not proof that helper effects honor every argument; shared helpers may receive the entire argument object.

#### `list_active_missions` — D

Rust `src/control_mcp/assistant.rs:1941`; minimum role **Coordinator**, mutation **false**. Lean `lean/OrbCore/OrbCore/McpGateway.lean:403-430`. Only active status, ignored filters/no next_offset. MCP-14.

```json
{"type":"object","properties":{"limit":{"type":"integer"},"project":{"type":"string"},"project_prefix":{"type":"string"},"track":{"type":"string"},"tag":{"type":"string"},"origin_session_id":{"type":"string"},"offset":{"type":"integer","minimum":0}},"additionalProperties":false}
```

Rust documented omission/default behavior: `limit`: Maximum missions to return, default 50.; `offset`: Use preceding page's next_offset; omit for first page.

Lean direct argument reads: `project`, `limit`, `offset`, `status`, `folder`, `track`. This is a read inventory, not proof that helper effects honor every argument; shared helpers may receive the entire argument object.

#### `list_missions` — D

Rust `src/control_mcp/assistant.rs:1956`; minimum role **Coordinator**, mutation **false**. Lean `lean/OrbCore/OrbCore/McpGateway.lean:403-430`. project_prefix/tag/origin ignored; max 200 not Rust 100; no next_offset. MCP-14.

```json
{"type":"object","properties":{"status":{"type":"string"},"limit":{"type":"integer"},"project":{"type":"string"},"project_prefix":{"type":"string"},"track":{"type":"string"},"tag":{"type":"string"},"origin_session_id":{"type":"string"},"offset":{"type":"integer","minimum":0}},"additionalProperties":false}
```

Rust documented omission/default behavior: `limit`: Maximum missions to return, default 50.; `offset`: Use preceding page's next_offset; omit for first page.

Lean direct argument reads: `project`, `limit`, `offset`, `status`, `folder`, `track`. This is a read inventory, not proof that helper effects honor every argument; shared helpers may receive the entire argument object.

#### `get_mission` — D

Rust `src/control_mcp/assistant.rs:1972`; minimum role **Executor**, mutation **false**. Lean `lean/OrbCore/OrbCore/McpGateway.lean:431-449`. Actual helper/SQL effect exists, but global policy/receipt/projection parity is not established; MCP-01/03/14.

```json
{"type":"object","required":["mission_id"],"properties":{"mission_id":{"type":"string","format":"uuid"}},"additionalProperties":false}
```

Lean direct argument reads: `mission_id`, `id`. This is a read inventory, not proof that helper effects honor every argument; shared helpers may receive the entire argument object.

#### `get_mission_events` — D

Rust `src/control_mcp/assistant.rs:1990`; minimum role **Executor**, mutation **false**. Lean `lean/OrbCore/OrbCore/McpGateway.lean:450-466`. Reads after_seq rather than since_seq/before_seq; Rust limit40 vs Lean100; view/max_payload ignored. Recovery-owned.

```json
{"type":"object","required":["mission_id"],"properties":{"mission_id":{"type":"string","format":"uuid"},"limit":{"type":"integer"},"view":{"type":"string","enum":["transcript","trace","history","all"]},"since_seq":{"type":"integer"},"before_seq":{"type":"integer"},"max_payload":{"type":"integer"}},"additionalProperties":false}
```

Rust documented omission/default behavior: `limit`: Maximum events to return, default 40 newest events (capped at 50 for view='all').; `max_payload`: Maximum bytes per tool_call/tool_result payload (default 4096, range 1024..65536).

Lean direct argument reads: `mission_id`, `id`, `limit`, `after_seq`. This is a read inventory, not proof that helper effects honor every argument; shared helpers may receive the entire argument object.

#### `list_mission_shared_files` — S

Rust `src/control_mcp/assistant.rs:2006`; minimum role **Executor**, mutation **false**. Lean `lean/OrbCore/OrbCore/McpGateway.lean:467-472`. Always empty; limit ignored. MCP-14.

```json
{"type":"object","required":["mission_id"],"properties":{"mission_id":{"type":"string","format":"uuid"},"limit":{"type":"integer"}},"additionalProperties":false}
```

Rust documented omission/default behavior: `limit`: Maximum mission events to scan, default 40.

Lean direct argument reads: `mission_id`. This is a read inventory, not proof that helper effects honor every argument; shared helpers may receive the entire argument object.

#### `list_cloud_models` — S

Rust `src/control_mcp/assistant.rs:2031`; minimum role **Executor**, mutation **false**. Lean `lean/OrbCore/OrbCore/McpGateway.lean:1097-1099`. Always models=[]; provider ignored. MCP-16.

```json
{"type":"object","required":["provider"],"properties":{"provider":{"type":"string","enum":["chatgpt","cursor_cloud","hermes"]}},"additionalProperties":false}
```

Lean direct argument reads: none. This is a read inventory, not proof that helper effects honor every argument; shared helpers may receive the entire argument object.

#### `list_cloud_accounts` — S

Rust `src/control_mcp/assistant.rs:2032`; minimum role **Executor**, mutation **false**. Lean `lean/OrbCore/OrbCore/McpGateway.lean:1100-1102`. Always accounts=[]. MCP-16.

```json
{"type":"object","properties":{},"additionalProperties":false}
```

Lean direct argument reads: none. This is a read inventory, not proof that helper effects honor every argument; shared helpers may receive the entire argument object.

#### `get_cloud_execution` — S

Rust `src/control_mcp/assistant.rs:2033`; minimum role **Executor**, mutation **false**. Lean `lean/OrbCore/OrbCore/McpGateway.lean:1103-1105`. Always enabled=false; all execution paging/identity args ignored. MCP-16.

```json
{"type":"object","required":["mission_id"],"properties":{"mission_id":{"type":"string","format":"uuid"},"offset":{"type":"integer","minimum":0},"limit":{"type":"integer","minimum":1,"maximum":5},"text_offset":{"type":"integer","minimum":0},"text_limit":{"type":"integer","minimum":1,"maximum":8192},"include_prompt":{"type":"boolean"}},"additionalProperties":false}
```

Lean direct argument reads: none. This is a read inventory, not proof that helper effects honor every argument; shared helpers may receive the entire argument object.

#### `start_mission` — D

Rust `src/control_mcp/assistant.rs:2035`; minimum role **Executor**, mutation **true**. Lean `lean/OrbCore/OrbCore/McpGateway.lean:473-552`. Direct insert/conditional remote launch; admitted fields/defaults dropped. MCP-05.

```json
{"type":"object","required":["title","prompt","idempotency_key"],"properties":{"prompt":{"type":"string"},"cloud":{"type":"object","required":["provider","account"],"properties":{"provider":{"type":"string","enum":["chatgpt","grok_bot","cursor_cloud","hermes"]},"account":{"type":"string"},"repository":{"type":"string"},"git_ref":{"type":"string"},"model":{"type":"string"},"model_params":{"type":"array","items":{"type":"object","required":["id","value"],"properties":{"id":{"type":"string"},"value":{"type":"string"}}}}},"additionalProperties":false},"workspace_id":{"type":"string"},"backend":{"type":"string","enum":["opencode","claudecode","codex","grok","antigravity","vibe"]},"model_override":{"type":"string"},"model_effort":{"type":"string","enum":["low","medium","high","xhigh","max"]},"fast_mode":{"type":"boolean"},"config_profile":{"type":"string"},"agent":{"type":"string"},"project":{"type":"string"},"track":{"type":"string"},"intent":{"type":"string"},"github_pr":{"type":"string"},"writer":{"type":"boolean"},"request_merge_authority":{"type":"boolean"},"tags":{"type":"array","items":{"type":"string"}},"desired_state":{"type":"string"},"acceptance_criteria":{"type":"array","items":{"type":"string"}},"idempotency_key":{"type":"string","minLength":1,"maxLength":200},"supersedes_mission_id":{"type":"string","format":"uuid"},"next_check_at":{"type":"string"},"estimated_disk_gib":{"type":"integer","minimum":1,"maximum":512},"origin_session_id":{"type":"string"},"attachments":{"type":"array","items":{"type":"object","required":["kind"],"properties":{"kind":{"type":"string","enum":["file","folder","controller"]},"path":{"type":"string"}}}},"remote_node_id":{"type":"string"},"managed_ttl_minutes":{"type":"integer","minimum":5,"maximum":720},"managed_from_snapshot":{"type":"string"},"managed_repo":{"type":"string"},"managed_base_key":{"type":"string"},"managed_lean_mode":{"type":"string","enum":["auto","cache-only","off","none"]},"managed_memory_mib":{"type":"integer","minimum":4096,"maximum":131072},"managed_allow_24h_commitment":{"type":"boolean"},"retain_vm_for_parent_minutes":{"type":"integer","minimum":0,"maximum":720},"managed_pre_stop_hook":{"type":"string"},"budget_usd":{"type":"number","minimum":0},"offset":{"type":"integer","minimum":0}},"additionalProperties":false}
```

Rust documented omission/default behavior: `model_override`: auto-managed:default / auto-managed:large) runs through the core proxy: pass model_override explicitly (e.g. gpt-6.1-sol or gpt-6.1-terra); if omitted, the configured Codex default is used and recorded on the mission.; `estimated_disk_gib`: Set this for Lean/build-heavy missions; omit for small/no-build work.; `remote_node_id`: Native node placement: omit on child/subagent launches to run on Boat ("auto-managed:boat", falling back to "auto" across least-loaded static nodes when Boat is disabled or the harness lacks managed auth); pass "same" ONLY when co-locating on the parent's exact machine to share/fork its uncommitted local workspace; avoid explicitly pinning fixed static fleet nodes (e.g. "auto-managed:large", "auto-managed:boost:boost-32vcpu-96gb", "auto-managed:hetzner:cpx42", "auto-managed:vastai:rtx4090", "auto-managed:scaleway:PRO2-S", "auto-managed:colab:a100") to rent a disposable cloud VM for this child (validated before renting; an idle sibling VM of the same provider and size is reused; default boat small; the child owns it and it is destroyed after the child ends, after 15 min idle, or at its TTL; call destroy_managed_machine to release it earlier).; `managed_ttl_minutes`: Only with remote_node_id auto-managed: initial machine TTL in minutes (default 60, auto-extended while busy).; `managed_from_snapshot`: Omitted defaults to light mode (clean base image, no snapshot files restored).; `managed_lean_mode`: Only with remote_node_id auto-managed:boost:<size>: Lean overlay mode (`auto` default, `cache-only`, or `off`; `none` is accepted as an alias for `off`).; `budget_usd`: Omit to let the child share your pool.; `offset`: Use the preceding page's next_offset; omit for the first page.

Lean direct argument reads: `title`, `summary`, `prompt`, `goal`, `project`, `folder`, `backend`, `model_override`, `model`, `model_effort`, `reasoning_effort`, `parent_mission_id`, `remote_node_id`, `working_directory`. This is a read inventory, not proof that helper effects honor every argument; shared helpers may receive the entire argument object.

#### `consult_model` — D

Rust `src/control_mcp/assistant.rs:2081`; minimum role **Executor**, mutation **true**. Lean `lean/OrbCore/OrbCore/McpGateway.lean:473-552`. question/files/models ignored; no prompt from normal schema-shaped request. MCP-06.

```json
{"type":"object","required":["question","idempotency_key"],"properties":{"model":{"type":"string"},"models":{"type":"array","minItems":1,"maxItems":6,"items":{"type":"string"}},"question":{"type":"string"},"files":{"type":"array","items":{"type":"string"}},"read_only":{"type":"boolean"},"remote_node_id":{"type":"string"},"managed_from_snapshot":{"type":"string"},"managed_ttl_minutes":{"type":"integer","minimum":5,"maximum":720},"project":{"type":"string"},"github_pr":{"type":"string"},"origin_session_id":{"type":"string"},"idempotency_key":{"type":"string","minLength":1,"maxLength":200}},"additionalProperties":false}
```

Rust documented omission/default behavior: `files`: Boat VMs (the default placement) start clean and see committed/PR/snapshot state only; pass remote_node_id="same" when inspecting uncommitted local workspace files in place.; `remote_node_id`: Optional placement override: omit for Boat ("auto-managed", falling back to "auto" if Boat is disabled), pass "auto-managed:<size>" or "auto" or a registered node id, or pass "same" to share/fork the parent's uncommitted local workspace on the same machine.; `managed_from_snapshot`: Omitted defaults to light mode (clean base image, no snapshot files restored).; `managed_ttl_minutes`: Only with auto-managed: initial machine TTL in minutes (default 60, auto-extended while busy).

Lean direct argument reads: `title`, `summary`, `prompt`, `goal`, `project`, `folder`, `backend`, `model_override`, `model`, `model_effort`, `reasoning_effort`, `parent_mission_id`, `remote_node_id`, `working_directory`. This is a read inventory, not proof that helper effects honor every argument; shared helpers may receive the entire argument object.

#### `get_consult_result` — D

Rust `src/control_mcp/assistant.rs:2103`; minimum role **Executor**, mutation **false**. Lean `lean/OrbCore/OrbCore/McpGateway.lean:553-560`. Generic detail, not done/answer; mission_ids batch ignored. MCP-06.

```json
{"type":"object","required":[],"properties":{"mission_id":{"type":"string","format":"uuid"},"mission_ids":{"type":"array","minItems":1,"maxItems":10,"items":{"type":"string"}}},"additionalProperties":false}
```

Lean direct argument reads: `mission_id`, `id`. This is a read inventory, not proof that helper effects honor every argument; shared helpers may receive the entire argument object.

#### `send_message_to_mission` — D

Rust `src/control_mcp/assistant.rs:2115`; minimum role **Executor**, mutation **true**. Lean `lean/OrbCore/OrbCore/McpGateway.lean:561-611`. Some real queue/remote effects, but routing/identity modes ignored and dispatch error dropped. MCP-07.

```json
{"type":"object","required":["mission_id","content","idempotency_key"],"properties":{"cloud_model":{"type":"string"},"cloud_model_params":{"type":"array","items":{"type":"object","required":["id","value"],"properties":{"id":{"type":"string"},"value":{"type":"string"}}}},"mode":{"type":"string","enum":["queue","steer_between_tools","interrupt_now","steer_now","interrupt"],"default":"queue"},"delivery":{"type":"string","enum":["queue","steer_between_tools","interrupt_now","steer_now","interrupt"]},"auto_replace_on_same_node":{"type":"boolean","default":false},"continue_identity":{"type":"object","required":["project","track","github_pr"],"properties":{"project":{"type":["string","null"]},"track":{"type":"string","minLength":1},"github_pr":{"type":["string","null"]}},"additionalProperties":false},"github_pr":{"type":"string"},"track":{"type":"string"},"mission_id":{"type":"string","format":"uuid"},"content":{"type":"string"},"idempotency_key":{"type":"string","minLength":1,"maxLength":200}},"additionalProperties":false}
```

Rust documented omission/default behavior: `mode`: Delivery mode when the target mission has a turn in flight: 'queue' (default FIFO), 'steer_between_tools' (alias 'steer_now': inject immediately after current tool call finishes), or 'interrupt_now' (alias 'interrupt': SIGINT in-flight child tool and steer immediately).; `github_pr`: Omit to preserve.; `track`: Omit to preserve.

Lean direct argument reads: `mission_id`, `target_mission_id`, `message`, `content`, `question`, `answer`. This is a read inventory, not proof that helper effects honor every argument; shared helpers may receive the entire argument object.

#### `ask_mission` — D

Rust `src/control_mcp/assistant.rs:2137`; minimum role **Executor**, mutation **true**. Lean `lean/OrbCore/OrbCore/McpGateway.lean:561-611`. Operator note only; no Ask thread/sandbox. MCP-07.

```json
{"type":"object","required":["mission_id","content","idempotency_key"],"properties":{"mission_id":{"type":"string","format":"uuid"},"content":{"type":"string"},"thread_id":{"type":"string"},"sandbox":{"type":"boolean"},"idempotency_key":{"type":"string","minLength":1,"maxLength":200}},"additionalProperties":false}
```

Rust documented omission/default behavior: `sandbox`: Optional: isolate bash writes in a throwaway copy of the workspace (default false).

Lean direct argument reads: `mission_id`, `target_mission_id`, `message`, `content`, `question`, `answer`. This is a read inventory, not proof that helper effects honor every argument; shared helpers may receive the entire argument object.

#### `answer_mission_question` — D

Rust `src/control_mcp/assistant.rs:2151`; minimum role **Executor**, mutation **true**. Lean `lean/OrbCore/OrbCore/McpGateway.lean:561-611`. answers/tool_call_id ignored; normal request rejected; no parked-tool delivery. MCP-07.

```json
{"type":"object","required":["mission_id","answers","idempotency_key"],"properties":{"mission_id":{"type":"string","format":"uuid"},"tool_call_id":{"type":"string"},"answers":{"type":"array","items":{"type":"array","items":{"type":"string"}}},"idempotency_key":{"type":"string","minLength":1,"maxLength":200}},"additionalProperties":false}
```

Rust documented omission/default behavior: `tool_call_id`: Omit to use the newest unanswered one.

Lean direct argument reads: `mission_id`, `target_mission_id`, `message`, `content`, `question`, `answer`. This is a read inventory, not proof that helper effects honor every argument; shared helpers may receive the entire argument object.

#### `cancel_mission` — D

Rust `src/control_mcp/assistant.rs:2164`; minimum role **Executor**, mutation **true**. Lean `lean/OrbCore/OrbCore/McpGateway.lean:612-674`. Actual continuation/remote cancellation attempted; target authority not checked. MCP-01.

```json
{"type":"object","required":["mission_id","idempotency_key"],"properties":{"mission_id":{"type":"string","format":"uuid"},"idempotency_key":{"type":"string","minLength":1,"maxLength":200}},"additionalProperties":false}
```

Lean direct argument reads: `mission_id`, `id`, `prompt`, `message`. This is a read inventory, not proof that helper effects honor every argument; shared helpers may receive the entire argument object.

#### `acknowledge_mission` — D

Rust `src/control_mcp/assistant.rs:2173`; minimum role **Coordinator**, mutation **true**. Lean `lean/OrbCore/OrbCore/McpGateway.lean:612-674`. Status=completed instead of acknowledgement flow; target authority absent. MCP-01.

```json
{"type":"object","required":["mission_id","idempotency_key"],"properties":{"mission_id":{"type":"string","format":"uuid"},"idempotency_key":{"type":"string","minLength":1,"maxLength":200}},"additionalProperties":false}
```

Lean direct argument reads: `mission_id`, `id`, `prompt`, `message`. This is a read inventory, not proof that helper effects honor every argument; shared helpers may receive the entire argument object.

#### `adopt_mission` — D

Rust `src/control_mcp/assistant.rs:2182`; minimum role **Coordinator**, mutation **true**. Lean `lean/OrbCore/OrbCore/McpGateway.lean:612-674`. Status=awaiting_user, not callback/session adoption. MCP-01; U for restored callback delivery.

```json
{"type":"object","required":["mission_id","idempotency_key"],"properties":{"mission_id":{"type":"string","format":"uuid"},"idempotency_key":{"type":"string","minLength":1,"maxLength":200}},"additionalProperties":false}
```

Lean direct argument reads: `mission_id`, `id`, `prompt`, `message`. This is a read inventory, not proof that helper effects honor every argument; shared helpers may receive the entire argument object.

#### `get_compute_fleet` — D

Rust `src/control_mcp/assistant.rs:2191`; minimum role **Coordinator**, mutation **false**. Lean `lean/OrbCore/OrbCore/McpGateway.lean:709-718`. Actual helper/SQL effect exists, but global policy/receipt/projection parity is not established; MCP-01/03/14.

```json
{"type":"object","properties":{},"additionalProperties":false}
```

Lean direct argument reads: none. This is a read inventory, not proof that helper effects honor every argument; shared helpers may receive the entire argument object.

#### `list_projects` — D

Rust `src/control_mcp/assistant.rs:2196`; minimum role **Coordinator**, mutation **false**. Lean `lean/OrbCore/OrbCore/McpGateway.lean:872-878`. Actual helper/SQL effect exists, but global policy/receipt/projection parity is not established; MCP-01/03/14.

```json
{"type":"object","properties":{},"additionalProperties":false}
```

Lean direct argument reads: none. This is a read inventory, not proof that helper effects honor every argument; shared helpers may receive the entire argument object.

#### `get_project` — D

Rust `src/control_mcp/assistant.rs:2201`; minimum role **Coordinator**, mutation **false**. Lean `lean/OrbCore/OrbCore/McpGateway.lean:879-886`. Simplified situation projection lacks Rust family/governance aggregation. MCP-11/14.

```json
{"type":"object","required":["slug"],"properties":{"slug":{"type":"string"}},"additionalProperties":false}
```

Lean direct argument reads: `project`, `slug`. This is a read inventory, not proof that helper effects honor every argument; shared helpers may receive the entire argument object.

#### `get_situation` — D

Rust `src/control_mcp/assistant.rs:2210`; minimum role **Coordinator**, mutation **false**. Lean `lean/OrbCore/OrbCore/McpGateway.lean:879-886`. Same simplified buildProjectSituationJVal as get_project. MCP-11/14.

```json
{"type":"object","required":["slug"],"properties":{"slug":{"type":"string"}},"additionalProperties":false}
```

Lean direct argument reads: `project`, `slug`. This is a read inventory, not proof that helper effects honor every argument; shared helpers may receive the entire argument object.

#### `update_project_status` — D

Rust `src/control_mcp/assistant.rs:2219`; minimum role **Coordinator**, mutation **true**. Lean `lean/OrbCore/OrbCore/McpGateway.lean:887-901`. consumed_steer_ids ignored; status defaults active even though Rust requires mode. MCP-11.

```json
{"type":"object","required":["slug","mode","idempotency_key"],"properties":{"slug":{"type":"string"},"mode":{"type":"string","enum":["active","blocked","paused"]},"next_action":{"type":"string"},"blocker":{"type":"string"},"consumed_steer_ids":{"type":"array","items":{"type":"string"}},"idempotency_key":{"type":"string","minLength":1,"maxLength":200}},"additionalProperties":false}
```

Rust documented omission/default behavior: `consumed_steer_ids`: Omit to leave all pending.

Lean direct argument reads: `project`, `slug`, `status`, `mode`, `next_action`, `blocker`. This is a read inventory, not proof that helper effects honor every argument; shared helpers may receive the entire argument object.

#### `set_project_track` — D

Rust `src/control_mcp/assistant.rs:2234`; minimum role **Coordinator**, mutation **true**. Lean `lean/OrbCore/OrbCore/McpGateway.lean:902-915`. Calls putProjectTrack with desired state/status; full governed contract not established. MCP-08.

```json
{"type":"object","required":["slug","track","idempotency_key"],"properties":{"slug":{"type":"string"},"track":{"type":"string"},"desired_state":{"type":"string"},"status":{"type":"string","enum":["planned","ready","executing","waiting","blocked","satisfied","cancelled"]},"idempotency_key":{"type":"string","minLength":1,"maxLength":200}},"additionalProperties":false}
```

Lean direct argument reads: `project`, `slug`, `track`, `desired_condition`, `desired_state`, `status`, `expected_revision`. This is a read inventory, not proof that helper effects honor every argument; shared helpers may receive the entire argument object.

#### `accept_project_track_evidence` — D

Rust `src/control_mcp/assistant.rs:2248`; minimum role **Coordinator**, mutation **true**. Lean `lean/OrbCore/OrbCore/McpGateway.lean:916-929`. Unchecked status=accepted; all evidence/version/verifier args ignored. MCP-08.

```json
{"type":"object","required":["slug","track","verifier_class","evidence_ref","artifact_version","idempotency_key"],"properties":{"slug":{"type":"string"},"track":{"type":"string"},"criterion":{"type":"string"},"verifier_class":{"type":"string","enum":["external_state","command","review","operator","manual"]},"evidence_ref":{"type":"string"},"artifact_version":{"type":"string"},"observed_at":{"type":"string"},"idempotency_key":{"type":"string","minLength":1,"maxLength":200}},"additionalProperties":false}
```

Rust documented omission/default behavior: `criterion`: May be omitted for a zero- or one-criterion track.

Lean direct argument reads: `project`, `slug`, `track`. This is a read inventory, not proof that helper effects honor every argument; shared helpers may receive the entire argument object.

#### `reopen_project_track` — D

Rust `src/control_mcp/assistant.rs:2265`; minimum role **Coordinator**, mutation **true**. Lean `lean/OrbCore/OrbCore/McpGateway.lean:916-929`. Status=open; reason/governed version ignored. MCP-08.

```json
{"type":"object","required":["slug","track","reason","idempotency_key"],"properties":{"slug":{"type":"string"},"track":{"type":"string"},"reason":{"type":"string"},"governed_artifact_version":{"type":"string"},"idempotency_key":{"type":"string","minLength":1,"maxLength":200}},"additionalProperties":false}
```

Lean direct argument reads: `project`, `slug`, `track`. This is a read inventory, not proof that helper effects honor every argument; shared helpers may receive the entire argument object.

#### `accept_project_track` — D

Rust `src/control_mcp/assistant.rs:2279`; minimum role **Coordinator**, mutation **true**. Lean `lean/OrbCore/OrbCore/McpGateway.lean:916-929`. Unchecked status=accepted; evidence/revision ignored. MCP-08.

```json
{"type":"object","required":["slug","track","idempotency_key","evidence"],"properties":{"slug":{"type":"string"},"track":{"type":"string"},"idempotency_key":{"type":"string","minLength":1,"maxLength":200},"expected_revision":{"type":"integer"},"evidence":{"type":"array","items":{"type":"object","required":["kind","subject_id"],"properties":{"criterion_id":{"type":"string"},"kind":{"type":"string","enum":["pr_merged","pr_head_review","review","command","external_state","operator","manual"]},"subject_id":{"type":"string"},"verifier":{"type":"string"},"payload":{"type":"object"}}}}},"additionalProperties":false}
```

Lean direct argument reads: `project`, `slug`, `track`. This is a read inventory, not proof that helper effects honor every argument; shared helpers may receive the entire argument object.

#### `invalidate_project_track_evidence` — D

Rust `src/control_mcp/assistant.rs:2307`; minimum role **Coordinator**, mutation **true**. Lean `lean/OrbCore/OrbCore/McpGateway.lean:916-929`. Status=open; receipt_id/reason ignored. MCP-08.

```json
{"type":"object","required":["slug","track","receipt_id","reason","idempotency_key"],"properties":{"slug":{"type":"string"},"track":{"type":"string"},"receipt_id":{"type":"string"},"reason":{"type":"string"},"idempotency_key":{"type":"string","minLength":1,"maxLength":200}},"additionalProperties":false}
```

Lean direct argument reads: `project`, `slug`, `track`. This is a read inventory, not proof that helper effects honor every argument; shared helpers may receive the entire argument object.

#### `get_project_grant` — D

Rust `src/control_mcp/assistant.rs:2321`; minimum role **Coordinator**, mutation **false**. Lean `lean/OrbCore/OrbCore/McpGateway.lean:930-936`. Real SQL projection; zero→null and changed shape/semantics. MCP-10.

```json
{"type":"object","required":["slug"],"properties":{"slug":{"type":"string"}},"additionalProperties":false}
```

Lean direct argument reads: `project`, `slug`. This is a read inventory, not proof that helper effects honor every argument; shared helpers may receive the entire argument object.

#### `set_project_grant` — M

Rust `src/control_mcp/assistant.rs:2330`; minimum role **Operator**, mutation **true**. Lean none; fallback `lean/OrbCore/OrbCore/McpGateway.lean:1106-1107`. Advertised operator mutation but unknown_tool. REST helper is not MCP dispatch. MCP-10.

```json
{"type":"object","required":["slug","idempotency_key"],"properties":{"slug":{"type":"string"},"autonomy_level":{"type":"string","enum":["observe","propose","act_reversible","act_full"]},"merge_authority":{"type":"string"},"budget_per_tick":{"type":"string"},"parallel_missions":{"type":"integer"},"pause_reason":{"type":"string"},"resume_condition":{"type":"string"},"material_bar":{"type":"string"},"idempotency_key":{"type":"string","minLength":1,"maxLength":200}},"additionalProperties":false}
```

#### `add_project_steer` — D

Rust `src/control_mcp/assistant.rs:2348`; minimum role **Coordinator**, mutation **true**. Lean `lean/OrbCore/OrbCore/McpGateway.lean:937-946`. Actual helper/SQL effect exists, but global policy/receipt/projection parity is not established; MCP-01/03/14.

```json
{"type":"object","required":["slug","body","idempotency_key"],"properties":{"slug":{"type":"string"},"body":{"type":"string"},"idempotency_key":{"type":"string","minLength":1,"maxLength":200}},"additionalProperties":false}
```

Lean direct argument reads: `project`, `slug`, `body`, `message`. This is a read inventory, not proof that helper effects honor every argument; shared helpers may receive the entire argument object.

#### `record_project_decision` — D

Rust `src/control_mcp/assistant.rs:2360`; minimum role **Coordinator**, mutation **true**. Lean `lean/OrbCore/OrbCore/McpGateway.lean:947-955`. kind ignored; structured evidence read as string; disposition defaults differ. MCP-11.

```json
{"type":"object","required":["slug","question","idempotency_key"],"properties":{"slug":{"type":"string"},"question":{"type":"string"},"rationale":{"type":"string"},"kind":{"type":"string"},"authority":{"type":"string","enum":["granted","escalation"]},"status":{"type":"string","enum":["decided","pending_user"]},"evidence":{"type":"object"},"idempotency_key":{"type":"string","minLength":1,"maxLength":200}},"additionalProperties":false}
```

Lean direct argument reads: `project`, `slug`. This is a read inventory, not proof that helper effects honor every argument; shared helpers may receive the entire argument object.

#### `answer_project_decision` — D

Rust `src/control_mcp/assistant.rs:2377`; minimum role **Coordinator**, mutation **true**. Lean `lean/OrbCore/OrbCore/McpGateway.lean:956-966`. Published at ignored; requires nonpublished id/decision_id instead. MCP-11.

```json
{"type":"object","required":["slug","at","answer","idempotency_key"],"properties":{"slug":{"type":"string"},"at":{"type":"string"},"answer":{"type":"string"},"idempotency_key":{"type":"string","minLength":1,"maxLength":200}},"additionalProperties":false}
```

Lean direct argument reads: `project`, `slug`, `id`, `decision_id`, `answer`. This is a read inventory, not proof that helper effects honor every argument; shared helpers may receive the entire argument object.

#### `get_project_tasks` — D

Rust `src/control_mcp/assistant.rs:2390`; minimum role **Coordinator**, mutation **false**. Lean `lean/OrbCore/OrbCore/McpGateway.lean:967-974`. Sparse executable-board rows rather than project proposal roster. MCP-09.

```json
{"type":"object","required":["slug"],"properties":{"slug":{"type":"string"}},"additionalProperties":false}
```

Lean direct argument reads: `project`, `slug`. This is a read inventory, not proof that helper effects honor every argument; shared helpers may receive the entire argument object.

#### `plan_project_tasks` — D

Rust `src/control_mcp/assistant.rs:2399`; minimum role **Coordinator**, mutation **true**. Lean `lean/OrbCore/OrbCore/McpGateway.lean:975-991`. Loses proposal title/prompt/dependencies/criteria; writes wrong sparse table. MCP-09.

```json
{"type":"object","required":["slug","tasks","idempotency_key"],"properties":{"slug":{"type":"string"},"tasks":{"type":"array","items":{"type":"object","required":["task_key","title"],"properties":{"task_key":{"type":"string"},"prompt":{"type":"string"},"acceptance_criteria":{"type":"array","items":{"type":"string"}},"depends_on":{"type":"array","items":{"type":"string"}},"position":{"type":"integer","minimum":0}}}},"idempotency_key":{"type":"string","minLength":1,"maxLength":200}},"additionalProperties":false}
```

Rust documented omission/default behavior: `tasks[].position`: Omission preserves an existing position or appends a new track.

Lean direct argument reads: `project`, `slug`, `tasks`. This is a read inventory, not proof that helper effects honor every argument; shared helpers may receive the entire argument object.

#### `update_project_task` — D

Rust `src/control_mcp/assistant.rs:2425`; minimum role **Coordinator**, mutation **true**. Lean `lean/OrbCore/OrbCore/McpGateway.lean:992-1008`. Ignores every published editable field; status defaults done. MCP-09.

```json
{"type":"object","required":["slug","task_key","idempotency_key"],"properties":{"slug":{"type":"string"},"task_key":{"type":"string"},"prompt":{"type":"string"},"acceptance_criteria":{"type":"array","items":{"type":"string"}},"depends_on":{"type":"array","items":{"type":"string"}},"idempotency_key":{"type":"string","minLength":1,"maxLength":200}},"additionalProperties":false}
```

Lean direct argument reads: `project`, `slug`, `task_key`, `key`, `status`. This is a read inventory, not proof that helper effects honor every argument; shared helpers may receive the entire argument object.

#### `cancel_project_task` — D

Rust `src/control_mcp/assistant.rs:2441`; minimum role **Coordinator**, mutation **true**. Lean `lean/OrbCore/OrbCore/McpGateway.lean:992-1008`. Sparse status assignment, no proposal/mission cancellation semantics. MCP-09.

```json
{"type":"object","required":["slug","task_key","idempotency_key"],"properties":{"slug":{"type":"string"},"task_key":{"type":"string"},"idempotency_key":{"type":"string","minLength":1,"maxLength":200}},"additionalProperties":false}
```

Lean direct argument reads: `project`, `slug`, `task_key`, `key`, `status`. This is a read inventory, not proof that helper effects honor every argument; shared helpers may receive the entire argument object.

#### `link_mission_to_project` — D

Rust `src/control_mcp/assistant.rs:2453`; minimum role **Coordinator**, mutation **true**. Lean `lean/OrbCore/OrbCore/McpGateway.lean:686-708`. Checked placement update and session rebind exist, but track/writer ignored and source authorization missing. MCP-01/05.

```json
{"type":"object","required":["mission_id","slug","idempotency_key"],"properties":{"mission_id":{"type":"string","format":"uuid"},"slug":{"type":"string"},"track":{"type":"string"},"writer":{"type":"boolean"},"idempotency_key":{"type":"string","minLength":1,"maxLength":200}},"additionalProperties":false}
```

Rust documented omission/default behavior: `writer`: Omit to preserve existing behavior.

Lean direct argument reads: `mission_id`, `project`, `slug`, `folder`. This is a read inventory, not proof that helper effects honor every argument; shared helpers may receive the entire argument object.

#### `list_workspaces` — D

Rust `src/control_mcp/assistant.rs:2467`; minimum role **Coordinator**, mutation **false**. Lean `lean/OrbCore/OrbCore/McpGateway.lean:1009-1023`. Real sparse SQL list, not full Rust workspace model/config/capabilities. MCP-15.

```json
{"type":"object","properties":{},"additionalProperties":false}
```

Lean direct argument reads: none. This is a read inventory, not proof that helper effects honor every argument; shared helpers may receive the entire argument object.

#### `get_workspace` — D

Rust `src/control_mcp/assistant.rs:2472`; minimum role **Coordinator**, mutation **false**. Lean `lean/OrbCore/OrbCore/McpGateway.lean:1024-1038`. Real sparse SQL row by ID/name; not full Rust model. MCP-15.

```json
{"type":"object","required":["workspace_id"],"properties":{"workspace_id":{"type":"string"}},"additionalProperties":false}
```

Lean direct argument reads: `workspace_id`, `id`. This is a read inventory, not proof that helper effects honor every argument; shared helpers may receive the entire argument object.

#### `create_workspace` — M

Rust `src/control_mcp/assistant.rs:2481`; minimum role **Operator**, mutation **true**. Lean none; fallback `lean/OrbCore/OrbCore/McpGateway.lean:1106-1107`. No gateway branch; advertising/schema existence is not effect. MCP-15.

```json
{"type":"object","required":["name","idempotency_key"],"properties":{"name":{"type":"string"},"workspace_type":{"type":"string","enum":["host","container"]},"path":{"type":"string"},"skills":{"type":"array","items":{"type":"string"}},"distro":{"type":"string"},"env_vars":{"type":"object","additionalProperties":{"type":"string"}},"init_script":{"type":"string"},"shared_network":{"type":"boolean"},"tailscale_mode":{"type":"string","enum":["exit_node","tailnet_only"]},"mcps":{"type":"array","items":{"type":"string"}},"mcps_replace_defaults":{"type":"boolean"},"idempotency_key":{"type":"string","minLength":1,"maxLength":200}},"additionalProperties":false}
```

Rust documented omission/default behavior: `path`: Required for host workspaces; omit for the standard container path.

#### `update_workspace` — M

Rust `src/control_mcp/assistant.rs:2502`; minimum role **Operator**, mutation **true**. Lean none; fallback `lean/OrbCore/OrbCore/McpGateway.lean:1106-1107`. No gateway branch; advertising/schema existence is not effect. MCP-15.

```json
{"type":"object","required":["workspace_id","idempotency_key"],"properties":{"workspace_id":{"type":"string"},"name":{"type":"string"},"skills":{"type":"array","items":{"type":"string"}},"distro":{"type":"string"},"env_vars":{"type":"object","additionalProperties":{"type":"string"}},"init_script":{"type":"string"},"shared_network":{"type":"boolean"},"tailscale_mode":{"type":"string","enum":["exit_node","tailnet_only"]},"mcps":{"type":"array","items":{"type":"string"}},"mcps_replace_defaults":{"type":"boolean"},"config":{"type":"object"},"idempotency_key":{"type":"string","minLength":1,"maxLength":200}},"additionalProperties":false}
```

#### `delete_workspace` — M

Rust `src/control_mcp/assistant.rs:2523`; minimum role **Operator**, mutation **true**. Lean none; fallback `lean/OrbCore/OrbCore/McpGateway.lean:1106-1107`. No gateway branch; advertising/schema existence is not effect. MCP-15.

```json
{"type":"object","required":["workspace_id","confirm","idempotency_key"],"properties":{"workspace_id":{"type":"string"},"confirm":{"type":"boolean"},"idempotency_key":{"type":"string","minLength":1,"maxLength":200}},"additionalProperties":false}
```

#### `start_workspace_job` — S

Rust `src/control_mcp/assistant.rs:2551`; minimum role **Executor**, mutation **true**. Lean `lean/OrbCore/OrbCore/McpGateway.lean:1039-1044`. No execution or persistence; ignores execution arguments. MCP-04.

```json
{"type":"object","required":["mission_id","idempotency_key"],"properties":{"command":{"type":"string"},"argv":{"type":"array","items":{"type":"string"}},"workspace_id":{"type":"string"},"mission_id":{"type":"string","format":"uuid"},"cwd":{"type":"string"},"timeout_secs":{"type":"integer"},"resource_class":{"type":"string"},"idempotency_key":{"type":"string","minLength":1,"maxLength":200}},"additionalProperties":false}
```

Rust documented omission/default behavior: `workspace_id`: Defaults to the assistant default workspace.

Lean direct argument reads: `job_id`. This is a read inventory, not proof that helper effects honor every argument; shared helpers may receive the entire argument object.

#### `get_workspace_job` — S

Rust `src/control_mcp/assistant.rs:2569`; minimum role **Executor**, mutation **false**. Lean `lean/OrbCore/OrbCore/McpGateway.lean:1039-1044`. No lookup/logs; reports any ID completed, ignores tail_bytes. MCP-04.

```json
{"type":"object","required":["job_id"],"properties":{"job_id":{"type":"string"},"tail_bytes":{"type":"integer"}},"additionalProperties":false}
```

Rust documented omission/default behavior: `tail_bytes`: Maximum bytes from each log, default 16384, maximum 65536.

Lean direct argument reads: `job_id`. This is a read inventory, not proof that helper effects honor every argument; shared helpers may receive the entire argument object.

#### `cancel_workspace_job` — S

Rust `src/control_mcp/assistant.rs:2581`; minimum role **Executor**, mutation **true**. Lean `lean/OrbCore/OrbCore/McpGateway.lean:1039-1044`. No process cancellation or lookup. MCP-04.

```json
{"type":"object","required":["job_id","idempotency_key"],"properties":{"job_id":{"type":"string"},"idempotency_key":{"type":"string","minLength":1,"maxLength":200}},"additionalProperties":false}
```

Lean direct argument reads: `job_id`. This is a read inventory, not proof that helper effects honor every argument; shared helpers may receive the entire argument object.

#### `get_mission_health` — D

Rust `src/control_mcp/assistant.rs:2590`; minimum role **Executor**, mutation **false**. Lean `lean/OrbCore/OrbCore/McpGateway.lean:431-449`. Bare status/verdict/resumable instead of live runner/analysis; recovery-owned.

```json
{"type":"object","required":["mission_id"],"properties":{"mission_id":{"type":"string","format":"uuid"}},"additionalProperties":false}
```

Lean direct argument reads: `mission_id`, `id`. This is a read inventory, not proof that helper effects honor every argument; shared helpers may receive the entire argument object.

#### `get_mission_diagnostics` — D

Rust `src/control_mcp/assistant.rs:2599`; minimum role **Executor**, mutation **false**. Lean `lean/OrbCore/OrbCore/McpGateway.lean:431-449`. Generic detail, ignores diagnostics limit; recovery-owned.

```json
{"type":"object","required":["mission_id"],"properties":{"mission_id":{"type":"string","format":"uuid"},"limit":{"type":"integer"}},"additionalProperties":false}
```

Rust documented omission/default behavior: `limit`: Trace events to scan from the tail, default 80, max 300.

Lean direct argument reads: `mission_id`, `id`. This is a read inventory, not proof that helper effects honor every argument; shared helpers may receive the entire argument object.

#### `update_mission_settings` — D

Rust `src/control_mcp/assistant.rs:2611`; minimum role **Coordinator**, mutation **true**. Lean `lean/OrbCore/OrbCore/McpGateway.lean:675-685`. Only title/model_override/model_effort written; advertised backend/agent/profile/fast_mode ignored. MCP-15.

```json
{"type":"object","required":["mission_id","idempotency_key"],"properties":{"mission_id":{"type":"string","format":"uuid"},"backend":{"type":"string","enum":["opencode","claudecode","codex","grok","antigravity","vibe"]},"model_override":{"type":"string"},"model_effort":{"type":"string","enum":["low","medium","high","xhigh","max"]},"fast_mode":{"type":"boolean"},"agent":{"type":"string"},"config_profile":{"type":"string"},"idempotency_key":{"type":"string","minLength":1,"maxLength":200}},"additionalProperties":false}
```

Rust documented omission/default behavior: `agent`: Omission preserves it on the same backend and clears it on a backend switch.

Lean direct argument reads: `mission_id`, `title`, `model_override`, `model_effort`. This is a read inventory, not proof that helper effects honor every argument; shared helpers may receive the entire argument object.

#### `resume_mission` — D

Rust `src/control_mcp/assistant.rs:2628`; minimum role **Executor**, mutation **true**. Lean `lean/OrbCore/OrbCore/McpGateway.lean:612-674`. Remote resume attempt or status-only fallback; content/clean_workspace/identity ignored. Recovery-owned content, MCP-01/05/07 for admission/effect.

```json
{"type":"object","required":["mission_id","idempotency_key"],"properties":{"continue_identity":{"type":"object","required":["project","track","github_pr"],"properties":{"project":{"type":["string","null"]},"track":{"type":"string","minLength":1},"github_pr":{"type":["string","null"]}},"additionalProperties":false},"github_pr":{"type":"string"},"track":{"type":"string"},"mission_id":{"type":"string","format":"uuid"},"content":{"type":"string"},"clean_workspace":{"type":"boolean"},"idempotency_key":{"type":"string","minLength":1,"maxLength":200}},"additionalProperties":false}
```

Rust documented omission/default behavior: `github_pr`: Omit to preserve.; `track`: Omit to preserve.; `clean_workspace`: Rarely needed; default false.

Lean direct argument reads: `mission_id`, `id`, `prompt`, `message`. This is a read inventory, not proof that helper effects honor every argument; shared helpers may receive the entire argument object.

#### `get_backend_auth_status` — M

Rust `src/control_mcp/orchestrator.rs:455`; minimum role **Operator**, mutation **false**. Lean none; fallback `lean/OrbCore/OrbCore/McpGateway.lean:1106-1107`. No gateway branch; advertising/schema existence is not effect. MCP-15.

```json
{"type":"object","properties":{"backend":{"type":"string","enum":["claudecode","codex","opencode","grok","antigravity","vibe"]}},"additionalProperties":false}
```

Rust documented omission/default behavior: `backend`: If omitted, returns all common backends.

#### `plan_tasks` — D

Rust `src/control_mcp/orchestrator.rs:518`; minimum role **Coordinator**, mutation **true**. Lean `lean/OrbCore/OrbCore/McpGateway.lean:975-991`. No prompt/dependency/backend/scheduling effect; sparse project rows only. MCP-09.

```json
{"type":"object","required":["tasks","idempotency_key"],"properties":{"tasks":{"type":"array","items":{"type":"object","required":["task_key","title","prompt","backend"],"properties":{"task_key":{"type":"string"},"prompt":{"type":"string"},"backend":{"type":"string"},"acceptance_criteria":{"type":"array","items":{"type":"string"}},"verification_command":{"type":"string"},"risk_class":{"type":"string"},"model_override":{"type":"string"},"model_effort":{"type":"string"},"working_directory":{"type":"string"},"depends_on":{"type":"array","items":{"type":"string"}},"worktree":{"type":"object","required":["path","branch"],"properties":{"path":{"type":"string"},"branch":{"type":"string"},"base":{"type":"string"},"repo_path":{"type":"string"}}}}}},"idempotency_key":{"type":"string","minLength":1,"maxLength":200}},"additionalProperties":false}
```

Rust documented omission/default behavior: `tasks[].risk_class`: low \| normal (default) \| high.; `tasks[].model_override`: For Codex Terra use gpt-6.1-terra with medium effort (default for Codex worker tasks; gpt-6-terra does not exist).; `tasks[].worktree.base`: Base branch/commit (default HEAD); `tasks[].worktree.repo_path`: Repo owning the worktree (auto-detected if omitted)

Lean direct argument reads: `project`, `slug`, `tasks`. This is a read inventory, not proof that helper effects honor every argument; shared helpers may receive the entire argument object.

#### `board_status` — D

Rust `src/control_mcp/orchestrator.rs:558`; minimum role **Coordinator**, mutation **false**. Lean `lean/OrbCore/OrbCore/McpGateway.lean:967-974`. Project tasks rather than authenticated mission board/utilization. MCP-09.

```json
{"type":"object","properties":{},"additionalProperties":false}
```

Lean direct argument reads: `project`, `slug`. This is a read inventory, not proof that helper effects honor every argument; shared helpers may receive the entire argument object.

#### `review_task` — D

Rust `src/control_mcp/orchestrator.rs:563`; minimum role **Coordinator**, mutation **true**. Lean `lean/OrbCore/OrbCore/McpGateway.lean:992-1008`. Changes status; ignores task_id/history_limit, returns no review. MCP-09.

```json
{"type":"object","properties":{"task_key":{"type":"string"},"task_id":{"type":"string"},"history_limit":{"type":"integer"},"idempotency_key":{"type":"string","minLength":1,"maxLength":200}},"additionalProperties":false,"required":["idempotency_key"]}
```

Rust documented omission/default behavior: `history_limit`: Worker history entries to include (default 6)

Lean direct argument reads: `project`, `slug`, `task_key`, `key`, `status`. This is a read inventory, not proof that helper effects honor every argument; shared helpers may receive the entire argument object.

#### `accept_task` — D

Rust `src/control_mcp/orchestrator.rs:575`; minimum role **Coordinator**, mutation **true**. Lean `lean/OrbCore/OrbCore/McpGateway.lean:992-1008`. Sparse accepted status, ignores task_id and outcome gates. MCP-09.

```json
{"type":"object","properties":{"task_key":{"type":"string"},"task_id":{"type":"string"},"idempotency_key":{"type":"string","minLength":1,"maxLength":200}},"additionalProperties":false,"required":["idempotency_key"]}
```

Lean direct argument reads: `project`, `slug`, `task_key`, `key`, `status`. This is a read inventory, not proof that helper effects honor every argument; shared helpers may receive the entire argument object.

#### `reject_task` — D

Rust `src/control_mcp/orchestrator.rs:586`; minimum role **Coordinator**, mutation **true**. Lean `lean/OrbCore/OrbCore/McpGateway.lean:992-1008`. Sparse open status, ignores task_id/feedback and retry gates. MCP-09.

```json
{"type":"object","required":["feedback","idempotency_key"],"properties":{"task_key":{"type":"string"},"task_id":{"type":"string"},"feedback":{"type":"string"},"idempotency_key":{"type":"string","minLength":1,"maxLength":200}},"additionalProperties":false}
```

Lean direct argument reads: `project`, `slug`, `task_key`, `key`, `status`. This is a read inventory, not proof that helper effects honor every argument; shared helpers may receive the entire argument object.

#### `deploy_sandboxed_sh` — M

Rust `src/control_mcp/orchestrator.rs:964`; minimum role **Operator**, mutation **true**. Lean none; fallback `lean/OrbCore/OrbCore/McpGateway.lean:1106-1107`. No gateway branch; advertising/schema existence is not effect. MCP-15.

```json
{"type":"object","properties":{"target_environment":{"type":"string","enum":["dev","prod"]},"force":{"type":"boolean","default":false},"git_ref":{"type":"string"},"skip_build":{"type":"boolean","default":false},"repo_path":{"type":"string"},"idempotency_key":{"type":"string","minLength":1,"maxLength":200}},"additionalProperties":false,"required":["idempotency_key"]}
```

Rust documented omission/default behavior: `target_environment`: Omit to deploy the backend API this mission is connected to.; `git_ref`: Omit to deploy whatever the local repo currently has checked out.; `repo_path`: Required when your build artifact lives outside the default location (e.g.

#### `secret_list` — D

Rust `src/api/secret_broker.rs:1849`; minimum role **Executor**, mutation **false**. Lean `lean/OrbCore/OrbCore/McpGateway.lean:1045-1047`. Calls actual Bitwarden broker; global admission and external subject parity unresolved. Provider credentials already owned elsewhere.

```json
{"type":"object","properties":{},"additionalProperties":false}
```

Lean direct argument reads: none. This is a read inventory, not proof that helper effects honor every argument; shared helpers may receive the entire argument object.

#### `secret_get` — D

Rust `src/api/secret_broker.rs:1856`; minimum role **Executor**, mutation **false**. Lean `lean/OrbCore/OrbCore/McpGateway.lean:1048-1053`. Calls actual approval-gated broker; reason forwarded. Reserved-provider key denial is existing provider work.

```json
{"type":"object","required":["name"],"properties":{"name":{"type":"string","minLength":1,"maxLength":200},"reason":{"type":"string","maxLength":500}},"additionalProperties":false}
```

Lean direct argument reads: `name`, `secret_name`, `reason`. This is a read inventory, not proof that helper effects honor every argument; shared helpers may receive the entire argument object.

#### `secret_request` — D

Rust `src/api/secret_broker.rs:1868`; minimum role **Executor**, mutation **false**. Lean `lean/OrbCore/OrbCore/McpGateway.lean:1054-1061`. Queues actual broker action; external identity/default access parity not established.

```json
{"type":"object","required":["bitwarden_project","reason"],"properties":{"bitwarden_project":{"type":"string","minLength":1,"maxLength":200},"reason":{"type":"string","minLength":1,"maxLength":500}},"additionalProperties":false}
```

Lean direct argument reads: `bitwarden_project`, `project`, `name`, `secret_name`, `value`, `note`, `reason`. This is a read inventory, not proof that helper effects honor every argument; shared helpers may receive the entire argument object.

#### `secret_put` — D

Rust `src/api/secret_broker.rs:1878`; minimum role **Executor**, mutation **false**. Lean `lean/OrbCore/OrbCore/McpGateway.lean:1054-1061`. Queues actual approval-gated action, not direct unconditional write.

```json
{"type":"object","required":["name","value","bitwarden_project","reason"],"properties":{"name":{"type":"string","minLength":1,"maxLength":200},"value":{"type":"string","minLength":1,"maxLength":65536},"bitwarden_project":{"type":"string","minLength":1,"maxLength":200},"note":{"type":"string","maxLength":2000},"reason":{"type":"string","minLength":1,"maxLength":500}},"additionalProperties":false}
```

Lean direct argument reads: `bitwarden_project`, `project`, `name`, `secret_name`, `value`, `note`, `reason`. This is a read inventory, not proof that helper effects honor every argument; shared helpers may receive the entire argument object.

#### `secret_delete` — D

Rust `src/api/secret_broker.rs:1892`; minimum role **Executor**, mutation **false**. Lean `lean/OrbCore/OrbCore/McpGateway.lean:1054-1061`. Queues actual approval-gated action.

```json
{"type":"object","required":["name","reason"],"properties":{"name":{"type":"string","minLength":1,"maxLength":200},"bitwarden_project":{"type":"string","minLength":1,"maxLength":200},"reason":{"type":"string","minLength":1,"maxLength":500}},"additionalProperties":false}
```

Lean direct argument reads: `bitwarden_project`, `project`, `name`, `secret_name`, `value`, `note`, `reason`. This is a read inventory, not proof that helper effects honor every argument; shared helpers may receive the entire argument object.

#### `secret_move` — D

Rust `src/api/secret_broker.rs:1906`; minimum role **Executor**, mutation **false**. Lean `lean/OrbCore/OrbCore/McpGateway.lean:1054-1061`. Queues actual approval-gated action.

```json
{"type":"object","required":["name","bitwarden_project","reason"],"properties":{"name":{"type":"string","minLength":1,"maxLength":200},"bitwarden_project":{"type":"string","minLength":1,"maxLength":200},"reason":{"type":"string","minLength":1,"maxLength":500}},"additionalProperties":false}
```

Lean direct argument reads: `bitwarden_project`, `project`, `name`, `secret_name`, `value`, `note`, `reason`. This is a read inventory, not proof that helper effects honor every argument; shared helpers may receive the entire argument object.

#### `request_mission_access` — D

Rust `src/api/mission_access.rs:1191`; minimum role **Executor**, mutation **false**. Lean `lean/OrbCore/OrbCore/McpGateway.lean:1062-1068`. scope ignored, always read; no external requester identity. MCP-13.

```json
{"type":"object","required":["target_mission_id","reason"],"properties":{"target_mission_id":{"type":"string","minLength":4,"maxLength":64},"scope":{"type":"string","enum":["read","control"],"default":"read"},"reason":{"type":"string","minLength":1,"maxLength":500},"ttl_hours":{"type":"integer","minimum":1,"maximum":168}},"additionalProperties":false}
```

Rust documented omission/default behavior: `ttl_hours`: How long you need it (default 24).

Lean direct argument reads: `target_mission_id`, `mission_id`, `reason`, `ttl_hours`. This is a read inventory, not proof that helper effects honor every argument; shared helpers may receive the entire argument object.

#### `list_mission_access` — D

Rust `src/api/mission_access.rs:1208`; minimum role **Executor**, mutation **false**. Lean `lean/OrbCore/OrbCore/McpGateway.lean:1069-1071`. Empty mission ID lists every request/grant. MCP-13.

```json
{"type":"object","properties":{},"additionalProperties":false}
```

Lean direct argument reads: none. This is a read inventory, not proof that helper effects honor every argument; shared helpers may receive the entire argument object.

#### `request_privileged_access` — D

Rust `src/api/privilege_broker.rs:2791`; minimum role **Executor**, mutation **false**. Lean `lean/OrbCore/OrbCore/McpGateway.lean:1072-1084`. Real request persistence; default scope service_deploy/TTL30 vs Rust root_exec/240. Absent from catalogue. MCP-13.

```json
{"type":"object","required":["reason"],"properties":{"target_host":{"type":"string","default":"self"},"scope":{"type":"string","enum":["ops_read","service_deploy","root_exec"],"default":"root_exec"},"allowed_unit":{"type":"string"},"session_scoped":{"type":"boolean","default":true},"ttl_minutes":{"type":"integer","minimum":1,"maximum":240},"reason":{"type":"string","minLength":1,"maxLength":500}},"additionalProperties":false}
```

Rust documented omission/default behavior: `ttl_minutes`: Max grant lifetime in minutes (default 240).

Lean direct argument reads: `scope`, `target_host`, `reason`, `allowed_unit`, `allowed_units`, `ttl_minutes`, `session_scoped`. This is a read inventory, not proof that helper effects honor every argument; shared helpers may receive the entire argument object.

#### `list_privileged_access` — D

Rust `src/api/privilege_broker.rs:2840`; minimum role **Executor**, mutation **false**. Lean `lean/OrbCore/OrbCore/McpGateway.lean:1085-1087`. External empty-mission query returns all leases including tokens. MCP-13.

```json
{"type":"object","properties":{},"additionalProperties":false}
```

Lean direct argument reads: none. This is a read inventory, not proof that helper effects honor every argument; shared helpers may receive the entire argument object.

#### `revoke_privileged_access` — D

Rust `src/api/privilege_broker.rs:2845`; minimum role **Executor**, mutation **false**. Lean `lean/OrbCore/OrbCore/McpGateway.lean:1088-1092`. request_id ignored; reads grant_id/id. MCP-13.

```json
{"type":"object","required":["request_id"],"properties":{"request_id":{"type":"string","format":"uuid"}},"additionalProperties":false}
```

Lean direct argument reads: `grant_id`, `id`. This is a read inventory, not proof that helper effects honor every argument; shared helpers may receive the entire argument object.

#### `execute_privileged_command` — D

Rust `src/api/privilege_broker.rs:2857`; minimum role **Executor**, mutation **false**. Lean `lean/OrbCore/OrbCore/McpGateway.lean:1093-1096`. Explicitly rejected with privilege_requires_lease; no MCP bridge to checked execution. Absent catalogue. MCP-13.

```json
{"type":"object","required":["target_host","argv"],"properties":{"target_host":{"type":"string"},"argv":{"type":"array","items":{"type":"string"},"minItems":1},"cwd":{"type":"string"},"request_id":{"type":"string","format":"uuid"},"lease_token":{"type":"string"}},"additionalProperties":false}
```

Rust documented omission/default behavior: `request_id`: Optional UUID of the approved privilege request (if omitted, automatically uses this mission's active grant for `target_host`).

Lean direct argument reads: none. This is a read inventory, not proof that helper effects honor every argument; shared helpers may receive the entire argument object.

#### `create_worktree` — M

Rust `src/control_mcp/workspace_ops.rs:10`; minimum role **Coordinator**, mutation **true**. Lean none; fallback `lean/OrbCore/OrbCore/McpGateway.lean:1106-1107`. No gateway branch; advertising/schema existence is not effect. MCP-15.

```json
{"type":"object","properties":{"path":{"type":"string"},"branch":{"type":"string"},"base":{"type":"string"},"mission_id":{"type":"string","format":"uuid"},"repo_path":{"type":"string"},"idempotency_key":{"type":"string","minLength":1,"maxLength":200}},"required":["path","branch","mission_id","idempotency_key"],"additionalProperties":false}
```

#### `remove_worktree` — M

Rust `src/control_mcp/workspace_ops.rs:11`; minimum role **Coordinator**, mutation **true**. Lean none; fallback `lean/OrbCore/OrbCore/McpGateway.lean:1106-1107`. No gateway branch; advertising/schema existence is not effect. MCP-15.

```json
{"type":"object","properties":{"path":{"type":"string"},"mission_id":{"type":"string","format":"uuid"},"repo_path":{"type":"string"},"idempotency_key":{"type":"string","minLength":1,"maxLength":200}},"required":["path","mission_id","idempotency_key"],"additionalProperties":false}
```

#### `merge_branch` — M

Rust `src/control_mcp/workspace_ops.rs:12`; minimum role **Coordinator**, mutation **true**. Lean none; fallback `lean/OrbCore/OrbCore/McpGateway.lean:1106-1107`. No gateway branch; advertising/schema existence is not effect. MCP-15.

```json
{"type":"object","properties":{"source_branch":{"type":"string"},"target_branch":{"type":"string"},"push":{"type":"boolean"},"delete_source":{"type":"boolean"},"mission_id":{"type":"string","format":"uuid"},"repo_path":{"type":"string"},"idempotency_key":{"type":"string","minLength":1,"maxLength":200}},"required":["source_branch","target_branch","mission_id","idempotency_key"],"additionalProperties":false}
```

#### `schedule_wakeup` — D

Rust `src/control_mcp/scheduling.rs:5`; minimum role **Executor**, mutation **true**. Lean `lean/OrbCore/OrbCore/McpGateway.lean:303-356`. Real registerContinuation; unadvertised mission_id/next_at accepted; coordinator cross-target scope not checked. MCP-01/03.

```json
{"type":"object","required":["prompt","reason","delay_seconds","idempotency_key"],"properties":{"prompt":{"type":"string","minLength":1},"reason":{"type":"string","minLength":1},"delay_seconds":{"type":"integer","minimum":60,"maximum":3600},"idempotency_key":{"type":"string","minLength":1,"maxLength":200}},"additionalProperties":false}
```

Lean direct argument reads: `mission_id`, `prompt`, `reason`, `delay_seconds`, `delaySeconds`, `next_at`, `nextAt`. This is a read inventory, not proof that helper effects honor every argument; shared helpers may receive the entire argument object.

#### `schedule_job_wakeup` — D

Rust `src/control_mcp/scheduling.rs:5`; minimum role **Executor**, mutation **true**. Lean `lean/OrbCore/OrbCore/McpGateway.lean:357-402`. Real registerContinuation with one-day due; actual terminal job integration not established for fabricated MCP jobs. MCP-04; U for end-to-end job wake.

```json
{"type":"object","required":["prompt","reason","job_id","idempotency_key"],"properties":{"prompt":{"type":"string","minLength":1},"reason":{"type":"string","minLength":1},"job_id":{"type":"string","format":"uuid"},"idempotency_key":{"type":"string","minLength":1,"maxLength":200}},"additionalProperties":false}
```

Lean direct argument reads: `mission_id`, `job_id`, `jobId`, `prompt`, `reason`. This is a read inventory, not proof that helper effects honor every argument; shared helpers may receive the entire argument object.

Published-tool classification totals: **E=0**, **D=73**, **S=9**, **M=9**, **U=0**. D includes working subsets with the global admission/receipt regression; it does not imply every invocation fails.

### B. Historical definitions excluded by Rust publication policy (23)

These are **U (not a published Rust MCP promise)**. Their source schemas are listed to avoid hiding tools found by broad source search. No restoration ticket is implied. `mod.rs:64-150,300-307` intentionally filters them out; replacement/current Lean branches are pointers only, not equivalence.

- **`ask_worker` — U**; Rust `src/control_mcp/orchestrator.rs:794`; related `lean/OrbCore/OrbCore/McpGateway.lean:561` (`ask_mission`), not an alias implementation. Arguments `{"type":"object","required":["mission_id"],"properties":{"mission_id":{"type":"string"},"question":{"type":"string"},"timeout_seconds":{"type":"number"},"baseline":{"type":"object"}}}`.

- **`batch_create_workers` — U**; Rust `src/control_mcp/orchestrator.rs:673`; no established corresponding Lean MCP handler. Arguments `{"type":"object","required":["workers"],"properties":{"workers":{"type":"array","items":{"type":"object","required":["title","prompt"],"properties":{"backend":{"type":"string","enum":["claudecode","codex","opencode","grok","antigravity","vibe"]},"model_override":{"type":"string"},"model_effort":{"type":"string","enum":["low","medium","high","xhigh","max"]},"agent":{"type":"string"},"config_profile":{"type":"string"},"working_directory":{"type":"string"},"remote_node_id":{"type":"string"},"placement":{"type":"string","enum":["core"]},"idempotency_key":{"type":"string"},"estimated_disk_gib":{"type":"integer","minimum":1,"maximum":512},"workspace_id":{"type":"string"},"prompt":{"type":"string"}}}}}}`.

- **`cancel_all_workers` — U**; Rust `src/control_mcp/orchestrator.rs:768`; no established corresponding Lean MCP handler. Arguments `{"type":"object","properties":{}}`.

- **`cancel_worker` — U**; Rust `src/control_mcp/orchestrator.rs:754`; related `lean/OrbCore/OrbCore/McpGateway.lean:612` (`cancel_mission`), not an alias implementation. Arguments `{"type":"object","required":["mission_id"],"properties":{"mission_id":{"type":"string"}}}`.

- **`check_workers_health` — U**; Rust `src/control_mcp/orchestrator.rs:714`; related `lean/OrbCore/OrbCore/McpGateway.lean:282` (`get_fleet_sweep`), not an alias implementation. Arguments `{"type":"object","properties":{}}`.

- **`create_worker_mission` — U**; Rust `src/control_mcp/orchestrator.rs:616`; related `lean/OrbCore/OrbCore/McpGateway.lean:473` (`start_mission`), not an alias implementation. Arguments `{"type":"object","required":["title","prompt"],"properties":{"remote_node_id":{"type":"string"},"placement":{"type":"string","enum":["core"]},"idempotency_key":{"type":"string"},"backend":{"type":"string","enum":["claudecode","codex","opencode","grok","antigravity","vibe"]},"model_override":{"type":"string"},"model_effort":{"type":"string","enum":["low","medium","high","xhigh","max"]},"agent":{"type":"string"},"config_profile":{"type":"string"},"working_directory":{"type":"string"},"estimated_disk_gib":{"type":"integer","minimum":1,"maximum":512},"workspace_id":{"type":"string"},"prompt":{"type":"string"}}}`.

- **`download_shared_file` — U**; Rust `src/control_mcp/assistant.rs:2018`; related `lean/OrbCore/OrbCore/McpGateway.lean:467` (`list_mission_shared_files`), not an alias implementation. Arguments `{"type":"object","required":["mission_id","url"],"properties":{"mission_id":{"type":"string"},"url":{"type":"string"},"filename":{"type":"string"},"output_dir":{"type":"string"}}}`.

- **`durable_job_cancel` — U**; Rust `src/control_mcp/orchestrator.rs:509`; related `lean/OrbCore/OrbCore/McpGateway.lean:1039` (`cancel_workspace_job`), not an alias implementation. Arguments `{"type":"object","required":["job_id"],"properties":{"job_id":{"type":"string"}}}`.

- **`durable_job_list` — U**; Rust `src/control_mcp/orchestrator.rs:482`; no established corresponding Lean MCP handler. Arguments `{"type":"object","properties":{}}`.

- **`durable_job_logs` — U**; Rust `src/control_mcp/orchestrator.rs:496`; related `lean/OrbCore/OrbCore/McpGateway.lean:1039` (`get_workspace_job`), not an alias implementation. Arguments `{"type":"object","required":["job_id"],"properties":{"job_id":{"type":"string"},"tail_bytes":{"type":"integer"},"stream":{"type":"string","enum":["stdout","stderr"]}}}`.

- **`durable_job_start` — U**; Rust `src/control_mcp/orchestrator.rs:469`; related `lean/OrbCore/OrbCore/McpGateway.lean:1039` (`start_workspace_job`), not an alias implementation. Arguments `{"type":"object","required":["command"],"properties":{"command":{"type":"string"},"cwd":{"type":"string"},"env":{"type":"object","additionalProperties":{"type":"string"}}}}`.

- **`durable_job_status` — U**; Rust `src/control_mcp/orchestrator.rs:487`; related `lean/OrbCore/OrbCore/McpGateway.lean:1039` (`get_workspace_job`), not an alias implementation. Arguments `{"type":"object","required":["job_id"],"properties":{"job_id":{"type":"string"}}}`.

- **`get_mission_digest` — U**; Rust `src/control_mcp/assistant.rs:1981`; related `lean/OrbCore/OrbCore/McpGateway.lean:431` (`get_mission`), not an alias implementation. Arguments `{"type":"object","required":["mission_id"],"properties":{"mission_id":{"type":"string"}}}`.

- **`get_worker_diagnostics` — U**; Rust `src/control_mcp/orchestrator.rs:736`; related `lean/OrbCore/OrbCore/McpGateway.lean:431` (`get_mission_diagnostics`), not an alias implementation. Arguments `{"type":"object","required":["mission_id"],"properties":{"mission_id":{"type":"string"},"event_limit":{"type":"integer"}}}`.

- **`get_worker_status` — U**; Rust `src/control_mcp/orchestrator.rs:722`; related `lean/OrbCore/OrbCore/McpGateway.lean:431` (`get_mission`), not an alias implementation. Arguments `{"type":"object","required":["mission_id"],"properties":{"mission_id":{"type":"string"}}}`.

- **`get_workspace_layout` — U**; Rust `src/control_mcp/orchestrator.rs:447`; no established corresponding Lean MCP handler. Arguments `{"type":"object","properties":{}}`.

- **`list_worker_missions` — U**; Rust `src/control_mcp/orchestrator.rs:706`; related `lean/OrbCore/OrbCore/McpGateway.lean:403` (`list_missions`), not an alias implementation. Arguments `{"type":"object","properties":{}}`.

- **`resume_worker` — U**; Rust `src/control_mcp/orchestrator.rs:829`; related `lean/OrbCore/OrbCore/McpGateway.lean:612` (`resume_mission`), not an alias implementation. Arguments `{"type":"object","required":["mission_id","content"],"properties":{"mission_id":{"type":"string"},"content":{"type":"string"}}}`.

- **`retask_worker` — U**; Rust `src/control_mcp/orchestrator.rs:847`; related `lean/OrbCore/OrbCore/McpGateway.lean:561` (`send_message_to_mission`), not an alias implementation. Arguments `{"type":"object","required":["mission_id","content"],"properties":{"mission_id":{"type":"string"},"content":{"type":"string"}}}`.

- **`send_message_to_worker` — U**; Rust `src/control_mcp/orchestrator.rs:776`; related `lean/OrbCore/OrbCore/McpGateway.lean:561` (`send_message_to_mission`), not an alias implementation. Arguments `{"type":"object","required":["mission_id","content"],"properties":{"mission_id":{"type":"string"},"content":{"type":"string"}}}`.

- **`wait_for_any_worker` — U**; Rust `src/control_mcp/orchestrator.rs:936`; related `lean/OrbCore/OrbCore/McpGateway.lean:431` (`get_mission`), not an alias implementation. Arguments `{"type":"object","required":["mission_ids"],"properties":{"mission_ids":{"type":"array","items":{"type":"string"}},"target_statuses":{"type":"array","items":{"type":"string"}},"timeout_seconds":{"type":"integer"},"poll_interval_seconds":{"type":"integer"}}}`.

- **`wait_for_worker` — U**; Rust `src/control_mcp/orchestrator.rs:909`; related `lean/OrbCore/OrbCore/McpGateway.lean:431` (`get_mission`), not an alias implementation. Arguments `{"type":"object","required":["mission_id"],"properties":{"mission_id":{"type":"string"},"target_statuses":{"type":"array","items":{"type":"string"}},"timeout_seconds":{"type":"integer"},"poll_interval_seconds":{"type":"integer"}}}`.

- **`workspace_bash` — U**; Rust `src/control_mcp/assistant.rs:2535`; related `lean/OrbCore/OrbCore/McpGateway.lean:1039` (`start_workspace_job`), not an alias implementation. Arguments `{"type":"object","required":["command"],"properties":{"command":{"type":"string"},"workspace_id":{"type":"string"},"cwd":{"type":"string"},"timeout_secs":{"type":"integer"},"mission_id":{"type":"string"},"idempotency_key":{"type":"string"}}}`.

### C. Rust builtin inventory (26; separate from control MCP)

These definitions are registered by `src/tools/mod.rs:173-256` and merged into the API tool inventory by `src/api/mcp.rs:168-215`. Lean workspace/desktop binaries run real effects for the mapped subset. U below means an MCP-facing replacement was not established, not that the whole product lacks the capability.

- **`read_file` — U**; Rust `src/tools/file_ops.rs:21`; Lean `lean/OrbBin/OrbBin/WorkspaceMcpMain.lean:167`. Arguments `{"type":"object","properties":{"path":{"type":"string"},"start_line":{"type":"integer"},"end_line":{"type":"integer"}},"required":["path"]}`.

- **`write_file` — U**; Rust `src/tools/file_ops.rs:134`; Lean `lean/OrbBin/OrbBin/WorkspaceMcpMain.lean:203`. Arguments `{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"]}`.

- **`delete_file` — E**; Rust `src/tools/file_ops.rs:251`; Lean `lean/OrbBin/OrbBin/WorkspaceMcpMain.lean:237`. Arguments `{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}`.

- **`list_directory` — U**; Rust `src/tools/directory.rs:22`; Lean `lean/OrbBin/OrbBin/WorkspaceMcpMain.lean:270`. Arguments `{"type":"object","properties":{"path":{"type":"string"},"max_depth":{"type":"integer"}},"required":["path"]}`.
  Rust documented defaults: `max_depth`: Maximum depth to traverse (default: 3)

- **`search_files` — U**; Rust `src/tools/directory.rs:106`; Lean `lean/OrbBin/OrbBin/WorkspaceMcpMain.lean:330`. Arguments `{"type":"object","properties":{"pattern":{"type":"string"},"path":{"type":"string"}},"required":["pattern"]}`.

- **`index_files` — U**; Rust `src/tools/index.rs:60`; Lean no established MCP/builtin replacement. Arguments `{"type":"object","properties":{"path":{"type":"string"},"output_path":{"type":"string"},"max_depth":{"type":"integer"},"max_files":{"type":"integer"},"ignore_dirs":{"type":"array","items":{"type":"string"}},"include_hidden":{"type":"boolean"}},"required":[]}`.
  Rust documented defaults: `max_depth`: Optional: maximum directory depth to traverse (default: unlimited).; `max_files`: Optional: stop after indexing this many files (default: 200000).; `ignore_dirs`: If omitted, uses a sensible default (e.g., .git, node_modules, target, proc, sys).; `include_hidden`: Whether to include hidden directories (starting with '.') (default: false; except '.' itself).

- **`search_file_index` — U**; Rust `src/tools/index.rs:206`; Lean no established MCP/builtin replacement. Arguments `{"type":"object","properties":{"query":{"type":"string"},"index_path":{"type":"string"},"limit":{"type":"integer"},"case_sensitive":{"type":"boolean"}},"required":["query"]}`.
  Rust documented defaults: `limit`: Max matches to return (default: 100); `case_sensitive`: Whether matching is case-sensitive (default: false)

- **`run_command` — U**; Rust `src/tools/terminal.rs:1016`; Lean no established MCP/builtin replacement. Arguments `{"type":"object","properties":{"command":{"type":"string"},"cwd":{"type":"string"},"timeout_secs":{"type":"integer"},"timeout_ms":{"type":"integer"},"timeout":{"type":"number"},"env":{"type":"object","additionalProperties":{"type":"string"}},"clear_env":{"type":"boolean"},"stdin":{"type":"string"},"shell":{"type":"string"},"max_output_chars":{"type":"integer"},"raw":{"type":"boolean"}},"required":["command"]}`.
  Rust documented defaults: `timeout_secs`: Timeout in seconds (default: 60).; `shell`: Optional: shell executable path (default: /bin/sh).; `max_output_chars`: Maximum output characters to return (default: 10000).

- **`grep_search` — U**; Rust `src/tools/search.rs:23`; Lean `lean/OrbBin/OrbBin/WorkspaceMcpMain.lean:356`. Arguments `{"type":"object","properties":{"pattern":{"type":"string"},"path":{"type":"string"},"file_pattern":{"type":"string"},"case_sensitive":{"type":"boolean"}},"required":["pattern"]}`.
  Rust documented defaults: `case_sensitive`: Whether search is case-sensitive (default: false)

- **`fetch_url` — U**; Rust `src/tools/web.rs:21`; Lean `lean/OrbBin/OrbBin/WorkspaceMcpMain.lean:489`. Arguments `{"type":"object","properties":{"url":{"type":"string"}},"required":["url"]}`.

- **`ui_optionList` — U**; Rust `src/tools/ui.rs:18`; Lean no established MCP/builtin replacement. Arguments `{"type":"object","required":["id","columns","rows"],"properties":{"id":{"type":"string"},"columns":{"type":"array","items":{"type":"object"},"minItems":1},"rows":{"type":"array","items":{"type":"object"}}},"additionalProperties":true}`.

- **`ui_dataTable` — U**; Rust `src/tools/ui.rs:68`; Lean no established MCP/builtin replacement. Arguments `{"type":"object","required":["id","columns","rows"],"properties":{"id":{"type":"string"},"columns":{"type":"array","items":{"type":"object"},"minItems":1},"rows":{"type":"array","items":{"type":"object"}}},"additionalProperties":true}`.

- **`analyze_codebase` — U**; Rust `src/tools/composite.rs:17`; Lean no established MCP/builtin replacement. Arguments `{"type":"object","properties":{"path":{"type":"string"},"max_depth":{"type":"integer"}},"required":[]}`.
  Rust documented defaults: `path`: Path to the codebase directory (default: current directory); `max_depth`: Maximum directory depth to explore (default: 3)

- **`deep_search` — U**; Rust `src/tools/composite.rs:180`; Lean no established MCP/builtin replacement. Arguments `{"type":"object","properties":{"pattern":{"type":"string"},"path":{"type":"string"},"file_types":{"type":"string"},"context_lines":{"type":"integer"}},"required":["pattern"]}`.
  Rust documented defaults: `path`: Path to search in (default: current directory); `context_lines`: Number of context lines before and after match (default: 2)

- **`prepare_project` — U**; Rust `src/tools/composite.rs:312`; Lean no established MCP/builtin replacement. Arguments `{"type":"object","properties":{"path":{"type":"string"}},"required":[]}`.
  Rust documented defaults: `path`: Path to the project directory (default: current directory)

- **`debug_error` — U**; Rust `src/tools/composite.rs:457`; Lean no established MCP/builtin replacement. Arguments `{"type":"object","properties":{"error_message":{"type":"string"},"path":{"type":"string"}},"required":["error_message"]}`.
  Rust documented defaults: `path`: Path to the codebase to search for related code (default: current directory)

- **`desktop_start_session` — U**; Rust `src/tools/desktop.rs:288`; Lean `lean/OrbBin/OrbBin/DesktopMcpMain.lean:159`. Arguments `{"type":"object","properties":{"launch_browser":{"type":"boolean"},"url":{"type":"string"}},"required":[]}`.
  Rust documented defaults: `launch_browser`: If true, automatically launch Chromium browser after starting the session (default: false)

- **`desktop_stop_session` — U**; Rust `src/tools/desktop.rs:475`; Lean `lean/OrbBin/OrbBin/DesktopMcpMain.lean:274`. Arguments `{"type":"object","properties":{"display":{"type":"string"}},"required":["display"]}`.

- **`desktop_screenshot` — D**; Rust `src/tools/desktop.rs:553`; Lean `lean/OrbBin/OrbBin/DesktopMcpMain.lean:302`. Arguments `{"type":"object","properties":{"display":{"type":"string"},"wait_seconds":{"type":"number"},"return_image":{"type":"boolean"},"filename":{"type":"string"},"region":{"type":"object","properties":{"x":{"type":"integer"},"y":{"type":"integer"},"width":{"type":"integer"},"height":{"type":"integer"}}}},"required":["display"]}`.
  Rust documented defaults: `description`: Description for the image (default: 'screenshot'); `filename`: Optional filename for the screenshot (default: auto-generated with timestamp)

- **`desktop_type` — U**; Rust `src/tools/desktop.rs:690`; Lean `lean/OrbBin/OrbBin/DesktopMcpMain.lean:337`. Arguments `{"type":"object","properties":{"display":{"type":"string"},"text":{"type":"string"},"key":{"type":"string"},"delay_ms":{"type":"integer"}},"required":["display"]}`.
  Rust documented defaults: `delay_ms`: Delay between keystrokes in milliseconds (default: 12, increase for slow applications)

- **`desktop_click` — U**; Rust `src/tools/desktop.rs:780`; Lean `lean/OrbBin/OrbBin/DesktopMcpMain.lean:359`. Arguments `{"type":"object","properties":{"display":{"type":"string"},"x":{"type":"integer"},"y":{"type":"integer"},"button":{"type":"string","enum":["left","middle","right"]},"double":{"type":"boolean"},"hold_ms":{"type":"integer"}},"required":["display","x","y"]}`.
  Rust documented defaults: `button`: Mouse button to click (default: 'left'); `double`: If true, perform a double-click (default: false)

- **`desktop_get_text` — D**; Rust `src/tools/desktop.rs:870`; Lean `lean/OrbBin/OrbBin/DesktopMcpMain.lean:424`. Arguments `{"type":"object","properties":{"display":{"type":"string"},"method":{"type":"string","enum":["accessibility","ocr","both"]},"max_depth":{"type":"integer"}},"required":["display"]}`.
  Rust documented defaults: `method`: 'accessibility' uses AT-SPI (best for browsers/apps), 'ocr' uses Tesseract (works on any content), 'both' tries accessibility first then OCR (default: 'accessibility'); `max_depth`: Maximum depth to traverse in accessibility tree (default: 10)

- **`desktop_mouse_move` — U**; Rust `src/tools/desktop.rs:1085`; Lean `lean/OrbBin/OrbBin/DesktopMcpMain.lean:381`. Arguments `{"type":"object","properties":{"display":{"type":"string"},"x":{"type":"integer"},"y":{"type":"integer"}},"required":["display","x","y"]}`.

- **`desktop_scroll` — U**; Rust `src/tools/desktop.rs:1140`; Lean `lean/OrbBin/OrbBin/DesktopMcpMain.lean:392`. Arguments `{"type":"object","properties":{"display":{"type":"string"},"amount":{"type":"integer"},"x":{"type":"integer"},"y":{"type":"integer"}},"required":["display","amount"]}`.

- **`desktop_i3_command` — U**; Rust `src/tools/desktop.rs:1219`; Lean `lean/OrbBin/OrbBin/DesktopMcpMain.lean:409`. Arguments `{"type":"object","properties":{"display":{"type":"string"},"command":{"type":"string"}},"required":["display","command"]}`.

- **`complete_mission` — U**; Rust `src/tools/mission.rs:95`; Lean no established MCP/builtin replacement. Arguments `{"type":"object","properties":{"status":{"type":"string","enum":["completed","failed","blocked","not_feasible"]},"summary":{"type":"string"},"blocker_type":{"type":"string","enum":["type_mismatch","access_denied","resource_unavailable","tool_failure","other"]},"attempted":{"type":"array","items":{"type":"string"}}},"required":["status"]}`.

### D. Behavioral defaults/limits not automatically supplied by schema

These override a naive reading of an optional field. Absence otherwise preserves/unsets the typed optional value; exact provider/REST-derived defaults are delegated to the existing owner where indicated, not invented from a missing schema `default`.

| Family | Rust actual/default behavior | Lean actual/default behavior and effect |
| --- | --- | --- |
| All mutations | Key required, canonical fingerprint, reserve before effect; role and all schema bounds rechecked. | No general key/schema enforcement; key optional in practice; many effects have no receipt. MCP-01/03. |
| Action waits | timeout_ms=15000, 0..30000; return_when=all; 1..64 IDs. Sweep wait=0, max25000, worker limit128 max256; include_completed/machines=true, offset0. | Wait does not wait and always all_succeeded; sweep reads none of these fields. |
| Mission lists | limit50, clamped1..100, offset0; filters absent mean no requested filter; active list scans bounded pages, next_offset. `assistant.rs:200-219,2647-2730`. | limit50 max200, offset0, status/project/folder/track only; no continuation cursor projection. |
| Events/shared files | limit40; events newest page by default, before_seq takes precedence, max_payload4096 clamped1024..65536; view optional. `assistant.rs:222-247,1331-1407,2752-2838`. | events limit100 max500, after_seq0 and fixed32768 payload, no before cursor; shared files always empty. Recovery owner. |
| Native mission | writer=false and merge authority=false; fast_mode=false at adapter, default workspace resolution via HERMES_DEFAULT_WORKSPACE_ID / ASSISTANT_DEFAULT_WORKSPACE_ID. Backend availability/placement chosen through admitted handler, not universal claudecode default. `assistant.rs:2867-3078`. | backend=claudecode (claude alias), title=Delegated Mission, prompt empty, project=caller, folder empty, parent=caller (but caller can override), node inherited, authority=writer, empty workspace UUID; most accepted fields unused. |
| Consultation | read_only=true; optional model OR models quorum, validate all before launch; backend opencode; prompt includes question/files; remote placement through launch rules. `assistant.rs:3099-3242`. | backend opencode, always readonly; prompt only prompt/goal (empty for valid question request); single model alias, no files/quorum; get returns raw detail. |
| Send/Ask/answers | queue mode default; auto_replace_on_same_node=false; omitted retask fields preserve identity; ask sandbox=false/new thread if absent; omitted tool_call_id resolves unique pending question; answers nonempty nested arrays. `assistant.rs:1024-1064,3418-3590`. | scalar content extraction only, no structured answers; Ask no thread/sandbox; only send wakes remote. Idempotent acceptance is not equivalent to delivered:true. |
| Resume/settings | clean_workspace=false; content optional invokes harness-specific native continuation/default, identity preserved on omission; settings optional fields preserve existing settings. | remote resume prompt/message or Continue., content ignored; no local runner in fallback; only three settings columns written, title is an undeclared extra. Recovery owns content fix. |
| Raw VM op | required operation enum; exec timeout60 bounded1..120; file operations use path/content rather than requiring command. | always requires command, timeout60 without upper bound, uses enrolled-node exec rather than raw provider operation. Existing provider owner. |
| Managed spawn | provider boat default; sizing can be selected from constraints; TTL60 max720; provisioning worker default; snapshot light default; commitment=false; provider-specific shape/cache/retention/hook options. `assistant.rs:260-303,1832-1857,3738-3795`. | provider boat,size small,TTL60; whole args forwarded to real configured worker, but quotes/provider support and snapshot scope can reject; do not infer support merely from forwarding. Lifecycle/provider owner. |
| Managed list/lifecycle | mission list scope own_pool, verbose=false, pool_only alias; resume/fork/extend honor requested TTL through provider service; delete snapshots by registry name. | full fleet list; lifecycle only machine/action (TTL ignored); fork copies old size/TTL; delete reads snapshot_id/id, not required name. Existing owner. |
| Workspace jobs | exactly one command/argv; default workspace from environment; timeout7200 clamped1..86400; logs tail16384 clamped1..65536. `assistant.rs:1084-1152,3365-3415`. | no execution/default enforcement at all; invented terminal statuses. |
| Project grants | optional fields preserve, explicit clears handled by store contract; autonomy validated; real project required. | setter missing in gateway; REST NULLIF+COALESCE loses clears, zero parallel reads null. |
| Evidence/review | before changing acceptance, validate immutable evidence and revision; review history_limit=6; key or task_id resolves within caller's board. `orchestrator.rs:266-268,1979-2035`. | status writes; history_limit/task_id ignored; review changes status rather than returning evidence. |
| Project proposals | title/key required per task, criteria/dependencies default empty; omitted editable options preserve existing values. Whole plan validates before writes. | only task_key/key (random UUID if absent),track default,mission_id empty,status open stored; updates default status done. |
| Decisions/status | kind/authority/status disposition derived under actual project contract; structured evidence optional; answers identify at; consumed steers acknowledged. | authority escalation,status pending; evidence string default empty; answer reads id; consumed IDs ignored. |
| Access | scope read default or control; TTL24h clamped1..168; subject is owner+mission/external session. | always read; TTL24 clamped1..168; empty mission collapses external subjects. |
| Privilege | target self,scope root_exec,session_scoped=true,TTL240 max240; required nonempty reason max500; revoke request_id. | target self,scope service_deploy,session_scoped=true,TTL30 clamped1..240; no schema gate; revoke grant_id/id. Execute explicitly refused instead of audited MCP operation. |
| Deployment | force=false,skip_build=false; target resolution constrained by backend implementation. | no gateway implementation. |
| Basic file tools | start_line1,end_line=total; path required, working-directory resolution; absolute paths supported. read ranges normalize according to Rust implementation. `file_ops.rs:21-128`. | real FS effects; read range swaps reversed bounds (`WorkspaceMcpMain.lean:185-187`); write verifies byte length and warns; delete primitive matches existence-check/remove effect (E narrowly scoped). |
| Directory/search | list max_depth3; search path='.'; index max_files200000,hidden=false,depth unbounded,default ignore dirs/index file; index-search limit100,case_sensitive=false. `directory.rs:51,135`, `index.rs:103-138,246-248`. | list depth3; search path='.', case-insensitive filename matching with star-only matcher and max100; indexing counterparts unestablished. |
| Grep | path='.',case_sensitive=false, file_pattern optional; real rg/grep behavior in `search.rs:56-150`. | same basic defaults/real subprocess; caps output100; fallback/error semantics not fully equivalent. |
| Command builtin | timeout_ms takes precedence over timeout_secs then timeout; explicit integer timeouts have minimum1 and cap3600s; absent/invalid floating timeout returns SANDBOXED_SH_COMMAND_TIMEOUT_SECS if positive, else300s (the early default return is not capped). `terminal.rs:517-549`. max_output_chars=10000, cap50000; env optional, clear_env=false,raw=false; shell/stdin optional (`:615-639`). | No established corresponding MCP builtin; native harness Bash is not asserted equivalent. |
| Composite builtins | path='.'; analyze depth3; deep_search context_lines2, optional file_types; prepare/debug real workspace analysis (`composite.rs:43-44,215-226,334,488`). | No established MCP replacement. |
| UI/completion builtins | option-list multiple=false; payload schemas include required IDs/options or columns/rows; complete_mission has real mission-control side effects, not just UI JSON. | No established builtin registration replacement; do not equate a native agent stopping with complete_mission. |
| Desktop | start launch_browser=false,url about:blank,resolution env DESKTOP_RESOLUTION or1280x720; screenshot wait0.0,region x/y0,width/height100,return_image=false; type delay12ms; click left,double=false; text method accessibility,max_depth10. `desktop.rs:46,377-379,610-667,728,835-840,905-906`. | Real Wayland subprocesses; screenshot integer wait only; type real wtype; click real wlrctl; text always OCR and ignores method/max_depth; session lifecycle/locks and other OS semantics remain U rather than name-based E. |

### E. Lean-only catalogue entries and schema drift checklist

- `memory_search_knowledge(query*,bank,limit)`, `memory_get_knowledge_page(path*,bank)`, `memory_get_knowledge_tree(path,bank)`, `memory_recall(query*,bank,max_tokens)`: **U relative to this Rust registry** (no published baseline entries). Real broker dispatch is `MemoryAndCloud.lean:195-265`, called by `Control.lean:2277-2322`; caller/managed-node/bunker gates exist. Credential availability is recovery-owned. This is not an empty stub.
- Five template tools listed in surface accounting: **M at Lean gateway** despite catalogue presence. Their extra name/config/profile/template/plugin/encryption arguments are not a Rust public-registry regression. Stop advertising unsupported calls rather than confusing them with the missing Rust workspace lifecycle methods.
- Copied Lean schemas omit baseline additions even when a name intersects: managed provider/GPU/arch/pricing/cache/provisioning fields; raw operations entirely; list managed pool scope; events max_payload; consultation quorum/batch-result/placement fields; send mode/delivery/auto-replacement; and start_mission's later managed warm-cache/retention/budget fields. See the source-derived schemas above, not the 93-name JSON snapshot, for the full baseline argument set.
- Client `SandboxedMcpMain.lean:759-835` guesses mutation from a static name array or a supplied key and normalizes receipts. `McpCatalog.lean:25-38` omits exec_raw_managed_machine from that static mutation array as well as from the catalogue. This cannot repair server reservation/authorization; on a raw call without a key it also weakens transport-uncertainty classification. Coordinate the raw managed tool with the existing provider owner.
- Self-tests or formal exports showing a policy helper exists do not establish that `POST /api/mcp/call` invokes it. Review must follow actual dispatcher branches through I/O to terminal effects.
