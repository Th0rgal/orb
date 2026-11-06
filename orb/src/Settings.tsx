import { HARNESS_IDS, harnessName } from "./harnesses";
import { cloudAccounts, cloudNames, type CloudAccount } from "./cloudAgentApi";
import { ErrorToast } from "./toast";
import { ExecutionSettings } from "./ExecutionSettings";
import { MachineProvidersCard } from "./ManagedMachines";
import { Select } from "./Select";
import { ConfirmDialog, Dialog, DialogButton, Field } from "./Dialog";
import { For, Show, createEffect, createSignal, on, onCleanup, onMount, type JSX } from "solid-js";
import * as Ic from "./icons";
import {
  clearConnection,
  connectionVersion,
  getApiUrl,
  getGlobalSettings,
  getJwt,
  isConnected,
  login,
  probeHealth,
  setApiUrl,
  setConnection,
  updateGlobalSettings,
  type ServerHealthInfo,
} from "./api";
import {
  authorizeGitHubIntegration,
  changeServerPassword,
  disconnectGitHubIntegration,
  downloadSettingsBackup,
  getAuthStatus,
  getGitHubIntegrationStatus,
  interpretRestoreResponse,
  parseCleanupDays,
  restoreSettingsBackup,
  type AuthStatusInfo,
  type GitHubIntegrationStatus,
} from "./accountAdmin";
import { ApprovalCancelled } from "./deviceApproval";
import {
  loadPendingGitHubOAuthAttempt,
  signInWithGitHubDesktop,
  verifyGitHubOAuthCallback,
  verifyIssuedAuthToken,
} from "./githubSignIn";
import { localInstalled, pathOverrides, refreshLocalAgents, setPathOverride, tauriInvoke } from "./localAgents";
import { nativeInvoke } from "./native";
import { pollWhileVisible } from "./poll";
import { DebugInfoPanel } from "./DebugInfo";
import { SettingsCard as Card, SettingsRow as Row } from "./SettingsCard";
import { Toggle } from "./Toggle";
export { Toggle };
import { getThemePref, setThemePref, type ThemePref } from "./theme";
import {
  describeBackgroundSyncStatus,
  getBackgroundSyncMode,
  getBackgroundSyncVerdict,
  setBackgroundSyncMode,
  type BackgroundSyncMode,
} from "./backgroundSync";

const THEME_LABELS: Record<ThemePref, string> = { auto: "Auto", light: "Light", dark: "Dark" };
const THEME_PREFS: Record<string, ThemePref> = { Auto: "auto", Light: "light", Dark: "dark" };
const BG_SYNC_LABELS: Record<BackgroundSyncMode, string> = { auto: "Auto", on: "On", off: "Off" };
const BG_SYNC_MODES: Record<string, BackgroundSyncMode> = { Auto: "auto", On: "on", Off: "off" };

function openExternalUrl(url: string) {
  const invoke = nativeInvoke();
  if (invoke) {
    void invoke("open_url", { url }).catch(() => window.open(url, "_blank", "noopener,noreferrer"));
  } else {
    window.open(url, "_blank", "noopener,noreferrer");
  }
}

function CloudAccountsCard(p: { onOpenPage?: (id: string) => void }) {
  const [accounts, setAccounts] = createSignal<CloudAccount[]>([]);
  const [busy, setBusy] = createSignal(false);
  const [error, setError] = createSignal("");
  const refresh = async () => {
    if (!isConnected()) return;
    const version = connectionVersion();
    setBusy(true);
    try { const list = await cloudAccounts(); if (connectionVersion() === version) { setAccounts(list); setError(""); } }
    catch (e) { if (connectionVersion() === version) setError(String(e)); }
    finally { setBusy(false); }
  };
  // Accounts belong to the connected Core: drop them on disconnect and reload
  // after every (re)connect instead of keeping a pre-login failure on screen.
  // connectionVersion bumps on every connect and disconnect.
  createEffect(on(connectionVersion, () => {
    setAccounts([]);
    setError("");
    void refresh();
  }));
  return <Card title="Cloud accounts">
    <Row title="Connected services" desc={isConnected() ? "Cloud agents use accounts connected to Core. Connecting an account does not start work." : "Connect to the backend above to see cloud accounts."}>
      <button class="s-btn" disabled={busy() || !isConnected()} onClick={() => void refresh()}>{busy() ? "Checking…" : "Refresh accounts"}</button>
    </Row>
    <ErrorToast error={error()} title="Couldn’t refresh cloud accounts" onDismiss={() => setError("")} />
    <For each={accounts()}>{a => <Row title={`${cloudNames[a.provider]} · ${a.label}`} desc={a.reason}>
      <span>{a.available ? "Available" : "Unavailable"}{a.experimental ? " · Experimental" : ""}</span>
      <Show when={a.provider === "hermes" && p.onOpenPage}><button class="s-btn" onClick={() => p.onOpenPage?.("hermes-settings")}>Configure</button></Show>
    </Row>}</For>
  </Card>;
}

function GitHubIntegrationCard() {
  const [status, setStatus] = createSignal<GitHubIntegrationStatus | null>(null);
  const [busy, setBusy] = createSignal(false);
  const [copied, setCopied] = createSignal(false);
  const [error, setError] = createSignal<string | null>(null);
  const [confirmDisconnect, setConfirmDisconnect] = createSignal(false);
  const [disconnectBusy, setDisconnectBusy] = createSignal(false);
  const [disconnectError, setDisconnectError] = createSignal<string | null>(null);

  const refresh = async () => {
    if (!isConnected()) return;
    const version = connectionVersion();
    try {
      const next = await getGitHubIntegrationStatus();
      if (connectionVersion() === version) {
        setStatus(next);
        setError(null);
      }
    } catch (e) {
      if (connectionVersion() === version) {
        setError(e instanceof Error ? e.message : String(e));
      }
    }
  };

  createEffect(on(connectionVersion, () => {
    setStatus(null);
    setError(null);
    if (isConnected()) void refresh();
  }));

  createEffect(() => {
    if (!isConnected() || !status()?.pending) return;
    const stop = pollWhileVisible(() => refresh(), 3000);
    onCleanup(stop);
  });

  const startConnect = async () => {
    if (busy()) return;
    setBusy(true);
    setError(null);
    try {
      const auth = await authorizeGitHubIntegration();
      setStatus({
        configured: true,
        connected: false,
        pending: true,
        user_code: auth.user_code,
        verification_uri: auth.verification_uri_complete ?? auth.verification_uri,
        scopes: [],
      });
      openExternalUrl(auth.verification_uri_complete ?? auth.verification_uri);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  };

  const copyCode = async () => {
    const code = status()?.user_code;
    if (!code) return;
    await navigator.clipboard.writeText(code);
    setCopied(true);
    setTimeout(() => setCopied(false), 1400);
  };

  const runDisconnect = async () => {
    if (disconnectBusy()) return;
    setDisconnectBusy(true);
    setDisconnectError(null);
    try {
      await disconnectGitHubIntegration();
      setConfirmDisconnect(false);
      await refresh();
    } catch (e) {
      setDisconnectError(e instanceof Error ? e.message : String(e));
    } finally {
      setDisconnectBusy(false);
    }
  };

  return (
    <Show when={isConnected()}>
      <Card title="GitHub">
        <Show
          when={status()?.connected}
          fallback={
            <Show
              when={status()?.pending && status()?.user_code}
              fallback={
                <Row
                  title="Mission git & gh credentials"
                  desc={
                    status()?.configured === false
                      ? "Configure GITHUB_OAUTH_CLIENT_ID on Core to connect."
                      : "Authorize a GitHub account via device flow so server missions can push branches and open pull requests."
                  }
                >
                  <button
                    type="button"
                    class="s-btn"
                    disabled={busy() || status()?.configured === false}
                    onClick={() => void startConnect()}
                  >
                    {busy() ? "Starting…" : "Connect GitHub"}
                  </button>
                </Row>
              }
            >
              <Row
                title={`One-time code: ${status()!.user_code}`}
                desc="Enter this code on GitHub to finish connecting. Waiting for approval…"
              >
                <button type="button" class="s-btn" onClick={() => void copyCode()}>
                  {copied() ? "Copied" : "Copy code"}
                </button>
                <button
                  type="button"
                  class="s-btn primary"
                  onClick={() => openExternalUrl(status()!.verification_uri || "https://github.com/login/device")}
                >
                  Open GitHub
                </button>
              </Row>
            </Show>
          }
        >
          <Row
            title={`@${status()!.login}`}
            desc={[
              status()!.name || status()!.email,
              status()!.scopes.length ? `Scopes: ${status()!.scopes.join(", ")}` : null,
            ].filter(Boolean).join(" · ") || "Injected into server mission workspaces for git push and gh."}
          >
            <button type="button" class="s-btn" onClick={() => { setDisconnectError(null); setConfirmDisconnect(true); }}>
              Disconnect…
            </button>
          </Row>
        </Show>
      </Card>
      <ErrorToast error={error()} title="Couldn’t load GitHub integration" background onDismiss={() => setError(null)} />
      <Show when={confirmDisconnect()}>
        <ConfirmDialog
          title="Disconnect GitHub?"
          description="New server missions will no longer receive stored GitHub git-push credentials."
          action={disconnectError() ? "Retry" : "Disconnect"}
          destructive
          busy={disconnectBusy()}
          error={disconnectError()}
          onClose={() => setConfirmDisconnect(false)}
          onConfirm={() => void runDisconnect()}
        />
      </Show>
    </Show>
  );
}

type ContextWorker = { project: string; connected: boolean; running: boolean };
/** Project context workers keep each project's local replica fresh, even after Orb quits. */
function BackgroundSyncCard() {
  const [workers, setWorkers] = createSignal<ContextWorker[]>([]);
  const [error, setError] = createSignal("");
  const request = (project: string) => ({ endpoint: getApiUrl(), token: getJwt() ?? "", project, paths: [] });
  const refresh = async () => {
    try {
      const invoke = tauriInvoke(); if (!invoke) return;
      const res = await invoke("project_context_workers", { request: request("list") }) as { workers: ContextWorker[] };
      setWorkers(res.workers); setError("");
    } catch (e) { setError(String(e)); }
  };
  const stop = async (project: string) => {
    try { const invoke = tauriInvoke(); if (!invoke) return; await invoke("project_context_stop", { request: request(project) }); }
    catch (e) { setError(String(e)); }
    setTimeout(() => void refresh(), 1500);
  };
  onMount(() => { if (isConnected()) void refresh(); });
  return <Show when={workers().length || error()}>
    <Card title="Background sync">
      <Row title="Project context" desc="One small process per project keeps its context folder in sync with Core, also while Orb is closed. Stopping one pauses it until you use that project again.">
        <button class="s-btn" onClick={() => void refresh()}>Refresh</button>
      </Row>
      <ErrorToast error={error()} title="Couldn’t read background sync" onDismiss={() => setError("")} />
      <For each={workers()}>{w => <Row title={w.project} desc={w.running ? "Syncing in the background" : w.connected ? "Starting…" : "Paused"}>
        <Show when={w.connected}><button class="s-btn" onClick={() => void stop(w.project)}>Stop</button></Show>
      </Row>}</For>
    </Card>
  </Show>;
}

function WorkspaceCleanupCard() {
  const [loaded, setLoaded] = createSignal(false);
  const [enabled, setEnabled] = createSignal(false);
  const [daysDraft, setDaysDraft] = createSignal("14");
  const [stoppedDaysDraft, setStoppedDaysDraft] = createSignal("7");
  const [orphansEnabled, setOrphansEnabled] = createSignal(true);
  const [dirty, setDirty] = createSignal(false);
  const [saving, setSaving] = createSignal(false);
  const [error, setError] = createSignal<string | null>(null);
  const [notice, setNotice] = createSignal<string | null>(null);

  let saveSeq = 0;

  const load = async () => {
    saveSeq += 1;
    setSaving(false);
    setLoaded(false);
    setDirty(false);
    setError(null);
    setNotice(null);
    if (!isConnected()) return;
    const version = connectionVersion();
    try {
      const s = await getGlobalSettings();
      if (connectionVersion() !== version) return;
      setEnabled(Boolean(s.auto_cleanup_enabled));
      setDaysDraft(String(s.auto_cleanup_days ?? 14));
      setStoppedDaysDraft(String(s.auto_cleanup_stopped_days ?? 7));
      setOrphansEnabled(s.auto_cleanup_orphans_enabled ?? true);
      setDirty(false);
      setLoaded(true);
    } catch (e) {
      if (connectionVersion() === version) {
        setError(e instanceof Error ? e.message : String(e));
      }
    }
  };

  createEffect(on(connectionVersion, () => {
    void load();
  }));

  const save = async () => {
    if (saving() || !loaded()) return;
    const days = parseCleanupDays(daysDraft(), 1, 365);
    const stoppedDays = parseCleanupDays(stoppedDaysDraft(), 1, 365);
    if (days == null || stoppedDays == null) {
      setError("Retention days must be whole numbers between 1 and 365.");
      return;
    }
    const version = connectionVersion();
    const seq = ++saveSeq;
    setSaving(true);
    setError(null);
    setNotice(null);
    try {
      const updated = await updateGlobalSettings({
        auto_cleanup_enabled: enabled(),
        auto_cleanup_days: days,
        auto_cleanup_stopped_days: stoppedDays,
        auto_cleanup_orphans_enabled: orphansEnabled(),
      });
      if (seq !== saveSeq || connectionVersion() !== version) return;
      setEnabled(Boolean(updated.auto_cleanup_enabled));
      setDaysDraft(String(updated.auto_cleanup_days ?? days));
      setStoppedDaysDraft(String(updated.auto_cleanup_stopped_days ?? stoppedDays));
      setOrphansEnabled(updated.auto_cleanup_orphans_enabled ?? orphansEnabled());
      setDirty(false);
      setNotice("Saved workspace cleanup policy.");
    } catch (e) {
      if (seq === saveSeq && connectionVersion() === version) {
        setError(e instanceof Error ? e.message : String(e));
      }
    } finally {
      if (seq === saveSeq && connectionVersion() === version) {
        setSaving(false);
      }
    }
  };

  return (
    <Show when={isConnected()}>
      <Card title="Workspace cleanup">
        <Row title="Automatic mission workspace GC" desc="Periodically reclaim disk and container /tmp scratch from finished missions.">
          <Toggle
            on={enabled()}
            label="Automatic mission workspace GC"
            disabled={!loaded() || saving()}
            onClick={() => { if (!loaded()) return; setEnabled(!enabled()); setDirty(true); setNotice(null); }}
          />
        </Row>
        <Row title="Completed retention (days)" desc="Days to keep workspaces for completed missions (1–365).">
          <input
            class="s-input ps-cap-input"
            inputmode="numeric"
            aria-label="Completed retention days"
            value={daysDraft()}
            disabled={!loaded() || saving()}
            onInput={(e) => { setDaysDraft(e.currentTarget.value); setDirty(true); setNotice(null); }}
          />
        </Row>
        <Row title="Stopped / failed retention (days)" desc="Days to keep workspaces for cancelled or failed missions (1–365).">
          <input
            class="s-input ps-cap-input"
            inputmode="numeric"
            aria-label="Stopped retention days"
            value={stoppedDaysDraft()}
            disabled={!loaded() || saving()}
            onInput={(e) => { setStoppedDaysDraft(e.currentTarget.value); setDirty(true); setNotice(null); }}
          />
        </Row>
        <Row title="Clean orphaned directories" desc="Remove leftover per-mission directories with no matching mission record.">
          <Toggle
            on={orphansEnabled()}
            label="Clean orphaned directories"
            disabled={!loaded() || saving()}
            onClick={() => { if (!loaded()) return; setOrphansEnabled(!orphansEnabled()); setDirty(true); setNotice(null); }}
          />
        </Row>
        <Row title="Policy changes" desc={notice() ?? "Changes apply on the next scheduled cleanup sweep."}>
          <button type="button" class="s-btn primary" disabled={!loaded() || saving() || !dirty()} onClick={() => void save()}>
            {saving() ? "Saving…" : "Save"}
          </button>
        </Row>
      </Card>
      <ErrorToast
        error={error()}
        title="Couldn’t save workspace cleanup"
        onDismiss={() => setError(null)}
        action={{ label: "Retry", run: () => (loaded() ? save() : load()) }}
      />
    </Show>
  );
}

function BackupRestoreCard() {
  let fileInput: HTMLInputElement | undefined;
  const [downloading, setDownloading] = createSignal(false);
  const [restoring, setRestoring] = createSignal(false);
  const [pendingArchive, setPendingArchive] = createSignal<{ name: string; bytes: Uint8Array } | null>(null);
  const [error, setError] = createSignal<string | null>(null);
  const [notice, setNotice] = createSignal<string | null>(null);

  const download = async () => {
    if (downloading()) return;
    setDownloading(true);
    setError(null);
    setNotice(null);
    try {
      const saved = await downloadSettingsBackup();
      if (saved) setNotice("Backup archive downloaded.");
    } catch (e) {
      if (!(e instanceof ApprovalCancelled)) {
        setError(e instanceof Error ? e.message : String(e));
      }
    } finally {
      setDownloading(false);
    }
  };

  const onFilePicked = async (file: File | undefined) => {
    if (!file) return;
    setError(null);
    setNotice(null);
    try {
      const bytes = new Uint8Array(await file.arrayBuffer());
      setPendingArchive({ name: file.name, bytes });
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    }
  };

  const confirmRestore = async () => {
    const item = pendingArchive();
    if (!item || restoring()) return;
    setRestoring(true);
    setError(null);
    try {
      const res = await restoreSettingsBackup(item.bytes, item.name);
      setPendingArchive(null);
      const outcome = interpretRestoreResponse(res);
      if (!outcome.ok) {
        setError(outcome.message);
      } else {
        setNotice(outcome.message);
      }
    } catch (e) {
      if (!(e instanceof ApprovalCancelled)) {
        setError(e instanceof Error ? e.message : String(e));
      }
    } finally {
      setRestoring(false);
    }
  };

  return (
    <Show when={isConnected()}>
      <Card title="Backup & restore">
        <Row title="Download backup" desc="Export Core settings, provider configs, and encryption keys as a .zip archive.">
          <button type="button" class="s-btn" disabled={downloading()} onClick={() => void download()}>
            {downloading() ? "Preparing…" : "Download backup"}
          </button>
        </Row>
        <Row title="Restore from backup" desc={notice() ?? "Upload a .zip backup archive to restore Core configuration."}>
          <input
            ref={fileInput}
            type="file"
            accept=".zip,application/zip"
            style={{ display: "none" }}
            onChange={(e) => {
              const f = e.currentTarget.files?.[0];
              e.currentTarget.value = "";
              void onFilePicked(f);
            }}
          />
          <button type="button" class="s-btn" disabled={restoring()} onClick={() => fileInput?.click()}>
            Restore backup…
          </button>
        </Row>
      </Card>
      <Show when={!pendingArchive()}>
        <ErrorToast error={error()} title="Backup operation failed" onDismiss={() => setError(null)} />
      </Show>
      <Show when={pendingArchive()}>
        {(item) => (
          <ConfirmDialog
            title={`Restore ${item().name}?`}
            description="Restoring overwrites Core settings, provider configurations, and keys stored in .sandboxed-sh."
            action="Restore backup"
            destructive
            busy={restoring()}
            error={error()}
            onClose={() => setPendingArchive(null)}
            onConfirm={() => void confirmRestore()}
          />
        )}
      </Show>
    </Show>
  );
}

function LocalAgentsCard() {
  const [busy, setBusy] = createSignal(false);
  const [drafts, setDrafts] = createSignal<Record<string, string>>(pathOverrides());
  const scan = async () => {
    setBusy(true);
    try {
      await refreshLocalAgents(true);
    } finally {
      setBusy(false);
    }
  };
  if (!localInstalled().length) void scan();
  const row = (id: string) => localInstalled().find((item) => item.id === id);
  const save = (id: string) => {
    setPathOverride(id, drafts()[id] ?? "");
    void scan();
  };
  return (
    <Card title="Local agents">
      <Row title="This computer" desc="CLIs Orb can launch here. A blank path uses whatever is on PATH.">
        <button class="s-btn" disabled={busy()} onClick={() => void scan()}>
          {busy() ? "Scanning…" : "Scan"}
        </button>
      </Row>
      <For each={HARNESS_IDS}>
        {(id) => {
          const found = () => row(id);
          return (
            <Row title={harnessName(id)} desc={found()?.installed ? `${found()?.version ?? "installed"} · ${found()?.path}${found()?.auth_error ? ` · ${found()?.auth_error}` : id === "antigravity" ? ` · ${found()?.models?.length ?? 0} account models` : found()?.models?.length ? ` · ${found()!.models!.map(([, label]) => label.replace(/^Claude\s+/, "")).join(", ")}` : ""}` : found()?.auth_error ? [found()?.path, found()?.auth_error].filter(Boolean).join(" · ") : "Not found"}>
              <input
                class="s-input"
                aria-label={`${harnessName(id)} path`}
                placeholder="Path override"
                value={drafts()[id] ?? ""}
                onInput={(e) => setDrafts({ ...drafts(), [id]: e.currentTarget.value })}
                onKeyDown={(e) => e.key === "Enter" && save(id)}
              />
              <button class="s-btn" onClick={() => save(id)}>
                Save
              </button>
            </Row>
          );
        }}
      </For>
    </Card>
  );
}

function BackendTab() {
  const [url, setUrl] = createSignal(getApiUrl());
  const [username, setUsername] = createSignal("");
  const [password, setPassword] = createSignal("");
  const [busy, setBusy] = createSignal(false);
  const [githubBusy, setGithubBusy] = createSignal(false);
  const [error, setError] = createSignal<string | null>(null);
  const [notice, setNotice] = createSignal<string | null>(null);
  const [health, setHealth] = createSignal<ServerHealthInfo | null>(null);
  const [authStatus, setAuthStatus] = createSignal<AuthStatusInfo | null>(null);
  const [passwordDialog, setPasswordDialog] = createSignal(false);
  const [currentPw, setCurrentPw] = createSignal("");
  const [newPw, setNewPw] = createSignal("");
  const [confirmPw, setConfirmPw] = createSignal("");
  const [pwBusy, setPwBusy] = createSignal(false);
  const [pwError, setPwError] = createSignal<string | null>(null);

  createEffect(() => {
    const target = url().trim();
    if (!target) {
      setHealth(null);
      return;
    }
    const ctrl = new AbortController();
    const timer = setTimeout(() => {
      void probeHealth(target, ctrl.signal)
        .then((info) => { if (!ctrl.signal.aborted) setHealth(info); })
        .catch(() => { if (!ctrl.signal.aborted) setHealth(null); });
    }, 250);
    onCleanup(() => {
      clearTimeout(timer);
      ctrl.abort();
    });
  });

  createEffect(on(connectionVersion, () => {
    setAuthStatus(null);
    if (!isConnected()) return;
    const version = connectionVersion();
    void getAuthStatus()
      .then((st) => { if (connectionVersion() === version) setAuthStatus(st); })
      .catch(() => {});
  }));

  onMount(() => {
    if (typeof window === "undefined") return;
    if (!window.location.pathname.endsWith("/auth/callback")) return;
    const pending = loadPendingGitHubOAuthAttempt();
    if (!pending) return;
    const verified = verifyGitHubOAuthCallback(window.location.href, pending);
    window.history.replaceState({}, "", "/");
    if (!verified.ok) {
      setError(verified.error);
      return;
    }
    setGithubBusy(true);
    void verifyIssuedAuthToken(verified.baseUrl, verified.token)
      .then(() => {
        setUrl(verified.baseUrl);
        setConnection(verified.baseUrl, verified.token);
      })
      .catch((e) => setError(e instanceof Error ? e.message : String(e)))
      .finally(() => setGithubBusy(false));
  });

  const isMultiUser = () => health()?.auth_mode === "multi_user";
  const authNotRequired = () => health()?.auth_required === false;
  const canConnect = () => {
    if (busy() || githubBusy()) return false;
    if (authNotRequired()) return true;
    if (!password().trim()) return false;
    if (isMultiUser() && !username().trim()) return false;
    return true;
  };

  const connect = async () => {
    if (!canConnect()) return;
    setApiUrl(url());
    setBusy(true);
    setError(null);
    setNotice(null);
    try {
      if (authNotRequired() && !password().trim()) {
        setConnection(url(), "dev-mode");
      } else {
        await login(password(), isMultiUser() ? username() : undefined);
        setPassword("");
      }
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  };

  const signInGitHub = async () => {
    if (busy() || githubBusy()) return;
    setApiUrl(url());
    setGithubBusy(true);
    setError(null);
    setNotice(null);
    try {
      const h = health();
      await signInWithGitHubDesktop(
        url(),
        h ? h.github_oauth_client_state === true : undefined,
      );
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setGithubBusy(false);
    }
  };

  const requiresCurrentPassword = () => {
    const st = authStatus();
    return Boolean(st && !st.dev_mode && st.password_source !== "none");
  };

  const submitPasswordChange = async () => {
    if (pwBusy()) return;
    if (requiresCurrentPassword() && !currentPw().trim()) {
      setPwError("Enter your current server password.");
      return;
    }
    if (newPw().trim().length < 8) {
      setPwError("New password must be at least 8 characters.");
      return;
    }
    if (newPw() !== confirmPw()) {
      setPwError("New password and confirmation do not match.");
      return;
    }
    setPwBusy(true);
    setPwError(null);
    try {
      await changeServerPassword(requiresCurrentPassword() ? currentPw() : undefined, newPw());
      setPasswordDialog(false);
      setCurrentPw("");
      setNewPw("");
      setConfirmPw("");
      setNotice("Server password updated.");
      void getAuthStatus().then(setAuthStatus).catch(() => {});
    } catch (e) {
      setPwError(e instanceof Error ? e.message : String(e));
    } finally {
      setPwBusy(false);
    }
  };

  return (
    <>
      <Card title="Backend">
        <Row title="API URL" desc="Base URL of the Core backend.">
          <input
            class="s-input"
            value={url()}
            placeholder="https://agent-backend.thomas.md"
            onInput={(e) => setUrl(e.currentTarget.value)}
          />
        </Row>
        <Show when={!isConnected() && isMultiUser()}>
          <Row title="Username" desc="Multi-user account configured on Core.">
            <input
              class="s-input"
              aria-label="Username"
              autocomplete="username"
              value={username()}
              onInput={(e) => setUsername(e.currentTarget.value)}
              onKeyDown={(e) => e.key === "Enter" && void connect()}
            />
          </Row>
        </Show>
        <Show when={!isConnected() && !authNotRequired()}>
          <Row title="Password" desc="Dashboard password. The returned JWT is stored in localStorage.">
            <input
              class="s-input"
              type="password"
              value={password()}
              onInput={(e) => setPassword(e.currentTarget.value)}
              onKeyDown={(e) => e.key === "Enter" && void connect()}
            />
          </Row>
        </Show>
        <Row
          title={isConnected() ? "Connected" : "Not connected"}
          desc={notice() ?? (isConnected() ? `Signed in to ${getApiUrl()}.` : "Connect to enable live Machines, Inference and missions.")}
        >
          <Show
            when={isConnected()}
            fallback={
              <>
                <Show when={health()?.github_enabled}>
                  <button type="button" class="s-btn" disabled={busy() || githubBusy()} onClick={() => void signInGitHub()}>
                    {githubBusy() ? "Signing in…" : "Sign in with GitHub"}
                  </button>
                </Show>
                <button class="s-btn primary" disabled={!canConnect()} onClick={() => void connect()}>
                  {busy() ? "Connecting…" : "Connect"}
                </button>
              </>
            }
          >
            <button class="s-btn" onClick={() => clearConnection()}>
              Disconnect
            </button>
          </Show>
        </Row>
        <Show when={isConnected() && authStatus()?.auth_mode === "single_tenant"}>
          <Row
            title="Server password"
            desc={authStatus()?.password_source === "dashboard" ? "Managed in Core settings." : "Override the environment password with a stored hash."}
          >
            <button
              type="button"
              class="s-btn"
              onClick={() => {
                setCurrentPw("");
                setNewPw("");
                setConfirmPw("");
                setPwError(null);
                setPasswordDialog(true);
              }}
            >
              Change password…
            </button>
          </Row>
        </Show>
      </Card>
      <ErrorToast error={error()} title="Couldn’t connect to the backend" onDismiss={() => setError(null)} />
      <Show when={passwordDialog()}>
        <Dialog
          size="compact"
          title="Change server password"
          description="Updates the single-tenant login password on Core."
          busy={pwBusy()}
          dirty={Boolean(currentPw() || newPw() || confirmPw())}
          onClose={() => setPasswordDialog(false)}
          footer={(close) => (
            <>
              <DialogButton disabled={pwBusy()} onClick={close}>Cancel</DialogButton>
              <DialogButton variant="primary" disabled={pwBusy() || !newPw().trim()} onClick={() => void submitPasswordChange()}>
                {pwBusy() ? "Saving…" : "Update password"}
              </DialogButton>
            </>
          )}
        >
          <Show when={requiresCurrentPassword()}>
            <Field label="Current password">
              <input
                class="s-input"
                type="password"
                autocomplete="current-password"
                value={currentPw()}
                disabled={pwBusy()}
                onInput={(e) => setCurrentPw(e.currentTarget.value)}
              />
            </Field>
          </Show>
          <Field label="New password" description="At least 8 characters.">
            <input
              class="s-input"
              type="password"
              autocomplete="new-password"
              value={newPw()}
              disabled={pwBusy()}
              onInput={(e) => setNewPw(e.currentTarget.value)}
            />
          </Field>
          <Field label="Confirm new password" error={pwError()}>
            <input
              class="s-input"
              type="password"
              autocomplete="new-password"
              value={confirmPw()}
              disabled={pwBusy()}
              onInput={(e) => setConfirmPw(e.currentTarget.value)}
              onKeyDown={(e) => e.key === "Enter" && void submitPasswordChange()}
            />
          </Field>
        </Dialog>
      </Show>
    </>
  );
}

/** Opens ~/.orb/logs in Finder via the native `reveal_logs` command. Desktop only. */
export function ShowLogsButton() {
  const [error, setError] = createSignal<string | null>(null);
  const reveal = async () => {
    const invoke = nativeInvoke();
    if (!invoke) return;
    setError(null);
    try { await invoke("reveal_logs"); } catch (e) { setError(e instanceof Error ? e.message : String(e)); }
  };
  return (
    <Show when={nativeInvoke()}>
      <Row title="Logs" desc={error() ?? "App and performance logs in ~/.orb/logs."}>
        <button class="s-btn" onClick={() => void reveal()}>Show logs</button>
      </Row>
    </Show>
  );
}

function DiagnosticsCard() {
  const [debugMounted, setDebugMounted] = createSignal(false);
  return (
    <section class="s-sec">
      <h3>Diagnostics</h3>
      <Show when={nativeInvoke()}>
        <div class="s-card debug-logs-card">
          <ShowLogsButton />
        </div>
      </Show>
      <details class="s-card debug-disclosure" onToggle={e => { if (e.currentTarget.open) setDebugMounted(true); }}>
        <summary class="s-row">
          <span class="s-row-text"><span class="s-row-title">Debug info</span><span class="s-row-desc">Versions, backend and recent log entries for bug reports.</span></span>
          <Ic.ChevronDown size={14} />
        </summary>
        <Show when={debugMounted()}><DebugInfoPanel /></Show>
      </details>
    </section>
  );
}

/** Account: server connection, connected accounts and appearance. */
export function Settings(p: { onOpenPage?: (id: string) => void } = {}) {
  const [advancedMounted, setAdvancedMounted] = createSignal(false);
  return (
    <div class="s-body settings-body">
      <div class="s-inner">
        <h2>Account</h2>
        <BackendTab />
        <GitHubIntegrationCard />
        <CloudAccountsCard onOpenPage={p.onOpenPage} />
        <Card title="Appearance">
          <Row title="Theme" desc="Auto follows your desktop appearance.">
            <Select
              value={THEME_LABELS[getThemePref()]}
              aria-label="Theme"
              onChange={(e) => setThemePref(THEME_PREFS[e.currentTarget.value])}
            ><option>Auto</option><option>Light</option><option>Dark</option></Select>
          </Row>
          <Row title="Background sync" desc={describeBackgroundSyncStatus(getBackgroundSyncVerdict())}>
            <Select
              value={BG_SYNC_LABELS[getBackgroundSyncMode()]}
              aria-label="Background sync"
              onChange={(e) => setBackgroundSyncMode(BG_SYNC_MODES[e.currentTarget.value] ?? "auto")}
            ><option>Auto</option><option>On</option><option>Off</option></Select>
          </Row>
        </Card>
        <details class="settings-advanced" onToggle={e => { if (e.currentTarget.open) setAdvancedMounted(true); }}>
          <summary>Advanced <Ic.ChevronDown size={14} /></summary>
          <Show when={advancedMounted()}>
            <WorkspaceCleanupCard />
            <BackupRestoreCard />
            <BackgroundSyncCard />
            <DiagnosticsCard />
          </Show>
        </details>
      </div>
    </div>
  );
}

/** Agents → Local agents: CLIs on this computer and concurrency limits. */
export function LocalAgentsSettings() {
  const [executionMounted, setExecutionMounted] = createSignal(false);
  return (
    <div class="s-body settings-body">
      <div class="s-inner">
        <LocalAgentsCard />
        <Show when={isConnected()}>
          <MachineProvidersCard inSettings />
          <section class="s-sec">
            <h3>Concurrency</h3>
            <details class="s-card execution-disclosure" onToggle={e => { if (e.currentTarget.open) setExecutionMounted(true); }}>
              <summary class="s-row">
                <span class="s-row-text"><span class="s-row-title">Concurrency limits</span><span class="s-row-desc">Agent and task limits across all projects.</span></span>
                <Ic.ChevronDown size={14} />
              </summary>
              <Show when={executionMounted()}><ExecutionSettings inline /></Show>
            </details>
          </section>
        </Show>
      </div>
    </div>
  );
}
