import type { HarnessChoice } from "./api";
import { harnessRank } from "./harnesses";

/** Native account models belong to an execution destination. On Core and remote
 * nodes, Core projects its connected Google Antigravity sign-in before spawn, so
 * Core's Antigravity catalog keeps the harness selectable while per-machine CLI
 * discovery resolves; this computer ("local") uses only its own sign-in. */
export function destinationHarnessChoices(
  core: HarnessChoice[],
  machine: string,
  accountModels: [string, string][],
  localVibeInstalled = false,
  localClaudeModels: [string, string][] = [],
): HarnessChoice[] {
  const coreAntigravity = core.find(choice => choice.backend.id === "antigravity");
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
  const antigravityModels = accountModels.length
    ? accountModels.map(([value, label]) => ({ value, label }))
    : machine !== "local" && coreAntigravity?.models.length
      ? coreAntigravity.models
      : [];
  if (antigravityModels.length) {
    choices.push({
      backend: { id: "antigravity", name: "Antigravity CLI", native_plan: true },
      models: antigravityModels,
    });
    choices.sort((a, b) => harnessRank(a.backend.id) - harnessRank(b.backend.id));
  }
  return choices;
}
