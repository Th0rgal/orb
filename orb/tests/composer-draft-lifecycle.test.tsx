import { cleanup, fireEvent, render, screen } from "@solidjs/testing-library";
import { afterEach, expect, it, vi } from "vitest";
import { Composer } from "../src/composer/Composer";
import { readComposerDraft, saveComposerDraft } from "../src/composerDrafts";

vi.mock("../src/composerDrafts", async original => ({
  ...await original<typeof import("../src/composerDrafts")>(),
  readComposerDraft: vi.fn(),
  saveComposerDraft: vi.fn().mockResolvedValue(undefined),
}));
afterEach(() => { cleanup(); vi.clearAllMocks(); });

it("flushes a draft typed before storage hydration when the composer closes", () => {
  vi.mocked(readComposerDraft).mockReturnValue(new Promise(() => {}));
  const view = render(() => <Composer scope="m:quick" placeholder="Reply" busy={false} onSend={() => {}} />);
  fireEvent.input(screen.getByPlaceholderText("Reply"), { target: { value: "Keep my unfinished reply" } });
  view.unmount();
  expect(saveComposerDraft).toHaveBeenCalledWith("m:quick", expect.objectContaining({ text: "Keep my unfinished reply" }));
});

it("does not overwrite an unseen stored draft if the composer closes before loading", () => {
  vi.mocked(readComposerDraft).mockReturnValue(new Promise(() => {}));
  const view = render(() => <Composer scope="m:untouched" placeholder="Reply" busy={false} onSend={() => {}} />);
  view.unmount();
  expect(saveComposerDraft).not.toHaveBeenCalled();
});

it("cancels a pending debounced draft save when a message is sent quickly so remounting stays empty", async () => {
  vi.useFakeTimers();
  try {
    vi.mocked(readComposerDraft).mockResolvedValue(undefined);
    const view = render(() => <Composer scope="m:archived-resume" placeholder="Reply" busy={false} onSend={async () => true} />);
    await vi.waitFor(() => expect(readComposerDraft).toHaveBeenCalledWith("m:archived-resume"));
    const input = screen.getByPlaceholderText("Reply") as HTMLTextAreaElement;
    fireEvent.input(input, { target: { value: "quel est le statut de l’EV bench ?" } });
    fireEvent.keyDown(input, { key: "Enter" });
    await vi.waitFor(() => expect(saveComposerDraft).toHaveBeenCalledWith("m:archived-resume", { text: "", images: [] }));
    vi.mocked(saveComposerDraft).mockClear();
    vi.advanceTimersByTime(250);
    expect(saveComposerDraft).not.toHaveBeenCalled();
    view.unmount();
    expect(saveComposerDraft).not.toHaveBeenCalledWith("m:archived-resume", expect.objectContaining({ text: "quel est le statut de l’EV bench ?" }));
  } finally {
    vi.useRealTimers();
  }
});

