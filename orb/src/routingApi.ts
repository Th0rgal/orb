import { api, connectionVersion } from "./api";

export interface ChainEntry {
  provider_id: string;
  model_id: string;
}

export interface ModelChain {
  id: string;
  name: string;
  entries: ChainEntry[];
  is_default: boolean;
  /**
   * Strip `<think>…</think>` blocks and stray orphan `</think>` tags from
   * responses routed through this chain. Useful for models (MiniMax, GLM) that
   * leak reasoning into `content`.
   */
  strip_thinking: boolean;
  created_at: string;
  updated_at: string;
  /** Client-only: why this row cannot be shown or edited (never sent to Core). */
  malformed?: string;
}

const text = (value: unknown) => (typeof value === "string" ? value : "");

/**
 * The one reader of Core's chain list. A row without a valid `entries` list
 * (an older Core sends `models_json` instead) is kept, marked `malformed`, and
 * shown with an inline error: it must never blank the tab, and it is never
 * editable, because saving it would overwrite the server's real models.
 */
export function normalizeChains(rows: unknown): ModelChain[] {
  if (!Array.isArray(rows)) throw new Error("Core returned an unexpected Fallback Chains response.");
  return rows.map((row, index) => {
    const r = (row && typeof row === "object" ? row : {}) as Record<string, unknown>;
    const id = text(r.id), name = text(r.name) || id || `Chain ${index + 1}`;
    const entries = Array.isArray(r.entries) ? r.entries : null;
    const kept = text(r.malformed); // a row already marked in the local cache stays marked
    const valid = !kept && !!id && !!entries && entries.every(e => !!e && typeof e === "object" && typeof (e as ChainEntry).provider_id === "string" && typeof (e as ChainEntry).model_id === "string");
    if (valid) return { ...(r as unknown as ModelChain), name };
    const malformed = kept ? kept : !id ? "Core sent this chain without an id."
      : "models_json" in r && !entries ? "Core sent this chain in an older format (models_json instead of entries). Update the server to view or edit it."
      : "Core sent this chain without a valid list of models.";
    return { id: id || `malformed:${index}`, name, entries: [], is_default: r.is_default === true, strip_thinking: r.strip_thinking === true, created_at: text(r.created_at), updated_at: text(r.updated_at), malformed };
  });
}

export interface ResolvedEntry {
  provider_id: string;
  model_id: string;
  account_id: string;
  has_credentials: boolean;
  auth_kind: "api_key" | "oauth" | "none";
  has_base_url: boolean;
  rpm_limit?: number | null;
  max_concurrency?: number | null;
  model_rpm_limit?: number | null;
  model_tpm_limit?: number | null;
  model_max_concurrency?: number | null;
}

export interface RateLimitSnapshot {
  requests_limit: number | null;
  requests_remaining: number | null;
  requests_reset: string | null;
  tokens_limit: number | null;
  tokens_remaining: number | null;
  tokens_reset: string | null;
  input_tokens_limit: number | null;
  input_tokens_remaining: number | null;
  output_tokens_limit: number | null;
  output_tokens_remaining: number | null;
  key_rpm_limit?: number | null;
  updated_at: string;
}

export interface AccountHealthSnapshot {
  account_id: string;
  provider_id?: string | null;
  is_healthy?: boolean;
  cooldown_remaining_secs?: number | null;
  cooldown_secs_remaining?: number | null;
  consecutive_failures?: number;
  last_failure_reason?: string | null;
  last_failure_at?: string | null;
  total_requests?: number;
  total_successes?: number;
  total_rate_limits?: number;
  total_errors?: number;
  avg_latency_ms?: number | null;
  total_input_tokens?: number;
  total_output_tokens?: number;
  is_degraded?: boolean;
  rate_limit_snapshot?: RateLimitSnapshot | null;
  /** available, out_of_credit, auth_failed, quota_exhausted, rate_limited or cooldown (older cores omit it). */
  account_state?: "available" | "out_of_credit" | "auth_failed" | "quota_exhausted" | "rate_limited" | "cooldown";
  /** When the circuit breaker lets the next probe request through. */
  next_probe_at?: string | null;
}

export interface FallbackEvent {
  timestamp: string;
  chain_id: string;
  from_provider: string;
  from_model: string;
  from_account_id: string;
  reason: string;
  cooldown_secs: number | null;
  to_provider: string | null;
  latency_ms: number | null;
  attempt_number: number;
  chain_length: number;
}

export interface ChainTestResult {
  ok: boolean;
  status: number;
  response: {
    model?: string;
    choices?: { message: { content: string | null } }[];
    error?: { message?: string };
    [key: string]: unknown;
  };
}

export interface RoutingCatalog {
  providers: {
    id: string;
    name: string;
    models: { id: string; name: string }[];
  }[];
  configured_ids?: string[];
}
const root = "/api/model-routing";
const chainPath = (id: string) => `${root}/chains/${encodeURIComponent(id)}`;
// Memory-only, connection-scoped cache. Never reuse another server/account's data.
function cached<T>(load: () => Promise<T>, ttl: number) {
  let state: { version: number; at: number; value?: T; pending?: Promise<T> } | undefined;
  return (force = false): Promise<T> => {
    const version = connectionVersion();
    if (!state || state.version !== version) state = { version, at: 0 };
    const current = state;
    if (current.pending) return current.pending;
    if (!force && current.value !== undefined && Date.now() - current.at < ttl) return Promise.resolve(current.value);
    current.pending = load().then(value => {
      current.value = value;
      current.at = Date.now();
      return value;
    }).finally(() => { current.pending = undefined; });
    return current.pending;
  };
}
export const listChains = cached(() => api<unknown>(`${root}/chains`).then(normalizeChains), 30_000);
export const listHealth = () => api<AccountHealthSnapshot[]>(`${root}/health`);
export const listEvents = () => api<FallbackEvent[]>(`${root}/events`);
export const routingCatalog = cached(() =>
  api<RoutingCatalog>(
    "/api/providers?include_all=true&include_unverified=true",
  ), 300_000);
export type ChainDraft = Pick<
  ModelChain,
  "id" | "name" | "entries" | "strip_thinking"
>;
export const saveChain = (draft: ChainDraft, existing: boolean) =>
  api<ModelChain>(existing ? chainPath(draft.id) : `${root}/chains`, {
    method: existing ? "PUT" : "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(draft),
  });
export const setDefaultChain = (id: string) =>
  api<ModelChain>(chainPath(id), {
    method: "PUT",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ is_default: true }),
  });
export const deleteChain = (id: string) =>
  api(chainPath(id), { method: "DELETE" });
export const resolveChain = (id: string) =>
  api<ResolvedEntry[]>(`${chainPath(id)}/resolve`);
export const testChain = (id: string) =>
  api<ChainTestResult>(`${chainPath(id)}/test`, { method: "POST" });
export const clearCooldown = (id: string) =>
  api(`${root}/health/${encodeURIComponent(id)}/clear`, { method: "POST" });

export interface ModelDiscovery {
  connections: {
    provider_id: string;
    access_profile: string;
    status: string;
    source: "discovery" | "stale_discovery" | "snapshot";
    diagnostic?: string;
    checked_at: string;
    last_success?: { observed_at: string; completeness: "complete" | "partial"; models: { id: string }[] };
  }[];
}
export const modelDiscovery = () => api<ModelDiscovery>("/api/providers/discovery");
export const refreshModelDiscovery = () => api("/api/providers/catalog/refresh", { method: "POST" });
export function modelEvidence(discovery: ModelDiscovery | undefined, provider: string, model: string): string {
  const connections = discovery?.connections?.filter(c => c.provider_id === provider) ?? [];
  if (connections.some(c => c.status === "discovered" && c.last_success?.models.some(m => m.id === model))) return "Listed by provider";
  if (connections.some(c => c.last_success?.models.some(m => m.id === model))) return "Previously listed · refresh failed";
  return "Fallback / unverified";
}
