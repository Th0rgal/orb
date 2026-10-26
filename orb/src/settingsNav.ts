/** Settings navigation: five goal-oriented sections, each made of one or more
 * tabs. Tab ids are the page ids `open(...)` has always used, so existing deep
 * links (`routing`, `bitwarden-settings`, …) keep landing on the same panel.
 * iOS (`OrbSettingsNav.swift`) and Android (`SettingsNav.kt`) use the same
 * ids, names and order. */
export type SettingsSectionId = "account" | "models" | "agents" | "security" | "notifications";
export type SettingsTab = { id: string; label: string };
/** `pages` are reachable by id but have no tab (opened from elsewhere). */
export type SettingsSection = { id: SettingsSectionId; label: string; subtitle: string; tabs: SettingsTab[]; pages?: SettingsTab[] };

export const SETTINGS_SECTIONS: SettingsSection[] = [
  { id: "account", label: "Account", subtitle: "Your server connection, connected accounts and how Orb looks.",
    tabs: [{ id: "settings", label: "Account" }] },
  { id: "models", label: "Models", subtitle: "Which models agents use and in what order when a provider is unavailable.",
    tabs: [{ id: "routing", label: "Routing" }],
    // Usage attribution (per mission, key, caller); quotas live in Providers, which links here.
    pages: [{ id: "usage-settings", label: "Usage details" }] },
  { id: "agents", label: "Agents", subtitle: "What agents know and can do, the Assistant, and the agents on this computer.",
    tabs: [{ id: "skills-settings", label: "Skills" }, { id: "hermes-settings", label: "Assistant" }, { id: "btw-settings", label: "Quick questions (/btw)" }, { id: "local-agents", label: "Local agents" }] },
  { id: "security", label: "Security", subtitle: "Who can approve risky actions, Fleet Bunker Mode, privileged access and secrets.",
    tabs: [{ id: "security-settings", label: "Access" }, { id: "bitwarden-settings", label: "Secrets vault" }] },
  { id: "notifications", label: "Notifications", subtitle: "What reaches your Inbox and when Orb tells you.",
    tabs: [{ id: "inbox-settings", label: "Notifications" }] },
];

/** Page ids that no longer have a page of their own. */
const LEGACY_PAGES: Record<string, string> = { execution: "local-agents" };

/** The current id for a page id, old or new. */
export const settingsPageId = (id: string): string => LEGACY_PAGES[id] ?? id;

export const settingsSectionFor = (id: string | null | undefined): SettingsSection | undefined =>
  id == null ? undefined : SETTINGS_SECTIONS.find(s => [...s.tabs, ...(s.pages ?? [])].some(t => t.id === settingsPageId(id)));

export const SETTINGS_PAGE_IDS: string[] = [...SETTINGS_SECTIONS.flatMap(s => [...s.tabs, ...(s.pages ?? [])].map(t => t.id)), ...Object.keys(LEGACY_PAGES)];

/** Which sections need the user: drives the sidebar's attention dots. */
export function settingsAttention(s: { bunkerActive: boolean; deviceEnrolled: boolean; quotaExhausted: boolean }): Set<SettingsSectionId> {
  const out = new Set<SettingsSectionId>();
  if (s.bunkerActive || !s.deviceEnrolled) out.add("security");
  if (s.quotaExhausted) out.add("models");
  return out;
}
