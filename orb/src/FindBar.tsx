import { createEffect, createSignal, onCleanup, onMount, Show, untrack } from 'solid-js';
import {
  CaseSensitiveIcon,
  CloseIcon,
  FindNextIcon,
  FindPrevIcon,
  SearchIcon,
  WholeWordIcon,
} from './icons';
import { markScrollIntent } from './mission/scrollPolicy';
import { hasOverlay } from './overlayLayer';
import { indexText, matchOffsets, matchRange, type TextIndex } from './searchIndex';
import { transcriptSearch, type SearchHit } from './VirtualTurns';

type MatchEntry = { start: number; end: number; hit?: SearchHit };

function rangeRect(range: Range): DOMRect | undefined {
  if (typeof range.getBoundingClientRect !== 'function') return undefined;
  const rect = range.getBoundingClientRect();
  if (rect.width || rect.height) return rect;
  return typeof range.getClientRects === 'function' ? range.getClientRects()[0] : undefined;
}

function scrollRangeIntoView(el: HTMLElement, range: Range, barEl?: HTMLElement) {
  const rect = rangeRect(range);
  if (!rect) return;
  const box = el.getBoundingClientRect();
  if (box.height <= 0 && el.clientHeight <= 0) return;
  const barClearance =
    barEl && rect.right > barEl.getBoundingClientRect().left - 8
      ? barEl.getBoundingClientRect().bottom - box.top + 10
      : 16;
  const topPad = Math.min(el.clientHeight * 0.35, Math.max(16, barClearance));
  const bottomPad = Math.min(el.clientHeight * 0.25, 24);
  if (rect.top < box.top + topPad || rect.bottom > box.bottom - bottomPad) {
    const usable = Math.max(1, el.clientHeight - topPad - bottomPad);
    const targetY = box.top + topPad + usable * 0.35;
    markScrollIntent(el);
    el.scrollTop = Math.max(0, el.scrollTop + (rect.top - targetY));
  }
  if (
    el.scrollWidth > el.clientWidth &&
    (rect.left < box.left + 16 || rect.right > box.right - 16)
  ) {
    el.scrollLeft = Math.max(0, el.scrollLeft + (rect.left - box.left - 32));
  }
}

function selectedSeed(el: HTMLElement): string | undefined {
  const sel = window.getSelection?.();
  if (!sel || sel.isCollapsed || !sel.rangeCount) return undefined;
  const anchor = sel.anchorNode;
  const focus = sel.focusNode;
  if (!anchor || !focus || !el.contains(anchor) || !el.contains(focus)) return undefined;
  const raw = sel.toString();
  if (!raw || raw.length > 200 || /[\r\n]/.test(raw)) return undefined;
  return raw;
}

/** Search rendered message/file text without mutating Solid-owned transcript or syntax nodes. */
export function FindBar() {
  const [open, setOpen] = createSignal(false);
  const [query, setQuery] = createSignal('');
  const [sensitive, setSensitive] = createSignal(false);
  const [whole, setWhole] = createSignal(false);
  const [matches, setMatches] = createSignal<MatchEntry[]>([]);
  const [index, setIndex] = createSignal(0);
  const [label, setLabel] = createSignal('conversation');
  const [loading, setLoading] = createSignal(false);
  const [failure, setFailure] = createSignal('');
  const [scrollTick, setScrollTick] = createSignal(0);
  const [position, setPosition] = createSignal({ top: '54px', right: '24px' });

  let input!: HTMLInputElement;
  let bar!: HTMLDivElement;
  let scope: HTMLElement | undefined;
  let lastTarget: HTMLElement | undefined;
  let previousFocus: HTMLElement | undefined;
  let cached: TextIndex | undefined;
  let mutationObserver: MutationObserver | undefined;
  let scopeResizeObserver: ResizeObserver | undefined;
  let streamTimer: ReturnType<typeof setTimeout> | undefined;
  let searchAbort: AbortController | undefined;
  let paintFrame = 0;
  let revealVersion = 0;
  let lastRevealedTick = 0;
  let anchorScrollTop = 0;
  let pendingStepAnchor = false;
  let hadQuery = false;

  const registry = () => (globalThis.CSS as unknown as { highlights?: Map<string, unknown> } | undefined)?.highlights;
  const paint = (name: string, ranges: Range[]) => {
    const H = (window as unknown as { Highlight?: new (...r: Range[]) => unknown }).Highlight;
    const reg = registry();
    if (H && reg) reg.set(name, new H(...ranges));
  };
  const clearHighlights = () => {
    registry()?.delete('orb-find');
    registry()?.delete('orb-find-current');
  };

  const isMessagesOnly = (el: HTMLElement) =>
    Boolean(
      transcriptSearch(el) ||
        el.matches('.scroll,.btw-thread') ||
        el.querySelector('[data-find-message]'),
    );

  const positionBar = () => {
    if (!scope) return;
    if (!scope.isConnected) {
      close(false);
      return;
    }
    const r = scope.getBoundingClientRect();
    if (r.width === 0 && r.height === 0 && scope.clientHeight === 0) return;
    setPosition({
      top: `${Math.max(8, Math.round(r.top + 8))}px`,
      right: `${Math.max(10, Math.round(innerWidth - r.right + 12))}px`,
    });
  };

  function paintVirtualHighlights(
    el: HTMLElement,
    q: string,
    s: boolean,
    w: boolean,
    messagesOnly: boolean,
    activeHit: SearchHit | undefined,
    activeNode?: HTMLElement,
  ): Range | undefined {
    if (!q) {
      clearHighlights();
      return undefined;
    }
    const box = el.getBoundingClientRect();
    const hasViewport = box.height > 0;
    const passive: Range[] = [];
    let activeRange: Range | undefined;
    const visited = new Set<HTMLElement>();

    const inspectNode = (node: HTMLElement) => {
      if (visited.has(node)) return;
      visited.add(node);
      if (hasViewport && node !== activeNode) {
        const rect = node.getBoundingClientRect();
        if (rect.bottom < box.top - box.height || rect.top > box.bottom + box.height) return;
      }
      const text = indexText(node, { messagesOnly });
      const found = matchOffsets(text.text, q, s, w);
      if (!found.length) return;
      const turnKey = node.dataset.turnKey;
      const activeOcc =
        activeHit && turnKey === activeHit.key
          ? Math.min(activeHit.occurrence, found.length - 1)
          : -1;
      for (let i = 0; i < found.length; i++) {
        const range = matchRange(text, found[i]);
        if (!range) continue;
        if (i === activeOcc) activeRange = range;
        else if (passive.length < 140) passive.push(range);
      }
    };

    if (activeNode) inspectNode(activeNode);
    for (const node of el.querySelectorAll<HTMLElement>('[data-turn-key]')) inspectNode(node);

    paint('orb-find', passive);
    paint('orb-find-current', activeRange ? [activeRange] : []);
    return activeRange;
  }

  const onScopeScroll = () => {
    if (!open() || !scope) return;
    if (!query()) {
      anchorScrollTop = scope.scrollTop;
      return;
    }
    if (!transcriptSearch(scope) || paintFrame) return;
    paintFrame = requestAnimationFrame(() => {
      paintFrame = 0;
      if (!open() || !scope || !transcriptSearch(scope)) return;
      paintVirtualHighlights(
        scope,
        query(),
        sensitive(),
        whole(),
        isMessagesOnly(scope),
        matches()[index()]?.hit,
      );
    });
  };

  function unbindScope() {
    mutationObserver?.disconnect();
    scopeResizeObserver?.disconnect();
    scope?.removeEventListener('scroll', onScopeScroll);
    if (paintFrame) {
      cancelAnimationFrame(paintFrame);
      paintFrame = 0;
    }
  }

  function close(restoreFocus = true) {
    searchAbort?.abort();
    revealVersion++;
    pendingStepAnchor = false;
    setLoading(false);
    setFailure('');
    setOpen(false);
    clearHighlights();
    unbindScope();
    clearTimeout(streamTimer);
    if (restoreFocus && previousFocus?.isConnected) {
      previousFocus.focus({ preventScroll: true });
    }
  }

  function pickAnchorIndex(entries: MatchEntry[], el: HTMLElement): number {
    if (!entries.length) return 0;
    const virtual = transcriptSearch(el);
    if (virtual?.turnRange) {
      const hasGeometry = el.clientHeight > 0 || el.scrollTop > 0;
      if (!hasGeometry) return 0;
      for (let i = 0; i < entries.length; i++) {
        const hit = entries[i].hit;
        const range = hit ? virtual.turnRange(hit.key) : undefined;
        if (range && range.top + range.height > anchorScrollTop + 4) return i;
      }
      return entries.length - 1;
    }
    if (!cached || anchorScrollTop <= 4) return 0;
    const box = el.getBoundingClientRect();
    if (box.height <= 0) return 0;
    for (let i = 0; i < entries.length; i++) {
      const range = matchRange(cached, entries[i]);
      const rect = range && rangeRect(range);
      if (rect && rect.bottom > box.top + 4) return i;
    }
    return entries.length - 1;
  }

  function preserveStreamIndex(prevEntries: MatchEntry[], prevIndex: number, nextEntries: MatchEntry[]): number {
    if (!nextEntries.length) return 0;
    const active = prevEntries[prevIndex];
    if (active?.hit) {
      const exact = nextEntries.findIndex(
        entry =>
          entry.hit?.key === active.hit!.key &&
          entry.hit?.occurrence === active.hit!.occurrence,
      );
      if (exact >= 0) return exact;
      const sameTurn = nextEntries.findIndex(entry => entry.hit?.key === active.hit!.key);
      if (sameTurn >= 0) return sameTurn;
    } else if (active) {
      const exact = nextEntries.findIndex(entry => entry.start === active.start);
      if (exact >= 0) return exact;
    }
    return Math.min(prevIndex, nextEntries.length - 1);
  }

  function runSearch(reason: 'open' | 'query' | 'stream') {
    if (!scope || !open()) return;
    const q = query();
    if (!q) {
      hadQuery = false;
      anchorScrollTop = scope.scrollTop;
      setMatches([]);
      setIndex(0);
      clearHighlights();
      return;
    }
    if (!hadQuery) {
      hadQuery = true;
      if (reason === 'query') anchorScrollTop = scope.scrollTop;
    }
    const prevEntries = matches();
    const prevIndex = index();
    const virtual = transcriptSearch(scope);
    let nextEntries: MatchEntry[];
    if (virtual) {
      nextEntries = virtual.search(q, sensitive(), whole()).map(hit => ({ start: 0, end: 0, hit }));
    } else {
      cached ??= indexText(scope, { messagesOnly: isMessagesOnly(scope) });
      nextEntries = matchOffsets(cached.text, q, sensitive(), whole());
    }
    const nextIndex =
      reason === 'stream' && prevEntries.length > 0
        ? preserveStreamIndex(prevEntries, prevIndex, nextEntries)
        : pickAnchorIndex(nextEntries, scope);
    setMatches(nextEntries);
    setIndex(nextIndex);
    if (reason !== 'stream') {
      pendingStepAnchor = false;
      setScrollTick(n => n + 1);
    }
  }

  createEffect(() => {
    query();
    sensitive();
    whole();
    if (!open()) return;
    clearTimeout(streamTimer);
    untrack(() => runSearch('query'));
  });

  createEffect(() => {
    if (!open()) return;
    const all = matches();
    const at = index();
    const tick = scrollTick();
    untrack(() => {
      const shouldScroll = tick !== lastRevealedTick;
      lastRevealedTick = tick;

      if (!scope || !query() || !all.length) {
        clearHighlights();
        return;
      }

      const targetScope = scope;
      const messagesOnly = isMessagesOnly(targetScope);
      const hit = all[at]?.hit;
      if (hit) {
        const virtual = transcriptSearch(targetScope);
        if (!virtual) return;
        const q = query();
        const s = sensitive();
        const w = whole();
        if (!shouldScroll) {
          paintVirtualHighlights(targetScope, q, s, w, messagesOnly, hit);
          return;
        }
        const stepScroll = pendingStepAnchor;
        const mounted = virtual.mountedTurn?.(hit.key);
        if (mounted) {
          revealVersion++;
          const activeRange = paintVirtualHighlights(targetScope, q, s, w, messagesOnly, hit, mounted);
          if (activeRange) {
            scrollRangeIntoView(targetScope, activeRange, bar);
            if (stepScroll) {
              anchorScrollTop = targetScope.scrollTop;
              pendingStepAnchor = false;
            }
          }
          return;
        }
        const version = ++revealVersion;
        void virtual.reveal(hit, { scroll: false }).then(node => {
          if (!node || version !== revealVersion || !open() || scope !== targetScope) return;
          let activeRange = paintVirtualHighlights(targetScope, q, s, w, messagesOnly, hit, node);
          if (activeRange) scrollRangeIntoView(targetScope, activeRange, bar);
          requestAnimationFrame(() => {
            if (version !== revealVersion || !open() || scope !== targetScope) return;
            activeRange = paintVirtualHighlights(targetScope, q, s, w, messagesOnly, hit, node);
            if (activeRange) scrollRangeIntoView(targetScope, activeRange, bar);
            if (stepScroll) {
              anchorScrollTop = targetScope.scrollTop;
              pendingStepAnchor = false;
            }
          });
        });
        return;
      }

      cached ??= indexText(targetScope, { messagesOnly });
      const passive: Range[] = [];
      for (let i = Math.max(0, at - 60); i < Math.min(all.length, at + 80); i++) {
        if (i === at) continue;
        const r = matchRange(cached, all[i]);
        if (r) passive.push(r);
      }
      const activeRange = all[at] ? matchRange(cached, all[at]) : undefined;
      paint('orb-find', passive);
      paint('orb-find-current', activeRange ? [activeRange] : []);
      if (shouldScroll && activeRange) {
        scrollRangeIntoView(targetScope, activeRange, bar);
        if (pendingStepAnchor) {
          anchorScrollTop = targetScope.scrollTop;
          pendingStepAnchor = false;
        }
      }
    });
  });

  const step = (delta: number) => {
    const count = matches().length;
    if (!count) return;
    pendingStepAnchor = true;
    setIndex(i => (i + delta + count) % count);
    setScrollTick(n => n + 1);
  };

  const trackTarget = (e: Event) => {
    if (!bar?.contains(e.target as Node)) lastTarget = e.target as HTMLElement;
  };

  const scheduleStreamSearch = () => {
    clearTimeout(streamTimer);
    streamTimer = setTimeout(() => runSearch('stream'), 90);
  };

  const onTranscriptChange = (event: Event) => {
    if (open() && scope?.contains(event.target as Node)) {
      cached = undefined;
      scheduleStreamSearch();
    }
  };

  function openSearch(nextScope: HTMLElement) {
    const wasOpen = open();
    const prevQuery = query();
    const switchingScope = scope !== nextScope;
    if (!wasOpen) {
      previousFocus = (document.activeElement as HTMLElement | null) ?? undefined;
    }
    unbindScope();
    scope = nextScope;
    cached = undefined;
    anchorScrollTop = nextScope.scrollTop;

    mutationObserver = new MutationObserver(() => {
      cached = undefined;
      scheduleStreamSearch();
    });
    if (!transcriptSearch(nextScope)) {
      mutationObserver.observe(nextScope, {
        subtree: true,
        childList: true,
        characterData: true,
      });
    }

    if (typeof ResizeObserver !== 'undefined') {
      scopeResizeObserver = new ResizeObserver(positionBar);
      scopeResizeObserver.observe(nextScope);
      if (document.documentElement) scopeResizeObserver.observe(document.documentElement);
    }
    nextScope.addEventListener('scroll', onScopeScroll, { passive: true });

    const seed = selectedSeed(nextScope);
    if (seed !== undefined) setQuery(seed);
    hadQuery = Boolean(seed ?? prevQuery);

    positionBar();
    setLabel(nextScope.matches('.file-preview') ? 'file' : 'conversation');
    setFailure('');
    setOpen(true);

    if (wasOpen && switchingScope && (seed === undefined || seed === prevQuery)) {
      runSearch('open');
    }

    searchAbort?.abort();
    const virtual = transcriptSearch(nextScope);
    if (virtual) {
      const needsLoad = virtual.needsPrepare ? virtual.needsPrepare() : true;
      if (needsLoad) {
        searchAbort = new AbortController();
        const signal = searchAbort.signal;
        setLoading(true);
        void virtual
          .prepare(signal)
          .then(() => {
            if (!signal.aborted && open() && scope === nextScope) runSearch('stream');
          })
          .catch(() => {
            if (!signal.aborted && open() && scope === nextScope) {
              setFailure('History unavailable');
            }
          })
          .finally(() => {
            if (!signal.aborted) setLoading(false);
          });
      } else {
        setLoading(false);
      }
    } else {
      setLoading(false);
    }

    requestAnimationFrame(() => {
      if (!open()) return;
      positionBar();
      input?.focus({ preventScroll: true });
      input?.select();
    });
  }

  function onKeyDown(e: KeyboardEvent) {
    if (e.defaultPrevented || e.isComposing || hasOverlay()) return;
    const mod = e.metaKey || e.ctrlKey;
    const key = e.key.toLowerCase();

    if (mod && !e.shiftKey && !e.altKey && key === 'f') {
      const origin = lastTarget?.isConnected
        ? lastTarget
        : (document.activeElement as HTMLElement | null);
      const nextScope =
        origin?.closest<HTMLElement>('.file-preview,.btw-thread,.scroll,[data-find-conversation]') ??
        origin?.closest('.file-panel')?.querySelector<HTMLElement>('.file-preview') ??
        document.querySelector<HTMLElement>('.scroll,[data-find-conversation]') ??
        undefined;
      if (!nextScope) return;
      e.preventDefault();
      e.stopImmediatePropagation();
      openSearch(nextScope);
      return;
    }

    if (!open()) return;

    if (e.key === 'Escape') {
      e.preventDefault();
      e.stopImmediatePropagation();
      close();
      return;
    }

    if ((mod && !e.altKey && key === 'g') || e.key === 'F3') {
      e.preventDefault();
      e.stopImmediatePropagation();
      step(e.shiftKey ? -1 : 1);
      return;
    }

    const isMac = /mac|iphone|ipad|ipod/i.test(navigator.platform);
    const optionShortcut = isMac
      ? e.metaKey && e.altKey && !e.ctrlKey && !e.shiftKey
      : e.altKey && !e.metaKey && !e.ctrlKey && !e.shiftKey;
    if (optionShortcut && (e.code === 'KeyC' || key === 'c')) {
      e.preventDefault();
      e.stopImmediatePropagation();
      setSensitive(v => !v);
      return;
    }
    if (optionShortcut && (e.code === 'KeyW' || key === 'w')) {
      e.preventDefault();
      e.stopImmediatePropagation();
      setWhole(v => !v);
    }
  }

  const countText = () => {
    if (failure()) return failure();
    if (!query()) return '';
    if (matches().length) return `${index() + 1} / ${matches().length}`;
    return loading() ? 'Searching…' : 'No results';
  };

  onMount(() => {
    window.addEventListener('orb:transcript-change', onTranscriptChange);
    window.addEventListener('resize', positionBar);
    window.addEventListener('keydown', onKeyDown, true);
    window.addEventListener('pointerdown', trackTarget, true);
    window.addEventListener('focusin', trackTarget, true);
  });

  onCleanup(() => {
    window.removeEventListener('orb:transcript-change', onTranscriptChange);
    window.removeEventListener('resize', positionBar);
    window.removeEventListener('keydown', onKeyDown, true);
    window.removeEventListener('pointerdown', trackTarget, true);
    window.removeEventListener('focusin', trackTarget, true);
    searchAbort?.abort();
    clearHighlights();
    unbindScope();
    clearTimeout(streamTimer);
  });

  return (
    <Show when={open()}>
      <div
        ref={bar}
        class="find-bar"
        style={position()}
        role="search"
        aria-label={`Find in ${label()}`}
      >
        <div class="find-field">
          <SearchIcon size={13} class="find-icon" />
          <input
            ref={input}
            type="text"
            spellcheck={false}
            autocomplete="off"
            aria-label={`Find in ${label()}`}
            placeholder="Find"
            title={`Find in ${label()}`}
            value={query()}
            onInput={e => setQuery(e.currentTarget.value)}
            onKeyDown={e => {
              if (!e.isComposing && e.key === 'Enter') {
                e.preventDefault();
                step(e.shiftKey ? -1 : 1);
              }
            }}
          />
          <button
            type="button"
            class="find-toggle"
            title="Match Case (⌥⌘C)"
            aria-label="Match case"
            aria-pressed={sensitive()}
            onClick={() => {
              setSensitive(v => !v);
              input?.focus({ preventScroll: true });
            }}
          >
            <CaseSensitiveIcon size={15} />
          </button>
          <button
            type="button"
            class="find-toggle"
            title="Match Whole Word (⌥⌘W)"
            aria-label="Whole word"
            aria-pressed={whole()}
            onClick={() => {
              setWhole(v => !v);
              input?.focus({ preventScroll: true });
            }}
          >
            <WholeWordIcon size={15} />
          </button>
        </div>
        <span
          class="find-count"
          classList={{
            'is-empty': Boolean(query() && !matches().length && !loading() && !failure()),
            'is-error': Boolean(failure()),
          }}
          aria-live="polite"
        >
          {countText()}
        </span>
        <div class="find-actions">
          <button
            type="button"
            class="find-nav"
            title="Previous Match (Shift+Enter)"
            aria-label="Previous match"
            disabled={!matches().length}
            onClick={() => step(-1)}
          >
            <FindPrevIcon size={14} />
          </button>
          <button
            type="button"
            class="find-nav"
            title="Next Match (Enter)"
            aria-label="Next match"
            disabled={!matches().length}
            onClick={() => step(1)}
          >
            <FindNextIcon size={14} />
          </button>
          <button
            type="button"
            class="find-close"
            title="Close (Esc)"
            aria-label="Close search"
            onClick={() => close()}
          >
            <CloseIcon size={14} />
          </button>
        </div>
      </div>
    </Show>
  );
}
