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
  excludeBtwMissions,
  getApiUrl,
  getMissionPassageContext,
  isBtwMission,
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
  return d.toLocaleDateString(
    undefined,
    sameYear
      ? { month: "short", day: "numeric" }
      : { year: "numeric", month: "short", day: "numeric" },
  );
}

function roleLabel(role: string): string {
  if (role === "user") return "User";
  if (role === "assistant") return "Assistant";
  if (role === "title") return "Title";
  if (role === "tool") return "Tool";
  return role;
}

function clampPreviewContent(text: string): string {
  const trimmed = text.trim();
  if (trimmed.length <= 2400) return trimmed;
  return `${trimmed.slice(0, 2400).trimEnd()}…`;
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
  let previewScrollRef: HTMLDivElement | undefined;
  let composing = false;
  let restoreFocusOnClose = true;

  const titleId = createUniqueId();
  const listboxId = createUniqueId();
  const layer: OverlayLayer = { root: () => root, parent: useOverlayParent(), modal: true };

  const [projectFilter, setProjectFilter] = createSignal<string>("");
  const [roleFilter, setRoleFilter] = createSignal<ConversationSearchRole>("all");
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
    return excludeBtwMissions(p.recentMissions)
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
      if (isBtwMission({ id: hit.mission_id })) continue;
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
    const tools = role === "tool";
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

  // Fetch passage preview context for the currently selected hit (including title matches,
  // which resolve the conversation's latest turns on the backend).
  let previewSeq = 0;
  let activePreviewAbort: AbortController | undefined;

  const scrollTargetIntoPreview = () => {
    queueMicrotask(() => {
      const container = previewScrollRef;
      if (!container) return;
      const target = container.querySelector<HTMLElement>(".sd-turn.is-target");
      if (target) {
        target.scrollIntoView({ block: "nearest" });
      } else {
        container.scrollTop = 0;
      }
    });
  };

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

    const cacheKey = `${connVer}|${apiBase}|${hit.mission_id}|${hit.locator}|${q}`;
    const cached = previewCache.get(cacheKey);
    if (cached) {
      setPreviewData(cached);
      setPreviewLoading(false);
      setPreviewError(null);
      scrollTargetIntoPreview();
      return;
    }

    setPreviewData(null);
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
        before: hit.locator === "title" ? 3 : 2,
        after: hit.locator === "title" ? 0 : 2,
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
        scrollTargetIntoPreview();
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
    const target = e.target as HTMLElement | null;
    if (target?.tagName === "SELECT") return;
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
      if (target && target.tagName === "BUTTON" && !target.hasAttribute("data-cs-index")) {
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
    projectFilter() !== "" || roleFilter() !== "all" || datePreset() !== "any";

  const clearFilters = () => {
    setProjectFilter("");
    setRoleFilter("all");
    setDatePreset("any");
  };

  const activeDescendantId = () =>
    activeItemsCount() > 0 ? `${listboxId}-opt-${selectedIndex()}` : undefined;

  const recentTurns = (m: Mission): Array<{ role: string; text: string }> => {
    const cached = peekReadyTranscript(m.id);
    if (cached?.items.length) {
      const turns = cached.items
        .filter((it): it is Extract<typeof it, { kind: "text" | "user" }> =>
          (it.kind === "text" || it.kind === "user") && Boolean(it.text.trim()),
        )
        .slice(-4)
        .map(it => ({
          role: it.kind === "user" ? "user" : "assistant",
          text: clampPreviewContent(it.text),
        }));
      if (turns.length) return turns;
    }
    const hist = (m.history ?? [])
      .filter(h => Boolean(h.content?.trim()))
      .slice(-4)
      .map(h => ({ role: h.role || "assistant", text: clampPreviewContent(h.content) }));
    return hist;
  };

  const recentSnippet = (m: Mission): string => {
    const turns = recentTurns(m);
    if (turns.length) {
      return turns[turns.length - 1].text.replace(/\s+/g, " ").slice(0, 180);
    }
    return isArchived(m.status) ? "Archived conversation" : "Active conversation";
  };

  return (
    <OverlayContext.Provider value={layer}>
      <Portal>
        <div
          class="sd-backdrop"
          classList={{ "sd-backdrop-dim": overlayFirstModal(layer) }}
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
            class="sd-dialog"
            data-testid="conversation-search-dialog"
            onKeyDown={handleDialogKeyDown}
          >
            <header class="sd-header">
              <div class="sd-searchbar">
                <span class="sd-search-ico" aria-hidden="true">
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
                  class="sd-input"
                  placeholder="Search conversations and messages…"
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
                    class="sd-icon-btn"
                    aria-label="Clear search query"
                    title="Clear search"
                    onClick={() => {
                      p.onQueryChange("");
                      inputRef?.focus({ preventScroll: true });
                    }}
                  >
                    <Ic.CloseIcon size={13} />
                  </button>
                </Show>
                <button
                  type="button"
                  class="sd-esc-btn"
                  aria-label="Close search"
                  onClick={() => p.onClose()}
                >
                  Esc
                </button>
              </div>

              <div class="sd-toolbar" role="toolbar" aria-label="Search filters">
                <div class="sd-tabs" role="group" aria-label="Message role">
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
                      class="sd-tab"
                      classList={{ "is-active": roleFilter() === id }}
                      aria-pressed={roleFilter() === id}
                      onClick={() => setRoleFilter(id)}
                    >
                      {label}
                    </button>
                  ))}
                </div>

                <div class="sd-meta-filters">
                  <Show when={p.projects.length > 0}>
                    <div class="sd-select-wrap" classList={{ "is-filtered": projectFilter() !== "" }}>
                      <span class="sd-select-label" aria-hidden="true">
                        {projectTitle(projectFilter()) || "All projects"}
                      </span>
                      <span class="sd-select-caret" aria-hidden="true">
                        <Ic.ChevronDown size={10} />
                      </span>
                      <select
                        class="sd-select"
                        aria-label="Filter by project"
                        value={projectFilter()}
                        onChange={e => setProjectFilter(e.currentTarget.value)}
                      >
                        <option value="">All projects</option>
                        <For each={p.projects}>
                          {proj => <option value={proj.slug}>{proj.title || proj.slug}</option>}
                        </For>
                      </select>
                    </div>
                  </Show>

                  <div class="sd-select-wrap" classList={{ "is-filtered": datePreset() !== "any" }}>
                    <span class="sd-select-label" aria-hidden="true">
                      {datePreset() === "7d"
                        ? "Past 7d"
                        : datePreset() === "30d"
                          ? "Past 30d"
                          : datePreset() === "90d"
                            ? "Past 90d"
                            : "Any time"}
                    </span>
                    <span class="sd-select-caret" aria-hidden="true">
                      <Ic.ChevronDown size={10} />
                    </span>
                    <select
                      class="sd-select"
                      aria-label="Date range"
                      value={datePreset()}
                      onChange={e => setDatePreset(e.currentTarget.value as DatePreset)}
                    >
                      <option value="any">Any time</option>
                      <option value="7d">Past 7 days</option>
                      <option value="30d">Past 30 days</option>
                      <option value="90d">Past 90 days</option>
                    </select>
                  </div>

                  <Show when={trimmedQuery().length > 0}>
                    <div
                      class="sd-select-wrap"
                      classList={{ "is-filtered": sortOrder() !== "relevance" }}
                    >
                      <span class="sd-select-label" aria-hidden="true">
                        {sortOrder() === "recent" ? "Recent" : "Relevance"}
                      </span>
                      <span class="sd-select-caret" aria-hidden="true">
                        <Ic.ChevronDown size={10} />
                      </span>
                      <select
                        class="sd-select"
                        aria-label="Sort order"
                        value={sortOrder()}
                        onChange={e =>
                          setSortOrder(e.currentTarget.value as ConversationSearchSort)
                        }
                      >
                        <option value="relevance">Relevance</option>
                        <option value="recent">Most recent</option>
                      </select>
                    </div>
                  </Show>
                </div>
              </div>
            </header>

            <Show when={coverage()?.state === "indexing"}>
              <div class="sd-banner" role="status" data-testid="search-indexing-banner">
                <span class="sd-banner-text">
                  <i class="sd-indexing-dot" aria-hidden="true" />
                  Indexing history ({coverage()!.indexed_missions} of {coverage()!.total_missions})
                </span>
                <Show when={trimmedQuery().length > 0}>
                  <button
                    type="button"
                    class="sd-inline-link"
                    onClick={() => void runSearch({ immediate: true })}
                  >
                    Refresh
                  </button>
                </Show>
              </div>
            </Show>

            <div class="cs-body sd-body" data-mobile-pane={mobilePane()}>
              <div
                ref={el => {
                  resultsPaneRef = el;
                }}
                id={listboxId}
                role="listbox"
                aria-label={trimmedQuery() ? "Matching passages" : "Recent conversations"}
                class="sd-results-pane"
              >
                <Switch>
                  <Match when={!isConnected()}>
                    <div class="sd-empty-state" role="status" data-testid="search-disconnected">
                      <div class="sd-empty-title">Disconnected</div>
                      <div class="sd-empty-desc">
                        Connect to an Orb server in Settings to search across conversations.
                      </div>
                    </div>
                  </Match>

                  <Match when={!trimmedQuery()}>
                    <div class="sd-section-head">
                      <span>Recent</span>
                    </div>
                    <Show
                      when={filteredRecents().length > 0}
                      fallback={
                        <div class="sd-empty-state" data-testid="search-recents-empty">
                          <div class="sd-empty-title">No recent conversations</div>
                          <div class="sd-empty-desc">
                            {hasActiveFilters()
                              ? "No loaded conversations match these filters."
                              : "Type above to search your conversation archive."}
                          </div>
                          <Show when={hasActiveFilters()}>
                            <button type="button" class="sd-ghost-btn" onClick={clearFilters}>
                              Reset filters
                            </button>
                          </Show>
                        </div>
                      }
                    >
                      <For each={filteredRecents()}>
                        {(m, idx) => {
                          const title = () =>
                            displayTitle(renamedTitle("mission", m.id, m.title)) ||
                            "Untitled conversation";
                          const proj = () => projectTitle(m.project);
                          const dateStr = () => formatShortDate(m.updated_at || m.created_at);
                          return (
                            <button
                              type="button"
                              id={`${listboxId}-opt-${idx()}`}
                              role="option"
                              aria-selected={selectedIndex() === idx()}
                              data-cs-index={idx()}
                              class="sd-row"
                              classList={{ "is-selected": selectedIndex() === idx() }}
                              onClick={() => {
                                setSelectedIndex(idx());
                                if (isNarrowViewport()) setMobilePane("preview");
                              }}
                              onDblClick={() => commitOpenRecent(m.id)}
                            >
                              <div class="sd-row-top">
                                <span class="sd-row-title">{title()}</span>
                                <span class="sd-row-meta">
                                  <Show when={proj()}>
                                    <span class="sd-meta-proj">{proj()}</span>
                                  </Show>
                                  <Show when={proj() && dateStr()}>
                                    <span class="sd-dot" aria-hidden="true">·</span>
                                  </Show>
                                  <span>{dateStr()}</span>
                                </span>
                              </div>
                              <div class="cs-row-excerpt sd-row-excerpt">{recentSnippet(m)}</div>
                            </button>
                          );
                        }}
                      </For>
                    </Show>
                  </Match>

                  <Match when={error()}>
                    <div class="sd-empty-state" role="alert" data-testid="search-error">
                      <div class="sd-empty-title">Search unavailable</div>
                      <div class="sd-empty-desc">{error()}</div>
                      <button
                        type="button"
                        class="sd-ghost-btn"
                        onClick={() => void runSearch({ immediate: true })}
                      >
                        Try again
                      </button>
                    </div>
                  </Match>

                  <Match when={loading() && !hasLoadedForQuery()}>
                    <div
                      class="sd-skeleton-list"
                      role="status"
                      aria-label="Searching conversations"
                      data-testid="search-loading"
                    >
                      <For each={[0, 1, 2, 3, 4]}>
                        {() => (
                          <div class="sd-skeleton-row" aria-hidden="true">
                            <div class="sd-sk-bar" style={{ width: "56%" }} />
                            <div class="sd-sk-bar" style={{ width: "84%" }} />
                          </div>
                        )}
                      </For>
                    </div>
                  </Match>

                  <Match when={groupedResults().flat.length === 0}>
                    <Show
                      when={coverage()?.state === "indexing"}
                      fallback={
                        <div class="sd-empty-state" role="status" data-testid="search-empty">
                          <div class="sd-empty-title">No matches</div>
                          <div class="sd-empty-desc">
                            Nothing matched “{trimmedQuery()}”
                            {hasActiveFilters() ? " with the current filters." : "."}
                          </div>
                          <Show when={hasActiveFilters()}>
                            <button type="button" class="sd-ghost-btn" onClick={clearFilters}>
                              Clear filters
                            </button>
                          </Show>
                        </div>
                      }
                    >
                      <div class="sd-empty-state" role="status" data-testid="search-still-indexing">
                        <div class="sd-empty-title">Indexing earlier conversations</div>
                        <div class="sd-empty-desc">
                          {coverage()!.indexed_missions} of {coverage()!.total_missions}{" "}
                          conversations indexed so far.
                        </div>
                        <button
                          type="button"
                          class="sd-ghost-btn"
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
                        const multi = () => group.rows.length > 1;
                        return (
                          <div class="sd-group" data-mission-group={group.missionId}>
                            <Show when={multi()}>
                              <div class="sd-group-head">
                                <span class="sd-group-title">{group.title}</span>
                                <span class="sd-group-meta">
                                  <Show when={proj()}>
                                    <span class="sd-meta-proj">{proj()}</span>
                                    <span class="sd-dot" aria-hidden="true">·</span>
                                  </Show>
                                  <span>{Math.max(group.rows.length, group.totalMatches)}</span>
                                </span>
                              </div>
                            </Show>
                            <div classList={{ "sd-group-passages": multi() }}>
                              <For each={group.rows}>
                                {entry => {
                                  const isSingleTitleHit = () =>
                                    !multi() && entry.hit.locator === "title";
                                  const isGroupedTitleHit = () =>
                                    multi() && entry.hit.locator === "title";
                                  const dateStr = () =>
                                    formatShortDate(entry.hit.timestamp || entry.hit.updated_at);
                                  return (
                                    <button
                                      type="button"
                                      id={`${listboxId}-opt-${entry.index}`}
                                      role="option"
                                      aria-selected={selectedIndex() === entry.index}
                                      data-cs-index={entry.index}
                                      class="sd-row"
                                      classList={{
                                        "sd-row-grouped": multi(),
                                        "is-selected": selectedIndex() === entry.index,
                                      }}
                                      onClick={() => {
                                        setSelectedIndex(entry.index);
                                        if (isNarrowViewport()) setMobilePane("preview");
                                      }}
                                      onDblClick={() => commitOpenHit(entry.hit)}
                                    >
                                      <Show when={!multi()}>
                                        <div class="sd-row-top">
                                          <span class="sd-row-title">
                                            <Show
                                              when={
                                                entry.hit.locator === "title" &&
                                                entry.hit.highlights.length > 0
                                              }
                                              fallback={group.title}
                                            >
                                              <HighlightedText
                                                text={entry.hit.excerpt || group.title}
                                                highlights={entry.hit.highlights}
                                              />
                                            </Show>
                                          </span>
                                          <span class="sd-row-meta">
                                            <Show when={proj()}>
                                              <span class="sd-meta-proj">{proj()}</span>
                                            </Show>
                                            <Show when={proj() && dateStr()}>
                                              <span class="sd-dot" aria-hidden="true">·</span>
                                            </Show>
                                            <span>{dateStr()}</span>
                                          </span>
                                        </div>
                                      </Show>
                                      <div
                                        class="cs-row-excerpt sd-row-excerpt"
                                        classList={{ "sd-row-excerpt-single": isGroupedTitleHit() }}
                                      >
                                        <Show
                                          when={!isSingleTitleHit()}
                                          fallback={
                                            <span class="sd-title-match-note">
                                              Title match
                                              <Show when={isArchived(group.status)}>
                                                {" · Archived"}
                                              </Show>
                                            </span>
                                          }
                                        >
                                          <span class="sd-role-tag">
                                            {roleLabel(entry.hit.role)}
                                          </span>
                                          <HighlightedText
                                            text={
                                              isGroupedTitleHit()
                                                ? entry.hit.excerpt || group.title
                                                : entry.hit.excerpt
                                            }
                                            highlights={entry.hit.highlights}
                                          />
                                        </Show>
                                      </div>
                                    </button>
                                  );
                                }}
                              </For>
                            </div>
                          </div>
                        );
                      }}
                    </For>
                    <Show when={nextCursor()}>
                      <button
                        type="button"
                        class="sd-load-more"
                        disabled={loadingMore()}
                        onClick={() => void runSearch({ cursor: nextCursor(), immediate: true })}
                      >
                        {loadingMore() ? "Loading…" : "Show more"}
                      </button>
                    </Show>
                  </Match>
                </Switch>
              </div>

              <div class="sd-preview-pane" data-testid="search-preview-pane">
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
                          <div class="sd-preview-head">
                            <div class="sd-preview-heading">
                              <div class="sd-preview-title">
                                <Show
                                  when={
                                    hit().locator === "title" && hit().highlights.length > 0
                                  }
                                  fallback={title()}
                                >
                                  <HighlightedText
                                    text={hit().excerpt || title()}
                                    highlights={hit().highlights}
                                  />
                                </Show>
                              </div>
                              <div class="sd-preview-sub">
                                <Show when={proj()}>
                                  <span>{proj()}</span>
                                  <span class="sd-dot" aria-hidden="true">·</span>
                                </Show>
                                <span>{formatShortDate(hit().timestamp || hit().updated_at)}</span>
                                <Show when={isArchived(hit().status)}>
                                  <span class="sd-dot" aria-hidden="true">·</span>
                                  <span>Archived</span>
                                </Show>
                              </div>
                            </div>
                            <div class="sd-preview-actions">
                              <button
                                type="button"
                                class="sd-open-btn sd-mobile-back"
                                onClick={() => setMobilePane("results")}
                              >
                                <Ic.ArrowLeft size={12} /> Results
                              </button>
                              <button
                                type="button"
                                class="sd-open-btn"
                                data-testid="search-open-hit"
                                onClick={() => commitOpenHit(hit())}
                              >
                                <span>Open</span>
                                <kbd class="sd-open-kbd" aria-hidden="true">↵</kbd>
                              </button>
                            </div>
                          </div>

                          <div
                            ref={el => {
                              previewScrollRef = el;
                            }}
                            class="sd-preview-scroll"
                          >
                            <Switch>
                              <Match when={previewLoading() && !previewData()}>
                                <Show
                                  when={hit().locator !== "title"}
                                  fallback={
                                    <div class="sd-preview-quiet">Loading conversation…</div>
                                  }
                                >
                                  <div
                                    class="sd-skeleton-list"
                                    role="status"
                                    aria-label="Loading message context"
                                  >
                                    <For each={[0, 1]}>
                                      {() => (
                                        <div class="sd-skeleton-row" aria-hidden="true">
                                          <div class="sd-sk-bar" style={{ width: "24%" }} />
                                          <div class="sd-sk-bar" style={{ width: "90%" }} />
                                          <div class="sd-sk-bar" style={{ width: "68%" }} />
                                        </div>
                                      )}
                                    </For>
                                  </div>
                                </Show>
                              </Match>

                              <Match when={previewError()}>
                                <Show
                                  when={hit().locator !== "title"}
                                  fallback={
                                    <div class="sd-preview-quiet">
                                      Press Enter to open this conversation.
                                    </div>
                                  }
                                >
                                  <div class="sd-turn is-target">
                                    <div class="sd-turn-meta">
                                      <span class="sd-turn-role">{roleLabel(hit().role)}</span>
                                      <span class="sd-turn-time">
                                        {formatShortDate(hit().timestamp)}
                                      </span>
                                    </div>
                                    <div class="sd-turn-body">
                                      <HighlightedText
                                        text={clampPreviewContent(hit().excerpt)}
                                        highlights={hit().highlights}
                                      />
                                    </div>
                                  </div>
                                </Show>
                              </Match>

                              <Match when={previewData()}>
                                {ctx => {
                                  const fallbackTurns = () => {
                                    const local = p.recentMissions.find(
                                      m => m.id === hit().mission_id,
                                    );
                                    return local ? recentTurns(local) : [];
                                  };
                                  return (
                                    <>
                                      <Show when={!ctx().target_found && hit().locator !== "title"}>
                                        <div class="sd-stale-note" role="status">
                                          Passage updated since indexing — showing latest context.
                                        </div>
                                      </Show>
                                      <Show
                                        when={ctx().messages.length > 0}
                                        fallback={
                                          <Show
                                            when={fallbackTurns().length > 0}
                                            fallback={
                                              <div class="sd-preview-quiet">
                                                {hit().locator === "title"
                                                  ? "Press Enter to open this conversation."
                                                  : "No messages recorded in this conversation yet."}
                                              </div>
                                            }
                                          >
                                            <div class="sd-turn-stream">
                                              <For each={fallbackTurns()}>
                                                {turn => (
                                                  <div class="sd-turn">
                                                    <div class="sd-turn-meta">
                                                      <span class="sd-turn-role">
                                                        {roleLabel(turn.role)}
                                                      </span>
                                                    </div>
                                                    <div class="sd-turn-body">{turn.text}</div>
                                                  </div>
                                                )}
                                              </For>
                                            </div>
                                          </Show>
                                        }
                                      >
                                        <div class="sd-turn-stream">
                                          <For each={ctx().messages}>
                                            {msg => (
                                              <div
                                                class="sd-turn"
                                                classList={{
                                                  "is-target":
                                                    msg.is_target && hit().locator !== "title",
                                                }}
                                              >
                                                <div class="sd-turn-meta">
                                                  <span class="sd-turn-role">
                                                    {roleLabel(msg.role)}
                                                  </span>
                                                  <span class="sd-turn-time">
                                                    {formatShortDate(msg.timestamp)}
                                                  </span>
                                                </div>
                                                <div class="sd-turn-body">
                                                  <HighlightedText
                                                    text={clampPreviewContent(msg.content)}
                                                    highlights={msg.highlights}
                                                  />
                                                </div>
                                              </div>
                                            )}
                                          </For>
                                        </div>
                                      </Show>
                                    </>
                                  );
                                }}
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
                      const turns = createMemo(() => recentTurns(recent()));
                      return (
                        <>
                          <div class="sd-preview-head">
                            <div class="sd-preview-heading">
                              <div class="sd-preview-title">{title()}</div>
                              <div class="sd-preview-sub">
                                <Show when={proj()}>
                                  <span>{proj()}</span>
                                  <span class="sd-dot" aria-hidden="true">·</span>
                                </Show>
                                <span>
                                  {formatShortDate(recent().updated_at || recent().created_at)}
                                </span>
                                <Show when={isArchived(recent().status)}>
                                  <span class="sd-dot" aria-hidden="true">·</span>
                                  <span>Archived</span>
                                </Show>
                              </div>
                            </div>
                            <div class="sd-preview-actions">
                              <button
                                type="button"
                                class="sd-open-btn sd-mobile-back"
                                onClick={() => setMobilePane("results")}
                              >
                                <Ic.ArrowLeft size={12} /> Results
                              </button>
                              <button
                                type="button"
                                class="sd-open-btn"
                                onClick={() => commitOpenRecent(recent().id)}
                              >
                                <span>Open</span>
                                <kbd class="sd-open-kbd" aria-hidden="true">↵</kbd>
                              </button>
                            </div>
                          </div>
                          <div class="sd-preview-scroll">
                            <Show
                              when={turns().length > 0}
                              fallback={
                                <div class="sd-preview-quiet">
                                  Press Enter to open this conversation.
                                </div>
                              }
                            >
                              <div class="sd-turn-stream">
                                <For each={turns()}>
                                  {turn => (
                                    <div class="sd-turn">
                                      <div class="sd-turn-meta">
                                        <span class="sd-turn-role">{roleLabel(turn.role)}</span>
                                      </div>
                                      <div class="sd-turn-body">{turn.text}</div>
                                    </div>
                                  )}
                                </For>
                              </div>
                            </Show>
                          </div>
                        </>
                      );
                    }}
                  </Match>

                  <Match when={true}>
                    <div class="sd-empty-state">
                      <div class="sd-empty-desc">
                        Select a conversation on the left to preview its messages.
                      </div>
                    </div>
                  </Match>
                </Switch>
              </div>
            </div>

            <footer class="sd-footer">
              <div class="sd-kbd-hints">
                <span>
                  <kbd class="sd-kbd">↑↓</kbd> Navigate
                </span>
                <span>
                  <kbd class="sd-kbd">↵</kbd> Open
                </span>
              </div>
              <span class="sd-footer-count">
                {trimmedQuery()
                  ? loading()
                    ? "Searching…"
                    : `${groupedResults().flat.length}${nextCursor() ? "+" : ""} ${
                        groupedResults().flat.length === 1 ? "match" : "matches"
                      }`
                  : filteredRecents().length > 0
                    ? `${filteredRecents().length} recent`
                    : ""}
              </span>
            </footer>
          </div>
        </div>
      </Portal>
    </OverlayContext.Provider>
  );
}
