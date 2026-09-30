import { describe, expect, it } from "vitest";
import { atQuery, chipToAttachment, consumeAtToken, filterAttach, insertMention, mentionText, mentionedChips, type AttachItem } from "../src/attach";

const items: AttachItem[] = [
  { id: "file:notes/foo.md", kind: "file", section: "Files", path: "notes/foo.md", label: "notes/foo.md" },
  { id: "folder:notes", kind: "folder", section: "Folders", path: "notes", label: "notes/" },
  { id: "controller:lido", kind: "controller", section: "Controller", label: "Lido controller" },
];

describe("at palette", () => {
  it("opens on @ at a token start", () => {
    expect(atQuery("@", 1)).toEqual({ open: true, query: "", start: 0 });
    expect(atQuery("see @foo", 8)).toEqual({ open: true, query: "foo", start: 4 });
    expect(atQuery("email@x", 7)).toEqual({ open: false, query: "", start: -1 });
    expect(atQuery("plain", 5)).toEqual({ open: false, query: "", start: -1 });
  });

  it("filters paths and hides legacy controller rows", () => {
    expect(filterAttach(items, "foo").map((i) => i.kind)).toEqual(["file"]);
    expect(filterAttach(items, "notes").map((i) => i.kind)).toEqual(["file", "folder"]);
    expect(filterAttach(items, "lido").map((i) => i.kind)).toEqual([]);
  });

  it("maps chips to structured attachments, never file bodies", () => {
    expect(chipToAttachment({ id: "file:notes/foo.md", kind: "file", path: "notes/foo.md", label: "notes/foo.md" }))
      .toEqual({ kind: "file", path: "notes/foo.md" });
    expect(chipToAttachment({ id: "folder:notes", kind: "folder", path: "notes", label: "notes/" }))
      .toEqual({ kind: "folder", path: "notes" });
    expect(chipToAttachment({ id: "controller:lido", kind: "controller", label: "Lido controller" }))
      .toEqual({ kind: "controller" });
  });

  it("consumes the @ token after a pick", () => {
    expect(consumeAtToken("see @foo", 8)).toBe("see ");
    expect(consumeAtToken("@notes", 6)).toBe("");
    expect(consumeAtToken("Keep\n\n  code  spacing @notes", 28)).toBe("Keep\n\n  code  spacing ");
    expect(consumeAtToken("Draft:\n\n@notes", 14)).toBe("Draft:\n\n");
    expect(consumeAtToken("Before @notes after", 13)).toBe("Before  after");
  });
});

describe("literal project paths", () => {
  const items: AttachItem[] = [
    {id:"context:p:context",kind:"context",project:"p",section:"Folders",path:"context",label:"context/"},
    {id:"context:p:context/notes.md",kind:"context",project:"p",section:"Files",path:"context/notes.md",label:"context/notes.md"},
  ];
  it("inserts actual paths without a synthetic namespace", () => {
    expect(insertMention("Review @no",10,items[1]).text).toBe("Review @context/notes.md ");
    expect(mentionedChips("@context/notes.md.",items)).toEqual([expect.objectContaining({path:"context/notes.md",project:"p"})]);
    expect(chipToAttachment(items[1])).toEqual({kind:"path",path:"context/notes.md"});
  });
  it("does not invent attachments for unknown context paths", () => {
    expect(mentionedChips("@context/missing.md @controller",items)).toEqual([]);
  });
  it("does not choose between identical paths owned by different roots", () => {
    expect(mentionedChips("@context/notes.md",[items[1],{...items[1],id:"other",project:"q"}])).toEqual([]);
  });
});
