import { afterEach, expect, it, vi } from "vitest";
import { fileDestination, folderWorkError, readFileReference, transferProjectFile } from "../src/fileActions";
import { setApiUrl } from "../src/api";
import { resetMissionHierarchy } from "../src/missionHierarchy";
afterEach(() => { vi.restoreAllMocks(); resetMissionHierarchy(); });
it("renames exactly and moves to the root without allowing traversal", () => {
  expect(fileDestination("notes/context.md", "README", true)).toBe("notes/README");
  expect(fileDestination("notes/context.md", "", false)).toBe("context.md");
  expect(fileDestination("notes/context.md", "archive/nested", false)).toBe("archive/nested/context.md");
  for (const value of ["../escape", "/absolute", "a//b", "a\\b"]) expect(() => fileDestination("notes/context.md", value, false)).toThrow();
  expect(() => fileDestination("notes/context.md", "notes", false)).toThrow();
});
it("accepts only file clipboard payloads from this backend", () => {
  setApiUrl("https://example.test");
  const payload = { slug: "test", path: "context.md", copy: false, backend: "https://example.test", account: "", nonce: "one" };
  expect(readFileReference("orb:file:" + JSON.stringify(payload))).toEqual(payload);
  expect(readFileReference("orb:file:" + JSON.stringify({...payload, backend: "https://other.test"}))).toBeNull();
  expect(readFileReference("some text")).toBeNull();
});
it("sends a transfer to the authoritative API, commits moved_missions, and surfaces an old backend", async () => {
  const fetch = vi.spyOn(globalThis, "fetch").mockResolvedValue(new Response(JSON.stringify({
    path: "notes/context.md",
    moved_missions: [{ mission_id: "m1", project: "test", folder: "notes", placement_revision: 3 }],
  }), {status:200}));
  await transferProjectFile("test", "context.md", "notes/context.md", true);
  expect(JSON.parse(String(fetch.mock.calls[0][1]?.body))).toEqual({path:"context.md",destination:"notes/context.md",copy:true});
  fetch.mockResolvedValue(new Response('Not found', {status:404}));
  await expect(transferProjectFile("test", "context.md", "renamed.md")).rejects.toThrow("Update the backend");
});

it("blocks folder deletion when a nested agent exists in folder_prefix", async () => {
  const { assertFolderHasNoWork } = await import('../src/fileActions');
  const fetch = vi.spyOn(globalThis, 'fetch')
    .mockResolvedValueOnce(new Response(JSON.stringify([{id:'nested',project:'test',folder:'notes/deep',tags:[]}])));
  await expect(assertFolderHasNoWork('test','notes')).rejects.toThrow('Move the agents');
  expect(String(fetch.mock.calls[0][0])).toContain('folder_prefix=notes');
});
it("allows a document folder but blocks a nested cron", async () => {
  const { assertFolderHasNoWork } = await import('../src/fileActions');
  const fetch = vi.spyOn(globalThis,'fetch').mockResolvedValueOnce(new Response('[]')).mockResolvedValueOnce(new Response('{"jobs":[]}'));
  await expect(assertFolderHasNoWork('test','notes')).resolves.toBeUndefined();
  fetch.mockResolvedValueOnce(new Response('[]')).mockResolvedValueOnce(new Response(JSON.stringify({jobs:[{id:'job',name:'Cron',folder:'notes/deep',enabled:true}]})));
  await expect(assertFolderHasNoWork('test','notes')).rejects.toThrow('crons');
});

it("synchronously flags loaded missions and crons inside a folder", () => {
  expect(folderWorkError("test", "Audits", [], [])).toBeNull();
  expect(folderWorkError("test", "Audits", [{ id: "m1", title: null, status: "completed", project: "test", folder: "Audits/sub", history: [] }], [])).toContain("Move the agents");
  expect(folderWorkError("test", "Audits", [], [{ folder: "Audits" }])).toContain("crons");
  expect(folderWorkError("test", "Audits", [{ id: "m2", title: null, status: "completed", project: "other", folder: "Audits", history: [] }], [{ folder: "Audits-other" }])).toBeNull();
  expect(folderWorkError("test", "Audits", [{ id: "m3", title: null, status: "completed", project: "test", folder: "", tags: ["orb-folder:Audits"], history: [] }], [])).toBeNull();
});

it("moves a file to another project through its own route", async () => {
  const roster = () => new Response(JSON.stringify({projects:[{slug:"test"},{slug:"other"},{slug:"gone",status:"archived"}]}));
  const fetch = vi.spyOn(globalThis, "fetch").mockImplementation(async input => String(input).endsWith("/api/projects") ? roster() : new Response('{}', {status:200}));
  await transferProjectFile("test", "notes/context.md", "context.md", false, "other");
  expect(String(fetch.mock.calls[1][0])).toContain("/api/projects/test/file/transfer/other");
  expect(JSON.parse(String(fetch.mock.calls[1][1]?.body))).toEqual({path:"notes/context.md",destination:"context.md",copy:false});
  await expect(transferProjectFile("test", "context.md", "context.md", false, "gone")).rejects.toThrow("no longer exists");
  expect(fetch.mock.calls.filter(call => String(call[0]).includes("/transfer/")).length).toBe(1);
  fetch.mockImplementation(async input => String(input).endsWith("/api/projects") ? roster() : new Response('Not found', {status:404}));
  await expect(transferProjectFile("test", "context.md", "context.md", false, "other")).rejects.toThrow("between projects");
});
it("keeps the folder flag on the clipboard and rejects a malformed one", async () => {
  setApiUrl("https://example.test");
  const payload = { slug: "test", path: "notes", copy: false, directory: true, backend: "https://example.test", account: "", nonce: "one" };
  expect(readFileReference("orb:file:" + JSON.stringify(payload))?.directory).toBe(true);
  expect(readFileReference("orb:file:" + JSON.stringify({...payload, directory: "yes"}))).toBeNull();
});
it("moves nested agents and crons with moveFolderWork fallback and reports failures", async () => {
  const { moveFolderWork } = await import('../src/fileActions');
  const missions = [
    {id:'inside',project:'test',folder:'notes/deep',tags:['pinned']},
    {id:'sibling',project:'test',folder:'notes',tags:[]},
    {id:'stuck',project:'test',folder:'notes',tags:[]},
  ];
  const sent: Array<{url:string;body:any}> = [];
  vi.spyOn(globalThis, 'fetch').mockImplementation(async (input, init) => {
    const url = String(input), body = init?.body ? JSON.parse(String(init.body)) : undefined;
    if (init?.method && init.method !== 'GET') {
      sent.push({url, body});
      if (url.endsWith('/api/control/missions/move') && body?.mission_ids?.includes('stuck')) {
        return new Response('busy', {status:409});
      }
      if (url.endsWith('/api/control/missions/move')) {
        return new Response(JSON.stringify({
          moved: body.mission_ids.map((mid: string) => ({ mission_id: mid, project: body.project, folder: body.folder, placement_revision: 2 })),
        }));
      }
      return new Response('{}');
    }
    if (url.includes('/crons')) return new Response(JSON.stringify({jobs:[{id:'job',name:'Cron',folder:'notes',enabled:true},{id:'far',name:'Far',folder:'other',enabled:true}]}));
    return new Response(JSON.stringify(missions));
  });
  await expect(moveFolderWork('test','notes','archive/renamed')).rejects.toThrow(/stuck.*could not follow/);
  expect(sent.find(call => call.url.endsWith('/api/control/missions/move') && call.body.mission_ids.includes('inside'))?.body).toMatchObject({
    mission_ids:['inside'],
    project:'test',
    folder:'archive/renamed/deep',
  });
  expect(sent.find(call => call.url.endsWith('/api/control/missions/move') && call.body.mission_ids.length === 1 && call.body.mission_ids[0] === 'sibling')?.body).toMatchObject({
    mission_ids:['sibling'],
    project:'test',
    folder:'archive/renamed',
  });
  expect(sent.find(call => call.url.includes('/crons/job'))?.body).toMatchObject({folder:'archive/renamed'});
  expect(sent.some(call => call.url.includes('/crons/far'))).toBe(false);
});

it("marks local-context transfers with { local: true } so desktop callers relocate folder work", async () => {
  const projectContext = await import("../src/projectContext");
  const spy = vi.spyOn(projectContext, "localContextFile").mockResolvedValueOnce({} as never);
  const fetch = vi.spyOn(globalThis, "fetch");
  const res = await transferProjectFile("test", "notes", "archive", false);
  expect(res).toEqual({ local: true });
  expect(spy).toHaveBeenCalledWith("test", "move", "notes", "archive", undefined, undefined);
  expect(fetch).not.toHaveBeenCalled();
});
