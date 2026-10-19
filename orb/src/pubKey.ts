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
  try {
    const r = await fetch("/__paloma_pub");
    if (r.ok) return (await r.text()).trim();
  } catch {
    /* ignore */
  }
  return "";
}
