import { createSignal, Show } from "solid-js";
import { Popover } from "../src/Popover";
export function NestedEditor() {
  const [open, setOpen] = createSignal(false);
  let anchor!: HTMLButtonElement;
  return <><button ref={anchor} aria-label="Editor" onClick={() => setOpen(!open())}>Editor</button><Show when={open()}><Popover label="Nested editor" anchor={anchor} onClose={() => setOpen(false)}><input aria-label="Editor value"/><button onClick={() => setOpen(false)}>Done</button></Popover></Show></>;
}
