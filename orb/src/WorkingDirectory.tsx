import { createSignal, Show } from "solid-js";
import { PromptSheet } from "./Dialog";
import { FolderIcon, ChevronDown, CloseIcon } from "./icons";
import { hasNativePicker, pickNativeDirectory } from "./uploads";

export function WorkingDirectory(p: { value: string; local: boolean; scope: string; disabled: boolean; onChange: (path: string) => void }) {
  const [pending, setPending] = createSignal(false);
  const [editing, setEditing] = createSignal<string>();
  const [draft, setDraft] = createSignal("");
  const [error, setError] = createSignal("");
  const choose = async () => {
    if (pending() || p.disabled) return;
    const scope = p.scope;
    setError("");
    if (!p.local || !hasNativePicker()) {
      setDraft(p.value); setEditing(scope); return;
    }
    setPending(true);
    try {
      const path = await pickNativeDirectory(p.value);
      if (path !== null && scope === p.scope && !p.disabled) p.onChange(path);
    } catch (err) {
      if (scope === p.scope) setError(String(err));
    } finally { setPending(false); }
  };
  return <>
    <span class="picks-sep">·</span>
    <div class="working-directory">
      <button class="model" aria-label="Choose working directory" title={error() || p.value || "Default directory"} disabled={p.disabled || pending()} onClick={choose}>
        <FolderIcon size={14} /><span class="working-directory-name">{pending() ? "Choosing…" : p.value.split(/[\\/]/).filter(Boolean).pop() || (p.value ? "/" : "Default directory")}</span><ChevronDown size={12} />
      </button>
      <Show when={p.value}><button class="working-directory-reset" aria-label="Use default directory" title="Use default directory" disabled={p.disabled || pending()} onClick={() => p.onChange("")}><CloseIcon size={12} /></button></Show>
      <Show when={error()}><span role="alert">{error()}</span></Show>
    </div>
    <Show when={editing() === p.scope}>
      <PromptSheet title="Working directory" hint={p.local ? "Enter the folder path, or use Orb desktop to browse folders." : "Enter a folder path on the selected remote machine."} value={draft()} onInput={setDraft} action="Choose" onAction={() => { p.onChange(draft().trim()); setEditing(undefined); }} onClose={() => setEditing(undefined)} />
    </Show>
  </>;
}
