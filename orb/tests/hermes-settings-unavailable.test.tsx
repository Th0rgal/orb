import { render, screen } from "@solidjs/testing-library";
import { afterEach, expect, it, vi } from "vitest";
import { HermesSettings } from "../src/HermesSettings";
import { clearConnection, setConnection } from "../src/api";

afterEach(() => { clearConnection(); vi.unstubAllGlobals(); vi.restoreAllMocks(); });

it("explains a Core without Hermes instead of reporting an error", async () => {
  setConnection("http://core.test", "test-token");
  vi.stubGlobal("fetch", vi.fn(async () => new Response("Hermes is not connected for this account", { status: 403 })));
  render(() => <HermesSettings />);
  expect(await screen.findByText("Assistant not set up on this Core")).toBeTruthy();
  expect(screen.getByText(/HERMES_CLOUD_OWNER/)).toBeTruthy();
  expect(screen.queryByRole("alert")).toBeNull();
  expect(screen.queryByText("Loading Hermes settings…")).toBeNull();
});
