import { ApiError, isAdminUser, type AIProvider } from "./api";

/** Admins manage every account; a member manages the shared accounts they added (docs/MULTI_USER.md §5). */
export function canManageProvider(a: AIProvider): boolean {
  return isAdminUser() || a.added_by_me === true;
}

/** Matches Core's `memberProviderBaseUrlAllowed` (`lean/OrbCore/OrbCore/Control.lean`). */
export function isMemberCustomBaseUrlAllowed(url: string): boolean {
  const u = url.trim().toLowerCase();
  if (!u.startsWith("https://")) return false;
  const rest = u.slice("https://".length);
  const hostPort = rest.split("/")[0] ?? "";
  const host = hostPort.startsWith("[") ? hostPort : (hostPort.split(":")[0] ?? "");
  if (
    !host ||
    host.startsWith("[") ||
    host === "localhost" ||
    host.endsWith(".localhost") ||
    host.endsWith(".internal") ||
    host.endsWith(".local") ||
    host.startsWith("127.") ||
    host.startsWith("10.") ||
    host.startsWith("192.168.") ||
    host.startsWith("169.254.") ||
    host.startsWith("0.")
  ) {
    return false;
  }
  if (host.startsWith("172.")) {
    const second = host.split(".")[1] ?? "";
    if (/^\d+$/.test(second)) {
      const n = Number(second);
      if (n >= 16 && n <= 31) return false;
    }
  }
  if (/^[0-9.]+$/.test(host) && host.startsWith("100.")) return false;
  return true;
}

export function isCustomBaseUrlAllowed(url: string, admin = isAdminUser()): boolean {
  return admin ? /^https?:\/\//i.test(url.trim()) : isMemberCustomBaseUrlAllowed(url);
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
