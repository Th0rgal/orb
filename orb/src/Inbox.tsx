import {
  For,
  Show,
  createEffect,
  createMemo,
  createSignal,
  createUniqueId,
  onCleanup,
  onMount,
  untrack,
  useContext,
  type JSX,
} from "solid-js";
import {
  api,
  archiveMission,
  cancelMission,
  connectionVersion,
  isConnected,
  reopenMission,
  sendMissionMessage,
  type Mission,
  type ProjectSummary,
} from "./api";
import { Composer } from "./App";
import { chipToAttachment, type AttachChip } from "./attach";
import { ErrorNotice } from "./ErrorNotice";
import {
  FileReferenceContext,
  type ReferenceResolver,
} from "./fileReferenceContext";
import {
  createFileClient,
  fileScopeKey,
  parseFileTarget,
  type FileRef,
  type FileSource,
} from "./fileResources";
import { hasOverlay } from "./overlayLayer";
import * as Ic from "./icons";
import {
  imagePrompt,
  stageLocalImages,
  stageRemoteImages,
  type DraftImage,
} from "./imageAttachments";
import {
  getCachedInboxDigest,
  inboxDigestVersion,
  requestInboxDigest,
} from "./inboxDigest";
import {
  buildInboxSections,
  buildPeekStreamItems,
  isSyntheticUserMessage,
  type InboxItem,
  type InboxOption,
} from "./inboxModel";
import { inboxConfig } from "./inboxSettings";
import {
  bindWorkspace,
  localBinding,
  materializeMentions,
  prepareProjectSkills,
  refreshLocalBindings,
  writeLocalFiles,
} from "./localAgents";
import { enqueueLocalMessage } from "./localMessageQueue";
import { pendingMissionInteraction } from "./missionAttention";
import {
  loadTranscript,
  peekReadyTranscript,
  peekTranscript,
  prefetchTranscript,
  putTranscript,
  putTranscriptItems,
  refreshTranscript,
  retainTranscript,
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
import { streamMission, type StreamEvent } from "./stream";
import { Transcript, type StreamItem } from "./Transcript";
import { applyStreamEvent } from "./transcriptModel";
import "./Inbox.css";

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

function MissionFileScope(p: {
  mission: Mission;
  onOpenMission: (id: string) => void;
  children: JSX.Element;
}) {
  const parent = useContext(FileReferenceContext);
  let client = createFileClient({ mission: p.mission });
  let rootPromise: Promise<FileSource[]> | undefined;
  const cache = new Map<string, Promise<FileRef[]>>();
  let queue = new Map<string, Array<(refs: FileRef[]) => void>>();
  let batchTimer: ReturnType<typeof setTimeout> | undefined;
  let generation = 0;

  const scopeKey = createMemo(() => fileScopeKey({ mission: p.mission }));

  createEffect(() => {
    scopeKey();
    generation += 1;
    if (batchTimer) {
      clearTimeout(batchTimer);
      batchTimer = undefined;
    }
    for (const callbacks of queue.values()) {
      callbacks.forEach((cb) => cb([]));
    }
    queue = new Map();
    client = createFileClient({ mission: p.mission });
    rootPromise = undefined;
    cache.clear();
  });

  onCleanup(() => {
    generation += 1;
    if (batchTimer) clearTimeout(batchTimer);
  });

  const ensureRoots = () => {
    if (!rootPromise) {
      rootPromise = client.roots().catch((err) => {
        rootPromise = undefined;
        throw err;
      });
    }
    return rootPromise;
  };

  async function flushReferences() {
    batchTimer = undefined;
    const pending = queue;
    queue = new Map();
    const g = generation;
    const c = client;
    try {
      const roots = await ensureRoots();
      const paths = [...pending.keys()];
      const all = new Map<string, FileRef[]>();
      for (let i = 0; i < paths.length; i += 64) {
        await Promise.all(
          roots
            .filter((s) => s.available)
            .map(async (root) => {
              try {
                const reply = await c.call(root.id, {
                  action: "resolve",
                  paths: paths.slice(i, i + 64),
                });
                for (const r of reply.results ?? []) {
                  all.set(r.reference, [
                    ...(all.get(r.reference) ?? []),
                    ...r.matches.map((m) => ({ ...m, source: root.id })),
                  ]);
                }
              } catch {
                /* unavailable sources never manufacture a link */
              }
            }),
        );
      }
      for (const [path, callbacks] of pending) {
        callbacks.forEach((cb) =>
          cb(g === generation ? (all.get(path) ?? []) : []),
        );
      }
    } catch {
      for (const callbacks of pending.values()) {
        callbacks.forEach((cb) => cb([]));
      }
    }
  }

  const resolver: ReferenceResolver = {
    async loadImage(path) {
      scopeKey();
      const g = generation;
      const c = client;
      const preview = c.imagePreview(path);
      if (preview) return preview;
      const extension = path.split(".").at(-1)?.toLowerCase();
      const mime = (
        {
          png: "image/png",
          jpg: "image/jpeg",
          jpeg: "image/jpeg",
          webp: "image/webp",
          gif: "image/gif",
        } as Record<string, string>
      )[extension ?? ""];
      if (!mime) return null;
      cache.delete(path);
      const refs = await resolver.resolve(path);
      if (g !== generation) return null;
      if (!refs.length) {
        rootPromise = undefined;
        const url = await c.loadUploadedImage(path);
        if (g !== generation) {
          if (url) URL.revokeObjectURL(url);
          return null;
        }
        return url;
      }
      const ref = refs[0];
      const chunks: Uint8Array[] = [];
      let offset = 0;
      while (true) {
        const part = await c.call(ref.source, {
          action: "download",
          path: ref.path,
          offset,
        });
        if (g !== generation) return null;
        if (!part.bytes?.length || !part.size || part.size > 20 * 1024 * 1024)
          return null;
        chunks.push(new Uint8Array(part.bytes));
        offset += part.bytes.length;
        if (offset >= part.size) break;
        if (offset > 20 * 1024 * 1024) return null;
      }
      return URL.createObjectURL(new Blob(chunks as BlobPart[], { type: mime }));
    },
    resolve(raw) {
      const parsed = parseFileTarget(raw);
      if (!parsed) return Promise.resolve([]);
      const path = parsed.path;
      if (!cache.has(path)) {
        cache.set(
          path,
          new Promise((resolve) => {
            queue.set(path, [...(queue.get(path) ?? []), resolve]);
            if (!batchTimer)
              batchTimer = setTimeout(() => void flushReferences(), 80);
          }),
        );
      }
      return cache
        .get(path)!
        .then((refs) => refs.map((r) => ({ ...r, line: parsed.line })));
    },
    open(refs) {
      if (parent && refs.length > 0) {
        parent.open(refs);
      } else {
        p.onOpenMission(p.mission.id);
      }
    },
    search(query) {
      if (parent) {
        parent.search(query);
      } else {
        p.onOpenMission(p.mission.id);
      }
    },
  };

  return (
    <FileReferenceContext.Provider value={resolver}>
      {p.children}
    </FileReferenceContext.Provider>
  );
}

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
  const viewId = createUniqueId();
  const [viewMode, setViewMode] = createSignal<InboxViewMode>("unread");
  const [projectFilter, setProjectFilter] = createSignal<string | null>(null);
  const [showWorking, setShowWorking] = createSignal(false);
  const [focusedId, setFocusedId] = createSignal<string | null>(null);
  const [replyingId, setReplyingId] = createSignal<string | null>(null);
  const [peekedIds, setPeekedIds] = createSignal<ReadonlySet<string>>(new Set());
  const [expandedPeekIds, setExpandedPeekIds] = createSignal<ReadonlySet<string>>(new Set());
  const [seenUnreadIds, setSeenUnreadIds] = createSignal<ReadonlySet<string>>(new Set());
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
  let listContainerRef: HTMLDivElement | undefined;
  const peekedSectionById = new Map<string, "needs_you" | "ready">();

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
      (id) => (peekReadyTranscript(id) ?? peekTranscript(id))?.items,
      (id) => pendingMissionInteraction(id),
      nowMs(),
    );
  });

  // Remember items that were unread during the current Inbox session so interacting with them
  // (e.g. replying in Peek or toggling read state) transitions their visual styling to .read
  // without yanking the card out from under the user until they switch tabs or mark Done.
  createEffect(() => {
    const secs = allSections();
    const currentUnread = [...secs.needsYou, ...secs.ready].filter((i) => i.unread);
    for (const item of secs.needsYou) peekedSectionById.set(item.id, "needs_you");
    for (const item of secs.ready) peekedSectionById.set(item.id, "ready");
    if (!currentUnread.length) return;
    setSeenUnreadIds((prev) => {
      let changed = false;
      const next = new Set(prev);
      for (const item of currentUnread) {
        if (!next.has(item.id)) {
          next.add(item.id);
          changed = true;
        }
      }
      return changed ? next : prev;
    });
  });

  const switchViewMode = (mode: InboxViewMode) => {
    if (viewMode() === mode) return;
    setSeenUnreadIds(new Set<string>());
    setViewMode(mode);
  };

  const itemById = createMemo(() => {
    const map = new Map<string, InboxItem>();
    const secs = allSections();
    for (const item of secs.needsYou) map.set(item.id, item);
    for (const item of secs.ready) map.set(item.id, item);
    for (const item of secs.working) map.set(item.id, item);
    return map;
  });

  const refreshedTranscriptAt = new Map<string, number>();

  const matchesViewMode = (item: InboxItem, mode = viewMode()): boolean => {
    if (peekedIds().has(item.id)) return true;
    if (mode === "unread") return item.unread || seenUnreadIds().has(item.id);
    if (mode === "attention") return item.attention;
    return true;
  };

  const modeFilteredNeedsYou = createMemo(() => {
    const secs = allSections();
    const peekedWorking = secs.working.filter(
      (item) =>
        peekedIds().has(item.id) &&
        (peekedSectionById.get(item.id) ?? "needs_you") === "needs_you",
    );
    return [...secs.needsYou, ...peekedWorking].filter((item) => matchesViewMode(item));
  });

  const modeFilteredReady = createMemo(() => {
    const secs = allSections();
    const peekedWorking = secs.working.filter(
      (item) => peekedIds().has(item.id) && peekedSectionById.get(item.id) === "ready",
    );
    return [...secs.ready, ...peekedWorking].filter((item) => matchesViewMode(item));
  });

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

  const sameIdList = (a: ReadonlyArray<string>, b: ReadonlyArray<string>) =>
    a.length === b.length && a.every((v, i) => v === b[i]);

  const filteredNeedsYouIds = createMemo<string[]>(
    () => filteredNeedsYou().map((item) => item.id),
    [],
    { equals: sameIdList },
  );

  const filteredReadyIds = createMemo<string[]>(
    () => filteredReady().map((item) => item.id),
    [],
    { equals: sameIdList },
  );

  const workingIds = createMemo<string[]>(
    () =>
      allSections()
        .working.filter((item) => !peekedIds().has(item.id))
        .map((item) => item.id),
    [],
    { equals: sameIdList },
  );

  const actionableItems = createMemo(() => [...filteredNeedsYou(), ...filteredReady()]);

  // Load or refresh transcripts for top actionable items so their summary and AI digest reflect the latest turn immediately.
  // Always prioritize currently visible items in the active filter tab so off-screen 'All' items never starve top 'Unread' rows.
  createEffect(() => {
    if (!isConnected()) return;
    const cfg = inboxConfig();
    const visible = actionableItems();
    const visibleIds = new Set(visible.map((item) => item.id));
    const { needsYou, ready } = allSections();
    const background = [...needsYou, ...ready].filter((item) => !visibleIds.has(item.id));
    const candidates = [...visible, ...background].slice(0, 14);
    candidates.forEach((item, idx) => {
      const isVisible = visibleIds.has(item.id);
      const priority = (isVisible ? 0 : 20) + idx;
      const prevMs = refreshedTranscriptAt.get(item.id);
      const readyTx = peekReadyTranscript(item.id);
      if (!readyTx) {
        refreshedTranscriptAt.set(item.id, item.updatedMs);
        if (idx < 12) {
          void loadTranscript(item.id)
            .then((snap) => {
              if (cfg.aiSummary && idx < 12 && !item.interaction) {
                requestInboxDigest(item.mission, snap.items, item.updatedMs, priority);
              }
            })
            .catch(() => {
              if (cfg.aiSummary && idx < 12 && !item.interaction) {
                requestInboxDigest(item.mission, undefined, item.updatedMs, priority);
              }
            });
          return;
        }
        prefetchTranscript(item.id);
      } else if (prevMs === undefined || item.updatedMs > prevMs) {
        refreshedTranscriptAt.set(item.id, item.updatedMs);
        void refreshTranscript(item.id)
          .then((snap) => {
            if (cfg.aiSummary && idx < 12 && !item.interaction) {
              requestInboxDigest(item.mission, snap.items, item.updatedMs, priority);
            }
          })
          .catch(() => {});
        return;
      }
      if (cfg.aiSummary && idx < 12 && !item.interaction) {
        requestInboxDigest(item.mission, readyTx?.items, item.updatedMs, priority);
      }
    });
  });

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
    markMissionRead(item.mission, true, Boolean(item.interaction));
    if (item.childSummary?.failedChildren.length) {
      markMissionsRead(item.childSummary.failedChildren.map((c) => c.mission));
    }
  };

  const toggleReadState = (item: InboxItem) => {
    if (item.unread) {
      markItemAndChildrenRead(item);
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

  const focusReplyInput = (id: string) => {
    queueMicrotask(() => {
      const input = listContainerRef?.querySelector<HTMLInputElement | HTMLTextAreaElement>(
        `[data-inbox-id="${CSS.escape(id)}"] .inbox-peek-composer textarea, [data-inbox-id="${CSS.escape(id)}"] .inbox-reply-input`,
      );
      input?.focus();
    });
  };

  const openUnifiedDrawer = (item: InboxItem, opts?: { focusInput?: boolean; toggle?: boolean }) => {
    setFocusedId(item.id);
    if (item.category === "needs_you" || item.category === "ready") {
      peekedSectionById.set(item.id, item.category);
    }
    const isCurrentlyOpen = peekedIds().has(item.id);
    if (isCurrentlyOpen && opts?.toggle) {
      if (opts.focusInput && replyingId() !== item.id) {
        setReplyingId(item.id);
        focusReplyInput(item.id);
        return;
      }
      setPeekedIds((prev) => {
        const next = new Set(prev);
        next.delete(item.id);
        return next;
      });
      if (replyingId() === item.id) {
        setReplyingId(null);
      }
      return;
    }

    if (!isCurrentlyOpen) {
      setPeekedIds((prev) => {
        const next = new Set(prev);
        next.add(item.id);
        return next;
      });
      if (!peekReadyTranscript(item.id)) {
        void loadTranscript(item.id).catch(() => {});
      } else {
        void refreshTranscript(item.id).catch(() => {});
      }
    }

    if (opts?.focusInput) {
      setReplyingId(item.id);
      focusReplyInput(item.id);
    }
  };

  const closeUnifiedDrawer = (id: string) => {
    const restoreFocus = document.activeElement?.closest(`[data-inbox-id="${CSS.escape(id)}"]`);
    setPeekedIds((prev) => {
      if (!prev.has(id)) return prev;
      const next = new Set(prev);
      next.delete(id);
      return next;
    });
    if (replyingId() === id) {
      setReplyingId(null);
    }
    if (restoreFocus) focusRow(id, false);
  };

  const togglePeek = (item: InboxItem) => {
    openUnifiedDrawer(item, { toggle: true, focusInput: false });
  };

  const openQuickReply = (item: InboxItem) => {
    if (peekedIds().has(item.id) && replyingId() === item.id) {
      closeUnifiedDrawer(item.id);
      return;
    }
    openUnifiedDrawer(item, { toggle: false, focusInput: true });
  };

  const [liveEventsByMission, setLiveEventsByMission] = createSignal<
    Record<string, StreamEvent[]>
  >({});

  const pushMissionLiveEvent = (missionId: string, ev: StreamEvent) => {
    setLiveEventsByMission((prev) => ({
      ...prev,
      [missionId]: [...(prev[missionId] ?? []), ev],
    }));
  };

  const appendUserEventToTranscript = (
    missionId: string,
    messageId: string,
    content: string,
    queued: boolean,
    attached: boolean,
  ) => {
    const ev: StreamEvent = {
      type: "user_message",
      eventId: messageId,
      data: {
        id: messageId,
        content,
        queued,
        receipt: true,
        attached,
      },
    };
    pushMissionLiveEvent(missionId, ev);
    const snap = peekReadyTranscript(missionId) ?? peekTranscript(missionId);
    const baseItems = snap?.items ?? [];
    const nextItems = applyStreamEvent(baseItems, ev);
    if (snap) {
      putTranscript(missionId, {
        ...snap,
        items: nextItems,
        stream: [...snap.stream, ev],
      });
    } else {
      putTranscript(missionId, {
        items: nextItems,
        stream: [ev],
        fromLog: true,
      });
    }
  };

  const retryMission = async (item: InboxItem) => {
    if (busyIds().has(item.id)) return;
    setError(null);
    addBusy(item.id);
    markItemAndChildrenRead(item);
    try {
      const msgId = crypto.randomUUID();
      const result = await sendMissionMessage(
        item.id,
        "Continue from where you left off.",
        [],
        msgId,
      );
      if (result.replacement) {
        p.onMissionUpdated?.(result.replacement);
      }
      if (peekedIds().has(item.id)) {
        appendUserEventToTranscript(
          item.id,
          result.id || msgId,
          "Continue from where you left off.",
          Boolean(result.queued),
          false,
        );
        p.onMissionUpdated?.({ ...item.mission, status: "running" });
        void refreshTranscript(item.id).catch(() => {});
        void p.onRefresh();
        return;
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
    setSeenUnreadIds((prev) => {
      if (!prev.has(item.id)) return prev;
      const next = new Set(prev);
      next.delete(item.id);
      return next;
    });
    closeUnifiedDrawer(item.id);
    setFocusedId(nextFocus);
    if (nextFocus) focusRow(nextFocus);
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

  const submitUnifiedReply = async (
    item: InboxItem,
    rawText: string,
    images: DraftImage[] = [],
    chips: AttachChip[] = [],
  ): Promise<boolean> => {
    const text = rawText.trim();
    if ((!text && !images.length) || busyIds().has(item.id)) return false;
    setError(null);
    addBusy(item.id);
    if (item.category === "needs_you" || item.category === "ready") {
      peekedSectionById.set(item.id, item.category);
    }
    markItemAndChildrenRead(item);
    try {
      const mission = item.mission;
      const clientPlaced = Boolean(mission.tags?.includes("placement:client"));
      const msgId = crypto.randomUUID();
      if (clientPlaced) {
        const sendVersion = connectionVersion();
        await refreshLocalBindings().catch(() => {});
        const binding = localBinding(item.id);
        if (!binding) {
          throw new Error("This session runs on the computer that started it. Your draft is kept.");
        }
        const project = mission.project;
        if (!project) {
          throw new Error("This mission has no project, so its files cannot be copied. Your draft is kept.");
        }
        const plan = await materializeMentions(project, text, chips);
        await prepareProjectSkills(project, binding.cwd, binding.harness, binding.bin);
        if (plan.files.length) await writeLocalFiles(binding.cwd, plan.files);
        const imagePaths = await stageLocalImages(binding.cwd, images);
        const sent = imagePrompt(bindWorkspace(plan.prompt, binding.cwd), imagePaths, images);
        if (connectionVersion() !== sendVersion) {
          throw new Error("Connection changed. Your draft is kept.");
        }
        const displaySent = imagePrompt(text, imagePaths, images);
        await enqueueLocalMessage(
          {
            id: item.id,
            harness: binding.harness,
            bin: binding.bin,
            cwd: binding.cwd,
            prompt: sent,
            model: mission.model_override ?? binding.model,
            imagePaths,
          },
          displaySent,
          { id: msgId, replace: false, waiting: false },
        );
        appendUserEventToTranscript(item.id, msgId, displaySent, false, chips.length > 0);
      } else {
        const attachments = chips.map(chipToAttachment);
        const sent = imagePrompt(text, await stageRemoteImages(images, mission), images);
        const result = await sendMissionMessage(item.id, sent, attachments, msgId);
        if (result.replacement) {
          p.onMissionUpdated?.(result.replacement);
        } else {
          p.onMissionUpdated?.({ ...mission, status: "running" });
        }
        appendUserEventToTranscript(
          item.id,
          result.id || msgId,
          sent,
          Boolean(result.queued),
          chips.length > 0,
        );
      }
      setPeekReplyDrafts((prev) => {
        const next = { ...prev };
        delete next[item.id];
        return next;
      });
      // Keep the Peek drawer open so the user sees their sent message and the live-streamed reply
      void refreshTranscript(item.id).catch(() => {});
      void p.onRefresh();
      return true;
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
      return false;
    } finally {
      removeBusy(item.id);
    }
  };

  const triggerOption = async (item: InboxItem, option: InboxOption) => {
    const interaction = item.interaction;
    if (!interaction || busyIds().has(item.id)) return;
    setError(null);
    addBusy(item.id);
    markItemAndChildrenRead(item);
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

  const focusRow = (id: string, scroll = true) => {
    setFocusedId(id);
    queueMicrotask(() => {
      const row = listContainerRef?.querySelector<HTMLElement>(`[data-inbox-id="${CSS.escape(id)}"]`);
      // Move native focus as well as the highlight so the next Tab stays in this row.
      row?.querySelector<HTMLButtonElement>(".inbox-row-title-btn")?.focus({ preventScroll: true });
      if (scroll) row?.scrollIntoView({ block: "nearest" });
    });
  };

  onMount(() => {
    const onKeyDown = (e: KeyboardEvent) => {
      if (e.defaultPrevented || e.isComposing || hasOverlay()) return;
      const target = e.target as HTMLElement | null;
      if (target?.closest("input, textarea, select, [contenteditable]")) return;
      if (e.metaKey || e.ctrlKey || e.altKey) return;

      const items = actionableItems();
      const currentId = focusedId();
      const currentIdx = items.findIndex((i) => i.id === currentId);
      const currentItem = currentIdx >= 0 ? items[currentIdx] : items[0];

      const inRow = !!target?.closest(".inbox-row");
      const inNavigation = !!target?.closest(".inbox-mode-tabs, .inbox-filters");
      if (e.key === "ArrowDown" || e.key === "ArrowUp" || e.key === "j" || e.key === "k") {
        if (!items.length || (!inRow && !inNavigation && target?.closest("button, summary"))) return;
        e.preventDefault();
        const forward = e.key === "ArrowDown" || e.key === "j";
        const index = inNavigation ? (forward ? 0 : items.length - 1)
          : (currentIdx + (forward ? 1 : items.length - 1)) % items.length;
        focusRow(items[Math.max(0, index)].id);
        return;
      }
      if (inRow && (e.key === "Home" || e.key === "End")) {
        e.preventDefault();
        focusRow(items[e.key === "Home" ? 0 : items.length - 1].id);
        return;
      }
      if (e.key === "Enter" && currentItem) {
        if (target?.closest("button:not(.inbox-row-main):not(.inbox-row-title-btn), summary, a[href]")) return;
        e.preventDefault();
        markItemAndChildrenRead(currentItem);
        p.onOpenMission(currentItem.id);
        return;
      }
      if (e.key === " " && currentItem) {
        if (target?.closest("button:not(.inbox-row-main):not(.inbox-row-title-btn), summary, a[href]")) return;
        e.preventDefault();
        togglePeek(currentItem);
        return;
      }
      if (e.key.toLowerCase() === "t" && !e.shiftKey && currentItem && peekedIds().has(currentItem.id)) {
        e.preventDefault();
        openUnifiedDrawer(currentItem, { focusInput: true, toggle: false });
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
      if (e.key === "Escape") {
        const openId =
          currentItem && peekedIds().has(currentItem.id)
            ? currentItem.id
            : Array.from(peekedIds()).at(-1);
        if (openId) {
          e.preventDefault();
          closeUnifiedDrawer(openId);
          return;
        }
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

  const renderRowById = (id: string) => {
    const item = createMemo(() => itemById().get(id));
    return (
      <Show when={item()}>
        {(currentItem) => {
          const isFocused = () => focusedId() === id;
          const isReplying = () => replyingId() === id;
          const isPeeked = () => peekedIds().has(id);
          const isPeekExpanded = () => expandedPeekIds().has(id);
          const isBusy = () => busyIds().has(id);
          const isMissionRunning = () => {
            const s = currentItem().mission.status;
            return Boolean(
              s && ["active", "running", "pending", "queued", "starting", "resuming"].includes(s),
            );
          };
          const color = () => projectColor(currentItem().projectSlug);
          const digest = createMemo(() => {
            inboxDigestVersion();
            if (!inboxConfig().aiSummary) return undefined;
            return getCachedInboxDigest(id, currentItem().updatedMs);
          });
          const normalizeCmp = (s: string) =>
            s
              .toLowerCase()
              .replace(/[^a-z0-9]+/g, " ")
              .trim();
          const isGenericBoilerplate = (s: string) =>
            /^(execute|complete|continue|run|perform)\s+the\s+.*(mission|goal|objective|task)/i.test(s) ||
            /^mission\s+.*(stopped|completed|finished|blocked)\b/i.test(s) ||
            /no conversation details/i.test(s);

          const effectiveHeadline = createMemo(() => {
            const aiGoal = digest()?.goal?.trim();
            if (aiGoal && !isGenericBoilerplate(aiGoal) && aiGoal.length <= 72) {
              return aiGoal;
            }
            return currentItem().headline;
          });

          const taskLine = createMemo(() => {
            const aiTask = digest()?.task?.trim();
            if (aiTask && !isGenericBoilerplate(aiTask) && !isSyntheticUserMessage(aiTask)) return aiTask;
            return currentItem().lastRequest?.trim();
          });

          const outcomeLine = createMemo(() => {
            const aiOutcome = digest()?.outcome?.trim();
            if (aiOutcome && !isGenericBoilerplate(aiOutcome)) return aiOutcome;
            return currentItem().summary;
          });

          const goalContextLine = createMemo(() => {
            const aiGoal = digest()?.goal?.trim();
            const rawGoal = currentItem().goalSummary?.trim();
            // When AI goal becomes the headline, show the underlying goalSummary if it adds context;
            // or if AI goal was too long for headline, show AI goal here.
            const candidate =
              aiGoal && effectiveHeadline() !== aiGoal ? aiGoal : rawGoal;
            if (!candidate || isGenericBoilerplate(candidate)) return undefined;
            const nc = normalizeCmp(candidate);
            const nh = normalizeCmp(effectiveHeadline());
            const no = normalizeCmp(outcomeLine());
            if (!nc || nc === nh || nc === no) return undefined;
            if (nh.length >= 16 && (nc.startsWith(nh.slice(0, 16)) || nh.startsWith(nc.slice(0, 16)))) {
              return undefined;
            }
            return candidate;
          });

          const showTaskLine = createMemo(() => {
            if (currentItem().interaction) return false;
            const t = taskLine();
            if (!t || isSyntheticUserMessage(t)) return false;
            const nt = normalizeCmp(t);
            const nh = normalizeCmp(effectiveHeadline());
            const ng = normalizeCmp(goalContextLine() ?? "");
            const no = normalizeCmp(outcomeLine());
            if (!nt || nt === nh || nt === ng || nt === no) return false;
            if (nh.length >= 18 && (nt.startsWith(nh.slice(0, 18)) || nh.startsWith(nt.slice(0, 18)))) {
              return false;
            }
            return true;
          });

          const appendLiveEvent = (ev: StreamEvent) => {
            pushMissionLiveEvent(id, ev);
            const snap = peekReadyTranscript(id) ?? peekTranscript(id);
            const curItems = snap?.items ?? [];
            const nextItems = applyStreamEvent(curItems, ev);
            if (nextItems !== curItems) {
              if (snap) {
                putTranscript(id, { ...snap, items: nextItems });
              } else {
                putTranscriptItems(id, nextItems);
              }
            }
          };

          const rawTranscriptItems = createMemo<StreamItem[] | undefined>(
            () => {
              transcriptVersion();
              return (peekReadyTranscript(id) ?? peekTranscript(id))?.items;
            },
            undefined,
            { equals: (a, b) => a === b },
          );

          // Live SSE stream while Peek drawer is open so user replies and agent turns stream in real time
          createEffect(() => {
            if (!isPeeked() || !isConnected()) return;
            const release = retainTranscript(id);
            const stopStream = streamMission(
              id,
              (ev) => {
                if (ev.type === "mission_status_changed" || ev.type === "status") {
                  if (ev.type === "mission_status_changed" && typeof ev.data.status === "string") {
                    const nextStatus = ev.data.status;
                    const curM = untrack(() => currentItem().mission);
                    p.onMissionUpdated?.({
                      ...curM,
                      status: nextStatus,
                      status_message:
                        typeof ev.data.summary === "string"
                          ? ev.data.summary
                          : curM.status_message,
                    });
                  }
                  void refreshTranscript(id).catch(() => {});
                  void p.onRefresh();
                  return;
                }
                appendLiveEvent(ev);
              },
              () => {
                void refreshTranscript(id).catch(() => {});
              },
            );
            onCleanup(() => {
              stopStream();
              release();
            });
          });

          const missionScopeKey = createMemo(() =>
            fileScopeKey({ mission: currentItem().mission }),
          );

          const stableMission = createMemo(() => {
            missionScopeKey();
            return untrack(() => currentItem().mission);
          });

          const missionPeekKey = createMemo(() => {
            const m = currentItem().mission;
            const hLen = Array.isArray(m.history) ? m.history.length : 0;
            const lastH = hLen > 0 ? m.history![hLen - 1]?.content ?? "" : "";
            return [
              m.id,
              m.status ?? "",
              m.terminal_reason ?? "",
              m.status_message ?? "",
              m.remote_job?.error ?? "",
              m.goal_objective ?? "",
              m.title ?? "",
              hLen,
              lastH.slice(-120),
            ].join("\u0000");
          });

          const peekStream = createMemo(() => {
            missionPeekKey();
            const txItems = rawTranscriptItems();
            const liveEvs = liveEventsByMission()[id];
            const expanded = isPeekExpanded();
            const it = untrack(() => currentItem());
            return buildPeekStreamItems(
              it.mission,
              txItems,
              it.summary,
              expanded,
              6,
              liveEvs,
            );
          });

          const hiddenPeekCount = createMemo(() => peekStream().hiddenTurnCount);

          let peekScrollEl: HTMLDivElement | undefined;
          let nearBottom = true;

          const [composerRevision, setComposerRevision] = createSignal<{
            text: string;
            append?: boolean;
          }>();
          const [followAttach, setFollowAttach] = createSignal<AttachChip[]>([]);

          const appendToReplyDraft = (snippet: string) => {
            setComposerRevision({ text: snippet, append: true });
            setReplyingId(id);
            focusReplyInput(id);
          };

          const uploadTarget = createMemo(() => {
            const m = currentItem().mission;
            if (m.tags?.includes("placement:client")) return "local";
            return m.remote_node_id ?? m.remote_job?.node_id ?? "core";
          });
          const stableProjectSlug = createMemo(() => currentItem().mission.project ?? undefined);
          const stableBackend = createMemo(() => currentItem().mission.backend);

          return (
            <article
              class={`inbox-row ${currentItem().unread ? "unread" : "read"} ${isFocused() ? "focused" : ""} ${isPeeked() ? "peeked" : ""} ${isBusy() ? "busy" : ""}`}
              data-inbox-id={id}
              data-inbox-tone={currentItem().tone}
              data-inbox-unread={currentItem().unread ? "true" : "false"}
              aria-busy={isBusy()}
              onFocusIn={() => setFocusedId(id)}
              onMouseEnter={() => {
                if (
                  !replyingId() ||
                  (!document.activeElement?.closest(".inbox-peek-composer") &&
                    !document.activeElement?.classList.contains("inbox-reply-input"))
                ) {
                  setFocusedId(id);
                }
              }}
            >
              <div class="inbox-row-body">
                <div class="inbox-row-main-col">
                  <div class="inbox-row-top">
                    <button
                      type="button"
                      class="inbox-row-title-btn"
                      tabIndex={isFocused() ? 0 : -1}
                      aria-keyshortcuts="ArrowDown ArrowUp Home End Space r t"
                      title={currentItem().mission.title || effectiveHeadline()}
                      onClick={() => {
                        const it = currentItem();
                        markItemAndChildrenRead(it);
                        p.onOpenMission(it.id);
                      }}
                    >
                      <span class="inbox-project-pill">
                        <i
                          class="inbox-project-dot"
                          style={color() ? { background: color() } : undefined}
                          aria-hidden="true"
                        />
                        <span class="inbox-project-name">{currentItem().projectTitle}</span>
                      </span>
                      <span class="inbox-sep" aria-hidden="true">·</span>
                      <span class="inbox-headline">{effectiveHeadline()}</span>
                      <Show when={currentItem().badge !== "Completed"}>
                        <span class={`inbox-badge ${currentItem().tone}`}>{currentItem().badge}</span>
                      </Show>
                    </button>

                    <div class="inbox-row-right">
                      <div class="inbox-row-meta">
                        <Show when={currentItem().machine}>
                          <span class="inbox-machine">{currentItem().machine}</span>
                        </Show>
                        <Show when={currentItem().relativeTime}>
                          <time class="inbox-time">{currentItem().relativeTime}</time>
                        </Show>
                      </div>

                      <div class="inbox-triage-btns">
                        <Show when={currentItem().canRetry}>
                          <button
                            type="button"
                            class="inbox-act-btn retry"
                            tabIndex={isFocused() ? 0 : -1}
                            disabled={isBusy()}
                            title="Retry / resume mission (⇧R)"
                            aria-label={`Retry ${effectiveHeadline()}`}
                            onClick={(e) => {
                              e.stopPropagation();
                              void retryMission(currentItem());
                            }}
                          >
                            <span aria-hidden="true">↻</span>
                            <span>Retry</span>
                            <kbd class="inbox-act-kbd" aria-hidden="true">⇧R</kbd>
                          </button>
                        </Show>
                        <button
                          type="button"
                          class={`inbox-act-btn ${isPeeked() ? "on" : ""}`}
                          tabIndex={isFocused() ? 0 : -1}
                          disabled={isBusy()}
                          title={isPeeked() ? "Close peek (Esc or Space)" : "Peek conversation & reply inline (Space)"}
                          aria-label={`Peek and reply to ${effectiveHeadline()}`}
                          aria-expanded={isPeeked()}
                          aria-controls={`${viewId}-peek-${id}`}
                          onClick={(e) => {
                            e.stopPropagation();
                            if (isPeeked()) {
                              closeUnifiedDrawer(id);
                            } else {
                              openUnifiedDrawer(currentItem(), { focusInput: true });
                            }
                          }}
                        >
                          <span>{isPeeked() ? "Close" : "Peek & Reply"}</span>
                          <kbd class="inbox-act-kbd" aria-hidden="true">{isPeeked() ? "Esc" : "Space"}</kbd>
                        </button>
                        <button
                          type="button"
                          class="inbox-act-btn done"
                          tabIndex={isFocused() ? 0 : -1}
                          disabled={isBusy()}
                          title="Archive & mark done (E)"
                          aria-label={`Mark ${effectiveHeadline()} done`}
                          onClick={(e) => {
                            e.stopPropagation();
                            void markDone(currentItem());
                          }}
                        >
                          <Ic.CheckIcon size={12} />
                          <span>Done</span>
                          <kbd class="inbox-act-kbd" aria-hidden="true">E</kbd>
                        </button>
                      </div>
                    </div>
                  </div>

                  <button
                    type="button"
                    class="inbox-row-main"
                    tabIndex={-1}
                    onClick={() => {
                      const it = currentItem();
                      markItemAndChildrenRead(it);
                      p.onOpenMission(it.id);
                    }}
                    aria-label={`${currentItem().unread ? "Unread. " : ""}${currentItem().projectTitle}: ${effectiveHeadline()}. ${currentItem().badge}. ${outcomeLine()}`}
                  >
                    <div class="inbox-row-bottom">
                      <p
                        class="inbox-summary"
                        title={
                          digest()?.aiGenerated
                            ? `AI Overview (${digest()?.model || inboxConfig().model})`
                            : undefined
                        }
                      >
                        <For each={outcomeLine().split(/(`[^`]+`|\*\*[^*]+\*\*)/g)}>
                          {(part) =>
                            part.startsWith("`") && part.endsWith("`") && part.length > 2 ? (
                              <code class="inbox-inline-code">{part.slice(1, -1)}</code>
                            ) : part.startsWith("**") && part.endsWith("**") && part.length > 4 ? (
                              <strong>{part.slice(2, -2)}</strong>
                            ) : (
                              part
                            )
                          }
                        </For>
                        <Show when={!currentItem().interaction && currentItem().workReceiptSummary}>
                          <span class="inbox-work-chip" title="Tools executed in the latest turn">
                            {" "}· {currentItem().workReceiptSummary}
                          </span>
                        </Show>
                      </p>
                    </div>
                  </button>

                  <Show
                    when={
                      currentItem().childSummary &&
                      (currentItem().childSummary!.failedChildren.length > 0 ||
                        currentItem().childSummary!.running > 0)
                    }
                  >
                    {(() => {
                      const cs = () => currentItem().childSummary!;
                      const firstFailed = () => cs().failedChildren[0];
                      return (
                        <div class="inbox-child-bar">
                          <Show when={firstFailed()}>
                            <button
                              type="button"
                              class="inbox-child-pill failed"
                              title={`Open failed child track: ${firstFailed()!.title}`}
                              onClick={(e) => {
                                e.stopPropagation();
                                markItemAndChildrenRead(currentItem());
                                p.onOpenMission(firstFailed()!.id);
                              }}
                            >
                              <span class="inbox-child-dot" aria-hidden="true" />
                              <span>
                                {cs().failed} {cs().failed === 1 ? "track" : "tracks"} failed: {firstFailed()!.title}
                              </span>
                              <span aria-hidden="true">→</span>
                            </button>
                          </Show>
                          <Show when={cs().running > 0}>
                            <span class="inbox-child-pill running" title="Active child worker tracks">
                              <span class="inbox-child-dot" aria-hidden="true" />
                              <span>
                                {cs().running} {cs().running === 1 ? "track" : "tracks"} running
                              </span>
                            </span>
                          </Show>
                        </div>
                      );
                    })()}
                  </Show>
                </div>

                <Show when={currentItem().interaction?.options.length}>
                  <div class="inbox-row-actions">
                    <div class="inbox-options" role="group" aria-label="Quick choices">
                      <For each={currentItem().interaction!.options}>
                        {(opt, idx) => (
                          <button
                            type="button"
                            class={`inbox-opt-btn ${idx() === 0 ? "primary" : ""}`}
                            disabled={isBusy()}
                            title={opt.description || `${opt.label} (${opt.key})`}
                            onClick={(e) => {
                              e.stopPropagation();
                              void triggerOption(currentItem(), opt);
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
              </div>

              <Show when={currentItem().interaction?.detail && currentItem().interaction!.kind === "permission"}>
                <pre class="inbox-perm-code">{currentItem().interaction!.detail}</pre>
              </Show>

              <Show when={isPeeked()}>
                <div id={`${viewId}-peek-${id}`} class="inbox-peek-drawer" role="region" aria-label={`Recent turns for ${effectiveHeadline()}`}>
                  <details class="inbox-peek-status-card">
                    <summary class="inbox-peek-status-label">Reply context <Ic.ChevronDown /></summary>
                    <div class="inbox-peek-status-top">
                      <div class="inbox-peek-status-chips">
                        <button
                          type="button"
                          class="inbox-context-chip"
                          title="Insert current status summary into your reply"
                          onClick={(e) => {
                            e.stopPropagation();
                            appendToReplyDraft(`Regarding status ("${outcomeLine()}"): `);
                          }}
                        >
                          Quote status
                        </button>
                        <Show when={currentItem().canRetry || currentItem().mission.status === "blocked"}>
                          <button
                            type="button"
                            class="inbox-context-chip"
                            onClick={(e) => {
                              e.stopPropagation();
                              appendToReplyDraft("Resume the goal and resolve the remaining blockers.");
                            }}
                          >
                            Resume & unblock
                          </button>
                        </Show>
                        <button
                          type="button"
                          class="inbox-context-chip"
                          onClick={(e) => {
                            e.stopPropagation();
                            appendToReplyDraft("Summarize the remaining work and open a PR when checks pass.");
                          }}
                        >
                          Ask for next steps
                        </button>
                      </div>
                    </div>
                    <Show when={showTaskLine()}>
                      <p class="inbox-task-row"><span class="inbox-digest-label">Asked</span><span class="inbox-task-text">{taskLine()}</span></p>
                    </Show>
                    <p class="inbox-peek-status-text">
                      <strong>Goal:</strong>{" "}
                      {goalContextLine() ||
                        currentItem().mission.goal_objective ||
                        effectiveHeadline()}
                      <Show when={outcomeLine()}>
                        <span class="inbox-peek-status-sub"> — {outcomeLine()}</span>
                      </Show>
                    </p>
                  </details>

                  <div class="inbox-peek-head">
                    <div class="inbox-peek-head-left">
                      <span class="inbox-peek-caption">Conversation</span>
                      <Show when={isMissionRunning()}>
                        <span class="inbox-peek-live-pill" role="status">
                          <Ic.RunningDots />
                          <span>Streaming</span>
                        </span>
                      </Show>
                      <Show when={hiddenPeekCount() > 0}>
                        <button
                          type="button"
                          class="inbox-peek-more-btn"
                          onClick={(e) => {
                            e.stopPropagation();
                            const scroller = peekScrollEl;
                            const prevHeight = scroller?.scrollHeight ?? 0;
                            const prevTop = scroller?.scrollTop ?? 0;
                            nearBottom = false;
                            setExpandedPeekIds((prev) => {
                              const next = new Set(prev);
                              next.add(id);
                              return next;
                            });
                            if (scroller) {
                              queueMicrotask(() => {
                                const delta = scroller.scrollHeight - prevHeight;
                                if (delta > 0 && prevTop > 0) {
                                  scroller.scrollTop = prevTop + delta;
                                }
                              });
                            }
                          }}
                        >
                          Show {hiddenPeekCount()} earlier {hiddenPeekCount() === 1 ? "turn" : "turns"}
                        </button>
                      </Show>
                    </div>
                    <button
                      type="button"
                      class="inbox-peek-open"
                      onClick={() => {
                        const it = currentItem();
                        markItemAndChildrenRead(it);
                        p.onOpenMission(it.id);
                      }}
                    >
                      <span>Open thread</span>
                      <span aria-hidden="true">↗</span>
                      <kbd class="inbox-act-kbd" aria-hidden="true">↵</kbd>
                    </button>
                  </div>

                  <div
                    class="inbox-peek-scroll"
                    data-find-conversation
                    onScroll={(e) => {
                      const el = e.currentTarget;
                      nearBottom = el.scrollHeight - el.scrollTop - el.clientHeight < 64;
                    }}
                    ref={(el) => {
                      peekScrollEl = el;
                      nearBottom = true;
                      const scrollToBottomIfPinned = () => {
                        if (nearBottom && el.isConnected) {
                          el.scrollTop = el.scrollHeight;
                        }
                      };
                      scrollToBottomIfPinned();
                      queueMicrotask(scrollToBottomIfPinned);
                      requestAnimationFrame(scrollToBottomIfPinned);
                      const content = el.querySelector(".inbox-peek-transcript");
                      if (content && typeof ResizeObserver !== "undefined") {
                        const ro = new ResizeObserver(() => {
                          scrollToBottomIfPinned();
                        });
                        ro.observe(content);
                        onCleanup(() => ro.disconnect());
                      }
                    }}
                  >
                    <div class="inbox-peek-transcript">
                      <MissionFileScope
                        mission={stableMission()}
                        onOpenMission={(mid) => {
                          markItemAndChildrenRead(currentItem());
                          p.onOpenMission(mid);
                        }}
                      >
                        <Transcript items={peekStream().items} />
                      </MissionFileScope>
                    </div>
                  </div>

                  <div
                    class="inbox-peek-composer"
                    onFocusIn={() => setReplyingId(id)}
                    onKeyDown={(e) => {
                      if (e.key === "Escape" && !e.defaultPrevented) {
                        e.preventDefault();
                        e.stopPropagation();
                        closeUnifiedDrawer(id);
                      }
                    }}
                  >
                    <Composer
                      placeholder="Send follow-up"
                      picker={false}
                      busy={isBusy() || isMissionRunning()}
                      disabled={isBusy()}
                      autofocus={isReplying()}
                      revision={composerRevision()}
                      scope={`m:${id}`}
                      uploadTarget={uploadTarget()}
                      backend={stableBackend()}
                      projectSlug={stableProjectSlug()}
                      onAttachments={setFollowAttach}
                      onDraft={(text) =>
                        setPeekReplyDrafts((prev) =>
                          prev[id] === text ? prev : { ...prev, [id]: text },
                        )
                      }
                      onStop={() => {
                        void cancelMission(id)
                          .then(() => {
                            void refreshTranscript(id).catch(() => {});
                            void p.onRefresh();
                          })
                          .catch((err) => setError(err instanceof Error ? err.message : String(err)));
                      }}
                      onSendError={(err) => setError(err)}
                      onSend={async (text, images) => {
                        nearBottom = true;
                        const ok = await submitUnifiedReply(
                          currentItem(),
                          text,
                          images,
                          followAttach(),
                        );
                        if (ok && peekScrollEl) {
                          queueMicrotask(() => {
                            if (peekScrollEl) peekScrollEl.scrollTop = peekScrollEl.scrollHeight;
                          });
                        }
                        return ok;
                      }}
                    />
                  </div>
                </div>
              </Show>
            </article>
          );
        }}
      </Show>
    );
  };
  return (
    <div class="page inbox-page" ref={listContainerRef}>
      <div class="page-head inbox-head">
        <div class="inbox-title-group">
          <h2>Inbox</h2>
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
          <button
            type="button"
            class="inbox-model-pill"
            title={
              inboxConfig().aiSummary
                ? `Inbox AI summaries: ${inboxConfig().model} (Click to configure)`
                : "Inbox AI summaries off (Click to configure)"
            }
            aria-label={`Inbox settings (${inboxConfig().aiSummary ? `AI · ${inboxConfig().model}` : "AI summary off"})`}
            onClick={() => (p.onOpenInboxSettings ?? p.onOpenSettings)()}
          >
            <Ic.GearIcon size={13} />
          </button>
        </div>
      </div>

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
            <p>Connect to your Orb backend to triage active and completed agents.</p>
            <button type="button" class="s-btn primary" onClick={p.onOpenSettings}>
              Connect backend
            </button>
          </div>
        }
      >
        <div class="inbox-toolbar">
          <div class="inbox-mode-tabs" role="tablist" aria-label="Inbox filter"
            onKeyDown={(e) => {
              if (e.isComposing || !["ArrowLeft", "ArrowRight", "Home", "End"].includes(e.key)) return;
              e.preventDefault();
              e.stopPropagation();
              const modes: InboxViewMode[] = ["unread", "attention", "all"];
              const index = modes.indexOf(viewMode());
              const next = e.key === "Home" ? 0 : e.key === "End" ? 2 : (index + (e.key === "ArrowRight" ? 1 : 2)) % 3;
              switchViewMode(modes[next]);
              e.currentTarget.querySelector<HTMLButtonElement>(`[data-inbox-filter="${modes[next]}"]`)?.focus({ preventScroll: true });
            }}>
            <button
              type="button"
              role="tab"
              data-inbox-filter="unread"
              id={`${viewId}-unread`}
              aria-controls={`${viewId}-results`}
              tabIndex={viewMode() === "unread" ? 0 : -1}
              aria-selected={viewMode() === "unread"}
              class={`inbox-mode-tab ${viewMode() === "unread" ? "on" : ""}`}
              onClick={() => switchViewMode("unread")}
            >
              <span class="inbox-unread-dot" aria-hidden="true" />
              <span>Unread</span>
              <span class="inbox-filter-count">{allSections().unreadCount}</span>
            </button>
            <button
              type="button"
              role="tab"
              data-inbox-filter="attention"
              id={`${viewId}-attention`}
              aria-controls={`${viewId}-results`}
              tabIndex={viewMode() === "attention" ? 0 : -1}
              aria-selected={viewMode() === "attention"}
              class={`inbox-mode-tab ${viewMode() === "attention" ? "on" : ""}`}
              onClick={() => switchViewMode("attention")}
            >
              <span>Needs attention</span>
              <span class="inbox-filter-count">{allSections().attentionCount}</span>
            </button>
            <button
              type="button"
              role="tab"
              data-inbox-filter="all"
              id={`${viewId}-all`}
              aria-controls={`${viewId}-results`}
              tabIndex={viewMode() === "all" ? 0 : -1}
              aria-selected={viewMode() === "all"}
              class={`inbox-mode-tab ${viewMode() === "all" ? "on" : ""}`}
              onClick={() => switchViewMode("all")}
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
              aria-pressed={projectFilter() === null}
              onClick={() => setProjectFilter(null)}
            >
              All projects
            </button>
            <For each={availableProjects()}>
              {(proj) => (
                <button
                  type="button"
                  class={`inbox-filter-chip ${projectFilter() === proj.slug ? "on" : ""}`}
                  aria-pressed={projectFilter() === proj.slug}
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

        <div id={`${viewId}-results`} role="tabpanel" aria-labelledby={`${viewId}-${viewMode()}`} aria-busy={p.loading || undefined}>
        <Show when={showWorking() && workingIds().length > 0}>
          <section class="inbox-sec working-sec" aria-label="Working quietly">
            <div class="inbox-sec-head">
              <h3>Working quietly</h3>
              <span class="inbox-sec-note">Hidden from triage until they finish or ask</span>
            </div>
            <div class="inbox-working-list">
              <For each={workingIds()}>
                {(id) => {
                  const wItem = () => itemById().get(id);
                  return (
                    <Show when={wItem()}>
                      {(item) => (
                        <button
                          type="button"
                          class="inbox-working-row"
                          onClick={() => p.onOpenMission(item().id)}
                        >
                          <Ic.RunningDots />
                          <span class="inbox-project-pill">
                            <i
                              class="inbox-project-dot"
                              style={
                                projectColor(item().projectSlug)
                                  ? { background: projectColor(item().projectSlug) }
                                  : undefined
                              }
                              aria-hidden="true"
                            />
                            <span class="inbox-project-name">{item().projectTitle}</span>
                          </span>
                          <span class="inbox-sep" aria-hidden="true">·</span>
                          <span class="inbox-headline">{item().headline}</span>
                          <Show when={item().machine}>
                            <span class="inbox-machine">{item().machine}</span>
                          </Show>
                          <Show when={item().relativeTime}>
                            <time class="inbox-time">{item().relativeTime}</time>
                          </Show>
                        </button>
                      )}
                    </Show>
                  );
                }}
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
                      onClick={() => switchViewMode("all")}
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
                    New agent
                  </button>
                </div>
              </div>
            }
          >
            <Show when={filteredNeedsYouIds().length > 0}>
              <section class="inbox-sec" aria-label="Needs you">
                <div class="inbox-sec-head">
                  <h3>Needs you</h3>
                  <span class="inbox-sec-count">{filteredNeedsYouIds().length}</span>
                </div>
                <div class="inbox-list">
                  <For each={filteredNeedsYouIds()}>{(id) => renderRowById(id)}</For>
                </div>
              </section>
            </Show>

            <Show when={filteredReadyIds().length > 0}>
              <section class="inbox-sec" aria-label="Ready for review">
                <div class="inbox-sec-head">
                  <h3>Ready for review</h3>
                  <span class="inbox-sec-count">{filteredReadyIds().length}</span>
                  <Show when={filteredReadyIds().length > 1}>
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
                  <For each={filteredReadyIds()}>{(id) => renderRowById(id)}</For>
                </div>
              </section>
            </Show>
          </Show>
        </Show>
        </div>
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
