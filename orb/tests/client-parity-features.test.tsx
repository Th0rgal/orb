import { cleanup, fireEvent, render, screen, waitFor } from "@solidjs/testing-library";
import { afterEach, describe, expect, it, vi } from "vitest";
import { Machines } from "../src/Machines";
import { Settings } from "../src/Settings";
import { SkillsSettings } from "../src/SkillsSettings";
import { buildRestoreMultipartBody, parseCleanupDays } from "../src/accountAdmin";
import { clearConnection, setConnection } from "../src/api";
import {
  GITHUB_OAUTH_STATE_TTL_MS,
  beginGitHubOAuthAttempt,
  verifyGitHubOAuthCallback,
  verifyIssuedAuthToken,
} from "../src/githubSignIn";
import { isDivergedLibraryError } from "../src/skillsApi";

afterEach(() => {
  cleanup();
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

  it("validates cleanup day bounds and diverged git errors", () => {
    expect(parseCleanupDays("14")).toBe(14);
    expect(parseCleanupDays("0")).toBeNull();
    expect(parseCleanupDays("366")).toBeNull();
    expect(parseCleanupDays("12.5")).toBeNull();
    expect(isDivergedLibraryError(new Error("409 DIVERGED_HISTORY: local 1 ahead, 2 behind"))).toBe(true);
    expect(isDivergedLibraryError(new Error("500 network timeout"))).toBe(false);
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
});
