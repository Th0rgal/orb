# Keyboard shortcuts

Global section navigation is registered in `src/keyboardShortcuts.ts`; both dispatch and sidebar labels read that registry. Use physical key codes so number shortcuts work on AZERTY too. Ctrl is accepted in place of Command outside macOS. Focused dialogs retain their keyboard scope.

| Shortcut | Action |
| --- | --- |
| ⌘1 / ⌘N | New agent |
| ⌘2 | Cloud agent |
| ⌘3 | Machines |
| ⌘4 | Providers |
| ⌘5 | Focus projects; ↑/↓ navigate visible rows, Enter opens/toggles |
| ⌘B | Sidebar (file pane owns this chord while it has focus) |
| ⌘, | Settings |
| ⌘[ / ⌘] | History |
| ⌘R | Refresh |
| ⌘F | Find |
| ⌘P | File palette |
| ⌘J | File panel |
| ⌘⇧F | File panel search |
| ⌘/ | Markdown source/preview |

Before adding a shortcut, check this table, the registry, and the native Tauri menu. Keep scoped editor/dialog shortcuts local; never let a global handler override an already handled event.
