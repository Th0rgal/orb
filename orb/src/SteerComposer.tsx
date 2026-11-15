import { Show, createSignal } from "solid-js";
import { Field } from "./Dialog";
import { connectionVersion, getMission, isClientPlacement, sendMissionMessage } from "./api";

/** Steering is an ordinary message; failed sends keep the draft and retry identity. */
export function SteerComposer(p: { missionId: string | null; disabled?: boolean; hint?: string; onBusyChange?: (busy: boolean) => void; onReplacement: (id: string, previousId: string) => Promise<void> }) {
  const [text, setText] = createSignal("");
  const [busy, setBusy] = createSignal(false);
  const [error, setError] = createSignal<string | null>(null);
  let attempt: { missionId: string; text: string; id: string } | undefined;
  const send = async () => {
    const missionId = p.missionId, body = text().trim();
    if (!missionId || !body || busy() || p.disabled) return;
    if (attempt?.missionId !== missionId || attempt.text !== body) attempt = { missionId, text: body, id: crypto.randomUUID() };
    const version = connectionVersion();
    setBusy(true); p.onBusyChange?.(true); setError(null);
    try {
      const mission = await getMission(missionId, { fresh: true, includeHistory: false });
      if (version !== connectionVersion() || p.missionId !== missionId) throw new Error("Controller changed. Your draft is kept.");
      if (isClientPlacement(mission)) throw new Error("Open this mission on the computer that started it to send your message. Your draft is kept.");
      const receipt = await sendMissionMessage(missionId, body, undefined, attempt.id, mission);
      setText(""); attempt = undefined;
      if (receipt.replacement) await p.onReplacement(receipt.replacement.id, missionId);
    } catch (e) { setError(e instanceof Error ? e.message : String(e)); }
    finally { setBusy(false); p.onBusyChange?.(false); }
  };
  return <form class="project-steer" onSubmit={e => { e.preventDefault(); void send(); }}>
    <Field label="Message controller" description={p.hint ?? (p.missionId ? "Send a normal message to the controller mission." : "Set a controller mission to send it a message.")} error={error()}>
      <textarea class="s-input" rows={3} value={text()} aria-label="Message controller" disabled={!p.missionId || busy() || p.disabled} placeholder="Message the controller…" onInput={e => setText(e.currentTarget.value)} />
    </Field>
    <button class="s-btn" type="submit" disabled={!p.missionId || busy() || p.disabled || !text().trim()}>{busy() ? "Sending…" : "Send message"}</button>
    <Show when={error()}><button class="s-btn" type="submit" disabled={busy() || p.disabled || !p.missionId}>Retry</button></Show>
  </form>;
}
