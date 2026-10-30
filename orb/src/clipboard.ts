/**
 * Clipboard writes that fail loudly. The Tauri webview and any non-secure
 * context can leave `navigator.clipboard` undefined, and a user gesture can
 * still be refused by the platform — a silent no-op there looks exactly like a
 * successful copy, so every caller gets a message it can show instead.
 */
export async function copyText(text: string): Promise<void> {
  const clipboard = navigator.clipboard;
  if (!clipboard?.writeText) throw new Error("Clipboard is unavailable in this window.");
  try {
    await clipboard.writeText(text);
  } catch (e) {
    throw new Error(`Copy was refused: ${e instanceof Error ? e.message : String(e)}`);
  }
}

let activeLocalReference = "";
let activeLocalUnsynced = false;
const retiredReferences = new Set<string>();

function rememberRetired(text: string): void {
  if (!text) return;
  retiredReferences.add(text);
  if (retiredReferences.size > 128) {
    const oldest = retiredReferences.values().next().value;
    if (oldest !== undefined) retiredReferences.delete(oldest);
  }
}

export function retireClipboardReference(text?: string): void {
  if (!text) return;
  rememberRetired(text);
  if (activeLocalReference === text) {
    activeLocalReference = "";
    activeLocalUnsynced = false;
  }
}

export function retireActiveClipboardReference(): void {
  if (activeLocalReference) rememberRetired(activeLocalReference);
  activeLocalReference = "";
  activeLocalUnsynced = false;
}

export function restoreClipboardReference(text: string, unsynced: boolean): void {
  if (!text) return;
  retiredReferences.delete(text);
  activeLocalReference = text;
  activeLocalUnsynced = unsynced;
}

export function isClipboardReferenceRetired(text: string): boolean {
  return !!text && retiredReferences.has(text);
}

export function isUnsyncedClipboard(text: string): boolean {
  return !!text && activeLocalReference === text && activeLocalUnsynced;
}

/**
 * Write an Orb clipboard reference, recording when the system clipboard could
 * not be updated so a subsequent paste prefers the active in-app reference over
 * stale system clipboard contents.
 */
export async function writeClipboardReference(text: string, clipboardData?: DataTransfer | null): Promise<string> {
  if (activeLocalReference && activeLocalReference !== text) rememberRetired(activeLocalReference);
  activeLocalReference = text;
  if (clipboardData) {
    clipboardData.setData("text/plain", text);
    activeLocalUnsynced = false;
    return text;
  }
  activeLocalUnsynced = true;
  try {
    await copyText(text);
    if (activeLocalReference === text) activeLocalUnsynced = false;
  } catch {
    // Keep `activeLocalUnsynced` true so in-app paste uses `text` rather than
    // an older reference still in the system clipboard.
  }
  return text;
}
