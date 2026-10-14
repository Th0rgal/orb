import {
  For,
  Show,
  createEffect,
  createMemo,
  createSignal,
  onCleanup,
  onMount,
} from "solid-js";
import { connectionVersion, isConnected, listProjects, type ProjectSummary } from "./api";
import {
  PALOMA_BITWARDEN_PROJECT_ID,
  authenticateBiometric,
  isBiometricCancelled,
  createBitwardenSecret,
  deleteBitwardenSecret,
  getBiometricStatus,
  getBitwardenStatus,
  listBitwardenProjects,
  listBitwardenSecrets,
  revealBitwardenSecret,
  updateBitwardenConfig,
  updateBitwardenSecret,
  type BiometricStatus,
  type BitwardenProject,
  type BitwardenSecretSummary,
  type BitwardenStatus,
} from "./bitwardenApi";
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
  const [palomaProjects, setPalomaProjects] = createSignal<ProjectSummary[]>([]);
  const [selectedProjectId, setSelectedProjectId] = createSignal<string>(
    PALOMA_BITWARDEN_PROJECT_ID,
  );
  const [secrets, setSecrets] = createSignal<BitwardenSecretSummary[]>([]);
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

  const [bindingPalomaSlug, setBindingPalomaSlug] = createSignal(
    p.initialProjectSlug || "paloma",
  );
  const [savingBinding, setSavingBinding] = createSignal(false);

  const isUnlocked = () => unlockedUntil() > nowTick();

  const lockSession = () => {
    setUnlockedUntil(0);
    setRevealed({});
  };

  const requireBiometric = async (reason: string): Promise<boolean> => {
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

  const loadSecretsForProject = async (projectId: string) => {
    if (!projectId || !isConnected()) return;
    setSecretsLoading(true);
    try {
      const list = await listBitwardenSecrets(projectId);
      setSecrets(list);
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
      const [st, projs] = await Promise.all([
        getBitwardenStatus(),
        listProjects().catch(() => [] as ProjectSummary[]),
      ]);
      setStatus(st);
      setPalomaProjects(projs);
      setServerUrlDraft(st.server_url ?? "");

      if (st.configured && st.bws_installed) {
        const bwList = await listBitwardenProjects();
        setBwProjects(bwList);
        const preferred =
          (p.initialProjectSlug && st.project_bindings?.[p.initialProjectSlug]) ||
          st.default_project_id ||
          bwList.find((x) => x.name.toLowerCase() === "paloma")?.id ||
          bwList[0]?.id ||
          PALOMA_BITWARDEN_PROJECT_ID;
        setSelectedProjectId(preferred);
        await loadSecretsForProject(preferred);
      } else {
        setBwProjects([]);
        setSecrets([]);
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
      (selectedProjectId() === PALOMA_BITWARDEN_PROJECT_ID ? "paloma" : selectedProjectId()),
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

  const handleSelectBwProject = async (projectId: string) => {
    setSelectedProjectId(projectId);
    setRevealed({});
    await loadSecretsForProject(projectId);
  };

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
      const detail = await revealBitwardenSecret(secret.id);
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
        const detail = await revealBitwardenSecret(secret.id);
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
    setSecretProjectDraft(selectedProjectId());
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
      const detail = await revealBitwardenSecret(secret.id);
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
      await deleteBitwardenSecret(target.id);
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

  const handleBindProject = async (palomaSlug: string, bwProjectId: string) => {
    if (savingBinding()) return;
    setSavingBinding(true);
    setToastError("");
    try {
      const currentBindings = { ...(status()?.project_bindings ?? {}) };
      currentBindings[palomaSlug] = bwProjectId;
      const next = await updateBitwardenConfig({
        default_project_id: bwProjectId,
        project_bindings: currentBindings,
      });
      setStatus(next);
      setNotice(
        `Connected Paloma project "${palomaSlug}" to Bitwarden project "${
          bwProjects().find((x) => x.id === bwProjectId)?.name ?? bwProjectId
        }".`,
      );
    } catch (e) {
      setToastError(e instanceof Error ? e.message : String(e));
    } finally {
      setSavingBinding(false);
    }
  };

  const palomaProjectOptions = createMemo(() => {
    const slugs = new Set<string>(["paloma"]);
    if (p.initialProjectSlug) slugs.add(p.initialProjectSlug);
    for (const proj of palomaProjects()) slugs.add(proj.slug);
    for (const k of Object.keys(status()?.project_bindings ?? {})) slugs.add(k);
    return [...slugs];
  });

  return (
    <div class="s-body settings-body bitwarden-settings-body" aria-label="Bitwarden Secrets settings">
      <div class="s-inner bitwarden-inner">
        <div class="bw-header">
          <div>
            <h2>Bitwarden Secrets Manager</h2>
            <p class="s-lead">
              Connect a Bitwarden Machine Account to view and edit project secrets (`paloma`), protected by {bioStatus().label || "Touch ID"}.
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
          {/* Machine Account & Connected Project Card */}
          <section class="s-sec">
            <h3>Machine Account &amp; Project Binding</h3>
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

              <Show when={bwProjects().length > 0}>
                <div class="s-row">
                  <div class="s-row-text">
                    <div class="s-row-title">Bitwarden Project</div>
                    <div class="s-row-desc">
                      Active Bitwarden Secrets Manager project ({secrets().length} secrets) ·{" "}
                      <code class="bw-mono">{selectedProjectId()}</code>
                    </div>
                  </div>
                  <div class="s-row-ctrl">
                    <Select
                      value={selectedProjectId()}
                      aria-label="Bitwarden Project"
                      onChange={(e) => void handleSelectBwProject(e.currentTarget.value)}
                    >
                      <For each={bwProjects()}>
                        {(proj) => <option value={proj.id}>{proj.name}</option>}
                      </For>
                    </Select>
                  </div>
                </div>

                <div class="s-row">
                  <div class="s-row-text">
                    <div class="s-row-title">Connected Paloma Project</div>
                    <div class="s-row-desc">
                      Binds Paloma project{" "}
                      <strong>{bindingPalomaSlug()}</strong> to Bitwarden project{" "}
                      <strong>{currentProjectName()}</strong>.
                    </div>
                  </div>
                  <div class="s-row-ctrl bw-binding-ctrl">
                    <Select
                      value={bindingPalomaSlug()}
                      aria-label="Paloma Project"
                      onChange={(e) => {
                        const slug = e.currentTarget.value;
                        setBindingPalomaSlug(slug);
                        const boundId = status()?.project_bindings?.[slug];
                        if (boundId && bwProjects().some((p) => p.id === boundId)) {
                          void handleSelectBwProject(boundId);
                        }
                      }}
                    >
                      <For each={palomaProjectOptions()}>
                        {(slug) => <option value={slug}>{slug}</option>}
                      </For>
                    </Select>
                    <button
                      class="s-btn primary"
                      disabled={
                        savingBinding() ||
                        status()?.project_bindings?.[bindingPalomaSlug()] === selectedProjectId()
                      }
                      onClick={() => void handleBindProject(bindingPalomaSlug(), selectedProjectId())}
                    >
                      {status()?.project_bindings?.[bindingPalomaSlug()] === selectedProjectId()
                        ? "Connected"
                        : savingBinding()
                          ? "Connecting…"
                          : "Connect Project"}
                    </button>
                  </div>
                </div>
              </Show>
            </div>
          </section>

          {/* Secrets Table Section */}
          <Show when={status()?.configured}>
            <section class="s-sec">
              <div class="bw-secrets-bar">
                <div class="bw-secrets-title">
                  <h3>
                    Secrets in <span class="bw-project-pill">{currentProjectName()}</span>
                  </h3>
                  <span class="bw-count-badge">
                    {filteredSecrets().length}
                    <Show when={search().trim()}> / {secrets().length}</Show>
                  </span>
                </div>
                <div class="bw-secrets-tools">
                  <div class="bw-search-wrap">
                    <Ic.SearchIcon size={13} />
                    <input
                      class="s-input bw-search-input"
                      type="search"
                      placeholder="Filter secrets by name, ID, or note…"
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
                  <span>Project</span>
                  <span>Last edited</span>
                  <span class="bw-col-actions">Actions</span>
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
                    <For each={filteredSecrets()}>
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
                                <Show when={secret.note}>
                                  <span class="bw-secret-note" title={secret.note}>
                                    {secret.note}
                                  </span>
                                </Show>
                              </div>
                              <div class="bw-secret-sub">
                                <code class="bw-secret-id">{secret.id}</code>
                                <button
                                  type="button"
                                  class="bw-mini-copy"
                                  title="Copy secret UUID"
                                  onClick={() => {
                                    copyText(secret.id);
                                    flashCopied(`id:${secret.id}`);
                                  }}
                                >
                                  <Show
                                    when={copiedId() === `id:${secret.id}`}
                                    fallback={<Ic.CopyIcon size={11} />}
                                  >
                                    <Ic.CheckIcon size={11} />
                                  </Show>
                                </button>
                              </div>
                              <Show when={isRev()}>
                                <div class="bw-revealed-box">
                                  <code class="bw-revealed-val">{revealed()[secret.id]}</code>
                                </div>
                              </Show>
                            </div>

                            <div class="bw-secret-proj">
                              <span class="bw-project-pill">{currentProjectName()}</span>
                            </div>

                            <div class="bw-secret-date">
                              {formatRevisionDate(secret.revisionDate || secret.creationDate)}
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
                              >
                                <Ic.PencilIcon size={12} />
                              </button>
                              <button
                                type="button"
                                class="s-btn bw-act-btn bw-danger-btn"
                                onClick={() => setDeleteTarget(secret)}
                                title="Delete secret"
                              >
                                <Ic.TrashIcon size={12} />
                              </button>
                            </div>
                          </div>
                        );
                      }}
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
