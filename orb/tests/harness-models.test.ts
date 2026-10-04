import { describe, expect, it } from "vitest";
import { destinationHarnessChoices } from "../src/harness-models";
const core = [{ backend: {id:"antigravity",name:"Antigravity"}, models:[{value:"core-only",label:"Core model"}] }];
describe("destination account models", () => {
  it("does not substitute the Core account for a local or node account", () => {
    for (const machine of ["local", "old-agent"]) {
      expect(destinationHarnessChoices(core, machine, [["agy-demo","Gemini 4 Argon"]])[0].models.map(m=>m.value)).toEqual(["agy-demo"]);
      expect(destinationHarnessChoices(core, machine, [])).toEqual([]);
    }
    expect(destinationHarnessChoices(core,"core",[["local-only","Local model"]])).toEqual(core);
  });
  it("supports a node-only installation without Core having the CLI", () => {
    expect(destinationHarnessChoices([],"old-agent",[["agy-demo","Gemini 4 Argon"]])[0].backend.id).toBe("antigravity");
  });
});
