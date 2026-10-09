import { Show, createMemo, createSignal, createEffect, type JSX } from "solid-js";
import { copyText } from "./clipboard";
import { CloseIcon, CopyIcon, CheckIcon } from "./icons";
import { Dialog, DialogButton } from "./Dialog";
import { providerLimit, resetPhrase } from "./usageLimit";

export type ErrorInfo = { title: string; message: string; tone?: "warning"; link?: { label: string; url: string } };
export function describeError(raw: string, fallback = "Something went wrong"): ErrorInfo {
  if (/daybreak[^\n]*(?:isn|not)[^\n]*available/i.test(raw)) return {title:"Daybreak is unavailable for this account or model",message:"OpenAI refused Daybreak for the selected model on this connection. Check the account’s approved access or explicitly choose Standard. The model and program were not changed automatically."};
  if (/access_program_not_enabled/.test(raw)) return {title:"Cyber access is not enabled",message:"The account is not approved for this program and model. Check its Daybreak access or explicitly choose Standard. The selected model has not been changed."};
  if (/unsupported_access_program/.test(raw)) return {title:"Cyber selection is unsupported on this connection",message:"This connection cannot apply the requested program reliably. Use a supported connection, or explicitly choose Automatic. Your conversation is saved."};
  if (/invalid_access_program/.test(raw)) return {title:"Cyber program and model are incompatible",message:"Choose a compatible cyber program or change the model. No alternative model was selected automatically."};
  if (/cyberPolicy|cyber_policy/.test(raw)) return {title:"Request rejected by OpenAI’s cyber policy",message:"This request was restricted by the provider. Daybreak access does not allow every request. Your conversation is saved; the program has not been changed automatically."};
  const limit = providerLimit(raw);
  if (limit?.kind === "quota") return {
    tone: "warning",
    title: `${limit.provider ? `${limit.provider} usage` : "Usage"} limit reached`,
    message: `${limit.resets ? `It resets ${resetPhrase(limit.resets)}. ` : ""}Your conversation is saved: resume it then, or switch to another account or model to continue now.`,
    link: limit.url ? { label: "View usage", url: limit.url } : undefined,
  };
  if (limit?.kind === "rate") return { tone: "warning", title: `${limit.provider ?? "The provider"} is rate-limiting requests`, message: "Wait a moment, then retry. Your conversation is saved." };
  if (/\[claude-code:unrecognized_model\]/.test(raw)) return { title: "Claude Code does not recognize this model", message: "Update Claude Code on the machine running this conversation (claude update), then retry. If it persists, choose a model available to that Claude account." };
  const disk = raw.match(/\((\d+(?:\.\d+)?) GiB required\), but only (\d+(?:\.\d+)?) GiB is free/i);
  if (disk) return { title: "Not enough disk space", message: `${disk[2]} GiB available · ${disk[1]} GiB required, including the safety reserve. Choose another machine or free up space.` };
  if (/parallel_missions_cap|maximum.*parallel|parallel mission limit/i.test(raw)) return { title: "Mission limit reached", message: "Wait for a mission to finish or adjust the parallel mission limit in settings." };
  if (/REMOTE_JOB_STILL_RUNNING/.test(raw)) return { title: "A turn is still running", message: "Wait for it to finish before sending this follow-up. Your draft is kept." };
  if (/REMOTE_RESUME_REQUIRES_REPLACEMENT/.test(raw)) return { title: "Couldn’t resume this session", message: "Your draft is kept. Try again; if the problem persists, fork the conversation into a new mission." };
  if (/There was a network issue connecting to the server/i.test(raw)) return { title: "Network issue connecting to the model server", message: "The connection dropped while the agent was working. Check your internet connection, then resume to continue from the last completed step." };
  if (/Our servers are experiencing high traffic right now|UNAVAILABLE \(code 503\): The service is currently unavailable/i.test(raw)) return { tone: "warning", title: "The model server is experiencing high traffic", message: "Wait a moment, then resume to continue from the last completed step." };
  if (/No space left on device|ENOSPC/i.test(raw)) return { title: "Disk full on the execution machine", message: "The machine ran out of disk space while the agent was working. Free up space or move the conversation to another machine, then resume." };
  if (/Antigravity ended its headless turn while background task\(s\).*were still running/i.test(raw)) return { title: "Antigravity turn ended while background tasks were still running", message: "Your conversation is saved. Resume to inspect task logs or continue from the last completed step." };
  if (/Antigravity ended without a SUCCESS result/i.test(raw)) return { title: "Antigravity stopped before completing its turn", message: "The CLI exited early without a final result. Your conversation is saved; resume to continue from the last completed step." };
  if (/Failed to fetch|NetworkError|Load failed|fetch failed/i.test(raw)) return { title: "Can’t reach the backend", message: "Check your connection and backend settings, then try again." };
  if (/Workspace exceeds transfer limit/.test(raw)) {
    const found = raw.match(/: (.+?) in (\d+) files\. Largest: (.+)$/);
    const folders = found && [...found[3].matchAll(/(.+?) \(([\d.]+ [MG]iB), (\d+) files\)(?:, |$)/g)].map(f => `${f[1]}  ·  ${f[2]}, ${Number(f[3]).toLocaleString("en-US")} files`);
    return { title: "Workspace too large to move", message: `${found ? `It holds ${found[1]} in ${Number(found[2]).toLocaleString("en-US")} files. ` : ""}A move carries at most 10 GiB and 50,000 files.${folders?.length ? `\n\nLargest folders\n${folders.join("\n")}` : ""}` };
  }
  const outdated = raw.match(/Update (.+) to receive a workspace (containing links|with selected build folders)/);
  if (outdated) return { title: `${outdated[1]} needs an update`, message: `This workspace ${outdated[2] === "containing links" ? "contains links" : "includes build folders you selected"}, which that machine cannot receive yet. Update it, or choose another machine. The conversation has not moved.` };
  const technical = raw.length > 260 || /(?:^\s*[{[]|\\n|Traceback|Internal error|statvfs:)/.test(raw);
  return { title: fallback, message: technical ? "The request could not be completed. See details for the backend response." : raw };
}

/** Inline, non-modal feedback. Never truncates or discards the original error. */
export function ErrorNotice(p: { error: string; title?: string; onDismiss?: () => void; children?: JSX.Element }) {
  const [copied, setCopied] = createSignal(false);
  const [copyError, setCopyError] = createSignal("");
  createEffect(() => { p.error; setCopied(false); setCopyError(""); });
  const copy = async () => {
    const error = p.error;
    try {
      await copyText(error);
      if (p.error === error) { setCopied(true); setCopyError(""); }
    } catch (e) {
      if (p.error === error) { setCopied(false); setCopyError(e instanceof Error ? e.message : String(e)); }
    }
  };
  const info = createMemo(() => describeError(p.error, p.title));
  return <section class="error-notice" classList={{ warning: info().tone === "warning" }} role="alert">
    <svg class="error-notice-icon" width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" aria-hidden="true"><circle cx="8" cy="8" r="6" /><path d="M8 4.5v4M8 10.5v1" /></svg>
    <div class="error-notice-body"><strong>{info().title}</strong><p>{info().message}</p>
      <Show when={p.children || info().link}><div class="error-notice-actions">
        <Show when={info().link}>{link => <button type="button" class="error-notice-link" onClick={() => void import("./api").then(m => m.openExternalUrl(link().url)).catch(() => {})}>{link().label}</button>}</Show>
        {p.children}
      </div></Show>
      <Show when={info().message !== p.error}><details><summary>Technical details</summary><pre>{p.error}</pre></details></Show>
      <Show when={copyError()}><p class="error-copy-status" role="status">{copyError()}</p></Show>
    </div>
    <button type="button" class="icon-btn error-copy" aria-label={copied() ? "Error copied" : "Copy error"} title={copied() ? "Copied" : "Copy error"} onClick={() => void copy()}><Show when={copied()} fallback={<CopyIcon size={14} />}><CheckIcon size={14} /></Show></button>
    <Show when={p.onDismiss}><button type="button" class="icon-btn" aria-label="Dismiss error" onClick={() => p.onDismiss?.()}><CloseIcon size={14} /></button></Show>
  </section>;
}

/** A refused action interrupts once, in front of the work, instead of displacing the list it came from. */
export function ErrorDialog(p: { error: string; title?: string; onClose: () => void }) {
  const [copied, setCopied] = createSignal(false);
  const raw = () => p.error.replace(/^Error: /, "");
  const info = createMemo(() => describeError(raw(), p.title ?? "This action couldn’t be completed"));
  const copy = () => void copyText(p.error).then(() => setCopied(true)).catch(() => setCopied(false));
  return <Dialog size="compact" title={info().title} onClose={p.onClose} footer={<>
    <DialogButton onClick={copy}>{copied() ? "Copied" : "Copy error"}</DialogButton>
    <DialogButton variant="primary" onClick={p.onClose}>Close</DialogButton>
  </>}>
    <div class="error-dialog" role="alert"><p>{info().message}</p>
      <Show when={info().message !== raw()}><details><summary>Technical details</summary><pre>{p.error}</pre></details></Show>
    </div>
  </Dialog>;
}
