# Grok Bot compatibility evidence

Validated installed desktop 0.58.0 user-scoped Connect JSON protocol on 2026-09-26.
Origin: https://api2.cursor.sh/aiserver.v1.GrokBotService/. Authentication was
verified read-only before creating a dedicated test Bot. No administrator method
was called. A Keychain-decrypted access token is held in a protected Core file,
referenced by account ID; expiry surfaces as reconnect_required.

The adapter creates a UUID-pinned Bot per mission, persists its identity before
sending, uses stable message IDs, reconciles GetGrokBotSendStatus before retry,
and associates transcript responses by clientNonce + requestId. Base64 bodies
contain UTF-8 JSON; unknown response formats disable that mission's connector.
Repeated observations have durable event keys. Interruption remains pending
until a subsequent provider reply confirms no active run.

## Real Core tests

- 000a483f-7f00-418d-98e3-38c91a3af590: initial marker, two queued follow-ups,
  restart, confirmed interruption, continuation retaining the original marker.
- a08cf25a-596e-45e1-a665-a5d7a622e22e: initial marker, two queued follow-ups,
  injected expired credential, reconnect state, restored credential and one
  recovered response after proving the rejected submission was not accepted.
- 2b87fba5-c799-42d3-adab-69fcf322fbcc: independent Bot, exact creation/message
  replay, two follow-ups, same provider identity after Core restart.
- d60acbd1-fed5-44b8-9a88-c706de64cf43: creation, replay and observation through MCP.

The direct protocol canary also verified creation, response, follow-up Markdown
(table/TeX/code/link), authenticated history reconnection and interruption.

Remaining limits: no verified attachment or provider file transport, no model
selection, no automatic refresh-token exchange, and no claim of isolation.
Bot computers are shared within an account; Orb archival never deletes files.
