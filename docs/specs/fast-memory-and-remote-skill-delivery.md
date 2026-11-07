# Governed Memory MCP Broker, Remote Skill Archive Retention, Proxy Exhaustion Classification, and Instant Cloud-to-Workspace Handoff

## Problem

Forensic inspection of mission `c2dcb8ab-2065-4569-a96d-c7673352125b` (`assistant` project on remote node `babylon`) and `builtin/fast` routing on `orbcore.thomas.md` uncovered four compounding failure modes:

1. **Premature deletion of cached remote Library skill archives (`OrbNode.FileBrowser.cleanupPromptUploads` vs shared `library-skills-*.tar.gz`):**
   - Core uploads `library-skills-<sha12>.tar.gz` once to `POST <node>/uploads` (`<work_root>/uploads/<uuid>/library-skills-<sha12>.tar.gz`) and reuses that path across missions within the node upload retention window (`6h`).
   - When the **first** job referencing that archive finishes, `OrbNode.Runner` runs post-job upload cleanup on the command string. Deleting `<uploads>/<uuid>` unconditionally after the first job strips subsequent missions on that node of their shared skill bundle until the cache expires.

2. **Multi-turn shell + raw-secret ceremony for personal memory retrieval (`spark-memory`):**
   - Agents on remote worker nodes previously had to call `secret_get(HINDSIGHT_API_KEY)` (blocking on Touch ID approval whenever a project such as `assistant` was not bound to Bitwarden `default_access`, and exposing a bearer token into the worker's LLM context) followed by manual `curl` JSON-RPC handshakes against `https://memory.thomas.md/mcp/<bank>/`.

3. **Opaque proxy chain exhaustion error on `HTTP 402` / `out_of_credit` (`payment_required`):**
   - When an upstream provider such as `particle/particle-ai/particle-1` returned `HTTP 402 Payment Required` (`"insufficient balance"`), pre-header chain routing and terminal exhaustion classification needed to treat `402` as pre-commitment failover-eligible while surfacing explicit `out_of_credit` diagnostics when every candidate in a chain exhausted on billing/credit limits rather than conflating it with `401`/`403` auth errors.

4. **Workspace harness startup overhead for quick memory/question turns:**
   - Spawning a full workspace harness (`opencode`/`claudecode`/`codex`) plus `sandboxed-mcp launch` (`initialize` + `tools/list` preflight repeated in child stdio server) and `500 ms` remote poll ticks incurred multi-second cold-start overhead for quick questions that Paloma (`cloud_hermes`) can answer immediately, while cloud conversations lacked a one-click handoff into a workspace harness when code/shell execution became necessary.

## Pure Lean 4 Formal Kernel Contracts (`lean/Orb/Kernel.lean` & `lean/Orb/Spec.lean`)

All admission, retention, exhaustion-classification, polling, caching, composer-default, and handoff decisions live in the shared pure Lean 4 kernel (`lean/Orb/Kernel.lean`, `0 import Lean`, `0 sorryAx`) and are proved non-vacuous and tight in `lean/Orb/Spec.lean` under Layer 0 (`MetaGateSpec`) and Layer I (`ScopedAuthority`, `ConservedResource`, `ProjectionStability`):

### 1. Governed Read-Only Memory MCP Gate (`orb_memory_tool_gate` / `Orb.Kernel.memoryToolGate`)

Decides whether an MCP caller may invoke a Core-brokered read-only Hindsight memory tool without ever receiving raw `HINDSIGHT_API_KEY` / `SPARK_MEMORY_API_TOKEN` material:

- **Inputs:**
  - `opKind : UInt8`: `0 = search_knowledge`, `1 = get_knowledge_page`, `2 = get_knowledge_tree`, `3 = recall` (`>= 4` = unknown or mutating operation -> rejected).
  - `callerRole : UInt8`: `0 = Executor`, `1 = Coordinator`, `2 = Operator` (`> 2` -> rejected).
  - `isExternalSession : UInt8`: `1` when the MCP session is an external missionless client, `0` for Core-minted sessions.
  - `bunkerState : UInt8`: `0 = Normal`, `1 = SoftQuarantine`, `>= 2 = HardLockdown`.
  - `onManagedNode : UInt8`: `1` when the calling mission runs on an untrusted ephemeral `managed-*` cloud VM.
  - `hasProjectMemorySkill : UInt8`: `1` when a non-external mission's Paloma project explicitly attaches `spark-memory`.
  - `hasSecretAccess : UInt8`: `1` when secret governance grants read access to `HINDSIGHT_API_KEY` or `SPARK_MEMORY_API_TOKEN`.
  - `bankKind : UInt8`: `0 = thomas`, `1 = ppl` (`>= 2` -> rejected, confining gateway URL construction to the allowlisted bank set).
  - `requestedLimit maxLimit requestedTokens maxTokens : UInt32`: bounded query result count and recall token budget.
- **Proven Invariants (`lean/Orb/Spec.lean`):** `memoryToolGateSpec` (`MetaGateSpec`), `memoryToolScopedAuthority` (`ScopedAuthority`), and `memoryToolConservedResource` (`ConservedResource`).

### 2. Upload Post-Job Cleanup Gate (`orb_upload_cleanup_gate` / `Orb.Kernel.uploadCleanupGate`)

Decides whether post-job cleanup may delete `<uploads>/<uuid>` when a single job terminates:

- **Decision (`orb_upload_cleanup_gate == 1`):** `hasValidUuid == 1 && (isSharedLibraryArchive == 0 || isExpiredForGc == 1)`.
  Single-job cleanup (`isExpiredForGc == 0`) deletes one-shot prompt attachments (`isSharedLibraryArchive == 0`) immediately while preserving shared `library-skills-*.tar.gz` bundles until TTL-based `pruneExpiredUploads` (`isExpiredForGc == 1`) reaps them.
- **Proven Invariants (`lean/Orb/Spec.lean`):** `uploadCleanupGateSpec` (`MetaGateSpec`) and `uploadCleanupScopedAuthority` (`ScopedAuthority`).

### 3. Proxy Chain Exhaustion Classifier (`orb_proxy_exhaustion_step` / `Orb.Kernel.proxyExhaustionStep`)

Deterministically partitions terminal chain exhaustion outcomes across attempted upstream hops (`1 = SkippedConfiguration`, `2 = TransportValidation`, `3 = ContextLengthExceeded`, `4 = PaymentRequiredOutOfCredit`, `5 = ClientOrAuthError`, `6 = ServerUnavailable`, `7 = RateLimitedOrQuota`), proved total and partition-stable by `proxyExhaustionProjectionStability` (`ProjectionStability`), alongside `402` pre-header failover in `Orb.Kernel.proxyClassifyHttp` / `Orb.Kernel.proxyStep`.

### 4. Cross-Client Composer Default Routing (`orb_composer_default_step` / `Orb.Kernel.composerDefaultStep`)

- **Inputs:** `hasExplicitChoice hasPinnedContext hermesAvailable hasNativeHarness : UInt8`.
- **Output (`UInt8`):** `0 = KeepExplicit`, `1 = DefaultPalomaHermes`, `2 = DefaultWorkspaceHarness`, `3 = AwaitSelection`.
- **Invariant (`composerDefaultProjectionStability`):** Preserves explicit user choices (`0`), routes unpinned quick-ask composers to Paloma (`1`) when available, routes folder/machine/workspace-pinned composers to a native workspace harness (`2`), and awaits catalog loading (`3`) when neither is ready.

### 5. Cloud-to-Workspace Handoff Admission (`orb_cloud_handoff_step` / `Orb.Kernel.cloudHandoffStep`)

- **Inputs:** `sourceIsCloud isSideQuestion targetIsNative hasHistoryTurns targetPlacementValid : UInt8`.
- **Output (`UInt8`):** `0 = Deny`, `1 = AllowHandoff`, `2 = AllowNativeFork`.
- **Invariants (`cloudHandoffGateSpec` & `cloudHandoffScopedAuthority`):** Admits `cloud_*` -> native workspace handoff (`1`) if and only if the source is a non-`/btw` cloud conversation with non-empty turn history, a native workspace harness target, and valid placement; preserves native-to-native forks (`2`) and rejects invalid combinations (`0`).

### 6. Adaptive Remote Job Burst Polling (`orb_fast_poll_delay_ms` / `Orb.Kernel.fastPollDelayMs`)

- **Inputs:** `elapsedMs steadyDelayMs : UInt32`.
- **Output (`UInt32`):** Clamps `steadyDelayMs` into `[100, 5000]`, returning `80 ms` during `[0, 4000) ms` (fast first-token & memory-question burst), `min(200, steady)` during `[4000, 15000) ms` (warm ramp), and `steady` thereafter (`fastPollDelayConserved`).

### 7. Per-Mission `sandboxed-mcp` Preflight Cache Gate (`orb_mcp_preflight_cache_gate` / `Orb.Kernel.mcpPreflightCacheGate`)

- **Inputs:** `hasCachedIdentity identityMatches contractVersionMatches : UInt8`, `ageMs maxTtlMs : UInt32`.
- **Output (`UInt8`):** `1` iff `hasCachedIdentity == 1 && identityMatches == 1 && contractVersionMatches == 1 && maxTtlMs >= 1000 && maxTtlMs <= 600000 && ageMs <= maxTtlMs` (`mcpPreflightCacheGateSpec` & `mcpPreflightCacheScopedAuthority`).

## Pure Lean 4 Runtime & Cross-Client Wiring

1. **Core Memory Broker & Companion MCP (`lean/OrbCore/OrbCore/MemoryAndCloud.lean`, `lean/OrbCore/OrbCore/Control.lean`, `lean/OrbBin/OrbBin/McpCatalog.lean`, `lean/OrbBin/OrbBin/SandboxedMcpMain.lean`):**
   - Exposes `memory_search_knowledge`, `memory_get_knowledge_page`, `memory_get_knowledge_tree`, and `memory_recall` across all 3 MCP roles (`executor`: `47`, `coordinator`: `83`, `operator`: `93`) with deterministic wire ordering.
   - Evaluates `Orb.Kernel.memoryToolGate` on every `/api/mcp/call` request, resolves `HINDSIGHT_API_KEY` / `SPARK_MEMORY_API_TOKEN` inside Core (`300 s` in-memory cache), and forwards stateless JSON-RPC `tools/call` requests to the Hindsight MCP gateway (`JSON` or `SSE` response decoding) without exposing bearer tokens to workers or logs.
   - `sandboxed-mcp` supports `--preflight-cache <path>` (`0600` owner-only) gated by `Orb.Kernel.mcpPreflightCacheGate` (`60_000 ms` TTL).

2. **Node Upload Retention & Burst Polling (`lean/OrbNode/OrbNode/FileBrowser.lean`):**
   - `cleanupPromptUploads` gates directory removal through `Orb.Kernel.uploadCleanupGate`, preserving shared `library-skills-*.tar.gz` directories until `pruneExpiredUploads` (`isExpiredForGc = true`).
   - `computeFastPollDelayMs` delegates directly to `Orb.Kernel.fastPollDelayMs`.

3. **Proxy `402` Failover & `out_of_credit` Diagnostics (`lean/OrbCore/OrbCore/Spec.lean`, `lean/OrbCore/OrbCore/Proxy.lean`):**
   - Pre-header `HTTP 402` fails over cleanly to fallback entries in chains such as `builtin/fast`, and terminal chain exhaustion classifies `paymentRequiredCount` via `Orb.Kernel.proxyExhaustionStep` (`out_of_credit`).

4. **Instant Paloma Wakeup, Incremental SSE Reducer, and Cloud-to-Workspace Handoff (`lean/OrbCore/OrbCore/MemoryAndCloud.lean`, `lean/OrbCore/OrbCore/Control.lean`, `orb/src/`, `ios_dashboard/`, `android_dashboard/`):**
   - `OrbCore.MemoryAndCloud` provides immediate wakeup notification (`notifyWake`), a `300 s` `/v1/capabilities` cache, monotone incremental SSE turn reduction (`reduceHermesSseChunk`), and `POST /api/control/missions/:id/fork` transcript synthesis gated by `Orb.Kernel.cloudHandoffStep`.
   - Desktop (`orb/src/App.tsx`, `orb/src/CloudAgents.tsx`, `orb/src/ForkMission.tsx`), iOS (`OrbConversation.swift`, `OrbForkSheet.swift`, `OrbAgentPicker.swift`), and Android (`OrbConversation.kt`, `OrbHarnessTransfer.kt`) share `composerDefaultStep` and `cloudHandoffStep` (`"Continue in workspace"`).
