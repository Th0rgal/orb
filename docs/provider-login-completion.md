# Provider login completion contract

Core's ProviderRuntimeHub owns login sessions and usage cache publication. CLIProxyAPI owns credential persistence. A successful callback or sidecar status alone is not proof that a new credential is visible to Core.

A session remains `completing` until a non-disabled, matching-type auth file is newly present or changed relative to the session baseline. Within 60 seconds after sidecar success, Core must either observe that file or report `failed` with an auth-file visibility timeout. Failure must not clear earlier authentication evidence.

Once the new file is visible, completion removes the reconnected login's evidence (its `cliproxyapi:<provider_type>` row and the rows of its hydrated OAuth-only accounts), clears both legacy and tracker cooldowns for those keys, and re-probes usage for the affected accounts using newly hydrated credentials. Evidence of other provider types is kept. Older in-flight usage probes cannot overwrite the post-login generation. Session polling is idempotent after completion or failure.

Replay: seed a rejected usage payload (98%) for the reconnected account and one for an unrelated account, plus auth-unavailable evidence and cooldowns in both owners; stand up a mock sidecar that answers `ok` before the new auth file is on disk. Exercise both completion paths: the callback POST and the GET poll. After either path, list, detail and cached usage must report connected for the reconnected account without any proxied inference request, the unrelated account keeps its rejection, and only the reconnected login's evidence row is cleared. Missing, unchanged, disabled, and wrong-type files cannot complete login; after 60 seconds the session reports `failed` with a message. Callback acknowledgment alone is `completing`, never `completed`.

Client contract: existing `pending`, `completing`, `completed`, and `failed` states remain. `completed` now implies credential visibility and health reconciliation; timeout is `failed` with a message. No fields are renamed.
