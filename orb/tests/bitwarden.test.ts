import { describe, expect, it, vi, beforeEach } from "vitest";
import {
  getBitwardenStatus,
  listBitwardenProjects,
  listBitwardenSecrets,
  revealBitwardenSecret,
  createBitwardenSecret,
  updateBitwardenSecret,
  deleteBitwardenSecret,
  updateBitwardenConfig,
  approveSecretRequest,
  groupSecrets,
  listAllBitwardenSecrets,
  setSecretDefaultAccess,
} from "../src/bitwardenApi";

const apiMock = vi.fn();

vi.mock("../src/api", () => ({
  api: (...args: unknown[]) => apiMock(...args),
  getApiUrl: () => "https://core.test",
  ApiError: class extends Error {},
}));

describe("bitwardenApi", () => {
  beforeEach(() => {
    apiMock.mockReset();
  });

  it("fetches status and projects from /api/bitwarden", async () => {
    apiMock.mockResolvedValueOnce({
      bws_available: true,
      configured: true,
      token_source: "template",
      token_hint: "0.9462f1…faad",
      server_url: null,
      default_project_id: "297f3106-758f-43d5-8a4b-b460007558c8",
      project_bindings: { paloma: "297f3106-758f-43d5-8a4b-b460007558c8" },
    });
    const status = await getBitwardenStatus();
    expect(apiMock).toHaveBeenCalledWith("/api/bitwarden/status");
    expect(status.default_project_id).toBe("297f3106-758f-43d5-8a4b-b460007558c8");
    expect(status.project_bindings.paloma).toBe("297f3106-758f-43d5-8a4b-b460007558c8");

    apiMock.mockResolvedValueOnce([
      {
        id: "297f3106-758f-43d5-8a4b-b460007558c8",
        organizationId: "4eef7130-29af-4b76-8f14-b3cc01120ee6",
        name: "paloma",
        creationDate: "2026-03-04T02:27:09.64Z",
        revisionDate: "2026-03-04T02:27:09.64Z",
      },
    ]);
    const projects = await listBitwardenProjects();
    expect(apiMock).toHaveBeenCalledWith("/api/bitwarden/projects");
    expect(projects[0]?.name).toBe("paloma");
  });

  it("lists, reveals, creates, edits, and deletes project secrets", async () => {
    const projectId = "297f3106-758f-43d5-8a4b-b460007558c8";
    apiMock.mockResolvedValueOnce([
      {
        id: "sec-1",
        organizationId: "org-1",
        projectId,
        key: "OPENAI_API_KEY",
        note: "prod key",
        creationDate: "2026-03-04T02:27:09.64Z",
        revisionDate: "2026-03-04T02:27:09.64Z",
      },
    ]);
    const list = await listBitwardenSecrets(projectId);
    expect(apiMock).toHaveBeenCalledWith(`/api/bitwarden/projects/${projectId}/secrets`);
    expect(list).toHaveLength(1);
    expect(list[0]?.key).toBe("OPENAI_API_KEY");

    apiMock.mockResolvedValueOnce({
      id: "sec-1",
      organizationId: "org-1",
      projectId,
      key: "OPENAI_API_KEY",
      value: "sk-live-123",
      note: "prod key",
      creationDate: "2026-03-04T02:27:09.64Z",
      revisionDate: "2026-03-04T02:27:09.64Z",
    });
    const revealed = await revealBitwardenSecret("sec-1");
    expect(apiMock).toHaveBeenCalledWith("/api/bitwarden/secrets/sec-1/reveal", { method: "GET", headers: {} });
    expect(revealed.value).toBe("sk-live-123");

    apiMock.mockResolvedValueOnce({
      id: "sec-2",
      organizationId: "org-1",
      projectId,
      key: "NEW_SECRET",
      value: "val-2",
      note: "note-2",
      creationDate: "2026-03-04T02:27:09.64Z",
      revisionDate: "2026-03-04T02:27:09.64Z",
    });
    await createBitwardenSecret(projectId, { key: "NEW_SECRET", value: "val-2", note: "note-2" });
    expect(apiMock).toHaveBeenCalledWith(`/api/bitwarden/projects/${projectId}/secrets`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ key: "NEW_SECRET", value: "val-2", note: "note-2" }),
    });

    apiMock.mockResolvedValueOnce({
      id: "sec-2",
      organizationId: "org-1",
      projectId,
      key: "NEW_SECRET",
      value: "val-updated",
      note: "note-updated",
      creationDate: "2026-03-04T02:27:09.64Z",
      revisionDate: "2026-03-04T02:27:09.64Z",
    });
    await updateBitwardenSecret("sec-2", { value: "val-updated", note: "note-updated" });
    expect(apiMock).toHaveBeenCalledWith("/api/bitwarden/secrets/sec-2", {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ value: "val-updated", note: "note-updated" }),
    });

    apiMock.mockResolvedValueOnce({ ok: true });
    await deleteBitwardenSecret("sec-2");
    expect(apiMock).toHaveBeenCalledWith("/api/bitwarden/secrets/sec-2", {
      method: "DELETE",
      headers: {},
    });

    apiMock.mockResolvedValueOnce({
      bws_available: true,
      configured: true,
      token_source: "settings",
      token_hint: "0.123456…abcd",
      server_url: null,
      default_project_id: projectId,
      project_bindings: { paloma: projectId },
    });
    await updateBitwardenConfig({ default_project_id: projectId });
    expect(apiMock).toHaveBeenCalledWith("/api/bitwarden/config", {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ default_project_id: projectId }),
    });
  });

  it("talks to the broker endpoints", async () => {
    apiMock.mockResolvedValue({});
    await listAllBitwardenSecrets();
    expect(apiMock).toHaveBeenLastCalledWith("/api/bitwarden/secrets");
    await approveSecretRequest("req-1", "project");
    expect(apiMock.mock.lastCall?.[0]).toBe("/api/bitwarden/requests/req-1/approve");
    expect(JSON.parse(apiMock.mock.lastCall?.[1].body)).toEqual({ scope: "project" });
    await setSecretDefaultAccess("minecraft", ["p-mc"]);
    expect(apiMock.mock.lastCall?.[0]).toBe("/api/bitwarden/default-access/minecraft");
    expect(JSON.parse(apiMock.mock.lastCall?.[1].body)).toEqual({ project_ids: ["p-mc"] });
  });
});

describe("groupSecrets", () => {
  it("groups by project, then by name prefix, folding single prefixes into Other", () => {
    const tree = groupSecrets([
      { key: "CLOUDFLARE_API_TOKEN", projectId: "p-infra", projectName: "infra" },
      { key: "CLOUDFLARE_ACCOUNT_ID", projectId: "p-infra", projectName: "infra" },
      { key: "VERCEL_TOKEN", projectId: "p-infra", projectName: "infra" },
      { key: "JWT_SECRET", projectId: "p-core", projectName: "paloma-core" },
    ]);
    expect(tree.map((p) => p.projectName)).toEqual(["infra", "paloma-core"]);
    expect(tree[0].groups.map((g) => [g.prefix, g.items.map((i) => i.key)])).toEqual([
      ["CLOUDFLARE", ["CLOUDFLARE_ACCOUNT_ID", "CLOUDFLARE_API_TOKEN"]],
      ["Other", ["VERCEL_TOKEN"]],
    ]);
  });
});

describe("signedApi", () => {
  it("signs the exact request with the enrolled device key", async () => {
    const invoke = vi.fn().mockResolvedValue("c2lnbmF0dXJl");
    (window as unknown as { __TAURI_INTERNALS__: unknown }).__TAURI_INTERNALS__ = { invoke };
    localStorage.setItem("orb.approvalDevice.https://core.test", "dev-1");
    apiMock.mockReset();
    apiMock.mockResolvedValueOnce({ challenge_id: "ch-1", payload: "paloma-approval-v1\n..." });
    apiMock.mockResolvedValueOnce({ status: "approved" });
    await approveSecretRequest("req-9", "secret", undefined, "give mission X the secret K");
    expect(JSON.parse(apiMock.mock.calls[0][1].body)).toEqual({
      method: "POST",
      path: "/api/bitwarden/requests/req-9/approve",
      body: JSON.stringify({ scope: "secret" }),
      summary: "give mission X the secret K",
    });
    expect(invoke).toHaveBeenCalledWith("approval_sign", {
      payload: "paloma-approval-v1\n...",
      reason: "give mission X the secret K",
    });
    const sent = apiMock.mock.calls[1][1];
    expect(sent.headers["X-Paloma-Approval"]).toBe("ch-1.dev-1.c2lnbmF0dXJl");
    expect(sent.body).toBe(JSON.stringify({ scope: "secret" }));
    localStorage.clear();
  });
});
