import { api } from "./api";

export interface ProxyApiKeySummary {
  id: string;
  name: string;
  key_prefix: string;
  created_at: string;
  last_used_at: string | null;
}

export interface ProxyApiKeyCreated {
  id: string;
  name: string;
  key: string;
  created_at: string;
}

export interface ProxyApiKeyCleanupResult {
  dry_run: boolean;
  cutoff: string;
  keys: ProxyApiKeySummary[];
}

const root = "/api/proxy-keys";
export const listProxyApiKeys = () => api<ProxyApiKeySummary[]>(root);
export const createProxyApiKey = (name: string) => api<ProxyApiKeyCreated>(root, {
  method: "POST",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({ name }),
});
export const deleteProxyApiKey = (id: string) =>
  api(`${root}/${encodeURIComponent(id)}`, { method: "DELETE" });
export const previewProxyApiKeyCleanup = (days: number) => api<ProxyApiKeyCleanupResult>(`${root}/cleanup`, {
  method: "POST",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({ max_age_days: days, dry_run: true }),
});
