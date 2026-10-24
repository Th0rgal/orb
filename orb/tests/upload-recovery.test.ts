import { describe, expect, it, vi } from "vitest";
import { getApiUrl } from "../src/api";
import { mentionText, scanMentions } from "../src/attach";
import { cleanRelativePath, contextAttachmentPath, isSourceUnavailable, prepareUploads, removeMention, uploadToken, type UploadedFile } from "../src/uploads";

// The exact mention from the bug report: unicode, underscores, a space and parentheses.
const PATH = "attachments/497dfe42-8ff1-44a8-b0f8-6b74a4866833/Questões_PPLA_air_Law_key (1).pdf";
const restored = (patch: Partial<UploadedFile> = {}): UploadedFile => ({
  source: { name: "Questões_PPLA_air_Law_key (1).pdf", localPath: "/Users/t/Downloads/Questões_PPLA_air_Law_key (1).pdf" },
  path: PATH, destination: "context:pilot", connection: 0, endpoint: getApiUrl(), ...patch,
});

describe("mentions with unicode, spaces and parentheses", () => {
  it("round-trips through the quoted mention form", () => {
    const token = uploadToken(PATH);
    expect(token).toBe(`@"${PATH}"`);
    const [mention] = scanMentions(`Read ${token} and summarize.`);
    expect(mention.value).toBe(PATH);
    expect(mention.raw).toBe(token);
  });
  it("keeps a folder mention's trailing slash and finds mentions inside parentheses", () => {
    const folder = mentionText({ kind: "folder", path: "attachments/b/Cours d’été (2024)" });
    expect(folder).toBe('@"attachments/b/Cours d’été (2024)/"');
    expect(scanMentions(`(see ${folder})`).map(m => m.value)).toEqual(["attachments/b/Cours d’été (2024)/"]);
  });
  it("normalizes macOS NFD names to NFC in upload paths", () => {
    const nfd = "Questo\u0303es (1).pdf";
    expect(contextAttachmentPath({ name: nfd }, "batch")).toBe("attachments/batch/Quest\u00f5es (1).pdf");
    expect(cleanRelativePath("Pasta//x/./Questo\u0303es.pdf")).toBe("Pasta/x/Quest\u00f5es.pdf");
    expect(() => cleanRelativePath("Pasta/../../etc/passwd")).toThrow("Invalid attachment name.");
  });
});

describe("restored drafts", () => {
  it("reuses a file already uploaded to this backend after a restart instead of re-reading it", async () => {
    const transfer = vi.fn();
    // The app restarted: the connection counter moved on, the endpoint did not.
    const result = await prepareUploads(`Check @"${PATH}"`, [restored()], "context:pilot", transfer, 7);
    expect(transfer).not.toHaveBeenCalled();
    expect(result).toEqual({ text: `Check @"${PATH}"`, files: [restored()], unavailable: [] });
  });
  it("matches a mention typed in NFC against an NFD path", async () => {
    const nfd = PATH.normalize("NFD");
    const result = await prepareUploads(`Check @"${PATH}"`, [restored({ path: nfd })], "context:pilot", vi.fn(), 7);
    expect(result.files).toHaveLength(1);
  });
  it("drops only an attachment whose original is gone and keeps the rest of the draft sendable", async () => {
    const other = restored({ path: "attachments/x/notes.md", source: { name: "notes.md" } });
    const transfer = vi.fn(async () => { throw new Error("Choose this file again using the file picker"); });
    const text = `Résume @"${PATH}" avec @attachments/x/notes.md stp`;
    const result = await prepareUploads(text, [restored({ endpoint: "https://old.example" }), other], "context:pilot", transfer, 7);
    expect(result.text).toBe("Résume avec @attachments/x/notes.md stp");
    expect(result.unavailable.map(f => f.path)).toEqual([PATH]);
    expect(result.files).toEqual([other]);
  });
  it("still surfaces real transfer failures", async () => {
    await expect(prepareUploads(`@"${PATH}"`, [restored({ destination: "ashur" })], "context:pilot", async () => { throw new Error("offline"); }, 7)).rejects.toThrow("offline");
  });
  it("recognizes the desktop's lost-file errors only", () => {
    expect(isSourceUnavailable(new Error("Choose this file again using the file picker"))).toBe(true);
    expect(isSourceUnavailable(new Error("No such file or directory (os error 2)"))).toBe(true);
    expect(isSourceUnavailable(new Error("The backend changed. Choose the file again."))).toBe(false);
    expect(removeMention(`a @"${PATH}" b`, PATH)).toBe("a b");
  });
});
