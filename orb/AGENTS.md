# Orb frontend

Follow the repository's root instructions. Before adding or changing a modal,
menu, picker, preview, or other overlay, read [the overlay contract](../docs/ui/overlays.md).
Use the existing SolidJS primitives and tokens; do not add per-view positioning,
stacking, focus trapping, outside-click or Escape listeners.

The executable gallery is `tests/overlays.html`. Validate using `pnpm build`,
relevant `pnpm exec vitest run ...` tests and
`pnpm exec playwright test --config=playwright.overlays.config.ts`.
Preserve native form semantics, IME input, drafts, and single in-flight mutations.

For Inbox presentation changes, follow [the Inbox contract](../docs/ui/inbox.md)
and run its Chromium/WebKit references and triage checks.
