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
  getCachedInboxDigest,
  inboxDigestVersion,
  requestInboxDigest,
} from "./inboxDigest";
import {
  buildInboxSections,
  type InboxItem,
  type InboxOption,
} from "./inboxModel";
import { inboxConfig } from "./inboxSettings";
import { MdView as Markdown } from "./Markdown";
import { pendingMissionInteraction } from "./missionAttention";
import {
  loadTranscript,
  peekReadyTranscript,
  prefetchTranscript,
  refreshTranscript,
  transcriptVersion,
} from "./missionCache";
import {
  markMissionRead,
  markMissionUnread,
  markMissionsRead,
  unreadVersion,
} from "./missionUnread";
import { rememberApprovedPlan } from "./PlanProgress";
import { projectColor } from "./projectAppearance";
import { InboxSkeleton } from "./Skeleton";

export type InboxViewMode = "unread" | "attention" | "all";

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
  onOpenInboxSettings?: () => void;
  onNewAgent: () => void;
  onRefresh: () => Promise<void> | void;
  onMissionUpdated?: (mission: Mission) => void;
}) {
  const [viewMode, setViewMode] = createSignal<InboxViewMode>("unread");
  const [projectFilter, setProjectFilter] = createSignal<string | null>(null);
  const [showWorking, setShowWorking] = createSignal(false);
  const [focusedId, setFocusedId] = createSignal<string | null>(null);
  const [replyingId, setReplyingId] = createSignal<string | null>(null);
  const [replyDraft, setReplyDraft] = createSignal("");
  const [peekedIds, setPeekedIds] = createSignal<ReadonlySet<string>>(new Set());
  const [expandedPeekIds, setExpandedPeekIds] = createSignal<ReadonlySet<string>>(new Set());
  const [peekReplyDrafts, setPeekReplyDrafts] = createSignal<Record<string, string>>({});
  const [busyIds, setBusyIds] = createSignal<ReadonlySet<string>>(new Set());
  const [dismissedIds, setDismissedIds] = createSignal<ReadonlySet<string>>(new Set());
  const [undoItem, setUndoItem] = createSignal<{
    id: string;
    title: string;
    mission: Mission;
    wasUnread: boolean;
  } | null>(null);
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
    unreadVersion();
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

  const refreshedTranscriptAt = new Map<string, number>();

  // Load or refresh transcripts for top actionable items so their summary and AI digest reflect the latest turn immediately.
  createEffect(() => {
    if (!isConnected()) return;
    const cfg = inboxConfig();
    const { needsYou, ready } = allSections();
    const candidates = [...needsYou, ...ready].slice(0, 14);
    candidates.forEach((item, idx) => {
      const prevMs = refreshedTranscriptAt.get(item.id);
      const readyTx = peekReadyTranscript(item.id);
      if (!readyTx) {
        refreshedTranscriptAt.set(item.id, item.updatedMs);
        if (idx < 8) {
          void loadTranscript(item.id).catch(() => {});
        } else {
          prefetchTranscript(item.id);
        }
      } else if (prevMs === undefined || item.updatedMs > prevMs) {
        refreshedTranscriptAt.set(item.id, item.updatedMs);
        void refreshTranscript(item.id).catch(() => {});
      }
      if (cfg.aiSummary && idx < 10 && !item.interaction) {
        requestInboxDigest(item.mission, readyTx?.items, item.updatedMs);
      }
    });
  });

  const matchesViewMode = (item: InboxItem, mode = viewMode()): boolean => {
    if (mode === "unread") return item.unread;
    if (mode === "attention") return item.attention;
    return true;
  };

  const modeFilteredNeedsYou = createMemo(() =>
    allSections().needsYou.filter((item) => matchesViewMode(item)),
  );

  const modeFilteredReady = createMemo(() =>
    allSections().ready.filter((item) => matchesViewMode(item)),
  );

  const availableProjects = createMemo(() => {
    const counts = new Map<string, { slug: string; title: string; count: number }>();
    for (const item of [...modeFilteredNeedsYou(), ...modeFilteredReady()]) {
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
    const list = modeFilteredNeedsYou();
    return filter ? list.filter((item) => item.projectSlug === filter) : list;
  });

  const filteredReady = createMemo(() => {
    const filter = projectFilter();
    const list = modeFilteredReady();
    return filter ? list.filter((item) => item.projectSlug === filter) : list;
  });

  const actionableItems = createMemo(() => [...filteredNeedsYou(), ...filteredReady()]);

  const unreadItemsInScope = createMemo(() => {
    const filter = projectFilter();
    return [...allSections().needsYou, ...allSections().ready].filter(
      (item) => item.unread && (!filter || item.projectSlug === filter),
    );
  });

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

  const markItemAndChildrenRead = (item: InboxItem) => {
    markMissionRead(item.mission);
    if (item.childSummary?.failedChildren.length) {
      markMissionsRead(item.childSummary.failedChildren.map((c) => c.mission));
    }
  };

  const toggleReadState = (item: InboxItem) => {
    if (item.unread) {
      const items = actionableItems();
      const idx = items.findIndex((x) => x.id === item.id);
      const nextFocus = items[idx + 1]?.id ?? items[idx - 1]?.id ?? null;
      markItemAndChildrenRead(item);
      if (viewMode() === "unread" && focusedId() === item.id) {
        setFocusedId(nextFocus);
      }
    } else {
      markMissionUnread(item.mission);
    }
  };

  const markAllUnreadAsRead = () => {
    const items = unreadItemsInScope();
    if (!items.length) return;
    const allMissions: Mission[] = [];
    for (const item of items) {
      allMissions.push(item.mission);
      if (item.childSummary?.failedChildren.length) {
        for (const c of item.childSummary.failedChildren) allMissions.push(c.mission);
      }
    }
    markMissionsRead(allMissions);
  };

  const togglePeek = (item: InboxItem) => {
    setFocusedId(item.id);
    const open = !peekedIds().has(item.id);
    setPeekedIds((prev) => {
      const next = new Set(prev);
      if (open) next.add(item.id);
      else next.delete(item.id);
      return next;
    });
    if (open) {
      if (!peekReadyTranscript(item.id)) {
        void loadTranscript(item.id).catch(() => {});
      } else {
        void refreshTranscript(item.id).catch(() => {});
      }
    }
  };

  const retryMission = async (item: InboxItem) => {
    if (busyIds().has(item.id)) return;
    setError(null);
    addBusy(item.id);
    markItemAndChildrenRead(item);
    try {
      const result = await sendMissionMessage(
        item.id,
        "Continue from where you left off.",
        [],
        crypto.randomUUID(),
      );
      if (result.replacement) {
        p.onMissionUpdated?.(result.replacement);
      }
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

  const markDone = async (item: InboxItem) => {
    if (busyIds().has(item.id)) return;
    setError(null);
    addBusy(item.id);
    const wasUnread = item.unread;
    markItemAndChildrenRead(item);
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
    setUndoItem({ id: item.id, title: item.headline, mission: item.mission, wasUnread });
    undoTimer = setTimeout(() => setUndoItem(null), 6000);

    try {
      await archiveMission(item.id);
      void p.onRefresh();
    } catch (e) {
      if (wasUnread) markMissionUnread(item.mission);
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
    markMissionsRead(readyItems.map((i) => i.mission));
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
    if (last.wasUnread) {
      markMissionUnread(last.mission);
    }
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
    markItemAndChildrenRead(item);
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
    markMissionRead(item.mission);
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
        markItemAndChildrenRead(currentItem);
        p.onOpenMission(currentItem.id);
        return;
      }
      if (e.key === " " && currentItem) {
        if (target?.closest("button:not(.inbox-row-main)")) return;
        e.preventDefault();
        togglePeek(currentItem);
        return;
      }
      if (e.key.toLowerCase() === "r" && currentItem && e.shiftKey && currentItem.canRetry) {
        e.preventDefault();
        void retryMission(currentItem);
        return;
      }
      if (e.key.toLowerCase() === "r" && currentItem && !e.shiftKey) {
        e.preventDefault();
        openQuickReply(currentItem);
        return;
      }
      if (e.key.toLowerCase() === "u" && currentItem && !e.shiftKey) {
        e.preventDefault();
        toggleReadState(currentItem);
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

  const submitPeekReply = async (item: InboxItem) => {
    const text = (peekReplyDrafts()[item.id] ?? "").trim();
    if (!text || busyIds().has(item.id)) return;
    setError(null);
    addBusy(item.id);
    markItemAndChildrenRead(item);
    try {
      const result = await sendMissionMessage(item.id, text, [], crypto.randomUUID());
      setPeekReplyDrafts((prev) => {
        const next = { ...prev };
        delete next[item.id];
        return next;
      });
      if (result.replacement) {
        p.onMissionUpdated?.(result.replacement);
      }
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

  const renderRow = (item: InboxItem) => {
    const isFocused = () => focusedId() === item.id;
    const isReplying = () => replyingId() === item.id;
    const isPeeked = () => peekedIds().has(item.id);
    const isPeekExpanded = () => expandedPeekIds().has(item.id);
    const isBusy = () => busyIds().has(item.id);
    const color = () => projectColor(item.projectSlug);
    const digest = () => {
      inboxDigestVersion();
      if (!inboxConfig().aiSummary) return undefined;
      return getCachedInboxDigest(item.id, item.updatedMs);
    };
    const taskLine = () => digest()?.task || item.lastRequest;
    const outcomeLine = () => digest()?.outcome || item.summary;
    const verdict = () => digest()?.verdict || item.verdict;
    const showTaskLine = () => {
      if (item.interaction) return false;
      const t = taskLine()?.trim();
      if (!t) return false;
      if (digest()?.task) return true;
      return t.toLowerCase() !== item.headline.trim().toLowerCase();
    };
    const visiblePeekTurns = () => {
      const all = item.allPeekTurns?.length ? item.allPeekTurns : item.peekTurns;
      if (isPeekExpanded() || all.length <= 4) return all;
      return all.slice(-4);
    };
    const hiddenPeekCount = () => {
      const all = item.allPeekTurns?.length ? item.allPeekTurns : item.peekTurns;
      return Math.max(0, all.length - visiblePeekTurns().length);
    };

    return (
      <article
        class={`inbox-row ${item.unread ? "unread" : "read"} ${isFocused() ? "focused" : ""} ${isPeeked() ? "peeked" : ""} ${isBusy() ? "busy" : ""}`}
        data-inbox-id={item.id}
        data-inbox-tone={item.tone}
        data-inbox-unread={item.unread ? "true" : "false"}
        onMouseEnter={() => {
          if (!replyingId()) setFocusedId(item.id);
        }}
      >
        <div class="inbox-row-body">
          <div class="inbox-row-main-col">
            <button
              type="button"
              class="inbox-row-main"
              onClick={() => {
                markItemAndChildrenRead(item);
                p.onOpenMission(item.id);
              }}
              aria-label={`${item.unread ? "Unread. " : ""}${item.projectTitle}: ${item.headline}. ${item.badge}. ${outcomeLine()}`}
            >
              <div class="inbox-row-top">
                <Show when={item.unread}>
                  <span
                    class="inbox-unread-dot"
                    title="Unread response"
                    aria-hidden="true"
                  />
                </Show>
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
              <Show when={showTaskLine()}>
                <div class="inbox-task-row">
                  <span class="inbox-digest-tag task">Task</span>
                  <span class="inbox-task-text">{taskLine()}</span>
                </div>
              </Show>
              <div class="inbox-row-bottom">
                <Show when={!item.interaction}>
                  <span
                    class={`inbox-digest-tag outcome ${verdict()}`}
                    title={
                      digest()?.aiGenerated
                        ? `AI summary (${digest()?.model || inboxConfig().model})`
                        : undefined
                    }
                  >
                    {verdict() === "failed"
                      ? "✕ Failed"
                      : verdict() === "waiting"
                        ? "⏳ Waiting"
                        : verdict() === "needs_input"
                          ? "? Input"
                          : "✓ Outcome"}
                  </span>
                </Show>
                <p class="inbox-summary">{outcomeLine()}</p>
                <Show when={!item.interaction && item.workReceiptSummary}>
                  <span class="inbox-work-chip" title="Tools executed in the latest turn">
                    {item.workReceiptSummary}
                  </span>
                </Show>
              </div>
            </button>

            <Show when={item.childSummary && item.childSummary.total > 0}>
              {(() => {
                const cs = item.childSummary!;
                const firstFailed = cs.failedChildren[0];
                return (
                  <div class="inbox-child-bar">
                    <Show
                      when={firstFailed}
                      fallback={
                        <span class="inbox-child-pill">
                          {cs.total} {cs.total === 1 ? "track" : "tracks"} · {cs.completed} completed
                          {cs.running > 0 ? ` · ${cs.running} running` : ""}
                        </span>
                      }
                    >
                      <button
                        type="button"
                        class="inbox-child-pill failed"
                        title={`Open failed child track: ${firstFailed.title}`}
                        onClick={(e) => {
                          e.stopPropagation();
                          markItemAndChildrenRead(item);
                          p.onOpenMission(firstFailed.id);
                        }}
                      >
                        <span class="inbox-child-dot" aria-hidden="true" />
                        <span>
                          {cs.failed} {cs.failed === 1 ? "track" : "tracks"} failed: {firstFailed.title}
                        </span>
                        <span aria-hidden="true">→</span>
                      </button>
                    </Show>
                  </div>
                );
              })()}
            </Show>
          </div>

          <Show when={item.interaction?.options.length}>
            <div class="inbox-row-actions">
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
            </div>
          </Show>

          <div class="inbox-triage-btns">
            <Show when={item.canRetry}>
              <button
                type="button"
                class="inbox-act-btn retry"
                disabled={isBusy()}
                title="Retry / resume mission (⇧R)"
                aria-label={`Retry ${item.headline}`}
                onClick={(e) => {
                  e.stopPropagation();
                  void retryMission(item);
                }}
              >
                <span aria-hidden="true">↻</span>
                <span>Retry</span>
                <kbd aria-hidden="true">⇧R</kbd>
              </button>
            </Show>
            <button
              type="button"
              class={`inbox-act-btn ${isPeeked() ? "on" : ""}`}
              disabled={isBusy()}
              title="Peek recent turns (Space)"
              aria-label={`Peek ${item.headline}`}
              aria-expanded={isPeeked()}
              onClick={(e) => {
                e.stopPropagation();
                togglePeek(item);
              }}
            >
              <span>Peek</span>
              <kbd aria-hidden="true">Space</kbd>
            </button>
            <Show when={item.unread}>
              <button
                type="button"
                class="inbox-act-btn"
                disabled={isBusy()}
                title="Mark as read (U)"
                aria-label={`Mark ${item.headline} as read`}
                onClick={(e) => {
                  e.stopPropagation();
                  toggleReadState(item);
                }}
              >
                <span class="inbox-unread-dot sm" aria-hidden="true" />
                <span>Read</span>
                <kbd aria-hidden="true">U</kbd>
              </button>
            </Show>
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
              title="Archive & mark done (E)"
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

        <Show when={item.interaction?.detail && item.interaction.kind === "permission"}>
          <pre class="inbox-perm-code">{item.interaction!.detail}</pre>
        </Show>

        <Show when={isPeeked()}>
          <div class="inbox-peek-drawer" role="region" aria-label={`Recent turns for ${item.headline}`}>
            <div class="inbox-peek-head">
              <div class="inbox-peek-head-left">
                <Show when={hiddenPeekCount() > 0}>
                  <button
                    type="button"
                    class="inbox-peek-more-btn"
                    onClick={(e) => {
                      e.stopPropagation();
                      setExpandedPeekIds((prev) => {
                        const next = new Set(prev);
                        next.add(item.id);
                        return next;
                      });
                    }}
                  >
                    ↑ Show {hiddenPeekCount()} earlier {hiddenPeekCount() === 1 ? "turn" : "turns"}
                  </button>
                </Show>
              </div>
              <button
                type="button"
                class="inbox-peek-open"
                onClick={() => {
                  markItemAndChildrenRead(item);
                  p.onOpenMission(item.id);
                }}
              >
                Open full conversation →
              </button>
            </div>

            <div
              class="inbox-peek-scroll"
              ref={(el) => {
                queueMicrotask(() => {
                  el.scrollTop = el.scrollHeight;
                });
              }}
            >
              <div class="inbox-peek-turns">
                <For each={visiblePeekTurns()}>
                  {(turn) => (
                    <>
                      <Show when={turn.workReceipt}>
                        {(receipt) => (
                          <details class={`inbox-peek-work ${receipt().failed ? "failed" : ""}`}>
                            <summary class="inbox-peek-work-sum">
                              <span class="inbox-peek-work-ico" aria-hidden="true">
                                {receipt().failed ? "✕" : "⚡"}
                              </span>
                              <span>
                                {receipt().failed ? "Failed" : "Worked"} — {receipt().summary}
                              </span>
                            </summary>
                            <Show when={receipt().details.length > 0}>
                              <ul class="inbox-peek-work-list">
                                <For each={receipt().details}>
                                  {(line) => <li>{line}</li>}
                                </For>
                              </ul>
                            </Show>
                          </details>
                        )}
                      </Show>
                      <div class={`inbox-peek-turn ${turn.role}`}>
                        <div class="inbox-peek-turn-head">
                          <span class={`inbox-peek-role ${turn.role}`}>
                            {turn.role === "user" ? "You" : turn.role === "error" ? "Error" : "Agent"}
                          </span>
                        </div>
                        <div class="inbox-peek-turn-body">
                          <Markdown text={turn.markdown || turn.text} />
                        </div>
                      </div>
                    </>
                  )}
                </For>
              </div>
            </div>

            <form
              class="inbox-peek-reply-bar"
              onSubmit={(e) => {
                e.preventDefault();
                void submitPeekReply(item);
              }}
            >
              <input
                type="text"
                class="inbox-reply-input"
                placeholder={`Reply to ${item.headline}…`}
                aria-label={`Reply in peek to ${item.headline}`}
                value={peekReplyDrafts()[item.id] ?? ""}
                disabled={isBusy()}
                onInput={(e) =>
                  setPeekReplyDrafts((prev) => ({
                    ...prev,
                    [item.id]: e.currentTarget.value,
                  }))
                }
                onKeyDown={(e) => {
                  if (e.key === "Escape") {
                    e.preventDefault();
                    e.stopPropagation();
                    togglePeek(item);
                  }
                }}
              />
              <button
                type="submit"
                class="s-btn sm primary"
                disabled={isBusy() || !(peekReplyDrafts()[item.id] ?? "").trim()}
              >
                Send <Ic.ReturnIcon size={12} />
              </button>
            </form>
          </div>
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

  const headerBadgeCount = () =>
    viewMode() === "unread"
      ? allSections().unreadCount
      : viewMode() === "attention"
        ? allSections().attentionCount
        : allSections().totalActionable;

  return (
    <div class="page inbox-page" ref={listContainerRef}>
      <div class="page-head inbox-head">
        <div class="inbox-title-group">
          <h2>Inbox</h2>
          <Show when={headerBadgeCount() > 0}>
            <span class="inbox-total-pill" aria-label={`${headerBadgeCount()} items`}>
              {headerBadgeCount()}
            </span>
          </Show>
        </div>

        <div class="inbox-head-right">
          <button
            type="button"
            class="inbox-model-pill"
            title="Configure Inbox AI summary model in Settings"
            onClick={() => (p.onOpenInboxSettings ?? p.onOpenSettings)()}
          >
            <Ic.GearIcon size={12} />
            <span>
              {inboxConfig().aiSummary ? `AI · ${inboxConfig().model}` : "AI summary off"}
            </span>
          </button>
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
            <span><kbd>Space</kbd> peek</span>
            <span><kbd>U</kbd> read</span>
            <span><kbd>R</kbd> reply</span>
            <span><kbd>⇧R</kbd> retry</span>
            <span><kbd>E</kbd> done</span>
          </div>
        </div>
      </div>

      <p class="s-lead inbox-lead">
        New agent responses and questions waiting on you. Working agents stay quiet until they finish.
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
        <div class="inbox-toolbar">
          <div class="inbox-mode-tabs" role="tablist" aria-label="Inbox filter">
            <button
              type="button"
              role="tab"
              data-inbox-filter="unread"
              aria-selected={viewMode() === "unread"}
              class={`inbox-mode-tab ${viewMode() === "unread" ? "on" : ""}`}
              onClick={() => setViewMode("unread")}
            >
              <span class="inbox-unread-dot" aria-hidden="true" />
              <span>Unread</span>
              <span class="inbox-filter-count">{allSections().unreadCount}</span>
            </button>
            <button
              type="button"
              role="tab"
              data-inbox-filter="attention"
              aria-selected={viewMode() === "attention"}
              class={`inbox-mode-tab ${viewMode() === "attention" ? "on" : ""}`}
              onClick={() => setViewMode("attention")}
            >
              <span>Needs attention</span>
              <span class="inbox-filter-count">{allSections().attentionCount}</span>
            </button>
            <button
              type="button"
              role="tab"
              data-inbox-filter="all"
              aria-selected={viewMode() === "all"}
              class={`inbox-mode-tab ${viewMode() === "all" ? "on" : ""}`}
              onClick={() => setViewMode("all")}
            >
              <span>All</span>
              <span class="inbox-filter-count">{allSections().totalActionable}</span>
            </button>
          </div>

          <Show when={unreadItemsInScope().length > 0}>
            <button
              type="button"
              class="inbox-mark-all-read-btn"
              onClick={markAllUnreadAsRead}
              title="Mark all unread responses as read"
            >
              <Ic.CheckIcon size={12} />
              <span>Mark all read</span>
            </button>
          </Show>
        </div>

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
                <strong>
                  {viewMode() === "unread"
                    ? "All caught up on unread responses"
                    : viewMode() === "attention"
                      ? "Nothing blocked or failing"
                      : "All caught up"}
                </strong>
                <p>
                  {viewMode() === "unread" && allSections().totalActionable > 0
                    ? `You’ve opened every recent agent response. ${allSections().totalActionable} earlier ${allSections().totalActionable === 1 ? "conversation is" : "conversations are"} available in All.`
                    : allSections().working.length > 0
                      ? `${allSections().working.length} ${allSections().working.length === 1 ? "agent is" : "agents are"} working quietly in the background and will appear here when ready.`
                      : "No agents are waiting on your input or review right now."}
                </p>
                <div class="inbox-empty-actions">
                  <Show when={viewMode() !== "all" && allSections().totalActionable > 0}>
                    <button
                      type="button"
                      class="s-btn"
                      onClick={() => setViewMode("all")}
                    >
                      View all ({allSections().totalActionable})
                    </button>
                  </Show>
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
