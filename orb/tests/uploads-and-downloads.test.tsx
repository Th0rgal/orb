import { render, fireEvent, waitFor } from "@solidjs/testing-library";
import { describe, it, expect, vi, beforeEach } from "vitest";
import { useContext } from "solid-js";
import { FilePanelProvider } from "../src/FilePanel";
import { FileReferenceContext, type ReferenceResolver } from "../src/fileReferenceContext";
import {
  backgroundUploads,
  cancelBackgroundUpload,
  pauseBackgroundUpload,
  resumeBackgroundUpload,
  softLimitForDestination,
  startBackgroundUpload,
  uploadContextBlobResumable,
} from "../src/uploads";

const apiMock = vi.fn(async (_path: string, init?: RequestInit) => {
  if (init?.body && typeof init.body === "string") {
    try {
      const q = JSON.parse(init.body);
      if (q.action === "roots")
        return {
          sources: [{ id: "workspace", label: "Workspace", available: true }],
        };
      if (q.action === "list")
        return { entries: [{ name: "archive.zip", path: "archive.zip", kind: "file", size: 2_000_000 }] };
      if (q.action === "read")
        return {
          content: "",
          size: 2_000_000,
          binary: true,
          truncated: true,
          mime: "application/zip",
        };
    } catch {}
  }
  return { entries: [] };
});

vi.mock("../src/api", async (importOriginal) => ({
  ...(await importOriginal<typeof import("../src/api")>()),
  getProjectController: vi.fn(async () => ({ settings: {} })),
  getProjectCron: vi.fn(async () => ({ settings: {} })),
  api: (path: string, init?: RequestInit) => apiMock(path, init),
  rawRequest: vi.fn(async (_path: string, init?: RequestInit) => {
    const chunks = [
      new Uint8Array(500_000),
      new Uint8Array(500_000),
      new Uint8Array(1_000_000),
    ];
    let idx = 0;
    const stream = new ReadableStream<Uint8Array>({
      async pull(controller) {
        if (init?.signal?.aborted) {
          controller.error(new DOMException("Aborted", "AbortError"));
          return;
        }
        await new Promise((r) => setTimeout(r, 15));
        if (idx < chunks.length) {
          controller.enqueue(chunks[idx++]);
        } else {
          controller.close();
        }
      },
    });
    return new Response(stream, {
      status: 200,
      headers: { "Content-Length": "2000000" },
    });
  }),
}));

describe("FilePanel download feedback & resumable background uploads", () => {
  beforeEach(() => {
    for (const item of backgroundUploads()) {
      cancelBackgroundUpload(item.id);
    }
  });

  it("shows inline progress during binary file download and transitions to Downloaded", async () => {
    let resolver!: ReferenceResolver;
    const Capture = () => {
      resolver = useContext(FileReferenceContext)!;
      return null;
    };

    const createObjectURL = vi.fn(() => "blob:test-download");
    const revokeObjectURL = vi.fn();
    Object.defineProperty(URL, "createObjectURL", { value: createObjectURL, configurable: true, writable: true });
    Object.defineProperty(URL, "revokeObjectURL", { value: revokeObjectURL, configurable: true, writable: true });
    const anchorClickSpy = vi.spyOn(HTMLAnchorElement.prototype, "click").mockImplementation(() => {});

    const { getByRole, getByText } = render(() => (
      <div class="app">
        <FilePanelProvider scope={{ project: "test" }}>
          <Capture />
        </FilePanelProvider>
      </div>
    ));

    resolver.open({ source: "workspace", path: "archive.zip", name: "archive.zip", kind: "file" });

    const row = await waitFor(() => getByRole("treeitem", { name: /archive\.zip/i }));
    fireEvent.click(row);

    const btn = await waitFor(() => getByRole("button", { name: /Download file/i }));
    fireEvent.click(btn);

    await waitFor(() => {
      expect(getByText(/Downloading|Downloaded ✓/)).toBeTruthy();
    });

    await waitFor(() => {
      expect(getByText("Downloaded ✓")).toBeTruthy();
    });

    expect(createObjectURL).toHaveBeenCalled();
    expect(anchorClickSpy).toHaveBeenCalled();
    anchorClickSpy.mockRestore();
  });

  it("enforces destination soft limits (10 MiB for context, 20 MiB for direct machine)", () => {
    expect(softLimitForDestination("context:alpha")).toBe(10 * 1024 * 1024);
    expect(softLimitForDestination("core")).toBe(20 * 1024 * 1024);
    expect(softLimitForDestination("local")).toBe(20 * 1024 * 1024);
  });

  it("resumes chunked upload from server bitmap and recovers after a transient chunk error", async () => {
    const size = 9 * 1024 * 1024;
    const payload = new Uint8Array(size);
    payload[0] = 42;
    payload[size - 1] = 99;
    const file = new File([payload], "dataset.bin", { type: "application/octet-stream", lastModified: 1700000000000 });

    const uploadedIndices: number[] = [];
    let failedOnceOnChunk1 = false;

    apiMock.mockImplementationOnce(async () => ({
      upload_id: "sess-123",
      chunk_size: 4 * 1024 * 1024,
      total_chunks: 3,
      received_chunks: [0],
      received_bytes: 4 * 1024 * 1024,
    }));

    apiMock.mockImplementation(async (path: string, init?: RequestInit) => {
      const chunkMatch = path.match(/\/upload-sessions\/[^/]+\/chunks\/(\d+)$/);
      if (chunkMatch && init?.method === "PUT") {
        const idx = Number(chunkMatch[1]);
        if (idx === 1 && !failedOnceOnChunk1) {
          failedOnceOnChunk1 = true;
          throw new Error("Simulated network drop");
        }
        uploadedIndices.push(idx);
        return {
          upload_id: "sess-123",
          chunk_size: 4 * 1024 * 1024,
          total_chunks: 3,
          received_chunks: [0, ...uploadedIndices],
          received_bytes: size,
        };
      }
      if (path.endsWith("/complete") && init?.method === "POST") {
        return {
          hash: "abcdef1234567890",
          size,
        };
      }
      throw new Error(`Unexpected api path: ${path}`);
    });

    const progressUpdates: number[] = [];
    const result = await uploadContextBlobResumable(
      "alpha",
      { name: "dataset.bin", file },
      size,
      file.lastModified,
      {
        onProgress: (p) => progressUpdates.push(p.uploadedBytes),
      },
    );

    expect(result.hash).toBe("abcdef1234567890");
    expect(result.size).toBe(size);
    // Chunk 0 was already in received_chunks, so only chunks 1 and 2 were uploaded
    expect(uploadedIndices.includes(0)).toBe(false);
    expect(uploadedIndices.sort()).toEqual([1, 2]);
    expect(failedOnceOnChunk1).toBe(true);
    expect(progressUpdates.at(-1)).toBe(size);
  });

  it("tracks background upload tasks and supports pause / resume / cancel", async () => {
    const size = 5 * 1024 * 1024;
    const file = new File([new Uint8Array(size)], "video.mp4", { type: "video/mp4", lastModified: 1700000000000 });

    let releaseChunk!: () => void;
    const chunkGate = new Promise<void>((resolve) => {
      releaseChunk = resolve;
    });

    apiMock.mockImplementation(async (path: string, init?: RequestInit) => {
      if (path === "/api/uploads/sessions" && init?.method === "POST") {
        return {
          upload_id: "direct-sess-1",
          chunk_size: 4 * 1024 * 1024,
          total_chunks: 2,
          received_chunks: [],
          received_bytes: 0,
        };
      }
      if (path.includes("/chunks/")) {
        await chunkGate;
        if (init?.signal?.aborted) {
          throw new DOMException("Aborted", "AbortError");
        }
        return {
          upload_id: "direct-sess-1",
          chunk_size: 4 * 1024 * 1024,
          total_chunks: 2,
          received_chunks: [0, 1],
          received_bytes: size,
        };
      }
      if (path.includes("/complete")) {
        return {
          name: "video.mp4",
          path: "/tmp/uploads/video.mp4",
          size,
        };
      }
      return {};
    });

    let completedPath = "";
    const id = startBackgroundUpload({
      source: { name: "video.mp4", file },
      destination: "core",
      totalBytes: size,
      confirmedLarge: true,
      scope: "mission-1",
      onComplete: (uploaded) => {
        completedPath = uploaded.path;
      },
    });

    expect(backgroundUploads().some((u) => u.id === id && u.state === "uploading")).toBe(true);

    pauseBackgroundUpload(id);
    expect(backgroundUploads().some((u) => u.id === id && u.state === "paused")).toBe(true);

    releaseChunk();
    resumeBackgroundUpload(id);

    await waitFor(() => {
      expect(completedPath).toBe("/tmp/uploads/video.mp4");
    });
  });
});
