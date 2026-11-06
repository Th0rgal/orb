import { For, Show, createMemo, createSignal, onCleanup, onMount } from "solid-js";
import { Dialog, DialogButton, Field } from "./Dialog";
import { ErrorNotice } from "./ErrorNotice";
import { Select } from "./Select";
import { getAllProviderUsage, getProviderUsage, isConnected, listProviders, resetProviderUsage, type AIProvider, type Mission, type ProviderUsage } from "./api";
import { formatResetGrantOption, subscriptionResetSummary, supportsSubscriptionReset, usableSubscriptionReset } from "./providerUsage";

export function SubscriptionResetDialog(p: {
  provider: Pick<AIProvider, "id" | "name" | "account_email" | "provider_type">;
  usage?: ProviderUsage;
  onClose: () => void;
  onDone: (updated: ProviderUsage) => void;
}) {
  const idempotencyKey = crypto.randomUUID();
  const grants = createMemo(() => {
    const all = p.usage?.subscription_resets?.grants ?? [];
    const usable = all.filter(g => g.usable_now);
    return usable.length ? usable : all;
  });
  const [grantId, setGrantId] = createSignal(grants()[0]?.id ?? "");
  const [busy, setBusy] = createSignal(false);
  const [error, setError] = createSignal<string | null>(null);
  let cancelBtn!: HTMLButtonElement;

  const accountLabel = () => p.provider.account_email || p.provider.name;
  const summary = createMemo(() => subscriptionResetSummary(p.usage));
  const description = createMemo(() => {
    const detail = summary()?.detail;
    return `Redeem 1 banked subscription reset on ${accountLabel()}? ${detail ? `${detail}. ` : ""}This immediately consumes a reset on your subscription and cannot be undone.`;
  });

  const confirm = async () => {
    if (busy()) return;
    setBusy(true);
    setError(null);
    try {
      const updated = await resetProviderUsage(p.provider.id, {
        idempotencyKey,
        grantId: grantId() || undefined,
      });
      window.dispatchEvent(new Event("orb:providers-refresh"));
      p.onDone(updated);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  };

  return (
    <Dialog
      size="compact"
      title="Use subscription reset"
      description={description()}
      busy={busy()}
      initialFocus={() => cancelBtn}
      onClose={p.onClose}
      footer={requestClose => (
        <>
          <DialogButton ref={cancelBtn} disabled={busy()} onClick={requestClose}>Cancel</DialogButton>
          <DialogButton variant="destructive" disabled={busy()} onClick={() => void confirm()}>
            {busy() ? "Resetting…" : "Use reset"}
          </DialogButton>
        </>
      )}
    >
      <Show when={grants().length > 1}>
        <Field label="Reset grant">
          <Select class="s-input" value={grantId()} disabled={busy()} onChange={e => setGrantId(e.currentTarget.value)}>
            <For each={grants()}>{g => <option value={g.id}>{formatResetGrantOption(g)}</option>}</For>
          </Select>
        </Field>
      </Show>
      <Show when={error()}>
        <ErrorNotice error={error()!} />
      </Show>
    </Dialog>
  );
}

export function QuotaResetAction(p: { mission: Mission; disabled?: boolean; onResetRedeemed?: () => void }) {
  const [candidate, setCandidate] = createSignal<{ provider: AIProvider; usage: ProviderUsage } | null>(null);
  const [open, setOpen] = createSignal(false);
  let disposed = false;

  const targetType = () => p.mission.backend === "claudecode" ? "anthropic"
    : p.mission.backend === "codex" ? "openai" : null;

  onMount(() => {
    const wanted = targetType();
    if (!wanted || !isConnected()) return;
    void (async () => {
      try {
        const [providers, bulk] = await Promise.all([listProviders(), getAllProviderUsage()]);
        if (disposed) return;
        const eligible = providers.filter(a => a.enabled !== false && a.provider_type === wanted && supportsSubscriptionReset(a));
        for (const a of eligible) {
          let u: ProviderUsage | undefined = bulk[a.id];
          if (!u) {
            try { u = await getProviderUsage(a.id); } catch { /* ignore */ }
            if (disposed) return;
          }
          if (usableSubscriptionReset(u)) {
            setCandidate({ provider: a, usage: u! });
            return;
          }
        }
      } catch { /* banner stays clean if provider catalog fails */ }
    })();
  });
  onCleanup(() => { disposed = true; });

  return (
    <Show when={candidate()}>
      {c => (
        <>
          <button type="button" tabIndex={0} disabled={p.disabled} onClick={() => setOpen(true)}>
            Use subscription reset…
          </button>
          <Show when={open()}>
            <SubscriptionResetDialog
              provider={c().provider}
              usage={c().usage}
              onClose={() => setOpen(false)}
              onDone={() => {
                setOpen(false);
                setCandidate(null);
                p.onResetRedeemed?.();
              }}
            />
          </Show>
        </>
      )}
    </Show>
  );
}
