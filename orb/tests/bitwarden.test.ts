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
} from "../src/bitwardenApi";

const apiMock = vi.fn();

vi.mock("../src/api", () => ({
  api: (...args: unknown[]) => apiMock(...args),
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
    expect(apiMock).toHaveBeenCalledWith("/api/bitwarden/secrets/sec-1/reveal");
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
});
