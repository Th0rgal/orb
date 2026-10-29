import {
  For,
  Show,
  Switch,
  Match,
  createEffect,
  createMemo,
  createSignal,
  createUniqueId,
  on,
  onCleanup,
  onMount,
} from "solid-js";
import { Portal } from "solid-js/web";
import {
  connectionVersion,
  getApiUrl,
  getMissionPassageContext,
  isConnected,
  searchConversationMessages,
  type ConversationSearchHit,
  type ConversationSearchRole,
  type ConversationSearchSort,
  type Mission,
  type PassageContextResponse,
  type ProjectSummary,
  type SearchHighlightRange,
  type SearchIndexCoverage,
} from "./api";
import { displayTitle } from "./goal";
import * as Ic from "./icons";
import { isArchived } from "./missionStatus";
import {
  mountOverlay,
  OverlayContext,
  overlayFirstModal,
  overlayHasModalAbove,
  overlayZIndex,
  useOverlayParent,
  type OverlayLayer,
} from "./overlayLayer";
import { peekReadyTranscript } from "./missionCache";
import { renamedTitle } from "./renames";
import { splitUtf16Highlights } from "./searchTarget";
import "./SearchDialog.css";

type DatePreset = "any" | "7d" | "30d" | "90d";

function sinceIsoForPreset(preset: DatePreset): string | null {
  if (preset === "any") return null;
  const days = preset === "7d" ? 7 : preset === "30d" ? 30 : 90;
  return new Date(Date.now() - days * 86_400_000).toISOString();
}

function formatShortDate(iso: string | undefined | null): string {
  if (!iso) return "";
  const ts = Date.parse(iso);
  if (!Number.isFinite(ts)) return "";
  const now = Date.now();
  const diffMs = now - ts;
  if (diffMs >= 0 && diffMs < 60_000) return "Just now";
  if (diffMs >= 0 && diffMs < 3_600_000) return `${Math.floor(diffMs / 60_000)}m ago`;
  if (diffMs >= 0 && diffMs < 86_400_000) return `${Math.floor(diffMs / 3_600_000)}h ago`;
  const d = new Date(ts);
  const sameYear = d.getFullYear() === new Date(now).getFullYear();
  return d.toLocaleDateString(undefined, sameYear ? { month: "short", day: "numeric" } : { year: "numeric", month: "short", day: "numeric" });
}

function HighlightedText(p: { text: string; highlights?: SearchHighlightRange[] }) {
  const segments = createMemo(() => splitUtf16Highlights(p.text, p.highlights));
  return (
    <For each={segments()}>
      {seg => (seg.match ? <mark class="cs-mark">{seg.text}</mark> : <>{seg.text}</>)}
    </For>
  );
}

export interface SearchDialogProps {
  query: string;
  onQueryChange: (q: string) => void;
  projects: ProjectSummary[];
  recentMissions: Mission[];
  returnFocus?: HTMLElement | null;
  onInputRef?: (el: HTMLInputElement | undefined) => void;
  onClose: () => void;
  onOpenMission: (missionId: string) => void;
  onOpenHit: (hit: ConversationSearchHit, query: string) => void;
}

const DEBOUNCE_MS = 120;
const MAX_PREVIEW_CACHE = 40;

export default function SearchDialog(p: SearchDialogProps) {
  let root!: HTMLDivElement;
  let inputRef: HTMLInputElement | undefined;
  let resultsPaneRef: HTMLDivElement | undefined;
  let composing = false;
  let restoreFocusOnClose = true;

  const titleId = createUniqueId();
  const listboxId = createUniqueId();
  const layer: OverlayLayer = { root: () => root, parent: useOverlayParent(), modal: true };

  const [projectFilter, setProjectFilter] = createSignal<string>("");
  const [roleFilter, setRoleFilter] = createSignal<ConversationSearchRole>("all");
  const [includeTools, setIncludeTools] = createSignal(false);
  const [datePreset, setDatePreset] = createSignal<DatePreset>("any");
  const [sortOrder, setSortOrder] = createSignal<ConversationSearchSort>("relevance");
  const [mobilePane, setMobilePane] = createSignal<"results" | "preview">("results");

  const [rawHits, setRawHits] = createSignal<ConversationSearchHit[]>([]);
  const [coverage, setCoverage] = createSignal<SearchIndexCoverage | null>(null);
  const [nextCursor, setNextCursor] = createSignal<string | null>(null);
  const [loading, setLoading] = createSignal(false);
  const [loadingMore, setLoadingMore] = createSignal(false);
  const [hasLoadedForQuery, setHasLoadedForQuery] = createSignal(false);
  const [error, setError] = createSignal<string | null>(null);
  const [selectedIndex, setSelectedIndex] = createSignal(0);

  const [previewData, setPreviewData] = createSignal<PassageContextResponse | null>(null);
  const [previewLoading, setPreviewLoading] = createSignal(false);
  const [previewError, setPreviewError] = createSignal<string | null>(null);

  const previewCache = new Map<string, PassageContextResponse>();

  const projectTitle = (slug: string | null | undefined): string | null => {
    if (!slug) return null;
    return p.projects.find(pr => pr.slug === slug)?.title || slug;
  };

  const trimmedQuery = createMemo(() => p.query.trim());

  // Recent conversations shown immediately when the query is blank.
  const filteredRecents = createMemo(() => {
    const proj = projectFilter();
    const since = sinceIsoForPreset(datePreset());
    const sinceMs = since ? Date.parse(since) : 0;
    return p.recentMissions
      .filter(m => {
        if (!m?.id) return false;
        if (proj && (m.project ?? "") !== proj) return false;
        if (sinceMs > 0) {
          const ts = Date.parse(m.updated_at || m.created_at || "") || 0;
          if (ts < sinceMs) return false;
        }
        return true;
      })
      .sort((a, b) => {
        const ta = Date.parse(a.updated_at || a.created_at || "") || 0;
        const tb = Date.parse(b.updated_at || b.created_at || "") || 0;
        return tb - ta;
      })
      .slice(0, 30);
  });

  // Group hits by conversation in the order of each conversation's top hit so
  // multi-passage matches stay visually grouped while preserving relevance rank.
  const groupedResults = createMemo(() => {
    type Group = {
      missionId: string;
      title: string;
      project: string | null;
      status: string;
      updatedAt: string;
      totalMatches: number;
      hits: ConversationSearchHit[];
    };
    const groups: Group[] = [];
    const byMission = new Map<string, Group>();
    for (const hit of rawHits()) {
      let group = byMission.get(hit.mission_id);
      if (!group) {
        const title =
          displayTitle(renamedTitle("mission", hit.mission_id, hit.title ?? null)) ||
          "Untitled conversation";
        group = {
          missionId: hit.mission_id,
          title,
          project: hit.project ?? null,
          status: hit.status,
          updatedAt: hit.updated_at,
          totalMatches: hit.mission_match_count || 1,
          hits: [],
        };
        byMission.set(hit.mission_id, group);
        groups.push(group);
      }
      group.hits.push(hit);
    }
    let flatIndex = 0;
    const flat: ConversationSearchHit[] = [];
    const indexedGroups = groups.map(g => ({
      ...g,
      rows: g.hits.map(hit => {
        const idx = flatIndex++;
        flat.push(hit);
        return { hit, index: idx };
      }),
    }));
    return { groups: indexedGroups, flat };
  });

  const activeItemsCount = createMemo(() =>
    trimmedQuery() ? groupedResults().flat.length : filteredRecents().length,
  );

  // Clamp selection whenever items change.
  createEffect(() => {
    const count = activeItemsCount();
    if (count === 0) {
      setSelectedIndex(0);
    } else if (selectedIndex() >= count) {
      setSelectedIndex(count - 1);
    }
  });

  const selectedHit = createMemo<ConversationSearchHit | undefined>(() =>
    trimmedQuery() ? groupedResults().flat[selectedIndex()] : undefined,
  );

  const selectedRecent = createMemo<Mission | undefined>(() =>
    !trimmedQuery() ? filteredRecents()[selectedIndex()] : undefined,
  );

  const isNarrowViewport = () =>
    typeof window !== "undefined" &&
    typeof window.matchMedia === "function" &&
    window.matchMedia("(max-width: 720px)").matches;

  // Monotonic search request fence + AbortController.
  let searchSeq = 0;
  let activeSearchAbort: AbortController | undefined;
  let debounceTimer: ReturnType<typeof setTimeout> | undefined;

  const cancelInFlightSearch = () => {
    if (debounceTimer !== undefined) {
      clearTimeout(debounceTimer);
      debounceTimer = undefined;
    }
    activeSearchAbort?.abort();
    activeSearchAbort = undefined;
  };

  const runSearch = async (opts?: { cursor?: string | null; immediate?: boolean }) => {
    const q = trimmedQuery();
    const connVer = connectionVersion();
    const apiBase = getApiUrl();
    const proj = projectFilter() || null;
    const role = roleFilter();
    const tools = role === "tool" || includeTools();
    const since = sinceIsoForPreset(datePreset());
    const sort = sortOrder();
    const appendCursor = opts?.cursor ?? null;

    if (!appendCursor) {
      cancelInFlightSearch();
    }

    if (!isConnected()) {
      setLoading(false);
      setLoadingMore(false);
      setError(null);
      return;
    }

    if (!q) {
      // Lightweight coverage check so an active backfill still shows its calm banner.
      const seq = ++searchSeq;
      const ctrl = new AbortController();
      activeSearchAbort = ctrl;
      setRawHits([]);
      setNextCursor(null);
      setHasLoadedForQuery(false);
      setLoading(false);
      setError(null);
      try {
        const res = await searchConversationMessages({ q: "", limit: 1 }, ctrl.signal);
        if (seq !== searchSeq || connVer !== connectionVersion() || apiBase !== getApiUrl()) return;
        setCoverage(res.coverage);
      } catch {
        // Ignore silent coverage probe errors while query is empty.
      }
      return;
    }

    const execute = async () => {
      const seq = ++searchSeq;
      const ctrl = new AbortController();
      activeSearchAbort = ctrl;
      if (appendCursor) {
        setLoadingMore(true);
      } else {
        setLoading(true);
        setError(null);
      }
      try {
        const res = await searchConversationMessages(
          {
            q,
            project: proj,
            role,
            include_tools: tools,
            since,
            sort,
            limit: 24,
            max_per_mission: 3,
            cursor: appendCursor,
          },
          ctrl.signal,
        );
        if (
          ctrl.signal.aborted ||
          seq !== searchSeq ||
          connVer !== connectionVersion() ||
          apiBase !== getApiUrl() ||
          trimmedQuery() !== q
        ) {
          return;
        }
        setCoverage(res.coverage);
        setNextCursor(res.next_cursor ?? null);
        if (appendCursor) {
          setRawHits(prev => {
            const seen = new Set(prev.map(h => `${h.mission_id}:${h.locator}`));
            const extra = res.hits.filter(h => !seen.has(`${h.mission_id}:${h.locator}`));
            return [...prev, ...extra];
          });
        } else {
          setRawHits(res.hits);
          setSelectedIndex(0);
          setHasLoadedForQuery(true);
        }
        setError(null);
      } catch (err) {
        if (
          ctrl.signal.aborted ||
          (err instanceof DOMException && err.name === "AbortError") ||
          seq !== searchSeq ||
          connVer !== connectionVersion() ||
          apiBase !== getApiUrl()
        ) {
          return;
        }
        setError(err instanceof Error ? err.message : String(err));
      } finally {
        if (seq === searchSeq) {
          setLoading(false);
          setLoadingMore(false);
        }
      }
    };

    if (opts?.immediate || appendCursor) {
      await execute();
    } else {
      setLoading(true);
      setError(null);
      debounceTimer = setTimeout(() => {
        debounceTimer = undefined;
        void execute();
      }, DEBOUNCE_MS);
    }
  };

  // Clear caches and re-query whenever query, filters, backend URL, or account changes.
  createEffect(
    on(
      () => [
        connectionVersion(),
        getApiUrl(),
        isConnected(),
        trimmedQuery(),
        projectFilter(),
        roleFilter(),
        includeTools(),
        datePreset(),
        sortOrder(),
      ] as const,
      ([connVer, apiBase], prev) => {
        if (prev && (prev[0] !== connVer || prev[1] !== apiBase)) {
          previewCache.clear();
          setRawHits([]);
          setCoverage(null);
          setNextCursor(null);
          setPreviewData(null);
          setHasLoadedForQuery(false);
        }
        setMobilePane("results");
        void runSearch();
      },
    ),
  );

  // Fetch passage preview context ONLY for the currently selected hit.
  let previewSeq = 0;
  let activePreviewAbort: AbortController | undefined;

  createEffect(() => {
    const connVer = connectionVersion();
    const apiBase = getApiUrl();
    const hit = selectedHit();
    const q = trimmedQuery();

    activePreviewAbort?.abort();
    activePreviewAbort = undefined;

    if (!hit || !isConnected()) {
      setPreviewData(null);
      setPreviewLoading(false);
      setPreviewError(null);
      return;
    }

    if (hit.locator === "title") {
      setPreviewData(null);
      setPreviewLoading(false);
      setPreviewError(null);
      return;
    }

    const cacheKey = `${connVer}|${apiBase}|${hit.mission_id}|${hit.locator}|${q}`;
    const cached = previewCache.get(cacheKey);
    if (cached) {
      setPreviewData(cached);
      setPreviewLoading(false);
      setPreviewError(null);
      return;
    }

    const seq = ++previewSeq;
    const ctrl = new AbortController();
    activePreviewAbort = ctrl;
    setPreviewLoading(true);
    setPreviewError(null);

    void getMissionPassageContext(
      hit.mission_id,
      {
        locator: hit.locator,
        sequence: hit.sequence,
        event_id: hit.event_id,
        query: q,
        before: 2,
        after: 2,
        include_events: false,
      },
      ctrl.signal,
    )
      .then(ctx => {
        if (
          ctrl.signal.aborted ||
          seq !== previewSeq ||
          connVer !== connectionVersion() ||
          apiBase !== getApiUrl()
        ) {
          return;
        }
        if (previewCache.size >= MAX_PREVIEW_CACHE) {
          const oldest = previewCache.keys().next().value;
          if (oldest !== undefined) previewCache.delete(oldest);
        }
        previewCache.set(cacheKey, ctx);
        setPreviewData(ctx);
        setPreviewError(null);
      })
      .catch(err => {
        if (
          ctrl.signal.aborted ||
          (err instanceof DOMException && err.name === "AbortError") ||
          seq !== previewSeq
        ) {
          return;
        }
        setPreviewError(err instanceof Error ? err.message : String(err));
      })
      .finally(() => {
        if (seq === previewSeq) setPreviewLoading(false);
      });
  });

  const scrollRowIntoView = (idx: number) => {
    queueMicrotask(() => {
      const row = resultsPaneRef?.querySelector<HTMLElement>(`[data-cs-index="${idx}"]`);
      row?.scrollIntoView({ block: "nearest" });
    });
  };

  const commitOpenHit = (hit: ConversationSearchHit) => {
    restoreFocusOnClose = false;
    p.onOpenHit(hit, trimmedQuery());
  };

  const commitOpenRecent = (missionId: string) => {
    restoreFocusOnClose = false;
    p.onOpenMission(missionId);
  };

  const openSelected = () => {
    if (trimmedQuery()) {
      const hit = selectedHit();
      if (hit) commitOpenHit(hit);
    } else {
      const recent = selectedRecent();
      if (recent) commitOpenRecent(recent.id);
    }
  };

  const handleDialogKeyDown = (e: KeyboardEvent) => {
    if (e.defaultPrevented || e.isComposing || composing) return;
    const count = activeItemsCount();
    if (e.key === "ArrowDown") {
      if (count > 0) {
        e.preventDefault();
        const next = (selectedIndex() + 1) % count;
        setSelectedIndex(next);
        scrollRowIntoView(next);
      }
      return;
    }
    if (e.key === "ArrowUp") {
      if (count > 0) {
        e.preventDefault();
        const next = (selectedIndex() - 1 + count) % count;
        setSelectedIndex(next);
        scrollRowIntoView(next);
      }
      return;
    }
    if (e.key === "Enter" && !e.shiftKey && !e.altKey) {
      const target = e.target as HTMLElement | null;
      // Let explicit buttons/selects handle their own Enter press naturally.
      if (target && (target.tagName === "BUTTON" || target.tagName === "SELECT") && !target.hasAttribute("data-cs-index")) {
        return;
      }
      if (count > 0) {
        e.preventDefault();
        openSelected();
      }
    }
  };

  onMount(() => {
    p.onInputRef?.(inputRef);
    const cleanupOverlay = mountOverlay(layer, {
      close: () => p.onClose(),
      outsideGesture: true,
      returnFocus: restoreFocusOnClose ? p.returnFocus : null,
      initialFocus: () => inputRef,
    });
    if (inputRef) {
      inputRef.focus({ preventScroll: true });
      const end = inputRef.value.length;
      try {
        inputRef.setSelectionRange(end, end);
      } catch {
        // Ignore on unsupported input types.
      }
    }
    onCleanup(() => {
      cancelInFlightSearch();
      activePreviewAbort?.abort();
      p.onInputRef?.(undefined);
      cleanupOverlay();
    });
  });

  const hasActiveFilters = () =>
    projectFilter() !== "" || roleFilter() !== "all" || includeTools() || datePreset() !== "any";

  const clearFilters = () => {
    setProjectFilter("");
    setRoleFilter("all");
    setIncludeTools(false);
    setDatePreset("any");
  };

  const activeDescendantId = () =>
    activeItemsCount() > 0 ? `${listboxId}-opt-${selectedIndex()}` : undefined;

  const recentSnippet = (m: Mission): string => {
    const cached = peekReadyTranscript(m.id);
    if (cached?.items.length) {
      for (let i = cached.items.length - 1; i >= 0; i--) {
        const it = cached.items[i];
        if ((it.kind === "text" || it.kind === "user") && it.text.trim()) {
          return it.text.replace(/\s+/g, " ").trim().slice(0, 180);
        }
      }
    }
    const lastHist = m.history?.at(-1)?.content?.trim();
    if (lastHist) return lastHist.replace(/\s+/g, " ").slice(0, 180);
    return isArchived(m.status) ? "Archived conversation" : "Open conversation";
  };

  return (
    <OverlayContext.Provider value={layer}>
      <Portal>
        <div
          class="cs-backdrop"
          classList={{ "cs-backdrop-dim": overlayFirstModal(layer) }}
          style={{ "z-index": overlayZIndex(layer) }}
        >
          <div
            ref={root}
            role="dialog"
            aria-modal="true"
            aria-labelledby={titleId}
            aria-busy={loading() || undefined}
            inert={overlayHasModalAbove(layer)}
            tabIndex={-1}
            class="cs-dialog"
            data-testid="conversation-search-dialog"
            onKeyDown={handleDialogKeyDown}
          >
            <header class="cs-header">
              <div class="cs-input-row">
                <span class="cs-search-ico" aria-hidden="true">
                  <Ic.SearchIcon size={16} />
                </span>
                <label id={titleId} class="sr-only">
                  Search conversations
                </label>
                <input
                  ref={el => {
                    inputRef = el;
                  }}
                  type="text"
                  role="combobox"
                  aria-expanded="true"
                  aria-controls={listboxId}
                  aria-activedescendant={activeDescendantId()}
                  aria-autocomplete="list"
                  aria-label="Search conversations and messages"
                  class="cs-input"
                  placeholder="Search conversations, code, identifiers, and messages…"
                  value={p.query}
                  autocomplete="off"
                  spellcheck={false}
                  onCompositionStart={() => {
                    composing = true;
                  }}
                  onCompositionEnd={() => {
                    composing = false;
                  }}
                  onInput={e => p.onQueryChange(e.currentTarget.value)}
                />
                <Show when={p.query.length > 0}>
                  <button
                    type="button"
                    class="cs-clear-btn"
                    aria-label="Clear search query"
                    onClick={() => {
                      p.onQueryChange("");
                      inputRef?.focus({ preventScroll: true });
                    }}
                  >
                    Clear
                  </button>
                </Show>
                <button
                  type="button"
                  class="cs-close-btn"
                  aria-label="Close search"
                  onClick={() => p.onClose()}
                >
                  <Ic.CloseIcon size={15} />
                </button>
              </div>

              <div class="cs-filters" role="toolbar" aria-label="Search filters">
                <select
                  class="cs-select"
                  aria-label="Filter by project"
                  value={projectFilter()}
                  onChange={e => setProjectFilter(e.currentTarget.value)}
                >
                  <option value="">All projects</option>
                  <For each={p.projects}>
                    {proj => <option value={proj.slug}>{proj.title || proj.slug}</option>}
                  </For>
                </select>

                <span class="cs-filter-sep" aria-hidden="true" />

                <div class="cs-chip-group" role="group" aria-label="Message role">
                  {(
                    [
                      ["all", "All"],
                      ["user", "User"],
                      ["assistant", "Assistant"],
                      ["title", "Titles"],
                      ["tool", "Tools"],
                    ] as const
                  ).map(([id, label]) => (
                    <button
                      type="button"
                      class="cs-chip"
                      classList={{ "is-active": roleFilter() === id }}
                      aria-pressed={roleFilter() === id}
                      onClick={() => setRoleFilter(id)}
                    >
                      {label}
                    </button>
                  ))}
                  <Show when={roleFilter() === "all"}>
                    <button
                      type="button"
                      class="cs-chip"
                      classList={{ "is-active": includeTools() }}
                      aria-pressed={includeTools()}
                      title="Include tool file and command targets in All results"
                      onClick={() => setIncludeTools(v => !v)}
                    >
                      + Tools
                    </button>
                  </Show>
                </div>

                <span class="cs-filter-sep" aria-hidden="true" />

                <div class="cs-chip-group" role="group" aria-label="Date range">
                  {(
                    [
                      ["any", "Any time"],
                      ["7d", "7d"],
                      ["30d", "30d"],
                      ["90d", "90d"],
                    ] as const
                  ).map(([id, label]) => (
                    <button
                      type="button"
                      class="cs-chip"
                      classList={{ "is-active": datePreset() === id }}
                      aria-pressed={datePreset() === id}
                      onClick={() => setDatePreset(id)}
                    >
                      {label}
                    </button>
                  ))}
                </div>

                <Show when={trimmedQuery().length > 0}>
                  <div class="cs-sort-push" role="group" aria-label="Sort order">
                    <button
                      type="button"
                      class="cs-chip"
                      classList={{ "is-active": sortOrder() === "relevance" }}
                      aria-pressed={sortOrder() === "relevance"}
                      onClick={() => setSortOrder("relevance")}
                    >
                      Relevance
                    </button>
                    <button
                      type="button"
                      class="cs-chip"
                      classList={{ "is-active": sortOrder() === "recent" }}
                      aria-pressed={sortOrder() === "recent"}
                      onClick={() => setSortOrder("recent")}
                    >
                      Recent
                    </button>
                  </div>
                </Show>
              </div>
            </header>

            <Show when={coverage()?.state === "indexing"}>
              <div class="cs-indexing-banner" role="status" data-testid="search-indexing-banner">
                <span>
                  <i class="cs-indexing-dot" aria-hidden="true" />
                  Indexing conversation history ({coverage()!.indexed_missions} of{" "}
                  {coverage()!.total_missions} conversations)…
                </span>
                <Show when={trimmedQuery().length > 0}>
                  <button
                    type="button"
                    class="cs-chip"
                    onClick={() => void runSearch({ immediate: true })}
                  >
                    Refresh
                  </button>
                </Show>
              </div>
            </Show>

            <div class="cs-body" data-mobile-pane={mobilePane()}>
              <div
                ref={el => {
                  resultsPaneRef = el;
                }}
                id={listboxId}
                role="listbox"
                aria-label={trimmedQuery() ? "Matching passages" : "Recent conversations"}
                class="cs-results-pane"
              >
                <Switch>
                  <Match when={!isConnected()}>
                    <div class="cs-state-box" role="status" data-testid="search-disconnected">
                      <div class="cs-state-title">Disconnected from backend</div>
                      <div class="cs-state-desc">
                        Connect to an Orb backend in Settings to search across your conversation history.
                      </div>
                    </div>
                  </Match>

                  <Match when={!trimmedQuery()}>
                    <div class="cs-section-label">
                      <span>Recent conversations</span>
                      <span>{filteredRecents().length}</span>
                    </div>
                    <Show
                      when={filteredRecents().length > 0}
                      fallback={
                        <div class="cs-state-box" data-testid="search-recents-empty">
                          <div class="cs-state-title">No recent conversations</div>
                          <div class="cs-state-desc">
                            {hasActiveFilters()
                              ? "No loaded conversations match the selected filters."
                              : "Start a conversation or type a query to search full history."}
                          </div>
                        </div>
                      }
                    >
                      <For each={filteredRecents()}>
                        {(m, idx) => {
                          const title = () =>
                            displayTitle(renamedTitle("mission", m.id, m.title)) ||
                            "Untitled conversation";
                          const proj = () => projectTitle(m.project);
                          return (
                            <button
                              type="button"
                              id={`${listboxId}-opt-${idx()}`}
                              role="option"
                              aria-selected={selectedIndex() === idx()}
                              data-cs-index={idx()}
                              class="cs-row"
                              classList={{ "is-selected": selectedIndex() === idx() }}
                              onClick={() => {
                                setSelectedIndex(idx());
                                if (isNarrowViewport()) setMobilePane("preview");
                              }}
                              onDblClick={() => commitOpenRecent(m.id)}
                            >
                              <div class="cs-row-top">
                                <span class="cs-row-title">{title()}</span>
                                <span class="cs-row-meta">
                                  <Show when={proj()}>
                                    <span class="cs-badge">{proj()}</span>
                                  </Show>
                                  <Show when={isArchived(m.status)}>
                                    <span class="cs-badge cs-badge-archived">Archived</span>
                                  </Show>
                                  <span>{formatShortDate(m.updated_at || m.created_at)}</span>
                                </span>
                              </div>
                              <div class="cs-row-excerpt">{recentSnippet(m)}</div>
                            </button>
                          );
                        }}
                      </For>
                    </Show>
                  </Match>

                  <Match when={error()}>
                    <div class="cs-state-box" role="alert" data-testid="search-error">
                      <div class="cs-state-title">Search couldn’t complete</div>
                      <div class="cs-state-desc">{error()}</div>
                      <button
                        type="button"
                        class="cs-action-btn"
                        onClick={() => void runSearch({ immediate: true })}
                      >
                        Retry
                      </button>
                    </div>
                  </Match>

                  <Match when={loading() && !hasLoadedForQuery()}>
                    <div
                      class="cs-skeleton-list"
                      role="status"
                      aria-label="Searching conversations"
                      data-testid="search-loading"
                    >
                      <For each={[0, 1, 2, 3, 4, 5]}>
                        {() => (
                          <div class="cs-skeleton-row" aria-hidden="true">
                            <div class="cs-sk-bar" style={{ width: "62%" }} />
                            <div class="cs-sk-bar" style={{ width: "88%" }} />
                          </div>
                        )}
                      </For>
                    </div>
                  </Match>

                  <Match when={groupedResults().flat.length === 0}>
                    <Show
                      when={coverage()?.state === "indexing"}
                      fallback={
                        <div class="cs-state-box" role="status" data-testid="search-empty">
                          <div class="cs-state-title">No matching passages</div>
                          <div class="cs-state-desc">
                            No conversations or messages matched your search
                            {hasActiveFilters() ? " with the active filters." : "."}
                          </div>
                          <Show when={hasActiveFilters()}>
                            <button type="button" class="cs-action-btn" onClick={clearFilters}>
                              Clear filters
                            </button>
                          </Show>
                        </div>
                      }
                    >
                      <div class="cs-state-box" role="status" data-testid="search-still-indexing">
                        <div class="cs-state-title">Still indexing earlier conversations</div>
                        <div class="cs-state-desc">
                          {coverage()!.indexed_missions} of {coverage()!.total_missions}{" "}
                          conversations indexed so far. Matching passages from older threads will
                          appear as indexing completes.
                        </div>
                        <button
                          type="button"
                          class="cs-action-btn"
                          onClick={() => void runSearch({ immediate: true })}
                        >
                          Check again
                        </button>
                      </div>
                    </Show>
                  </Match>

                  <Match when={groupedResults().flat.length > 0}>
                    <For each={groupedResults().groups}>
                      {group => {
                        const proj = () => projectTitle(group.project);
                        return (
                          <div class="cs-group" data-mission-group={group.missionId}>
                            <Show when={group.rows.length > 1}>
                              <div class="cs-group-head">
                                <span class="cs-group-title">{group.title}</span>
                                <span class="cs-group-meta">
                                  <Show when={proj()}>{proj()} · </Show>
                                  {Math.max(group.rows.length, group.totalMatches)} matches
                                </span>
                              </div>
                            </Show>
                            <For each={group.rows}>
                              {entry => (
                                <button
                                  type="button"
                                  id={`${listboxId}-opt-${entry.index}`}
                                  role="option"
                                  aria-selected={selectedIndex() === entry.index}
                                  data-cs-index={entry.index}
                                  class="cs-row"
                                  classList={{
                                    "cs-row-grouped": group.rows.length > 1,
                                    "is-selected": selectedIndex() === entry.index,
                                  }}
                                  onClick={() => {
                                    setSelectedIndex(entry.index);
                                    if (isNarrowViewport()) setMobilePane("preview");
                                  }}
                                  onDblClick={() => commitOpenHit(entry.hit)}
                                >
                                  <Show when={group.rows.length === 1}>
                                    <div class="cs-row-top">
                                      <span class="cs-row-title">
                                        <Show
                                          when={entry.hit.locator === "title" && entry.hit.highlights.length > 0}
                                          fallback={group.title}
                                        >
                                          <HighlightedText
                                            text={entry.hit.excerpt || group.title}
                                            highlights={entry.hit.highlights}
                                          />
                                        </Show>
                                      </span>
                                      <span class="cs-row-meta">
                                        <Show when={proj()}>
                                          <span class="cs-badge">{proj()}</span>
                                        </Show>
                                        <Show when={isArchived(group.status)}>
                                          <span class="cs-badge cs-badge-archived">Archived</span>
                                        </Show>
                                        <span>
                                          {formatShortDate(
                                            entry.hit.timestamp || entry.hit.updated_at,
                                          )}
                                        </span>
                                      </span>
                                    </div>
                                  </Show>
                                  <div class="cs-row-excerpt">
                                    <span class="cs-role-tag">{entry.hit.role}</span>
                                    <HighlightedText
                                      text={entry.hit.excerpt}
                                      highlights={entry.hit.highlights}
                                    />
                                  </div>
                                </button>
                              )}
                            </For>
                          </div>
                        );
                      }}
                    </For>
                    <Show when={nextCursor()}>
                      <button
                        type="button"
                        class="cs-load-more"
                        disabled={loadingMore()}
                        onClick={() => void runSearch({ cursor: nextCursor(), immediate: true })}
                      >
                        {loadingMore() ? "Loading more…" : "Show more matches"}
                      </button>
                    </Show>
                  </Match>
                </Switch>
              </div>

              <div class="cs-preview-pane" data-testid="search-preview-pane">
                <Switch>
                  <Match when={Boolean(trimmedQuery()) ? selectedHit() : undefined}>
                    {hit => {
                      const title = () =>
                        displayTitle(
                          renamedTitle("mission", hit().mission_id, hit().title ?? null),
                        ) || "Untitled conversation";
                      const proj = () => projectTitle(hit().project);
                      return (
                        <>
                          <div class="cs-preview-head">
                            <div class="cs-preview-title-wrap">
                              <div class="cs-preview-title">{title()}</div>
                              <div class="cs-preview-sub">
                                <Show when={proj()}>
                                  <span>{proj()}</span>
                                  <span>·</span>
                                </Show>
                                <span>{formatShortDate(hit().timestamp || hit().updated_at)}</span>
                                <Show when={isArchived(hit().status)}>
                                  <span>·</span>
                                  <span>Archived</span>
                                </Show>
                              </div>
                            </div>
                            <div class="cs-preview-actions">
                              <button
                                type="button"
                                class="cs-action-btn cs-mobile-back"
                                onClick={() => setMobilePane("results")}
                              >
                                <Ic.ArrowLeft size={13} /> Results
                              </button>
                              <button
                                type="button"
                                class="cs-action-btn cs-action-primary"
                                data-testid="search-open-hit"
                                onClick={() => commitOpenHit(hit())}
                              >
                                Open passage
                              </button>
                            </div>
                          </div>
                          <div class="cs-preview-scroll">
                            <Switch>
                              <Match when={hit().locator === "title"}>
                                <div class="cs-context-msg is-target">
                                  <div class="cs-context-role">
                                    <span>Conversation title</span>
                                    <span>{formatShortDate(hit().updated_at)}</span>
                                  </div>
                                  <div class="cs-context-body">
                                    <HighlightedText
                                      text={hit().excerpt || title()}
                                      highlights={hit().highlights}
                                    />
                                  </div>
                                </div>
                              </Match>

                              <Match when={previewLoading() && !previewData()}>
                                <div
                                  class="cs-skeleton-list"
                                  role="status"
                                  aria-label="Loading message context"
                                >
                                  <For each={[0, 1, 2]}>
                                    {() => (
                                      <div class="cs-skeleton-row" aria-hidden="true">
                                        <div class="cs-sk-bar" style={{ width: "30%" }} />
                                        <div class="cs-sk-bar" style={{ width: "92%" }} />
                                        <div class="cs-sk-bar" style={{ width: "74%" }} />
                                      </div>
                                    )}
                                  </For>
                                </div>
                              </Match>

                              <Match when={previewError()}>
                                <div class="cs-context-msg is-target">
                                  <div class="cs-context-role">
                                    <span>{hit().role}</span>
                                    <span>{formatShortDate(hit().timestamp)}</span>
                                  </div>
                                  <div class="cs-context-body">
                                    <HighlightedText
                                      text={hit().excerpt}
                                      highlights={hit().highlights}
                                    />
                                  </div>
                                </div>
                              </Match>

                              <Match when={previewData()}>
                                {ctx => (
                                  <>
                                    <Show when={!ctx().target_found}>
                                      <div class="cs-indexing-banner" role="status">
                                        This passage was updated or removed since indexing — showing
                                        the latest surrounding context.
                                      </div>
                                    </Show>
                                    <For each={ctx().messages}>
                                      {msg => (
                                        <div
                                          class="cs-context-msg"
                                          classList={{ "is-target": msg.is_target }}
                                        >
                                          <div class="cs-context-role">
                                            <span>{msg.role}</span>
                                            <span>{formatShortDate(msg.timestamp)}</span>
                                          </div>
                                          <div class="cs-context-body">
                                            <HighlightedText
                                              text={msg.content}
                                              highlights={msg.highlights}
                                            />
                                          </div>
                                        </div>
                                      )}
                                    </For>
                                  </>
                                )}
                              </Match>
                            </Switch>
                          </div>
                        </>
                      );
                    }}
                  </Match>

                  <Match when={!trimmedQuery() && selectedRecent()}>
                    {recent => {
                      const title = () =>
                        displayTitle(renamedTitle("mission", recent().id, recent().title)) ||
                        "Untitled conversation";
                      const proj = () => projectTitle(recent().project);
                      return (
                        <>
                          <div class="cs-preview-head">
                            <div class="cs-preview-title-wrap">
                              <div class="cs-preview-title">{title()}</div>
                              <div class="cs-preview-sub">
                                <Show when={proj()}>
                                  <span>{proj()}</span>
                                  <span>·</span>
                                </Show>
                                <span>
                                  {formatShortDate(recent().updated_at || recent().created_at)}
                                </span>
                                <Show when={isArchived(recent().status)}>
                                  <span>·</span>
                                  <span>Archived</span>
                                </Show>
                              </div>
                            </div>
                            <div class="cs-preview-actions">
                              <button
                                type="button"
                                class="cs-action-btn cs-mobile-back"
                                onClick={() => setMobilePane("results")}
                              >
                                <Ic.ArrowLeft size={13} /> Back
                              </button>
                              <button
                                type="button"
                                class="cs-action-btn cs-action-primary"
                                onClick={() => commitOpenRecent(recent().id)}
                              >
                                Open conversation
                              </button>
                            </div>
                          </div>
                          <div class="cs-preview-scroll">
                            <div class="cs-context-msg is-target">
                              <div class="cs-context-role">
                                <span>Latest summary</span>
                                <span>{recent().backend || "agent"}</span>
                              </div>
                              <div class="cs-context-body">{recentSnippet(recent())}</div>
                            </div>
                          </div>
                        </>
                      );
                    }}
                  </Match>

                  <Match when={true}>
                    <div class="cs-state-box">
                      <div class="cs-state-desc">
                        Select a result on the left to preview its message context without leaving
                        your current conversation.
                      </div>
                    </div>
                  </Match>
                </Switch>
              </div>
            </div>

            <footer class="cs-footer">
              <div class="cs-kbd-hints">
                <span>
                  <kbd class="cs-kbd">↑</kbd>
                  <kbd class="cs-kbd">↓</kbd> Select
                </span>
                <span>
                  <kbd class="cs-kbd">↵</kbd> Open
                </span>
                <span>
                  <kbd class="cs-kbd">Esc</kbd> Close
                </span>
              </div>
              <span>
                {trimmedQuery()
                  ? loading()
                    ? "Searching…"
                    : `${groupedResults().flat.length}${nextCursor() ? "+" : ""} passage${
                        groupedResults().flat.length === 1 ? "" : "s"
                      }`
                  : "Active & archived conversations"}
              </span>
            </footer>
          </div>
        </div>
      </Portal>
    </OverlayContext.Provider>
  );
}
