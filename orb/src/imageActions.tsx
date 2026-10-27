import { Show, createSignal, onCleanup } from "solid-js";
import { PopupMenu, type MenuEntry } from "./Menu";
import { copyText } from "./clipboard";
import { nativeInvoke } from "./native";
import { imageMime } from "./imageTypes";
import * as Ic from "./icons";

/** Save, copy and context-menu actions shared by every image surface (lightbox,
 * Files pane, transcript images). Images are always shown from `blob:` or `data:`
 * URLs whose bytes were already fetched through the authenticated file API, so
 * the actions read those bytes back locally and never build a network URL. */
const EXTENSIONS: Record<string, string> = { "image/png": "png", "image/jpeg": "jpg", "image/gif": "gif", "image/webp": "webp", "image/avif": "avif", "image/bmp": "bmp", "image/x-icon": "ico", "image/svg+xml": "svg" };

export async function imageBlob(src: string): Promise<Blob> {
  if (!/^(blob|data):/i.test(src)) throw new Error("This image can only be saved from a local copy.");
  const response = await fetch(src);
  if (!response.ok) throw new Error("Couldn’t read the image.");
  return response.blob();
}

/** The label as a file name, keeping its extension or adding one from the bytes' type. */
export function imageFileName(label: string, mime: string): string {
  const base = (label.split(/[\\/]/).at(-1) ?? "").replace(/[\0-\x1f:*?"<>|#]/g, "").trim() || "image";
  if (imageMime(base)) return base;
  return `${base}.${EXTENSIONS[mime.split(";")[0].toLowerCase()] ?? "png"}`;
}

const base64 = async (blob: Blob) => {
  const bytes = new Uint8Array(await blob.arrayBuffer());
  let binary = "";
  for (let i = 0; i < bytes.length; i += 0x8000) binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(binary);
};

/** Opens the native Save dialog in Orb desktop (the user picks the path; the
 * webview never names one), or a browser download elsewhere. Resolves false when cancelled. */
export async function saveImage(src: string, label: string): Promise<boolean> {
  const blob = await imageBlob(src);
  const name = imageFileName(label, blob.type || imageMime(label) || "image/png");
  const invoke = nativeInvoke();
  if (invoke) return (await invoke<string | null>("save_file_as", { name, dataBase64: await base64(blob) })) !== null;
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url; a.download = name; a.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
  return true;
}

/** Copies image data; the clipboard only accepts PNG everywhere, so other types are re-encoded. */
export async function copyImage(src: string): Promise<void> {
  const clipboard = navigator.clipboard;
  if (!clipboard?.write || typeof ClipboardItem === "undefined") throw new Error("Clipboard is unavailable in this window.");
  const png = (async () => {
    const blob = await imageBlob(src);
    if (blob.type === "image/png") return blob;
    const image = new Image();
    image.src = src;
    await image.decode();
    const canvas = document.createElement("canvas");
    canvas.width = image.naturalWidth; canvas.height = image.naturalHeight;
    canvas.getContext("2d")!.drawImage(image, 0, 0);
    return new Promise<Blob>((resolve, reject) => canvas.toBlob(b => b ? resolve(b) : reject(new Error("Couldn’t encode the image.")), "image/png"));
  })();
  // Safari requires the ClipboardItem synchronously inside the gesture, with a promised blob.
  try { await clipboard.write([new ClipboardItem({ "image/png": png })]); }
  catch (e) { throw new Error(`Copy was refused: ${e instanceof Error ? e.message : String(e)}`); }
}

/** Right-click menu state for one image surface, replacing the webview's
 * Reload / Inspect Element there only. `src()` is null while nothing can be saved. */
export function createImageMenu(image: () => { src: string | null; label: string; path?: string }) {
  const [point, setPoint] = createSignal<{ x: number; y: number } | null>(null);
  const [status, setStatus] = createSignal("");
  let timer: ReturnType<typeof setTimeout> | undefined;
  onCleanup(() => clearTimeout(timer));
  const report = (message: string) => { clearTimeout(timer); setStatus(message); timer = setTimeout(() => setStatus(""), 2500); };
  const run = (action: () => Promise<unknown>, done?: string) => void action().then(ok => ok !== false && done && report(done), e => report(e instanceof Error ? e.message : String(e)));
  // A mission file keeps its own name and extension; other images are named after their label.
  const save = () => { const { src, label, path } = image(); if (src) run(() => saveImage(src, path ?? label), "Image saved"); };
  const items = (): MenuEntry[] => {
    const { src, path } = image();
    return [
      { kind: "item", label: "Save image as…", icon: Ic.DownloadIcon, disabled: !src, onClick: save },
      { kind: "item", label: "Copy image", icon: Ic.CopyIcon, disabled: !src, onClick: () => run(() => copyImage(src!), "Image copied") },
      ...(path ? [{ kind: "item" as const, label: "Copy path", icon: Ic.FileIcon, onClick: () => run(() => copyText(path), "Path copied") }] : []),
    ];
  };
  const onContextMenu = (e: MouseEvent) => { e.preventDefault(); e.stopPropagation(); setPoint({ x: e.clientX, y: e.clientY }); };
  const view = () => <>
    <Show when={point()}>{at => <PopupMenu x={at().x} y={at().y} items={items()} onClose={() => setPoint(null)} />}</Show>
    <Show when={status()}><span class="image-action-status" role="status">{status()}</span></Show>
  </>;
  return { onContextMenu, save, view };
}
