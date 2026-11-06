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
