import { describe, expect, it } from "vitest";
import {
  canInstallSoftware,
  canUpdateSoftware,
  matchesSoftwareJob,
  softwareAttentionSummary,
  type SoftwareComponent,
  type SoftwareJob,
  type SoftwareMachine,
} from "../src/softwareInventory";

function comp(overrides: Partial<SoftwareComponent>): SoftwareComponent {
  return {
    id: "vibe",
    name: "Mistral Vibe",
    version: "2.19.1",
    path: "/usr/local/bin/vibe-acp",
    installed: true,
    owner: "Fleet installer",
    update_supported: true,
    latest: "2.19.1",
    release_error: null,
    running: [],
    instructions: "",
    ready: true,
    ready_detail: "Authenticated via Core Mistral proxy.",
    ...overrides,
  };
}

describe("softwareInventory readiness & fleet install helpers", () => {
  it("recognizes fresh fleet-installable components without an existing binary path", () => {
    const missingFleet = comp({
      installed: false,
      version: null,
      path: null,
      update_supported: true,
      latest: "2.19.1",
      ready: false,
    });
    expect(canInstallSoftware(missingFleet)).toBe(true);
    expect(canUpdateSoftware(missingFleet)).toBe(false);

    const job: SoftwareJob = {
      id: "job-vibe",
      component: "vibe",
      version: "2.19.1",
      path: "/usr/local/bin/vibe-acp",
      state: "queued",
      error: null,
      created_at: 1,
      updated_at: 1,
    };
    expect(matchesSoftwareJob(job, missingFleet)).toBe(true);
  });

  it("summarizes restarts, missing CLIs, auth setup gaps, and updates in header order", () => {
    const machines: SoftwareMachine[] = [
      {
        id: "dgx-spark-admin",
        name: "dgx-spark-admin",
        online: true,
        inventory: {
          checked_at: 1,
          runtime: {
            name: "Node runner",
            version: "0.13.0",
            build: "test",
            path: "/usr/local/bin/sandboxed-node",
            restart_required: true,
          },
          jobs: [],
          components: [
            comp({ id: "codex", version: "1.9.0", latest: "1.10.0" }),
            comp({ id: "grok", ready: false, ready_detail: "Missing Grok profile" }),
          ],
        },
      },
      {
        id: "nimrud",
        name: "nimrud",
        online: true,
        inventory: {
          checked_at: 1,
          runtime: {
            name: "Node runner",
            version: "0.13.0",
            build: "test",
            path: "/usr/local/bin/sandboxed-node",
            restart_required: false,
          },
          jobs: [],
          components: [
            comp({ id: "vibe", installed: false, version: null, path: null, ready: false }),
          ],
        },
      },
    ];

    expect(softwareAttentionSummary(machines)).toBe(
      "1 restart needed · 1 missing · 1 setup needed · 1 update",
    );
  });
});
