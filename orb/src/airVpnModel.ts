/** Shared AirVPN settings model mirrored on iOS (`OrbAirVpnModel` in
 * `OrbAdminSettings.swift`) and Android (`OrbAirVpnModel` in `OrbAdminSettings.kt`),
 * tested against `shared/orb-spec/fixtures/airvpn-settings.json`. */

export interface AirVpnTunnelSummary {
  device: string;
  country: string;
  server: string;
  exits: string[];
  accounts: number;
}

export interface AirVpnProfileView {
  device: string;
  country: string;
  server: string;
  active: boolean;
  exits: string[];
  accounts: number;
}

export interface AirVpnStatusView {
  apiKeyConfigured: boolean;
  sessionLimit: number;
  profiles: AirVpnProfileView[];
  activeTunnels: AirVpnTunnelSummary[];
}

export interface AirVpnFilenameHint {
  country: string;
  server: string;
  device: string;
}

function asInt(value: unknown, fallback: number): number {
  if (typeof value === "number" && Number.isFinite(value)) return Math.max(0, Math.trunc(value));
  if (typeof value === "string" && /^\d+$/.test(value)) return Number.parseInt(value, 10);
  return fallback;
}

/** Normalize both legacy (`devices` only) and enriched (`profiles` + `active_tunnels`)
 * `/api/settings/airvpn` payloads without ever retaining secret material. */
export function parseAirVpnStatus(payload: unknown): AirVpnStatusView | null {
  const raw = payload as Record<string, unknown> | null;
  if (!raw || typeof raw !== "object" || typeof raw.api_key_configured !== "boolean" || !Array.isArray(raw.devices)) {
    return null;
  }
  const devices = raw.devices.filter((d): d is string => typeof d === "string" && d.length > 0);
  const sessionLimit = Math.max(1, asInt(raw.session_limit, 5));

  const activeTunnels: AirVpnTunnelSummary[] = Array.isArray(raw.active_tunnels)
    ? raw.active_tunnels.flatMap((item): AirVpnTunnelSummary[] => {
        if (!item || typeof item !== "object") return [];
        const t = item as Record<string, unknown>;
        if (typeof t.device !== "string" || !t.device) return [];
        return [{
          device: t.device,
          country: typeof t.country === "string" ? t.country : "",
          server: typeof t.server === "string" ? t.server : "",
          exits: Array.isArray(t.exits) ? t.exits.filter((ip): ip is string => typeof ip === "string" && ip.length > 0) : [],
          accounts: asInt(t.accounts, 0),
        }];
      })
    : [];

  const tunnelByDevice = new Map<string, AirVpnTunnelSummary>();
  for (const t of activeTunnels) tunnelByDevice.set(t.device, t);

  const metaByDevice = new Map<string, { country: string; server: string }>();
  if (Array.isArray(raw.profiles)) {
    for (const item of raw.profiles) {
      if (!item || typeof item !== "object") continue;
      const p = item as Record<string, unknown>;
      if (typeof p.device !== "string" || !p.device) continue;
      metaByDevice.set(p.device, {
        country: typeof p.country === "string" ? p.country : "",
        server: typeof p.server === "string" ? p.server : "",
      });
      if (!devices.includes(p.device)) devices.push(p.device);
    }
  }

  const profiles: AirVpnProfileView[] = devices.map((device) => {
    const meta = metaByDevice.get(device);
    const live = tunnelByDevice.get(device);
    return {
      device,
      country: meta?.country || live?.country || "",
      server: meta?.server || live?.server || "",
      active: Boolean(live),
      exits: live?.exits ?? [],
      accounts: live?.accounts ?? 0,
    };
  });

  return {
    apiKeyConfigured: raw.api_key_configured,
    sessionLimit,
    profiles,
    activeTunnels,
  };
}

/** Extract country, server and suggested Orb device slug from an AirVPN Config Generator filename. */
export function parseAirVpnFilenameHint(filename: string): AirVpnFilenameHint {
  const base = filename.split(/[\\/]/).pop()?.replace(/\.conf$/i, "").trim() ?? "";
  if (!base) return { country: "", server: "", device: "" };

  const airMatch = /^AirVPN_([A-Za-z]{2})(?:-[A-Za-z0-9-]+)?_([A-Za-z0-9-]+?)(?:_(?:UDP|TCP|Entry|TLS|IPv4|IPv6).*)?$/i.exec(base);
  if (airMatch) {
    const country = airMatch[1].toUpperCase();
    const server = airMatch[2];
    const slug = `orb-${country.toLowerCase()}-${server.toLowerCase()}`.replace(/[^a-z0-9-]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 64);
    return { country, server, device: slug };
  }

  if (/^[A-Za-z0-9-]{1,56}$/.test(base)) {
    const slug = `orb-${base.toLowerCase()}`.replace(/[^a-z0-9-]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 64);
    return { country: "", server: base, device: slug };
  }

  return { country: "", server: "", device: "" };
}

/** Format the AirVPN concurrent-session budget across Orb tunnels and external sessions. */
export function airVpnSessionSummary(
  activeSessions: number | null | undefined,
  orbTunnels: number,
  sessionLimit = 5,
): string {
  const limit = sessionLimit > 0 ? Math.trunc(sessionLimit) : 5;
  const orb = Math.max(0, Math.trunc(orbTunnels));
  if (activeSessions == null) {
    if (orb === 0) return `Up to ${limit} concurrent sessions across AirVPN`;
    return `${orb} Orb tunnel${orb === 1 ? "" : "s"} active · up to ${limit} concurrent sessions`;
  }
  const active = Math.max(0, Math.trunc(activeSessions));
  const external = Math.max(0, active - orb);
  const free = Math.max(0, limit - active);
  return `${active} / ${limit} active sessions · ${orb} Orb tunnel${orb === 1 ? "" : "s"} · ${external} external · ${free} free`;
}
