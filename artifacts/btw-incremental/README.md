# Incremental /btw context — validated 2026-09-26

Implemented and deployed. Orb sends bounded initial context, then only public
main-agent events after the side session's last accepted cursor. It no longer
reinserts main or side history into every prompt. Core's incremental launch mode
also suppresses its former duplicate history injection.

Full available public messages and tool details are readable through
`.paloma/conversation/<snapshot-id>/conversation.json` inside the actual harness
workspace. Transferred parents use their destination workspace. Archives exclude
private thinking and queued drafts, preserve large Unicode data in bounded parts,
and are staged without changing harness permissions. Copying rejects traversal
and symlinks. Unchanged remote snapshots reuse upload receipts. Legacy side
sessions migrate to fresh sessions with saved side history available as a file.

Validation:
- 33 frontend tests and TypeScript pass.
- 430 Linux control-plane tests pass.
- 4 filesystem staging tests pass (including symlink/traversal rejection).
- Three real read-only /btw turns passed on Verity/old-agent, reusing one side
  session. Tools read the manifest and a 12,000-byte transcript tail rather than
  the approximately 3 MB archive, inspected validation services, and correctly
  recognized new events 389–395 after the main mission resumed.
- Prompt bytes: legacy 195,588; initial 6,210; unchanged follow-up 1,207; subsequent
  delta 3,778. The unchanged follow-up reported 1,043 uncached input tokens and
  15,616 cache-read tokens. These are measured per-turn usage, not a guarantee
  about arbitrary future tool reads or total retained harness context.
- The main mission resumed with its goal unchanged and was active/healthy on
  old-agent at final verification. Test-only side missions were archived.

`validation.json` records identities, replies, prompt sizes, provider-reported
usage and parent execution evidence. No credentials are included.

Production binary SHA-256:
`81b2a37e6aa1d5865d55153ae0514bcf7c1fe87169ee2f903b08a96f97f0e506`

Both guarded deployments waited for natural idle windows; no active harness was
interrupted or deployment forced. The final change also rejects generated
“finished without assistant text” notices as evidence of a real side-agent reply.

The live test is explicitly opt-in (`ORB_BTW_LIVE_CHECK=1`) and uses a protected
JSON connection file (`endpoint`, `token`) selected by `ORB_BTW_LIVE_CONNECTION`.
`ORB_BTW_LIVE_MISSION` selects the parent. `ORB_BTW_LIVE_FOLLOWUP=1` reuses the prior
test receipt to verify a subsequent non-empty delta. The temporary credential
file used for this validation was removed.
