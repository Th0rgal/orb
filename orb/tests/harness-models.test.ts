import { describe, expect, it } from "vitest";
import { destinationHarnessChoices } from "../src/harness-models";
const core = [{ backend: {id:"antigravity",name:"Antigravity"}, models:[{value:"core-only",label:"Core model"}] }];
describe("destination account models", () => {
  it("offers installed local Vibe without a Core Mistral account or catalog entry", () => {
    const choices = destinationHarnessChoices([], "local", [], true);
    expect(choices.map(choice => choice.backend.id)).toEqual(["vibe"]);
    expect(choices[0].models[0].value).toBe("mistral/mistral-vibe-cli-latest");
    expect(destinationHarnessChoices([], "core", [], true)).toEqual([]);
    expect(destinationHarnessChoices([], "local", [], false)).toEqual([]);
    expect(destinationHarnessChoices(choices, "local", [], true)).toEqual(choices);
  });
  it("does not substitute the Core account for a local or node account", () => {
    for (const machine of ["local", "old-agent", "core"]) {
      expect(destinationHarnessChoices(core, machine, [["agy-demo","Gemini 4 Argon"]])[0].models.map(m=>m.value)).toEqual(["agy-demo"]);
      expect(destinationHarnessChoices(core, machine, [])).toEqual([]);
    }
  });
  it("keeps other harnesses available while native discovery is pending", () => {
    const codex = {backend:{id:"codex",name:"Codex"},models:[{value:"model",label:"Model"}]};
    expect(destinationHarnessChoices([...core,codex],"core",[])).toEqual([codex]);
  });
  it("supports a node-only installation without Core having the CLI", () => {
    expect(destinationHarnessChoices([],"old-agent",[["agy-demo","Gemini 4 Argon"]])[0].backend.id).toBe("antigravity");
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
});

it("drops retired Gemini CLI from stale Core choices without removing Antigravity models", () => {
  const retired = {backend: {id: "gemini", name: "Gemini CLI"}, models: [{value: "gemini-old", label: "Old model"}]};
  const choices = destinationHarnessChoices([retired, ...core], "local", [["gemini-account", "Gemini account model"]]);
  expect(choices.map(choice => choice.backend.id)).toEqual(["antigravity"]);
  expect(choices[0].models[0].value).toBe("gemini-account");
  expect(destinationHarnessChoices([retired], "local", [])).toEqual([]);
});
