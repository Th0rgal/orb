import { afterEach, expect, it, vi } from "vitest";
import { fileDestination, readFileReference, transferProjectFile } from "../src/fileActions";
import { setApiUrl } from "../src/api";
afterEach(() => vi.restoreAllMocks());
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
it("sends a transfer to the authoritative API and surfaces an old backend", async () => {
  const fetch = vi.spyOn(globalThis, "fetch").mockResolvedValue(new Response('{}', {status:200}));
  await transferProjectFile("test", "context.md", "notes/context.md", true);
  expect(JSON.parse(String(fetch.mock.calls[0][1]?.body))).toEqual({path:"context.md",destination:"notes/context.md",copy:true});
  fetch.mockResolvedValue(new Response('Not found', {status:404}));
  await expect(transferProjectFile("test", "context.md", "renamed.md")).rejects.toThrow("Update the backend");
});

it("blocks folder deletion when a nested agent exists beyond the first page", async () => {
  const { assertFolderHasNoWork } = await import('../src/fileActions');
  const fetch = vi.spyOn(globalThis, 'fetch')
    .mockResolvedValueOnce(new Response(JSON.stringify(Array.from({length:200},(_,i)=>({id:String(i),project:'test',tags:[]})))))
    .mockResolvedValueOnce(new Response(JSON.stringify([{id:'nested',project:'test',tags:['orb-folder:notes/deep']}])));
  await expect(assertFolderHasNoWork('test','notes')).rejects.toThrow('Move the agents');
  expect(String(fetch.mock.calls[1][0])).toContain('offset=200');
});
it("allows a document folder but blocks a nested cron", async () => {
  const { assertFolderHasNoWork } = await import('../src/fileActions');
  const fetch = vi.spyOn(globalThis,'fetch').mockResolvedValueOnce(new Response('[]')).mockResolvedValueOnce(new Response('{"jobs":[]}'));
  await expect(assertFolderHasNoWork('test','notes')).resolves.toBeUndefined();
  fetch.mockResolvedValueOnce(new Response('[]')).mockResolvedValueOnce(new Response(JSON.stringify({jobs:[{id:'job',name:'Cron',folder:'notes/deep',enabled:true}]})));
  await expect(assertFolderHasNoWork('test','notes')).rejects.toThrow('crons');
});

it("moves a file to another project through its own route", async () => {
  const fetch = vi.spyOn(globalThis, "fetch").mockResolvedValue(new Response('{}', {status:200}));
  await transferProjectFile("test", "notes/context.md", "context.md", false, "other");
  expect(String(fetch.mock.calls[0][0])).toContain("/api/projects/test/file/transfer/other");
  expect(JSON.parse(String(fetch.mock.calls[0][1]?.body))).toEqual({path:"notes/context.md",destination:"context.md",copy:false});
  fetch.mockResolvedValue(new Response('Not found', {status:404}));
  await expect(transferProjectFile("test", "context.md", "context.md", false, "other")).rejects.toThrow("between projects");
});
it("keeps the folder flag on the clipboard and rejects a malformed one", async () => {
  setApiUrl("https://example.test");
  const payload = { slug: "test", path: "notes", copy: false, directory: true, backend: "https://example.test", account: "", nonce: "one" };
  expect(readFileReference("orb:file:" + JSON.stringify(payload))?.directory).toBe(true);
  expect(readFileReference("orb:file:" + JSON.stringify({...payload, directory: "yes"}))).toBeNull();
});
it("moves nested agents and crons with their folder and reports the ones left behind", async () => {
  const { moveFolderWork } = await import('../src/fileActions');
  const missions = [
    {id:'inside',project:'test',tags:['pinned','orb-folder:notes/deep']},
    {id:'sibling',project:'test',tags:['orb-folder:notes-archive']},
    {id:'stuck',project:'test',tags:['orb-folder:notes']},
  ];
  const sent: Array<{url:string;body:any}> = [];
  vi.spyOn(globalThis, 'fetch').mockImplementation(async (input, init) => {
    const url = String(input), body = init?.body ? JSON.parse(String(init.body)) : undefined;
    if (init?.method && init.method !== 'GET') {
      sent.push({url, body});
      return url.includes('/stuck/') ? new Response('busy', {status:409}) : new Response('{}');
    }
    if (url.includes('/crons')) return new Response(JSON.stringify({jobs:[{id:'job',name:'Cron',folder:'notes',enabled:true},{id:'far',name:'Far',folder:'other',enabled:true}]}));
    const id = url.match(/missions\/([a-z]+)$/)?.[1];
    return new Response(JSON.stringify(id ? missions.find(m => m.id === id) : missions));
  });
  await expect(moveFolderWork('test','notes','archive/renamed')).rejects.toThrow(/stuck.*could not follow/);
  expect(sent.find(call => call.url.includes('/inside/'))?.body).toEqual({project:'test',tags:['pinned','orb-folder:archive/renamed/deep']});
  expect(sent.some(call => call.url.includes('/sibling/'))).toBe(false);
  expect(sent.find(call => call.url.includes('/crons/job'))?.body).toMatchObject({folder:'archive/renamed'});
  expect(sent.some(call => call.url.includes('/crons/far'))).toBe(false);
});
