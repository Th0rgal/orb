# Project skill validation

Validation ran on **old-agent, Linux**, against the working tree based on
`00041f64`. This is not macOS Orb desktop validation. No production backend,
node service, unrelated project, or unrelated mission was restarted or deployed.

## Real Orb mission coverage

No real Orb test project or mission was created in this environment. Project
IDs and mission IDs are **none**. `orb-project-skills-test` is the requested
remaining disposable Orb project name, not a claimed existing project.

| Harness | Orb local, default cwd | Orb local, custom cwd | Orb remote machine | Orb Core | Native scanner on old-agent |
| --- | --- | --- | --- | --- | --- |
| Codex 0.159.3 | Not run: no desktop session | Same | Not run: no isolated test deployment access | Same | Symlink discovered by `skills/list` |
| Claude Code 2.1.286 | Not run: no desktop session | Same | Not run: no isolated test deployment access | Same | Symlink listed in native startup `skills` metadata |
| OpenCode 1.18.34 | Not run: no desktop session | Same | Not run: no isolated test deployment access | Same | Symlink discovered by `debug skill` |
| Grok 1.0.44 | Not run: no desktop session | Same | Not run: no isolated test deployment access | Same | Symlink discovered by `inspect --json` in a trusted disposable directory |
| Gemini 0.62.0 | Not run: no desktop session | Same | Not run: test deployment unavailable | Same | Symlink discovered by `skills list --all`; CLI installed only in a disposable prefix, with private fixture trust settings |
| ChatGPT UI / hosted agents | Unsupported filesystem integration | Unsupported | Unsupported filesystem integration | Unsupported filesystem integration | Not applicable |

Native scanner fixtures were under `/tmp/orb-project-skills-native-kikegci8`.
The skill `orb-marker` described the **turquoise lantern check**, with supporting
file `references/marker.md` containing **ORB-PROJECT-SKILLS-7E981**. Scanner
results proved that Codex, OpenCode, trusted Gemini and trusted Grok discovered
the skill's name, description, and native location. Claude listed the skill
in native startup metadata. No model task was sent by those probes. They do **not** prove reference reads or instruction following.

Grok and Gemini omitted workspace skills in untrusted directories, even when a
native copy replaced the link. Trust was exercised only for disposable fixtures
using private test settings; application preparation does not modify trust settings.

A second reproducible native probe, `scripts/project_skills_discovery_probe.py`,
ran under `/tmp/orb-project-skills-discovery-xf0z7_gc`. Each of the five real native
scanners detected initial symlink discovery, an added adapted plain Markdown
skill, rename cleanup, deletion, and cleanup after deleting the final original.
All 25 stage checks passed. Raw filtered discovery names, expected names and
fixture identity are recorded in
[`evidence/project-skills-native-discovery.json`](evidence/project-skills-native-discovery.json).
This proves native metadata discovery and cleanup on new processes, not agent
reference reads, instruction following, or mission resumes.

## Automated checks

- Python ownership/preparation tests cover native links and supporting files,
  original edits through links, add/rename/delete cleanup across harnesses,
  configuration/user-skill preservation, native alias collisions, replaced
  managed entries, separate/shared/nested project directories, generated-copy
  source notices and refresh, unsupported links, unsupported harnesses, Grok/Gemini
  discovery refusal, skill-free launches without Python, and concurrent preparation.
- Rust checks cover Library preservation, cleanup, collision refusal and refusal
  to follow project links. Context tests cover original `@context/skills` and
  `@context/Context` resolution. A replica test edits originals and verifies the
  existing sync protocol carries skill, reference, and Context edits to Core
  and a second replica. These are local automated protocol tests, not physical
  machine or Orb UI synchronization evidence.
- Frontend checks cover preparation without mentions, actionable preflight
  failures, and typed context namespace references resolving to originals
  without attachment chips.

Final command results:

| Check | Result |
| --- | --- |
| Python project skill preparation | 19 passed, including review regressions |
| Rust workspace tests | 2,907 passed, 8 ignored, no failures |
| Harness contract script | Passed, including 81 Python driver tests |
| Capability matrix | Passed |
| Frontend build and unit tests | Build passed; 767 passed, 3 skipped |
| Linux Tauri compile | Passed; six existing warnings |
| Native discovery lifecycle probe | 25 checks passed across five harnesses |
| Browser fixtures | 169 passed; seven failures reproduced on unchanged base `00041f64` |
| Strict backend Clippy | Blocked by four existing errors in `monitoring.rs`, `runners/errors.rs`, and `library/mod.rs` |
| Formatting / diff whitespace | Passed |

The seven baseline browser failures concern composer scrolling, Cursor-style
file references, the machine-transfer footer, three Markdown-editor cases, and
created Markdown/Cmd+/ behavior. Browser fixtures do not establish desktop Orb
mission validation. Clippy reported unnecessary casts at `monitoring.rs:208–209`,
manual-find at `runners/errors.rs:40`, and recursion-only `self` at
`library/mod.rs:403`.

Targeted Linux Tauri lock tests: two passed. The recovery protocol run had
three passing cases, two failures, and one case left waiting for a mock request;
it was interrupted. Individual reruns confirmed that the two failures occur
before skill preparation: the existing `workspace_quiet` guard refuses recovery
because old-agent has an `opencode` process (PID 1009) with an unreadable cwd.
That guard is unchanged from base and deliberately treats unknown harness cwd
as busy. The unrelated process was left untouched. Protocol launch/resume
coverage therefore remains incomplete on this machine.

## Remaining acceptance work

With the test backend/node build installed through the repository's dev
procedure and an authenticated Orb desktop available:

1. Create `orb-project-skills-test` and a second disposable project in Orb.
2. Add the marker skill/reference and `Context/architecture.md` through project
   files. Run matching tasks without naming native discovery paths.
3. Collect mission IDs and tool events proving native skill discovery, reference
   reads and instruction following for every available matrix combination.
4. Edit the original via `@context/skills`, confirm the edit in Orb, wait for
   synchronization to a second machine, and verify a subsequent mission there
   follows the new instructions.
5. Exercise additions, renames, final deletion and cleanup on launch/resume;
   test `@context/Context` reading/editing, project isolation, user configuration
   preservation and concurrent launches.

## GitHub delivery

After the development identity rollout, GitHub authentication succeeded as
`Th0rgal`. The branch was rebased without conflicts onto `master` at `d5fa2c58`.
The implementation is tracked in [PR #998](https://github.com/Th0rgal/sandboxed.sh/pull/998).
Commits use `Thomas Marchand (agent) <agent@thomas.md>` and OpenPGP fingerprint
`30EAE29B6766A7A70A4DEB4BF480B9A3F84BE648`; GitHub verified the implementation
commit's signature as valid.

The initial signed head passed GitHub Format, Clippy, Test, Harness Contract,
Orb, Policy Lint, Capability Matrix, and Dashboard checks. Local Rust tests after
rebasing passed 2,907 tests with eight ignored. The automatic review identified
three lifecycle issues; fixes add early stale cleanup, per-mission discovery
root checks, and staged/journaled Library updates with interruption recovery.
All six Rust ownership/recovery regression tests passed; all 19 Python tests
and all 25 native discovery lifecycle checks passed on the reviewed code.

Post-rebase frontend build passed; unit tests passed 788 tests with three
skipped. This authentication rollout does not supply macOS Orb desktop or
isolated test-deployment access, so the real mission coverage above remains
outstanding.
