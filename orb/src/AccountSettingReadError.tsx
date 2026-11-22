import { Show } from "solid-js";
import { ApiError } from "./api";

function missingEndpoint(error: unknown, path: string) {
  if (!(error instanceof ApiError) || error.status !== 404) return false;
  try {
    const body = JSON.parse(error.detail);
    return body?.error === "not_found" && body.path === path;
  } catch {
    return false;
  }
}

export function AccountSettingReadError(p: {
  error: unknown;
  path: string;
  updateMessage: string;
  retryLabel: string;
  retry: () => void;
}) {
  return <>
    <Show when={missingEndpoint(p.error, p.path)}>
      <span class="s-row-desc" role="status">{p.updateMessage}</span>
    </Show>
    <button class="s-btn" onClick={p.retry}>{p.retryLabel}</button>
  </>;
}
