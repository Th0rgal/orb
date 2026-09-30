import { api } from "./api";
export type SshAddress = { name: string; host: string; user: string; port: number; note: string };
export type SshHost = SshAddress & { id: string; revision: number };
export const legacySshKey = "orb.customMachines";
export function validAddress(a: SshAddress): boolean {
  return !!a.name.trim() && a.name.trim().length <= 200 && a.host.length <= 253
    && /^[a-zA-Z0-9[\]_:][a-zA-Z0-9.\-[\]_:]*$/.test(a.host.trim())
    && /^[a-zA-Z0-9_.][a-zA-Z0-9_.-]*$/.test(a.user.trim()) && a.user.length <= 128
    && Number.isInteger(a.port) && a.port > 0 && a.port <= 65535 && a.note.length <= 2000;
}
export function legacyAddresses(): SshAddress[] {
  try {
    const data: unknown = JSON.parse(localStorage.getItem(legacySshKey) ?? "[]");
    return Array.isArray(data) ? data.filter(a => a && typeof a.name === "string" && typeof a.host === "string" && typeof a.user === "string" && typeof a.note === "string" && validAddress(a)).map(({name,host,user,port,note}) => ({name,host,user,port,note})) : [];
  } catch { return []; }
}
export function sameAddress(a: SshAddress, b: SshAddress): boolean {
  return a.host.trim().toLowerCase() === b.host.trim().toLowerCase() && a.user.trim() === b.user.trim() && a.port === b.port;
}
const path = "/api/settings/ssh-hosts";
export function isSshHost(value: unknown): value is SshHost {
  if (!value || typeof value !== "object") return false;
  const h = value as SshHost;
  return typeof h.id === "string" && Number.isSafeInteger(h.revision) && h.revision >= 1 && typeof h.name === "string" && typeof h.host === "string" && typeof h.user === "string" && typeof h.note === "string" && validAddress(h);
}
export async function listSshHosts(signal?: AbortSignal): Promise<SshHost[]> {
  const value = await api<unknown>(path, {signal});
  if (!Array.isArray(value) || !value.every(isSshHost)) throw new Error("The backend returned an invalid SSH address book.");
  return value;
}
export const saveSshHost = (address: SshAddress, previous?: SshHost) => api<SshHost>(previous ? `${path}/${encodeURIComponent(previous.id)}` : path, {
  method: previous ? "PUT" : "POST", headers: { "Content-Type": "application/json" },
  body: JSON.stringify({...address, ...(previous ? {revision: previous.revision} : {})}),
});
export const deleteSshHost = (host: SshHost) => api<void>(`${path}/${encodeURIComponent(host.id)}?revision=${host.revision}`, {method: "DELETE"});
