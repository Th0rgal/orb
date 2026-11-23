/** Account connection and alternative-router settings as Core reports them.
 * `OrbAccountVpn` on iOS (`OrbProvidersSettings.swift`) and Android (`OrbAccountVpn.kt`)
 * mirrors these functions; all three are checked against
 * `shared/orb-spec/fixtures/account-vpn.json`. Its `requests` cases order the
 * mobile row's reads and writes; `AccountVpnSettings.tsx` gets the same order
 * from its effect cleanup. */
export interface AccountVpnRoute {
  mode: "direct" | "vpn";
  country?: string;
  countries: string[];
  can_configure: boolean;
  saved?: boolean;
  configuration_message?: string;
  status: "direct" | "verified" | "blocked";
  reason?: string;
  server?: string;
  exits?: string[];
  message?: string;
}

export interface AccountVpnView {
  /** Saved country, or "" for Direct. */
  selected: string;
  /** Selectable countries: the saved one first, then Core's imported profiles. */
  countries: string[];
  editable: boolean;
  /** A native account must confirm a Direct route it never chose. */
  confirmDirect: boolean;
  notice: string;
  status: string;
  retry: boolean;
  /** Verification is still running: reread until it settles. */
  poll: boolean;
}

/** A payload that states neither the mode nor the countries confirms nothing,
 * and neither does a VPN route that does not name its country. */
export function accountVpnRoute(payload: unknown): AccountVpnRoute | null {
  const route = payload as AccountVpnRoute | null;
  if (!route || typeof route !== "object" || !Array.isArray(route.countries)) return null;
  if (route.mode === "vpn") return typeof route.country === "string" && route.country ? route : null;
  return route.mode === "direct" ? route : null;
}

export function accountVpnView(route: AccountVpnRoute, nativeAccount: boolean): AccountVpnView {
  // Only a VPN route has a country, an exit or a failure to retry.
  const vpn = route.mode === "vpn";
  const selected = vpn ? route.country ?? "" : "";
  const offered = route.countries.filter(country => typeof country === "string" && country);
  const editable = route.can_configure === true;
  const blocked = vpn && route.status === "blocked";
  const pending = blocked && route.reason === "vpn_awaiting_verification";
  return {
    selected,
    countries: Array.from(new Set([...(selected ? [selected] : []), ...offered])),
    editable,
    confirmDirect: nativeAccount && editable && route.mode === "direct" && route.saved !== true,
    notice: !editable ? route.configuration_message ?? "VPN routing is unavailable for this credential."
      : offered.length ? "" : "Import a named server profile in AirVPN Settings to enable VPN routing.",
    status: vpn && route.status === "verified" ? `Verified exit · ${route.server ?? ""} · ${(route.exits ?? []).join(", ")}`
      : blocked ? route.message ?? "The VPN route is unavailable." : "",
    retry: blocked && !pending,
    poll: pending,
  };
}

export function accountVpnWrite(country: string) {
  return country ? { mode: "vpn", country } : { mode: "direct" };
}

/** Core answers an unknown endpoint with its own path; a missing account does not. */
export function missingAccountSetting(status: number, body: string, path: string): boolean {
  if (status !== 404) return false;
  try {
    const parsed = JSON.parse(body);
    return parsed?.error === "not_found" && parsed.path === path;
  } catch {
    return false;
  }
}

export function alternativeRouterAccess(payload: unknown): boolean | null {
  const allowed = (payload as { allowed?: unknown } | null)?.allowed;
  return typeof allowed === "boolean" ? allowed : null;
}
