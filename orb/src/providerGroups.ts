import type { AIProvider, ProviderUsage } from "./api";
import type { AccountHealthSnapshot } from "./routingApi";
import { orderAccounts, type OrderedAccount } from "./accountOrder";
import { effectiveProviderStatus, usageChips, type QuotaLevel } from "./providerUsage";

/**
 * Inference page: accounts of one provider type collapse into one expandable
 * row. This file is the whole model (grouping, the header's aggregate, the
 * remembered open state); `Providers.tsx` only renders it.
 */
export type ProviderGroup<T> = { type: string; name: string; accounts: T[] };

type Groupable = OrderedAccount & { provider_type_name?: string };

/** The provider's display name, the same for every account of the type. */
export function providerGroupName(a: Groupable): string {
  return a.provider_type === "antigravity" ? "Google Antigravity" : a.provider_type_name || a.provider_type;
}

/**
 * One group per provider type, in order of first appearance; accounts inside
 * a group keep the backend's priority order (`orderAccounts`), so position i
 * is the account tried (i+1)th. A group of one is rendered as a plain row.
 */
export function groupProviderAccounts<T extends Groupable>(list: readonly T[]): ProviderGroup<T>[] {
  const groups = new Map<string, ProviderGroup<T>>();
  for (const a of orderAccounts(list)) {
    const group = groups.get(a.provider_type);
    if (group) group.accounts.push(a);
    else groups.set(a.provider_type, { type: a.provider_type, name: providerGroupName(a), accounts: [a] });
  }
  return [...groups.values()];
}

export type GroupTone = "attention" | "exhausted" | "warning" | "muted";
export type GroupStatusPart = { text: string; tone: GroupTone };

/** One chip per quota family: how many of the accounts reporting it can still serve it. */
export type GroupChip = {
  label: string;
  /** Accounts that can serve this family now (usable account, family not spent). */
  available: number;
  /** Accounts counted: those reporting this family, plus those known to serve nothing. */
  total: number;
  /** Lowest used ratio (0..1) among the available accounts. */
  leastUsed?: number;
  level: QuotaLevel;
  detail: string;
};

export type ProviderGroupSummary = {
  count: number;
  /** Worst first: sign-in, verification, credit, error, limit reached, near limit, disabled. */
  parts: GroupStatusPart[];
  /** "4 accounts · 1 limit reached · 2 near limit". */
  text: string;
  chips: GroupChip[];
  /** An account needs an action only its own row offers, so the group opens by default. */
  attention: boolean;
};

const BUCKETS: { statuses: string[]; one: string; many: string; tone: GroupTone; attention?: boolean }[] = [
  { statuses: ["needs_reauth", "needs_auth", "auth_failed"], one: "needs sign-in", many: "need sign-in", tone: "attention", attention: true },
  { statuses: ["needs_verification"], one: "needs verification", many: "need verification", tone: "attention", attention: true },
  { statuses: ["out_of_credit"], one: "out of credit", many: "out of credit", tone: "exhausted", attention: true },
  { statuses: ["error"], one: "error", many: "errors", tone: "attention", attention: true },
  { statuses: ["quota_exhausted", "pool_exhausted"], one: "limit reached", many: "limit reached", tone: "exhausted" },
  { statuses: ["quota_warning"], one: "near limit", many: "near limit", tone: "warning" },
  { statuses: ["disabled"], one: "disabled", many: "disabled", tone: "muted" },
];

/** Statuses of an account the router can still pick (a spent pool leaves the other pools). */
const USABLE = new Set(["connected", "ready", "quota_warning", "pool_exhausted"]);

/**
 * The group header's aggregate. Statuses are counted, never merged into one
 * word. Usage is "N of M" accounts with quota left per family rather than a
 * percentage: an average hides a spent account, the best account hides that
 * the others are spent, the worst hides the headroom that failover will use.
 * A disabled, signed-out, failing or fully spent account counts as not
 * available. A working account without a figure for a family is left out of
 * that family's count: unknown is never shown as free or as spent.
 */
export function summarizeProviderGroup(
  accounts: readonly AIProvider[],
  usage: Record<string, ProviderUsage | undefined> = {},
  health: Record<string, AccountHealthSnapshot | undefined> = {},
): ProviderGroupSummary {
  const statuses = accounts.map(a => effectiveProviderStatus(a, usage[a.id], health[a.id]));
  const parts: GroupStatusPart[] = [];
  let attention = false;
  for (const bucket of BUCKETS) {
    const n = statuses.filter(s => bucket.statuses.includes(s)).length;
    if (!n) continue;
    parts.push({ text: `${n} ${n === 1 ? bucket.one : bucket.many}`, tone: bucket.tone });
    attention ||= !!bucket.attention;
  }
  const families = new Map<string, { reported: Set<number>; used: number[]; levels: QuotaLevel[] }>();
  accounts.forEach((a, i) => {
    const u = usage[a.id];
    if (!u || u.error) return;
    for (const chip of usageChips(u)) {
      const family = families.get(chip.label) ?? { reported: new Set(), used: [], levels: [] };
      family.reported.add(i);
      if (USABLE.has(statuses[i]) && chip.level !== "exhausted") { family.used.push(chip.used); family.levels.push(chip.level); }
      families.set(chip.label, family);
    }
  });
  // Known to serve nothing, with or without a figure.
  const down = statuses.flatMap((s, i) => USABLE.has(s) ? [] : [i]);
  const chips = [...families].map(([name, f]): GroupChip => {
    const label = name === "7d" ? "Weekly" : name;
    const available = f.used.length;
    const total = f.reported.size + down.filter(i => !f.reported.has(i)).length;
    const leastUsed = available ? Math.min(...f.used) : undefined;
    return {
      label, available, total, leastUsed,
      level: !available ? "exhausted" : f.levels.every(l => l === "warning") ? "warning" : "normal",
      detail: `${label}: ${available} of ${total} ${total === 1 ? "account has" : "accounts have"} quota left`
        + (leastUsed != null ? ` · least used ${Math.round(leastUsed * 100)}%` : ""),
    };
  });
  const count = accounts.length;
  return { count, parts, chips, attention, text: [`${count} ${count === 1 ? "account" : "accounts"}`, ...parts.map(p => p.text)].join(" · ") };
}

/** Explicit choices only: a group without an entry follows its default. */
export type GroupPrefs = Record<string, boolean>;

/** Collapsed by default; open by default while an account inside needs attention. */
export function isGroupOpen(prefs: GroupPrefs, key: string, attention: boolean): boolean {
  return prefs[key] ?? attention;
}

/** Prefs after the user toggles `key`. Returning to the default forgets the choice, so a later problem can open the group again. */
export function toggleGroupPref(prefs: GroupPrefs, key: string, attention: boolean): GroupPrefs {
  const open = !isGroupOpen(prefs, key, attention);
  const next = { ...prefs };
  if (open === attention) delete next[key]; else next[key] = open;
  return next;
}

const storageKey = (connection: string) => `orb.inferenceGroups:${connection}`;

/** Remembered per connection (Core URL); storage may be unavailable or hold junk. */
export function loadGroupPrefs(connection: string): GroupPrefs {
  try {
    const raw: unknown = JSON.parse(localStorage.getItem(storageKey(connection)) ?? "{}");
    if (!raw || typeof raw !== "object" || Array.isArray(raw)) return {};
    return Object.fromEntries(Object.entries(raw).filter((e): e is [string, boolean] => typeof e[1] === "boolean"));
  } catch { return {}; }
}

export function saveGroupPrefs(connection: string, prefs: GroupPrefs): void {
  try {
    if (Object.keys(prefs).length) localStorage.setItem(storageKey(connection), JSON.stringify(prefs));
    else localStorage.removeItem(storageKey(connection));
  } catch { /* The choice then lasts for this visit only. */ }
}
