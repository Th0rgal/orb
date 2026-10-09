import { fireEvent, render, screen, waitFor } from "@solidjs/testing-library";
import { beforeEach, expect, it, vi } from "vitest";
import { Composer } from "../src/App";

const catalog = vi.hoisted(() => ({ supported: true }));
vi.mock("../src/harness-models", () => ({
  destinationHarnessChoices: () => catalog.supported ? [{
    backend: { id: "vibe", name: "Mistral Vibe", native_plan: true },
    models: [{ value: "mistral/mistral-vibe-cli-latest", label: "Mistral Vibe" }],
  }] : [],
}));
beforeEach(() => { catalog.supported = true; });

it("offers and submits a Vibe plan on a remote execution node", async () => {
  const send = vi.fn();
  render(() => <Composer placeholder="Task" uploadTarget="ashur" backend="vibe" picker={false} busy={false} onSend={send} />);
  const input = screen.getByPlaceholderText("Task") as HTMLTextAreaElement;
  fireEvent.input(input, { target: { value: "/pl" } });
  expect(screen.getByText("Plan")).toBeTruthy();
  fireEvent.input(input, { target: { value: "/plan Inspect the repository" } });
  fireEvent.click(screen.getByTitle("Send"));
  await waitFor(() => expect(send).toHaveBeenCalledWith("/plan Inspect the repository", []));
});

it.each(["vibe", "unknown", "codex"])("keeps unsupported remote plans gated for %s", async backend => {
  catalog.supported = false;
  const send = vi.fn();
  render(() => <Composer placeholder="Task" uploadTarget="ashur" backend={backend} picker={false} busy={false} onSend={send} />);
  const input = screen.getByPlaceholderText("Task") as HTMLTextAreaElement;
  fireEvent.input(input, { target: { value: "/plan Inspect the repository" } });
  fireEvent.click(screen.getByTitle("Send"));
  await screen.findByRole("alert");
  expect(send).not.toHaveBeenCalled();
  expect(input.value).toBe("/plan Inspect the repository");
});
