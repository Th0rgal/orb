import { For, Show, createMemo, createSignal, onMount } from "solid-js";
import type { Mission } from "./api";
import { Dialog, DialogButton, Field } from "./Dialog";
import { ErrorNotice } from "./ErrorNotice";
import {
  type MissionShareEntry,
  type UserDirectoryEntry,
  addMissionShare,
  listMissionShares,
  listUserDirectory,
  removeMissionShare,
} from "./missionSharesApi";

export function ShareMissionDialog(p: {
  mission: Mission;
  onClose: () => void;
  onSharesChanged?: (shares: MissionShareEntry[]) => void;
}) {
  const [shares, setShares] = createSignal<MissionShareEntry[]>(p.mission.shared_with ?? []);
  const [directory, setDirectory] = createSignal<UserDirectoryEntry[]>([]);
  const [loading, setLoading] = createSignal(true);
  const [query, setQuery] = createSignal("");
  const [busy, setBusy] = createSignal(false);
  const [error, setError] = createSignal<string | null>(null);

  onMount(async () => {
    setLoading(true);
    setError(null);
    try {
      const [loadedShares, loadedDir] = await Promise.all([
        listMissionShares(p.mission.id),
        listUserDirectory().catch(() => [] as UserDirectoryEntry[]),
      ]);
      setShares(loadedShares);
      setDirectory(loadedDir);
      p.onSharesChanged?.(loadedShares);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setLoading(false);
    }
  });

  const sharedUserIds = createMemo(() => new Set(shares().map((s) => s.user_id)));
  const sharedUsernames = createMemo(
    () => new Set(shares().map((s) => s.username.toLowerCase())),
  );

  const candidates = createMemo(() => {
    const q = query().trim().toLowerCase().replace(/^@/, "");
    return directory().filter(
      (u) =>
        !sharedUserIds().has(u.id) &&
        !sharedUsernames().has(u.username.toLowerCase()) &&
        (!q || u.username.toLowerCase().includes(q)),
    );
  });

  const invite = async (usernameRaw: string) => {
    const clean = usernameRaw.trim().replace(/^@/, "");
    if (!clean || busy()) return;
    setBusy(true);
    setError(null);
    try {
      const updated = await addMissionShare(p.mission.id, { username: clean });
      setShares(updated);
      setQuery("");
      p.onSharesChanged?.(updated);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  };

  const revoke = async (entry: MissionShareEntry) => {
    if (busy()) return;
    const prev = shares();
    const optimistic = prev.filter((s) => s.user_id !== entry.user_id);
    setShares(optimistic);
    p.onSharesChanged?.(optimistic);
    setBusy(true);
    setError(null);
    try {
      await removeMissionShare(p.mission.id, entry.user_id);
    } catch (e) {
      setShares(prev);
      p.onSharesChanged?.(prev);
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  };

  return (
    <Dialog
      size="compact"
      title="Share mission"
      description="Collaborators can read the live transcript, send messages, and stop or resume turns. Only you can move, archive, fork, or delete this mission."
      busy={busy()}
      onClose={p.onClose}
      footer={(close) => (
        <DialogButton disabled={busy()} onClick={close}>
          Done
        </DialogButton>
      )}
    >
      <Show when={error()}>
        <ErrorNotice error={error()!} />
      </Show>
      <form
        onSubmit={(e) => {
          e.preventDefault();
          void invite(query());
        }}
      >
        <Field label="Invite collaborator" description="Type a username or pick an account below.">
          <div style={{ display: "flex", gap: "8px" }}>
            <input
              class="s-input"
              autofocus
              placeholder="username"
              value={query()}
              disabled={busy()}
              onInput={(e) => setQuery(e.currentTarget.value)}
            />
            <DialogButton
              type="submit"
              variant="primary"
              disabled={busy() || !query().trim()}
            >
              Add
            </DialogButton>
          </div>
        </Field>
      </form>

      <Show when={candidates().length > 0}>
        <div class="s-card" style={{ "margin-top": "10px" }}>
          <For each={candidates().slice(0, 6)}>
            {(user) => (
              <div class="s-row">
                <div class="s-row-text">
                  <div class="s-row-title">@{user.username}</div>
                </div>
                <div class="s-row-ctrl">
                  <button
                    type="button"
                    class="s-btn"
                    disabled={busy()}
                    onClick={() => void invite(user.username)}
                  >
                    Share
                  </button>
                </div>
              </div>
            )}
          </For>
        </div>
      </Show>

      <div style={{ "margin-top": "14px" }}>
        <div class="muted" style={{ "font-size": "12px", "margin-bottom": "6px" }}>
          Collaborators ({shares().length})
        </div>
        <Show
          when={!loading()}
          fallback={
            <div class="s-card" role="status" aria-busy="true">
              <div class="s-row">
                <div class="sk-bar" style={{ width: "45%", height: "13px" }} />
              </div>
            </div>
          }
        >
          <Show
            when={shares().length > 0}
            fallback={
              <div class="muted" style={{ "font-size": "13px" }}>
                Only you have access to this mission.
              </div>
            }
          >
            <div class="s-card">
              <For each={shares()}>
                {(entry) => (
                  <div class="s-row">
                    <div class="s-row-text">
                      <div class="s-row-title">@{entry.username}</div>
                      <div class="s-row-desc">Participant</div>
                    </div>
                    <div class="s-row-ctrl">
                      <button
                        type="button"
                        class="s-btn danger"
                        disabled={busy()}
                        onClick={() => void revoke(entry)}
                      >
                        Remove
                      </button>
                    </div>
                  </div>
                )}
              </For>
            </div>
          </Show>
        </Show>
      </div>
    </Dialog>
  );
}
export default ShareMissionDialog;
