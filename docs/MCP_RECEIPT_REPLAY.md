# Settled mission action replay

For keyed mission starts, consultations, resumes, adoption, messages, cancellation
and time wakeups, Core reserves one action row before effects. The unique
`(scope, retry_key)` winner executes; matching retries read the row, and different
arguments conflict. A successful settlement changes only an accepted row and
records the target mission together with its result. Terminal rows are immutable.

A first response, a settled retry and `get_action` must agree on action ID,
mission ID and outcome. Mission status belongs inside the result; a succeeded
action has outer status `completed` and accepted `yes` (normalization word
`65793`). A no-placement refusal retains `no_execution_placement`, accepted `no`,
and creates no ghost mission. An exception or unsuccessful settlement write is
uncertain and cannot authorize fresh-key repetition.

`TurnOutcomeTests` replays successful and refused starts, checks exact receipt
equality and one created mission, and retains the concurrent-message, failed
reservation, failed writes, failed remote cancellation and terminal-state guards.
Old result shapes still normalize without discarding their mission status. For
legacy succeeded rows whose fingerprint held the retry key, replay validates the
stored serialized arguments instead; a changed request still conflicts.
