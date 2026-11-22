import { nativeInvoke } from "./native";
export async function readPalomaPub(): Promise<string> {
  try {
    const invoke = nativeInvoke();
    if (invoke) {
      const v = await invoke("paloma_ssh_pubkey");
      if (v) return v.trim();
    }
  } catch {
    /* fall through */
  }
  // Only the Vite dev server serves this endpoint. Packaged WebViews serve index.html for unknown paths.
  if (!import.meta.env.DEV) return "";
  try {
    const r = await fetch("/__paloma_pub");
    if (r.ok && r.headers.get("content-type")?.split(";")[0].trim() === "text/plain") {
      return (await r.text()).trim();
    }
  } catch {
    /* ignore */
  }
  return "";
}
