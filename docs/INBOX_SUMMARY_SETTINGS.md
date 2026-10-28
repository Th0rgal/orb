# Inbox AI summary selection

Desktop, iOS and Android expose one **AI summaries** picker. Its choices are
Off, built-in routing chains, server routing chains, provider-qualified models,
the remembered model (even when absent from the catalog), and a custom ID dialog.
Catalog failures never erase the remembered selection.

The existing synchronized preferences remain the source of truth: `aiSummary`
controls generation and `model` remembers the selected model/chain. Off writes
`aiSummary=false` and preserves `model`. Selecting a model writes that model and
`aiSummary=true`. No new preference or server migration is needed. Custom IDs
are trimmed and applied only on confirmation; Cancel and blank drafts do not
change preferences. Include-autonomous and notification preferences are unchanged.

`shared/orb-spec/fixtures/inbox-summary-choice.json` replays selection, Off,
repeated Off and re-enabling on all three platforms. Desktop also tests actual
settings persistence across unmount/remount and cancellation of custom edits.
