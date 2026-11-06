import { cleanup, fireEvent, render, screen, waitFor } from "@solidjs/testing-library";
import { afterEach, describe, expect, it, vi } from "vitest";
import { Machines } from "../src/Machines";
import { Settings } from "../src/Settings";
import { SkillsSettings } from "../src/SkillsSettings";
import {
  buildRestoreMultipartBody,
  changeServerPassword,
  interpretRestoreResponse,
  parseCleanupDays,
} from "../src/accountAdmin";
import { clearConnection, isConnected, setConnection } from "../src/api";
import { signedApi, signedRawRequest } from "../src/deviceApproval";
import {
  GITHUB_OAUTH_STATE_TTL_MS,
  beginGitHubOAuthAttempt,
  verifyGitHubOAuthCallback,
  verifyIssuedAuthToken,
} from "../src/githubSignIn";
import { isDivergedLibraryError, needsLibraryRemoteInit, sameLibraryRemote } from "../src/skillsApi";

afterEach(() => {
  cleanup();
  delete (window as unknown as { __TAURI_INTERNALS__?: unknown }).__TAURI_INTERNALS__;
  localStorage.clear();
  clearConnection();
  sessionStorage.clear();
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});

describe("OrbGitHubSignIn", () => {
  it("verifies matching state, rejects mismatched state, expiry, and origin changes", () => {
    const attempt = beginGitHubOAuthAttempt("https://Core.Example.com/", true, 1_000);
    expect(attempt).not.toBeNull();
    expect(attempt!.baseUrl).toBe("https://core.example.com");
    expect(attempt!.state).toMatch(/^[A-Za-z0-9_-]{43}$/);

    const okLoopback = verifyGitHubOAuthCallback(
      `http://127.0.0.1:51234/auth/callback?token=jwt-123&state=${attempt!.state}`,
      attempt,
      "https://core.example.com",
      2_000,
    );
    expect(okLoopback).toEqual({
      ok: true,
      baseUrl: "https://core.example.com",
      token: "jwt-123",
    });

    const okScheme = verifyGitHubOAuthCallback(
      `sandboxed://auth/callback?token=jwt-456&state=${attempt!.state}`,
      attempt,
      "https://core.example.com/",
      2_000,
    );
    expect(okScheme).toEqual({
      ok: true,
      baseUrl: "https://core.example.com",
      token: "jwt-456",
    });

    const badState = verifyGitHubOAuthCallback(
      "sandboxed://auth/callback?token=jwt-456&state=wrong-state-value-1234",
      attempt,
      "https://core.example.com",
      2_000,
    );
    expect(badState.ok).toBe(false);

    const expired = verifyGitHubOAuthCallback(
      `sandboxed://auth/callback?token=jwt-456&state=${attempt!.state}`,
      attempt,
      "https://core.example.com",
      1_000 + GITHUB_OAUTH_STATE_TTL_MS + 1,
    );
    expect(expired).toEqual({
      ok: false,
      error: "GitHub sign-in expired — please try again",
    });

    const changedOrigin = verifyGitHubOAuthCallback(
      `sandboxed://auth/callback?token=jwt-456&state=${attempt!.state}`,
      attempt,
      "https://other.example.com",
      2_000,
    );
    expect(changedOrigin).toEqual({
      ok: false,
      error: "Server URL changed during GitHub sign-in — please try again",
    });

    // Older Core omits `github_oauth_client_state` (`clientStateSupported === false`):
    // callback without `state` succeeds via origin + TTL + `/api/auth/status`, while a
    // forged non-empty `state` is still rejected (matching iOS & Android).
    const legacyAttempt = beginGitHubOAuthAttempt("https://legacy.example.com/", false, 1_000);
    expect(legacyAttempt!.state).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect(legacyAttempt!.requireState).toBe(false);
    expect(
      verifyGitHubOAuthCallback(
        "sandboxed://auth/callback?token=jwt-legacy",
        legacyAttempt,
        "https://legacy.example.com",
        2_000,
      ),
    ).toEqual({
      ok: true,
      baseUrl: "https://legacy.example.com",
      token: "jwt-legacy",
    });
    expect(
      verifyGitHubOAuthCallback(
        "sandboxed://auth/callback?token=jwt-legacy&state=forged-state",
        legacyAttempt,
        "https://legacy.example.com",
        2_000,
      ).ok,
    ).toBe(false);
  });

  it("rejects tokens rejected by GET /api/auth/status", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => new Response("Unauthorized", { status: 401 })),
    );
    await expect(verifyIssuedAuthToken("https://core.test", "bad-jwt")).rejects.toThrow(
      "Server rejected GitHub token",
    );
  });
});

describe("Backup multipart & cleanup helpers", () => {
  it("builds deterministic multipart/form-data bytes and repeatable SHA-256 digest", async () => {
    const zip = new Uint8Array([0x50, 0x4b, 0x03, 0x04, 0xca, 0xfe]);
    const builtA = buildRestoreMultipartBody(zip, 'my"backup\r\n.zip', "FixedBoundary42");
    const builtB = buildRestoreMultipartBody(zip, 'my"backup\r\n.zip', "FixedBoundary42");
    expect(builtA.contentType).toBe("multipart/form-data; boundary=FixedBoundary42");
    expect(Array.from(builtA.body)).toEqual(Array.from(builtB.body));
    const text = new TextDecoder().decode(builtA.body);
    expect(text).toContain('Content-Disposition: form-data; name="backup"; filename="my_backup__.zip"');
    const hashA = await builtA.sha256();
    const hashB = await builtB.sha256();
    expect(hashA).toMatch(/^[0-9a-f]{64}$/);
    expect(hashA).toBe(hashB);
  });

  it("validates cleanup day bounds, restore outcomes, and diverged git errors", () => {
    expect(parseCleanupDays("14")).toBe(14);
    expect(parseCleanupDays("0")).toBeNull();
    expect(parseCleanupDays("366")).toBeNull();
    expect(parseCleanupDays("12.5")).toBeNull();

    expect(
      interpretRestoreResponse({
        success: false,
        message: "No recognized files in backup archive",
        restored_files: [],
        errors: [],
      }),
    ).toEqual({
      ok: false,
      message: "No recognized files in backup archive",
    });

    expect(
      interpretRestoreResponse({
        success: false,
        message: "Partial restore failed",
        restored_files: ["settings.json"],
        errors: ["keys.json: permission denied"],
      }),
    ).toEqual({
      ok: false,
      message: "Partial restore failed (keys.json: permission denied)",
    });

    expect(
      interpretRestoreResponse({
        success: true,
        message: "",
        restored_files: ["settings.json", "providers.json"],
        errors: [],
      }),
    ).toEqual({
      ok: true,
      message: "Restored 2 files (settings.json, providers.json).",
    });

    expect(isDivergedLibraryError(new Error("409 DIVERGED_HISTORY: local 1 ahead, 2 behind"))).toBe(true);
    expect(isDivergedLibraryError(new Error("500 network timeout"))).toBe(false);
  });

  it("reloads WorkspaceCleanupCard on connection switch and disables inputs until loaded", async () => {
    setConnection("http://core-a.test", "jwt-a");
    let resolveSecondSettings: ((res: Response) => void) | undefined;
    vi.stubGlobal("fetch", (input: RequestInfo | URL) => {
      const url = String(input);
      if (url === "http://core-a.test/api/settings") {
        return Promise.resolve(
          new Response(
            JSON.stringify({
              auto_cleanup_enabled: true,
              auto_cleanup_days: 14,
              auto_cleanup_stopped_days: 3,
              auto_cleanup_orphans_enabled: true,
            }),
          ),
        );
      }
      if (url === "http://core-b.test/api/settings") {
        return new Promise<Response>((resolve) => {
          resolveSecondSettings = resolve;
        });
      }
      return Promise.resolve(new Response(JSON.stringify({})));
    });

    render(() => <Settings />);
    const details = document.querySelector("details.settings-advanced") as HTMLDetailsElement;
    details.open = true;
    fireEvent(details, new Event("toggle"));

    const daysInput = (await screen.findByLabelText("Completed retention days")) as HTMLInputElement;
    await waitFor(() => {
      expect(daysInput.disabled).toBe(false);
      expect(daysInput.value).toBe("14");
    });

    setConnection("http://core-b.test", "jwt-b");
    await waitFor(() => {
      expect(daysInput.disabled).toBe(true);
    });

    resolveSecondSettings?.(
      new Response(
        JSON.stringify({
          auto_cleanup_enabled: false,
          auto_cleanup_days: 30,
          auto_cleanup_stopped_days: 5,
          auto_cleanup_orphans_enabled: false,
        }),
      ),
    );

    await waitFor(() => {
      expect(daysInput.disabled).toBe(false);
      expect(daysInput.value).toBe("30");
    });
  });

  it("resets cleanup saving state if connection changes while save is pending", async () => {
    setConnection("http://core-a.test", "jwt-a");
    let resolveSaveA: ((res: Response) => void) | undefined;
    vi.stubGlobal("fetch", (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input);
      if (url === "http://core-a.test/api/settings" && init?.method === "PUT") {
        return new Promise<Response>((resolve) => {
          resolveSaveA = resolve;
        });
      }
      if (url === "http://core-a.test/api/settings") {
        return Promise.resolve(
          new Response(
            JSON.stringify({
              auto_cleanup_enabled: true,
              auto_cleanup_days: 14,
              auto_cleanup_stopped_days: 3,
              auto_cleanup_orphans_enabled: true,
            }),
          ),
        );
      }
      if (url === "http://core-b.test/api/settings") {
        return Promise.resolve(
          new Response(
            JSON.stringify({
              auto_cleanup_enabled: true,
              auto_cleanup_days: 21,
              auto_cleanup_stopped_days: 5,
              auto_cleanup_orphans_enabled: false,
            }),
          ),
        );
      }
      return Promise.resolve(new Response(JSON.stringify({})));
    });

    render(() => <Settings />);
    const details = document.querySelector("details.settings-advanced") as HTMLDetailsElement;
    details.open = true;
    fireEvent(details, new Event("toggle"));

    const daysInput = (await screen.findByLabelText("Completed retention days")) as HTMLInputElement;
    await waitFor(() => {
      expect(daysInput.disabled).toBe(false);
      expect(daysInput.value).toBe("14");
    });
    daysInput.value = "15";
    fireEvent.input(daysInput);

    const saveBtn = await screen.findByRole("button", { name: "Save" });
    await waitFor(() => expect((saveBtn as HTMLButtonElement).disabled).toBe(false));
    fireEvent.click(saveBtn);
    await waitFor(() => expect(daysInput.disabled).toBe(true));

    // Switch servers while PUT /api/settings on core-a is still pending.
    setConnection("http://core-b.test", "jwt-b");
    await waitFor(() => {
      expect(daysInput.disabled).toBe(false);
      expect(daysInput.value).toBe("21");
    });

    // Stale completion from core-a must not overwrite core-b state.
    resolveSaveA?.(new Response(JSON.stringify({ auto_cleanup_days: 15 })));
    await new Promise((r) => setTimeout(r, 20));
    expect(daysInput.value).toBe("21");
  });

  it("preserves session when POST /api/auth/change-password rejects current_password with 401", async () => {
    setConnection("http://core.test", "valid-jwt");
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => new Response("Current password is incorrect", { status: 401 })),
    );

    await expect(changeServerPassword("wrong-old", "new-password-123")).rejects.toThrow(
      "Current password is incorrect",
    );
    expect(isConnected()).toBe(true);
  });
});

describe("Machines FleetRow cordon / uncordon", () => {
  it("cordons and uncordons a static remote node with optimistic update and rollback on failure", async () => {
    setConnection("http://core.test", "jwt-token");
    let shouldFail = true;
    const fetchMock = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input);
      if (url.endsWith("/api/remote-nodes")) {
        return new Response(
          JSON.stringify({
            nodes: [
              {
                id: "spark-1",
                display_name: "DGX Spark",
                status: "online",
                cordoned: false,
                capacity_total: 4,
                active_leases: 1,
              },
            ],
          }),
        );
      }
      if (url.endsWith("/api/nodes/spark-1/cordon") && init?.method === "POST") {
        if (shouldFail) return new Response("node busy", { status: 500 });
        return new Response(JSON.stringify({ node: "spark-1", cordoned: true, changed: true }));
      }
      if (url.endsWith("/api/software")) {
        return new Response(JSON.stringify({ machines: [] }));
      }
      return new Response(JSON.stringify({}));
    });
    vi.stubGlobal("fetch", fetchMock);
    vi.stubGlobal(
      "WebSocket",
      class {
        static CLOSING = 2;
        readyState = 1;
        close() {}
      },
    );

    render(() => <Machines />);
    const nodeBtn = await screen.findByText("DGX Spark");
    fireEvent.click(nodeBtn);

    const cordonBtn = await screen.findByRole("button", { name: "Cordon" });
    fireEvent.click(cordonBtn);

    expect(await screen.findByText(/Couldn’t update node scheduling/i)).toBeTruthy();
    expect(screen.getByRole("button", { name: "Cordon" })).toBeTruthy();

    shouldFail = false;
    fireEvent.click(screen.getByRole("button", { name: "Retry" }));
    expect(await screen.findByRole("button", { name: "Uncordon" })).toBeTruthy();
  });
});

describe("Settings multi-user login & GitHub integration", () => {
  it("surfaces Username input when /api/health reports multi_user and sends username to /api/auth/login", async () => {
    const fetchMock = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input);
      if (url.endsWith("/api/health")) {
        return new Response(
          JSON.stringify({
            status: "ok",
            auth_required: true,
            auth_mode: "multi_user",
            github_enabled: true,
            github_oauth_client_state: true,
          }),
        );
      }
      if (url.endsWith("/api/auth/login") && init?.method === "POST") {
        const body = JSON.parse(String(init.body));
        expect(body).toEqual({ username: "alice", password: "secret-password" });
        return new Response(JSON.stringify({ token: "multi-jwt", exp: 9999999999 }));
      }
      if (url.endsWith("/api/cloud/accounts")) {
        return new Response(JSON.stringify([]));
      }
      if (url.endsWith("/api/integrations/github/status")) {
        return new Response(
          JSON.stringify({
            configured: true,
            connected: true,
            pending: false,
            login: "octocat",
            scopes: ["repo", "workflow"],
          }),
        );
      }
      if (url.endsWith("/api/auth/status")) {
        return new Response(
          JSON.stringify({
            auth_mode: "multi_user",
            password_source: "none",
            dev_mode: false,
          }),
        );
      }
      return new Response(JSON.stringify({}));
    });
    vi.stubGlobal("fetch", fetchMock);

    render(() => <Settings />);
    const usernameInput = await screen.findByLabelText("Username");
    expect(screen.getByRole("button", { name: "Sign in with GitHub" })).toBeTruthy();

    fireEvent.input(usernameInput, { target: { value: "alice" } });
    const pwInput = document.querySelector('input[type="password"]') as HTMLInputElement;
    fireEvent.input(pwInput, { target: { value: "secret-password" } });
    fireEvent.click(screen.getByRole("button", { name: "Connect" }));

    expect(await screen.findByText("@octocat")).toBeTruthy();
  });

  it("allows GitHub OAuth sign-in when an older Core omits github_oauth_client_state from /api/health", async () => {
    const fetchMock = vi.fn(async (input: RequestInfo | URL) => {
      const url = String(input);
      if (url.endsWith("/api/health")) {
        return new Response(
          JSON.stringify({
            status: "ok",
            auth_required: true,
            auth_mode: "single_tenant",
            github_enabled: true,
            // github_oauth_client_state intentionally omitted (older Core)
          }),
        );
      }
      if (url.endsWith("/api/auth/status")) {
        return new Response(
          JSON.stringify({
            auth_mode: "single_tenant",
            password_source: "env",
            dev_mode: false,
          }),
        );
      }
      if (url.endsWith("/api/cloud/accounts")) return new Response(JSON.stringify([]));
      if (url.endsWith("/api/integrations/github/status")) {
        return new Response(JSON.stringify({ configured: false, connected: false, pending: false, scopes: [] }));
      }
      return new Response(JSON.stringify({}));
    });
    vi.stubGlobal("fetch", fetchMock);
    const invokeSpy = vi.fn(async (cmd: string) => {
      if (cmd === "github_oauth_sign_in") {
        // Older Core redirects back without echoing `state`.
        return "sandboxed://auth/callback?token=legacy-gh-jwt";
      }
      return undefined;
    });
    (window as unknown as { __TAURI_INTERNALS__?: { invoke: typeof invokeSpy } }).__TAURI_INTERNALS__ = {
      invoke: invokeSpy,
    };

    render(() => <Settings />);
    const ghBtn = await screen.findByRole("button", { name: "Sign in with GitHub" });
    fireEvent.click(ghBtn);

    await waitFor(() => expect(isConnected()).toBe(true));
  });
});

describe("SkillsSettings diverged history recovery", () => {
  it("opens the diverged Library dialog on 409 DIVERGED_HISTORY and runs force-sync", async () => {
    setConnection("http://core.test", "jwt-token");
    const calls: string[] = [];
    vi.stubGlobal("fetch", async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input);
      calls.push(`${init?.method ?? "GET"} ${url}`);
      if (url.endsWith("/api/library/skills")) return new Response(JSON.stringify([]));
      if (url.endsWith("/api/library/status")) {
        return new Response(
          JSON.stringify({
            remote: "git@github.com:org/skills.git",
            branch: "main",
            clean: true,
            ahead: 1,
            behind: 1,
            modified_files: [],
          }),
        );
      }
      if (url.endsWith("/api/library/sync") && init?.method === "POST") {
        return new Response("DIVERGED_HISTORY: local and remote diverged", { status: 409 });
      }
      if (url.endsWith("/api/library/force-sync") && init?.method === "POST") {
        return new Response("ok", { status: 200 });
      }
      if (url.endsWith("/api/remote-nodes")) return new Response(JSON.stringify({ nodes: [] }));
      if (url.endsWith("/api/projects")) return new Response(JSON.stringify([]));
      if (url.endsWith("/api/software")) return new Response(JSON.stringify({ machines: [] }));
      return new Response(JSON.stringify({}));
    });

    render(() => <SkillsSettings />);
    const pullBtn = await screen.findByRole("button", { name: "Pull from the repo" });
    fireEvent.click(pullBtn);

    expect(await screen.findByText("Library history diverged")).toBeTruthy();
    fireEvent.click(screen.getByRole("button", { name: "Reset to remote" }));

    await waitFor(() => {
      expect(calls.some((c) => c.endsWith("/api/library/force-sync"))).toBe(true);
    });
  });

  it("retries Library initialization after a failed remote update instead of treating a no-op second save as success", async () => {
    expect(sameLibraryRemote("git@github.com:Org/Skills.git/", "git@github.com:org/skills")).toBe(true);
    expect(needsLibraryRemoteInit(null, "git@github.com:org/skills.git", null)).toBe(false);
    expect(needsLibraryRemoteInit("git@github.com:org/skills.git", "git@github.com:org/skills", null)).toBe(false);
    expect(
      needsLibraryRemoteInit(
        "git@github.com:org/new-skills.git",
        "git@github.com:org/old-skills.git",
        null,
      ),
    ).toBe(true);
    expect(
      needsLibraryRemoteInit(
        "git@github.com:org/new-skills.git",
        "git@github.com:org/new-skills.git",
        "git@github.com:org/new-skills.git",
      ),
    ).toBe(true);

    setConnection("http://core.test", "jwt-token");
    let putCount = 0;
    let statusHealthy = false;
    const putBodies: Array<Record<string, unknown>> = [];

    vi.stubGlobal("fetch", async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input);
      if (url.endsWith("/api/settings/library-remote") && init?.method === "PUT") {
        putCount += 1;
        putBodies.push(JSON.parse(String(init.body)));
        if (putCount === 1) {
          return new Response(
            JSON.stringify({
              library_remote: "git@github.com:org/new-skills.git",
              library_reinitialized: false,
              library_error: "git clone failed: temporary network outage",
            }),
          );
        }
        // Simulate an older Core server where `library_remote` was persisted on the
        // first attempt so the retry returns `library_reinitialized: false` with no error.
        return new Response(
          JSON.stringify({
            library_remote: "git@github.com:org/new-skills.git",
            library_reinitialized: false,
          }),
        );
      }
      if (url.endsWith("/api/library/status")) {
        if (!statusHealthy && putCount >= 2) {
          return new Response("Failed to initialize library: ssh timeout", { status: 500 });
        }
        return new Response(
          JSON.stringify({
            remote: statusHealthy
              ? "git@github.com:org/new-skills.git"
              : "git@github.com:org/old-skills.git",
            branch: "main",
            clean: true,
            ahead: 0,
            behind: 0,
            modified_files: [],
          }),
        );
      }
      if (url.endsWith("/api/library/skill") || url.endsWith("/api/library/skills")) {
        return new Response(JSON.stringify([]));
      }
      if (url.endsWith("/api/remote-nodes")) return new Response(JSON.stringify({ nodes: [] }));
      if (url.endsWith("/api/projects")) return new Response(JSON.stringify([]));
      if (url.endsWith("/api/software")) return new Response(JSON.stringify({ machines: [] }));
      return new Response(JSON.stringify({}));
    });

    render(() => <SkillsSettings />);
    const repoBtn = await screen.findByRole("button", { name: "Repo…" });
    fireEvent.click(repoBtn);

    const urlInput = (await screen.findByLabelText("Git remote URL")) as HTMLInputElement;
    fireEvent.input(urlInput, { target: { value: "git@github.com:org/new-skills.git" } });
    fireEvent.click(screen.getByRole("button", { name: "Save" }));

    // Attempt 1 fails: dialog stays open, surfaces error, and offers Retry.
    expect(await screen.findByText("git clone failed: temporary network outage")).toBeTruthy();
    const retryBtn = await screen.findByRole("button", { name: "Retry" });

    // Attempt 2: PUT returns no-op `library_reinitialized: false`, status init still fails -> must NOT close or claim connected.
    fireEvent.click(retryBtn);
    expect(await screen.findByText(/Failed to initialize library: ssh timeout/)).toBeTruthy();
    expect(screen.queryByText(/Library connected to/)).toBeNull();

    // Attempt 3: status initialization succeeds -> dialog closes and reports connected.
    statusHealthy = true;
    fireEvent.click(screen.getByRole("button", { name: "Retry" }));
    expect(await screen.findByText("Library connected to org/new-skills.")).toBeTruthy();
    expect(putBodies.every((b) => b.force_reinitialize === true)).toBe(true);
  });
});

describe("signedRawRequest & signedApi connection binding", () => {
  it("aborts signedRawRequest and never leaks origin bearer token or archive to a newly selected server", async () => {
    setConnection("http://core-a.test", "jwt-origin-a");
    localStorage.setItem("orb.approvalDevice.http://core-a.test", "dev-mac-1");

    const requests: Array<{ url: string; auth?: string }> = [];
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
        const url = String(input);
        const headers = (init?.headers ?? {}) as Record<string, string>;
        requests.push({ url, auth: headers.Authorization });
        if (url === "http://core-a.test/api/approvals/challenge") {
          return new Response(JSON.stringify({ challenge_id: "ch-1", payload: "payload-to-sign" }));
        }
        return new Response(JSON.stringify({ success: true }));
      }),
    );

    (window as unknown as { __TAURI_INTERNALS__?: { invoke: (cmd: string) => Promise<unknown> } }).__TAURI_INTERNALS__ = {
      invoke: async (cmd: string) => {
        if (cmd === "approval_sign") {
          // User or background event switches active server mid-Touch-ID prompt.
          setConnection("http://core-b.test", "jwt-dest-b");
          return "sig-abc";
        }
        if (cmd === "approval_grace_remaining") return 300;
        return undefined;
      },
    };

    const archive = new Uint8Array([0x50, 0x4b, 0x03, 0x04]);
    await expect(
      signedRawRequest("POST", "/api/settings/restore", "Restore backup", {
        body: archive,
        contentType: "multipart/form-data; boundary=orb",
      }),
    ).rejects.toThrow(/Server connection changed during device approval/);

    // Challenge went to core-a, and the restore archive + jwt-origin-a were NEVER sent to core-b (or anywhere).
    expect(requests.some((r) => r.url.startsWith("http://core-b.test"))).toBe(false);
    expect(requests.some((r) => r.url.endsWith("/api/settings/restore"))).toBe(false);
  });

  it("sends signedRawRequest and signedApi to the bound origin when the connection stays unchanged", async () => {
    setConnection("http://core-a.test/", "jwt-origin-a");
    localStorage.setItem("orb.approvalDevice.http://core-a.test", "dev-mac-1");

    const seen: Array<{ url: string; auth?: string; approval?: string }> = [];
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
        const url = String(input);
        const headers = (init?.headers ?? {}) as Record<string, string>;
        seen.push({
          url,
          auth: headers.Authorization,
          approval: headers["X-Paloma-Approval"],
        });
        if (url === "http://core-a.test/api/approvals/challenge") {
          return new Response(JSON.stringify({ challenge_id: "ch-2", payload: "payload-2" }));
        }
        if (url === "http://core-a.test/api/settings/backup") {
          return new Response(new Uint8Array([1, 2, 3]), { status: 200 });
        }
        return new Response(JSON.stringify({ ok: true }));
      }),
    );

    (window as unknown as { __TAURI_INTERNALS__?: { invoke: (cmd: string) => Promise<unknown> } }).__TAURI_INTERNALS__ = {
      invoke: async (cmd: string) => {
        if (cmd === "approval_sign") return "sig-ok";
        if (cmd === "approval_grace_remaining") return 300;
        return undefined;
      },
    };

    const backupRes = await signedRawRequest("GET", "/api/settings/backup", "Download backup");
    expect(backupRes.status).toBe(200);
    expect(seen).toContainEqual({
      url: "http://core-a.test/api/settings/backup",
      auth: "Bearer jwt-origin-a",
      approval: "ch-2.dev-mac-1.sig-ok",
    });

    // Also verify signedApi aborts if connection switches during signing.
    (window as unknown as { __TAURI_INTERNALS__?: { invoke: (cmd: string) => Promise<unknown> } }).__TAURI_INTERNALS__ = {
      invoke: async (cmd: string) => {
        if (cmd === "approval_sign") {
          setConnection("http://core-c.test", "jwt-c");
          return "sig-late";
        }
        return 0;
      },
    };
    await expect(
      signedApi("POST", "/api/privilege-access/req-1/approve", { note: "ok" }, "Approve"),
    ).rejects.toThrow(/Server connection changed during device approval/);
    expect(seen.some((r) => r.url.startsWith("http://core-c.test"))).toBe(false);
  });
});
