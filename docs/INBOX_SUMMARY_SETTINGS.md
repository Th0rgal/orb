# Inbox & AI summary settings

Desktop, iOS and Android expose **Inbox & summaries** under **Settings → Agents**
(`inbox-summaries`), alongside `Skills`, `Assistant` and `Quick questions (/btw)`.
**Settings → Notifications** (`inbox-settings`) retains alert delivery settings
and links to **Inbox & summaries**.

Controls in **Inbox & summaries**:
- **Enable Inbox** (`inboxEnabled`, default `true`): hides Inbox navigation,
  shortcuts and background unread work when off, without erasing saved summary
  preferences.
- **Include autonomous agents** (`includeAutonomous`, default `false`): includes
  sub-agents and Hermes-launched missions in Inbox and unread counts.
- **AI summaries** (`aiSummary` + `model`): Off, built-in routing chains, server
  routing chains, provider-qualified models, the remembered model (even when
  absent from the catalog), and a custom ID dialog. Off writes `aiSummary=false`
  and preserves `model` and `summaryMode`.
- **Summary mode** (`summaryMode`, default `"standard"`): `"standard"` (background
  pre-warm + chat recaps), `"on_open"` (only while Inbox is open for settled
  runs), or `"eco"` (only while Inbox is open for settled runs after 1 hour with
  no messages).

`shared/orb-spec/fixtures/inbox-summary-choice.json` and
`shared/orb-spec/fixtures/inbox-summary-policy.json` replay selection,
preference normalization and summary request gating across Desktop, iOS, Android
and Core. See `docs/specs/inbox-and-summaries.md` for the full specification.
