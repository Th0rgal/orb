/** Reasoning effort accepted by Core and each native harness. */
export const EFFORT_LADDER = ["low", "medium", "high", "xhigh", "max"] as const;
export type Effort = (typeof EFFORT_LADDER)[number];

export const EFFORT_BY_HARNESS: Readonly<Record<string, readonly Effort[]>> = {
  antigravity: ["low", "medium", "high"],
  codex: EFFORT_LADDER,
  claudecode: EFFORT_LADDER,
};

/** The efforts this harness accepts. Empty when it ignores effort entirely. */
export function supportedEfforts(backend?: string | null): readonly Effort[] {
  return (backend && EFFORT_BY_HARNESS[backend]) || [];
}

export function harnessSupportsEffort(backend?: string | null): boolean {
  return supportedEfforts(backend).length > 0;
}

/**
 * The effort actually usable on `backend`, or null for "let the backend pick"
 * (which is sent by omitting `model_effort` on create, and by an explicit empty
 * string on the settings patch — the core trims that to a clear).
 * An effort the harness no longer accepts normalizes away instead of riding
 * along into a request the server would reject.
 */
export function normalizeEffort(effort: string | null | undefined, backend?: string | null): Effort | null {
  const value = (effort ?? "").trim().toLowerCase();
  if (!value) return null;
  const allowed = supportedEfforts(backend);
  return allowed.includes(value as Effort) ? (value as Effort) : null;
}

const LABELS: Record<Effort, string> = {
  low: "Low",
  medium: "Medium",
  high: "High",
  xhigh: "XHigh",
  max: "Max",
};

/** Menu/chip text. Unset means the backend's own default, never a guessed level. */
export const DEFAULT_EFFORT_LABEL = "Default";

export function effortLabel(effort: string | null | undefined, backend?: string | null, model?: string | null): string {
  const value = (effort ?? "").trim().toLowerCase() as Effort;
  return LABELS[value] ?? defaultEffortLabel(backend, model);
}

/** Native agy-model (Carbon) and agy-demo (Argon) require an effort; unset uses our explicit High default. */
export function defaultEffortLabel(backend?:string|null, model?:string|null):string {
  if (backend !== "antigravity" || !model) return DEFAULT_EFFORT_LABEL;
  const variant = model.match(/^(?:agy-model|gemini-4-carbon|agy-demo)-(low|medium|high)$/)?.[1];
  if (variant) return `Default (${LABELS[variant as Effort]})`;
  if (model === "agy-model" || model === "gemini-4-carbon" || model === "gemini-4-carbon-eap" || model === "agy-demo") {
    return "Default (High)";
  }
  return DEFAULT_EFFORT_LABEL;
}

/** Compatibility for missions saved with the CLI's effort-specific Carbon/Argon IDs. */
export function antigravityBaseModel(model?: string | null): string | undefined {
  if (!model) return undefined;
  if (/^(?:agy-model|gemini-4-carbon)(?:-(?:low|medium|high)|-eap)?$/.test(model)) return "agy-model";
  return model.replace(/^agy-demo-(low|medium|high)$/, "agy-demo");
}
