import { afterEach, describe, expect, it, vi } from "vitest";
import { ApiError } from "../src/api";
import * as api from "../src/api";
import { destinationHarnessChoices } from "../src/harness-models";
import { refreshNodeAntigravityModels } from "../src/harnessPick";
const core = [{ backend: {id:"antigravity",name:"Google Antigravity"}, models:[{value:"agy-model",label:"Google Antigravity — Gemini 4 Carbon"}] }];
afterEach(() => { vi.restoreAllMocks(); vi.useRealTimers(); });
describe("destination account models", () => {
  it("offers installed local Vibe without a Core Mistral account or catalog entry", () => {
    const choices = destinationHarnessChoices([], "local", [], true);
    expect(choices.map(choice => choice.backend.id)).toEqual(["vibe"]);
    expect(choices[0].models[0].value).toBe("mistral/mistral-vibe-cli-latest");
    expect(destinationHarnessChoices([], "core", [], true)).toEqual([]);
    expect(destinationHarnessChoices([], "local", [], false)).toEqual([]);
    expect(destinationHarnessChoices(choices, "local", [], true)).toEqual(choices);
  });
  it("never substitutes the Core Antigravity account on this computer", () => {
    expect(destinationHarnessChoices(core, "local", [["agy-demo","Gemini 4 Argon"]])[0].models.map(m=>m.value)).toEqual(["agy-demo"]);
    expect(destinationHarnessChoices(core, "local", [])).toEqual([]);
  });
  it("keeps Core's connected Antigravity catalog on Core and fleet nodes until machine discovery resolves", () => {
    for (const machine of ["core", "nimrud"]) {
      const pending = destinationHarnessChoices(core, machine, []);
      expect(pending[0].backend).toEqual({ id: "antigravity", name: "Antigravity CLI", native_plan: true });
      expect(pending[0].models.map(m => m.value)).toEqual(["agy-model"]);
      expect(destinationHarnessChoices(core, machine, [["agy-demo", "Gemini 4 Argon"]])[0].models.map(m => m.value)).toEqual(["agy-demo"]);
    }
  });
  it("sorts Antigravity in composer harness order alongside other harnesses", () => {
    const codex = {backend:{id:"codex",name:"Codex"},models:[{value:"model",label:"Model"}]};
    const vibe = {backend:{id:"vibe",name:"Mistral Vibe"},models:[{value:"mistral/devstral",label:"Devstral"}]};
    expect(destinationHarnessChoices([...core,codex,vibe],"core",[]).map(c=>c.backend.id)).toEqual(["codex","antigravity","vibe"]);
  });
  it("supports a node-only installation without Core having the CLI", () => {
    expect(destinationHarnessChoices([],"old-agent",[["agy-demo","Gemini 4 Argon"]])[0].backend.id).toBe("antigravity");
  });
  it("skips side-question pseudo-targets and does not retry permanent 404 node lookups", async () => {
    vi.useFakeTimers();
    const spy = vi.spyOn(api, "listNodeAntigravityModels").mockRejectedValue(new ApiError(404, "Unknown node"));
    await refreshNodeAntigravityModels("side");
    expect(spy).not.toHaveBeenCalled();
    await refreshNodeAntigravityModels("retired-node");
    expect(spy).toHaveBeenCalledTimes(1);
    await vi.advanceTimersByTimeAsync(20_000);
    expect(spy).toHaveBeenCalledTimes(1);
  });
});

describe("this computer's Claude Code models", () => {
  const claude = {backend:{id:"claudecode",name:"Claude Code"},models:[{value:"claude-sonnet-5",label:"Claude (Subscription) — Claude Sonnet 5"}]};
  const local: [string,string][] = [["claude-opus-5-5","Claude Opus 5.5"],["claude-sonnet-5-5","Claude Sonnet 5.5"]];
  it("replaces Core's list on this computer only", () => {
    expect(destinationHarnessChoices([claude],"local",[],false,local)[0].models.map(m=>m.value)).toEqual(["claude-opus-5-5","claude-sonnet-5-5"]);
    expect(destinationHarnessChoices([claude],"local",[],false,local)[0].models[1].label).toBe("This computer — Claude Sonnet 5.5");
    expect(destinationHarnessChoices([claude],"core",[],false,local)).toEqual([claude]);
    expect(destinationHarnessChoices([claude],"old-agent",[],false,local)).toEqual([claude]);
  });
  it("keeps Core's list while discovery is pending or failed", () => {
    expect(destinationHarnessChoices([claude],"local",[],false,[])).toEqual([claude]);
  });
  it("does not mutate Core's shared choices", () => {
    const core = [claude];
    destinationHarnessChoices(core,"local",[],false,local);
    expect(core[0].models[0].value).toBe("claude-sonnet-5");
  });
  it("orders Opus first even if local CLI discovery emitted Fable or Mythos ahead of Opus", () => {
    const unordered: [string,string][] = [
      ["claude-fable-5-2","Claude Fable 5.2"],
      ["claude-mythos-5-2","Claude Mythos 5.2"],
      ["claude-opus-5-5","Claude Opus 5.5"],
      ["claude-sonnet-5-5","Claude Sonnet 5.5"],
    ];
    expect(destinationHarnessChoices([claude],"local",[],false,unordered)[0].models.map(m=>m.value)).toEqual([
      "claude-opus-5-5",
      "claude-fable-5-2",
      "claude-mythos-5-2",
      "claude-sonnet-5-5",
    ]);
  });
});

it("drops retired Gemini CLI from stale Core choices without removing Antigravity models", () => {
  const retired = {backend: {id: "gemini", name: "Gemini CLI"}, models: [{value: "gemini-old", label: "Old model"}]};
  const choices = destinationHarnessChoices([retired, ...core], "local", [["gemini-account", "Gemini account model"]]);
  expect(choices.map(choice => choice.backend.id)).toEqual(["antigravity"]);
  expect(choices[0].models[0].value).toBe("gemini-account");
  expect(destinationHarnessChoices([retired], "local", [])).toEqual([]);
});

describe("this computer's OpenCode models", () => {
  const coreOpenCode = {
    backend: { id: "opencode", name: "OpenCode", native_plan: true },
    models: [{ value: "builtin/smart", label: "Routing — smart" }],
  };
  const localOpenCode: [string, string][] = [
    ["orbrouter/builtin/smart", "Routing — Smart"],
    ["orbrouter/builtin/fast", "Routing — Fast"],
    ["orbrouter/anthropic/claude-opus-5-5", "Orb Router (Anthropic) — claude-opus-5-5"],
  ];
  it("uses local OpenCode models on this computer while preserving Core's list elsewhere", () => {
    expect(destinationHarnessChoices([coreOpenCode], "local", [], false, [], localOpenCode)[0].models.map(m => m.value)).toEqual([
      "orbrouter/builtin/smart",
      "orbrouter/builtin/fast",
      "orbrouter/anthropic/claude-opus-5-5",
    ]);
    expect(destinationHarnessChoices([coreOpenCode], "core", [], false, [], localOpenCode)).toEqual([coreOpenCode]);
    expect(destinationHarnessChoices([coreOpenCode], "nimrud", [], false, [], localOpenCode)).toEqual([coreOpenCode]);
  });
  it("exposes local OpenCode on this computer even when Core has no OpenCode catalog", () => {
    const res = destinationHarnessChoices([], "local", [], false, [], localOpenCode);
    expect(res).toHaveLength(1);
    expect(res[0].backend).toEqual({ id: "opencode", name: "OpenCode", native_plan: true });
    expect(res[0].models[0].value).toBe("orbrouter/builtin/smart");
  });
});
