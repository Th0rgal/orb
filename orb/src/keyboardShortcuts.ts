/** Global navigation and shell chords. Keep labels and dispatch in one registry. */
export const navigationShortcuts = [
  {id:'new-agent', code:'Digit1', label:'⌘1', title:'New agent'},
  {id:'inbox', code:'KeyI', label:'⌘I', title:'Inbox'},
  {id:'cloud-agent', code:'Digit2', label:'⌘2', title:'Cloud agent'},
  {id:'machines', code:'Digit3', label:'⌘3', title:'Machines'},
  {id:'providers', code:'Digit4', label:'⌘4', title:'Inference'},
  {id:'projects', code:'Digit5', label:'⌘5', title:'Projects'},
] as const;
export function navigationShortcut(event: KeyboardEvent) {
  if (event.isComposing || event.defaultPrevented || !hasPrimaryModifier(event) || event.altKey || event.shiftKey) return;
  return navigationShortcuts.find(shortcut => shortcut.code === event.code);
}
export const shortcutLabel = (id: typeof navigationShortcuts[number]['id']) => navigationShortcuts.find(s => s.id === id)!.label;

export function isMacKeyboardPlatform(): boolean {
  if (typeof navigator === "undefined") return true;
  const platform = (navigator as Navigator & { userAgentData?: { platform?: string } }).userAgentData?.platform ?? navigator.platform ?? navigator.userAgent ?? "";
  return /mac|iphone|ipad|ipod/i.test(platform);
}

/** Command on macOS/iOS, Command or Control elsewhere (without mixing both on one chord). */
export function hasPrimaryModifier(event: KeyboardEvent): boolean {
  return isMacKeyboardPlatform()
    ? event.metaKey && !event.ctrlKey
    : event.metaKey !== event.ctrlKey;
}

/** Strict platform modifier for chords where Control+letter has native macOS editing meaning (e.g. Ctrl+K). */
function hasStrictPlatformModifier(event: KeyboardEvent): boolean {
  return isMacKeyboardPlatform()
    ? event.metaKey && !event.ctrlKey
    : event.ctrlKey && !event.metaKey;
}

export const searchShortcutLabel = () => (isMacKeyboardPlatform() ? "⌘⇧F" : "Ctrl+Shift+F");
export const btwShortcutLabel = () => (isMacKeyboardPlatform() ? "⌘K" : "Ctrl+K");
export const filesShortcutLabel = () => (isMacKeyboardPlatform() ? "⌘J" : "Ctrl+J");
export const fileTreeShortcutLabel = () => (isMacKeyboardPlatform() ? "⌘⇧B" : "Ctrl+Shift+B");
export const expandShortcutLabel = () => (isMacKeyboardPlatform() ? "⌘\\" : "Ctrl+\\");
export const sidebarShortcutLabel = () => (isMacKeyboardPlatform() ? "⌘B" : "Ctrl+B");

/** Command-Shift-F on macOS, Control-Shift-F elsewhere; ignores IME composition and extra modifiers. */
export function isSearchShortcut(event: KeyboardEvent): boolean {
  if (event.isComposing || event.defaultPrevented || event.altKey || !event.shiftKey) return false;
  const keyMatches = event.code === "KeyF" || event.key.toLowerCase() === "f";
  return keyMatches && hasStrictPlatformModifier(event);
}

/** Command-F on macOS, Control-F elsewhere (local Find, or global search when sidebar has focus). */
export function isFindShortcut(event: KeyboardEvent): boolean {
  if (event.isComposing || event.defaultPrevented || event.altKey || event.shiftKey) return false;
  const keyMatches = event.code === "KeyF" || event.key.toLowerCase() === "f";
  return keyMatches && hasPrimaryModifier(event);
}

/** Command-K (or legacy Command-Shift-J) on macOS, Control-K / Control-Shift-J elsewhere. */
export function isBtwShortcut(event: KeyboardEvent): boolean {
  if (event.isComposing || event.defaultPrevented || event.altKey || !hasPrimaryModifier(event)) return false;
  if (!event.shiftKey) {
    return event.code === "KeyK" || event.key.toLowerCase() === "k";
  }
  return event.code === "KeyJ" || event.key.toLowerCase() === "j";
}

/** Command-\ on macOS, Control-\ elsewhere: focus/expand the active pane (conversation or right panel). */
export function isFocusModeShortcut(event: KeyboardEvent): boolean {
  if (event.isComposing || event.defaultPrevented || event.altKey || event.shiftKey) return false;
  const keyMatches = event.code === "Backslash" || event.key === "\\";
  return keyMatches && hasPrimaryModifier(event);
}
