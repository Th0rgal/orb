/** Account connection and alternative-router settings as Core reports them.
 * `OrbAccountVpn` on iOS (`OrbProvidersSettings.swift`) and Android (`OrbAccountVpn.kt`)
 * mirrors these functions; all three are checked against
 * `shared/orb-spec/fixtures/account-vpn.json`. */
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

/** A payload that states neither the mode nor the countries confirms nothing. */
export function accountVpnRoute(payload: unknown): AccountVpnRoute | null {
  const route = payload as AccountVpnRoute | null;
  if (!route || typeof route !== "object" || !["vpn", "direct"].includes(route.mode) || !Array.isArray(route.countries)) return null;
  return route;
}

export function accountVpnView(route: AccountVpnRoute, nativeAccount: boolean): AccountVpnView {
  const selected = route.country ?? "";
  const editable = route.can_configure === true;
  const blocked = route.status === "blocked";
  const pending = blocked && route.reason === "vpn_awaiting_verification";
  return {
    selected,
    countries: Array.from(new Set([...(selected ? [selected] : []), ...route.countries])),
    editable,
    confirmDirect: nativeAccount && editable && route.mode === "direct" && route.saved !== true,
    notice: !editable ? route.configuration_message ?? "VPN routing is unavailable for this credential."
      : route.countries.length ? "" : "Import a named server profile in AirVPN Settings to enable VPN routing.",
    status: route.status === "verified" ? `Verified exit · ${route.server ?? ""} · ${(route.exits ?? []).join(", ")}`
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
