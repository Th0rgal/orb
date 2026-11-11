# Multi-User Architecture & Security Model

Orb supports first-class multi-user operation on a single Core + fleet deployment with strict owner privacy, non-admin Core exclusion, dedicated Linux user isolation on worker nodes, credential non-leakage, and dual global + per-user spend caps.

## 1. Principal Roles & Session Tokens (`orb-jwt-v2`)

Every account in `users` (`missions.db`) has one of two roles:

- **`admin`**: Manages user accounts (`/api/admin/users/*`), global inference providers and API keys, global cloud-compute provider keys and fleet routing, node administration, backups, and deploys. May launch missions on any target (`core`, colocated nodes, dedicated fleet nodes, managed VMs, or local desktop).
- **`member`**: Launches and collaborates on missions using dedicated fleet nodes, ephemeral managed VMs (`boat.dev`, Hetzner, `lean.ci`, Vast.ai, Scaleway, Colab), or their own desktop (`orb-locald`), with personal enable/disable toggles over globally configured providers and an optional daily spend cap.

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

When executing a `member` job (`unixUsername.isSome`), `OrbNode/Runner.lean` never copies host/admin OAuth files (`.claude/.credentials.json`, `~/.codex/auth.json`, Antigravity login, or fleet SSH keys) into `/home/<unix_username>`. Instead, Core mints a short-lived `mission_proxy_token` (`orb-mpt-v1_<random>`, stored as SHA-256 in `mission_proxy_tokens` bound to `(mission_id, owner_user_id)`) and points harnesses at `<core_url>/v1`. `OrbCore/Proxy.lean` resolves `owner_user_id` from the proxy token, filters candidate providers by `user_provider_prefs`, checks and meters `user_daily_spend` via `orb_user_spend_cap_step`, and attaches upstream credentials solely inside Core.
