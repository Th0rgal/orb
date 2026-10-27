import { TrashIcon } from "./icons";
import type { SecretAccessRequest } from "./bitwardenApi";

/** Icons shared by the approval card and the Secrets / Privileged / Mission access pages. */
export function EyeIcon() {
  return <svg width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5"><path d="M1.5 8S4 3.5 8 3.5 14.5 8 14.5 8 12 12.5 8 12.5 1.5 8 1.5 8z" /><circle cx="8" cy="8" r="2" /></svg>;
}

/** Read, write, delete or move, as an icon with its label. */
export function SecretKindIcon(p: { request: SecretAccessRequest }) {
  const title = () => ({ write: "Write", delete: "Delete", move: "Move" } as Record<string, string>)[p.request.kind] ?? "Read";
  return <span class="secret-kind" title={title()} aria-label={title()}>
    {p.request.kind === "delete" ? <TrashIcon /> : p.request.kind === "read" ? <EyeIcon /> : <PencilIcon />}
  </span>;
}

export function PencilIcon() {
  return <svg width="13" height="13" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M11 2.5l2.5 2.5L6 12.5 3 13l.5-3z" /></svg>;
}

export function FingerprintIcon(p: { size?: number }) {
  const size = p.size ?? 16;
  return <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round">
    <path d="M6.8 5.2A8 8 0 0 1 20 11.5c0 1.5-.1 3-.4 4.4" />
    <path d="M4 15.5a8 8 0 0 1-.1-4.1 8 8 0 0 1 1-2.6" />
    <path d="M8.2 18.6A12 12 0 0 0 9.5 12a2.5 2.5 0 0 1 5 0c0 2.6-.4 5-1.2 7.3" />
    <path d="M6.4 12a5.6 5.6 0 0 1 11.2 0c0 1.9-.2 3.7-.6 5.4" />
    <path d="M12 12c0 3.4-.7 6.4-2 9" />
  </svg>;
}
