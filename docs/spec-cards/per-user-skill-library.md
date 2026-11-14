# Per-user Library scope

Repository: `Th0rgal/orb`; sync commit: `24d06a9f2` (master).
Contract: `docs/specs/per-user-skill-library.md` at `d9233feb`.
Covered files: `lean/OrbCore/OrbCore/Spec.lean`,
`lean/OrbCore/OrbCore/{Skills,ResourcesAndSystem,Control,RemoteDispatch,TenantIsolationTests}.lean`.

The Library catalog and REST checkout belong to the requester. Turn delivery
belongs to the stored mission owner, including a coordinator's follow-up.
Only the bootstrap owner (and the legacy empty owner) uses host path resolution
and global Library settings. All other users have private checkouts/settings.

`OrbCore.Spec.orbLibraryScopeGate` consumes two extracted flags: same owner and
an independently verified explicit admin grant. Only the value `1` grants
access. Core's owner resolver supplies the actual ID comparison and no grant;
REST routes have no parameter for selecting another user's Library.

* Proved: `libraryScopeMetaGate` has soundness, completeness, an accepting
  witness `(1,0)`, and a rejecting witness `(0,0)`.
  `library_scope_ordinary` relates the extracted ID equality to String equality;
  `library_scope_no_owner_substitution` rejects distinct member/owner IDs without
  an explicit grant. `library_scope_stable` proves rechecking the result does
  not change admission. `library_scope_explicit` models explicit authorization.
* Executable obligations: the eight numbered Library regressions in
  `TenantIsolationTests.run`, plus actual installer execution, project-context
  isolation, member CRUD, revision settings, and desktop account-cache reset.
* Trusted boundary: authenticated principal extraction, stored mission owner,
  bootstrap identity, filesystem/Git behavior and the ID-comparison input.
  The proofs do not establish OS filesystem isolation or HTTP correctness.
* Outside the model: sharing, organization defaults, migration of previously
  exposed skills, live dev deployment and the authenticated `ben` rollout probe.

Reachable positive trace: member `member` creates a skill in its own checkout,
connects a fixture repository with `PUT /api/settings/library-remote`, syncs,
and sees only its own Library and tenant-scoped project context. A shared-mission
coordinator selects that member's skill and receives the identical member install
prelude. Substituting the coordinator's owner-only skill is rejected.
