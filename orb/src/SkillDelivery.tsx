import { For, Show, createSignal } from "solid-js";
import { Select } from "./Select";
import type { ProjectSummary } from "./api";
import { UnsupportedEndpoint, getProjectSkills, getSkillDelivery, putProjectSkills, type SkillDelivery } from "./skillsApi";

const errorText = (e: unknown) => (e instanceof Error ? e.message : String(e));

/** Pick a project: edit its Library skill selection and preview what a mission receives. */
export function SkillDeliveryPreview(p: { projects: ProjectSummary[]; librarySkills: string[] }) {
  const [slug, setSlug] = createSignal("");
  const [selected, setSelected] = createSignal<string[]>([]);
  const [saved, setSaved] = createSignal<string[]>([]);
  const [missing, setMissing] = createSignal<string[]>([]);
  const [delivery, setDelivery] = createSignal<SkillDelivery | null>(null);
  const [selectionNote, setSelectionNote] = createSignal<string | null>(null);
  const [deliveryNote, setDeliveryNote] = createSignal<string | null>(null);
  const [busy, setBusy] = createSignal(false);
  const [error, setError] = createSignal<string | null>(null);
  let generation = 0;

  const loadDelivery = async (project: string, gen: number) => {
    try {
      const d = await getSkillDelivery(project);
      if (gen === generation) { setDelivery(d); setDeliveryNote(null); }
    } catch (e) {
      if (gen !== generation) return;
      setDelivery(null);
      setDeliveryNote(e instanceof UnsupportedEndpoint ? e.message : errorText(e));
    }
  };

  const pick = async (project: string) => {
    const gen = ++generation;
    setSlug(project);
    setError(null);
    setSelected([]); setSaved([]); setMissing([]); setDelivery(null);
    if (!project) return;
    const selection = getProjectSkills(project).then((res) => {
      if (gen !== generation) return;
      setSelected(res.skills); setSaved(res.skills); setMissing(res.missing); setSelectionNote(null);
    }).catch((e) => {
      if (gen === generation) setSelectionNote(e instanceof UnsupportedEndpoint ? e.message : errorText(e));
    });
    await Promise.all([selection, loadDelivery(project, gen)]);
  };

  const dirty = () => selected().join("\n") !== saved().join("\n");
  const save = async () => {
    if (busy() || !slug()) return;
    setBusy(true); setError(null);
    try {
      const res = await putProjectSkills(slug(), selected());
      setSelected(res.skills); setSaved(res.skills); setMissing(res.missing);
      await loadDelivery(slug(), generation);
    } catch (e) {
      setError(errorText(e));
    } finally {
      setBusy(false);
    }
  };
  const addable = () => p.librarySkills.filter((n) => !selected().includes(n));

  return (
    <section class="s-sec" aria-label="Skill delivery preview">
      <div class="skills-sec-head">
        <h3>Delivery preview</h3>
        <div class="skills-machine-pick">
          <span>Project</span>
          <Select aria-label="Preview project" class="s-input" value={slug()} onChange={(e) => void pick(e.currentTarget.value)}>
            <option value="">Choose a project…</option>
            <For each={p.projects}>{(proj) => <option value={proj.slug}>{proj.title || proj.slug}</option>}</For>
          </Select>
        </div>
      </div>
      <div class="s-card">
        <Show when={slug()} fallback={<div class="s-row"><div class="s-row-text"><div class="s-row-desc">Pick a project to see the skills its missions receive: base, global and project selections.</div></div></div>}>
          <div class="s-row skills-delivery-row">
            <div class="s-row-text">
              <div class="s-row-title">Project skills</div>
              <Show when={!selectionNote()} fallback={<div class="s-row-desc">{selectionNote()}</div>}>
                <div class="skills-chip-list skills-delivery-chips">
                  <For each={selected()} fallback={<span class="skills-sub-note">No project-selected skills.</span>}>{(name) => (
                    <span class={`skills-proj-chip ${missing().includes(name) ? "missing" : ""}`} title={missing().includes(name) ? "Not in the Library" : undefined}>
                      {name}
                      <button type="button" class="skills-chip-x" aria-label={`Remove ${name}`} disabled={busy()} onClick={() => setSelected(selected().filter((n) => n !== name))}>×</button>
                    </span>
                  )}</For>
                </div>
                <div class="skills-new-inputs">
                  <Select aria-label="Add project skill" class="s-input" value="" disabled={busy() || !addable().length} onChange={(e) => { const v = e.currentTarget.value; if (v) setSelected([...selected(), v]); }}>
                    <option value="">Add a Library skill…</option>
                    <For each={addable()}>{(n) => <option value={n}>{n}</option>}</For>
                  </Select>
                  <button type="button" class="s-btn sm primary" disabled={busy() || !dirty()} onClick={() => void save()}>{busy() ? "Saving…" : "Save selection"}</button>
                </div>
                <Show when={missing().length}><p class="skills-harness-warn">Not in the Library: {missing().join(", ")}</p></Show>
              </Show>
              <Show when={error()}>{(e) => <p class="inline-error" role="alert">{e()}</p>}</Show>
            </div>
          </div>
          <div class="s-row skills-delivery-row">
            <div class="s-row-text">
              <div class="s-row-title">Resolved delivery {delivery() ? `(${delivery()!.skills.length})` : ""}</div>
              <Show when={delivery()} fallback={<div class="s-row-desc">{deliveryNote() ?? "Resolving…"}</div>}>
                {(d) => (
                  <>
                    <div class="skills-delivery-list" role="list">
                      <For each={d().skills}>{(s) => (
                        <div class="skills-delivery-item" role="listitem">
                          <code>{s.name}</code>
                          <For each={s.reasons}>{(r) => <span class={`skills-aud aud-${r}`}>{r}</span>}</For>
                        </div>
                      )}</For>
                    </div>
                    <Show when={d().missing.length}><p class="skills-harness-warn">Missing from the Library: {d().missing.join(", ")}</p></Show>
                  </>
                )}
              </Show>
            </div>
          </div>
        </Show>
      </div>
    </section>
  );
}
