import { describe, it, expect } from "vitest";
import {
  antigravityBrainReference,
  contextReferencePath,
  parseFileTarget,
  splitFileReferences,
  relativeFilePath,
} from "../src/fileResources";
describe("file references", () => {
  it.each([
    "audit/guarantees.yaml",
    "/workspaces/mission/repo/notes.md",
    "proof.lean:42",
    "proof.lean:42:7",
    "proof.lean:42-50",
    "proof.lean#L42",
    "proof.lean#L42C3-L50C10",
    "file:///Users/thomas/.orb/project-context/ca68973cf8de2cb8952d0d457d202e044a678eddc50ccf8e7a975192d7210322/6754af9632a2745e85c293e5aac0863370d9bd3330b9938c00cadfd215227d77/verity-core/files/Context/Morpho.md",
    "A folder/Note.md",
  ])("recognizes %s", (raw) => expect(parseFileTarget(raw)).not.toBeNull());
  it.each([
    "https://example.com/file.md",
    "javascript:alert(1)",
    "file:///etc/passwd",
    "file://other-host/tmp/notes.md",
    "/srv/.../note.md",
    "/srv/…/note.md",
    "hello world",
  ])("rejects %s", (raw) => expect(parseFileTarget(raw)).toBeNull());
  it("separates line from identity", () => {
    expect(parseFileTarget("audit/proof.lean:42:7")).toEqual({
      path: "audit/proof.lean",
      line: 42,
    });
    expect(parseFileTarget("src/main.rs:42-58")).toEqual({
      path: "src/main.rs",
      line: 42,
    });
    expect(parseFileTarget("file:///workspace/src/main.rs#L17-L44")).toEqual({
      path: "/workspace/src/main.rs",
      line: 17,
    });
  });
  it("maps materialized project-context paths back to project-relative paths", async () => {
    expect(
      contextReferencePath(
        "/Users/thomas/.orb/project-context/ca68973cf8de2cb8952d0d457d202e044a678eddc50ccf8e7a975192d7210322/6754af9632a2745e85c293e5aac0863370d9bd3330b9938c00cadfd215227d77/verity-core/files/Context/Morpho.md",
        "verity-core",
      ),
    ).toBe("Context/Morpho.md");
    expect(
      contextReferencePath(
        "/var/lib/sandboxed-node/project-context/ca68973cf8de2cb8952d0d457d202e044a678eddc50ccf8e7a975192d7210322/verity-core/files/Context/Morpho.md",
        "verity-core",
      ),
    ).toBe("Context/Morpho.md");
    expect(
      contextReferencePath(
        "/run/sandboxed-context/verity-core/Context/Morpho.md",
        "verity-core",
      ),
    ).toBe("Context/Morpho.md");
    expect(
      contextReferencePath(
        "/run/sandboxed-context/other-project/Context/Morpho.md",
        "verity-core",
      ),
    ).toBeNull();
  });
  it("resolves materialized project-context paths through createFileClient while preserving original reference keys", async () => {
    const { createFileClient } = await import("../src/fileResources");
    const calls: unknown[] = [];
    const origFetch = globalThis.fetch;
    globalThis.fetch = (async (_url: RequestInfo | URL, init?: RequestInit) => {
      const body = JSON.parse(String(init?.body ?? "{}"));
      calls.push(body);
      if (body.action === "roots") {
        return new Response(
          JSON.stringify({
            sources: [
              { id: "context", label: "Project context", available: true },
            ],
          }),
          { status: 200 },
        );
      }
      return new Response(
        JSON.stringify({
          results: (body.paths ?? []).map((p: string) => ({
            reference: p,
            matches:
              p === "Context/Morpho.md"
                ? [{ name: "Morpho.md", path: "Context/Morpho.md", kind: "file" }]
                : [],
          })),
        }),
        { status: 200 },
      );
    }) as typeof fetch;
    try {
      const client = createFileClient({ project: "verity-core" });
      await client.roots();
      const raw =
        "/Users/thomas/.orb/project-context/ca68973cf8de2cb8952d0d457d202e044a678eddc50ccf8e7a975192d7210322/6754af9632a2745e85c293e5aac0863370d9bd3330b9938c00cadfd215227d77/verity-core/files/Context/Morpho.md";
      const reply = await client.call("context", {
        action: "resolve",
        paths: [raw],
      });
      const resolveCall = (calls as { action?: string }[]).find(
        (c) => c.action === "resolve",
      );
      expect(resolveCall).toMatchObject({
        source: "context",
        action: "resolve",
        paths: ["Context/Morpho.md"],
      });
      expect(reply.results).toEqual([
        {
          reference: raw,
          matches: [
            { name: "Morpho.md", path: "Context/Morpho.md", kind: "file" },
          ],
        },
      ]);
    } finally {
      globalThis.fetch = origFetch;
    }
  });
  it("maps Antigravity brain artifact paths and rejects traversal", () => {
    expect(
      antigravityBrainReference(
        "/home/thomas/.gemini/antigravity-cli/brain/a9d747d2-e45e-4308-b5e3-a79dd02188ce/razr_bonsai_demo.mp4",
      ),
    ).toEqual({
      root: "/home/thomas/.gemini/antigravity-cli/brain/a9d747d2-e45e-4308-b5e3-a79dd02188ce",
      rel: "razr_bonsai_demo.mp4",
    });
    expect(
      antigravityBrainReference(
        "/Users/thomas/.gemini/antigravity/brain/conv-1/scratch/clip.mp4",
      ),
    ).toEqual({
      root: "/Users/thomas/.gemini/antigravity/brain/conv-1",
      rel: "scratch/clip.mp4",
    });
    expect(
      antigravityBrainReference(
        "/home/thomas/.gemini/antigravity-cli/brain/conv-1/../../antigravity-oauth-token",
      ),
    ).toBeNull();
    expect(antigravityBrainReference("/home/thomas/work/nixos/flake.nix")).toBeNull();
  });
  it("resolves local Antigravity brain file links via mounted local root without duplicates", async () => {
    const { createFileClient } = await import("../src/fileResources");
    const invokes: { cmd: string; args: Record<string, unknown> }[] = [];
    const origTauri = (window as unknown as { __TAURI_INTERNALS__?: unknown }).__TAURI_INTERNALS__;
    const origFetch = globalThis.fetch;
    (window as unknown as { __TAURI_INTERNALS__?: unknown }).__TAURI_INTERNALS__ = {
      invoke: async (cmd: string, args: Record<string, unknown>) => {
        invokes.push({ cmd, args });
        const root = String(args.root ?? "");
        const req = (args.request ?? {}) as { paths?: string[] };
        if (root.endsWith("/brain/a9d747d2-e45e-4308-b5e3-a79dd02188ce")) {
          return {
            results: (req.paths ?? []).map((p) => ({
              reference: p,
              matches:
                p === "razr_bonsai_demo.mp4"
                  ? [{ name: "razr_bonsai_demo.mp4", path: "razr_bonsai_demo.mp4", kind: "file" }]
                  : [],
            })),
          };
        }
        return {
          results: (req.paths ?? []).map((p) => ({ reference: p, matches: [] })),
        };
      },
    };
    globalThis.fetch = (async () =>
      new Response(JSON.stringify({ sources: [] }), { status: 200 })) as typeof fetch;
    try {
      const client = createFileClient({
        mission: { id: "a90cca7c-d2b3-4512-9adc-6b32f135aef8" } as never,
      });
      await client.roots();
      const wsRoot = client.mountLocalRoot("/home/thomas/work/nixos");
      const raw =
        "/home/thomas/.gemini/antigravity-cli/brain/a9d747d2-e45e-4308-b5e3-a79dd02188ce/razr_bonsai_demo.mp4";
      const reply = await client.call(wsRoot.id, {
        action: "resolve",
        paths: [raw],
      });
      const mountedBrain = client
        .currentSources()
        .find((s) => s.local && s.path?.endsWith("/brain/a9d747d2-e45e-4308-b5e3-a79dd02188ce"));
      expect(mountedBrain).toBeDefined();
      expect(reply.results).toEqual([
        {
          reference: raw,
          matches: [
            {
              name: "razr_bonsai_demo.mp4",
              path: "razr_bonsai_demo.mp4",
              kind: "file",
              source: mountedBrain!.id,
            },
          ],
        },
      ]);
      // Once mounted, resolving via the workspace root skips re-querying the brain root so there are no duplicate matches.
      const before = invokes.length;
      const second = await client.call(wsRoot.id, {
        action: "resolve",
        paths: [raw],
      });
      expect(second.results?.[0]?.matches).toEqual([]);
      expect(invokes.slice(before).every((c) => c.args.root === "/home/thomas/work/nixos")).toBe(true);
    } finally {
      (window as unknown as { __TAURI_INTERNALS__?: unknown }).__TAURI_INTERNALS__ = origTauri;
      globalThis.fetch = origFetch;
    }
  });
  it("never resolves paths inside web URLs", () =>
    expect(
      splitFileReferences("See https://example.com/a/file.md now").filter(
        (p) => p.target,
      ),
    ).toHaveLength(0));
  it("preserves prose byte for byte", () => {
    const text = "Read audit/guarantees.yaml and `notes.md`.";
    expect(
      splitFileReferences(text)
        .map((p) => p.text)
        .join(""),
    ).toBe(text);
  });
});

it("resolves document links without escaping the source", () => {
  expect(relativeFilePath("audit/notes.md", "../README.md")).toBe("README.md");
  expect(relativeFilePath("docs/notes.md", "C:/Users/Jane/readme.md")).toBe("C:/Users/Jane/readme.md");
  expect(relativeFilePath("docs/notes.md", "C:\\Users\\Jane\\readme.md")).toBe("C:\\Users\\Jane\\readme.md");
  expect(relativeFilePath("notes.md", "../secret.md")).toBeNull();
  expect(relativeFilePath("audit/notes.md", "/workspace/README.md")).toBe(
    "/workspace/README.md",
  );
});
