import { For, Show, createMemo, createSignal, onMount } from "solid-js";
import {
  type AdminUserRecord,
  createAdminUser,
  currentUser,
  defaultUnixUsernameFor,
  deleteAdminUser,
  isAdminUser,
  listAdminUsers,
  refreshCurrentUser,
  resetAdminUserPassword,
  updateAdminUser,
  validUnixUsername,
} from "./accountAdmin";
import { connectionVersion, isConnected } from "./api";
import { ConfirmDialog, Dialog, DialogButton, Field } from "./Dialog";
import { ErrorNotice } from "./ErrorNotice";
import { formatUsdFromCents, parseUsdToCents } from "./missionSharesApi";
import { SettingsCard, SettingsRow } from "./SettingsCard";

export function UsersSettings() {
  const [users, setUsers] = createSignal<AdminUserRecord[]>([]);
  const [loading, setLoading] = createSignal(true);
  const [error, setError] = createSignal<string | null>(null);
  const [notice, setNotice] = createSignal<string | null>(null);

  const [creating, setCreating] = createSignal(false);
  const [newUsername, setNewUsername] = createSignal("");
  const [newPassword, setNewPassword] = createSignal("");
  const [newRole, setNewRole] = createSignal<"admin" | "member">("member");
  const [newUnix, setNewUnix] = createSignal("");
  const [unixTouched, setUnixTouched] = createSignal(false);
  const [newCapUsd, setNewCapUsd] = createSignal("");
  const [createBusy, setCreateBusy] = createSignal(false);
  const [createError, setCreateError] = createSignal<string | null>(null);

  const [editing, setEditing] = createSignal<AdminUserRecord | null>(null);
  const [editRole, setEditRole] = createSignal<"admin" | "member">("member");
  const [editUnix, setEditUnix] = createSignal("");
  const [editDisabled, setEditDisabled] = createSignal(false);
  const [editCapUsd, setEditCapUsd] = createSignal("");
  const [editBusy, setEditBusy] = createSignal(false);
  const [editError, setEditError] = createSignal<string | null>(null);

  const [resetTarget, setResetTarget] = createSignal<AdminUserRecord | null>(null);
  const [resetPwd, setResetPwd] = createSignal("");
  const [resetConfirm, setResetConfirm] = createSignal("");
  const [resetBusy, setResetBusy] = createSignal(false);
  const [resetError, setResetError] = createSignal<string | null>(null);

  const [deleteTarget, setDeleteTarget] = createSignal<AdminUserRecord | null>(null);
  const [deleteBusy, setDeleteBusy] = createSignal(false);
  const [deleteError, setDeleteError] = createSignal<string | null>(null);

  const activeAdminCount = createMemo(
    () => users().filter((u) => u.role === "admin" && !u.disabled).length,
  );
  const isSoleActiveAdmin = (u: AdminUserRecord) =>
    u.role === "admin" && !u.disabled && activeAdminCount() <= 1;

  const load = async () => {
    if (!isConnected() || !isAdminUser()) {
      setUsers([]);
      setLoading(false);
      return;
    }
    const ver = connectionVersion();
    setLoading(true);
    setError(null);
    try {
      const list = await listAdminUsers();
      if (ver !== connectionVersion()) return;
      setUsers(list);
    } catch (e) {
      if (ver !== connectionVersion()) return;
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      if (ver === connectionVersion()) setLoading(false);
    }
  };

  onMount(() => {
    void load();
  });

  const openCreate = () => {
    setNewUsername("");
    setNewPassword("");
    setNewRole("member");
    setNewUnix("");
    setUnixTouched(false);
    setNewCapUsd("");
    setCreateError(null);
    setCreating(true);
  };

  const onNewUsernameInput = (val: string) => {
    setNewUsername(val);
    if (!unixTouched() && newRole() === "member") {
      setNewUnix(defaultUnixUsernameFor(val));
    }
  };

  const onNewRoleChange = (role: "admin" | "member") => {
    setNewRole(role);
    if (!unixTouched()) {
      setNewUnix(role === "member" ? defaultUnixUsernameFor(newUsername()) : "");
    }
  };

  const createUnixError = createMemo(() => {
    const ux = newUnix().trim();
    if (!ux) return newRole() === "member" ? "Members need a Linux account name for confined node execution." : null;
    return validUnixUsername(ux)
      ? null
      : "Use 1–31 lowercase letters, digits, underscores, or hyphens (not a reserved system account).";
  });

  const submitCreate = async (e?: Event) => {
    e?.preventDefault();
    if (createBusy()) return;
    const uname = newUsername().trim();
    if (!uname) {
      setCreateError("Enter a username.");
      return;
    }
    if (newPassword().length < 8) {
      setCreateError("Password must be at least 8 characters.");
      return;
    }
    if (createUnixError()) {
      setCreateError(createUnixError());
      return;
    }
    const capCents = parseUsdToCents(newCapUsd());
    if (capCents === undefined) {
      setCreateError("Enter a valid daily spend limit in USD (for example 25.00), or leave empty.");
      return;
    }
    setCreateBusy(true);
    setCreateError(null);
    try {
      const created = await createAdminUser({
        username: uname,
        password: newPassword(),
        role: newRole(),
        unix_username: newUnix().trim() || null,
        daily_spend_cap_cents: capCents,
      });
      setUsers((prev) => [...prev.filter((u) => u.id !== created.id), created]);
      setCreating(false);
      setNotice(`Created @${created.username}.`);
      void refreshCurrentUser(true);
    } catch (err) {
      setCreateError(err instanceof Error ? err.message : String(err));
    } finally {
      setCreateBusy(false);
    }
  };

  const openEdit = (u: AdminUserRecord) => {
    setEditing(u);
    setEditRole(u.role === "admin" ? "admin" : "member");
    setEditUnix(u.unix_username ?? "");
    setEditDisabled(Boolean(u.disabled));
    setEditCapUsd(
      u.daily_spend_cap_cents !== null && u.daily_spend_cap_cents !== undefined
        ? (u.daily_spend_cap_cents / 100).toFixed(2)
        : "",
    );
    setEditError(null);
  };

  const editUnixError = createMemo(() => {
    const ux = editUnix().trim();
    if (!ux) return editRole() === "member" ? "Members need a Linux account name for confined node execution." : null;
    return validUnixUsername(ux)
      ? null
      : "Use 1–31 lowercase letters, digits, underscores, or hyphens (not a reserved system account).";
  });

  const submitEdit = async (e?: Event) => {
    e?.preventDefault();
    const target = editing();
    if (!target || editBusy()) return;
    if (editUnixError()) {
      setEditError(editUnixError());
      return;
    }
    const capCents = parseUsdToCents(editCapUsd());
    if (capCents === undefined) {
      setEditError("Enter a valid daily spend limit in USD (for example 25.00), or leave empty.");
      return;
    }
    setEditBusy(true);
    setEditError(null);
    try {
      const updated = await updateAdminUser(target.id, {
        role: editRole(),
        unix_username: editUnix().trim() || null,
        disabled: editDisabled(),
        daily_spend_cap_cents: capCents,
      });
      setUsers((prev) => prev.map((u) => (u.id === updated.id ? updated : u)));
      setEditing(null);
      setNotice(`Updated @${updated.username}.`);
      if (currentUser()?.id === updated.id) void refreshCurrentUser(true);
    } catch (err) {
      setEditError(err instanceof Error ? err.message : String(err));
    } finally {
      setEditBusy(false);
    }
  };

  const submitResetPassword = async (e?: Event) => {
    e?.preventDefault();
    const target = resetTarget();
    if (!target || resetBusy()) return;
    if (resetPwd().length < 8) {
      setResetError("New password must be at least 8 characters.");
      return;
    }
    if (resetPwd() !== resetConfirm()) {
      setResetError("Passwords do not match.");
      return;
    }
    setResetBusy(true);
    setResetError(null);
    try {
      await resetAdminUserPassword(target.id, resetPwd());
      setResetTarget(null);
      setResetPwd("");
      setResetConfirm("");
      setNotice(`Password reset for @${target.username}. Existing sessions were signed out.`);
    } catch (err) {
      setResetError(err instanceof Error ? err.message : String(err));
    } finally {
      setResetBusy(false);
    }
  };

  const submitDelete = async () => {
    const target = deleteTarget();
    if (!target || deleteBusy()) return;
    setDeleteBusy(true);
    setDeleteError(null);
    try {
      await deleteAdminUser(target.id);
      setUsers((prev) => prev.filter((u) => u.id !== target.id));
      setDeleteTarget(null);
      setNotice(`Removed @${target.username}.`);
    } catch (err) {
      setDeleteError(err instanceof Error ? err.message : String(err));
    } finally {
      setDeleteBusy(false);
    }
  };

  return (
    <div class="settings-body">
      <Show when={!isConnected()}>
        <SettingsCard title="Users">
          <SettingsRow
            title="Not connected"
            desc="Connect to an Orb server in Account to manage user accounts."
          />
        </SettingsCard>
      </Show>

      <Show when={isConnected() && !isAdminUser()}>
        <SettingsCard title="Users">
          <SettingsRow
            title="Administrator access required"
            desc="Only administrator accounts can manage server users."
          />
        </SettingsCard>
      </Show>

      <Show when={isConnected() && isAdminUser()}>
        <SettingsCard
          title="Server accounts"
          hint="Missions, workspaces, and projects are private to their owner. Administrators manage accounts, Linux homes, and daily spend caps without access to another user's private work."
        >
          <SettingsRow
            title="Multi-user accounts"
            desc={`${users().length} ${users().length === 1 ? "account" : "accounts"} configured on Core.`}
          >
            <button type="button" class="s-btn" onClick={() => void load()} disabled={loading()}>
              Refresh
            </button>
            <button type="button" class="s-btn primary" onClick={openCreate}>
              Add user…
            </button>
          </SettingsRow>
          <Show when={notice()}>
            <SettingsRow title={notice()!} status />
          </Show>
          <Show when={error()}>
            <SettingsRow
              title="Couldn’t load users"
              desc={error()!}
              status
            >
              <button type="button" class="s-btn" onClick={() => void load()}>
                Retry
              </button>
            </SettingsRow>
          </Show>
        </SettingsCard>

        <SettingsCard title="Accounts">
          <Show
            when={!loading()}
            fallback={
              <div class="s-row" role="status" aria-label="Loading users" aria-busy="true">
                <div class="s-row-text" style={{ width: "100%" }}>
                  <div class="sk-bar" style={{ width: "34%", height: "14px", "margin-bottom": "8px" }} />
                  <div class="sk-bar" style={{ width: "62%", height: "12px" }} />
                </div>
              </div>
            }
          >
            <Show
              when={users().length > 0}
              fallback={<SettingsRow title="No user accounts yet" desc="Create a user account to enable multi-user sign-in." />}
            >
              <For each={users()}>
                {(u) => {
                  const spendDesc = () => {
                    const spent = formatUsdFromCents(u.spent_today_cents);
                    return u.daily_spend_cap_cents !== null && u.daily_spend_cap_cents !== undefined
                      ? `${spent} / ${formatUsdFromCents(u.daily_spend_cap_cents)} today`
                      : `${spent} today · no cap`;
                  };
                  const soleAdmin = () => isSoleActiveAdmin(u);
                  return (
                    <SettingsRow
                      title={
                        <span>
                          <strong>@{u.username}</strong>{" "}
                          <span class="muted">
                            · {u.role === "admin" ? "Admin" : "Member"}
                            {u.disabled ? " · Disabled" : ""}
                            {currentUser()?.id === u.id ? " · You" : ""}
                          </span>
                        </span>
                      }
                      desc={
                        <span>
                          {u.unix_username ? `/home/${u.unix_username}` : "No Linux home assigned"} · {spendDesc()}
                        </span>
                      }
                    >
                      <button type="button" class="s-btn" onClick={() => openEdit(u)}>
                        Edit
                      </button>
                      <button
                        type="button"
                        class="s-btn"
                        onClick={() => {
                          setResetTarget(u);
                          setResetPwd("");
                          setResetConfirm("");
                          setResetError(null);
                        }}
                      >
                        Reset password
                      </button>
                      <button
                        type="button"
                        class="s-btn danger"
                        disabled={soleAdmin() || currentUser()?.id === u.id}
                        title={
                          soleAdmin()
                            ? "At least one active administrator account must remain."
                            : currentUser()?.id === u.id
                              ? "Sign in as another administrator to remove your own account."
                              : undefined
                        }
                        onClick={() => {
                          setDeleteError(null);
                          setDeleteTarget(u);
                        }}
                      >
                        Delete
                      </button>
                    </SettingsRow>
                  );
                }}
              </For>
            </Show>
          </Show>
        </SettingsCard>
      </Show>

      <Show when={creating()}>
        <Dialog
          size="standard"
          title="Add user"
          description="Create an isolated Orb account. Members run remote missions inside their own Linux home directory."
          busy={createBusy()}
          onClose={() => !createBusy() && setCreating(false)}
          footer={(close) => (
            <>
              <DialogButton disabled={createBusy()} onClick={close}>
                Cancel
              </DialogButton>
              <DialogButton
                variant="primary"
                disabled={
                  createBusy() ||
                  !newUsername().trim() ||
                  newPassword().length < 8 ||
                  Boolean(createUnixError())
                }
                onClick={() => void submitCreate()}
              >
                {createBusy() ? "Creating…" : "Create user"}
              </DialogButton>
            </>
          )}
        >
          <form onSubmit={(e) => void submitCreate(e)}>
            <Show when={createError()}>
              <ErrorNotice error={createError()!} />
            </Show>
            <Field label="Username" description="Used when signing in to Orb.">
              <input
                class="s-input"
                autofocus
                placeholder="alice"
                value={newUsername()}
                disabled={createBusy()}
                onInput={(e) => onNewUsernameInput(e.currentTarget.value)}
              />
            </Field>
            <Field label="Initial password" description="At least 8 characters. The user can rotate it in Account.">
              <input
                type="password"
                class="s-input"
                autocomplete="new-password"
                value={newPassword()}
                disabled={createBusy()}
                onInput={(e) => setNewPassword(e.currentTarget.value)}
              />
            </Field>
            <Field
              label="Role"
              description="Members cannot run missions on Core or administer global providers."
            >
              <select
                class="s-input"
                value={newRole()}
                disabled={createBusy()}
                onChange={(e) => onNewRoleChange(e.currentTarget.value === "admin" ? "admin" : "member")}
              >
                <option value="member">Member</option>
                <option value="admin">Admin</option>
              </select>
            </Field>
            <Field
              label="Linux account (unix_username)"
              description={newUnix().trim() ? `Remote node workspaces isolate under /home/${newUnix().trim()}.` : "Optional for admins; required for members."}
              error={newUnix().trim() || newRole() === "member" ? createUnixError() : null}
            >
              <input
                class="s-input"
                placeholder="orb-alice"
                value={newUnix()}
                disabled={createBusy()}
                onInput={(e) => {
                  setUnixTouched(true);
                  setNewUnix(e.currentTarget.value);
                }}
              />
            </Field>
            <Field
              label="Daily spend limit (USD, optional)"
              description="Combined daily cap across proxied model inference and managed cloud VMs. Leave empty for no per-user cap."
            >
              <input
                class="s-input"
                placeholder="25.00"
                value={newCapUsd()}
                disabled={createBusy()}
                onInput={(e) => setNewCapUsd(e.currentTarget.value)}
              />
            </Field>
          </form>
        </Dialog>
      </Show>

      <Show when={editing()} keyed>
        {(target) => {
          const soleAdmin = () => isSoleActiveAdmin(target);
          return (
            <Dialog
              size="standard"
              title={`Edit @${target.username}`}
              description="Changes apply immediately. Disabling an account or demoting an admin revokes active sessions."
              busy={editBusy()}
              onClose={() => !editBusy() && setEditing(null)}
              footer={(close) => (
                <>
                  <DialogButton disabled={editBusy()} onClick={close}>
                    Cancel
                  </DialogButton>
                  <DialogButton
                    variant="primary"
                    disabled={editBusy() || Boolean(editUnixError())}
                    onClick={() => void submitEdit()}
                  >
                    {editBusy() ? "Saving…" : "Save changes"}
                  </DialogButton>
                </>
              )}
            >
              <form onSubmit={(e) => void submitEdit(e)}>
                <Show when={editError()}>
                  <ErrorNotice error={editError()!} />
                </Show>
                <Field
                  label="Role"
                  description={soleAdmin() ? "The last active administrator cannot be demoted." : undefined}
                >
                  <select
                    class="s-input"
                    value={editRole()}
                    disabled={editBusy() || soleAdmin()}
                    onChange={(e) => {
                      const next = e.currentTarget.value === "admin" ? "admin" : "member";
                      setEditRole(next);
                      if (next === "member" && !editUnix().trim()) {
                        setEditUnix(defaultUnixUsernameFor(target.username));
                      }
                    }}
                  >
                    <option value="member">Member</option>
                    <option value="admin">Admin</option>
                  </select>
                </Field>
                <Field
                  label="Linux account (unix_username)"
                  description={editUnix().trim() ? `Remote node workspaces isolate under /home/${editUnix().trim()}.` : "Optional for admins; required for members."}
                  error={editUnixError()}
                >
                  <input
                    class="s-input"
                    placeholder={`orb-${target.username}`}
                    value={editUnix()}
                    disabled={editBusy()}
                    onInput={(e) => setEditUnix(e.currentTarget.value)}
                  />
                </Field>
                <Field
                  label="Daily spend limit (USD, optional)"
                  description="Leave empty to remove the per-user daily cap."
                >
                  <input
                    class="s-input"
                    placeholder="25.00"
                    value={editCapUsd()}
                    disabled={editBusy()}
                    onInput={(e) => setEditCapUsd(e.currentTarget.value)}
                  />
                </Field>
                <Field
                  label="Account status"
                  description={soleAdmin() ? "The last active administrator cannot be disabled." : "Disabled users are signed out immediately."}
                >
                  <select
                    class="s-input"
                    value={editDisabled() ? "disabled" : "active"}
                    disabled={editBusy() || soleAdmin()}
                    onChange={(e) => setEditDisabled(e.currentTarget.value === "disabled")}
                  >
                    <option value="active">Active</option>
                    <option value="disabled">Disabled</option>
                  </select>
                </Field>
              </form>
            </Dialog>
          );
        }}
      </Show>

      <Show when={resetTarget()} keyed>
        {(target) => (
          <Dialog
            size="compact"
            title={`Reset password for @${target.username}`}
            description="Active sessions for this user are revoked immediately."
            busy={resetBusy()}
            onClose={() => !resetBusy() && setResetTarget(null)}
            footer={(close) => (
              <>
                <DialogButton disabled={resetBusy()} onClick={close}>
                  Cancel
                </DialogButton>
                <DialogButton
                  variant="primary"
                  disabled={resetBusy() || resetPwd().length < 8}
                  onClick={() => void submitResetPassword()}
                >
                  {resetBusy() ? "Saving…" : "Reset password"}
                </DialogButton>
              </>
            )}
          >
            <form onSubmit={(e) => void submitResetPassword(e)}>
              <Show when={resetError()}>
                <ErrorNotice error={resetError()!} />
              </Show>
              <Field label="New password">
                <input
                  type="password"
                  class="s-input"
                  autofocus
                  autocomplete="new-password"
                  placeholder="At least 8 characters"
                  value={resetPwd()}
                  disabled={resetBusy()}
                  onInput={(e) => setResetPwd(e.currentTarget.value)}
                />
              </Field>
              <Field label="Confirm new password">
                <input
                  type="password"
                  class="s-input"
                  autocomplete="new-password"
                  value={resetConfirm()}
                  disabled={resetBusy()}
                  onInput={(e) => setResetConfirm(e.currentTarget.value)}
                />
              </Field>
            </form>
          </Dialog>
        )}
      </Show>

      <Show when={deleteTarget()} keyed>
        {(target) => (
          <ConfirmDialog
            destructive
            title={`Delete @${target.username}?`}
            description={`Remove @${target.username} from Core? Existing sessions for this account are revoked immediately.`}
            action="Delete user"
            busy={deleteBusy()}
            error={deleteError()}
            onConfirm={() => void submitDelete()}
            onClose={() => !deleteBusy() && setDeleteTarget(null)}
          />
        )}
      </Show>
    </div>
  );
}
export default UsersSettings;
