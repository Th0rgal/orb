import { cleanup, fireEvent, render, screen, waitFor } from "@solidjs/testing-library";
import { afterEach, expect, it, vi } from "vitest";
import { Composer } from "../src/composer/Composer";
import { readComposerDraft } from "../src/composerDrafts";

vi.mock("../src/composerDrafts", async original => ({
  ...await original<typeof import("../src/composerDrafts")>(),
  readComposerDraft: vi.fn(),
  saveComposerDraft: vi.fn().mockResolvedValue(undefined),
}));
afterEach(() => { cleanup(); vi.clearAllMocks(); vi.unstubAllGlobals(); delete (window as any).__TAURI__; });

const PATH = "attachments/497dfe42-8ff1-44a8-b0f8-6b74a4866833/Questões_PPLA_air_Law_key (1).pdf";

it("keeps the draft sendable when a restored attachment can no longer be read", async () => {
  // After a restart the desktop refuses to re-read a file chosen in the previous session.
  (window as any).__TAURI__ = { core: { invoke: vi.fn(async () => { throw "Choose this file again using the file picker"; }) }, event: { listen: vi.fn(async () => () => {}) } };
  vi.stubGlobal("fetch", vi.fn(async () => new Response("[]")));
  vi.mocked(readComposerDraft).mockResolvedValue({
    text: `Explique @"${PATH}" por favor`, images: [],
    uploads: [{ source: { name: "Questões_PPLA_air_Law_key (1).pdf", localPath: "/Users/t/Questões_PPLA_air_Law_key (1).pdf" }, path: PATH, destination: "context:pilot", connection: 0, endpoint: "https://previous-backend.example" }],
  });
  const send = vi.fn(async () => true), sendError = vi.fn();
  render(() => <Composer scope="m:old-agent" projectSlug="pilot" uploadTarget="old-agent" placeholder="Reply" busy={false} onSend={send} onSendError={sendError} />);
  const input = screen.getByPlaceholderText("Reply") as HTMLTextAreaElement;
  await waitFor(() => expect(input.value).toContain(PATH));
  fireEvent.keyDown(input, { key: "Enter" });
  await waitFor(() => expect(screen.getByText(/File no longer available — re-attach: Questões_PPLA_air_Law_key \(1\)\.pdf/)).toBeTruthy());
  expect(send).not.toHaveBeenCalled();
  expect(sendError).not.toHaveBeenCalled();
  expect(screen.queryByRole("alert")).toBeNull();
  expect(input.value).toBe("Explique por favor");
  fireEvent.keyDown(input, { key: "Enter" });
  await waitFor(() => expect(send).toHaveBeenCalledWith("Explique por favor", []));
});

it("sends a restored attachment that is already uploaded without touching the original file", async () => {
  const invoke = vi.fn(async () => { throw "Choose this file again using the file picker"; });
  (window as any).__TAURI__ = { core: { invoke }, event: { listen: vi.fn(async () => () => {}) } };
  vi.stubGlobal("fetch", vi.fn(async () => new Response("[]")));
  const { getApiUrl } = await import("../src/api");
  vi.mocked(readComposerDraft).mockResolvedValue({
    text: `Explique @"${PATH}"`, images: [],
    uploads: [{ source: { name: "Questões_PPLA_air_Law_key (1).pdf", localPath: "/Users/t/q.pdf" }, path: PATH, destination: "context:pilot", connection: 0, endpoint: getApiUrl() }],
  });
  const send = vi.fn(async () => true);
  render(() => <Composer scope="m:old-agent-2" projectSlug="pilot" uploadTarget="old-agent" placeholder="Reply" busy={false} onSend={send} />);
  const input = screen.getByPlaceholderText("Reply") as HTMLTextAreaElement;
  await waitFor(() => expect(input.value).toContain(PATH));
  fireEvent.keyDown(input, { key: "Enter" });
  await waitFor(() => expect(send).toHaveBeenCalledWith(`Explique @"${PATH}"`, []));
  expect(invoke).not.toHaveBeenCalled();
});
