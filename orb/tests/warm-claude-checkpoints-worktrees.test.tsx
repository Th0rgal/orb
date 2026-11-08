import { render, screen, fireEvent, waitFor, cleanup } from "@solidjs/testing-library";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import DiffViewer, { pairSplitRows, parseUnifiedDiff } from "../src/DiffViewer";
import {
  ClaudePermissionPicker,
  WorktreeLaunchPicker,
  claudePermissionLabel,
  normalizeClaudePermission,
} from "../src/ClaudePermissionPicker";
import { NativeInteraction } from "../src/NativeInteraction";
import { api } from "../src/api";

vi.mock("../src/api", async (importOriginal) => ({
  ...(await importOriginal<typeof import("../src/api")>()),
  api: vi.fn(),
}));

const sampleDiff = [
  "diff --git a/src/old.ts b/src/new.ts",
  "--- a/src/old.ts",
  "+++ b/src/new.ts",
  "@@ -10,3 +10,4 @@ function demo()",
  " const keep = 1;",
  "-const oldVal = 2;",
  "+const newVal = 3;",
  "+const extra = 4;",
].join("\n");

beforeEach(() => {
  localStorage.clear();
  sessionStorage.clear();
  vi.mocked(api).mockReset();
});

afterEach(() => {
  cleanup();
});

describe("parseUnifiedDiff and pairSplitRows", () => {
  it("parses multi-line hunks, line numbers, and rename paths", () => {
    const parsed = parseUnifiedDiff(sampleDiff);
    expect(parsed).toHaveLength(1);
    expect(parsed[0].oldPath).toBe("src/old.ts");
    expect(parsed[0].path).toBe("src/new.ts");
    expect(parsed[0].hunks).toHaveLength(1);
    const lines = parsed[0].hunks[0].lines;
    expect(lines).toEqual([
      { kind: "ctx", oldLine: 10, newLine: 10, text: "const keep = 1;" },
      { kind: "del", oldLine: 11, text: "const oldVal = 2;" },
      { kind: "add", newLine: 11, text: "const newVal = 3;" },
      { kind: "add", newLine: 12, text: "const extra = 4;" },
    ]);
    const split = pairSplitRows(lines);
    expect(split).toHaveLength(3);
    expect(split[0].left?.text).toBe("const keep = 1;");
    expect(split[1].left?.text).toBe("const oldVal = 2;");
    expect(split[1].right?.text).toBe("const newVal = 3;");
    expect(split[2].left).toBeUndefined();
    expect(split[2].right?.text).toBe("const extra = 4;");
  });
});

describe("DiffViewer checkpoint diff and atomic restore", () => {
  it("renders checkpoint diffs, switches to Split view, and confirms Revert", async () => {
    vi.mocked(api).mockImplementation(async (path: string) => {
      if (path.endsWith("/checkpoints")) {
        return {
          checkpoints: [
            {
              turn: 1,
              ref: "refs/orb/checkpoints/m1/1",
              commit: "abcdef1234567890",
              head_commit: "11111112222222",
              created_at: 1700000000,
            },
          ],
        };
      }
      if (path.includes("/checkpoints/diff")) {
        return {
          from_ref: "HEAD",
          to_ref: "",
          files: [{ status: "M", path: "src/new.ts", additions: 2, deletions: 1 }],
          total_additions: 2,
          total_deletions: 1,
          raw_diff: sampleDiff,
          budget_exceeded: false,
          filtered_by_author: false,
        };
      }
      if (path.endsWith("/checkpoints/restore")) {
        return { ok: true, backup_ref: "refs/orb/backups/m1/1700000099" };
      }
      return {};
    });

    render(() => <DiffViewer missionId="m1" />);
    await screen.findByText("src/old.ts → src/new.ts");
    expect(screen.getByText("+const newVal = 3;")).toBeTruthy();

    fireEvent.click(screen.getByRole("button", { name: "Split" }));
    expect(screen.getByRole("button", { name: "Split" }).getAttribute("aria-pressed")).toBe("true");

    fireEvent.click(screen.getByRole("button", { name: /Revert to Turn 1/ }));
    await screen.findByText("Revert workspace to Turn 1?");
    fireEvent.click(screen.getByRole("button", { name: "Revert workspace" }));

    await waitFor(() =>
      expect(api).toHaveBeenCalledWith(
        "/api/control/missions/m1/checkpoints/restore",
        expect.objectContaining({
          method: "POST",
          body: JSON.stringify({ ref: "refs/orb/checkpoints/m1/1" }),
        }),
      ),
    );
  });
});

describe("Allow for session permission action", () => {
  it("sends accept_session for remote permission prompts", async () => {
    vi.mocked(api).mockResolvedValue({ delivered: true });
    render(() => (
      <NativeInteraction
        mission="m-perm"
        active
        remote
        items={[
          {
            kind: "tool",
            key: "perm-1",
            callId: "call-perm-1",
            name: "ui_native_request",
            args: {
              method: "permission",
              params: { tool: "Bash", input: { command: "npm test", description: "Run unit tests" } },
            },
            done: false,
          },
        ]}
      />
    ));

    const allowSessionBtn = await screen.findByRole("button", { name: "Allow for session" });
    expect(screen.getByRole("button", { name: "Decline" })).toBeTruthy();
    expect(screen.getByRole("button", { name: "Allow once" })).toBeTruthy();

    fireEvent.click(allowSessionBtn);
    await waitFor(() =>
      expect(api).toHaveBeenCalledWith(
        "/api/control/tool_result",
        expect.objectContaining({
          method: "POST",
          body: JSON.stringify({
            tool_call_id: "call-perm-1",
            name: "ui_native_request",
            result: { action: "accept_session", feedback: "" },
          }),
        }),
      ),
    );
  });
});

describe("ClaudePermissionPicker and WorktreeLaunchPicker", () => {
  it("normalizes permission modes and selects Auto-edit", async () => {
    expect(normalizeClaudePermission("unknown")).toBe("supervised");
    expect(claudePermissionLabel("acceptEdits")).toBe("Auto-edit");
    expect(claudePermissionLabel("bypassPermissions")).toBe("Full access");

    let chosen = "supervised";
    render(() => (
      <ClaudePermissionPicker
        value="supervised"
        onChange={(next) => {
          chosen = next;
        }}
      />
    ));
    fireEvent.click(screen.getByRole("button", { name: "Permissions: Supervised" }));
    fireEvent.click(await screen.findByRole("option", { name: /Auto-edit/ }));
    expect(chosen).toBe("acceptEdits");
  });

  it("recommends isolated worktree when Orb.Kernel.worktreeDecisionStep returns 513", async () => {
    const host = window as unknown as Record<string, unknown>;
    const prev = host.__TAURI_INTERNALS__;
    host.__TAURI_INTERNALS__ = {
      invoke: vi.fn(async (cmd: string) => {
        if (cmd === "local_worktree_status") {
          return {
            is_git_repo: true,
            repo_root: "/tmp/repo",
            current_branch: "main",
            is_worktree: false,
            is_dirty: true,
            repo_busy: true,
            decision_word: 513,
          };
        }
        return null;
      }),
    };
    try {
      let mode = "auto";
      render(() => (
        <WorktreeLaunchPicker
          cwd="/tmp/repo"
          value="auto"
          onChange={(next) => {
            mode = next;
          }}
        />
      ));
      const btn = await screen.findByRole("button", { name: "Checkout isolation: Worktree · auto" });
      fireEvent.click(btn);
      fireEvent.click(await screen.findByRole("option", { name: /^Local/ }));
      expect(mode).toBe("local");
    } finally {
      host.__TAURI_INTERNALS__ = prev;
    }
  });
});
