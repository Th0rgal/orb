import {createSignal,useContext} from "solid-js";
import {FileReferenceContext,type ReferenceResolver} from "../src/fileReferenceContext";
import { render, fireEvent, waitFor } from "@solidjs/testing-library";
import { it, expect, vi } from "vitest";
import { FilePanelProvider, FilePanelButton, lazyRetry } from "../src/FilePanel";
import { MdView } from "../src/Markdown";
vi.mock("../src/api", async (importOriginal) => ({
  ...(await importOriginal<typeof import("../src/api")>()),
  // This fixture has no controller; never let optional source discovery hit
  // the real API and make reference resolution depend on network latency.
  getProjectController: vi.fn(async () => ({ settings: {} })),
  getProjectCron: vi.fn(async () => ({ settings: {} })),
  api: vi.fn(async (_path: string, init: RequestInit) => {
    const q = JSON.parse(String(init.body));
    if (q.action === "roots")
      return {
        sources: [{ id: "workspace", label: "Workspace", available: true }],
      };
    if (q.action === "list")
      return { entries: [{ name: "note.md", path: "note.md", kind: "file" }] };
    if (q.action === "resolve")
      return {
        results: q.paths.map((reference: string) => ({
          reference,
          matches:
            reference === "note.md"
              ? [{ name: "note.md", path: "note.md", kind: "file" }]
              : [],
        })),
      };
    if (q.action === "read")
      return {
        content: "# Readable note\n\nEvidence.",
        size: 27,
        binary: false,
        truncated: false,
      };
    return { entries: [] };
  }),
}));
it("opens a detected reference beside a mounted chat and switches Markdown with the focused shortcut", async () => {
  const { container, getByRole, getByText } = render(() => (
    <div class="app">
      <FilePanelProvider scope={{ project: "test" }}>
        <div class="chat">
          <input aria-label="Draft" value="keep this" />
          <MdView text="Read `note.md`." />
          <FilePanelButton />
        </div>
      </FilePanelProvider>
    </div>
  ));
  await waitFor(() =>
    expect(container.querySelector(".file-reference")).not.toBeNull(),
  );
  const draft = getByRole("textbox", { name: "Draft" });
  fireEvent.click(container.querySelector(".file-reference")!);
  await waitFor(() => expect(getByText("Readable note")).toBeTruthy());
  expect(getByRole("textbox", { name: "Draft" })).toBe(draft);
  const panel = container.querySelector<HTMLElement>(".file-panel")!;
  panel.focus();
  fireEvent.keyDown(window, { key: "/", metaKey: true });
  expect(container.querySelector(".file-source-code")).not.toBeNull();
  fireEvent.click(getByRole("button", { name: "Close files" }));
  expect(container.querySelector(".file-panel")).toBeNull();
  expect(draft).toHaveProperty("value", "keep this");
});

it("only resolves completed assistant text and updates changed references", async () => {
  const { createSignal } = await import("solid-js");
  const { Transcript } = await import("../src/Transcript");
  const { FileReferenceContext, FileReference } =
    await import("../src/fileReferenceContext");
  const resolve = vi.fn(async (raw: string) => [
    { source: "workspace", path: raw, name: raw, kind: "file" },
  ]);
  const [live, setLive] = createSignal(true);
  const [raw, setRaw] = createSignal("first.md");
  const { container } = render(() => (
    <FileReferenceContext.Provider
      value={{ resolve, open: () => {}, search: () => {} }}
    >
      <Transcript
        items={[{ kind: "text", text: "Read `note.md`.", live: live() }]}
      />
      <FileReference raw={raw()} />
    </FileReferenceContext.Provider>
  ));
  await waitFor(() => expect(resolve).toHaveBeenCalledWith("first.md"));
  expect(resolve).not.toHaveBeenCalledWith("note.md");
  setLive(false);
  await waitFor(() => expect(resolve).toHaveBeenCalledWith("note.md"));
  setRaw("second.md");
  await waitFor(() => expect(resolve).toHaveBeenCalledWith("second.md"));
  await waitFor(() =>
    expect(
      container.querySelector('[title="workspace: second.md"]'),
    ).not.toBeNull(),
  );
});

it("reschedules file lookups after a scope change cancels a pending batch",async()=>{
 const [project,setProject]=createSignal('before');
 let resolver!:ReferenceResolver;
 const Capture=()=>{resolver=useContext(FileReferenceContext)!;return null;};
 render(()=><FilePanelProvider scope={{project:project()}}><Capture/></FilePanelProvider>);
 const old=resolver.resolve('note.md');
 setProject('after');
 expect(await old).toEqual([]);
 const fresh=await resolver.resolve('note.md');
 expect(fresh).toEqual([expect.objectContaining({name:'note.md',source:'workspace'})]);
});

it("lazyRetry reactivity mounts the recovered component when reset() is clicked inside ErrorBoundary", async () => {
  const { ErrorBoundary, Show, Suspense } = await import("solid-js");
  let attempts = 0;
  const retryable = lazyRetry(async () => {
    attempts += 1;
    if (attempts === 1) throw new TypeError("Importing a module script failed.");
    return { default: (p: { label: string }) => <div data-testid="recovered-pdf">{p.label}</div> };
  });
  const { getByRole, getByTestId } = render(() => (
    <ErrorBoundary
      fallback={(err, reset) => (
        <div role="alert">
          <span>{err instanceof Error ? err.message : String(err)}</span>
          <button onClick={() => { retryable.reset(); reset(); }}>Retry</button>
        </div>
      )}
    >
      <Suspense fallback={<p>Loading PDF viewer…</p>}>
        <Show when={retryable.Component()} keyed>
          {(Comp) => <Comp label="PDF Ready" />}
        </Show>
      </Suspense>
    </ErrorBoundary>
  ));
  await waitFor(() => expect(getByRole("alert")).toBeTruthy());
  fireEvent.click(getByRole("button", { name: "Retry" }));
  await waitFor(() => expect(getByTestId("recovered-pdf").textContent).toBe("PDF Ready"));
  expect(attempts).toBe(2);
});
