# Per-user skill libraries

Status: decided by Thomas 2026-11-14. Replaces the open policy question in
`docs/plans/orb-consolidation-2026-11.md` ("members' missions still receive
Library skill bodies"). Implementation is tracked on the multi-user track.

## Decision

Every user owns a private skill library. A user, member or admin, only ever
sees, receives or syncs their own library:

- no bodies of another user's skills,
- no names or descriptions of another user's skills,
- nothing from another user's library is installed into a mission workspace,
- `/api/library/skill-delivery` lists only the caller's own skills,
- the Library REST surface operates on the caller's own checkout,
- a mission syncs the library of the mission owner, whoever launches the turn.

The owner (bootstrap admin) keeps today's checkout path, so existing installs
keep their library. Each member gets a separate checkout and settings.

## Problem

Today the library is a single host-wide checkout:

- `OrbCore.Skills.resolveLibraryRoot` reads `LIBRARY_PATH`, then
  `{workingDir}/.sandboxed-sh/library`, then `{storeRoot}/library`, then
  `{workingDir}/library`, with no user dimension (`Skills.lean:313`).
- `library_remote` and `library_revision` live in the single global settings
  document (`SettingsDocument.lean:72`), so a member cannot point their library
  at their own remote and a member write would change the owner's remote.
- `handleLibraryRoute` refuses every mutating call to non-admins
  (`ResourcesAndSystem.lean:1454, 1509`), so a member cannot create or edit
  their own skills, while `GET /api/library/status` already hides the path and
  remote from members.
- `buildDeliveryPlan` and `remoteInstallPrelude` read that single checkout
  (`Skills.lean:326, 370`), so every mission on the instance receives the
  owner's skills regardless of who owns the mission.
- `GET /api/library/skill-delivery` calls `buildDeliveryPlan` with no caller
  scope (`Control.lean:5803`), so a member sees the owner's skill names and
  descriptions today. The operator probe on `c77d4e162` confirmed the leak.
- `RemoteDispatch.lean:540` builds the install prelude from `coreWorkDir` with
  no owner, so a member's remote turn gets the owner's skills in its workspace.

## Model

### Storage

- Owner (the bootstrap admin) keeps `resolveLibraryRoot` exactly as it is today;
  `LIBRARY_PATH` still wins for the owner, preserving current deployments.
- A member's checkout is `{storeRoot}/library/users/<userId>` (created on first
  sync). `{workingDir}/.sandboxed-sh/library` stays owner-only: it is the
  legacy default and must not be shared.
- Per-user library settings live in `{storeRoot}/library/users/<userId>/library.json`:
  `{ "remote": <string|null>, "revision": <string|null> }`. The owner keeps
  using the global settings document for `library_remote`/`library_revision`
  so environment transfers and existing tooling are unchanged.
- `LIBRARY_PATH` is never applied to a member: it is an owner/host override.

### Resolution API

```
OrbCore.Skills.resolveLibraryRootFor (ownerUserId : String) (workingDir storeRoot bootstrapAdminId : String) : IO String
```

Pure helper in `OrbCore.Skills`:

```
OrbCore.Skills.libraryRootCandidate (ownerUserId bootstrapAdminId workingDir storeRoot : String) : String
```

Rules, in order:

1. `ownerUserId` empty or equal to `bootstrapAdminId` -> owner resolution as today.
2. otherwise `{storeRoot}/library/users/<safe userId>`.
3. `safe userId` must match `[A-Za-z0-9._-]{1,64}` without `..`; an invalid id is
   rejected by the caller, never silently collapsed to the owner.

Every existing call site that builds a plan, installs skills or serves a
Library route must pass the owner id. Call sites that cannot know it (health,
static status) keep the owner path and are documented as owner-only.

### Settings

- `GET /api/library/status` returns `remote` and `revision` for the caller's
  own library; `path` stays empty for members.
- `PUT /api/settings/library-remote` becomes: owner -> global settings
  (unchanged); member -> the member's `library.json`, with the same
  `isValidGitRemote` validation and the same `settings_library_remote_contains_credentials`
  rejection. No member can read or change the owner's remote.
- Owners may still set a shared default remote in global settings; it is not
  inherited by members.

### Routes

`/api/library/*` operates on `resolveLibraryRootFor caller.userId`:

| Route | Owner | Member |
| --- | --- | --- |
| `GET /api/library/status` | own | own, `path` empty |
| `GET /api/library/skills` (list) | own | own |
| `POST /api/library/sync` | own | own (no longer `admin_required`) |
| `POST /api/library/force-sync` | own | own |
| `PUT/POST /api/library/skills/:name` (create/edit) | own | own |
| `DELETE /api/library/skills/:name` | own | own |
| revision pin (`library_revision`) | global settings | per-user `library.json` |

A member route never reads another user's checkout; the only 403 left is a
caller with no valid principal.

### Mission delivery

- `selectDelivered`, `buildDeliveryPlan`, `remoteInstallPrelude` take
  `ownerUserId` and resolve that user's checkout.
- `POST /api/control/missions`, `POST /api/control/message`, `POST .../resume`
  and the steer path pass the mission's `ownerUserId`, not the caller's, so a
  coordinator steering a member mission still installs the member's skills.
- `RemoteDispatch` passes `spec.ownerUserId` into the install prelude.
- `GET /api/library/skill-delivery` calls `buildDeliveryPlan` with
  `caller.userId` (admin and member alike); project context stays scoped to the
  caller's own project slugs, as project scoping already does.
- Skill selection and `/skill:` validation use the same owner-scoped plan, so a
  prompt naming another user's skill either fails as unavailable or, for
  `remoteInstallable` names, is simply absent.

### Clients

Desktop, iOS and Android show the signed-in user's own library and allow
create, edit and delete there. A member never sees the owner's skills. The
desktop Settings page hides "Library remote" from members or shows it scoped to
their own library; an admin still sees the global setting.

## Invariants

1. No response or workspace of user A contains a name, body or description of a
   skill that exists only in user B's library.
2. `/api/library/skill-delivery` for a member equals that member's own plan,
   byte for byte, regardless of the owner's library.
3. A mission's installed skills are those of the mission owner at turn start.
4. The owner's checkout path and `LIBRARY_PATH` behaviour are unchanged.
5. A member can create, edit and sync in their own library without any admin
   grant, and cannot affect another user's checkout.

## Tests (tests first)

Core, in `lean/OrbCore/OrbCore/TenantIsolationTests.lean` (or a new
`LibraryIsolationTests.lean` wired into `orb-core-test`):

1. Two users, disjoint libraries. `GET /api/library/skill-delivery` as each
   returns only their own skills; assert the other's name is absent.
2. `GET /api/library/status` as a member has an empty `path` and the member's
   remote, not the owner's.
3. A member `POST /api/library/sync` succeeds against a fixture git remote and
   creates `{storeRoot}/library/users/<member>`; the owner checkout is untouched.
4. A member `PUT /api/settings/library-remote` writes only the member's
   `library.json`; the global settings file is byte-identical before and after.
5. `remoteInstallPrelude` for a member mission contains only that member's
   skills; the owner's skill name is absent from the command string.
6. A coordinator (admin) steering a member mission installs the member's
   skills, not the admin's.
7. Owner resolution is unchanged: `LIBRARY_PATH` still wins and the global
   settings remote still applies.
8. An invalid user id is rejected (`library_invalid_user_scope`) rather than
   falling back to the owner checkout.

Specs (`lean/Orb/Spec.lean` if a kernel gate is introduced):
- `orbLibraryScopeGate`: `(requesterUserId == ownerUserId || isAdminWithExplicitAccess)`
  only for admin reads of their own library; otherwise the plan is the
  requester's own. Prove the scope is stable and that the owner id is never
  substituted for a member id.

## Rollout

1. Ship the resolution helper and per-user settings with the owner path
   unchanged, plus the tests.
2. Switch `handleLibraryRoute`, `/api/library/skill-delivery` and the mission
   install path to the owner-scoped resolution.
3. Update the clients' library screens.
4. Verify on dev as `ben`: only `ben`'s library is listed and delivered, and a
   `ben` mission workspace contains no owner skill.

## Out of scope

- Sharing a skill between users, or an organisation-wide library. Not decided.
- Migrating an existing member who had been reading the owner's library: none
  could legitimately create one, and reading it was the defect.
