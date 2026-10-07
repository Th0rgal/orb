/** Global navigation chords. Keep labels and dispatch in one registry. */
export const navigationShortcuts = [
  {id:'new-agent', code:'Digit1', label:'⌘1', title:'New agent'},
  {id:'inbox', code:'KeyI', label:'⌘I', title:'Inbox'},
  {id:'cloud-agent', code:'Digit2', label:'⌘2', title:'Cloud agent'},
  {id:'machines', code:'Digit3', label:'⌘3', title:'Machines'},
  {id:'providers', code:'Digit4', label:'⌘4', title:'Providers'},
  {id:'projects', code:'Digit5', label:'⌘5', title:'Projects'},
] as const;
export function navigationShortcut(event: KeyboardEvent) {
  if (event.isComposing || event.defaultPrevented || !(event.metaKey || event.ctrlKey) || event.altKey || event.shiftKey) return;
  return navigationShortcuts.find(shortcut => shortcut.code === event.code);
}
export const shortcutLabel = (id: typeof navigationShortcuts[number]['id']) => navigationShortcuts.find(s => s.id === id)!.label;
