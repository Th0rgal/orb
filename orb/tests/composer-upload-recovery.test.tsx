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

it("grants only the confirmed folder files to the desktop and revokes the grant when done", async () => {
  const handlers = new Map<string, (event: any) => void>();
  const calls: Array<[string, any]> = [];
  const invoke = vi.fn(async (cmd: string, args: any) => { calls.push([cmd, args]); return cmd === "read_upload_file" ? btoa("x") : cmd === "grant_upload_folder" ? 2 : cmd === "stat_upload_file" ? { size: 1, modified: 0 } : undefined; });
  (window as any).__TAURI__ = { core: { invoke }, event: { listen: vi.fn(async (name, handler) => { handlers.set(name, handler); return () => handlers.delete(name); }) } };
  vi.stubGlobal("fetch", vi.fn(async (url: string) => new Response(JSON.stringify(String(url).endsWith("/blobs") ? { hash: "h" } : String(url).endsWith("/operations") ? { conflict: false } : []))));
  vi.mocked(readComposerDraft).mockResolvedValue(undefined);
  const view = render(() => <Composer scope="m:grant" projectSlug="pilot" uploadTarget="old-agent" placeholder="Reply" busy={false} onSend={() => true} />);
  const el = view.container.querySelector(".composer") as HTMLElement;
  vi.spyOn(el, "getClientRects").mockReturnValue([{}] as unknown as DOMRectList);
  vi.spyOn(el, "getBoundingClientRect").mockReturnValue({ left: 0, right: 400, top: 0, bottom: 400 } as DOMRect);
  await waitFor(() => expect(handlers.has("orb-upload-drop")).toBe(true));
  handlers.get("orb-upload-drop")!({ payload: { paths: [], x: 10, y: 10, folder: { batch: "offer-1", files: [
    { name: "a.pdf", path: "/U/Aulas/a.pdf", relative_path: "Aulas/a.pdf", size: 1 },
    { name: "b.pdf", path: "/U/Aulas/sub/b.pdf", relative_path: "Aulas/sub/b.pdf", size: 1 },
  ] } } });
  const input = screen.getByPlaceholderText("Reply") as HTMLTextAreaElement;
  await waitFor(() => expect(input.value).toMatch(/^@attachments\/[0-9a-f-]+\/Aulas\/ $/));
  const files = calls.filter(([cmd]) => cmd !== "voice_capability");
  const order = files.map(([cmd]) => cmd);
  expect(order[0]).toBe("grant_upload_folder");
  expect(files[0][1]).toEqual({ batch: "offer-1", relativePaths: ["Aulas/a.pdf", "Aulas/sub/b.pdf"] });
  expect(order.at(-1)).toBe("revoke_upload_folder");
});
