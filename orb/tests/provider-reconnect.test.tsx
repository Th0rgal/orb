import { fireEvent, render, screen, waitFor } from "@solidjs/testing-library";
import { afterEach, expect, it, vi } from "vitest";
import { Providers } from "../src/Providers";
import { clearConnection, setConnection } from "../src/api";

afterEach(() => { clearConnection(); vi.unstubAllGlobals(); vi.restoreAllMocks(); });
it("reconnects a revoked sandboxed-owned Anthropic account using its existing identity", async () => {
  setConnection("http://core.test", "test-token");
  vi.spyOn(window, "open").mockReturnValue(null);
  let connected = false;
  const fetch = vi.fn(async (url: string, options?: RequestInit) => {
    if (url.endsWith("/oauth/callback")) {
      expect(url).toContain("/expired-account/");
      expect(JSON.parse(options!.body as string)).toEqual({ method_index: 0, code: "authorized-code" });
      connected = true;
      return new Response(JSON.stringify({ status: { type: "connected" } }));
    }
    const data = url.endsWith("/cloud/accounts") ? [] : url.endsWith("/providers") ? [{ id: "expired-account", provider_type: "anthropic", name: "Claude account", uses_oauth: true, credential_owner: "sandboxed_sh", account_email: "account@example.test", status: { type: connected ? "connected" : "needs_reauth", reason: connected ? undefined : "Refresh token revoked" } }]
      : url.endsWith("/oauth/authorize") ? { url: "https://example.test/authorize", method: "code", instructions: "Paste the authorization code." }
      : {};
    return new Response(JSON.stringify(data));
  });
  vi.stubGlobal("fetch", fetch);
  render(() => <Providers />);
  fireEvent.click(await screen.findByRole("button", { name: "Actions for Claude account", exact: true }));
  fireEvent.click(screen.getByRole("menuitem", { name: "Reconnect", exact: true }));
  const input = await screen.findByLabelText("Authorization code or redirect URL");
  expect(screen.getByText(/Sign in as account@example.test/)).toBeTruthy();
  fireEvent.input(input, { target: { value: "authorized-code" } });
  fireEvent.click(screen.getByRole("button", { name: "Submit callback" }));
  await waitFor(() => expect(screen.queryByRole("dialog")).toBeNull());
  await screen.findByText("Connected");
  expect(fetch.mock.calls.some(([url, options]) => url.includes("cli-proxy-login") && options?.method === "POST")).toBe(false);
});
it("exposes API key editing and keeps real error details", async () => {
  setConnection("http://core.test", "test-token");
  vi.stubGlobal("fetch", vi.fn(async (url: string) => new Response(JSON.stringify(url.endsWith("/cloud/accounts") ? [] : url.endsWith("/zai/usage") ? {provider_type:"zai",error:"Account unavailable"} : url.endsWith("/minimax/usage") ? {provider_type:"minimax",model_usage:[]} : url.endsWith("/providers")
    ? ["muse", "custom", "minimax", "zai"].map(id => ({ id, name: id, provider_type: id, uses_oauth: false, status: { type: "connected" } }))
    : url.endsWith("/zai/usage") ? {provider_type:"zai",error:"Account unavailable"} : url.endsWith("/minimax/usage") ? {provider_type:"minimax",model_usage:[]} : { entries: { muse: { provider_type: "muse" }, custom: { provider_type: "custom" }, minimax: { provider_type: "minimax", model_usage: [] }, zai: { provider_type: "zai", error: "Account unavailable" } } }))));
  render(() => <Providers />);
  await screen.findAllByText("muse");
  await waitFor(() => expect(screen.getByRole("button", { name: /^zai/ })).toBeTruthy());
  for (const name of ["muse", "custom", "minimax"]) expect(screen.getByRole("button", { name: `Actions for ${name}`, exact: true })).toBeTruthy();
  expect(screen.getByRole("heading", { name: "API keys" }).closest("section")!.querySelectorAll(".p-acc-chev")).toHaveLength(4);
  fireEvent.click(screen.getByRole("button", { name: /^zai/ }));
  expect(await screen.findByText("Account unavailable")).toBeTruthy();
});

it("feeds a Claude authorization code to CLIProxyAPI while preserving the reconnect UUID", async () => {
  const id = "3be8246a-6fa4-41a5-948c-f0d333e6e247";
  setConnection("http://core.test", "test-token");
  vi.spyOn(window, "open").mockReturnValue(null);
  const fetch = vi.fn(async (url: string, options?: RequestInit) => {
    if (url.endsWith("/cli-proxy-login")) {
      if (options?.method !== "POST") return new Response(JSON.stringify({available:true,providers:[]}));
      expect(JSON.parse(options!.body as string)).toEqual({ provider: "anthropic", provider_id: id });
      return new Response(JSON.stringify({ session_id: "proxy-session", auth_url: "https://claude.ai/oauth/authorize", flow: "code", instructions: "Paste the Claude authorization code." }));
    }
    if (url.endsWith("/callback")) {
      expect(JSON.parse(options!.body as string)).toEqual({ url: "approved-code#state" });
      return new Response(JSON.stringify({ status: "completed" }));
    }
    return new Response(JSON.stringify(url.endsWith("/cloud/accounts") ? [] : url.endsWith("/providers") ? [{ id, provider_type: "anthropic", name: "Proxy Claude", enabled: true, uses_oauth: true, credential_owner: "cli_proxy", status: { type: "needs_reauth" } }] : {}));
  });
  vi.stubGlobal("fetch", fetch);
  render(() => <Providers />);
  fireEvent.click(await screen.findByRole("button", { name: "Actions for Proxy Claude", exact: true }));
  fireEvent.click(screen.getByRole("menuitem", { name: "Reconnect", exact: true }));
  const input = await screen.findByLabelText("Authorization code or redirect URL");
  expect(screen.getByText("Paste the Claude authorization code.")).toBeTruthy();
  fireEvent.input(input, { target: { value: "approved-code#state" } });
  fireEvent.click(screen.getByRole("button", { name: "Submit callback" }));
  await waitFor(() => expect(screen.queryByRole("dialog")).toBeNull());
  expect(fetch.mock.calls.some(([url]) => url.includes("/oauth/"))).toBe(false);
});

it("adds a second subscription through the backend capability list without a reconnect target", async () => {
  setConnection("http://core.test", "test-token");
  vi.spyOn(window, "open").mockReturnValue(null);
  const requests: RequestInit[] = [];
  vi.stubGlobal("fetch", vi.fn(async (url: string, options?: RequestInit) => {
    if (url.endsWith("/cli-proxy-login")) {
      if (options?.method === "POST") {
        requests.push(options);
        return new Response(JSON.stringify({session_id:"new-session",auth_url:"https://example.test/login",flow:"code",instructions:"Approve the new account."}));
      }
      return new Response(JSON.stringify({available:true,providers:[{id:"anthropic",name:"Claude Pro/Max"}]}));
    }
    if (url.endsWith("/callback")) return new Response(JSON.stringify({status:"completed"}));
    return new Response(JSON.stringify(url.endsWith("/providers") || url.endsWith("/cloud/accounts") ? [] : {}));
  }));
  render(() => <Providers />);
  const add = await screen.findByRole("button", {name:"Add subscription account"});
  await waitFor(() => expect((add as HTMLButtonElement).disabled).toBe(false));
  fireEvent.click(add);
  expect(screen.getByRole("radio", {name:/Mistral Vibe/i})).toBeTruthy();
  fireEvent.click(screen.getByRole("button", {name:"Continue in browser"}));
  const input = await screen.findByLabelText("Authorization code or redirect URL");
  expect(JSON.parse(requests[0].body as string)).toEqual({provider:"anthropic"});
  fireEvent.input(input,{target:{value:"approved-code"}});
  fireEvent.click(screen.getByRole("button",{name:"Submit callback"}));
  await waitFor(() => expect(screen.queryByRole("dialog")).toBeNull());
});

it("warns that removing a combined provider also deletes its independent API key", async () => {
  setConnection("http://core.test", "test-token");
  let deleted = false;
  vi.stubGlobal("fetch", vi.fn(async (url: string, options?: RequestInit) => {
    if (options?.method === "DELETE") { deleted = true; return new Response(JSON.stringify({status:"ok"})); }
    const data = url.endsWith("/providers") ? [{id:"combined",name:"Combined account",provider_type:"anthropic",uses_oauth:true,has_api_key:true,credential_owner:"cli_proxy",status:{type:"connected"}}] : url.endsWith("/cloud/accounts") ? [] : {};
    return new Response(JSON.stringify(data));
  }));
  render(() => <Providers />);
  fireEvent.click(await screen.findByRole("button", {name:"Actions for Combined account",exact:true}));
  fireEvent.click(screen.getByRole("menuitem", {name:"Remove provider…",exact:true}));
  expect(screen.getByText(/any independent API key saved on this provider/)).toBeTruthy();
  expect(deleted).toBe(false);
  fireEvent.click(screen.getByRole("button", {name:"Remove provider and credentials",exact:true}));
  await waitFor(() => expect(screen.queryByRole("dialog")).toBeNull());
  expect(deleted).toBe(true);
});

it("connects Mistral Vibe through its own browser flow and polls without a callback", async () => {
  setConnection("http://core.test", "test-token");
  vi.spyOn(window, "open").mockReturnValue(null);
  const fetch = vi.fn(async (url: string, options?: RequestInit) => {
    if (url.endsWith("/cli-proxy-login")) return new Response(JSON.stringify({available:true,providers:[{id:"mistral",name:"Mistral Vibe"}]}));
    if (url.endsWith("/mistral-login")) {
      expect(JSON.parse(options!.body as string)).toEqual({provider:"mistral"});
      return new Response(JSON.stringify({session_id:"mistral-test",auth_url:"https://console.mistral.ai/vibe/sign-in/test",flow:"device",instructions:"Approve Mistral Vibe."}));
    }
    if (url.endsWith("/mistral-login/mistral-test")) return new Response(JSON.stringify({status:"completed"}));
    return new Response(JSON.stringify(url.endsWith("/providers") || url.endsWith("/cloud/accounts") ? [] : {}));
  });
  vi.stubGlobal("fetch", fetch);
  render(() => <Providers />);
  const add = await screen.findByRole("button", {name:"Add subscription account"});
  await waitFor(() => expect((add as HTMLButtonElement).disabled).toBe(false));
  fireEvent.click(add);
  fireEvent.click(screen.getByRole("button", {name:"Continue in browser"}));
  expect(await screen.findByText("Approve Mistral Vibe.")).toBeTruthy();
  expect(screen.queryByLabelText("Authorization code or redirect URL")).toBeNull();
  await waitFor(() => expect(screen.queryByRole("dialog")).toBeNull(), {timeout:4000});
  expect(fetch.mock.calls.some(([url]) => url.endsWith("/callback"))).toBe(false);
});

it("reconnects a backend-owned Mistral subscription without changing its account ID", async () => {
  const id = "3be8246a-6fa4-41a5-948c-f0d333e6e247";
  setConnection("http://core.test", "test-token");
  vi.spyOn(window, "open").mockReturnValue(null);
  let started = false;
  vi.stubGlobal("fetch", vi.fn(async (url: string, options?: RequestInit) => {
    if (url.endsWith("/mistral-login")) {
      expect(JSON.parse(options!.body as string)).toEqual({provider:"mistral",provider_id:id});
      started = true;
      return new Response(JSON.stringify({session_id:"mistral-reconnect",auth_url:"https://console.mistral.ai/vibe/sign-in/test",flow:"device"}));
    }
    const data = url.endsWith("/providers") ? [{id,name:"Mistral Vibe",provider_type:"mistral",uses_oauth:true,credential_owner:"sandboxed_sh",enabled:true,status:{type:"connected"}}] : url.endsWith("/cli-proxy-login") ? {available:true,providers:[]} : url.endsWith("/cloud/accounts") ? [] : {};
    return new Response(JSON.stringify(data));
  }));
  render(() => <Providers />);
  fireEvent.click(await screen.findByRole("button", {name:"Actions for Mistral Vibe",exact:true}));
  fireEvent.click(screen.getByRole("menuitem", {name:"Re-authenticate",exact:true}));
  await waitFor(() => expect(started).toBe(true));
  expect(screen.queryByLabelText("Authorization code or redirect URL")).toBeNull();
});

it("includes Mistral Vibe in subscription options even if the backend capability list omits it", async () => {
  setConnection("http://core.test", "test-token");
  vi.stubGlobal("fetch", vi.fn(async (url: string) => {
    if (url.endsWith("/cli-proxy-login")) {
      return new Response(JSON.stringify({
        available: true,
        providers: [
          { id: "anthropic", name: "Claude Pro/Max" },
          { id: "openai", name: "ChatGPT Plus/Pro" },
          { id: "xai", name: "SuperGrok" },
          { id: "kimi", name: "Kimi Code" },
          { id: "antigravity", name: "Google Antigravity" },
        ],
      }));
    }
    return new Response(JSON.stringify(url.endsWith("/providers") || url.endsWith("/cloud/accounts") ? [] : {}));
  }));
  render(() => <Providers />);
  const add = await screen.findByRole("button", { name: "Add subscription account" });
  await waitFor(() => expect((add as HTMLButtonElement).disabled).toBe(false));
  fireEvent.click(add);
  expect(screen.getByRole("radio", { name: /Mistral Vibe/ })).toBeTruthy();
});

it("connects Muse Code through device login and reports an inactive subscription without API fallback", async () => {
  setConnection("http://core.test", "test-token");
  vi.spyOn(window, "open").mockReturnValue(null);
  const calls: { url: string; options?: RequestInit }[] = [];
  vi.stubGlobal("fetch", vi.fn(async (url: string, options?: RequestInit) => {
    calls.push({url, options});
    const body = url.endsWith("/cli-proxy-login")
      ? options?.method === "POST"
        ? {session_id:"muse-login",auth_url:"https://auth.meta.com/oauth/device/",flow:"device",instructions:"Approve code TEST in your browser."}
        : {available:true,providers:[{id:"muse-code",name:"Muse Code"}]}
      : url.endsWith("/cli-proxy-login/muse-login")
        ? {status:"failed",message:"This Meta account has no active Muse Code subscription."}
        : url.endsWith("/providers") || url.endsWith("/cloud/accounts") ? [] : {};
    return new Response(JSON.stringify(body));
  }));
  render(() => <Providers />);
  const add = await screen.findByRole("button", {name:"Add subscription account"});
  await waitFor(() => expect((add as HTMLButtonElement).disabled).toBe(false));
  fireEvent.click(add);
  fireEvent.click(screen.getByRole("radio", {name:/Muse Code/}));
  fireEvent.click(screen.getByRole("button", {name:"Continue in browser"}));
  expect(await screen.findByText("Approve code TEST in your browser.")).toBeTruthy();
  await screen.findByText("This Meta account has no active Muse Code subscription.", {}, {timeout:5000});
  expect(calls.filter(c => c.options?.method === "POST" && c.url.endsWith("/providers"))).toHaveLength(0);
  expect(JSON.parse(calls.find(c => c.options?.method === "POST" && c.url.endsWith("/cli-proxy-login"))!.options!.body as string)).toEqual({provider:"muse-code"});
}, 10000);
