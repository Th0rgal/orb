/** Arrow traversal changes focus, never the selected value. */
export function navigateOverlayItems(event: KeyboardEvent, root: HTMLElement, selector: string) {
  if (event.defaultPrevented || event.isComposing || !["ArrowDown", "ArrowUp", "Home", "End"].includes(event.key)) return;
  if (event.target instanceof HTMLInputElement && ["Home", "End"].includes(event.key)) return;
  const items = Array.from(root.querySelectorAll<HTMLElement>(selector)).filter(item => !item.matches(":disabled, [aria-disabled='true']") && !item.closest("[hidden], [inert]"));
  const current = items.indexOf(document.activeElement as HTMLElement);
  const next = event.key === "Home" || (event.key === "ArrowDown" && current < 0) ? 0 : event.key === "End" || (event.key === "ArrowUp" && current < 0) ? items.length - 1 : (current + (event.key === "ArrowDown" ? 1 : -1) + items.length) % items.length;
  event.preventDefault(); event.stopPropagation();
  items[next]?.focus({preventScroll: true}); items[next]?.scrollIntoView?.({block:"nearest"});
}
