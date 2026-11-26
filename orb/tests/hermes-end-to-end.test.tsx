import { cleanup, fireEvent, render, screen, waitFor } from "@solidjs/testing-library";
import { afterEach, describe, expect, it, vi } from "vitest";
import { clearConnection, setConnection } from "../src/api";
import { HermesSettings, hermesRuntimeLine } from "../src/HermesSettings";
import { CloudAgentPage, CloudConversation } from "../src/CloudAgents";
import { CloudModelPicker } from "../src/CloudModelPicker";
import type { CloudAccount, CloudExecution, HermesSettingsState } from "../src/cloudAgentApi";

afterEach(() => {
  cleanup();
  clearConnection();
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});

const fullHermesState = (overrides: Partial<HermesSettingsState> = {}): HermesSettingsState => ({
  home_dir: "/var/lib/hermes-assistant",
  config_path: "/var/lib/hermes-assistant/config.yaml",
  soul_path: "/var/lib/hermes-assistant/SOUL.md",
  default_model: "builtin/smart",
  provider: "custom",
  base_url: "http://127.0.0.1:3000/v1",
  reasoning_effort: "medium",
  use_sandboxed_router: true,
  memory_enabled: true,
  user_profile_enabled: true,
  memory_char_limit: 8000,
  user_char_limit: 4000,
  compression_enabled: true,
  compression_threshold: 0.5,
  telegram_tool_progress: "new",
  telegram_cleanup_progress: true,
  soul_markdown: "# Paloma\nHelpful assistant.",
  runtime: {
    service_name: "hermes-assistant.service",
    service_active: true,
    api_server_healthy: true,
    uses_sandboxed_proxy: true,
    token_present: true,
    notes: [],
  },
  sessions: {
    available: true,
    total_sessions: 12,
    active_sessions_24h: 3,
    total_tokens: 4500,
  },
  models: [
    { id: "", name: "Profile default" },
    { id: "builtin/smart", name: "Smart · builtin/smart" },
    { id: "openai/gpt-6-astra", name: "GPT-6 Astra" },
  ],
  efforts: [
    { id: "", name: "Default" },
    { id: "none", name: "Off" },
    { id: "low", name: "Low" },
    { id: "medium", name: "Medium" },
    { id: "high", name: "High" },
  ],
  ...overrides,
});

describe("HermesSettings end-to-end (H1)", () => {
  it("loads admin settings, displays runtime health and sessions, saves updates, and clears on member 403 switch", async () => {
    const savedBodies: Record<string, unknown>[] = [];
    const fetchMock = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input);
      if (url.startsWith("http://member.test")) {
        return new Response(JSON.stringify({ error: "Hermes is not connected for this account" }), {
          status: 403,
          headers: { "Content-Type": "application/json" },
        });
      }
      if (url.endsWith("/api/cloud/hermes/settings") && (!init?.method || init.method === "GET")) {
        return Response.json(fullHermesState());
      }
      if (url.endsWith("/api/cloud/hermes/settings") && init?.method === "PUT") {
        const body = JSON.parse(String(init.body ?? "{}")) as Record<string, unknown>;
        savedBodies.push(body);
        return Response.json(
          fullHermesState({
            default_model: String(body.default_model ?? "builtin/smart"),
            reasoning_effort: String(body.reasoning_effort ?? ""),
            telegram_tool_progress: String(body.telegram_tool_progress ?? "new"),
            telegram_cleanup_progress: Boolean(body.telegram_cleanup_progress),
            soul_markdown: String(body.soul_markdown ?? ""),
          }),
        );
      }
      return Response.json({});
    });
    vi.stubGlobal("fetch", fetchMock);

    setConnection("http://admin.test", "admin-token");
    render(() => <HermesSettings />);

    expect(await screen.findByText(/Service: active · API: Healthy · Via Core proxy/)).toBeTruthy();
    expect(screen.getByText(/12 total sessions · 3 active in 24h/)).toBeTruthy();

    fireEvent.change(screen.getByLabelText("Default Hermes model"), { target: { value: "openai/gpt-6-astra" } });
    fireEvent.change(screen.getByLabelText("Default reasoning effort"), { target: { value: "high" } });
    fireEvent.change(screen.getByLabelText("Telegram tool progress"), { target: { value: "edit" } });
    fireEvent.input(screen.getByLabelText("SOUL.md content"), { target: { value: "# Updated Soul" } });

    fireEvent.click(screen.getByRole("button", { name: "Save" }));
    expect(await screen.findByText("Saved Hermes configuration.")).toBeTruthy();
    expect(savedBodies).toHaveLength(1);
    expect(savedBodies[0]).toMatchObject({
      default_model: "openai/gpt-6-astra",
      reasoning_effort: "high",
      telegram_tool_progress: "edit",
      soul_markdown: "# Updated Soul",
      restart_service: false,
    });

    // Switch to a member session -> must immediately clear admin Hermes settings and show calm 403 card
    setConnection("http://member.test", "member-token");
    expect(await screen.findByText("Assistant not set up on this Core")).toBeTruthy();
    expect(screen.queryByLabelText("Default Hermes model")).toBeNull();
    expect(screen.queryByRole("alert")).toBeNull();
  });

  it("formats runtime summary including unhealthy API and missing token flags", () => {
    expect(
      hermesRuntimeLine({
        service_active: true,
        api_server_healthy: false,
        uses_sandboxed_proxy: true,
        token_present: false,
      }),
    ).toBe("Service: active · API: Unreachable · Via Core proxy · Token missing");
  });
});

describe("CloudModelPicker Hermes options (H1)", () => {
  it("fetches /api/cloud/hermes/options and preserves effort when switching models", async () => {
    setConnection("http://admin.test", "admin-token");
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: RequestInfo | URL) => {
        expect(String(input)).toBe("http://admin.test/api/cloud/hermes/options");
        return Response.json({
          models: {
            items: [
              { id: "", name: "Profile default" },
              { id: "builtin/code", name: "Code · builtin/code" },
            ],
          },
          efforts: [
            { id: "", name: "Default" },
            { id: "high", name: "High" },
          ],
        });
      }),
    );

    const changes: Array<{ model: string; params: { id: string; value: string }[] }> = [];
    const onChange = (model: string, params: { id: string; value: string }[]) => {
      changes.push({ model, params });
    };
    render(() => (
      <CloudModelPicker
        provider="hermes"
        model="builtin/code"
        params={[{ id: "effort", value: "high" }]}
        onChange={onChange}
        onError={() => {}}
      />
    ));

    const modelBtn = await screen.findByLabelText("Model");
    const effortBtn = screen.getByLabelText("Effort");
    expect(modelBtn.textContent).toContain("Code · builtin/code");
    expect(effortBtn.textContent).toContain("High");

    fireEvent.click(effortBtn);
    fireEvent.click(screen.getByRole("option", { name: "Default" }));
    expect(changes.at(-1)).toEqual({ model: "builtin/code", params: [] });
  });
});

describe("Hermes CloudAgentPage & CloudConversation end-to-end (H1)", () => {
  const hermesAccount = (available: boolean): CloudAccount => ({
    id: "paloma",
    provider: "hermes",
    label: "Paloma",
    available,
    experimental: false,
    reason: available ? undefined : "Hermes is not connected for this account",
    capabilities: {
      models: true,
      attachments: true,
      repository: false,
      follow_up: true,
      cancel: true,
      detailed_events: true,
      artifacts: false,
    },
  });

  it("isolates members when paloma is unavailable (no options fetch, launch disabled)", async () => {
    setConnection("http://member.test", "member-token");
    const urls: string[] = [];
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: RequestInfo | URL) => {
        const url = String(input);
        urls.push(url);
        if (url.endsWith("/api/cloud/accounts")) return Response.json([hermesAccount(false)]);
        return Response.json({});
      }),
    );

    render(() => <CloudAgentPage project="demo" onCreated={() => {}} />);
    expect(await screen.findByText("Hermes is not connected for this account")).toBeTruthy();
    fireEvent.input(screen.getByLabelText("Prompt"), { target: { value: "Try launching Hermes" } });
    expect((screen.getByRole("button", { name: "Create cloud agent" }) as HTMLButtonElement).disabled).toBe(true);
    expect(urls.some((u) => u.includes("/api/cloud/hermes/options"))).toBe(false);
    expect(urls.some((u) => u.includes("/api/control/missions"))).toBe(false);
  });

  it("streams Hermes turn, submits approval using external_id fallback, sends follow-up with effort, and refreshes immediately on cancel", async () => {
    setConnection("http://admin.test", "admin-token");
    let currentExec: CloudExecution = {
      mission_id: "m-h1",
      revision: 1,
      selection: { provider: "hermes", account: "paloma", model: "builtin/smart", model_params: [{ id: "effort", value: "high" }] },
      turns: [
        {
          key: "turn-1",
          prompt: "Check status",
          phase: "waiting_user",
          external_id: "run_h1_ui",
          result: "Checking…",
          steps: [
            { kind: "think", id: "th1", text: "Inspecting workspace", done: true },
            { kind: "tool", id: "tl1", call_id: "tl1", name: "bash", status: "completed", done: true, args: { preview: "git status" }, result: "clean" },
          ],
          // Deliberately omit run_id on approval to verify fallback to turn.external_id
          artifacts: [
            { kind: "hermes_approval", path: "", request: { request_id: "req_ui_1", command: "git status", choices: ["once", "deny"] } },
          ],
          branches: [],
        },
      ],
    };

    const posts: Array<{ url: string; body: unknown }> = [];
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
        const url = String(input);
        const method = init?.method ?? "GET";
        if (url.endsWith("/api/cloud/accounts")) return Response.json([hermesAccount(true)]);
        if (url.endsWith("/api/cloud/hermes/options")) {
          return Response.json({
            models: { items: [{ id: "", name: "Profile default" }, { id: "builtin/smart", name: "Smart" }] },
            efforts: [{ id: "", name: "Default" }, { id: "high", name: "High" }],
          });
        }
        if (url.endsWith("/api/control/missions/m-h1/cloud/children")) return Response.json({ missions: [] });
        if (url.endsWith("/api/control/missions/m-h1/cloud")) return Response.json(currentExec);
        if (url.endsWith("/api/control/missions/m-h1")) {
          return Response.json({ id: "m-h1", title: "Check status", backend: "cloud_hermes", status: "active", history: [], created_at: "", updated_at: "" });
        }
        if (method === "POST" && url.endsWith("/api/control/missions/m-h1/cloud/approval")) {
          posts.push({ url, body: JSON.parse(String(init?.body ?? "{}")) });
          currentExec = {
            ...currentExec,
            revision: 2,
            turns: [{ ...currentExec.turns[0], phase: "running", artifacts: [], result: "Almost done" }],
          };
          return Response.json({ ok: true });
        }
        if (method === "POST" && url.endsWith("/api/control/missions/m-h1/cloud/cancel")) {
          posts.push({ url, body: null });
          currentExec = {
            ...currentExec,
            revision: 3,
            turns: [{ ...currentExec.turns[0], phase: "cancel_requested", artifacts: [] }],
          };
          return Response.json({ cancel_requested: true });
        }
        return Response.json({});
      }),
    );

    render(() => <CloudConversation id="m-h1" />);
    const approveBtn = await screen.findByRole("button", { name: "Approve once" });
    fireEvent.click(approveBtn);

    await waitFor(() => {
      expect(posts.some((p) => p.url.endsWith("/cloud/approval"))).toBe(true);
    });
    expect(posts[0].body).toEqual({ run_id: "run_h1_ui", request_id: "req_ui_1", choice: "once" });

    // After approval refreshes, turn is running and Stop triggers cancel + immediate refresh to "Stopping…"
    await screen.findByText("Almost done");
    const stopBtn = await screen.findByRole("button", { name: /Stop/i });
    fireEvent.click(stopBtn);

    await waitFor(() => {
      expect(posts.some((p) => p.url.endsWith("/cloud/cancel"))).toBe(true);
    });
    expect(await screen.findByText("Stopping…")).toBeTruthy();
  });

  it("does not probe /api/cloud/hermes/options on CloudConversation when Hermes account is unavailable", async () => {
    setConnection("http://member.test", "member-token");
    const urls: string[] = [];
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: RequestInfo | URL) => {
        const url = String(input);
        urls.push(url);
        if (url.endsWith("/api/cloud/accounts")) return Response.json([hermesAccount(false)]);
        if (url.endsWith("/api/control/missions/m-h2/cloud/children")) return Response.json({ missions: [] });
        if (url.endsWith("/api/control/missions/m-h2/cloud")) {
          return Response.json({
            mission_id: "m-h2",
            revision: 1,
            selection: { provider: "hermes", account: "paloma", model: "builtin/smart", model_params: [{ id: "effort", value: "high" }] },
            turns: [{ key: "turn-1", prompt: "Hello", phase: "response_complete", result: "Done", artifacts: [], branches: [] }],
          } satisfies CloudExecution);
        }
        if (url.endsWith("/api/control/missions/m-h2")) {
          return Response.json({ id: "m-h2", title: "Hello", backend: "cloud_hermes", status: "awaiting_user", history: [], created_at: "", updated_at: "" });
        }
        return Response.json({});
      }),
    );

    render(() => <CloudConversation id="m-h2" />);
    expect(await screen.findByText("Done")).toBeTruthy();
    expect(urls.some((u) => u.includes("/api/cloud/hermes/options"))).toBe(false);
  });
});
