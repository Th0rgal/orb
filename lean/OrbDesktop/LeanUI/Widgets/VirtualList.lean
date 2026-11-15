import LeanUI.Defs
import LeanUI.Kernel
import LeanUI.Style
import LeanUI.Layout
import LeanUI.Scene
/-!
# LeanUI.Widgets.VirtualList — Variable-Height Virtualized List (`0` FFI)

Pure variable-height virtualized list anchored via `Kernel.scrollLimit` / `Kernel.scrollStep`
and `ScrollSpec`. Computes the visible item slice
`(firstIdx, lastIdx, topSpacerSub, bottomSpacerSub, visibleItems)` and constructs a
`WidgetNode.scrollClip` tree so large transcripts only lay out visible cards while
preserving exact scroll geometry and bottom-pinned follow mode.
-/
namespace LeanUI.Widgets

/-- Clamp a scroll offset `offsetSub` into `[0, scrollLimit contentSub viewportSub]`
using `Kernel.scrollStep` and `Kernel.scrollLimit`. -/
@[inline] def clampScrollOffset (contentSub viewportSub offsetSub : SubPx) : SubPx :=
  let lim := scrollLimit contentSub viewportSub
  min lim (scrollStep contentSub viewportSub (min offsetSub lim) 0)

/-- Metadata for a single variable-height item in a virtualized list. -/
structure VirtualItemMeta (α : Type) where
  id : EntityId
  estimatedHeightSub : SubPx
  measuredHeightSub : Option SubPx := none
  payload : α
  deriving Repr, Inhabited

namespace VirtualItemMeta

/-- Effective item height in `SubPx` (`measuredHeightSub` if available, else `estimatedHeightSub`). -/
@[inline] def effectiveHeightSub {α : Type} (item : VirtualItemMeta α) : SubPx :=
  max (pxToSub 1) (item.measuredHeightSub.getD item.estimatedHeightSub)

end VirtualItemMeta

/-- Positioned virtual item within the full vertical list coordinate space. -/
structure PositionedVirtualItem (α : Type) where
  index : Nat
  topSub : SubPx
  heightSub : SubPx
  item : VirtualItemMeta α
  deriving Repr, Inhabited

namespace PositionedVirtualItem

@[inline] def bottomSub {α : Type} (p : PositionedVirtualItem α) : SubPx :=
  p.topSub + p.heightSub

end PositionedVirtualItem

/-- Computed visible window slice of a variable-height virtualized list. -/
structure VirtualWindow (α : Type) where
  firstIdx : Nat
  lastIdx : Nat
  topSpacerSub : SubPx
  bottomSpacerSub : SubPx
  totalContentHeightSub : SubPx
  clampedOffsetY : SubPx
  pinnedToBottom : Bool
  visibleItems : List (PositionedVirtualItem α)
  deriving Repr, Inhabited

/-- Configuration for a variable-height `VirtualList`. -/
structure VirtualListConfig where
  viewportWidthSub : SubPx
  viewportHeightSub : SubPx
  itemGapSub : SubPx := pxToSub 12
  padding : Edges := Edges.all (pxToSub 16)
  overscanSub : SubPx := pxToSub 96
  pinnedToBottom : Bool := false
  scrollWidgetId : Option WidgetId := some 200
  deriving DecidableEq, Repr, Inhabited

/-- Place a list of `VirtualItemMeta` sequentially top-to-bottom with `gapSub` spacing. -/
def placeVirtualItems {α : Type} (gapSub : SubPx) :
    Nat → SubPx → List (VirtualItemMeta α) → List (PositionedVirtualItem α) × SubPx
  | _, curY, [] => ([], curY)
  | idx, curY, it :: rest =>
    let h := it.effectiveHeightSub
    let pos : PositionedVirtualItem α := {
      index := idx
      topSub := curY
      heightSub := h
      item := it
    }
    let nextY := if rest.isEmpty then curY + h else curY + h + gapSub
    let (tail, totalH) := placeVirtualItems gapSub (idx + 1) nextY rest
    (pos :: tail, totalH)

/-- Compute the visible item slice `(firstIdx, lastIdx, topSpacerSub, bottomSpacerSub, visibleItems)`
for a given `rawOffsetY` and `VirtualListConfig`. -/
def computeVirtualWindow {α : Type} (cfg : VirtualListConfig) (rawOffsetY : SubPx)
    (items : List (VirtualItemMeta α)) : VirtualWindow α :=
  let (placed, bodyHeightSub) := placeVirtualItems cfg.itemGapSub 0 0 items
  let totalContentH := bodyHeightSub + cfg.padding.vertical
  let maxScroll := scrollLimit totalContentH cfg.viewportHeightSub
  let targetOffset :=
    if cfg.pinnedToBottom then maxScroll
    else clampScrollOffset totalContentH cfg.viewportHeightSub rawOffsetY
  let isAtBottom := targetOffset >= maxScroll
  let winTop : SubPx := targetOffset - min targetOffset cfg.overscanSub
  let winBottom : SubPx := targetOffset + cfg.viewportHeightSub + cfg.overscanSub
  let visible := placed.filter fun p =>
    let itemStart := cfg.padding.top + p.topSub
    let itemEnd := cfg.padding.top + p.bottomSub
    itemEnd >= winTop && itemStart <= winBottom
  match visible with
  | [] =>
    { firstIdx := 0
      lastIdx := 0
      topSpacerSub := bodyHeightSub
      bottomSpacerSub := 0
      totalContentHeightSub := totalContentH
      clampedOffsetY := targetOffset
      pinnedToBottom := isAtBottom
      visibleItems := [] }
  | first :: _ =>
    let last := visible.getLastD first
    let topSpacer := first.topSub
    let bottomSpacer := bodyHeightSub - last.bottomSub
    { firstIdx := first.index
      lastIdx := last.index
      topSpacerSub := topSpacer
      bottomSpacerSub := bottomSpacer
      totalContentHeightSub := totalContentH
      clampedOffsetY := targetOffset
      pinnedToBottom := isAtBottom
      visibleItems := visible }

/-- Step a `VirtualList` vertical scroll state by `deltaY` (in `SubPx`), updating
`pinnedToBottom` automatically when reaching or leaving the bottom boundary. -/
def stepVirtualScroll {α : Type} (cfg : VirtualListConfig) (currentOffsetY : SubPx)
    (deltaY : Int) (items : List (VirtualItemMeta α)) : SubPx × Bool :=
  let (_, bodyHeightSub) := placeVirtualItems cfg.itemGapSub 0 0 items
  let totalContentH := bodyHeightSub + cfg.padding.vertical
  let maxScroll := scrollLimit totalContentH cfg.viewportHeightSub
  let nextOffset := min maxScroll (scrollStep totalContentH cfg.viewportHeightSub currentOffsetY deltaY)
  (nextOffset, nextOffset >= maxScroll)

/-- Build a `WidgetNode.scrollClip` tree for a variable-height virtualized list.
Only `window.visibleItems` are instantiated via `renderItem`; `topSpacerSub` and
`bottomSpacerSub` preserve exact scroll geometry. -/
def buildVirtualListWidget {α : Type} (theme : Theme) (cfg : VirtualListConfig)
    (rawOffsetY : SubPx) (items : List (VirtualItemMeta α))
    (renderItem : PositionedVirtualItem α → WidgetNode) :
    VirtualWindow α × WidgetNode :=
  let pal := theme.palette
  let win := computeVirtualWindow cfg rawOffsetY items
  let innerW := cfg.viewportWidthSub - cfg.padding.horizontal
  let topSpacerList : List WidgetNode :=
    if win.topSpacerSub > 0 then
      [WidgetNode.box (BoxStyle.col 0 |>.withFixedSize innerW win.topSpacerSub)]
    else []
  let bottomSpacerList : List WidgetNode :=
    if win.bottomSpacerSub > 0 then
      [WidgetNode.box (BoxStyle.col 0 |>.withFixedSize innerW win.bottomSpacerSub)]
    else []
  let renderedVisible : List WidgetNode := win.visibleItems.map renderItem
  -- Note: when spacers are included, compensate for the extra gap between spacer and items
  -- by using an inner visible-items column with `cfg.itemGapSub` inside an outer 0-gap column.
  let visibleColumn : WidgetNode :=
    WidgetNode.box
      (BoxStyle.col cfg.itemGapSub)
      renderedVisible
  let trackChildren : List WidgetNode :=
    topSpacerList ++ [visibleColumn] ++ bottomSpacerList
  let contentTrack : WidgetNode :=
    WidgetNode.box
      (BoxStyle.col 0
        |>.withPadding cfg.padding
        |>.withFixedSize cfg.viewportWidthSub win.totalContentHeightSub)
      trackChildren
  let scrollSpec : ScrollSpec := {
    offsetX := 0
    offsetY := win.clampedOffsetY
    contentWidth := cfg.viewportWidthSub
    contentHeight := win.totalContentHeightSub
  }
  let scrollNode : WidgetNode :=
    WidgetNode.scrollClip
      (BoxStyle.col 0
        |>.withFixedSize cfg.viewportWidthSub cfg.viewportHeightSub
        |>.withBg pal.canvas)
      scrollSpec
      contentTrack
      cfg.scrollWidgetId
  (win, scrollNode)

end LeanUI.Widgets
