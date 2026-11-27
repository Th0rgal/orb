import { For, Show, createEffect, createMemo, createResource, createSignal, onCleanup } from "solid-js";
import * as apiMod from "./api";
import { AccountSettingReadError } from "./AccountSettingReadError";
import { accountVpnRoute, accountVpnView, accountVpnWrite, type AccountVpnRoute } from "./accountVpn";
import {
  airVpnSessionSummary,
  parseAirVpnFilenameHint,
  parseAirVpnStatus,
  type AirVpnProfileView,
} from "./airVpnModel";
import { ConfirmDialog, Dialog, DialogButton, Field } from "./Dialog";
import { pollWhileVisible } from "./poll";
import { Select } from "./Select";
import { SettingsCard, SettingsRow } from "./SettingsCard";

const SETTINGS_PATH = "/api/settings/airvpn";

export function AirVpnSettings(p: { onOpenPage?: (id: string) => void } = {}) {
  return (
    <Show when={String(apiMod.connectionVersion())} keyed>
      {(_connection) => <AirVpnPageInner onOpenPage={p.onOpenPage} />}
    </Show>
  );
}

function AirVpnPageInner(p: { onOpenPage?: (id: string) => void }) {
  const isAdmin = () => (typeof apiMod.isAdminUser === "function" ? apiMod.isAdminUser() : true);
  const connected = () => (typeof apiMod.isConnected === "function" ? apiMod.isConnected() : true);
  const [routesRevision, setRoutesRevision] = createSignal(0);

  return (
    <div class="s-body settings-body">
      <div class="s-inner">
        <Show
          when={connected()}
          fallback={<p class="s-lead">Connect to Core on the Account page to manage AirVPN routing.</p>}
        >
          <Show when={isAdmin()}>
            <AdminAirVpnPanels onMutated={() => setRoutesRevision((v) => v + 1)} />
          </Show>
          <Show when={typeof apiMod.listProviders === "function"}>
            <AccountRoutesCard onOpenPage={p.onOpenPage} refreshKey={routesRevision()} />
          </Show>
        </Show>
      </div>
    </div>
  );
}

function AdminAirVpnPanels(p: { onMutated?: () => void }) {
  const [status, { refetch }] = createResource(async () => {
    const parsed = parseAirVpnStatus(await apiMod.api<unknown>(SETTINGS_PATH));
    if (!parsed) throw new Error("AirVPN settings are unavailable.");
    return parsed;
  });

  const [saving, setSaving] = createSignal(false);
  const [checking, setChecking] = createSignal(false);
  const [activeSessions, setActiveSessions] = createSignal<number | null>(null);
  const [message, setMessage] = createSignal("");

  // API Key modal state
  const [keyDialogOpen, setKeyDialogOpen] = createSignal(false);
  const [keyDraft, setKeyDraft] = createSignal("");
  const [keyError, setKeyError] = createSignal<string | null>(null);

  // Import / Replace WireGuard profile modal state
  const [profileDialogOpen, setProfileDialogOpen] = createSignal(false);
  const [replacingDevice, setReplacingDevice] = createSignal<string | null>(null);
  const [deviceDraft, setDeviceDraft] = createSignal("");
  const [countryDraft, setCountryDraft] = createSignal("");
  const [serverDraft, setServerDraft] = createSignal("");
  const [profileText, setProfileText] = createSignal("");
  const [profileError, setProfileError] = createSignal<string | null>(null);
  let fileInput: HTMLInputElement | undefined;

  // Remove profile confirmation modal state
  const [deletingDevice, setDeletingDevice] = createSignal<string | null>(null);
  const [deleteError, setDeleteError] = createSignal<string | null>(null);

  const openKeyDialog = () => {
    setKeyDraft("");
    setKeyError(null);
    setKeyDialogOpen(true);
  };

  const openProfileDialog = (existing?: AirVpnProfileView) => {
    setReplacingDevice(existing?.device ?? null);
    setDeviceDraft(existing?.device ?? "");
    setCountryDraft(existing?.country ?? "");
    setServerDraft(existing?.server ?? "");
    setProfileText("");
    setProfileError(null);
    if (fileInput) fileInput.value = "";
    setProfileDialogOpen(true);
  };

  async function onPickProfileFile(e: Event & { currentTarget: HTMLInputElement }) {
    const file = e.currentTarget.files?.[0];
    setProfileError(null);
    if (!file) {
      setProfileText("");
      return;
    }
    if (file.size > 30_000) {
      setProfileText("");
      setProfileError("Choose a WireGuard profile under 30 KB.");
      return;
    }
    const hint = parseAirVpnFilenameHint(file.name);
    if (!countryDraft().trim() && hint.country) setCountryDraft(hint.country);
    if (!serverDraft().trim() && hint.server) setServerDraft(hint.server);
    if (!replacingDevice() && !deviceDraft().trim() && hint.device) setDeviceDraft(hint.device);
    setProfileText(await file.text());
  }

  async function saveApiKey() {
    if (saving()) return;
    const clean = keyDraft().trim();
    if (!clean || clean.length > 512 || /\s/.test(clean)) {
      setKeyError("Enter a valid AirVPN API key without spaces.");
      return;
    }
    const version = apiMod.connectionVersion();
    setSaving(true);
    setKeyError(null);
    setMessage("");
    try {
      await apiMod.api(SETTINGS_PATH, {
        method: "PUT",
        body: JSON.stringify({ api_key: clean }),
      });
      if (apiMod.connectionVersion() !== version) return;
      setKeyDraft("");
      setKeyDialogOpen(false);
      await refetch();
      p.onMutated?.();
      setSaving(false);
      setMessage("API key saved.");
    } catch (e) {
      if (apiMod.connectionVersion() === version) {
        setKeyError(e instanceof Error ? e.message : String(e));
      }
    } finally {
      setSaving(false);
    }
  }

  async function saveProfile() {
    if (saving()) return;
    const dev = deviceDraft().trim();
    const cc = countryDraft().trim().toUpperCase();
    const srv = serverDraft().trim();
    const conf = profileText();
    if (!/^[a-z0-9-]{1,64}$/.test(dev)) {
      setProfileError("Device name must use lowercase letters, digits, or hyphens (e.g. orb-ch).");
      return;
    }
    if (!/^[A-Z]{2}$/.test(cc)) {
      setProfileError("Enter a two-letter ISO country code (e.g. NL, CH, FR).");
      return;
    }
    if (!/^[A-Za-z0-9-]{1,64}$/.test(srv)) {
      setProfileError("Enter the AirVPN server name (letters, digits, or hyphens).");
      return;
    }
    if (!conf) {
      setProfileError("Choose a downloaded WireGuard .conf file.");
      return;
    }
    const version = apiMod.connectionVersion();
    setSaving(true);
    setProfileError(null);
    setMessage("");
    try {
      await apiMod.api(SETTINGS_PATH, {
        method: "PUT",
        body: JSON.stringify({
          device_id: dev,
          country: cc,
          server: srv,
          profile: conf,
        }),
      });
      if (apiMod.connectionVersion() !== version) return;
      setProfileText("");
      if (fileInput) fileInput.value = "";
      setProfileDialogOpen(false);
      await refetch();
      p.onMutated?.();
      setSaving(false);
      setMessage("Device profile saved.");
    } catch (e) {
      if (apiMod.connectionVersion() === version) {
        setProfileError(e instanceof Error ? e.message : String(e));
      }
    } finally {
      setSaving(false);
    }
  }

  async function confirmDeleteDevice() {
    const dev = deletingDevice();
    if (!dev || saving()) return;
    const version = apiMod.connectionVersion();
    setSaving(true);
    setDeleteError(null);
    setMessage("");
    try {
      await apiMod.api(SETTINGS_PATH, {
        method: "DELETE",
        body: JSON.stringify({ device_id: dev }),
      });
      if (apiMod.connectionVersion() !== version) return;
      setDeletingDevice(null);
      await refetch();
      p.onMutated?.();
      setSaving(false);
      setMessage(`Removed profile ${dev}.`);
    } catch (e) {
      if (apiMod.connectionVersion() === version) {
        setDeleteError(e instanceof Error ? e.message : String(e));
      }
    } finally {
      setSaving(false);
    }
  }

  async function checkSessions() {
    if (saving() || checking()) return;
    const version = apiMod.connectionVersion();
    setChecking(true);
    setMessage("");
    try {
      const result = await apiMod.api<{ active_sessions: number }>(SETTINGS_PATH, { method: "POST" });
      if (apiMod.connectionVersion() !== version) return;
      const count = typeof result.active_sessions === "number" ? result.active_sessions : Number(result.active_sessions ?? 0);
      setActiveSessions(count);
      await refetch();
      setChecking(false);
      setMessage(`AirVPN reports ${count} active session${count === 1 ? "" : "s"}.`);
    } catch (e) {
      if (apiMod.connectionVersion() === version) {
        setMessage(e instanceof Error ? e.message : String(e));
      }
    } finally {
      setChecking(false);
    }
  }

  const profileTitle = (prof: AirVpnProfileView) =>
    prof.country && prof.server ? `${prof.country} · ${prof.server}` : prof.country ? `${prof.country} · ${prof.device}` : prof.device;

  const profileDetail = (prof: AirVpnProfileView) => {
    if (prof.active) {
      const exits = prof.exits.length ? ` · ${prof.exits.join(", ")}` : "";
      return `Active${exits} · ${prof.accounts} account${prof.accounts === 1 ? "" : "s"}`;
    }
    if (prof.country && prof.server) return "Idle";
    return "Imported · Re-import with country & server metadata if needed";
  };

  return (
    <>
      <Show
        when={!status.error}
        fallback={
          <SettingsCard title="AirVPN">
            <SettingsRow title="Couldn’t load AirVPN settings" desc={status.error instanceof Error ? status.error.message : String(status.error)}>
              <button class="s-btn" onClick={() => void refetch()}>Retry</button>
            </SettingsRow>
          </SettingsCard>
        }
      >
        <SettingsCard
          title="Subscription & sessions"
          hint="AirVPN allows up to 5 concurrent WireGuard sessions across Orb and external devices."
        >
          <SettingsRow
            title="API key"
            desc={
              status()?.apiKeyConfigured
                ? "Configured · Stored encrypted on Core"
                : "Generate a key in AirVPN’s Client Area → API so Orb can check active sessions."
            }
          >
            <Show when={status()?.apiKeyConfigured}>
              <button class="s-btn" disabled={saving() || checking()} onClick={() => void checkSessions()}>
                {checking() ? "Checking…" : "Test saved key"}
              </button>
            </Show>
            <button class="s-btn" disabled={saving()} onClick={openKeyDialog}>
              {status()?.apiKeyConfigured ? "Update key…" : "Set API key…"}
            </button>
          </SettingsRow>
          <SettingsRow
            title="Session budget"
            desc={airVpnSessionSummary(
              activeSessions(),
              status()?.activeTunnels.length ?? 0,
              status()?.sessionLimit ?? 5,
            )}
            status
          >
            <button
              class="s-btn"
              disabled={saving() || checking() || !status()?.apiKeyConfigured}
              onClick={() => void checkSessions()}
            >
              {checking() ? "Checking…" : "Check sessions"}
            </button>
          </SettingsRow>
          <Show when={message()}>
            <SettingsRow title={<span role="status">{message()}</span>} />
          </Show>
        </SettingsCard>

        <SettingsCard
          title="WireGuard profiles"
          hint="Accounts in different provider categories share one tunnel per country. Import additional profiles in the same country only when multiple accounts of the same provider need distinct public exits."
        >
          <SettingsRow
            title={
              status()?.profiles.length
                ? `${status()!.profiles.length} imported profile${status()!.profiles.length === 1 ? "" : "s"}`
                : "No profiles imported"
            }
            desc="In AirVPN’s Config Generator, choose Linux, WireGuard, one dedicated Orb device, and one named server."
          >
            <button class="s-btn" disabled={saving()} onClick={() => openProfileDialog()}>
              Import profile…
            </button>
          </SettingsRow>
          <For each={status()?.profiles ?? []}>
            {(prof) => (
              <SettingsRow
                title={profileTitle(prof)}
                desc={
                  <>
                    <code>{prof.device}</code> · {profileDetail(prof)}
                  </>
                }
              >
                <button class="s-btn" disabled={saving()} onClick={() => openProfileDialog(prof)}>
                  Replace…
                </button>
                <button class="s-btn" disabled={saving()} onClick={() => { setDeleteError(null); setDeletingDevice(prof.device); }}>
                  Remove
                </button>
              </SettingsRow>
            )}
          </For>
        </SettingsCard>
      </Show>

      <Show when={keyDialogOpen()}>
        <Dialog
          size="compact"
          title={status()?.apiKeyConfigured ? "Update API key" : "Set API key"}
          description="Generate a key in AirVPN’s Client Area → API. Core encrypts it at rest and never returns it."
          busy={saving()}
          dirty={keyDraft().length > 0}
          onClose={() => { setKeyDraft(""); setKeyError(null); setKeyDialogOpen(false); }}
          footer={(requestClose) => (
            <>
              <DialogButton disabled={saving()} onClick={requestClose}>Cancel</DialogButton>
              <DialogButton
                variant="primary"
                disabled={saving() || !keyDraft().trim()}
                onClick={() => void saveApiKey()}
              >
                {saving() ? "Saving…" : "Save key"}
              </DialogButton>
            </>
          )}
        >
          <form onSubmit={(e) => { e.preventDefault(); void saveApiKey(); }}>
            <Field label="AirVPN API key" error={keyError()}>
              <input
                class="s-input"
                type="password"
                autocomplete="new-password"
                maxlength={512}
                value={keyDraft()}
                disabled={saving()}
                onInput={(e) => { setKeyDraft(e.currentTarget.value); setKeyError(null); }}
              />
            </Field>
          </form>
        </Dialog>
      </Show>

      <Show when={profileDialogOpen()}>
        <Dialog
          size="standard"
          title={replacingDevice() ? `Replace ${replacingDevice()}` : "Import device config"}
          description="Export a single-server WireGuard .conf file from AirVPN’s Config Generator. Selecting the file pre-fills the country and server when named by AirVPN."
          busy={saving()}
          dirty={Boolean(profileText() || (!replacingDevice() && (deviceDraft() || countryDraft() || serverDraft())))}
          onClose={() => {
            setProfileText("");
            if (fileInput) fileInput.value = "";
            setProfileError(null);
            setProfileDialogOpen(false);
          }}
          footer={(requestClose) => (
            <>
              <DialogButton disabled={saving()} onClick={requestClose}>Cancel</DialogButton>
              <DialogButton
                variant="primary"
                disabled={saving()}
                onClick={() => void saveProfile()}
              >
                {saving() ? "Importing…" : "Import profile"}
              </DialogButton>
            </>
          )}
        >
          <form
            style={{ display: "flex", "flex-direction": "column", gap: "12px" }}
            onSubmit={(e) => { e.preventDefault(); void saveProfile(); }}
          >
            <Field
              label="WireGuard profile"
              description="Single-interface, single-peer WireGuard .conf file under 30 KB."
            >
              <input
                ref={(el) => { fileInput = el; }}
                type="file"
                aria-label="WireGuard profile"
                accept=".conf"
                disabled={saving()}
                onChange={(e) => void onPickProfileFile(e)}
              />
            </Field>
            <Field
              label="Server country code"
              description="Two-letter ISO country code (e.g. NL, CH, FR, DE)."
            >
              <input
                class="s-input"
                aria-label="Server country code"
                placeholder="CH"
                maxlength={2}
                value={countryDraft()}
                disabled={saving()}
                onInput={(e) => { setCountryDraft(e.currentTarget.value.toUpperCase()); setProfileError(null); }}
              />
            </Field>
            <Field
              label="AirVPN server name"
              description="Exact server name verified against AirVPN’s session API (e.g. Alcyone, Kitalpha)."
            >
              <input
                class="s-input"
                aria-label="AirVPN server name"
                placeholder="Kitalpha"
                maxlength={64}
                value={serverDraft()}
                disabled={saving()}
                onInput={(e) => { setServerDraft(e.currentTarget.value); setProfileError(null); }}
              />
            </Field>
            <Field
              label="Device name"
              description="Lowercase identifier for this AirVPN device slot (a–z, 0–9, hyphens)."
              error={profileError()}
            >
              <input
                class="s-input"
                aria-label="Device name"
                placeholder="orb-ch"
                maxlength={64}
                value={deviceDraft()}
                disabled={saving() || Boolean(replacingDevice())}
                onInput={(e) => { setDeviceDraft(e.currentTarget.value.toLowerCase()); setProfileError(null); }}
              />
            </Field>
          </form>
        </Dialog>
      </Show>

      <Show when={deletingDevice()}>
        {(dev) => (
          <ConfirmDialog
            title={`Remove ${dev()}?`}
            description="Any active Orb tunnel using this WireGuard device profile will be drained and disconnected immediately."
            action="Remove profile"
            destructive={true}
            busy={saving()}
            error={deleteError()}
            onConfirm={() => void confirmDeleteDevice()}
            onClose={() => { setDeletingDevice(null); setDeleteError(null); }}
          />
        )}
      </Show>
    </>
  );
}

interface ProviderAccountRow {
  id: string;
  name: string;
  provider_type: string;
  has_credentials?: boolean;
}

function AccountRoutesCard(p: { onOpenPage?: (id: string) => void; refreshKey?: number }) {
  const [filterVpnOnly, setFilterVpnOnly] = createSignal(false);
  const [routes, setRoutes] = createSignal<Record<string, AccountVpnRoute>>({});
  const [routeErrors, setRouteErrors] = createSignal<Record<string, unknown>>({});
  const accountVersions = new Map<string, number>();
  const savingAccounts = new Set<string>();
  let mounted = true;
  onCleanup(() => {
    mounted = false;
  });
  const bumpAccountVersion = (id: string) => {
    const next = (accountVersions.get(id) ?? 0) + 1;
    accountVersions.set(id, next);
    return next;
  };
  const applyRoute = (id: string, next: AccountVpnRoute) => {
    setRouteErrors((prev) => {
      if (!(id in prev)) return prev;
      const copy = { ...prev };
      delete copy[id];
      return copy;
    });
    setRoutes((prev) => ({ ...prev, [id]: next }));
  };
  const clearRouteWithError = (id: string, err: unknown) => {
    setRoutes((prev) => {
      if (!(id in prev)) return prev;
      const copy = { ...prev };
      delete copy[id];
      return copy;
    });
    setRouteErrors((prev) => ({ ...prev, [id]: err }));
  };
  const refreshAccount = async (id: string, versionAtStart: number, isAlive: () => boolean) => {
    if (savingAccounts.has(id)) return;
    const gen = accountVersions.get(id) ?? 0;
    try {
      const parsed = accountVpnRoute(
        await apiMod.api<unknown>(`/api/ai/providers/${encodeURIComponent(id)}/vpn`),
      );
      if (!isAlive() || versionAtStart !== apiMod.connectionVersion()) return;
      if (savingAccounts.has(id) || (accountVersions.get(id) ?? 0) !== gen) return;
      if (parsed) applyRoute(id, parsed);
      else clearRouteWithError(id, new Error("Account connection settings are unavailable."));
    } catch (e) {
      if (!isAlive() || versionAtStart !== apiMod.connectionVersion()) return;
      if (savingAccounts.has(id) || (accountVersions.get(id) ?? 0) !== gen) return;
      clearRouteWithError(id, e);
    }
  };
  const [providers] = createResource(async () => {
    const list = await apiMod.listProviders();
    return (list as ProviderAccountRow[]).filter((item) => item.has_credentials !== false);
  });

  createEffect(() => {
    const list = providers() ?? [];
    void p.refreshKey;
    if (!list.length) return;
    let alive = true;
    const version = apiMod.connectionVersion();
    void (async () => {
      // Bounded concurrency so cold opens stay calm and responsive.
      const queue = [...list];
      const workers = Array.from({ length: Math.min(4, queue.length) }, async () => {
        while (queue.length && alive && version === apiMod.connectionVersion()) {
          const item = queue.shift();
          if (!item) break;
          await refreshAccount(item.id, version, () => alive && mounted);
        }
      });
      await Promise.all(workers);
    })();
    onCleanup(() => {
      alive = false;
    });
  });

  const sortedAccounts = createMemo(() => {
    const list = providers() ?? [];
    const map = routes();
    const errs = routeErrors();
    const filtered = filterVpnOnly()
      ? list.filter((a) => map[a.id]?.mode === "vpn" || a.id in errs)
      : list.filter((a) => {
          const r = map[a.id];
          return !r || r.mode === "vpn" || r.can_configure || a.id in errs;
        });
    return [...filtered].sort((a, b) => {
      const aVpn = map[a.id]?.mode === "vpn" ? 0 : 1;
      const bVpn = map[b.id]?.mode === "vpn" ? 0 : 1;
      return aVpn !== bVpn ? aVpn - bVpn : a.name.localeCompare(b.name);
    });
  });

  const vpnCount = createMemo(() => {
    const map = routes();
    return (providers() ?? []).filter((a) => map[a.id]?.mode === "vpn").length;
  });

  const errorCount = createMemo(() => {
    const errs = routeErrors();
    return (providers() ?? []).filter((a) => a.id in errs).length;
  });

  const summaryTitle = () => {
    if (providers.loading) return "Loading provider accounts…";
    const vpns = vpnCount();
    const errs = errorCount();
    if (errs > 0 && vpns === 0) {
      return `Could not confirm ${errs} account route${errs === 1 ? "" : "s"}`;
    }
    const base = `${vpns} account${vpns === 1 ? "" : "s"} routed via AirVPN`;
    return errs > 0 ? `${base} · ${errs} unconfirmed` : base;
  };

  return (
    <SettingsCard
      title="Account routes"
      hint="Choose whether each connected provider account exits directly or through a verified AirVPN country."
    >
      <SettingsRow
        title={summaryTitle()}
        desc="Accounts in the same provider category automatically receive disjoint public exit IPs."
      >
        <Show when={(providers()?.length ?? 0) > 0}>
          <Select
            aria-label="Filter account routes"
            value={filterVpnOnly() ? "vpn" : "all"}
            onChange={(e) => setFilterVpnOnly(e.currentTarget.value === "vpn")}
          >
            <option value="all">All configurable</option>
            <option value="vpn">VPN routed only</option>
          </Select>
        </Show>
        <Show when={p.onOpenPage}>
          <button class="s-btn" onClick={() => p.onOpenPage?.("providers")}>
            Open Providers
          </button>
        </Show>
      </SettingsRow>
      <Show when={!providers.loading && sortedAccounts().length === 0}>
        <SettingsRow
          title={filterVpnOnly() ? "No accounts currently use AirVPN" : "No configurable provider accounts"}
          desc={filterVpnOnly() ? "Switch to All configurable to route an account through AirVPN." : "Connect an account on the Providers page first."}
        />
      </Show>
      <For each={sortedAccounts()}>
        {(account) => (
          <AccountRouteSummaryRow
            account={account}
            route={routes()[account.id]}
            readError={routeErrors()[account.id]}
            onSaveStart={() => {
              savingAccounts.add(account.id);
              bumpAccountVersion(account.id);
            }}
            onSaveEnd={() => {
              savingAccounts.delete(account.id);
            }}
            onUpdated={(next) => {
              bumpAccountVersion(account.id);
              applyRoute(account.id, next);
            }}
            onUnconfirmed={(err) => {
              if (savingAccounts.has(account.id)) return;
              clearRouteWithError(account.id, err);
            }}
            onRetryRead={() => {
              const version = apiMod.connectionVersion();
              void refreshAccount(account.id, version, () => mounted);
            }}
          />
        )}
      </For>
    </SettingsCard>
  );
}

function AccountRouteSummaryRow(p: {
  account: ProviderAccountRow;
  route: AccountVpnRoute | undefined;
  readError?: unknown;
  onSaveStart: () => void;
  onSaveEnd: () => void;
  onUpdated: (route: AccountVpnRoute) => void;
  onUnconfirmed: (err: unknown) => void;
  onRetryRead: () => void;
}) {
  const [busy, setBusy] = createSignal(false);
  const [error, setError] = createSignal("");
  const nativeAccount = () => p.account.provider_type === "antigravity";
  const uri = () => `/api/ai/providers/${encodeURIComponent(p.account.id)}/vpn`;

  createEffect(() => {
    const r = p.route;
    if (busy() || !r) return;
    const pollMs = accountVpnView(r, nativeAccount()).poll ? 5000 : null;
    const version = apiMod.connectionVersion();
    let active = true;
    const stop = pollWhileVisible(
      async () => {
        try {
          const next = accountVpnRoute(await apiMod.api<unknown>(uri()));
          if (!active || busy() || version !== apiMod.connectionVersion()) return;
          if (next) p.onUpdated(next);
          else p.onUnconfirmed(new Error("Account connection settings are unavailable."));
        } catch (e) {
          if (active && !busy() && version === apiMod.connectionVersion()) p.onUnconfirmed(e);
        }
      },
      pollMs,
      `airvpn-page-${p.account.id}`,
    );
    onCleanup(() => {
      active = false;
      stop();
    });
  });

  async function save(country: string) {
    const version = apiMod.connectionVersion();
    setBusy(true);
    setError("");
    p.onSaveStart();
    try {
      const next = accountVpnRoute(
        await apiMod.api<unknown>(uri(), {
          method: "PUT",
          body: JSON.stringify(accountVpnWrite(country)),
        }),
      );
      if (version === apiMod.connectionVersion()) {
        if (next) p.onUpdated({ ...next, saved: true });
        else setError("Account connection settings are unavailable.");
      }
    } catch (e) {
      if (version === apiMod.connectionVersion()) {
        setError(e instanceof Error ? e.message : String(e));
      }
    } finally {
      p.onSaveEnd();
      setBusy(false);
    }
  }

  return (
    <SettingsRow
      title={p.account.name}
      desc={
        <Show
          when={!p.readError}
          fallback={
            <AccountSettingReadError
              error={p.readError}
              path={uri()}
              updateMessage="Update Core to configure account VPNs."
              retryLabel="Retry connection settings"
              retry={() => { setError(""); p.onRetryRead(); }}
            />
          }
        >
          <Show when={p.route} fallback={<span>Checking route…</span>}>
            {(r) => {
              const v = () => accountVpnView(r(), nativeAccount());
              return (
                <>
                  <code>{p.account.provider_type}</code>
                  <Show when={v().status}> · <span role="status">{v().status}</span></Show>
                  <Show when={!v().status && v().notice}> · {v().notice}</Show>
                  <Show when={error()}> · <span role="alert">{error()}</span></Show>
                </>
              );
            }}
          </Show>
        </Show>
      }
    >
      <Show when={!p.readError && p.route}>
        {(r) => {
          const v = () => accountVpnView(r(), nativeAccount());
          return (
            <>
              <Show when={v().confirmDirect}>
                <button class="s-btn" disabled={busy()} onClick={() => void save("")}>
                  Confirm Direct route
                </button>
              </Show>
              <Show when={v().retry}>
                <button class="s-btn" disabled={busy() || !v().editable} onClick={() => void save(v().selected)}>
                  Retry
                </button>
              </Show>
              <Select
                aria-label={`Route for ${p.account.name}`}
                disabled={busy() || !v().editable}
                value={v().selected}
                onChange={(e) => {
                  const selected = e.currentTarget.value;
                  e.currentTarget.value = v().selected;
                  void save(selected);
                }}
              >
                <option value="">Direct</option>
                {v().countries.map((c) => (
                  <option value={c}>AirVPN · {c}</option>
                ))}
              </Select>
            </>
          );
        }}
      </Show>
    </SettingsRow>
  );
}
