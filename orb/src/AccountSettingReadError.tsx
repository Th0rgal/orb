import { Show } from "solid-js";
import { ApiError } from "./api";
import { missingAccountSetting } from "./accountVpn";

function missingEndpoint(error: unknown, path: string) {
  return error instanceof ApiError && missingAccountSetting(error.status, error.detail, path);
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
