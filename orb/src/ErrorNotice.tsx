import { swallow } from "./log";
import { For, Show, createMemo, createSignal, createEffect, type JSX } from "solid-js";
import { copyText } from "./clipboard";
import { CloseIcon, CopyIcon, CheckIcon } from "./icons";
import { Dialog, DialogButton } from "./Dialog";
import { harnessName } from "./harnesses";
import { isTransientNodeNotice } from "./stream";
import { providerLimit, resetPhrase } from "./usageLimit";

export { isTransientNodeNotice };
export type ErrorInfo = { title: string; message: string; tone?: "warning"; link?: { label: string; url: string }; nonResumable?: boolean };
export type ProcessLaunchFailureKind = "arg_list_too_long" | "missing_binary" | "spawn_failed";

/** Render inline backtick spans (e.g. ``Node `ashur` ``) as `<code>` elements without HTML injection. */
export function renderInlineCode(text: string): JSX.Element {
  if (!text.includes("`")) return text;
  const parts = text.split(/(`[^`\n]+`)/g);
  return parts.length <= 1 ? text : <For each={parts}>{(p) => (p.length >= 2 && p[0] === "`" && p[p.length - 1] === "`" ? <code>{p.slice(1, -1)}</code> : p)}</For>;
}

const CLI_PAT = "opencode|claude(?:code)?|codex|agy|antigravity|grok|vibe";
const CLI_FIND_RE = new RegExp(`\\.sandboxed-sh-(${CLI_PAT})-cmd\\.sh|\\bRemote\\s+(${CLI_PAT})\\s+job\\b|Failed to (?:start|spawn|launch|write)\\s+(OpenCode|Claude Code|${CLI_PAT})\\b|command not found:\\s*(${CLI_PAT})\\b|(?:^|:\\s*)(${CLI_PAT}):\\s*(?:Argument list too long|(?:command )?not found|No such file or directory|Permission denied|Exec format error)`, "im");
const cliFailRe = (why: string, errno: string) => new RegExp(`(?:(?:\\.sandboxed-sh-[\\w-]+-cmd\\.sh|\\b(?:${CLI_PAT})\\b)[^\\n]*:\\s*(?:${why})|(?:failed to (?:start|spawn|launch|exec)|posix_spawn)[^\\n]*(?:${why}|\\bos error (?:${errno})\\b))`, "i");
const MISSING_BIN_RE = new RegExp(`${cliFailRe("(?:command )?not found|No such file or directory", "2").source}|command not found:\\s*(?:${CLI_PAT})\\b`, "i");
const SPAWN_FAIL_RE = new RegExp(`${cliFailRe("Permission denied|Exec format error", "8|13").source}|Failed to (?:start|write) [^\\n]*(?:CLI|command script)`, "i");
const SILENT_STOP_RE = new RegExp(`^Remote\\s+(${CLI_PAT}|node\\s+'[^']+')\\s+job\\s+[0-9a-f-]{36}(?:\\s+on\\s+node\\s+'([^']+)')?\\s+finished without assistant text(?:\\s+\\(stop reason:\\s*([^)]+)\\))?\\.?$`, "i");
const PRESERVED = "Your workspace and conversation history are preserved.";
const CONT_DIRECT = "then continue in this conversation directly without transferring again — or switch to another agent.";
const CONV_SAVED = "Your conversation is saved";
const CONT_STEP = "continue from the last completed step.";

function inferLaunchHarness(raw: string, backend?: string | null): string {
  if (backend?.trim()) return harnessName(backend.trim()).replace(/\s+CLI$/, "");
  const m = raw.match(CLI_FIND_RE);
  const matched = m?.[1] || m?.[2] || m?.[3] || m?.[4] || m?.[5];
  if (!matched) return "Agent";
  const key = matched.toLowerCase().replace(/\s+/g, "");
  return harnessName(key === "claude" ? "claudecode" : key === "agy" ? "antigravity" : key).replace(/\s+CLI$/, "");
}

export function classifyProcessLaunchFailure(raw: string, backend?: string | null): (ErrorInfo & { kind: ProcessLaunchFailureKind; nonResumable: true }) | null {
  const fb = (kind: ProcessLaunchFailureKind, message: (a: string) => string) => {
    const a = inferLaunchHarness(raw, backend);
    return { kind, nonResumable: true as const, title: `${a} could not start`, message: message(a) };
  };
  if (/argument list too long|\bE2BIG\b|\bos error 7\b/i.test(raw))
    return fb("arg_list_too_long", a => `The carried conversation history exceeded the system command-line limit before ${a} could launch. ${PRESERVED} Update the backend so ${a} receives large histories over stdin, ${CONT_DIRECT.slice(0, -1)}, or continue in the original conversation.`);
  if (MISSING_BIN_RE.test(raw))
    return fb("missing_binary", a => `The ${a} CLI was not found on the execution machine. ${PRESERVED} Install or update ${a} on that machine, ${CONT_DIRECT}`);
  if (SPAWN_FAIL_RE.test(raw))
    return fb("spawn_failed", a => `The execution machine could not launch the ${a} CLI process. ${PRESERVED} Check the ${a} CLI installation or update the backend on that machine, ${CONT_DIRECT}`);
  return null;
}

export function isNonResumableError(raw: string, backend?: string | null): boolean {
  if (!raw) return false;
  return describeError(raw, "Mission failed", backend).nonResumable === true;
}

export function describeError(raw: string, fallback = "Something went wrong", backend?: string | null): ErrorInfo {
  const launch = classifyProcessLaunchFailure(raw, backend);
  if (launch) return launch;
  const err = (title: string, message: string, tone?: "warning"): ErrorInfo => ({ title, message, ...(tone ? { tone } : {}) });
  if (/daybreak[^\n]*(?:isn|not)[^\n]*available/i.test(raw)) return err("Daybreak is unavailable for this account or model", "OpenAI refused Daybreak for the selected model on this connection. Check the account’s approved access or explicitly choose Standard. The model and program were not changed automatically.");
  if (/access_program_not_enabled/.test(raw)) return err("Cyber access is not enabled", "The account is not approved for this program and model. Check its Daybreak access or explicitly choose Standard. The selected model has not been changed.");
  if (/unsupported_access_program/.test(raw)) return err("Cyber selection is unsupported on this connection", `This connection cannot apply the requested program reliably. Use a supported connection, or explicitly choose Automatic. ${CONV_SAVED}.`);
  if (/invalid_access_program/.test(raw)) return err("Cyber program and model are incompatible", "Choose a compatible cyber program or change the model. No alternative model was selected automatically.");
  if (/cyberPolicy|cyber_policy/.test(raw)) return err("Request rejected by OpenAI’s cyber policy", `This request was restricted by the provider. Daybreak access does not allow every request. ${CONV_SAVED}; the program has not been changed automatically.`);
  const limit = providerLimit(raw);
  if (limit?.kind === "quota") return {
    tone: "warning",
    title: `${limit.provider ? `${limit.provider} usage` : "Usage"} limit reached`,
    message: `${limit.resets ? `It resets ${resetPhrase(limit.resets)}. ` : ""}${CONV_SAVED}: resume it then, or switch to another account or model to continue now.`,
    link: limit.url ? { label: "View usage", url: limit.url } : undefined,
  };
  if (limit?.kind === "rate") return err(`${limit.provider ?? "The provider"} is rate-limiting requests`, `Wait a moment, then retry. ${CONV_SAVED}.`, "warning");
  if (/\[claude-code:unrecognized_model\]/.test(raw)) return err("Claude Code does not recognize this model", "Update Claude Code on the machine running this conversation (claude update), then retry. If it persists, choose a model available to that Claude account.");
  const disk = raw.match(/\((\d+(?:\.\d+)?) GiB required\), but only (\d+(?:\.\d+)?) GiB is free/i);
  if (disk) return err("Not enough disk space", `${disk[2]} GiB available · ${disk[1]} GiB required, including the safety reserve. Choose another machine or free up space.`);
  if (/parallel_missions_cap/i.test(raw)) return err("Project agent limit reached", "Finish an agent in this project or increase the limit in Project settings.");
  if (/maximum.*parallel|parallel mission limit/i.test(raw)) return err("Mission limit reached", "Wait for a mission to finish or adjust the parallel mission limit in settings.");
  const writer = raw.match(/writer_conflict: Project (\S+) already has a writer for (.+?) \(mission ([\da-f-]+)\)/);
  if (writer) return err("That project already has a writer", `Project ${writer[1]} already has a writer for ${writer[2]} (mission ${writer[3].slice(0, 8)}). The conversation has not moved.`);
  if (/local_run_in_progress/.test(raw)) return err("A local run is in progress", "This computer is still running a turn in the current folder. Wait for it to finish, then move the conversation.");
  const busy = raw.match(/assignment_busy: mission (has an active run|has a remote job|has a deferred goal|has queued or running work|is Pending|is Active)/);
  if (busy) return err("Can’t change the track or PR while it runs", `This mission ${busy[1]}. Stop it or wait for it to finish, then change its track or PR.`);
  if (/REMOTE_JOB_STILL_RUNNING/.test(raw)) return err("A turn is still running", "Wait for it to finish before sending this follow-up. Your draft is kept.");
  if (/REMOTE_RESUME_REQUIRES_REPLACEMENT/.test(raw)) return err("Couldn’t resume this session", "Your draft is kept. Try again; if the problem persists, fork the conversation into a new mission.");
  const defaultFallback = fallback === "Something went wrong" || fallback === "Mission failed";
  if (/Node [`'][^`']+[`'] answers ping but its API is unresponsive/i.test(raw)) return err(defaultFallback ? "Execution node unresponsive" : fallback, raw.trim(), "warning");
  if (/Lost contact with remote node [`'][^`']+[`']/i.test(raw)) return err(defaultFallback ? "Connection to execution node interrupted" : fallback, raw.trim(), "warning");
  if (/There was a network issue connecting to the server/i.test(raw)) return err("Network issue connecting to the model server", `The connection dropped while the agent was working. Check your internet connection, then resume to ${CONT_STEP}`);
  if (/Our servers are experiencing high traffic right now|UNAVAILABLE \(code 503\): The service is currently unavailable/i.test(raw)) return err("The model server is experiencing high traffic", `Wait a moment, then resume to ${CONT_STEP}`, "warning");
  if (/No space left on device|ENOSPC/i.test(raw)) return err("Disk full on the execution machine", "The machine ran out of disk space while the agent was working. Free up space or move the conversation to another machine, then resume.");
  if (/Antigravity ended its headless turn while background task\(s\).*were still running/i.test(raw)) return err("Antigravity turn ended while background tasks were still running", `${CONV_SAVED}. Resume to inspect task logs or ${CONT_STEP}`);
  if (/Antigravity ended without a SUCCESS result/i.test(raw)) return err("Antigravity stopped before completing its turn", `The CLI exited early without a final result. ${CONV_SAVED}; resume to ${CONT_STEP}`);
  const agyLimit = raw.match(/Antigravity prompts must be at most (\d+ KiB)/i);
  if (agyLimit) return { nonResumable: true, title: `Antigravity prompt exceeds ${agyLimit[1]}`, message: `Shorten the message or put large context in workspace files so the prompt stays within ${agyLimit[1]}. Your draft is kept.` };
  if (/Failed to fetch|NetworkError|Load failed|fetch failed/i.test(raw)) return err("Can’t reach the backend", "Check your connection and backend settings, then try again.");
  if (/The server is taking too long to answer|\bTimeoutError\b|ProviderHeaderTimeoutError|Provider response headers timed out/i.test(raw)) return err("The server is taking too long to answer", "Please retry; nothing was lost.");
  if (/Workspace exceeds transfer limit/.test(raw)) {
    const found = raw.match(/: (.+?) in (\d+) files\. Largest: (.+)$/);
    const folders = found && [...found[3].matchAll(/(.+?) \(([\d.]+ [MG]iB), (\d+) files\)(?:, |$)/g)].map(f => `${f[1]}  ·  ${f[2]}, ${Number(f[3]).toLocaleString("en-US")} files`);
    return { title: "Workspace too large to move", message: `${found ? `It holds ${found[1]} in ${Number(found[2]).toLocaleString("en-US")} files. ` : ""}A move carries at most 10 GiB and 50,000 files.${folders?.length ? `\n\nLargest folders\n${folders.join("\n")}` : ""}` };
  }
  const outdated = raw.match(/Update (.+) to receive a workspace (containing links|with selected build folders)/);
  if (outdated) return err(`${outdated[1]} needs an update`, `This workspace ${outdated[2] === "containing links" ? "contains links" : "includes build folders you selected"}, which that machine cannot receive yet. Update it, or choose another machine. The conversation has not moved.`);
  const silentStop = SILENT_STOP_RE.exec(raw);
  if (silentStop) return err(`${inferLaunchHarness(raw, backend)} stopped without a written reply`, `The run${silentStop[2] ? ` on ${silentStop[2]}` : ""} completed its tool or reasoning step without emitting a final message. ${PRESERVED} Resume or send a follow-up to ask for the summary.`, "warning");
  let cleaned = raw.trim();
  if (cleaned === "Model error") return err(fallback, `The run ended with an error before returning a response. ${PRESERVED}`);
  const normalize = (s: string) => s.replace(/[\u2018\u2019]/g, "'").toLowerCase();
  if (fallback && normalize(cleaned).startsWith(`${normalize(fallback)}:`)) cleaned = cleaned.slice(fallback.length + 1).trim();
  cleaned = cleaned.replace(/^(?:(?:Error|TypeError|DOMException|ApiError|RequestTimeoutError|TimeoutError):\s*)+/i, "").trim() || cleaned;
  const technical = cleaned.length > 260 || /(?:^\s*[{[]|\\n|Traceback|Internal error|statvfs:)/.test(cleaned);
  return err(fallback, technical ? "The request could not be completed. See details for the backend response." : cleaned);
}

/** Inline, non-modal feedback. Never truncates or discards the original error. */
export function ErrorNotice(p: { error: string; title?: string; backend?: string | null; onDismiss?: () => void; children?: JSX.Element }) {
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
  const info = createMemo(() => describeError(p.error, p.title, p.backend));
  return <section class="error-notice" classList={{ warning: info().tone === "warning" }} role="alert">
    <svg class="error-notice-icon" width="15" height="15" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" aria-hidden="true"><circle cx="8" cy="8" r="6.25" /><path d="M8 4.75v3.5" /><circle cx="8" cy="11.1" r="0.8" fill="currentColor" stroke="none" /></svg>
    <div class="error-notice-body"><strong>{info().title}</strong><p>{renderInlineCode(info().message)}</p>
      <Show when={info().link}>{link => <div class="toast-links">
        <button type="button" class="toast-link" onClick={() => void import("./api").then(m => m.openExternalUrl(link().url)).catch(swallow("errorNotice.openLink"))}>{link().label}</button>
      </div>}</Show>
      <Show when={p.children}><div class="error-notice-actions">
        {p.children}
      </div></Show>
      <Show when={info().message !== p.error.trim()}><details><summary>Technical details</summary><pre>{p.error}</pre></details></Show>
      <Show when={copyError()}><p class="error-copy-status" role="status">{copyError()}</p></Show>
    </div>
    <div class="toast-corner">
      <Show when={p.onDismiss}><button type="button" class="icon-btn toast-icon-btn" aria-label="Dismiss error" onClick={() => p.onDismiss?.()}><CloseIcon size={14} /></button></Show>
      <button type="button" class="icon-btn toast-icon-btn error-copy" aria-label={copied() ? "Error copied" : "Copy error"} title={copied() ? "Copied" : "Copy error"} onClick={() => void copy()}><Show when={copied()} fallback={<CopyIcon size={14} />}><CheckIcon size={14} /></Show></button>
    </div>
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
    <div class="error-dialog" role="alert"><p>{renderInlineCode(info().message)}</p>
      <Show when={info().message !== raw()}><details><summary>Technical details</summary><pre>{p.error}</pre></details></Show>
    </div>
  </Dialog>;
}
