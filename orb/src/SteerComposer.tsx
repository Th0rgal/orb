import { Show, createSignal } from "solid-js";
import { Field } from "./Dialog";
import { sendMissionMessage } from "./api";

/** Steering is an ordinary message; failed sends keep the draft and retry identity. */
export function SteerComposer(p: { missionId: string | null; onReplacement: (id: string) => Promise<void> }) {
  const [text, setText] = createSignal("");
  const [busy, setBusy] = createSignal(false);
  const [error, setError] = createSignal<string | null>(null);
  let attempt: { missionId: string; text: string; id: string } | undefined;
  const send = async () => {
    const missionId = p.missionId, body = text().trim();
    if (!missionId || !body || busy()) return;
    if (attempt?.missionId !== missionId || attempt.text !== body) attempt = { missionId, text: body, id: crypto.randomUUID() };
    setBusy(true); setError(null);
    try {
      const receipt = await sendMissionMessage(missionId, body, undefined, attempt.id);
      setText(""); attempt = undefined;
      if (receipt.replacement) await p.onReplacement(receipt.replacement.id);
    } catch (e) { setError(e instanceof Error ? e.message : String(e)); }
    finally { setBusy(false); }
  };
  return <form class="project-steer" onSubmit={e => { e.preventDefault(); void send(); }}>
    <Field label="Message controller" description={p.missionId ? "Send a normal message to the controller mission." : "Set a controller mission to send it a message."} error={error()}>
      <textarea class="s-input" rows={3} value={text()} aria-label="Message controller" disabled={!p.missionId || busy()} placeholder="Message the controller…" onInput={e => setText(e.currentTarget.value)} />
    </Field>
    <button class="s-btn" type="submit" disabled={!p.missionId || busy() || !text().trim()}>{busy() ? "Sending…" : "Send message"}</button>
    <Show when={error()}><button class="s-btn" type="submit" disabled={busy() || !p.missionId}>Retry</button></Show>
  </form>;
}
