# Keyboard shortcuts

Global section navigation and shell chords are registered in `src/keyboardShortcuts.ts`; both dispatch and labels read that registry. Use physical key codes so number shortcuts work on AZERTY too. Ctrl is accepted in place of Command outside macOS. Focused dialogs retain their keyboard scope.

| Shortcut | Action |
| --- | --- |
| ⌘1 / ⌘N | New agent |
| ⌘I | Inbox (local keys inside Inbox: ↑/↓ or J/K navigate, Enter open, R reply inline, E mark done, Z undo, 1/2/3 pick option) |
| ⌘2 | Cloud agent |
| ⌘3 | Machines |
| ⌘4 | Inference |
| ⌘5 | Focus projects; ↑/↓ navigate visible rows, Enter opens/toggles |
| ⌘B | Toggle left sidebar |
| ⌘J | Toggle Files panel |
| ⌘⇧B | Toggle file explorer tree (when Files panel is open) |
| ⌘P | Quick-open file in Files panel |
| ⌘K (or ⌘⇧J) | Open / focus `/btw` side question (press again while focused to close) |
| ⌘⇧F | Search all conversations and messages (also `⌘F` when left sidebar has focus) |
| ⌘F | Find in active pane (main conversation, `/btw` side question, or open file) |
| ⌘\ | Focus / Zen mode: hides sidebar + right panel from main view, or expands right panel when focused |
| ⌘⇧E | Side-by-side 50/50 split (full height, hides left sidebar) |
| ⌘/ | Toggle Markdown source/preview |
| ⌘, | Settings |
| ⌘[ / ⌘] | History |
| ⌘R | Refresh |

Before adding a shortcut, check this table, the registry, and the native Tauri menu. Keep scoped editor/dialog shortcuts local; never let a global handler override an already handled event.
