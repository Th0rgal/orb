import type { HarnessChoice } from "./api";

/** Native account models belong to an execution destination. */
export function destinationHarnessChoices(
  core: HarnessChoice[],
  machine: string,
  accountModels: [string, string][],
): HarnessChoice[] {
  if (machine === "core") return core;
  const choices = core.filter(choice => choice.backend.id !== "antigravity");
  if (accountModels.length) choices.push({
    backend: { id: "antigravity", name: "Antigravity" },
    models: accountModels.map(([value, label]) => ({ value, label })),
  });
  return choices;
}
