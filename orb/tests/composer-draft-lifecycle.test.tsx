import { cleanup, fireEvent, render, screen } from "@solidjs/testing-library";
import { afterEach, expect, it, vi } from "vitest";
import { Composer } from "../src/App";
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
