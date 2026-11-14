import { ApiError, isAdminUser, type AIProvider } from "./api";

/** Admins manage every account; a member manages the shared accounts they added (docs/MULTI_USER.md §5). */
export function canManageProvider(a: AIProvider): boolean {
  return isAdminUser() || a.added_by_me === true;
}

/** A readable sentence for a refused provider write; never the raw `403 {json}` body. */
export function providerWriteError(error: unknown, fallback: string): string {
  const raw = error instanceof ApiError ? error.detail : "";
  const code = (() => { try { return (JSON.parse(raw) as { error?: string }).error; } catch { return undefined; } })();
  switch (code) {
    case "not_account_owner": return "Only the person who added this account, or an admin, can change its credentials or remove it.";
    case "base_url_not_allowed": return "Members can set a base URL only on custom accounts they added, and only to a public https:// address.";
    case "admin_required": return "Only an admin can change this setting.";
    case "account_disabled": return "Your account is disabled.";
    default: return fallback;
  }
}
