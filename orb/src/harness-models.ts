import type { HarnessChoice } from "./api";

/** Native account models belong to an execution destination. */
export function destinationHarnessChoices(
  core: HarnessChoice[],
  machine: string,
  accountModels: [string, string][],
  localVibeInstalled = false,
): HarnessChoice[] {
  const choices = core.filter(choice => choice.backend.id !== "antigravity" && choice.backend.id !== "gemini");
  if (machine === "local" && localVibeInstalled && !choices.some(choice => choice.backend.id === "vibe")) {
    choices.push({
      backend: { id: "vibe", name: "Mistral Vibe" },
      models: [{ value: "mistral/mistral-vibe-cli-latest", label: "Mistral Vibe", description: "Uses this computer's native Vibe account" }],
    });
  }
  if (accountModels.length) choices.push({
    backend: { id: "antigravity", name: "Antigravity CLI" },
    models: accountModels.map(([value, label]) => ({ value, label })),
  });
  return choices;
}
