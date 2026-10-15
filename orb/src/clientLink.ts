import { getApiUrl } from "./api";
import { nativeInvoke } from "./clientRuns";

/** Whether Orb desktop streams local runs to Core over the client link; the
 * assistant transcript is then delivered by that journal, not posted here. */
export async function clientLinkActive(): Promise<boolean> {
  const invoke = nativeInvoke();
  if (!invoke) return false;
  try { return await invoke("client_link_active", { apiUrl: getApiUrl() }) === true; }
  catch { return false; }
}
