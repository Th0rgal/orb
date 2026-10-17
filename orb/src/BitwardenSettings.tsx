import {
  For,
  Show,
  createEffect,
  createMemo,
  createSignal,
  onCleanup,
  onMount,
} from "solid-js";
import { connectionVersion, isConnected } from "./api";
import {
  authenticateBiometric,
  isBiometricCancelled,
  createBitwardenSecret,
  deleteBitwardenSecret,
  getBiometricStatus,
  getBitwardenStatus,
  listBitwardenProjects,
  groupSecrets,
  listAllBitwardenSecrets,
  revealBitwardenSecret,
  updateBitwardenConfig,
  updateBitwardenSecret,
  type BiometricStatus,
  type BitwardenProject,
  type BitwardenSecretSummary,
  type BitwardenSecretWithProject,
  type BitwardenStatus,
} from "./bitwardenApi";
import { SecretAccessPanel } from "./SecretAccessPanel";
import { ApprovalDevicesPanel } from "./ApprovalDevicesPanel";
import { enrolledDeviceId } from "./deviceApproval";
import { copyText } from "./clipboard";
import { ConfirmDialog, Dialog, DialogButton, Field } from "./Dialog";
import { ErrorNotice } from "./ErrorNotice";
import * as Ic from "./icons";
import { Select } from "./Select";
import { ErrorToast } from "./toast";

const UNLOCK_TTL_MS = 5 * 60 * 1000;

function formatRevisionDate(raw?: string): string {
  if (!raw) return "—";
  const ts = Date.parse(raw);
  if (!Number.isFinite(ts)) return raw;
  return new Date(ts).toLocaleString(undefined, {
    month: "short",
    day: "numeric",
    year: "numeric",
    hour: "numeric",
    minute: "2-digit",
  });
}

function relativeDate(raw?: string): string {
  const ts = raw ? Date.parse(raw) : NaN;
  if (!Number.isFinite(ts)) return raw || "—";
  const minutes = Math.round((Date.now() - ts) / 60000);
  if (minutes < 1) return "Just now";
  if (minutes < 60) return `${minutes} min ago`;
  const hours = Math.round(minutes / 60);
  if (hours < 24) return `${hours} h ago`;
  const days = Math.round(hours / 24);
  if (days < 7) return days === 1 ? "Yesterday" : `${days} days ago`;
  const date = new Date(ts);
  return date.toLocaleDateString(undefined, date.getFullYear() === new Date().getFullYear()
    ? { month: "short", day: "numeric" }
    : { month: "short", day: "numeric", year: "numeric" });
}

function sourceLabel(src: string | null | undefined): string {
  switch (src) {
    case "settings":
      return "Machine Account token (Settings)";
    case "environment":
      return "Machine Account token (BWS_ACCESS_TOKEN)";
    case "library":
      return "Machine Account token (Paloma Library)";
    default:
      return "Not configured";
  }
}

export function BitwardenSettings(p: { initialProjectSlug?: string } = {}) {
  const [status, setStatus] = createSignal<BitwardenStatus | null>(null);
  const [bwProjects, setBwProjects] = createSignal<BitwardenProject[]>([]);
  const [selectedProjectId, setSelectedProjectId] = createSignal<string>("");
  const [allSecrets, setAllSecrets] = createSignal<BitwardenSecretWithProject[]>([]);
  // "" shows every project.
  const secrets = createMemo(() =>
    selectedProjectId() ? allSecrets().filter((s) => s.projectId === selectedProjectId()) : allSecrets(),
  );
  const projectCount = (id: string) => allSecrets().filter((s) => s.projectId === id).length;
  const [collapsed, setCollapsed] = createSignal<Record<string, boolean>>({});
  const [revealed, setRevealed] = createSignal<Record<string, string>>({});
  const [revealingIds, setRevealingIds] = createSignal<Record<string, boolean>>({});
  const [copiedId, setCopiedId] = createSignal<string | null>(null);
  const [search, setSearch] = createSignal("");
  const [loading, setLoading] = createSignal(true);
  const [secretsLoading, setSecretsLoading] = createSignal(false);
  const [error, setError] = createSignal<string | null>(null);
  const [toastError, setToastError] = createSignal<string>("");
  const [notice, setNotice] = createSignal<string | null>(null);

  // Biometric unlock session (5-minute window once authenticated via Touch ID)
  const [bioStatus, setBioStatus] = createSignal<BiometricStatus>({
    available: false,
    kind: "none",
    label: "Touch ID",
  });
  const [unlockedUntil, setUnlockedUntil] = createSignal<number>(0);
  const [nowTick, setNowTick] = createSignal<number>(Date.now());
  const [authenticating, setAuthenticating] = createSignal(false);
  let pendingAuth: Promise<boolean> | null = null;

  // Modals: Token configuration, Create/Edit Secret, Delete Secret
  const [tokenModalOpen, setTokenModalOpen] = createSignal(false);
  const [tokenDraft, setTokenDraft] = createSignal("");
  const [serverUrlDraft, setServerUrlDraft] = createSignal("");
  const [savingConfig, setSavingConfig] = createSignal(false);

  const [editorMode, setEditorMode] = createSignal<"create" | "edit" | null>(null);
  const [editingSecret, setEditingSecret] = createSignal<BitwardenSecretSummary | null>(null);
  const [secretKeyDraft, setSecretKeyDraft] = createSignal("");
  const [secretValueDraft, setSecretValueDraft] = createSignal("");
  const [secretNoteDraft, setSecretNoteDraft] = createSignal("");
  const [secretProjectDraft, setSecretProjectDraft] = createSignal("");
  const [secretValueLoading, setSecretValueLoading] = createSignal(false);
  const [showDraftValue, setShowDraftValue] = createSignal(false);
  const [savingSecret, setSavingSecret] = createSignal(false);

  const [deleteTarget, setDeleteTarget] = createSignal<BitwardenSecretSummary | null>(null);
  const [deletingSecret, setDeletingSecret] = createSignal(false);

  const [managing, setManaging] = createSignal(false);
  const isUnlocked = () => unlockedUntil() > nowTick();

  const lockSession = () => {
    setUnlockedUntil(0);
    setRevealed({});
  };

  const requireBiometric = async (reason: string): Promise<boolean> => {
    // An enrolled Mac signs each protected request with Touch ID already.
    if (enrolledDeviceId()) return true;
    if (isUnlocked()) {
      setUnlockedUntil(Date.now() + UNLOCK_TTL_MS);
      setNowTick(Date.now());
      return true;
    }
    // One sheet at a time: a second click while macOS is prompting joins it.
    if (pendingAuth) return pendingAuth;
    setAuthenticating(true);
    pendingAuth = (async () => {
      try {
        await authenticateBiometric(reason);
        const now = Date.now();
        setNowTick(now);
        setUnlockedUntil(now + UNLOCK_TTL_MS);
        return true;
      } catch (e) {
        if (!isBiometricCancelled(e)) setToastError(e instanceof Error ? e.message : String(e));
        return false;
      } finally {
        pendingAuth = null;
        setAuthenticating(false);
      }
    })();
    return pendingAuth;
  };
  const bioLabel = () => bioStatus().label || "Touch ID";
  const remaining = () => {
    const s = Math.max(0, Math.ceil((unlockedUntil() - nowTick()) / 1000));
    return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;
  };

  let copyTimer: ReturnType<typeof setTimeout> | undefined;
  const flashCopied = (tag: string) => {
    setCopiedId(tag);
    clearTimeout(copyTimer);
    copyTimer = setTimeout(() => setCopiedId(null), 1800);
  };

  const loadSecretsForProject = async (_projectId?: string) => {
    if (!isConnected()) return;
    setSecretsLoading(true);
    try {
      setAllSecrets(await listAllBitwardenSecrets());
      setError(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setSecretsLoading(false);
    }
  };

  const refreshAll = async () => {
    if (!isConnected()) {
      setLoading(false);
      return;
    }
    setLoading(true);
    setError(null);
    try {
      const st = await getBitwardenStatus();
      setStatus(st);
      setServerUrlDraft(st.server_url ?? "");

      if (st.configured && st.bws_installed) {
        const bwList = await listBitwardenProjects();
        setBwProjects(bwList);
        if (selectedProjectId() && !bwList.some((x) => x.id === selectedProjectId())) {
          setSelectedProjectId("");
        }
        await loadSecretsForProject();
      } else {
        setBwProjects([]);
        setAllSecrets([]);
      }
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setLoading(false);
    }
  };

  onMount(() => {
    void getBiometricStatus().then(setBioStatus);
    void refreshAll();
    const timer = setInterval(() => {
      const now = Date.now();
      setNowTick(now);
      if (unlockedUntil() > 0 && unlockedUntil() <= now) {
        setUnlockedUntil(0);
        setRevealed({});
      }
      // Every second: the unlocked pill shows a m:ss countdown.
    }, 1000);
    const onVisChange = () => {
      if (document.hidden) lockSession();
    };
    document.addEventListener("visibilitychange", onVisChange);
    onCleanup(() => {
      clearInterval(timer);
      clearTimeout(copyTimer);
      document.removeEventListener("visibilitychange", onVisChange);
      lockSession();
    });
  });

  createEffect(() => {
    connectionVersion();
    if (isConnected()) {
      void refreshAll();
    }
  });

  const currentBwProject = createMemo(() =>
    bwProjects().find((proj) => proj.id === selectedProjectId()),
  );

  const currentProjectName = createMemo(
    () =>
      currentBwProject()?.name ??
      (selectedProjectId() || bwProjects()[0]?.name || "paloma"),
  );

  const filteredSecrets = createMemo(() => {
    const q = search().trim().toLowerCase();
    if (!q) return secrets();
    return secrets().filter(
      (s) =>
        s.key.toLowerCase().includes(q) ||
        s.id.toLowerCase().includes(q) ||
        (s.note && s.note.toLowerCase().includes(q)),
    );
  });

  const handleSelectBwProject = (projectId: string) => {
    setSelectedProjectId(projectId);
    setRevealed({});
  };
  const groupedSecrets = createMemo(() => groupSecrets(filteredSecrets()));
  const toggleGroup = (id: string) => setCollapsed((prev) => ({ ...prev, [id]: !prev[id] }));

  const handleToggleReveal = async (secret: BitwardenSecretSummary) => {
    const existing = revealed()[secret.id];
    if (existing !== undefined) {
      setRevealed((prev) => {
        const next = { ...prev };
        delete next[secret.id];
        return next;
      });
      return;
    }
    if (!(await requireBiometric(`reveal secret ${secret.key}`))) return;
    setRevealingIds((prev) => ({ ...prev, [secret.id]: true }));
    try {
      const detail = await revealBitwardenSecret(secret.id, secret.key);
      setRevealed((prev) => ({ ...prev, [secret.id]: detail.value }));
    } catch (e) {
      setToastError(e instanceof Error ? e.message : String(e));
    } finally {
      setRevealingIds((prev) => ({ ...prev, [secret.id]: false }));
    }
  };

  const handleCopySecretValue = async (secret: BitwardenSecretSummary) => {
    if (!(await requireBiometric(`copy secret ${secret.key}`))) return;
    let val = revealed()[secret.id];
    if (val === undefined) {
      setRevealingIds((prev) => ({ ...prev, [secret.id]: true }));
      try {
        const detail = await revealBitwardenSecret(secret.id, secret.key);
        val = detail.value;
      } catch (e) {
        setToastError(e instanceof Error ? e.message : String(e));
        return;
      } finally {
        setRevealingIds((prev) => ({ ...prev, [secret.id]: false }));
      }
    }
    copyText(val);
    flashCopied(`val:${secret.id}`);
  };

  const handleOpenCreateSecret = async () => {
    if (!(await requireBiometric(`create a new secret in ${currentProjectName()}`))) return;
    setEditingSecret(null);
    setSecretKeyDraft("");
    setSecretValueDraft("");
    setSecretNoteDraft("");
    setSecretProjectDraft(selectedProjectId() || bwProjects()[0]?.id || "");
    setShowDraftValue(false);
    setEditorMode("create");
  };

  const handleOpenEditSecret = async (secret: BitwardenSecretSummary) => {
    if (!(await requireBiometric(`edit secret ${secret.key}`))) return;
    setEditingSecret(secret);
    setSecretKeyDraft(secret.key);
    setSecretNoteDraft(secret.note || "");
    setSecretProjectDraft(secret.projectId || selectedProjectId());
    setShowDraftValue(false);
    const cachedVal = revealed()[secret.id];
    if (cachedVal !== undefined) {
      setSecretValueDraft(cachedVal);
      setSecretValueLoading(false);
      setEditorMode("edit");
      return;
    }
    setSecretValueDraft("");
    setSecretValueLoading(true);
    setEditorMode("edit");
    try {
      const detail = await revealBitwardenSecret(secret.id, secret.key);
      setSecretValueDraft(detail.value);
    } catch (e) {
      setToastError(e instanceof Error ? e.message : String(e));
      setEditorMode(null);
    } finally {
      setSecretValueLoading(false);
    }
  };

  const handleSaveSecret = async () => {
    if (savingSecret() || secretValueLoading()) return;
    const key = secretKeyDraft().trim();
    if (!key) {
      setToastError("Secret name (key) is required.");
      return;
    }
    setSavingSecret(true);
    setToastError("");
    try {
      if (editorMode() === "create") {
        const targetProject = secretProjectDraft() || selectedProjectId();
        const created = await createBitwardenSecret(targetProject, {
          key,
          value: secretValueDraft(),
          note: secretNoteDraft().trim() || undefined,
        });
        setNotice(`Created secret ${created.key}.`);
        setEditorMode(null);
        await loadSecretsForProject(selectedProjectId());
      } else if (editorMode() === "edit" && editingSecret()) {
        const target = editingSecret()!;
        const updated = await updateBitwardenSecret(target.id, {
          key,
          value: secretValueDraft(),
          note: secretNoteDraft(),
          project_id: secretProjectDraft() || selectedProjectId(),
        });
        if (revealed()[target.id] !== undefined) {
          setRevealed((prev) => ({ ...prev, [target.id]: updated.value }));
        }
        setNotice(`Updated secret ${updated.key}.`);
        setEditorMode(null);
        await loadSecretsForProject(selectedProjectId());
      }
    } catch (e) {
      setToastError(e instanceof Error ? e.message : String(e));
    } finally {
      setSavingSecret(false);
    }
  };

  const handleConfirmDelete = async () => {
    const target = deleteTarget();
    if (!target || deletingSecret()) return;
    if (!(await requireBiometric(`delete secret ${target.key}`))) return;
    setDeletingSecret(true);
    try {
      await deleteBitwardenSecret(target.id, target.key);
      setDeleteTarget(null);
      setRevealed((prev) => {
        const next = { ...prev };
        delete next[target.id];
        return next;
      });
      setNotice(`Deleted secret ${target.key}.`);
      await loadSecretsForProject(selectedProjectId());
    } catch (e) {
      setToastError(e instanceof Error ? e.message : String(e));
    } finally {
      setDeletingSecret(false);
    }
  };

  const handleOpenTokenModal = async () => {
    if (status()?.configured) {
      if (!(await requireBiometric("configure Bitwarden Machine Account token"))) return;
    }
    setTokenDraft("");
    setServerUrlDraft(status()?.server_url ?? "");
    setTokenModalOpen(true);
  };

  const handleSaveTokenConfig = async () => {
    if (savingConfig()) return;
    setSavingConfig(true);
    setToastError("");
    try {
      const payload: {
        access_token?: string;
        server_url?: string;
        default_project_id?: string;
      } = {
        server_url: serverUrlDraft().trim(),
        default_project_id: selectedProjectId(),
      };
      if (tokenDraft().trim()) {
        payload.access_token = tokenDraft().trim();
      }
      const next = await updateBitwardenConfig(payload);
      setStatus(next);
      setTokenModalOpen(false);
      setTokenDraft("");
      setNotice("Saved Bitwarden Machine Account configuration.");
      await refreshAll();
    } catch (e) {
      setToastError(e instanceof Error ? e.message : String(e));
    } finally {
      setSavingConfig(false);
    }
  };

  return (
    <div class="s-body settings-body bitwarden-settings-body" aria-label="Bitwarden Secrets settings">
      <div class="s-inner bitwarden-inner">
        <div class="bw-header">
          <div>
            <h2>Secrets</h2>
            <p class="s-lead">
              Project secrets from Bitwarden Secrets Manager, unlocked with {bioStatus().label || "Touch ID"}.
            </p>
          </div>
          <div class="bw-header-actions">
            <Show
              when={isUnlocked()}
              fallback={
                <button
                  class="s-btn primary bw-unlock-btn"
                  disabled={authenticating()}
                  aria-busy={authenticating()}
                  onClick={() => void requireBiometric("unlock Bitwarden project secrets")}
                  title={`Authenticate with ${bioLabel()} to reveal and edit secrets for 5 minutes`}
                >
                  <Ic.LockIcon size={13} />
                  {authenticating() ? `Waiting for ${bioLabel()}…` : `Unlock with ${bioLabel()}`}
                </button>
              }
            >
              <span class="bw-unlocked-pill" role="status">
                <span class="bw-dot online" /> Unlocked · locks in {remaining()}
              </span>
              <button class="s-btn" onClick={lockSession}>
                Lock
              </button>
            </Show>
            <button
              class="s-btn"
              disabled={loading() || secretsLoading()}
              onClick={() => void refreshAll()}
            >
              {loading() || secretsLoading() ? "Refreshing…" : "Refresh"}
            </button>
          </div>
        </div>

        <ErrorToast
          error={toastError()}
          title="Bitwarden Secrets Manager"
          onDismiss={() => setToastError("")}
        />

        <Show when={notice()}>
          <div class="bw-notice" role="status">
            <span>{notice()}</span>
            <button class="bw-notice-close" onClick={() => setNotice(null)} aria-label="Dismiss">
              <Ic.CloseIcon size={12} />
            </button>
          </div>
        </Show>

        <Show when={error()}>
          <ErrorNotice error={error()!} />
        </Show>

        <Show
          when={isConnected()}
          fallback={
            <section class="s-sec">
              <div class="s-card">
                <div class="s-row">
                  <div class="s-row-text">
                    <div class="s-row-title">Not connected to Core</div>
                    <div class="s-row-desc">
                      Connect to the sandboxed.sh backend in Client settings to manage Bitwarden secrets.
                    </div>
                  </div>
                </div>
              </div>
            </section>
          }
        >
          <Show when={status()?.configured && !managing()}>
            <section class="s-sec">
              <div class="s-card">
                <div class="s-row">
                  <div class="s-row-text">
                    <div class="s-row-title">
                      <span class="bw-status-line">
                        <span class={`bw-dot ${status()?.bws_installed ? "online" : "offline"}`} />
                        Bitwarden
                      </span>
                    </div>
                    <div class="s-row-desc">
                      {bwProjects().length} projects · {allSecrets().length} secrets
                    </div>
                  </div>
                  <div class="s-row-ctrl">
                    <button class="s-btn" onClick={() => setManaging(true)}>Manage</button>
                  </div>
                </div>
              </div>
            </section>
          </Show>

          <Show when={!status()?.configured || managing()}>
          <section class="s-sec">
            <div class="bw-section-head">
              <h3>Bitwarden connection</h3>
              <Show when={status()?.configured}>
                <button class="s-btn" onClick={() => setManaging(false)}>Done</button>
              </Show>
            </div>
            <div class="s-card">
              <div class="s-row">
                <div class="s-row-text">
                  <div class="s-row-title">
                    <span class="bw-status-line">
                      <span
                        class={`bw-dot ${
                          status()?.configured && status()?.bws_installed ? "online" : "offline"
                        }`}
                      />
                      <span>
                        {status()?.configured
                          ? "Machine Account Connected"
                          : "Machine Account Not Configured"}
                      </span>
                      <Show when={status()?.bws_version}>
                        <span class="bw-badge">{status()!.bws_version}</span>
                      </Show>
                    </span>
                  </div>
                  <div class="s-row-desc">
                    {sourceLabel(status()?.token_source)}
                    <Show when={status()?.token_hint}>
                      {" · "}
                      <code class="bw-mono">{status()!.token_hint}</code>
                    </Show>
                  </div>
                </div>
                <div class="s-row-ctrl">
                  <button class="s-btn" onClick={() => void handleOpenTokenModal()}>
                    {status()?.configured ? "Update Token" : "Connect Machine Account"}
                  </button>
                </div>
              </div>

            </div>
          </section>
          </Show>

          <Show when={status()?.configured}>
            <SecretAccessPanel
              projects={bwProjects()}
              requireBiometric={requireBiometric}
              onError={(m) => setToastError(m)}
              onSecretsChanged={() => void loadSecretsForProject()}
            />
            <ApprovalDevicesPanel onError={(m) => setToastError(m)} />
          </Show>

          {/* Secrets Table Section */}
          <Show when={status()?.configured}>
            <section class="s-sec">
              <div class="bw-secrets-bar">
                <div class="bw-secrets-title">
                  <h3>Secrets</h3>
                  <span class="bw-count-badge">
                    {filteredSecrets().length}
                    <Show when={search().trim()}> / {secrets().length}</Show>
                  </span>
                </div>
                <div class="bw-project-chips" role="tablist" aria-label="Bitwarden projects">
                  <button
                    role="tab"
                    class={`bw-chip ${selectedProjectId() === "" ? "active" : ""}`}
                    aria-selected={selectedProjectId() === ""}
                    onClick={() => handleSelectBwProject("")}
                  >
                    All <span class="bw-chip-count">{allSecrets().length}</span>
                  </button>
                  <For each={bwProjects()}>
                    {(proj) => (
                      <button
                        role="tab"
                        class={`bw-chip ${selectedProjectId() === proj.id ? "active" : ""}`}
                        aria-selected={selectedProjectId() === proj.id}
                        onClick={() => handleSelectBwProject(proj.id)}
                      >
                        {proj.name} <span class="bw-chip-count">{projectCount(proj.id)}</span>
                      </button>
                    )}
                  </For>
                </div>
                <div class="bw-secrets-tools">
                  <div class="bw-search-wrap">
                    <Ic.SearchIcon size={13} />
                    <input
                      class="s-input bw-search-input"
                      type="search"
                      placeholder="Filter secrets"
                      aria-label="Filter secrets by name, ID, or note"
                      value={search()}
                      onInput={(e) => setSearch(e.currentTarget.value)}
                    />
                  </div>
                  <button
                    class="s-btn primary"
                    onClick={() => void handleOpenCreateSecret()}
                  >
                    <Ic.PlusIcon size={13} /> New secret
                  </button>
                </div>
              </div>

              <div class="s-card bw-secrets-card">
                <div class="bw-table-head">
                  <span>Name</span>
                  <span>Last edited</span>
                  <span />
                </div>

                <Show
                  when={!secretsLoading() || secrets().length > 0}
                  fallback={
                    <div class="bw-empty">
                      <Ic.Spinner size={14} /> Loading secrets from Bitwarden…
                    </div>
                  }
                >
                  <Show
                    when={filteredSecrets().length > 0}
                    fallback={
                      <div class="bw-empty">
                        {search().trim()
                          ? `No secrets matching "${search().trim()}".`
                          : "No secrets in this Bitwarden project yet."}
                      </div>
                    }
                  >
                    <For each={groupedSecrets()}>
                      {(proj) => (
                        <div class="bw-project-group">
                          <Show when={!selectedProjectId()}>
                            <button
                              type="button"
                              class="bw-group-head project"
                              onClick={() => toggleGroup(`p:${proj.projectId}`)}
                            >
                              <Show when={collapsed()[`p:${proj.projectId}`]} fallback={<Ic.ChevronDown size={11} />}>
                                <Ic.ChevronRight size={11} />
                              </Show>
                              <span>{proj.projectName}</span>
                              <span class="bw-count-badge">
                                {proj.groups.reduce((n, g) => n + g.items.length, 0)}
                              </span>
                            </button>
                          </Show>
                          <Show when={!collapsed()[`p:${proj.projectId}`] || !!selectedProjectId()}>
                            <For each={proj.groups}>
                              {(group) => (
                                <>
                                  <button
                                    type="button"
                                    class="bw-group-head"
                                    onClick={() => toggleGroup(`g:${proj.projectId}:${group.prefix}`)}
                                  >
                                    <Show
                                      when={collapsed()[`g:${proj.projectId}:${group.prefix}`]}
                                      fallback={<Ic.ChevronDown size={10} />}
                                    >
                                      <Ic.ChevronRight size={10} />
                                    </Show>
                                    <span>{group.prefix}</span>
                                    <span class="bw-group-count">{group.items.length}</span>
                                  </button>
                                  <Show when={!collapsed()[`g:${proj.projectId}:${group.prefix}`]}>
                    <For each={group.items}>
                      {(secret) => {
                        const isRev = () => revealed()[secret.id] !== undefined;
                        const isBusy = () => Boolean(revealingIds()[secret.id]);
                        return (
                          <div class="bw-secret-row">
                            <div class="bw-secret-main">
                              <div class="bw-secret-key-line">
                                <span class="bw-key-ico">
                                  <Ic.KeyIcon size={13} />
                                </span>
                                <button
                                  type="button"
                                  class="bw-secret-key"
                                  onClick={() => void handleOpenEditSecret(secret)}
                                  title="Edit secret"
                                >
                                  {secret.key}
                                </button>
                              </div>
                              <Show when={secret.note}>
                                <div class="bw-secret-note" title={secret.note}>
                                  {secret.note}
                                </div>
                              </Show>
                              <Show when={isRev()}>
                                <div class="bw-revealed-box">
                                  <code class="bw-revealed-val">{revealed()[secret.id]}</code>
                                </div>
                              </Show>
                            </div>

                            <div
                              class="bw-secret-date"
                              title={formatRevisionDate(secret.revisionDate || secret.creationDate)}
                            >
                              {relativeDate(secret.revisionDate || secret.creationDate)}
                            </div>

                            <div class="bw-secret-actions">
                              <button
                                type="button"
                                class="s-btn bw-act-btn"
                                disabled={isBusy()}
                                onClick={() => void handleToggleReveal(secret)}
                                title={
                                  isRev()
                                    ? "Hide value"
                                    : `Reveal with ${bioStatus().label || "Touch ID"}`
                                }
                              >
                                <Show when={!isUnlocked() && !isRev()}><Ic.LockIcon size={11} /></Show>
                                {isBusy() ? "…" : isRev() ? "Hide" : "Reveal"}
                              </button>
                              <button
                                type="button"
                                class="s-btn bw-act-btn"
                                disabled={isBusy()}
                                onClick={() => void handleCopySecretValue(secret)}
                                title={`Copy secret value (${bioStatus().label || "Touch ID"})`}
                              >
                                <Show when={!isUnlocked() && copiedId() !== `val:${secret.id}`}><Ic.LockIcon size={11} /></Show>
                                {copiedId() === `val:${secret.id}` ? "Copied" : "Copy"}
                              </button>
                              <button
                                type="button"
                                class="s-btn bw-act-btn"
                                onClick={() => void handleOpenEditSecret(secret)}
                                title="Edit secret"
                                aria-label="Edit secret"
                              >
                                <Ic.PencilIcon size={12} />
                              </button>
                              <button
                                type="button"
                                class="s-btn bw-act-btn bw-danger-btn"
                                onClick={() => setDeleteTarget(secret)}
                                title="Delete secret"
                                aria-label="Delete secret"
                              >
                                <Ic.TrashIcon size={12} />
                              </button>
                            </div>
                          </div>
                        );
                      }}
                    </For>
                                  </Show>
                                </>
                              )}
                            </For>
                          </Show>
                        </div>
                      )}
                    </For>
                  </Show>
                </Show>
              </div>
            </section>
          </Show>
        </Show>
      </div>

      {/* Machine Account Token Dialog */}
      <Show when={tokenModalOpen()}>
        <Dialog
          size="standard"
          title="Bitwarden Machine Account"
          description="Provide a Bitwarden Secrets Manager Machine Account access token (BWS_ACCESS_TOKEN) with read/write access to your projects."
          busy={savingConfig()}
          onClose={() => setTokenModalOpen(false)}
          footer={(close) => (
            <>
              <DialogButton disabled={savingConfig()} onClick={close}>
                Cancel
              </DialogButton>
              <DialogButton
                variant="primary"
                disabled={savingConfig()}
                onClick={() => void handleSaveTokenConfig()}
              >
                {savingConfig() ? "Validating…" : "Save Configuration"}
              </DialogButton>
            </>
          )}
        >
          <div class="bw-dialog-form">
            <Field
              label="Machine Account Access Token"
              description={
                status()?.token_hint
                  ? `Current token: ${status()!.token_hint} (${sourceLabel(status()?.token_source)}). Leave blank to keep existing token.`
                  : "Paste your BWS_ACCESS_TOKEN (starts with 0.…)."
              }
            >
              <input
                class="s-input"
                type="password"
                placeholder="0.xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx.…:…"
                value={tokenDraft()}
                onInput={(e) => setTokenDraft(e.currentTarget.value)}
              />
            </Field>
            <Field
              label="Server URL (optional)"
              description="Leave blank for Bitwarden Cloud (vault.bitwarden.com)."
            >
              <input
                class="s-input"
                type="url"
                placeholder="https://vault.bitwarden.com"
                value={serverUrlDraft()}
                onInput={(e) => setServerUrlDraft(e.currentTarget.value)}
              />
            </Field>
          </div>
        </Dialog>
      </Show>

      {/* Create / Edit Secret Dialog */}
      <Show when={editorMode() !== null}>
        <Dialog
          size="standard"
          title={editorMode() === "create" ? "New Secret" : `Edit ${editingSecret()?.key ?? "Secret"}`}
          description={
            editorMode() === "create"
              ? `Create a secret in Bitwarden project "${currentProjectName()}".`
              : `Update secret in Bitwarden project "${currentProjectName()}".`
          }
          busy={savingSecret()}
          onClose={() => setEditorMode(null)}
          footer={(close) => (
            <>
              <DialogButton disabled={savingSecret()} onClick={close}>
                Cancel
              </DialogButton>
              <DialogButton
                variant="primary"
                disabled={savingSecret() || secretValueLoading() || !secretKeyDraft().trim()}
                onClick={() => void handleSaveSecret()}
              >
                {savingSecret()
                  ? "Saving…"
                  : editorMode() === "create"
                    ? "Create Secret"
                    : "Save Changes"}
              </DialogButton>
            </>
          )}
        >
          <div class="bw-dialog-form">
            <Field label="Name (Key)" description="Environment variable or secret identifier (e.g. API_SERVER_KEY).">
              <input
                class="s-input bw-mono"
                autofocus
                placeholder="API_KEY_NAME"
                value={secretKeyDraft()}
                disabled={savingSecret()}
                onInput={(e) => setSecretKeyDraft(e.currentTarget.value)}
              />
            </Field>

            <Field label="Value">
              <Show
                when={!secretValueLoading()}
                fallback={
                  <div class="bw-loading-inline">
                    <Ic.Spinner size={13} /> Decrypting current value from Bitwarden…
                  </div>
                }
              >
                <div class="bw-value-editor">
                  <textarea
                    class={`s-input bw-textarea bw-mono ${showDraftValue() ? "" : "bw-masked-textarea"}`}
                    rows={4}
                    placeholder="Secret value…"
                    value={secretValueDraft()}
                    disabled={savingSecret()}
                    onInput={(e) => setSecretValueDraft(e.currentTarget.value)}
                  />
                  <div class="bw-value-bar">
                    <button
                      type="button"
                      class="s-btn"
                      onClick={() => setShowDraftValue(!showDraftValue())}
                    >
                      {showDraftValue() ? "Mask value" : "Show plaintext"}
                    </button>
                    <button
                      type="button"
                      class="s-btn"
                      onClick={() => {
                        copyText(secretValueDraft());
                        flashCopied("draft-val");
                      }}
                    >
                      {copiedId() === "draft-val" ? "Copied" : "Copy value"}
                    </button>
                  </div>
                </div>
              </Show>
            </Field>

            <Field label="Notes (optional)" description="Internal description or rotation notes.">
              <input
                class="s-input"
                placeholder="Optional note…"
                value={secretNoteDraft()}
                disabled={savingSecret()}
                onInput={(e) => setSecretNoteDraft(e.currentTarget.value)}
              />
            </Field>

            <Show when={bwProjects().length > 1}>
              <Field label="Bitwarden Project">
                <Select
                  value={secretProjectDraft()}
                  aria-label="Bitwarden Project"
                  onChange={(e) => setSecretProjectDraft(e.currentTarget.value)}
                >
                  <For each={bwProjects()}>
                    {(proj) => <option value={proj.id}>{proj.name}</option>}
                  </For>
                </Select>
              </Field>
            </Show>
          </div>
        </Dialog>
      </Show>

      {/* Delete Secret Confirmation */}
      <Show when={deleteTarget()}>
        {(target) => (
          <ConfirmDialog
            title={`Delete ${target().key}?`}
            description={`This will permanently delete "${target().key}" (${target().id}) from Bitwarden project "${currentProjectName()}".`}
            action="Delete Secret"
            destructive={true}
            busy={deletingSecret()}
            onConfirm={() => void handleConfirmDelete()}
            onClose={() => setDeleteTarget(null)}
          />
        )}
      </Show>
    </div>
  );
}
