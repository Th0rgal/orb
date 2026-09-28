# Verity /btw replacement repair — 2026-09-28

Parent: `ebb2f1fe-8d03-4cc0-b966-68b3cb86077f`.
Incorrect replacement: `a66f9ad6-1756-4093-a772-dca8bae83a63`.
Failed remote job: `283bf384-0e15-4ed1-9d30-548aa07f04d3`.

## Cause and changes

The generic remote follow-up fallback handled OpenCode's explicit 409
`REMOTE_RESUME_REQUIRES_REPLACEMENT` by creating an ordinary mission. It lost
the side-agent parent tags and embedded the entire conversation in the command.
The resulting 248,886-byte command exceeded Linux's per-argument limit before
execution (`E2BIG`). The deployed backend also lacked incremental side-context
handling and reinserted parent history into otherwise compact requests.

Orb now leaves this explicit refusal to the side-agent controller, which creates
a replacement through the dedicated `/btw/agent` endpoint, renews its archive
and cursor, and saves the replacement identity. Uncertain transport failures do
not trigger replacement. The server honors incremental context and follows the
parent's transferred working directory. The erroneous session was tagged as a
side conversation without deleting its history or failure evidence.

## Validation

- Frontend regression coverage: refused side reuse must not create an ordinary
  mission; replacement retains parent binding and refreshes archived context.
- TypeScript compilation and the focused btw-agent/btw-context/connection tests.
- Backend incremental-context regression with 200 KB parent history.
- Opt-in live test against production and old-agent passed in 266 seconds,
  including uploading the large history archive. Follow-up prompt: 5,799 bytes;
  replacement prompt: 5,857 bytes. Side context: 5,078 bytes.
- Child `a1772328-9ad4-4136-9bba-0baabbc6a636`, remote job
  `0e243a00-97b6-421a-bc1d-8c9099e40437`, completed successfully with exit 0,
  both parent tags, and a roadmap answer based on local evidence.

The live test exercises Orb's frontend functions against production, not the
user's native panel storage. No claim is made that its answer was inserted into
the user's existing panel. Its historical health summary is not authoritative;
the live mission API must be used to establish current execution state.

## Deployment incident and recovery

The first guarded deployment exposed an additional startup defect: graceful
shutdown preserved external remote jobs, but actor startup only recognized
accepted RemoteBuild ledger handles, not Mission handles. Startup marked two
missions interrupted and their remote observers cancelled their jobs.

Startup now also recognizes accepted Mission handles. Two startup tests pass,
including exclusion of tentative/unaccepted handles and explicitly interrupted
missions. The corrected debug binary was built on Core and deployed through the
guarded endpoint; Hermes was restarted afterward.

Verity was recovered on its existing native thread
`01a0de07-cadd-7a61-b0c5-6aa62dfae607`, without resetting its goal. Remote job
`1e066c78-1d00-4b82-a349-b8c0d1b8a297` remained running across the second
deployment, verified from fresh node observations at 06:48 UTC.

The other affected mission, Vanity adresses
`ccc73aa1-b9d8-4025-bdbf-ddac24095701`, had been waiting for a Spark slot.
Plain resume was explicitly refused by admission; its uncertain action was
reconciled as rejected. Admitted replacement
`8426890f-ea9b-4cae-aa7a-43ac2101317e` preserves its request, backend/model,
project/track and node, and supersedes the interrupted attempt. Its remote job
`2e890601-dbe6-4790-9b48-3e8c611c9b9f` was observed running on dgx-spark.
