import { invokeNative } from "./native";
import { swallow } from "./log";
import { ErrorToast } from "./toast";
import { rememberApprovedPlan } from "./PlanProgress";
import { For, Show, createSignal, type Accessor, type Setter } from "solid-js";
import { MdView } from "./Markdown";
import { api } from "./api";
import type { StreamItem } from "./transcriptModel";
import type { CompletedPlanTurn, NativeInteractionRequest } from "./NativeInteraction";

const invoke = (command: string, args: Record<string, unknown>) =>
  invokeNative(command, args, "Open this session in Orb.");

export default function NativeInteractionPrompt(p: {
  mission: string;
  remote?: boolean;
  items?: StreamItem[];
  onSend?: (text: string) => Promise<unknown> | unknown;
  request: Accessor<NativeInteractionRequest | null>;
  setRequest: Setter<NativeInteractionRequest | null>;
  completedPlanTurn: Accessor<CompletedPlanTurn | null>;
  answers: Accessor<Record<string, string[]>>;
  setAnswers: Setter<Record<string, string[]>>;
  feedback: Accessor<string>;
  setFeedback: Setter<string>;
  error: Accessor<string>;
  setError: Setter<string>;
  connectionVersion: () => number;
  answeredKey: (mission: string) => string;
  rememberAnswered: (id: string, mission: string, version: number, targetKey: string) => void;
}) {
  const [sending, setSending] = createSignal(false);

  const replyCompletedPlan = async (action: "accept" | "revise") => {
    const completed = p.completedPlanTurn();
    if (!completed || sending() || !p.onSend) return;
    const selectedMission = p.mission;
    const selectedConnection = p.connectionVersion();
    const selectedKey = p.answeredKey(selectedMission);
    setSending(true);
    p.setError("");
    try {
      const text = action === "accept" ? "Implement the approved plan." : `/plan ${p.feedback().trim()}`;
      if (action === "accept") {
        await rememberApprovedPlan(selectedMission, {
          requestId: completed.id,
          text: completed.plan,
          approvedAt: new Date().toISOString(),
          boundary: completed.boundary,
        }).catch(swallow("nativeInteraction.rememberPlan", { mission: selectedMission }));
      }
      await p.onSend(text);
      p.rememberAnswered(completed.id, selectedMission, selectedConnection, selectedKey);
      if (selectedMission === p.mission && selectedConnection === p.connectionVersion()) p.setFeedback("");
    } catch (e) {
      p.setError(String(e));
    } finally {
      setSending(false);
    }
  };

  const reply = async (action?: string) => {
    const current = p.request();
    if (!current || sending()) return;
    const selectedMission = p.mission;
    const selectedConnection = p.connectionVersion();
    const selectedKey = p.answeredKey(selectedMission);
    const boundary = p.items?.at(-1)?.key;
    setSending(true);
    p.setError("");
    const mapped = Object.fromEntries(
      (current.params.questions ?? []).map((q, i) => {
        const key = q.id ?? String(i);
        const values = p.answers()[key] ?? [];
        return current.method === "claude_questions" ? [q.question, values.join(", ")] : [key, { answers: values }];
      }),
    );
    try {
      const answer = action ? { action, feedback: p.feedback() } : { answers: mapped };
      if (p.remote) {
        const item = p.items?.find(i => i.kind === "tool" && i.callId === current.id);
        const result = await api<{ delivered: boolean }>("/api/control/tool_result", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            tool_call_id: current.id,
            name: item?.kind === "tool" ? item.name : "ui_native_request",
            result: answer,
          }),
        });
        if (!result.delivered) throw new Error("This request has expired. Resume the session to continue.");
      } else {
        await invoke("local_interaction_answer", { id: p.mission, requestId: current.id, answer });
      }
      if (current.method === "plan" && action === "accept") {
        await rememberApprovedPlan(selectedMission, {
          requestId: current.id,
          text: current.params.plan ?? "Plan text unavailable",
          approvedAt: new Date().toISOString(),
          boundary,
        }).catch(() => p.setError("Plan accepted, but its local tracking could not be saved."));
      }
      p.rememberAnswered(current.id, selectedMission, selectedConnection, selectedKey);
      if (selectedMission === p.mission && selectedConnection === p.connectionVersion()) {
        p.setRequest(next => (next?.id === current.id ? null : next));
      }
    } catch (e) {
      p.setError(String(e));
    } finally {
      setSending(false);
    }
  };

  return (
    <>
      <Show when={p.request()}>
        {r => (
          <section class="native-question" aria-label="Waiting for your response">
            <div class="native-question-heading">
              {r().method === "plan" ? "Review the plan" : r().method === "permission" ? "Permission requested" : "Questions"}
            </div>
            <Show
              when={r().method === "plan" || r().method === "permission"}
              fallback={
                <For each={r().params.questions}>
                  {(q, i) => {
                    const key = () => q.id ?? String(i());
                    return (
                      <fieldset disabled={sending()}>
                        <legend>{q.question}</legend>
                        <For each={q.options}>
                          {(option, index) => (
                            <label class="native-choice">
                              <input
                                type={q.multiSelect ? "checkbox" : "radio"}
                                name={`question-${key()}`}
                                checked={p.answers()[key()]?.includes(option.label) ?? false}
                                onChange={e =>
                                  p.setAnswers(prev => ({
                                    ...prev,
                                    [key()]: q.multiSelect
                                      ? e.currentTarget.checked
                                        ? [...(prev[key()] ?? []), option.label]
                                        : (prev[key()] ?? []).filter(v => v !== option.label)
                                      : [option.label],
                                  }))
                                }
                              />
                              <span class="native-choice-key" aria-hidden="true">
                                {String.fromCharCode(65 + index())}
                              </span>
                              <span class="native-choice-copy">
                                <span class="native-choice-title">{option.label}</span>
                                <Show when={option.description}>
                                  <small>{option.description}</small>
                                </Show>
                              </span>
                              <span class="native-choice-check" aria-hidden="true">
                                ✓
                              </span>
                            </label>
                          )}
                        </For>
                        <input
                          class="s-input"
                          aria-label={`Other answer: ${q.question}`}
                          placeholder="Other…"
                          value={p.answers()[key()]?.filter(v => !q.options?.some(o => o.label === v)).join(", ") ?? ""}
                          onInput={e => p.setAnswers(prev => ({ ...prev, [key()]: [e.currentTarget.value] }))}
                        />
                      </fieldset>
                    );
                  }}
                </For>
              }
            >
              <Show when={r().params.plan}>
                <div class="native-plan">
                  <MdView compact text={r().params.plan!} />
                </div>
              </Show>
              <Show when={r().method === "permission"}>
                <div class="native-permission-title">
                  <span class="p-chip">{r().params.tool ?? "Tool action"}</span>
                  <span>{r().params.input?.description ?? "Allow this action?"}</span>
                </div>
                <Show when={r().params.input?.command || r().params.input?.file_path}>
                  <pre>{r().params.input?.command ?? r().params.input?.file_path}</pre>
                </Show>
              </Show>
              <details class="native-feedback" open={r().method === "plan"}>
                <summary>{r().method === "plan" ? "Request changes" : "Add feedback"}</summary>
                <textarea
                  aria-label="Requested changes"
                  placeholder={r().method === "plan" ? "Changes to the plan…" : "Optional feedback…"}
                  value={p.feedback()}
                  onInput={e => p.setFeedback(e.currentTarget.value)}
                />
              </details>
            </Show>
            <div class="native-question-actions">
              <Show
                when={r().method === "plan" || r().method === "permission"}
                fallback={
                  <button
                    class="s-btn native-primary"
                    disabled={sending() || (r().params.questions ?? []).some((q, i) => !(p.answers()[q.id ?? String(i)] ?? []).some(v => v.trim()))}
                    onClick={() => void reply()}
                  >
                    Continue
                  </button>
                }
              >
                <button
                  class="s-btn native-secondary"
                  disabled={sending() || (r().method === "plan" && !p.feedback().trim())}
                  onClick={() => void reply("revise")}
                >
                  {r().method === "plan" ? "Request changes" : "Decline"}
                </button>
                <Show when={r().method === "permission"}>
                  <button
                    class="s-btn native-secondary"
                    disabled={sending()}
                    onClick={() => void reply("accept_session")}
                  >
                    Allow for session
                  </button>
                </Show>
                <button class="s-btn native-primary" disabled={sending()} onClick={() => void reply("accept")}>
                  {r().method === "plan" ? "Implement plan" : "Allow once"}
                </button>
              </Show>
              <Show when={sending()}>
                <span role="status">Sending…</span>
              </Show>
            </div>
            <ErrorToast error={p.error()} title="Couldn’t send your answer" onDismiss={() => p.setError("")} />
          </section>
        )}
      </Show>
      <Show when={p.completedPlanTurn()}>
        <section class="native-question" aria-label="Review the plan">
          <div class="native-question-heading">Review the plan</div>
          <details class="native-feedback">
            <summary>Request changes</summary>
            <textarea
              aria-label="Requested changes"
              placeholder="Changes to the plan…"
              value={p.feedback()}
              onInput={e => p.setFeedback(e.currentTarget.value)}
            />
          </details>
          <div class="native-question-actions">
            <button
              class="s-btn native-secondary"
              disabled={sending() || !p.feedback().trim()}
              onClick={() => void replyCompletedPlan("revise")}
            >
              Request changes
            </button>
            <button class="s-btn native-primary" disabled={sending()} onClick={() => void replyCompletedPlan("accept")}>
              Implement plan
            </button>
            <Show when={sending()}>
              <span role="status">Sending…</span>
            </Show>
          </div>
          <ErrorToast error={p.error()} title="Couldn’t send your answer" onDismiss={() => p.setError("")} />
        </section>
      </Show>
    </>
  );
}
