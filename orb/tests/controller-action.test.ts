import { afterEach, expect, it, vi } from "vitest";
import { controllerAction, deleteProjectController } from "../src/api";

afterEach(() => vi.restoreAllMocks());

it("rejects legacy success when Run now leaves the controller paused", async () => {
  vi.spyOn(globalThis, "fetch").mockResolvedValue(new Response(JSON.stringify({
    slug: "lido", job: { id: "controller", enabled: false, state: "paused" }, runs: [],
  }), { status: 200 }));
  await expect(controllerAction("lido", "run")).rejects.toThrow("did not wake the paused controller");
});

it("accepts a queued wake without pretending the steer has been consumed", async () => {
  vi.spyOn(globalThis, "fetch").mockResolvedValue(new Response(JSON.stringify({
    slug: "lido", job: { id: "controller", enabled: true, state: "scheduled" }, runs: [],
  }), { status: 200 }));
  const view = await controllerAction("lido", "run");
  expect(view.job?.enabled).toBe(true);
  expect(view.runs).toEqual([]);
});

it("keeps pause actions valid", async () => {
  vi.spyOn(globalThis, "fetch").mockResolvedValue(new Response(JSON.stringify({
    slug: "lido", job: { id: "controller", enabled: false, state: "paused" }, runs: [],
  }), { status: 200 }));
  expect((await controllerAction("lido", "pause")).job?.state).toBe("paused");
});

for (const action of ["archive", "restore"] as const) {
  it(`${action} keeps the controller paused and preserves archival state`, async () => {
    const fetch = vi.spyOn(globalThis, "fetch").mockResolvedValue(new Response(JSON.stringify({
      slug: "verity", job: {id: "controller", enabled: false, state: "paused", archived: action === "archive"}, runs: [],
    }), {status: 200}));
    const view = await controllerAction("verity", action);
    expect(JSON.parse(String(fetch.mock.calls[0][1]?.body))).toEqual({action});
    expect(view.job?.archived).toBe(action === "archive");
    expect(view.job?.enabled).toBe(false);
  });
}

it("deletes a project controller via DELETE /api/projects/:slug/controller", async () => {
  const fetch = vi.spyOn(globalThis, "fetch").mockResolvedValue(new Response(JSON.stringify({
    slug: "verity", job: null, settings: null, runs: [],
  }), { status: 200 }));
  const view = await deleteProjectController("verity");
  expect(fetch.mock.calls[0][1]?.method).toBe("DELETE");
  expect(view.job).toBeNull();
});

it("preserves script_path and script_content on script-based Hermes crons and builds a debug prompt", async () => {
  const { getProjectCron, updateProjectCron } = await import("../src/api");
  const { buildCronDebugPrompt } = await import("../src/Controller");
  const fetchSpy = vi.spyOn(globalThis, "fetch")
    .mockResolvedValueOnce(new Response(JSON.stringify({
      job: {
        id: "70c14fb0c5f2",
        name: "gaulle-film1-watch",
        schedule: { display: "3m" },
        enabled: true,
        state: "scheduled",
        prompt: "",
        script: "gaulle_watch_tick.sh",
        script_path: "/var/lib/hermes-assistant/scripts/gaulle_watch_tick.sh",
        script_content: "#!/usr/bin/env bash\necho tick\n",
        no_agent: true,
        deliver: "telegram:-5261918484",
      },
      runs: [
        { id: "r1", status: "ok", duration_secs: 1.8, silent: true, report: "[SILENT]" },
      ],
    }), { status: 200 }))
    .mockResolvedValueOnce(new Response(JSON.stringify({
      job: {
        id: "70c14fb0c5f2",
        name: "gaulle-film1-watch",
        schedule: { display: "3m" },
        enabled: true,
        state: "scheduled",
        prompt: "Watch film1 render progress",
        script: "gaulle_watch_tick.sh",
        script_path: "/var/lib/hermes-assistant/scripts/gaulle_watch_tick.sh",
        script_content: "#!/usr/bin/env bash\necho updated\n",
        no_agent: true,
      },
      runs: [],
    }), { status: 200 }));

  const view = await getProjectCron("gaulle", "70c14fb0c5f2");
  expect(view.settings?.script).toBe("gaulle_watch_tick.sh");
  expect(view.settings?.script_path).toBe("/var/lib/hermes-assistant/scripts/gaulle_watch_tick.sh");
  expect(view.settings?.script_content).toContain("echo tick");
  expect(view.settings?.no_agent).toBe(true);

  const debugPrompt = buildCronDebugPrompt(view);
  expect(debugPrompt).toContain("gaulle-film1-watch");
  expect(debugPrompt).toContain("/var/lib/hermes-assistant/scripts/gaulle_watch_tick.sh");
  expect(debugPrompt).toContain("echo tick");

  const updated = await updateProjectCron("gaulle", "70c14fb0c5f2", {
    prompt: "Watch film1 render progress",
    script_content: "#!/usr/bin/env bash\necho updated\n",
  });
  expect(JSON.parse(String(fetchSpy.mock.calls[1][1]?.body))).toMatchObject({
    prompt: "Watch film1 render progress",
    script_content: "#!/usr/bin/env bash\necho updated\n",
  });
  expect(updated.settings?.script_content).toContain("echo updated");
});

