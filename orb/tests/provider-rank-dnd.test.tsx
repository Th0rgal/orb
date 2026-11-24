import { fireEvent, render, screen, waitFor } from "@solidjs/testing-library";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { Providers } from "../src/Providers";
import { clearConnection, setConnection, type AIProvider } from "../src/api";
import { cacheReset } from "../src/pageCache";
import { applyAuthMeResponse, resetCurrentUserState } from "../src/accountAdmin";

const makeAccount = (id: string, provider_type: string, name: string, priority: number): AIProvider => ({
  id,
  name,
  provider_type,
  provider_type_name: provider_type === "openai" ? "OpenAI" : "Anthropic",
  enabled: true,
  uses_oauth: false,
  has_api_key: true,
  has_oauth: false,
  priority,
  status: { type: "connected" },
});

function makeDataTransfer() {
  const store = new Map<string, string>();
  return {
    effectAllowed: "none",
    get types() {
      return [...store.keys()];
    },
    setData(type: string, value: string) {
      store.set(type, value);
    },
    getData(type: string) {
      return store.get(type) ?? "";
    },
  };
}

describe("Providers drag-and-drop account ranking", () => {
  let accounts: AIProvider[];
  let reorders: string[][];

  beforeEach(() => {
    cacheReset();
    localStorage.clear();
    resetCurrentUserState("multi_user");
    applyAuthMeResponse({
      auth_mode: "multi_user",
      user: {
        id: "u-admin",
        username: "admin",
        role: "admin",
        unix_username: null,
        daily_spend_cap_cents: null,
        spent_today_cents: 0,
      },
      capabilities: {
        can_manage_users: true,
        can_use_core_target: true,
        can_manage_global_providers: true,
      },
    });
    setConnection("https://providers-dnd.test", "test-jwt");
    accounts = [
      makeAccount("openai-1", "openai", "OpenAI First", 0),
      makeAccount("openai-2", "openai", "OpenAI Second", 1),
      makeAccount("anth-1", "anthropic", "Anthropic First", 0),
      makeAccount("anth-2", "anthropic", "Anthropic Second", 1),
    ];
    reorders = [];
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: string, init?: RequestInit) => {
        const path = new URL(String(input)).pathname;
        const method = init?.method ?? "GET";
        if (path === "/api/ai/providers/reorder" && method === "POST") {
          const { ids } = JSON.parse(String(init?.body ?? "{}")) as { ids: string[] };
          reorders.push(ids);
          accounts = accounts.map((a) => {
            const idx = ids.indexOf(a.id);
            return idx >= 0 ? { ...a, priority: idx } : a;
          });
          return new Response(JSON.stringify(accounts), { status: 200 });
        }
        if (path === "/api/ai/providers") return new Response(JSON.stringify(accounts), { status: 200 });
        if (path === "/api/ai/providers/usage") return new Response(JSON.stringify({ entries: {} }), { status: 200 });
        if (path === "/api/ai/providers/cli-proxy-login")
          return new Response(JSON.stringify({ available: false, providers: [] }), { status: 200 });
        if (path === "/api/model-routing/health") return new Response(JSON.stringify([]), { status: 200 });
        if (path === "/api/cloud/accounts") return new Response(JSON.stringify([]), { status: 200 });
        return new Response(JSON.stringify([]), { status: 200 });
      }),
    );
  });

  afterEach(() => {
    clearConnection();
    resetCurrentUserState();
    vi.restoreAllMocks();
    vi.unstubAllGlobals();
  });

  it("moves the dragged account onto a same-provider sibling and ignores cross-provider drops", async () => {
    const view = render(() => <Providers />);
    await screen.findByText("OpenAI First");

    // Expand OpenAI First to reveal its drag grip.
    fireEvent.click(screen.getByText("OpenAI First").closest("button")!);
    const firstRow = view.container.querySelector('[data-provider-id="openai-1"]')!;
    const secondRow = view.container.querySelector('[data-provider-id="openai-2"]')!;
    const otherProviderRow = view.container.querySelector('[data-provider-id="anth-2"]')!;
    const grip = firstRow.querySelector(".p-rank-grip")!;
    expect(grip).toBeTruthy();

    // Cross-provider drop (openai-1 onto anth-2) must be ignored.
    const crossDt = makeDataTransfer();
    fireEvent.dragStart(grip, { dataTransfer: crossDt });
    fireEvent.drop(otherProviderRow, { dataTransfer: crossDt });
    expect(reorders).toEqual([]);

    // Same-provider drop (openai-1 onto openai-2) must reorder openai-1 after openai-2.
    const sameDt = makeDataTransfer();
    fireEvent.dragStart(grip, { dataTransfer: sameDt });
    fireEvent.dragOver(secondRow, { dataTransfer: sameDt });
    fireEvent.drop(secondRow, { dataTransfer: sameDt });

    await waitFor(() => expect(reorders).toEqual([["openai-2", "openai-1"]]));
  });
});
