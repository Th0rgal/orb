// A bounded, connection-scoped bridge from upload to the canonical message.
// Upload previews and downloaded images share a bounded cache; file scopes
// include the mission revision so mutable workspace paths cannot live forever.
const previews = new Map<string, string>();
let size = 0;
const LIMIT = 48 * 1024 * 1024;
export function rememberImagePreview(scope: string, path: string, dataUrl: string) {
  const key = JSON.stringify([scope, path]);
  size -= previews.get(key)?.length ?? 0;
  previews.delete(key);
  if (dataUrl.length <= LIMIT) { previews.set(key, dataUrl); size += dataUrl.length; }
  while (size > LIMIT) {
    const oldest = previews.keys().next().value!;
    size -= previews.get(oldest)!.length;
    previews.delete(oldest);
  }
}
export function imagePreview(scope: string, path: string) {
  const key = JSON.stringify([scope, path]);
  const value = previews.get(key);
  if (value) { previews.delete(key); previews.set(key, value); }
  return value;
}
export const imagePreviewScope = (endpoint: string, connection: number, destination: string) => JSON.stringify([endpoint, connection, destination]);

const pending = new Map<string, Promise<string | null>>();
/** Cache data URLs, not consumer-owned blob URLs which unmount cleanup revokes. */
export function loadImagePreview(scope: string, path: string, load: () => Promise<Blob | null>): Promise<string | null> {
  const cached = imagePreview(scope, path);
  if (cached) return Promise.resolve(cached);
  const key = JSON.stringify([scope, path]);
  const flight = pending.get(key);
  if (flight) return flight;
  const task = (async () => {
    const blob = await load();
    if (!blob || blob.size > LIMIT / 2) return null;
    const data = await new Promise<string>((resolve, reject) => {
      const reader = new FileReader();
      reader.onload = () => resolve(reader.result as string);
      reader.onerror = () => reject(reader.error);
      reader.readAsDataURL(blob);
    });
    rememberImagePreview(scope, path, data);
    return data;
  })().finally(() => { pending.delete(key); });
  pending.set(key, task);
  return task;
}
