import { afterEach, expect, it, vi } from "vitest";
import { clearConnection, listHarnessChoices, setConnection } from "../src/api";
import { LOCAL_HARNESSES } from "../src/localAgents";

afterEach(() => { clearConnection(); localStorage.clear(); vi.unstubAllGlobals(); });

it("excludes Gemini CLI from live and offline cached catalogs", async () => {
  localStorage.clear();
  setConnection("http://retired-harness.test", "fixture");
  const backends = [{id: "gemini", name: "Gemini CLI"}, {id: "antigravity", name: "Antigravity CLI"}];
  const models = {backends: {gemini: [{value: "gemini-old", label: "Old"}], antigravity: [{value: "gemini-account", label: "Account model"}]}};
  vi.stubGlobal("fetch", vi.fn(async (url: string) => new Response(JSON.stringify(
    url.endsWith("/api/backends") ? backends : url.endsWith("/api/providers/backend-models") ? models : [],
  ))));
  expect((await listHarnessChoices()).map(choice => choice.backend.id)).toEqual(["antigravity"]);
  vi.stubGlobal("fetch", vi.fn(async () => { throw new TypeError("offline"); }));
  expect((await listHarnessChoices()).map(choice => choice.backend.id)).toEqual(["antigravity"]);
  expect(LOCAL_HARNESSES).not.toContain("gemini");
  expect(LOCAL_HARNESSES).toContain("antigravity");
});
