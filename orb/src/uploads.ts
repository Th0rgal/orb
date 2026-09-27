import { api, connectionVersion, getApiUrl } from "./api";
import { mentionText, scanMentions } from "./attach";

export interface UploadSource { name: string; localPath?: string; file?: File }
export interface UploadedFile { source: UploadSource; path: string; destination: string; connection: number; endpoint?: string; dataBase64?: string }
export interface UploadReceipt { name: string; path: string; size: number; sha256: string }
const MAX = 20 * 1024 * 1024;
type Invoke = <T>(command: string, args?: Record<string, unknown>) => Promise<T>;
function nativeInvoke(): Invoke | undefined {
  return (window as unknown as { __TAURI__?: { core?: { invoke?: Invoke } } }).__TAURI__?.core?.invoke;
}
export function hasNativePicker() { return !!nativeInvoke(); }
export async function pickNativeFiles(): Promise<UploadSource[]> {
  const invoke = nativeInvoke();
  if (!invoke) throw new Error("Use the desktop app to attach a local file path.");
  const files = await invoke<Array<{ name: string; path: string }>>("pick_upload_files");
  return files.map(file => ({ name: file.name, localPath: file.path }));
}
export async function encoded(source: UploadSource, maxBytes=MAX): Promise<string> {
  if (source.localPath) {
    const invoke = nativeInvoke();
    if (!invoke) throw new Error("Reopen this file in the desktop app.");
    return invoke<string>("read_upload_file", { path: source.localPath, ...(maxBytes===MAX?{}:{maxBytes}) });
  }
  const file = source.file;
  if (!file) throw new Error("Choose the file again.");
  if (file.size > maxBytes) throw new Error(`Files must be ${maxBytes/1024/1024} MiB or smaller.`);
  const bytes = new Uint8Array(await file.arrayBuffer());
  let binary = "";
  for (let i = 0; i < bytes.length; i += 8192) binary += String.fromCharCode(...bytes.subarray(i, i + 8192));
  return btoa(binary);
}
export const uploadToken = (path: string) => mentionText({ kind: "file", path });
export async function transferFile(source: UploadSource, destination: string): Promise<UploadedFile> {
  const connection = connectionVersion();
  if (destination === "side") {
    return { source, path: `side-attachment/${crypto.randomUUID()}/${source.name}`, destination, connection, endpoint:getApiUrl(), dataBase64:await encoded(source) };
  }
  if (destination === "local") {
    if (!source.localPath) {
      const invoke=nativeInvoke();
      if(!invoke)throw new Error("Local file attachments require the desktop app.");
      const path=await invoke<string>("stage_upload_file",{name:source.name,dataBase64:await encoded(source)});
      source={...source,localPath:path};
    }
    return { source, path: source.localPath!, destination, connection, endpoint: getApiUrl() };
  }
  const data = await encoded(source);
  if (destination.startsWith("context:")) {
    const project = destination.slice("context:".length);
    if (!project) throw new Error("Select a project before uploading files to shared context.");
    const route = `/api/projects/${encodeURIComponent(project)}/context`;
    const bytes = Uint8Array.from(atob(data), c => c.charCodeAt(0));
    if (connection !== connectionVersion()) throw new Error("The backend changed. Choose the file again.");
    const blob = await api<{hash:string}>(`${route}/blobs`, {method:"POST", headers:{"Content-Type":"application/octet-stream"}, body:bytes});
    if (connection !== connectionVersion()) throw new Error("The backend changed during the upload. Choose the file again.");
    // Unique directories preserve names without overwriting another attachment.
    const name = source.name.replace(/[\\/\x00-\x1f]/g, "_");
    if (!name || name === "." || name === "..") throw new Error("Invalid attachment name.");
    const path = `attachments/${crypto.randomUUID()}/${name}`;
    const receipt = await api<{conflict:boolean}>(`${route}/operations`, {
      method:"POST", headers:{"Content-Type":"application/json"},
      body:JSON.stringify({id:crypto.randomUUID(),path,base:null,hash:blob.hash,directory:false,delete:false,source:"Orb"}),
    });
    if (connection !== connectionVersion()) throw new Error("The backend changed during the upload. Choose the file again.");
    if (receipt.conflict) throw new Error("Shared context changed. Drop the file again.");
    return {source,path:`context/${path}`,destination,connection,endpoint:getApiUrl()};
  }
  if (connection !== connectionVersion()) throw new Error("The backend changed. Choose the file again.");
  const receipt = await api<UploadReceipt>("/api/uploads", {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ node_id: destination, name: source.name, data_base64: data }),
  });
  if (connection !== connectionVersion()) throw new Error("The backend changed during the upload. Choose the file again.");
  return { source, path: receipt.path, destination, connection, endpoint: getApiUrl() };
}
/** Resolve only references still in the draft, and never reuse another machine's path. */
export async function prepareUploads(text: string, files: UploadedFile[], destination: string,
  transfer = transferFile, connection = connectionVersion()): Promise<{ text: string; files: UploadedFile[] }> {
  const next: UploadedFile[] = [];
  for (const file of files) {
    if (!scanMentions(text).some(mention => mention.value === file.path)) continue;
    const resolved = file.destination === destination && file.connection === connection
      ? file : await transfer(file.source, destination);
    if (resolved !== file) {
      for (const mention of scanMentions(text).filter(mention => mention.value === file.path).reverse()) {
        text = text.slice(0, mention.index) + uploadToken(resolved.path) + text.slice(mention.index + mention.raw.length);
      }
    }
    next.push(resolved);
  }
  return { text, files: next };
}
