import {
  For,
  Show,
  createEffect,
  createMemo,
  createSignal,
  onCleanup,
  onMount,
} from "solid-js";
import {
  api,
  archiveMission,
  isConnected,
  reopenMission,
  sendMissionMessage,
  type Mission,
  type ProjectSummary,
} from "./api";
import { ErrorNotice } from "./ErrorNotice";
import { hasFocusScope } from "./focusScope";
import * as Ic from "./icons";
import {
  buildInboxSections,
  type InboxItem,
  type InboxOption,
} from "./inboxModel";
import { pendingMissionInteraction } from "./missionAttention";
import {
  peekReadyTranscript,
  prefetchTranscript,
  refreshTranscript,
  transcriptVersion,
} from "./missionCache";
import { rememberApprovedPlan } from "./PlanProgress";
import { projectColor } from "./projectAppearance";
import { InboxSkeleton } from "./Skeleton";

const invokeLocalInteraction = (command: string, args: Record<string, unknown>) => {
  const host = window as unknown as {
    __TAURI_INTERNALS__?: {
      invoke: (cmd: string, args: Record<string, unknown>) => Promise<unknown>;
    };
  };
  if (!host.__TAURI_INTERNALS__) {
    return Promise.reject(new Error("Open this session in Orb desktop to answer local tool requests."));
  }
  return host.__TAURI_INTERNALS__.invoke(command, args);
};

export function InboxPage(p: {
  missions: ReadonlyArray<Mission>;
  projects: ReadonlyArray<ProjectSummary>;
  loading?: boolean;
  onOpenMission: (id: string) => void;
  onOpenSettings: () => void;
  onNewAgent: () => void;
  onRefresh: () => Promise<void> | void;
  onMissionUpdated?: (mission: Mission) => void;
}) {
  const [projectFilter, setProjectFilter] = createSignal<string | null>(null);
  const [showWorking, setShowWorking] = createSignal(false);
  const [focusedId, setFocusedId] = createSignal<string | null>(null);
  const [replyingId, setReplyingId] = createSignal<string | null>(null);
  const [replyDraft, setReplyDraft] = createSignal("");
  const [busyIds, setBusyIds] = createSignal<ReadonlySet<string>>(new Set());
  const [dismissedIds, setDismissedIds] = createSignal<ReadonlySet<string>>(new Set());
  const [undoItem, setUndoItem] = createSignal<{ id: string; title: string } | null>(null);
  const [error, setError] = createSignal<string | null>(null);
  const [nowMs, setNowMs] = createSignal(Date.now());

  let undoTimer: ReturnType<typeof setTimeout> | undefined;
  let replyInputRef: HTMLInputElement | undefined;
  let listContainerRef: HTMLDivElement | undefined;

  onMount(() => {
    const clock = setInterval(() => setNowMs(Date.now()), 30_000);
    onCleanup(() => {
      clearInterval(clock);
      if (undoTimer) clearTimeout(undoTimer);
    });
  });

  const addBusy = (id: string) =>
    setBusyIds((prev) => {
      const next = new Set(prev);
      next.add(id);
      return next;
    });
  const removeBusy = (id: string) =>
    setBusyIds((prev) => {
      const next = new Set(prev);
      next.delete(id);
      return next;
    });

  const allSections = createMemo(() => {
    transcriptVersion();
    const dismissed = dismissedIds();
    const visibleMissions = p.missions.filter((m) => !dismissed.has(m.id));
    return buildInboxSections(
      visibleMissions,
      p.projects,
      (id) => peekReadyTranscript(id)?.items,
      (id) => pendingMissionInteraction(id),
      nowMs(),
    );
  });

  // Prefetch transcripts for top actionable items that lack history so their 1-line summary populates.
  createEffect(() => {
    if (!isConnected()) return;
    const { needsYou, ready } = allSections();
    const candidates = [...needsYou, ...ready].slice(0, 14);
    for (const item of candidates) {
      if (!peekReadyTranscript(item.id)) {
        prefetchTranscript(item.id);
      }
    }
  });

  const availableProjects = createMemo(() => {
    const counts = new Map<string, { slug: string; title: string; count: number }>();
    for (const item of [...allSections().needsYou, ...allSections().ready]) {
      const existing = counts.get(item.projectSlug);
      if (existing) existing.count++;
      else counts.set(item.projectSlug, { slug: item.projectSlug, title: item.projectTitle, count: 1 });
    }
    return Array.from(counts.values()).sort((a, b) => b.count - a.count);
  });

  createEffect(() => {
    const current = projectFilter();
    if (current && !availableProjects().some((proj) => proj.slug === current)) {
      setProjectFilter(null);
    }
  });

  const filteredNeedsYou = createMemo(() => {
    const filter = projectFilter();
    const list = allSections().needsYou;
    return filter ? list.filter((item) => item.projectSlug === filter) : list;
  });

  const filteredReady = createMemo(() => {
    const filter = projectFilter();
    const list = allSections().ready;
    return filter ? list.filter((item) => item.projectSlug === filter) : list;
  });

  const actionableItems = createMemo(() => [...filteredNeedsYou(), ...filteredReady()]);

  // Keep focusedId anchored to a valid actionable item
  createEffect(() => {
    const items = actionableItems();
    const current = focusedId();
    if (!items.length) {
      if (current !== null) setFocusedId(null);
      return;
    }
    if (!current || !items.some((item) => item.id === current)) {
      setFocusedId(items[0].id);
    }
  });

  const markDone = async (item: InboxItem) => {
    if (busyIds().has(item.id)) return;
    setError(null);
    addBusy(item.id);
    // Optimistically hide and advance focus to the next row
    const items = actionableItems();
    const idx = items.findIndex((x) => x.id === item.id);
    const nextFocus = items[idx + 1]?.id ?? items[idx - 1]?.id ?? null;
    setDismissedIds((prev) => new Set(prev).add(item.id));
    if (replyingId() === item.id) {
      setReplyingId(null);
      setReplyDraft("");
    }
    setFocusedId(nextFocus);
    if (undoTimer) clearTimeout(undoTimer);
    setUndoItem({ id: item.id, title: item.headline });
    undoTimer = setTimeout(() => setUndoItem(null), 6000);

    try {
      await archiveMission(item.id);
      void p.onRefresh();
    } catch (e) {
      setDismissedIds((prev) => {
        const next = new Set(prev);
        next.delete(item.id);
        return next;
      });
      setUndoItem(null);
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      removeBusy(item.id);
    }
  };

  const markAllReadyDone = async () => {
    const readyItems = filteredReady();
    if (!readyItems.length) return;
    setError(null);
    const ids = readyItems.map((i) => i.id);
    setDismissedIds((prev) => {
      const next = new Set(prev);
      for (const id of ids) next.add(id);
      return next;
    });
    try {
      await Promise.all(ids.map((id) => archiveMission(id)));
      void p.onRefresh();
    } catch (e) {
      setDismissedIds((prev) => {
        const next = new Set(prev);
        for (const id of ids) next.delete(id);
        return next;
      });
      setError(e instanceof Error ? e.message : String(e));
    }
  };

  const undoLastDone = async () => {
    const last = undoItem();
    if (!last) return;
    if (undoTimer) clearTimeout(undoTimer);
    setUndoItem(null);
    setError(null);
    setDismissedIds((prev) => {
      const next = new Set(prev);
      next.delete(last.id);
      return next;
    });
    setFocusedId(last.id);
    try {
      await reopenMission(last.id);
      void p.onRefresh();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    }
  };

  const openQuickReply = (item: InboxItem) => {
    setFocusedId(item.id);
    if (replyingId() === item.id) {
      setReplyingId(null);
      setReplyDraft("");
      return;
    }
    setReplyingId(item.id);
    setReplyDraft("");
    queueMicrotask(() => replyInputRef?.focus());
  };

  const submitQuickReply = async (item: InboxItem) => {
    const text = replyDraft().trim();
    if (!text || busyIds().has(item.id)) return;
    setError(null);
    addBusy(item.id);
    try {
      const result = await sendMissionMessage(item.id, text, [], crypto.randomUUID());
      setReplyingId(null);
      setReplyDraft("");
      if (result.replacement) {
        p.onMissionUpdated?.(result.replacement);
      }
      // Once replied, the agent goes back to work; remove from actionable list immediately
      setDismissedIds((prev) => new Set(prev).add(item.id));
      void p.onRefresh();
      setTimeout(() => {
        setDismissedIds((prev) => {
          const next = new Set(prev);
          next.delete(item.id);
          return next;
        });
      }, 2500);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      removeBusy(item.id);
    }
  };

  const triggerOption = async (item: InboxItem, option: InboxOption) => {
    const interaction = item.interaction;
    if (!interaction || busyIds().has(item.id)) return;
    setError(null);
    addBusy(item.id);
    try {
      const answer = option.action
        ? { action: option.action, feedback: "" }
        : {
            answers: option.claudeFormat
              ? { [option.questionText || "0"]: option.label }
              : { [option.questionKey || "0"]: { answers: [option.label] } },
          };

      if (interaction.remote) {
        const res = await api<{ delivered: boolean }>("/api/control/tool_result", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            tool_call_id: interaction.callId,
            name: interaction.toolName || "ui_native_request",
            result: answer,
          }),
        });
        if (!res.delivered) {
          throw new Error("This interactive request has expired. Open the session to continue.");
        }
      } else {
        await invokeLocalInteraction("local_interaction_answer", {
          id: item.id,
          requestId: interaction.callId,
          answer,
        });
      }

      if (interaction.kind === "plan" && option.action === "accept") {
        await rememberApprovedPlan(item.id, {
          requestId: interaction.callId,
          text: interaction.detail ?? interaction.prompt,
          approvedAt: new Date().toISOString(),
        }).catch(() => {});
      }

      await refreshTranscript(item.id).catch(() => {});
      void p.onRefresh();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      removeBusy(item.id);
    }
  };

  const scrollFocusedIntoView = (id: string) => {
    queueMicrotask(() => {
      const el = listContainerRef?.querySelector<HTMLElement>(`[data-inbox-id="${CSS.escape(id)}"]`);
      el?.scrollIntoView({ block: "nearest", behavior: "smooth" });
    });
  };

  onMount(() => {
    const onKeyDown = (e: KeyboardEvent) => {
      if (e.defaultPrevented || e.isComposing || hasFocusScope()) return;
      const target = e.target as HTMLElement | null;
      if (target && target.matches("input, textarea, select, [contenteditable]")) return;
      if (e.metaKey || e.ctrlKey || e.altKey) return;

      const items = actionableItems();
      const currentId = focusedId();
      const currentIdx = items.findIndex((i) => i.id === currentId);
      const currentItem = currentIdx >= 0 ? items[currentIdx] : items[0];

      if (e.key === "ArrowDown" || e.key === "j") {
        if (!items.length) return;
        e.preventDefault();
        const next = items[(currentIdx + 1) % items.length];
        setFocusedId(next.id);
        scrollFocusedIntoView(next.id);
        return;
      }
      if (e.key === "ArrowUp" || e.key === "k") {
        if (!items.length) return;
        e.preventDefault();
        const prev = items[(currentIdx - 1 + items.length) % items.length];
        setFocusedId(prev.id);
        scrollFocusedIntoView(prev.id);
        return;
      }
      if (e.key === "Enter" && currentItem) {
        if (target?.closest("button:not(.inbox-row-main)")) return;
        e.preventDefault();
        p.onOpenMission(currentItem.id);
        return;
      }
      if (e.key.toLowerCase() === "r" && currentItem && !e.shiftKey) {
        e.preventDefault();
        openQuickReply(currentItem);
        return;
      }
      if (e.key.toLowerCase() === "e" && currentItem && !e.shiftKey) {
        e.preventDefault();
        void markDone(currentItem);
        return;
      }
      if (e.key.toLowerCase() === "z" && undoItem() && !e.shiftKey) {
        e.preventDefault();
        void undoLastDone();
        return;
      }
      if ((e.key === "1" || e.key === "2" || e.key === "3") && currentItem?.interaction) {
        const opt = currentItem.interaction.options.find((o) => o.key === e.key);
        if (opt) {
          e.preventDefault();
          void triggerOption(currentItem, opt);
        }
      }
    };
    window.addEventListener("keydown", onKeyDown);
    onCleanup(() => window.removeEventListener("keydown", onKeyDown));
  });

  const renderRow = (item: InboxItem) => {
    const isFocused = () => focusedId() === item.id;
    const isReplying = () => replyingId() === item.id;
    const isBusy = () => busyIds().has(item.id);
    const color = () => projectColor(item.projectSlug);

    return (
      <article
        class={`inbox-row ${isFocused() ? "focused" : ""} ${isBusy() ? "busy" : ""}`}
        data-inbox-id={item.id}
        data-inbox-tone={item.tone}
        onMouseEnter={() => {
          if (!replyingId()) setFocusedId(item.id);
        }}
      >
        <div class="inbox-row-body">
          <button
            type="button"
            class="inbox-row-main"
            onClick={() => p.onOpenMission(item.id)}
            aria-label={`${item.projectTitle}: ${item.headline}. ${item.badge}. ${item.summary}`}
          >
            <div class="inbox-row-top">
              <span class="inbox-project-pill">
                <i
                  class="inbox-project-dot"
                  style={color() ? { background: color() } : undefined}
                  aria-hidden="true"
                />
                <span class="inbox-project-name">{item.projectTitle}</span>
              </span>
              <span class="inbox-sep" aria-hidden="true">·</span>
              <Show when={item.isGoal}>
                <span class="goal-tag small" aria-hidden="true">
                  <Ic.TargetIcon size={10} />
                  <span class="goal-tag-label">Goal</span>
                </span>
              </Show>
              <span class="inbox-headline">{item.headline}</span>
              <span class={`inbox-badge ${item.tone}`}>{item.badge}</span>
              <Show when={item.machine}>
                <span class="inbox-machine">{item.machine}</span>
              </Show>
              <Show when={item.relativeTime}>
                <time class="inbox-time">{item.relativeTime}</time>
              </Show>
            </div>
            <div class="inbox-row-bottom">
              <p class="inbox-summary">{item.summary}</p>
            </div>
          </button>

          <div class="inbox-row-actions">
            <Show when={item.interaction?.options.length}>
              <div class="inbox-options" role="group" aria-label="Quick choices">
                <For each={item.interaction!.options}>
                  {(opt, idx) => (
                    <button
                      type="button"
                      class={`inbox-opt-btn ${idx() === 0 ? "primary" : ""}`}
                      disabled={isBusy()}
                      title={opt.description || `${opt.label} (${opt.key})`}
                      onClick={(e) => {
                        e.stopPropagation();
                        void triggerOption(item, opt);
                      }}
                    >
                      <kbd>{opt.key}</kbd>
                      <span>{opt.label}</span>
                    </button>
                  )}
                </For>
              </div>
            </Show>

            <div class="inbox-triage-btns">
              <button
                type="button"
                class={`inbox-act-btn ${isReplying() ? "on" : ""}`}
                disabled={isBusy()}
                title="Reply inline (R)"
                aria-label={`Reply to ${item.headline}`}
                onClick={(e) => {
                  e.stopPropagation();
                  openQuickReply(item);
                }}
              >
                <Ic.ReplyIcon size={13} />
                <span>Reply</span>
                <kbd aria-hidden="true">R</kbd>
              </button>
              <button
                type="button"
                class="inbox-act-btn done"
                disabled={isBusy()}
                title="Mark done (E)"
                aria-label={`Mark ${item.headline} done`}
                onClick={(e) => {
                  e.stopPropagation();
                  void markDone(item);
                }}
              >
                <Ic.CheckIcon size={13} />
                <span>Done</span>
                <kbd aria-hidden="true">E</kbd>
              </button>
            </div>
          </div>
        </div>

        <Show when={item.interaction?.detail && item.interaction.kind === "permission"}>
          <pre class="inbox-perm-code">{item.interaction!.detail}</pre>
        </Show>

        <Show when={isReplying()}>
          <form
            class="inbox-reply-bar"
            onSubmit={(e) => {
              e.preventDefault();
              void submitQuickReply(item);
            }}
          >
            <input
              ref={replyInputRef}
              type="text"
              class="inbox-reply-input"
              placeholder="Reply to send back to work…"
              aria-label={`Quick reply to ${item.headline}`}
              value={replyDraft()}
              disabled={isBusy()}
              onInput={(e) => setReplyDraft(e.currentTarget.value)}
              onKeyDown={(e) => {
                if (e.key === "Escape") {
                  e.preventDefault();
                  e.stopPropagation();
                  setReplyingId(null);
                  setReplyDraft("");
                }
              }}
            />
            <button
              type="button"
              class="s-btn sm quiet"
              disabled={isBusy()}
              onClick={() => {
                setReplyingId(null);
                setReplyDraft("");
              }}
            >
              Cancel
            </button>
            <button
              type="submit"
              class="s-btn sm primary"
              disabled={isBusy() || !replyDraft().trim()}
            >
              Send <Ic.ReturnIcon size={12} />
            </button>
          </form>
        </Show>
      </article>
    );
  };

  return (
    <div class="page inbox-page" ref={listContainerRef}>
      <div class="page-head inbox-head">
        <div class="inbox-title-group">
          <h2>Inbox</h2>
          <Show when={allSections().totalActionable > 0}>
            <span class="inbox-total-pill" aria-label={`${allSections().totalActionable} items`}>
              {allSections().totalActionable}
            </span>
          </Show>
        </div>

        <div class="inbox-head-right">
          <Show when={allSections().working.length > 0}>
            <button
              type="button"
              class={`inbox-working-pill ${showWorking() ? "on" : ""}`}
              aria-expanded={showWorking()}
              onClick={() => setShowWorking(!showWorking())}
              title="Working agents stay quiet until they need you. Click to inspect."
            >
              <Ic.RunningDots />
              <span>{allSections().working.length} working</span>
            </button>
          </Show>
          <div class="inbox-key-legend" aria-hidden="true">
            <span><kbd>J</kbd><kbd>K</kbd> navigate</span>
            <span><kbd>R</kbd> reply</span>
            <span><kbd>E</kbd> done</span>
          </div>
        </div>
      </div>

      <p class="s-lead inbox-lead">
        Agents that need your input or finished their run. Working agents stay quiet until they need you.
      </p>

      <Show when={error()}>
        <ErrorNotice
          error={error()!}
          title="Couldn’t update mission"
          onDismiss={() => setError(null)}
        />
      </Show>

      <Show
        when={isConnected()}
        fallback={
          <div class="s-card inbox-empty">
            <div class="inbox-empty-ico">
              <Ic.InboxIcon size={22} />
            </div>
            <strong>No backend connected</strong>
            <p>Connect to your sandboxed.sh backend to triage active and completed agents.</p>
            <button type="button" class="s-btn primary" onClick={p.onOpenSettings}>
              Connect backend
            </button>
          </div>
        }
      >
        <Show when={availableProjects().length > 1}>
          <div class="inbox-filters" role="toolbar" aria-label="Filter by project">
            <button
              type="button"
              class={`inbox-filter-chip ${projectFilter() === null ? "on" : ""}`}
              onClick={() => setProjectFilter(null)}
            >
              All projects
            </button>
            <For each={availableProjects()}>
              {(proj) => (
                <button
                  type="button"
                  class={`inbox-filter-chip ${projectFilter() === proj.slug ? "on" : ""}`}
                  onClick={() =>
                    setProjectFilter(projectFilter() === proj.slug ? null : proj.slug)
                  }
                >
                  <i
                    class="inbox-project-dot"
                    style={
                      projectColor(proj.slug)
                        ? { background: projectColor(proj.slug) }
                        : undefined
                    }
                    aria-hidden="true"
                  />
                  <span>{proj.title}</span>
                  <span class="inbox-filter-count">{proj.count}</span>
                </button>
              )}
            </For>
          </div>
        </Show>

        <Show when={showWorking() && allSections().working.length > 0}>
          <section class="inbox-sec working-sec" aria-label="Working quietly">
            <div class="inbox-sec-head">
              <h3>Working quietly</h3>
              <span class="inbox-sec-note">Hidden from triage until they finish or ask</span>
            </div>
            <div class="inbox-working-list">
              <For each={allSections().working}>
                {(item) => (
                  <button
                    type="button"
                    class="inbox-working-row"
                    onClick={() => p.onOpenMission(item.id)}
                  >
                    <Ic.RunningDots />
                    <span class="inbox-project-pill">
                      <i
                        class="inbox-project-dot"
                        style={
                          projectColor(item.projectSlug)
                            ? { background: projectColor(item.projectSlug) }
                            : undefined
                        }
                        aria-hidden="true"
                      />
                      <span class="inbox-project-name">{item.projectTitle}</span>
                    </span>
                    <span class="inbox-sep" aria-hidden="true">·</span>
                    <span class="inbox-headline">{item.headline}</span>
                    <Show when={item.machine}>
                      <span class="inbox-machine">{item.machine}</span>
                    </Show>
                    <Show when={item.relativeTime}>
                      <time class="inbox-time">{item.relativeTime}</time>
                    </Show>
                  </button>
                )}
              </For>
            </div>
          </section>
        </Show>

        <Show
          when={!p.loading || p.missions.length > 0}
          fallback={<InboxSkeleton />}
        >
          <Show
            when={actionableItems().length > 0}
            fallback={
              <div class="s-card inbox-empty" role="status">
                <div class="inbox-empty-ico">
                  <Ic.CheckIcon size={20} />
                </div>
                <strong>All caught up</strong>
                <p>
                  {allSections().working.length > 0
                    ? `${allSections().working.length} ${allSections().working.length === 1 ? "agent is" : "agents are"} working quietly in the background and will appear here when ready.`
                    : "No agents are waiting on your input or review right now."}
                </p>
                <div class="inbox-empty-actions">
                  <Show when={allSections().working.length > 0}>
                    <button
                      type="button"
                      class="s-btn"
                      onClick={() => setShowWorking(!showWorking())}
                    >
                      {showWorking() ? "Hide working agents" : `Inspect ${allSections().working.length} working`}
                    </button>
                  </Show>
                  <button type="button" class="s-btn" onClick={p.onNewAgent}>
                    New Agent
                  </button>
                </div>
              </div>
            }
          >
            <Show when={filteredNeedsYou().length > 0}>
              <section class="inbox-sec" aria-label="Needs you">
                <div class="inbox-sec-head">
                  <h3>Needs you</h3>
                  <span class="inbox-sec-count">{filteredNeedsYou().length}</span>
                </div>
                <div class="inbox-list">
                  <For each={filteredNeedsYou()}>{(item) => renderRow(item)}</For>
                </div>
              </section>
            </Show>

            <Show when={filteredReady().length > 0}>
              <section class="inbox-sec" aria-label="Ready for review">
                <div class="inbox-sec-head">
                  <h3>Ready for review</h3>
                  <span class="inbox-sec-count">{filteredReady().length}</span>
                  <Show when={filteredReady().length > 1}>
                    <button
                      type="button"
                      class="inbox-clear-btn"
                      onClick={() => void markAllReadyDone()}
                    >
                      Mark all done
                    </button>
                  </Show>
                </div>
                <div class="inbox-list">
                  <For each={filteredReady()}>{(item) => renderRow(item)}</For>
                </div>
              </section>
            </Show>
          </Show>
        </Show>
      </Show>

      <Show when={undoItem()}>
        {(u) => (
          <div class="inbox-undo-toast" role="status" aria-live="polite">
            <span>
              Marked <strong>{u().title}</strong> done
            </span>
            <button type="button" class="inbox-undo-btn" onClick={() => void undoLastDone()}>
              Undo <kbd>Z</kbd>
            </button>
          </div>
        )}
      </Show>
    </div>
  );
}
