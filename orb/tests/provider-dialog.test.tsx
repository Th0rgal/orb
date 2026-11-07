import { fireEvent, render, screen, waitFor, within } from "@solidjs/testing-library";
import { afterEach, expect, it, vi } from "vitest";
import { Providers } from "../src/Providers";
import { clearConnection, setConnection } from "../src/api";

afterEach(() => { clearConnection(); vi.unstubAllGlobals(); vi.restoreAllMocks(); });
it("keeps the login modal open during callback submission and exposes a rejected login", async () => {
  setConnection("http://core.test", "test-token");
  vi.spyOn(window, "open").mockReturnValue(null);
  let finish!: (response: Response) => void;
  let submissions = 0;
  vi.stubGlobal("fetch", vi.fn(async (url: string) => {
    if (url.endsWith("/callback")) {
      submissions++;
      return new Promise<Response>(resolve => { finish = resolve; });
    }
    const data = url.endsWith("/providers")
      ? [{ id: "test", provider_type: "openai", name: "Test account", enabled: true, uses_oauth: true, credential_owner: "cli_proxy", status: { type: "connected" } }]
      : url.endsWith("/cli-proxy-login")
      ? { session_id: "test-login", auth_url: "https://example.test/login", flow: "redirect" }
      : { status: "pending" };
    return new Response(JSON.stringify(data));
  }));
  render(() => <Providers />);
  fireEvent.click(await screen.findByRole("button", { name: "Actions for Test account", exact: true }));
  fireEvent.click(screen.getByRole("menuitem", { name: "Re-authenticate", exact: true }));
  const input = await screen.findByLabelText("Redirect URL (http://localhost:…)");
  fireEvent.input(input, { target: { value: "http://localhost:54545/callback?code=test" } });
  fireEvent.keyDown(input, { key: "Enter", isComposing: true });
  expect(submissions).toBe(0);
  fireEvent.keyDown(input, { key: "Enter" });
  fireEvent.keyDown(input, { key: "Enter" });
  fireEvent.keyDown(input, { key: "Escape" });
  expect(submissions).toBe(1);
  expect((screen.getByRole("button", { name: "Close", exact: true }) as HTMLButtonElement).disabled).toBe(true);
  expect((screen.getByRole("button", { name: "Cancel", exact: true }) as HTMLButtonElement).disabled).toBe(true);
  finish(new Response(JSON.stringify({ status: "failed", message: "Callback rejected" })));
  await waitFor(() => expect(within(screen.getByRole("dialog")).getByRole("alert").textContent).toContain("Callback rejected"));
  expect((input as HTMLInputElement).value).toBe("http://localhost:54545/callback?code=test");
  fireEvent.click(screen.getAllByRole("button", { name: "Close", exact: true })[0]);
  expect(screen.getByRole("button", {name:"Keep editing"})).toBeTruthy();
  fireEvent.click(screen.getByRole("button", {name:"Discard changes"}));
  await waitFor(() => expect(screen.queryByRole("dialog")).toBeNull());
});

it("saves custom provider pacing limits without requiring a replacement API key", async () => {
  setConnection("http://core.test", "test-token");
  const puts: any[] = [];
  vi.stubGlobal("fetch", vi.fn(async (url: string, init?: RequestInit) => {
    const method = init?.method || "GET";
    if (method === "PUT" && url.includes("/api/ai/providers/eth-foundation")) {
      const body = JSON.parse(init!.body as string);
      puts.push(body);
      return new Response(JSON.stringify({ id: "eth-foundation", ...body }));
    }
    const data = url.endsWith("/providers")
      ? [{
          id: "eth-foundation",
          provider_type: "custom",
          name: "Ethereum Foundation",
          enabled: true,
          has_api_key: true,
          uses_oauth: false,
          base_url: "https://inference.ethereum.foundation/v1",
          rpm_limit: 300,
          status: { type: "connected" },
        }]
      : { entries: {} };
    return new Response(JSON.stringify(data));
  }));
  render(() => <Providers />);
  expect(await screen.findByText("300 RPM")).toBeTruthy();
  fireEvent.click(screen.getByRole("button", { name: "Actions for Ethereum Foundation", exact: true }));
  fireEvent.click(screen.getByRole("menuitem", { name: "Edit API key", exact: true }));
  const concInput = await screen.findByLabelText("Max concurrent requests (optional)");
  fireEvent.input(concInput, { target: { value: "8" } });
  fireEvent.click(screen.getByRole("button", { name: "Save", exact: true }));
  await waitFor(() => expect(puts.length).toBe(1));
  await waitFor(() => expect(screen.queryByRole("dialog")).toBeNull());
  expect(puts[0]).toEqual({
    name: "Ethereum Foundation",
    base_url: "https://inference.ethereum.foundation/v1",
    rpm_limit: 300,
    max_concurrency: 8,
  });

  // Clearing a previously configured rpm_limit sends explicit null while omitting untouched unset caps.
  fireEvent.click(await screen.findByRole("button", { name: "Actions for Ethereum Foundation", exact: true }));
  fireEvent.click(screen.getByRole("menuitem", { name: "Edit API key", exact: true }));
  const rpmInput = await screen.findByLabelText("Requests / min limit (optional)");
  fireEvent.input(rpmInput, { target: { value: "" } });
  fireEvent.click(screen.getByRole("button", { name: "Save", exact: true }));
  await waitFor(() => expect(puts.length).toBe(2));
  expect(puts[1]).toEqual({
    name: "Ethereum Foundation",
    base_url: "https://inference.ethereum.foundation/v1",
    rpm_limit: null,
  });
});
