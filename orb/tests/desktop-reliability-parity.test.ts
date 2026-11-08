import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it, vi } from "vitest";
import { authenticateBiometric } from "../src/bitwardenApi";

describe("desktop reliability & rust-parity regressions", () => {
  it("authenticateBiometric rejects when biometric_authenticate returns false", async () => {
    const host = window as unknown as {
      __TAURI_INTERNALS__?: { invoke: (cmd: string, args?: unknown) => Promise<unknown> };
    };
    const previous = host.__TAURI_INTERNALS__;
    try {
      host.__TAURI_INTERNALS__ = {
        invoke: vi.fn().mockResolvedValueOnce(false).mockResolvedValueOnce(true),
      };
      await expect(authenticateBiometric("unlock secrets")).rejects.toThrow("biometric_failed");
      await expect(authenticateBiometric("unlock secrets")).resolves.toBeUndefined();
    } finally {
      host.__TAURI_INTERNALS__ = previous;
    }
  });

  it("restoreLocalBindings keeps legacy localStorage on transient migration failure and clears after success", async () => {
    vi.resetModules();
    const { restoreLocalBindings, localBinding } = await import("../src/localAgents");
    const legacyBinding = {
      harness: "codex",
      bin: "/usr/local/bin/codex",
      cwd: "/tmp/work",
      sessionId: "sess-legacy",
    };
    localStorage.setItem("orb.localBindings", JSON.stringify({ m1: legacyBinding }));

    const host = window as unknown as {
      __TAURI_INTERNALS__?: { invoke: (...args: any[]) => Promise<unknown> };
      __TAURI__?: unknown;
    };
    const previousInternals = host.__TAURI_INTERNALS__;
    const previousTauri = host.__TAURI__;
    host.__TAURI__ = { core: { Channel: class { onmessage = (_value: unknown) => {}; } } };

    let failSet = true;
    let stored: Record<string, typeof legacyBinding> = {};
    host.__TAURI_INTERNALS__ = {
      invoke: async (cmd: string, args?: any) => {
        if (cmd === "local_bindings_subscribe") {
          args.onEvent.onmessage({ revision: 0, bindings: { ...stored } });
          return 1;
        }
        if (cmd === "local_binding_set") {
          if (failSet) throw new Error("daemon restarting");
          stored[args.id] = args.binding;
          return { revision: 1, bindings: { ...stored } };
        }
        if (cmd === "local_bindings_refresh") {
          return { revision: 1, bindings: { ...stored } };
        }
        return null;
      },
    };

    try {
      await expect(restoreLocalBindings()).rejects.toThrow("daemon restarting");
      expect(localStorage.getItem("orb.localBindings")).not.toBeNull();

      failSet = false;
      await restoreLocalBindings();
      expect(localStorage.getItem("orb.localBindings")).toBeNull();
      expect(localBinding("m1")).toEqual(legacyBinding);
    } finally {
      window.dispatchEvent(new Event("pagehide"));
      host.__TAURI_INTERNALS__ = previousInternals;
      host.__TAURI__ = previousTauri;
      localStorage.removeItem("orb.localBindings");
    }
  });

  it("materializeMentions handles null from project_context_prepare without TypeError", async () => {
    vi.resetModules();
    const { materializeMentions } = await import("../src/localAgents");
    const host = window as unknown as {
      __TAURI_INTERNALS__?: { invoke: ReturnType<typeof vi.fn> };
    };
    const previous = host.__TAURI_INTERNALS__;
    host.__TAURI_INTERNALS__ = { invoke: vi.fn().mockResolvedValue(null) };
    try {
      await expect(
        materializeMentions(
          "demo",
          "Inspect @context/readme.md",
          [{ id: "c1", kind: "context", path: "context/readme.md", label: "readme", project: "demo" }],
        ),
      ).rejects.toThrow("Restart Orb to load the updated context resolver. Your draft is kept.");

      const fallback = await materializeMentions(
        "demo",
        "Inspect @notes/foo.md",
        [{ id: "f1", kind: "file", path: "notes/foo.md", label: "foo" }],
        async () => "copied body",
        async () => [],
      );
      expect(fallback.files).toEqual([{ rel: ".paloma/attach/notes/foo.md", content: "copied body" }]);
      expect(fallback.prompt).toContain("__ROOT__/.paloma/attach/notes/foo.md");
    } finally {
      host.__TAURI_INTERNALS__ = previous;
    }
  });

  it("enforces quiet unified focus rings and deduplicated .managed-size in styles.css", () => {
    const css = readFileSync(resolve(__dirname, "../src/styles.css"), "utf8");
    expect(css).not.toMatch(/\.gh-repo-search:focus\s*\{[^}]*var\(--accent\)/);
    expect(css).not.toMatch(/\.managed-size:focus-visible\s*\{[^}]*box-shadow:\s*0\s+0\s+0\s+2px/);
    expect(css).not.toMatch(/\.model-chip:focus-visible\s*\{[^}]*2px\s+solid\s+var\(--accent\)/);
    expect(css).not.toMatch(/\.cron-name-input:focus-visible\s*\{[^}]*outline:\s*1px\s+solid/);
    const managedSizeBlocks = css.match(/^\.managed-size\s*\{/gm) ?? [];
    expect(managedSizeBlocks).toHaveLength(1);
  });
});
