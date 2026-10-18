import { createSignal, For, onCleanup, Show } from "solid-js";
import { placesLabel, type SkillPlaces } from "./skillModel";

export type PlaceProject = { slug: string; title?: string };

/** Cursor-style placement picker: stackable checkboxes for Local, Common and each project. */
export function SkillPlacesPicker(p: { value: SkillPlaces; projects: PlaceProject[]; disabled?: boolean; onChange: (next: SkillPlaces) => void }) {
  const [open, setOpen] = createSignal(false);
  let root!: HTMLDivElement;
  const close = (e: PointerEvent) => { if (open() && !root.contains(e.target as Node)) setOpen(false); };
  const esc = (e: KeyboardEvent) => { if (e.key === "Escape") setOpen(false); };
  document.addEventListener("pointerdown", close);
  document.addEventListener("keydown", esc);
  onCleanup(() => { document.removeEventListener("pointerdown", close); document.removeEventListener("keydown", esc); });
  const toggleProject = (slug: string, on: boolean) => p.onChange({ ...p.value, projects: on ? [...new Set([...p.value.projects, slug])].sort() : p.value.projects.filter((s) => s !== slug) });
  return (
    <div class="skill-places" ref={root}>
      <button type="button" class="skill-places-btn" aria-haspopup="true" aria-expanded={open()} disabled={p.disabled} onClick={() => setOpen(!open())}>
        <svg viewBox="0 0 16 16" width="13" height="13" aria-hidden="true"><circle cx="8" cy="8" r="6.2" fill="none" stroke="currentColor" stroke-width="1.3" /><path d="M1.8 8h12.4M8 1.8c2 2 2 10.4 0 12.4M8 1.8c-2 2-2 10.4 0 12.4" fill="none" stroke="currentColor" stroke-width="1.1" /></svg>
        <span>{placesLabel(p.value)}</span>
        <span aria-hidden="true">⌄</span>
      </button>
      <Show when={open()}>
        <div class="skill-places-menu" role="group" aria-label="Where this skill applies">
          <label class="skill-places-row"><span><strong>Local</strong><small>This computer's agents (Claude Code, Codex, OpenCode…)</small></span><input type="checkbox" checked={p.value.local} onChange={(e) => p.onChange({ ...p.value, local: e.currentTarget.checked })} /></label>
          <label class="skill-places-row"><span><strong>Common</strong><small>Every mission and the coordinator</small></span><input type="checkbox" checked={p.value.common} onChange={(e) => p.onChange({ ...p.value, common: e.currentTarget.checked })} /></label>
          <div class="skill-places-sep">Projects</div>
          <For each={p.projects} fallback={<p class="dim skill-places-empty">No projects.</p>}>{(proj) => (
            <label class="skill-places-row"><span><strong>{proj.title || proj.slug}</strong><small>{proj.slug}</small></span><input type="checkbox" checked={p.value.projects.includes(proj.slug)} disabled={p.value.common} onChange={(e) => toggleProject(proj.slug, e.currentTarget.checked)} /></label>
          )}</For>
          <Show when={p.value.common && p.projects.length}><p class="dim skill-places-empty">Common already reaches every project.</p></Show>
        </div>
      </Show>
    </div>
  );
}
