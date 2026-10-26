import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { approvalDecisionPath } from "../src/deviceApproval";
import { USAGE_ACTIONS, createUsageTelemetry, screenName } from "../src/usageTelemetry";

const fixture = JSON.parse(readFileSync(join(dirname(fileURLToPath(import.meta.url)), "..", "..", "shared", "orb-spec", "fixtures", "usage-telemetry.json"), "utf8"));
const ident = new RegExp(fixture.ident_pattern);

function allowed(event: Record<string, unknown>) {
  const fields = { ...fixture.common, ...fixture.schemas[event.schema as string] };
  for (const [key, value] of Object.entries(event)) {
    const type = fields[key];
    expect(type, `field ${key}`).toBeDefined();
    if (Array.isArray(type)) expect(type).toContain(value);
    else if (type === "uint") expect(Number.isInteger(value) && (value as number) >= 0).toBe(true);
    else if (type === "ident") expect(value).toMatch(ident);
  }
}

function harness(fail = 0) {
  const sent: Record<string, unknown>[][] = [];
  let t = 1_000;
  const telemetry = createUsageTelemetry({
    transport: async events => { if (fail-- > 0) throw new Error("offline"); sent.push(events); },
    now: () => t,
  });
  return { telemetry, sent, advance: (ms: number) => { t += ms; } };
}

describe("shared/orb-spec/fixtures/usage-telemetry.json", () => {
  it("uses the shared action names", () => expect([...USAGE_ACTIONS]).toEqual(fixture.schemas["orb.action.v1"].action));

  it("builds only allowlisted fields", async () => {
    const { telemetry, sent, advance } = harness();
    telemetry.setActive(true);
    telemetry.action("fork", "mission");
    telemetry.action("sidebar_move", "sidebar", 3);
    telemetry.approval({ kind: "grant", decision: "approved", method: "touch_id", waitMs: 1234.6 });
    const close = telemetry.page("settings.telemetry", "sheet", "command_palette");
    advance(1500);
    close();
    close();
    await telemetry.flush();
    expect(sent[0]).toHaveLength(4);
    for (const event of sent[0]) {
      expect(fixture.client_schemas).toContain(event.schema);
      expect(event.client).toBe("desktop");
      allowed(event);
    }
    expect(sent[0][3]).toMatchObject({ screen: "settings.telemetry", dwell_ms: 1500 });
    expect(sent[0][3]).not.toHaveProperty("quick_close");
  });

  it("drops free-text values that are not identifiers", async () => {
    const { telemetry, sent } = harness();
    telemetry.setActive(true);
    telemetry.action("fork", "a surface with spaces");
    await telemetry.flush();
    expect(sent[0][0]).not.toHaveProperty("surface");
  });
});

describe("usage telemetry client", () => {
  it("queues nothing while off (the default)", async () => {
    const { telemetry, sent } = harness();
    expect(telemetry.active).toBe(false);
    telemetry.action("queue");
    telemetry.page("inbox", "screen")();
    await telemetry.flush();
    expect(telemetry.queued).toBe(0);
    expect(sent).toHaveLength(0);
  });

  it("keeps events when a flush fails and sends them on the next one", async () => {
    const { telemetry, sent } = harness(1);
    telemetry.setActive(true);
    telemetry.action("queue");
    telemetry.action("btw");
    await telemetry.flush();
    expect(telemetry.queued).toBe(2);
    expect(sent).toHaveLength(0);
    await telemetry.flush();
    expect(telemetry.queued).toBe(0);
    expect(sent[0].map(e => e.action)).toEqual(["queue", "btw"]);
  });

  it("batches at 50 events", async () => {
    const { telemetry, sent } = harness();
    telemetry.setActive(true);
    for (let i = 0; i < 60; i++) telemetry.action("queue");
    await telemetry.flush();
    await telemetry.flush();
    expect(sent.map(batch => batch.length)).toEqual([50, 10]);
  });

  it("names pages without ids", () => {
    expect(screenName("m:6f1c")).toBe("mission");
    expect(screenName(null)).toBe("home");
    expect(screenName("bitwarden-settings")).toBe("bitwarden-settings");
  });

  it("reads approval kind and decision from the route only", () => {
    expect(approvalDecisionPath("/api/privilege-access/abc/approve")).toEqual({ kind: "command_class", decision: "approved" });
    expect(approvalDecisionPath("/api/bitwarden/requests/abc/reject")).toEqual({ kind: "grant", decision: "denied" });
    expect(approvalDecisionPath("/api/mission-access/abc/deny")).toEqual({ kind: "grant", decision: "denied" });
    expect(approvalDecisionPath("/api/bitwarden/config")).toBeNull();
  });
});
