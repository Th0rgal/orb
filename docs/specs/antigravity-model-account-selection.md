# Antigravity Model-Compatible Account Selection and Node Profile Isolation

## Problem

Google Antigravity rolls EAP models out per Google account. In particular,
`Gemini 4 Carbon` (`agy-model` / `agy-model-{low,medium,high}`) is exposed only
to accounts enrolled in the Carbon EAP pool (`gemini-eap`), while a higher-priority
general Ultra account on the same Orb Core may offer `Claude Opus 5.5` and
`Gemini 4 Argon` (`agy-demo-*`) without Carbon.

Two failure modes caused native `agy` runs on `agy-model-*` to launch under an
incompatible Google account and fail immediately with
`model agy-model-low is not recognized as a known model`:

1. **Unverified accounts outranking positively entitled accounts (`choose_for_model`):**
   Candidate filtering treated missing `ai_providers.json` reconciliation,
   partial/missing `model-discovery.json` entries, and unprobed accounts as
   model-compatible (`!connection_lacks(...) == true`), then sorted by base
   priority. Any unprobed or unreconciled higher-priority account therefore
   preempted a lower-priority account with positive Carbon entitlement. In
   addition, when every candidate lacked the model, `choose_for_model` fell back
   to `eligible[0]` instead of failing closed.
2. **Shared mutable node and workspace credential clobbering:**
   `sandboxed-node` stored a single shared `managed-auth/antigravity/antigravity-oauth-token`
   symlinked into every job's `.gemini/antigravity-cli`, and Core projected the
   login early during preflight (`require_node_managed_auth`) while three paths
   overwrote that shared file with the general (`model = None`) account:
   `GET /api/providers/nodes/:node_id/antigravity/models`,
   `workspace_antigravity_models`, and periodic `refresh_and_sync`.

## Formal Kernel Contract (`orb_model_account_admit` & `orb_model_account_score`)

Account admission and ranking for model-scoped pools is decided by
`Orb.Kernel.modelAccountAdmit` (`orb_model_account_admit`) and
`Orb.Kernel.modelAccountScore` (`orb_model_account_score`) in `lean/Orb/Kernel.lean`,
verified in `lean/Orb/Spec.lean` and folded through `orb_route_argmin_step`:

- **Inputs:**
  - `candId : UInt32` (`0` = invalid)
  - `ineligible : UInt8` (`1` = `NeedsVerification` or disabled)
  - `entitlement : UInt8` (`0 = LacksModel`, `1 = Unknown`, `2 = Entitled`)
  - `requireEntitled : UInt8` (`1` when an EAP-gated model requires positive
    entitlement or at least one candidate in the pool is `Entitled`)
  - `hasPoolQuota : UInt8` (`1` when the candidate's quota pool for the requested
    model is unspent and not in native refusal cooldown)
  - `priorityRank : UInt32` (`0..65535`, smaller rank = higher configured priority)
  - `usableInSecs : UInt32` (seconds until the model's quota pool resets when
    `hasPoolQuota == 0`)

- **Admission (`orb_model_account_admit == 1`):**
  A candidate is admissible if and only if:
  1. `candId != 0`,
  2. `ineligible == 0`,
  3. `entitlement == 2` (`Entitled`), OR (`entitlement == 1` (`Unknown`) AND `requireEntitled == 0`).

- **Monotone Minimize-Score Key (`orb_model_account_score` -> `orb_route_argmin_step`):**
  For every admissible candidate, `orb_model_account_score` computes a 64-bit
  minimize-score folded through `orb_route_argmin_step` (and returns `UInt64.max`
  for inadmissible candidates):
  ```text
  entitlementPenalty = if entitlement == 2 then 0 else 1
  quotaPenalty       = if hasPoolQuota == 1 then 0 else 1
  waitSecs           = if hasPoolQuota == 1 then 0 else usableInSecs
  rankClamped        = min(priorityRank, 65535)
  score = (entitlementPenalty << 50) | (quotaPenalty << 49) | (waitSecs << 16) | rankClamped
  ```

- **Proven Invariants (`lean/Orb/Spec.lean`):**
  1. **Incompatible Exclusion (`ScopedAuthority`):** `entitlement == 0` (`LacksModel`),
     `entitlement > 2`, or `ineligible != 0` is never admitted under any priority
     or quota state.
  2. **EAP / Positive-Entitlement Gate (`ScopedAuthority`):** When
     `requireEntitled == 1`, `Unknown` accounts (`entitlement == 1`) are strictly
     rejected; an unprobed high-priority account can never preempt an entitled
     account or guess on an EAP model when no account is entitled.
  3. **Entitlement Dominance (`ScopedAuthority`):** Every admissible `Entitled`
     candidate strictly beats every admissible `Unknown` candidate (`scoreEnt < scoreUnk`),
     even if the `Entitled` candidate's pool is currently on cooldown and the
     `Unknown` candidate has `priorityRank = 0` and full quota.
  4. **Pool Quota & Reset Ordering (`ClockDiscipline`):** Within the same
     entitlement tier, unspent pool quota (`hasPoolQuota == 1`) strictly beats
     spent pool quota (`hasPoolQuota == 0`); among unspent candidates, smaller
     `priorityRank` wins; among spent candidates, earlier `usableInSecs` reset wins.

## Runtime & Node Isolation

1. **Dual Entitlement Evidence:**
   Per-account Carbon / model entitlement is derived from both
   `model-discovery.json` (`Completeness::Complete` catalog observations,
   matching accounts via `cli_proxy_accounts` identity rules as well as
   `cli_proxy_auth_file`) and live Cloud Code `retrieveUserQuota` model buckets
   recorded in `antigravity_accounts::Health` (`carbon_entitled`: `Some(true)`
   when `agy-model*` / Carbon buckets appear, `Some(false)` when a non-empty
   per-model bucket list omits Carbon). All Carbon effort/alias spellings
   (`agy-model`, `agy-model-{low,medium,high}`, `gemini-4-carbon*`) resolve to
   the same entitlement family.
2. **Per-Account Node Credential Slots (`antigravity:<slot>`):**
   Core derives a deterministic non-secret slot id (`16` lowercase hex chars of
   `SHA-256(refresh_token)`) per Antigravity login and pushes it to
   `PUT /managed-auth/antigravity?slot=<slot>` (keeping the legacy body/route
   compatible with older nodes). Upgraded `sandboxed-node` instances store each
   login under `managed-auth/antigravity/accounts/<slot>/antigravity-oauth-token`,
   advertise `antigravity:<slot>` on `/heartbeat`, and bind each job's
   `<mission_dir>/.gemini/antigravity-cli/antigravity-oauth-token` symlink to
   that exact slot while keeping `conversations/` and `brain/` inside
   `<mission_dir>/.gemini/antigravity-cli/`. Concurrent Carbon and non-Carbon
   jobs on the same node never share or overwrite each other's OAuth token.
   Provisioning with a named slot and `default=false` leaves the default unmodified even on a fresh node. A request with `default=false` and no named slot is invalid. Omitting the flag retains the default-profile behavior.
3. **Legacy Node & Discovery Non-Clobbering:**
   - `submit_leased_remote_job` syncs the model-selected credential immediately
     before `submit_job` and selects `antigravity:<slot>` whenever the node
     advertises it (falling back to `antigravity` on pre-slot nodes, and failing
     closed if an explicit EAP model has no compatible connected login).
   - `GET /api/providers/nodes/:node_id/antigravity/models` only seeds a node
     when its heartbeat does not yet advertise `antigravity`, and
     `discover_workspace_antigravity_models` probes `agy models` in a temporary
     `HOME` rather than overwriting the workspace's active sign-in.
   - Periodic `refresh_and_sync` updates the default `antigravity` profile
     without touching `accounts/<slot>` bindings and skips legacy single-slot
     nodes that currently have an active or tentative remote job in `job_ledger`.

### Member catalog discovery

For a signed-in member, Core lists models discovered by the native CLI for
enabled accounts the member has selected. Each probe uses the uniquely bound
subscription, a private disposable CLI profile, and the account's resolved
transport. A refresh credential stays with its owner. A personal opt-out takes
effect even when a successful catalog is cached. Rotating the credential or
changing the route invalidates the account's cached result. When every eligible
probe fails, the dedicated endpoint returns a retryable failure. Restoring the
route allows a fresh discovery. With no eligible subscription it returns an
empty list. Loading the other harnesses never waits on native catalog discovery.

### Consumer headless eligibility on remote workers

The native launcher gives agy a local relay nonce. Core alone authenticates
gateway requests with the selected Google account through its configured
network route. A successful `v1internal:fetchUserInfo` response verifies only
that gateway request. On Linux, agy 1.5.13 also sends an authenticated GET to
`https://www.googleapis.com/oauth2/v2/userinfo` outside the configured
`CLOUD_CODE_URL`. A 401 there can stop eligibility before generation for both
Carbon and Neon. The terminal error alone does not identify which request
failed.

The worker cannot use the relay nonce as a Google OAuth credential. Remote
support needs a vendor-supported way for the selected account's credential
holder to perform this auxiliary identity check through the account's network
route and return Google's actual decision. A plain HTTPS CONNECT proxy would
transport the same nonce to Google.

To replay the rejection, use a disposable Linux guest with only loopback
enabled, map `www.googleapis.com` to `127.0.0.1` in the guest, and run:

```sh
openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
  -subj /CN=www.googleapis.com -addext subjectAltName=DNS:www.googleapis.com \
  -out cert.pem -keyout key.pem
python3 scripts/test_antigravity_native_eligibility.py \
  --agy "$(command -v agy)" --cert cert.pem --key key.pem
```

The disposable certificate is trusted only by the test process. The test
requires port 443 in the guest, rejects every identity request, and checks
the actual CLI terminal result and zero generation requests. Google's
headless CLI documentation describes using cached credentials after sign-in.
[Headless mode](https://antigravity.google/docs/cli/headless/)

### Running the signed-in CLI in a trusted per-account service

A service could keep the genuine native login and all Google traffic inside the
selected account's VPN. The remaining boundary is between that service and
mission-controlled workspace operations. On Linux agy 1.5.13 and 1.5.14, we
found no documented mode that assigns those operations exclusively to a
separately authenticated workspace executor.

* The terminal sandbox uses OS namespaces and permission-derived mounts for
  shell commands. Google documents that `--sandbox` has no effect when the
  sandbox is unavailable and describes execution outside it. The option
  specifies neither a mandatory remote runner nor the identity for other
  workspace subprocesses. Hooks can run scripts and stdio MCP servers have their
  own executable configuration. Mounting the remote checkout into the service
  solves file visibility alone.
  [Terminal sandbox](https://antigravity.google/docs/sandbox/)
  · [Hooks](https://antigravity.google/docs/hooks/)
  · [MCP transports](https://antigravity.google/docs/mcp/)
* ACP carries permission decisions and session state. In a loopback-only
  guest with an empty HOME, both binaries completed ACP v1 `initialize` with
  client terminal and file capabilities enabled. Both advertised session
  load and resume; `--process-per-session` added HTTP MCP capability. That
  handshake exercises capability negotiation only. The documented per-session
  process flag does not select an OS principal for tools. IDE MCP adds host
  tools; the documentation provides no exclusive client-execution contract
  for native commands, filesystem operations, or workspace integrations.
  [ACP interface and flags](https://antigravity.google/docs/ide/extensions/acp/)
* Remote Control attaches to the machine running the agent. Remote Agents use
  Google-managed environments and project resources. The App's SSH mode runs
  tools and saves the Google login on the SSH host. None documents a headless
  service option to bind a session to an existing Orb worker for tool execution.
  [Remote Control](https://antigravity.google/docs/remote-control/)
  · [Remote Agents](https://antigravity.google/docs/remote-agents/)
  · [SSH](https://antigravity.google/docs/ssh/)

**Minimal upstream request.** Add a mandatory workspace-executor mode to
`agy acp`. Let the authenticated service bind a session to a caller-supplied
executor for all workspace file access and process execution, including
terminal commands, hooks, and stdio MCP. Unsupported local integrations must
be disabled in that mode. Apply native tool approvals before dispatch; if the
executor disconnects, fail the operation without local fallback. The executor
receives mission-scoped authority only. OAuth, eligibility, inference and
native conversation state stay in the service.

Orb could then persist the selected account, mission, stable workspace
identity and native conversation ID together, verify that binding on resume,
and reconnect the same worker workspace. Acceptance would require a ledger
edit and resume on that worker, denial before dispatch, and a disconnected
executor producing zero local executions. The CLI scopes its local conversation
history by working directory.
[Conversation scoping](https://antigravity.google/docs/cli/conversations/)
