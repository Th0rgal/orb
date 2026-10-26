import type { HarnessChoice } from "./api";

/** Native account models belong to an execution destination. */
export function destinationHarnessChoices(
  core: HarnessChoice[],
  machine: string,
  accountModels: [string, string][],
  localVibeInstalled = false,
  localClaudeModels: [string, string][] = [],
): HarnessChoice[] {
  const choices = core.filter(choice => choice.backend.id !== "antigravity" && choice.backend.id !== "gemini");
  // This computer's Claude Code lists what its own sign-in can run.
  if (machine === "local" && localClaudeModels.length) {
    const models = localClaudeModels.map(([value, label]) => ({ value, label: `This computer — ${label}` }));
    const index = choices.findIndex(choice => choice.backend.id === "claudecode");
    if (index >= 0) choices[index] = { ...choices[index], models };
    else choices.unshift({ backend: { id: "claudecode", name: "Claude Code" }, models });
  }
  if (machine === "local" && localVibeInstalled && !choices.some(choice => choice.backend.id === "vibe")) {
    choices.push({
      backend: { id: "vibe", name: "Mistral Vibe" },
      models: [{ value: "mistral/mistral-vibe-cli-latest", label: "Mistral Vibe", description: "Uses this computer's native Vibe account" }],
    });
  }
  if (accountModels.length) choices.push({
    backend: { id: "antigravity", name: "Antigravity CLI", native_plan: true },
    models: accountModels.map(([value, label]) => ({ value, label })),
  });
  return choices;
}
