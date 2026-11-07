import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const { invokeMock, apiMock, connectionVersionMock, getApiUrlMock, getJwtMock } = vi.hoisted(() => ({
  invokeMock: vi.fn(),
  apiMock: vi.fn(),
  connectionVersionMock: vi.fn(() => 1),
  getApiUrlMock: vi.fn(() => "https://orbcore.thomas.md"),
  getJwtMock: vi.fn(() => "jwt-token"),
}));

vi.mock("../src/native", () => ({
  nativeInvoke: () => invokeMock,
}));

vi.mock("../src/api", () => ({
  api: apiMock,
  ApiError: class ApiError extends Error {
    constructor(public status: number, public detail: string) {
      super(`${status} ${detail}`);
    }
  },
  clearConnection: vi.fn(),
  connectionVersion: connectionVersionMock,
  getApiUrl: getApiUrlMock,
  getJwt: getJwtMock,
  REQUEST_TIMEOUT_MS: 30000,
  transportFetch: vi.fn(),
}));

vi.mock("../src/sharedReads", () => ({
  invalidateReads: vi.fn(),
}));

vi.mock("../src/usageTelemetry", () => ({
  usageTelemetry: { approval: vi.fn() },
}));

import { ApiError } from "../src/api";
import { ApprovalCancelled, enrolledDeviceId, signedApi } from "../src/deviceApproval";

describe("deviceApproval signedApi", () => {
  const storage = new Map<string, string>();

  beforeEach(() => {
    storage.clear();
    vi.stubGlobal("localStorage", {
      getItem: (k: string) => storage.get(k) ?? null,
      setItem: (k: string, v: string) => {
        storage.set(k, v);
      },
      removeItem: (k: string) => {
        storage.delete(k);
      },
    });
    invokeMock.mockReset();
    apiMock.mockReset();
    connectionVersionMock.mockReturnValue(1);
    getApiUrlMock.mockReturnValue("https://orbcore.thomas.md");
    getJwtMock.mockReturnValue("jwt-token");
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("lazily resolves and caches enrolled device ID when localStorage lacks it (e.g. startup race or server alias switch)", async () => {
    invokeMock.mockImplementation(async (cmd: string) => {
      if (cmd === "approval_key_status") return { available: true, public_key: "PUBKEY_MAC_1" };
      if (cmd === "set_approval_grace") return null;
      if (cmd === "approval_sign") return "SIG_BASE64";
      if (cmd === "approval_grace_until") return 1800000000;
      throw new Error(`unexpected ${cmd}`);
    });

    apiMock.mockImplementation(async (path: string, init?: RequestInit) => {
      if (path === "/api/approvals/devices") {
        return {
          mode: "warn",
          enrollment_code_pending: false,
          devices: [
            {
              id: "dev-mac-uuid",
              name: "Orb on Mac",
              platform: "macos",
              public_key: "PUBKEY_MAC_1",
              created_at: "2026-11-01T00:00:00Z",
            },
          ],
        };
      }
      if (path === "/api/approvals/challenge") {
        return { challenge_id: "chal-1", payload: "paloma-approval-v1\n1\nPOST /api/approvals/approve-all\nh\nb\nsum" };
      }
      if (path === "/api/approvals/approve-all") {
        expect((init?.headers as Record<string, string>)["X-Paloma-Approval"]).toBe("chal-1.dev-mac-uuid.SIG_BASE64");
        return { approved: 1 };
      }
      throw new Error(`unexpected path ${path}`);
    });

    expect(enrolledDeviceId()).toBeNull();
    const res = await signedApi("POST", "/api/approvals/approve-all", { items: [], confirm_critical: false }, "Allow secret");
    expect(res).toEqual({ approved: 1 });
    expect(enrolledDeviceId()).toBe("dev-mac-uuid");
  });

  it("repairs a stale stored device ID and retries once when Core returns 403 Unknown approval device", async () => {
    storage.set("orb.approvalDevice.https://orbcore.thomas.md", "stale-device-id");

    let signCount = 0;
    invokeMock.mockImplementation(async (cmd: string) => {
      if (cmd === "approval_key_status") return { available: true, public_key: "PUBKEY_MAC_2" };
      if (cmd === "set_approval_grace") return null;
      if (cmd === "approval_sign") return `SIG_${++signCount}`;
      if (cmd === "approval_grace_until") return 0;
      throw new Error(`unexpected ${cmd}`);
    });

    apiMock.mockImplementation(async (path: string, init?: RequestInit) => {
      if (path === "/api/approvals/challenge") {
        return { challenge_id: `chal-${signCount + 1}`, payload: "paloma-approval-v1" };
      }
      if (path === "/api/approvals/devices") {
        return {
          mode: "enforce",
          enrollment_code_pending: false,
          devices: [
            {
              id: "fresh-device-id",
              name: "Orb on Mac",
              platform: "macos",
              public_key: "PUBKEY_MAC_2",
              created_at: "2026-11-07T00:00:00Z",
            },
          ],
        };
      }
      if (path === "/api/approvals/approve-all") {
        const hdr = (init?.headers as Record<string, string>)["X-Paloma-Approval"];
        if (hdr?.includes(".stale-device-id.")) {
          throw new ApiError(403, '{"error":"device_approval_required","message":"Unknown approval device"}');
        }
        expect(hdr).toBe("chal-2.fresh-device-id.SIG_2");
        return { approved: 2 };
      }
      throw new Error(`unexpected path ${path}`);
    });

    const out = await signedApi("POST", "/api/approvals/approve-all", { items: [], confirm_critical: false }, "Approve 2");
    expect(out).toEqual({ approved: 2 });
    expect(enrolledDeviceId()).toBe("fresh-device-id");
    expect(signCount).toBe(2);
  });

  it("serializes concurrent approval_sign calls so Touch ID prompts never overlap", async () => {
    storage.set("orb.approvalDevice.https://orbcore.thomas.md", "dev-1");
    let activeSigns = 0;
    let maxConcurrentSigns = 0;

    invokeMock.mockImplementation(async (cmd: string) => {
      if (cmd === "set_approval_grace" || cmd === "approval_grace_until") return 0;
      if (cmd === "approval_sign") {
        activeSigns++;
        maxConcurrentSigns = Math.max(maxConcurrentSigns, activeSigns);
        await new Promise((r) => setTimeout(r, 20));
        activeSigns--;
        return "SIG";
      }
      throw new Error(`unexpected ${cmd}`);
    });

    apiMock.mockImplementation(async (path: string) => {
      if (path === "/api/approvals/challenge") return { challenge_id: "c1", payload: "p1" };
      return { ok: true };
    });

    await Promise.all([
      signedApi("POST", "/api/bitwarden/requests/r1/approve", {}, "Allow 1"),
      signedApi("POST", "/api/bitwarden/requests/r2/approve", {}, "Allow 2"),
    ]);
    expect(maxConcurrentSigns).toBe(1);
  });

  it("translates cancelled signer error to ApprovalCancelled", async () => {
    storage.set("orb.approvalDevice.https://orbcore.thomas.md", "dev-1");
    invokeMock.mockImplementation(async (cmd: string) => {
      if (cmd === "set_approval_grace" || cmd === "approval_grace_until") return 0;
      if (cmd === "approval_sign") throw new Error("cancelled");
      return null;
    });
    apiMock.mockResolvedValue({ challenge_id: "c1", payload: "p1" });

    await expect(signedApi("POST", "/api/approvals/approve-all", {}, "Allow")).rejects.toBeInstanceOf(ApprovalCancelled);
  });
});
