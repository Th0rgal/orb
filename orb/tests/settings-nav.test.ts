import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { SETTINGS_SECTIONS, settingsAttention, settingsPageId, settingsSectionFor } from "../src/settingsNav";

const fixture = JSON.parse(readFileSync(join(dirname(fileURLToPath(import.meta.url)), "..", "..", "shared", "orb-spec", "fixtures", "settings-nav.json"), "utf8"));

describe("shared/orb-spec/fixtures/settings-nav.json", () => {
  it("has the same sections, names and tabs", () => expect(SETTINGS_SECTIONS).toEqual(fixture.sections));
  it("maps legacy ids", () => { for (const [from, to] of Object.entries(fixture.legacy)) expect(settingsPageId(from)).toBe(to); });
  for (const c of fixture.attention) it(`attention: ${c.name}`, () => expect([...settingsAttention(c.state)].sort()).toEqual([...c.expected].sort()));
});

it("keeps every old page id inside a section", () => {
  const old: Record<string, string> = { settings: "account", execution: "agents", routing: "models", "usage-settings": "models", "hermes-settings": "agents", "btw-settings": "agents", "skills-settings": "agents", "bitwarden-settings": "security", "inbox-settings": "notifications" };
  for (const [id, section] of Object.entries(old)) expect(settingsSectionFor(id)?.id).toBe(section);
  expect(settingsSectionFor("inbox")).toBeUndefined();
  expect(settingsSectionFor(null)).toBeUndefined();
});
