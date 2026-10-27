# Harness transfer

The agent selector on desktop, iOS and Android offers transfer of an existing
native conversation. Explicit Fork remains independent where offered. A transfer
uses Core's conversation-fork API with the same workspace and portable history.

1. Fetch the source. If its status, client execution or remote job is live, cancel
   it and wait for a confirmed stop. Unknown state, network failure and timeout
   stop the operation; they must never be treated as successful cancellation.
2. Submit the fork with a stable idempotency key and unchanged payload on retry.
   Do not start a successor before the source stops.
3. Retain the creation receipt, then archive the source. An archive failure stays
   visible, and retry only archives; it must not create another successor.
4. Navigate to the successor after success. The workspace and conversation
   history remain available. The old conversation is retained in the archive.

A failed fork leaves the source stopped and available for retry. Selecting a
new target is allowed before submission; after submission retry uses the exact
original payload because a lost response does not prove launch failure.

Structured fork, edited-message and native-recovery envelopes are historical
context. Desktop collapses them; mobile expands their messages instead of showing
raw JSON. Only a complete envelope with valid message roles and string contents
is decoded; malformed user text stays visible. Event-first and history-first
arrival must retain the carried conversation without duplicating the envelope.

Regression coverage includes stop-before-launch ordering, remote jobs still live
under a failed mission, stop timeout, launch-response loss, archive failure, and
literal delimiters or malformed data inside carried history.
