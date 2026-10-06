import { describe, expect, it } from "vitest";
import { destinationHarnessChoices } from "../src/harness-models";
const core = [{ backend: {id:"antigravity",name:"Antigravity"}, models:[{value:"core-only",label:"Core model"}] }];
describe("destination account models", () => {
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

it("drops retired Gemini CLI from stale Core choices without removing Antigravity models", () => {
  const retired = {backend: {id: "gemini", name: "Gemini CLI"}, models: [{value: "gemini-old", label: "Old model"}]};
  const choices = destinationHarnessChoices([retired, ...core], "local", [["gemini-account", "Gemini account model"]]);
  expect(choices.map(choice => choice.backend.id)).toEqual(["antigravity"]);
  expect(choices[0].models[0].value).toBe("gemini-account");
  expect(destinationHarnessChoices([retired], "local", [])).toEqual([]);
});
