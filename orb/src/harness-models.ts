import type { HarnessChoice } from "./api";

/** Native account models belong to an execution destination. */
export function destinationHarnessChoices(
  core: HarnessChoice[],
  _machine: string,
  accountModels: [string, string][],
): HarnessChoice[] {
  const choices = core.filter(choice => choice.backend.id !== "antigravity");
  if (accountModels.length) choices.push({
    backend: { id: "antigravity", name: "Antigravity CLI" },
    models: accountModels.map(([value, label]) => ({ value, label })),
  });
  return choices;
}
