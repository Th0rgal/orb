# Orb consolidation roadmap (2026-11-13)

Status: approved by Thomas on 2026-11-13 ("full autonomy, approved to deploy and
test in production, prioritise speed, do not wait for CI initially, fix any new
bug you find"). Owner: the single mission **"Orb: consolidation"** (project
`refining-loops`). It replaces the four earlier Orb missions (`68e2a387` parity,
`44e3fec6` Boat recovery, `2bf5e847` lean.ci/Colab providers, `9382ef4d`
dev/prod), whose handoffs are at the top of their plan documents in this folder.

## How the work is run

- One orchestrator (Claude Code, Fable 5.2). It keeps the task board, reviews
  and merges; it does not write feature code itself.
- Workers are child missions (`builtin/smart` on opencode by default), each on
  **its own managed VM** (`auto-managed:<provider>:<size>`, Boat or lean.ci) so
  Lean builds never share a build slot. At most 5 writers at once, one per
  track, one branch per bounded change. Destroy VMs when a worker ends.
- Merge policy today: a worker merges its own PR once its local CI-parity build
  and self-test pass; GitHub CI is checked afterwards and any red master is the
  first thing fixed. Once track B makes CI fast (< 10 min), return to
  green-before-merge (AGENTS.md).
- Deploys: `orb-deploy --detach <sha> --dev-only` first, verify on dev, then
  prod. Never a bare restart or binary copy. One deploy at a time.
- Every decision that Thomas would otherwise have been asked about goes into
  the decision log below, with the reason.

## Tracks

### A. turbo-lean builds all of Orb (blocks B)
`turbo-lean` rejects `OrbBin.PosixExt` and `OrbCore.Store` in its in-kernel
`.olean` soundness audit (PR #1708 CI), and missions report a "known
OrbCore.Spec materialization gate", so everyone falls back to raw
`SANDBOXED_ALLOW_RAW_LAKE=1 lake build`. Reproduce, find the cause (Orb source
or `Th0rgal/turbo-lean`), fix it at the cause, bump `lean/turbo-lean-revision`.
Done when `scripts/build_orb_bins.sh` builds every binary through turbo-lean
with no raw-Lake fallback, locally and in CI.

### B. CI: fast, cached, on lean.ci
1. Land #1708 (cached pinned turbo-lean binary, batched audit-spec, no raw Lake).
2. Move Linux jobs to lean.ci runners (GitHub App `lean-ci`; labels validated on
   2026-11-11: `lean-16vcpu-ubuntu-2604`, `lean-32vcpu-ubuntu-2604`). macOS/iOS
   jobs stay on GitHub `macos-26`. Keep a `workflow_dispatch` input / repo
   variable to fall back to `ubuntu-latest` when lean.ci is at capacity.
   Known lean.ci gaps to fix or work around (lean.ci is ours: fix upstream in
   `lfglabs-dev/lean.ci`, keeping it generic, no Orb-specific coupling): the
   Actions cache is not wired inside microVMs; warm-base pinning across engines
   was broken for Actions jobs on 6 Nov; `Th0rgal/orb` is a user repo, while
   the App syncs an org runner group, so repo-level JIT runners may be needed.
3. Finish the planner in `docs/ci/refactor-proposal.md`: path-gated jobs
   (docs-only and `orb/`-only PRs skip Lean; kernel-abi merged into `ci.yml`),
   master pushes seed the warm base / turbo-lean CAS, no test reruns when
   inputs are unchanged.
Targets, measured and written here: web-only PR < 5 min, warm Lean PR < 10 min,
cold full run < 20 min.

### C. lean.ci and Colab at Boat parity in the product
After #1720: on desktop, iOS and Android a user can see active VMs per
provider, start one from the UI (size, TTL), stop/extend/destroy it, and see
cost, for `boat`, `leanci` and `colab` alike. Test with real rentals on dev,
then prod. iOS and Android ship together (version bump per AGENTS.md).

### D. Rust → Lean parity: implement, stop auditing
Work the ranked queue in `rust-lean-parity-audit.md` (handoff section), one
bounded branch per finding group, failing test first, verified on dev. Start
with RUN-07 (incremental proxy streaming + deadlines) and the "Not done" items
of the implementation ledger. No new audit documents.

### E. Dev/prod environments live
Apply items 1–6 of `dev-prod-environments.md` on agent-core (base + overlays,
settings round trip, sealing, `dev_operator` grant, auto-deploy timer, dev
spend cap), verify each, then run the multi-user isolation test on dev and fix
every leak with a test. Keep `docs/operations/*` exact.

### F. Hindsight
When a track closes, update the Hindsight pages (lean.ci page
`kp-7660c626095640c08f6742f9e60c2946`, the "Now" chapter, Orb pages) with the
outcome. Request memory-write access through the governed broker.

## Decision log

| When (UTC) | Decision | Why |
| --- | --- | --- |
| 13 Nov 11:44 | Merged #1721 (web search dialog in native chrome) without waiting for CI | Thomas's explicit instruction |
| 13 Nov 12:03–12:06 | Merged #1711, #1717, #1720 without waiting for remaining checks | "No need to wait for CI initially"; each had a passing local CI-parity build + self-test; #1711 was fully green |
| 13 Nov 12:07 | Asked the four old missions for a final handoff commit, then close them | One orchestrator instead of four missions sharing one build slot |
| 13 Nov | #1708 kept open, assigned to track A/B rather than closed | It is the base of the CI work; its failure is the turbo-lean audit rejection |
