import { createSignal } from "solid-js";
import {
  orbSidebarDragStep, orbSidebarMoveTargetAdmit,
  type SidebarDragPhase, type SidebarMoveItemKind,
} from "../orbKernel";

export type DragSourceItem = {
  treeId: string;
  kind: SidebarMoveItemKind;
  srcSlug: string;
  srcPath: string;
  srcParent: string;
  label: string;
};

export type DragTargetContainer = {
  slug: string;
  path: string;
  collapsed: boolean;
  element: HTMLElement;
};

/** Deterministic session-local ordinal table (`0` reserved for root/none; projects/paths ≥ 1). */
export function createContainerOrdinals() {
  const projects = new Map<string, number>();
  const paths = new Map<string, number>([["", 0]]);
  const projectOrd = (slug: string): number => {
    if (!slug) return 0;
    let ord = projects.get(slug);
    if (!ord) { ord = projects.size + 1; projects.set(slug, ord); }
    return ord;
  };
  const pathOrd = (path: string): number => {
    if (!path) return 0;
    let ord = paths.get(path);
    if (ord === undefined) { ord = paths.size + 1; paths.set(path, ord); }
    return ord;
  };
  return { projectOrd, pathOrd };
}

export function isGroupMoveAdmitted(
  ords: ReturnType<typeof createContainerOrdinals>,
  sources: readonly DragSourceItem[],
  dstSlug: string,
  dstPath: string,
): boolean {
  if (!sources.length || !dstSlug) return false;
  const dstProjectOrd = ords.projectOrd(dstSlug);
  const dstPathOrd = ords.pathOrd(dstPath);
  const folderBlocked = sources.some(s =>
    s.kind === 1 && s.srcSlug === dstSlug && (dstPath === s.srcPath || dstPath.startsWith(`${s.srcPath}/`)));
  if (folderBlocked) return false;
  return sources.some(s => orbSidebarMoveTargetAdmit({
    itemKind: s.kind,
    dstIsSelfOrSubtree: s.kind === 1 && s.srcSlug === dstSlug && (dstPath === s.srcPath || dstPath.startsWith(`${s.srcPath}/`)),
    srcProjectOrd: ords.projectOrd(s.srcSlug),
    srcPathOrd: ords.pathOrd(s.srcPath),
    srcParentOrd: ords.pathOrd(s.srcParent),
    dstProjectOrd,
    dstPathOrd,
  }));
}

export function createSidebarRowDrag(deps: {
  getTreeEl: () => HTMLElement | undefined;
  resolveSources: (treeId: string) => DragSourceItem[];
  resolveTargetAt: (x: number, y: number) => DragTargetContainer | undefined;
  expandContainer: (slug: string, path: string) => void;
  commitDrop: (sources: DragSourceItem[], dstSlug: string, dstPath: string) => void;
  openMovePicker: (sources: DragSourceItem[], anchor: HTMLElement) => void;
  dismissTooltip: () => void;
  onQuickTap?: (treeId: string, entry: HTMLElement) => void;
}) {
  const ords = createContainerOrdinals();
  const emptySet: ReadonlySet<string> = new Set<string>();
  const [phase, setPhase] = createSignal<SidebarDragPhase>(0);
  const [liftedIds, setLiftedIds] = createSignal<ReadonlySet<string>>(emptySet);
  const [pill, setPill] = createSignal<{ label: string; count: number; x: number; y: number } | null>(null);
  let cleanupActive: (() => void) | undefined;

  const targetOrdOf = (slug: string, path: string) => ords.pathOrd(`${slug}\0${path}`);

  const onPointerDown = (e: PointerEvent) => {
    if (e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return;
    const target = e.target as HTMLElement | null;
    if (!target || target.closest(".row-action, .launched-toggle, input, textarea, [contenteditable='true']")) return;
    const treeEl = deps.getTreeEl();
    const entry = target.closest<HTMLElement>(".tree-entry");
    if (!entry || !treeEl?.contains(entry) || entry.querySelector("button:disabled")) return;
    const treeId = entry.dataset.treeId;
    if (!treeId) return;
    const sources = deps.resolveSources(treeId);
    const downStep = orbSidebarDragStep({
      phase: 0, eventKind: 0, rowMovable: sources.length > 0,
      targetCollapsed: false, targetAdmitted: false,
      distSq: 0, elapsedMs: 0, springElapsedMs: 0,
      hoverTargetOrd: 0, springTargetOrd: 0, edgeTopDistPx: 999, edgeBottomDistPx: 999,
    });
    if (downStep.nextPhase === 0) {
      if (deps.onQuickTap) {
        const x = e.clientX, y = e.clientY;
        const up = (ev: PointerEvent) => {
          window.removeEventListener("pointerup", up, true);
          window.removeEventListener("pointercancel", up, true);
          if (ev.button === 0 && Math.hypot(ev.clientX - x, ev.clientY - y) < 6) {
            deps.onQuickTap?.(treeId, entry);
          }
        };
        window.addEventListener("pointerup", up, true);
        window.addEventListener("pointercancel", up, true);
      }
      return;
    }
    cleanupActive?.();

    const anchorEl = entry.querySelector<HTMLElement>(".row") ?? entry;
    const startX = e.clientX, startY = e.clientY, startAt = performance.now();
    let curPhase: SidebarDragPhase = downStep.nextPhase;
    let curX = startX, curY = startY;
    let springOrd = 0, springStartedAt = 0;
    let scrollDir: -1 | 0 | 1 = 0, scrollStepPx = 0, rafId = 0;
    let highlighted: HTMLElement | undefined;
    let holdTimer: ReturnType<typeof setTimeout> | undefined;
    let springTimer: ReturnType<typeof setTimeout> | undefined;
    const prevUserSelect = document.body.style.userSelect;
    let lockedSelect = false;

    const clearHighlight = () => { highlighted?.classList.remove("drop-active"); highlighted = undefined; };
    const stopAutoScroll = () => { if (rafId) { cancelAnimationFrame(rafId); rafId = 0; } scrollDir = 0; scrollStepPx = 0; };
    const syncPill = (x: number, y: number) => {
      if (curPhase >= 2) setPill({ label: sources[0]!.label, count: sources.length, x, y });
    };
    const lockSelection = () => {
      if (!lockedSelect) { lockedSelect = true; document.body.style.userSelect = "none"; }
    };
    const suppressNextClick = () => {
      const eat = (ce: MouseEvent) => { ce.preventDefault(); ce.stopPropagation(); };
      window.addEventListener("click", eat, true);
      setTimeout(() => window.removeEventListener("click", eat, true), 0);
    };

    const teardown = () => {
      clearTimeout(holdTimer); clearTimeout(springTimer);
      stopAutoScroll(); clearHighlight();
      if (lockedSelect) { document.body.style.userSelect = prevUserSelect; lockedSelect = false; }
      curPhase = 0; springOrd = 0;
      setPhase(0); setLiftedIds(emptySet); setPill(null);
      window.removeEventListener("pointermove", onMove);
      window.removeEventListener("pointerup", onUp);
      window.removeEventListener("pointercancel", onCancel);
      window.removeEventListener("contextmenu", onContext, true);
      window.removeEventListener("blur", onCancel);
      window.removeEventListener("keydown", onKey, true);
      cleanupActive = undefined;
    };

    const inspectHover = (x: number, y: number) => {
      const hit = deps.resolveTargetAt(x, y);
      const admitted = !!hit && isGroupMoveAdmitted(ords, sources, hit.slug, hit.path);
      const ord = hit ? targetOrdOf(hit.slug, hit.path) : 0;
      const scrollBox = treeEl.closest<HTMLElement>(".sb-scroll")?.getBoundingClientRect();
      const edgeTop = scrollBox ? Math.max(0, Math.floor(y - scrollBox.top)) : 999;
      const edgeBot = scrollBox ? Math.max(0, Math.floor(scrollBox.bottom - y)) : 999;
      return { hit, admitted, ord, collapsed: !!hit?.collapsed, edgeTop, edgeBot };
    };

    const armSpringTimer = (nextSpringOrd: number) => {
      if (nextSpringOrd === springOrd) return;
      clearTimeout(springTimer); springTimer = undefined;
      springOrd = nextSpringOrd;
      if (springOrd !== 0) {
        springStartedAt = performance.now();
        springTimer = setTimeout(onSpringTick, 450);
      }
    };

    const applyMoveVisuals = (hit: DragTargetContainer | undefined, admitted: boolean) => {
      const nextEl = curPhase === 3 && hit && admitted ? hit.element : undefined;
      if (nextEl !== highlighted) {
        clearHighlight();
        highlighted = nextEl;
        highlighted?.classList.add("drop-active");
      }
    };

    const tickAutoScroll = () => {
      rafId = 0;
      if (curPhase !== 3 || scrollDir === 0 || scrollStepPx <= 0) return;
      const scroller = treeEl.closest<HTMLElement>(".sb-scroll");
      if (scroller) scroller.scrollTop += scrollDir * scrollStepPx;
      rafId = requestAnimationFrame(tickAutoScroll);
    };

    const onHoldTick = () => {
      holdTimer = undefined;
      const distSq = Math.round((curX - startX) ** 2 + (curY - startY) ** 2);
      const elapsedMs = Math.max(260, Math.round(performance.now() - startAt));
      const res = orbSidebarDragStep({
        phase: curPhase, eventKind: 1, rowMovable: true,
        targetCollapsed: false, targetAdmitted: false,
        distSq, elapsedMs, springElapsedMs: 0,
        hoverTargetOrd: 0, springTargetOrd: springOrd, edgeTopDistPx: 999, edgeBottomDistPx: 999,
      });
      curPhase = res.nextPhase; setPhase(curPhase);
      if (res.effectCode === 1) {
        lockSelection();
        deps.dismissTooltip();
        setLiftedIds(new Set(sources.map(s => s.treeId)));
        syncPill(curX, curY);
      }
    };

    const onSpringTick = () => {
      springTimer = undefined;
      const h = inspectHover(curX, curY);
      const springElapsedMs = Math.max(450, Math.round(performance.now() - springStartedAt));
      const res = orbSidebarDragStep({
        phase: curPhase, eventKind: 3, rowMovable: true,
        targetCollapsed: h.collapsed, targetAdmitted: h.admitted,
        distSq: Math.round((curX - startX) ** 2 + (curY - startY) ** 2),
        elapsedMs: Math.round(performance.now() - startAt),
        springElapsedMs, hoverTargetOrd: h.ord, springTargetOrd: springOrd,
        edgeTopDistPx: h.edgeTop, edgeBottomDistPx: h.edgeBot,
      });
      curPhase = res.nextPhase; setPhase(curPhase);
      springOrd = res.nextSpringTargetOrd;
      if (res.effectCode === 3 && h.hit) deps.expandContainer(h.hit.slug, h.hit.path);
    };

    const onMove = (me: PointerEvent) => {
      curX = me.clientX; curY = me.clientY;
      const distSq = Math.round((curX - startX) ** 2 + (curY - startY) ** 2);
      const h = inspectHover(curX, curY);
      const res = orbSidebarDragStep({
        phase: curPhase, eventKind: 2, rowMovable: true,
        targetCollapsed: h.collapsed, targetAdmitted: h.admitted,
        distSq, elapsedMs: Math.round(performance.now() - startAt),
        springElapsedMs: springOrd ? Math.round(performance.now() - springStartedAt) : 0,
        hoverTargetOrd: h.ord, springTargetOrd: springOrd,
        edgeTopDistPx: h.edgeTop, edgeBottomDistPx: h.edgeBot,
      });
      curPhase = res.nextPhase; setPhase(curPhase);
      if (res.effectCode === 2) {
        clearTimeout(holdTimer); holdTimer = undefined;
        lockSelection();
        deps.dismissTooltip();
        setLiftedIds(new Set(sources.map(s => s.treeId)));
      }
      if (curPhase >= 2) syncPill(curX, curY);
      applyMoveVisuals(h.hit, h.admitted);
      armSpringTimer(res.nextSpringTargetOrd);
      scrollDir = res.scrollDir; scrollStepPx = res.scrollStepPx;
      if (scrollDir !== 0 && scrollStepPx > 0 && !rafId) rafId = requestAnimationFrame(tickAutoScroll);
      else if ((scrollDir === 0 || scrollStepPx === 0) && rafId) stopAutoScroll();
    };

    const onUp = (ue: PointerEvent) => {
      curX = ue.clientX; curY = ue.clientY;
      const wasPressing = curPhase === 1;
      const distSq = Math.round((curX - startX) ** 2 + (curY - startY) ** 2);
      const h = inspectHover(curX, curY);
      const res = orbSidebarDragStep({
        phase: curPhase, eventKind: 4, rowMovable: true,
        targetCollapsed: h.collapsed, targetAdmitted: h.admitted,
        distSq,
        elapsedMs: Math.round(performance.now() - startAt),
        springElapsedMs: 0, hoverTargetOrd: h.ord, springTargetOrd: springOrd,
        edgeTopDistPx: h.edgeTop, edgeBottomDistPx: h.edgeBot,
      });
      teardown();
      if (res.eatClick) suppressNextClick();
      if (res.effectCode === 4 && h.hit) deps.commitDrop(sources, h.hit.slug, h.hit.path);
      else if (res.effectCode === 5 && anchorEl.isConnected) deps.openMovePicker(sources, anchorEl);
      else if (wasPressing && res.effectCode === 0 && ue.button === 0 && distSq < 36) deps.onQuickTap?.(treeId, entry);
    };

    const onCancel = () => {
      const res = orbSidebarDragStep({
        phase: curPhase, eventKind: 5, rowMovable: true,
        targetCollapsed: false, targetAdmitted: false,
        distSq: 0, elapsedMs: 0, springElapsedMs: 0,
        hoverTargetOrd: 0, springTargetOrd: springOrd, edgeTopDistPx: 999, edgeBottomDistPx: 999,
      });
      if (res.effectCode === 6 || curPhase !== 0) teardown();
    };

    const onContext = () => { if (curPhase >= 1) onCancel(); };
    const onKey = (ke: KeyboardEvent) => {
      if (ke.key === "Escape" && curPhase >= 2) {
        ke.preventDefault(); ke.stopPropagation();
        onCancel();
      } else if (ke.key === "Escape" && curPhase === 1) {
        onCancel();
      }
    };

    setPhase(curPhase);
    holdTimer = setTimeout(onHoldTick, 260);
    cleanupActive = teardown;
    window.addEventListener("pointermove", onMove);
    window.addEventListener("pointerup", onUp);
    window.addEventListener("pointercancel", onCancel);
    window.addEventListener("contextmenu", onContext, true);
    window.addEventListener("blur", onCancel);
    window.addEventListener("keydown", onKey, true);
  };

  return {
    ords,
    phase,
    isLifted: (treeId: string) => liftedIds().has(treeId),
    pill,
    onPointerDown,
    cancel: () => cleanupActive?.(),
  };
}
