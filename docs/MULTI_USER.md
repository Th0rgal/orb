# Multi-User Architecture & Security Model

Orb supports first-class multi-user operation on a single Core + fleet deployment with strict owner privacy, non-admin Core exclusion, dedicated Linux user isolation on worker nodes, credential non-leakage, and dual global + per-user spend caps.

## 1. Principal Roles & Session Tokens (`orb-jwt-v2`)

Every account in `users` (`missions.db`) has one of two roles:

- **`admin`**: Manages user accounts (`/api/admin/users/*`), instance-level inference settings (routing chains, default provider, usage resets, `/api/settings`), any inference provider account, global cloud-compute provider keys and fleet routing, node administration, backups, and deploys. May launch missions on any target (`core`, colocated nodes, dedicated fleet nodes, managed VMs, or local desktop).
- **`member`**: Launches and collaborates on missions using dedicated fleet nodes, ephemeral managed VMs (`boat.dev`, Hetzner, `lean.ci`, Vast.ai, Scaleway, Colab), or their own desktop (`orb-locald`), with personal enable/disable toggles over globally configured providers, the right to add and edit shared inference accounts (§5), and an optional daily spend cap.

Passwords are stored solely as salted `PBKDF2-HMAC-SHA256` (`210,000` iterations, 16-byte CSPRNG salt, constant-time verification). Sessions use HMAC-SHA256 signed `orb-jwt-v2` tokens:

```text
orb-jwt-v2:<userId>:<role>:<sessionEpoch>:<expEpochSec>.<hmacSha256Hex>
```

Incrementing `session_epoch` (on password change/reset, role change, Linux username change, or account disable) or setting `disabled = 1` immediately invalidates all previously issued tokens (`StickyFence`: `session_epoch_sticky_fence` in `lean/Orb/Spec.lean`).

## 2. Formal Kernel Gates (`lean/Orb/Kernel.lean` & `lean/Orb/Spec.lean`)

Four total, pure, unboxed C-ABI exports decide every multi-user boundary across Core, `OrbNode`, `orb-privd`, and the Desktop/iOS/Android clients:

1. **`orb_multiuser_rbac_step`**:
   - Evaluates `(callerAuthed, callerDisabled, epochMatches, callerRole, opClass, isOwner, isSharedParticipant)`.
   - **Strict Owner Privacy (`admin_cannot_read_unowned_mission`)**: For `opClass ∈ {2 (missionReadOrParticipate), 3 (missionOwnerMutate), 4 (ownedResourceStrict)}`, when `isOwner == 0 && isSharedParticipant == 0`, the kernel returns **`admit = 0, httpStatus = 404`** *even when `callerRole == 1` (`admin`)*. Admins manage accounts and global infrastructure; they never see, list, search, stream, or mutate another user's missions, projects, workspaces, or managed VMs, and `/api/admin/users` returns zero mission or project counts/titles.
   - **Scoped Collaboration (`participant_cannot_destroy_or_share`)**: Shared participants (`isSharedParticipant == 1 && isOwner == 0`) are admitted (`200`) to `opClass = 2` (read transcript/events/files, send message, queue message, cancel turn, resume) and denied (`403`) on `opClass = 3` (archive, delete, move machine, fork, mutate mission settings, or mutate shares other than leaving).
2. **`orb_placement_role_admit`**:
   - Blocks `member` (`callerRole == 0`) from `core_local` (`0`), `core_colocated_node` (`1`), any node with `ORB_NODE_ADMIN_ONLY=1`, and any server-side node run without a validated `unix_username` (`member_blocked_from_core_and_admin_nodes`).
   - Permits `dedicated_fleet_node` (`2`) and `managed_vm` (`3`) when `nodeAdminOnly == 0 && hasValidUnixUser == 1`, plus `client_local` (`4`, `orb-locald` on the user's own computer).
3. **`orb_user_spend_cap_step`**:
   - Saturation-safe dual ledger gate enforcing both the server-wide daily cap (`globalCapCents`) and the user's personal daily cap (`userCapCents`) across inference (`Proxy.lean`) and managed VMs (`Managed.lean`) (`user_spend_cap_conserved`).
4. **`orb_privd_user_exec_step`**:
   - Enforces `SO_PEERCRED` (`sandboxed-node` UID), signed lease verification, `ORB_NODE_ADMIN_ONLY` exclusion, `validUnixUsername` grammar confinement (`^[a-z_][a-z0-9_-]{0,30}$` minus reserved system names; `unix_username_confinement`), unprivileged UID/GID range `2000..65533` disjoint from privileged groups, symlink-free `/home/<unix_username>`, and root-owned `/opt/orb/elan`.

## 3. Dedicated Per-User Linux Confinement (`OrbNode` + `orb-privd`)

On worker nodes and ephemeral VMs, `orb-node.service` runs as unprivileged `sandboxed-node` with `NoNewPrivileges=true` and has **no** write or read access to `/home/<unix_username>`. Privileged user provisioning and job launch are brokered exclusively by `orb-privd` over `/run/orb-privd.sock`:

- **`ensure_mission_user`**: Allocates or verifies a dedicated Linux user & primary group (`UID/GID ∈ 2000..60000`, zero supplementary groups), verifies `/home` and `/home/<u_name>` via `lstat` (no symlinks), enforces `chmod 0700 /home/<u_name>`, links `/opt/orb/elan` toolchains into `/home/<u_name>/.elan` as the dropped UID, and creates `/home/<u_name>/.orb-missions/<mission_id>` (`0700`).
- **`spawn_user_job`**: Scrubs unsafe environment keys, opens `/var/lib/sandboxed-node/logs/<job_id>.log` (`0640 root:sandboxed-node`, `O_NOFOLLOW`) for SSE/log streaming without granting `sandboxed-node` access to `/home/<u_name>`, and launches:
  ```text
  systemd-run --system --unit=orb-job-<job_id> --uid=<uid> --gid=<gid>
    --working-directory=/home/<u_name>/.orb-missions/<mission_id>
    --property=Slice=missions.slice
    --property=NoNewPrivileges=yes
    --property=SupplementaryGroups=
    --property=PrivateTmp=yes
    --property=ProtectSystem=strict
    --property=ReadWritePaths=/home/<u_name>
  ```
- **`user_fs_op`**: File-browser, upload, and workspace-transfer operations for dedicated-user jobs fork a short-lived worker that drops `setresgid(gid)` + `setresuid(uid)` *before* resolving paths with `O_NOFOLLOW`, defeating symlink TOCTOU escapes via kernel DAC.

## 4. Credential Non-Leakage (`mission_proxy_token`)

When executing a `member` job (`unixUsername.isSome`), `OrbNode/Runner.lean` never copies host/admin OAuth files (`.claude/.credentials.json`, `~/.codex/auth.json`, Antigravity login, or fleet SSH keys) into `/home/<unix_username>`. Instead, Core mints a short-lived `mission_proxy_token` (`orb-mpt-v1_<random>`, stored as SHA-256 in `mission_proxy_tokens` bound to `(mission_id, owner_user_id)`) and points harnesses at `<core_url>/v1`. `OrbCore/Proxy.lean` resolves `owner_user_id` from the proxy token, filters candidate providers by `user_provider_prefs`, checks and meters `user_daily_spend` via `orb_user_spend_cap_step`, and attaches upstream credentials solely inside Core. Across `/api/ai/providers*`, a `member` sees only each active provider's `id`, type, indexed type display name (e.g. `Anthropic` or `Anthropic 1`), credential/OAuth flags, personal preference toggle, connection status without account identity, custom models, and anonymous quota windows—never the owner's stored provider name, account email, organization, base URL, Google project ID, or rate limits.

## 5. Shared Inference Providers (owner decision 2026-11-14)

Members contribute accounts to the shared inference pool. A member-added account is shared:
it serves every user's missions through routing exactly like the operator's accounts.

| Action | Admin | Member |
| --- | --- | --- |
| Add an API-key account (`POST /api/ai/providers`) | yes | yes; Core picks the id (a client `id` is ignored, so an existing account is never overwritten) |
| Start / poll / complete / cancel a subscription login (`/api/ai/providers/cli-proxy-login*`) | yes | yes; a login session is visible only to the user who started it (`404` otherwise); re-login with `provider_id` only for accounts they added (`403 not_account_owner`) |
| Edit name, models, limits, global `enabled` (`PUT /api/ai/providers/:id`) | any account | any account |
| Replace the API key | any account | only accounts they added (`403 not_account_owner`) |
| Set `base_url` | any account | only on `custom` accounts they added, public `https://` hosts only (no loopback, private, link-local, `.local`, `.internal`; `403 base_url_not_allowed`) |
| Reorder (`POST /api/ai/providers/reorder`) | yes | yes |
| Delete (`DELETE /api/ai/providers/:id`) | any account | only accounts they added (`403 not_account_owner`) |
| Read an API key, OAuth access or refresh token | never | never (write-only for everyone) |
| Default provider, usage reset, Antigravity recheck, health clear, chain tests, routing chains, `/api/settings` | yes | no (`403 admin_required`) |
| Read the audit log (`GET /api/ai/providers/audit`) | yes | no |

Rules:

- `ai_providers.created_by_user_id` records who added an account (set on insert, never
  changed by edits; empty for operator and legacy rows). Admins see `created_by_user_id` and
  `created_by_username` ("added by …") on every account.
- A member sees the full credential-free view (`added_by_me: true`, stored name, email,
  limits, usage) of accounts they added, even when disabled or not yet connected, and the
  reduced view (§4) of everyone else's. Editing someone else's account returns the reduced view.
- A member-added account never inherits the operator's credentials: no instance env-key
  fallback (`ANTHROPIC_API_KEY`, …) and no CLIProxy login joined by provider type or email,
  only a login file whose prefix is the account's own id.
- `provider_audit_log` records every add, edit, delete, reorder, login start and login
  completion: user, role, action, account id, the *names* of changed fields, and time. Values
  (keys, names, URLs) are never recorded.

Tests: `memberSharedProviderRules` in `lean/OrbCore/OrbCore/TenantIsolationTests.lean`
(check labels are the rule names, e.g. `member_cannot_delete_owner_account`).
