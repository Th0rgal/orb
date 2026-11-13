import LeanUI.Defs
import LeanUI.Kernel
import LeanUI.Style
import LeanUI.Layout
import LeanUI.Scene
/-!
# LeanUI.Widgets.Overlays — Modal `Dialog`, `Field`, `Select`, `Tooltip`, `Toast`, and `SearchDialog` (`0` FFI)

Pure declarative overlay and form control widgets:
- `Field` (labeled text input with validation error state & focus ring)
- `Select` (dropdown trigger + option popup list)
- `Tooltip` (floating rounded pill with elevation shadow)
- `Toast` (status notification card: `info`, `success`, `warning`, `error`)
- `Dialog` (modal dialog with backdrop scrim, elevation shadow, and focusable action buttons)
- `SearchDialog` (command palette / quick-switcher with active filter query, keyboard selection, and modal focus trap IDs)
-/
namespace LeanUI.Widgets

/-- Deterministic fallback `InlineRun` synthesizer for overlay labels and inputs. -/
@[inline] def overlaySynthRun (style : TextStyle) (text : String) : InlineRun :=
  let charAdv : SubPx := max (6 * subPerPx) (style.sizeSub / 2)
  let glyphs : List ShapedGlyph :=
    text.toList.mapIdx fun idx c => {
      glyphId := c.toNat
      cluster := idx
      xAdvance := charAdv
    }
  { glyphs := glyphs, style := style, allowBreakAfter := false, hardBreakAfter := false }

/-- Specification for a labeled form `Field`. -/
structure FieldSpec where
  id : WidgetId
  label : String
  value : String := ""
  placeholder : String := ""
  errorText : Option String := none
  disabled : Bool := false
  deriving DecidableEq, Repr, Inhabited

/-- Option item inside a `Select` dropdown. -/
structure SelectOption where
  value : String
  label : String
  optionWidgetId : WidgetId
  deriving DecidableEq, Repr, Inhabited

/-- Specification for a `Select` dropdown control. -/
structure SelectSpec where
  triggerId : WidgetId
  label : String := ""
  options : List SelectOption := []
  selectedIdx : Nat := 0
  isOpen : Bool := false
  deriving DecidableEq, Repr, Inhabited

/-- Specification for a `Tooltip` overlay. -/
structure TooltipSpec where
  text : String
  shortcutHint : String := ""
  deriving DecidableEq, Repr, Inhabited

/-- Semantic severity level for a `Toast` notification. -/
inductive ToastKind where
  | info
  | success
  | warning
  | error
  deriving DecidableEq, Repr, Inhabited

/-- Specification for a `Toast` notification banner. -/
structure ToastSpec where
  id : WidgetId
  kind : ToastKind := .info
  title : String
  message : String := ""
  dismissButtonId : Option WidgetId := none
  deriving DecidableEq, Repr, Inhabited

/-- Specification for a modal `Dialog`. -/
structure DialogSpec where
  dialogId : WidgetId
  title : String
  description : String := ""
  confirmLabel : String := "Confirm"
  cancelLabel : String := "Cancel"
  confirmButtonId : WidgetId
  cancelButtonId : WidgetId
  dangerConfirm : Bool := false
  deriving DecidableEq, Repr, Inhabited

/-- A single searchable command/mission item in a `SearchDialog`. -/
structure SearchItem where
  widgetId : WidgetId
  title : String
  subtitle : String := ""
  category : String := ""
  shortcut : String := ""
  deriving DecidableEq, Repr, Inhabited

/-- Specification for a modal `SearchDialog` (command palette / mission switcher). -/
structure SearchDialogSpec where
  inputWidgetId : WidgetId
  query : String := ""
  placeholder : String := "Search missions, commands, or files..."
  items : List SearchItem := []
  selectedIdx : Nat := 0
  deriving DecidableEq, Repr, Inhabited

/-- Build a labeled form `Field` widget with focusable input box and optional validation message. -/
def buildFieldWidget (theme : Theme) (availW : SubPx) (spec : FieldSpec) : WidgetNode :=
  let pal := theme.palette
  let labelH : SubPx := pxToSub 18
  let inputH : SubPx := pxToSub 34
  let borderCol :=
    match spec.errorText with
    | some _ => pal.danger
    | none   => pal.border
  let labelNode : WidgetNode :=
    WidgetNode.text
      (BoxStyle.row 0 |>.withFixedSize availW labelH)
      theme.typo.lineTight
      [overlaySynthRun (Theme.secondaryText theme) spec.label]
  let displayStr := if spec.value.isEmpty then spec.placeholder else spec.value
  let textCol := if spec.value.isEmpty then pal.textMuted else pal.textPrimary
  let inputTextStyle : TextStyle := { (Theme.bodyText theme) with color := textCol }
  let inputBoxRaw : WidgetNode :=
    WidgetNode.rrect
      (BoxStyle.row 0
        |>.withAlign .center
        |>.withPadding (Edges.xy (pxToSub 10) (pxToSub 6))
        |>.withFixedSize availW inputH)
      pal.surface
      (CornerRadii.uniform theme.radiusSm)
      (BorderStyle.uniform theme.borderWidth borderCol)
      [WidgetNode.text
        (BoxStyle.row 0 |>.withFixedSize (availW - pxToSub 20) (pxToSub 20))
        theme.typo.lineBase
        [overlaySynthRun inputTextStyle displayStr]]
      (some spec.id)
  let inputBox :=
    if spec.disabled then inputBoxRaw
    else WidgetNode.focusable spec.id inputBoxRaw
  match spec.errorText with
  | none =>
    WidgetNode.box
      (BoxStyle.col (pxToSub 4) |>.withFixedSize availW (labelH + inputH + pxToSub 4))
      [labelNode, inputBox]
  | some err =>
    let errStyle : TextStyle := { (Theme.mutedText theme) with color := pal.danger }
    let errNode : WidgetNode :=
      WidgetNode.text
        (BoxStyle.row 0 |>.withFixedSize availW (pxToSub 16))
        theme.typo.lineTight
        [overlaySynthRun errStyle err]
    WidgetNode.box
      (BoxStyle.col (pxToSub 4) |>.withFixedSize availW (labelH + inputH + pxToSub 24))
      [labelNode, inputBox, errNode]

/-- Build a `Select` dropdown widget (trigger button + expanded menu when `spec.isOpen = true`). -/
def buildSelectWidget (theme : Theme) (availW : SubPx) (spec : SelectSpec) : WidgetNode :=
  let pal := theme.palette
  let triggerH : SubPx := pxToSub 34
  let selectedLabel :=
    match spec.options[spec.selectedIdx]? with
    | some opt => opt.label
    | none => "Select..."
  let triggerTextStyle := Theme.bodyText theme
  let caretStyle := Theme.mutedText theme
  let triggerNode : WidgetNode :=
    WidgetNode.focusable spec.triggerId <|
      WidgetNode.rrect
        (BoxStyle.row (pxToSub 8)
          |>.withAlign .center
          |>.withJustify .spaceBetween
          |>.withPadding (Edges.xy (pxToSub 10) (pxToSub 6))
          |>.withFixedSize availW triggerH)
        pal.surface
        (CornerRadii.uniform theme.radiusSm)
        (BorderStyle.uniform theme.borderWidth pal.border)
        [ WidgetNode.text
            (BoxStyle.row 0 |>.withFixedSize (availW - pxToSub 44) (pxToSub 20))
            theme.typo.lineBase
            [overlaySynthRun triggerTextStyle selectedLabel]
        , WidgetNode.text
            (BoxStyle.row 0 |>.withFixedSize (pxToSub 16) (pxToSub 16))
            theme.typo.lineTight
            [overlaySynthRun caretStyle (if spec.isOpen then "▴" else "▾")]
        ]
  if !spec.isOpen then
    triggerNode
  else
    let optH : SubPx := pxToSub 30
    let menuH : SubPx := max optH (spec.options.length * optH + pxToSub 8)
    let optRows : List WidgetNode :=
      spec.options.mapIdx fun idx opt =>
        let isSelected := idx == spec.selectedIdx
        let rowBg := if isSelected then pal.accentMuted else pal.elevatedSurface
        let rowFg := if isSelected then pal.accent else pal.textPrimary
        let optStyle : TextStyle := { (Theme.bodyText theme) with color := rowFg }
        WidgetNode.focusable opt.optionWidgetId <|
          WidgetNode.rrect
            (BoxStyle.row 0
              |>.withAlign .center
              |>.withPadding (Edges.xy (pxToSub 10) (pxToSub 4))
              |>.withFixedSize (availW - pxToSub 8) optH)
            rowBg
            (CornerRadii.uniform theme.radiusSm)
            BorderStyle.none
            [WidgetNode.text
              (BoxStyle.row 0 |>.withFixedSize (availW - pxToSub 28) (pxToSub 18))
              theme.typo.lineTight
              [overlaySynthRun optStyle opt.label]]
    let menuShadow : ShadowStyle := {
      offsetX := 0
      offsetY := Int.ofNat (pxToSub 4)
      blur := pxToSub 10
      spread := 0
      color := pal.shadowColor
    }
    let menuBox : WidgetNode :=
      WidgetNode.box
        (BoxStyle.col 0
          |>.withPadding (Edges.all (pxToSub 4))
          |>.withFixedSize availW menuH
          |>.withBg pal.elevatedSurface
          |>.withRadius theme.radiusMd
          |>.withBorder theme.borderWidth pal.border
          |>.withShadow menuShadow)
        optRows
    WidgetNode.box
      (BoxStyle.col (pxToSub 4) |>.withFixedSize availW (triggerH + menuH + pxToSub 4))
      [triggerNode, menuBox]

/-- Build a floating `Tooltip` pill widget with elevation shadow. -/
def buildTooltipWidget (theme : Theme) (spec : TooltipSpec) : WidgetNode :=
  let pal := theme.palette
  let labelStyle := Theme.secondaryText theme
  let hintStyle := Theme.mutedText theme
  let textLen := spec.text.length + spec.shortcutHint.length
  let pillW : SubPx := pxToSub (max 80 (textLen * 7 + 24))
  let pillH : SubPx := pxToSub 28
  let sh : ShadowStyle := {
    offsetX := 0
    offsetY := Int.ofNat (pxToSub 2)
    blur := pxToSub 6
    spread := 0
    color := pal.shadowColor
  }
  let contentRuns :=
    if spec.shortcutHint.isEmpty then
      [overlaySynthRun labelStyle spec.text]
    else
      [overlaySynthRun labelStyle (spec.text ++ "  "), overlaySynthRun hintStyle spec.shortcutHint]
  WidgetNode.box
    (BoxStyle.row 0
      |>.withAlign .center
      |>.withPadding (Edges.xy (pxToSub 10) (pxToSub 5))
      |>.withFixedSize pillW pillH
      |>.withBg pal.elevatedSurface
      |>.withRadius theme.radiusSm
      |>.withBorder theme.borderWidth pal.border
      |>.withShadow sh)
    [WidgetNode.text
      (BoxStyle.row 0 |>.withFixedSize (pillW - pxToSub 20) (pxToSub 18))
      theme.typo.lineTight
      contentRuns]

/-- Accent border color for a `ToastKind`. -/
@[inline] def toastAccentColor (pal : Palette) : ToastKind → Color
  | .info    => pal.accent
  | .success => pal.success
  | .warning => pal.warning
  | .error   => pal.danger

/-- Build a `Toast` notification banner widget with accent border and optional dismiss button. -/
def buildToastWidget (theme : Theme) (availW : SubPx) (spec : ToastSpec) : WidgetNode :=
  let pal := theme.palette
  let toastH : SubPx := if spec.message.isEmpty then pxToSub 40 else pxToSub 58
  let accentCol := toastAccentColor pal spec.kind
  let titleStyle : TextStyle := { (Theme.bodyText theme) with weight := 600 }
  let msgStyle := Theme.secondaryText theme
  let textW := availW - pxToSub 56
  let textChildren : List WidgetNode :=
    if spec.message.isEmpty then
      [WidgetNode.text (BoxStyle.row 0 |>.withFixedSize textW (pxToSub 20)) theme.typo.lineBase
        [overlaySynthRun titleStyle spec.title]]
    else
      [ WidgetNode.text (BoxStyle.row 0 |>.withFixedSize textW (pxToSub 20)) theme.typo.lineBase
          [overlaySynthRun titleStyle spec.title]
      , WidgetNode.text (BoxStyle.row 0 |>.withFixedSize textW (pxToSub 18)) theme.typo.lineTight
          [overlaySynthRun msgStyle spec.message]
      ]
  let textCol : WidgetNode :=
    WidgetNode.box
      (BoxStyle.col (pxToSub 2) |>.withFixedSize textW (toastH - pxToSub 16))
      textChildren
  let rowChildren : List WidgetNode :=
    match spec.dismissButtonId with
    | none => [textCol]
    | some btnId =>
      let dismissBtn :=
        WidgetNode.focusable btnId <|
          WidgetNode.rrect
            (BoxStyle.row 0 |>.withAlign .center |>.withJustify .center |>.withFixedSize (pxToSub 24) (pxToSub 24))
            pal.surface
            (CornerRadii.uniform theme.radiusSm)
            (BorderStyle.uniform theme.borderWidth pal.borderSubtle)
            [WidgetNode.text (BoxStyle.row 0 |>.withFixedSize (pxToSub 12) (pxToSub 14)) theme.typo.lineTight
              [overlaySynthRun (Theme.mutedText theme) "×"]]
      [textCol, dismissBtn]
  let sh : ShadowStyle := {
    offsetX := 0
    offsetY := Int.ofNat (pxToSub 4)
    blur := pxToSub 10
    spread := 0
    color := pal.shadowColor
  }
  WidgetNode.box
    (BoxStyle.row (pxToSub 8)
      |>.withAlign .center
      |>.withJustify .spaceBetween
      |>.withPadding (Edges.xy (pxToSub 12) (pxToSub 8))
      |>.withFixedSize availW toastH
      |>.withBg pal.elevatedSurface
      |>.withRadius theme.radiusMd
      |>.withBorder theme.borderWidth accentCol
      |>.withShadow sh)
    rowChildren
    (some spec.id)

/-- Return the modal focus trap `List EntityId` for a `DialogSpec`. -/
@[inline] def dialogTrapIds (spec : DialogSpec) : List EntityId :=
  [spec.cancelButtonId, spec.confirmButtonId]

/-- Build a modal `Dialog` widget with semi-transparent backdrop scrim, elevation shadow,
and focusable Cancel / Confirm buttons. -/
def buildDialogWidget (theme : Theme) (viewportW viewportH : SubPx)
    (spec : DialogSpec) (bodyChildren : List WidgetNode := []) : WidgetNode :=
  let pal := theme.palette
  let dialogW : SubPx := min (pxToSub 460) (viewportW - pxToSub 40)
  let innerW : SubPx := dialogW - pxToSub 32
  let dialogH : SubPx := pxToSub (168 + bodyChildren.length * 40)
  let titleNode : WidgetNode :=
    WidgetNode.text
      (BoxStyle.row 0 |>.withFixedSize innerW (pxToSub 24))
      theme.typo.lineHeading
      [overlaySynthRun (Theme.headingText theme) spec.title]
  let descNode : WidgetNode :=
    WidgetNode.text
      (BoxStyle.row 0 |>.withFixedSize innerW (pxToSub 36))
      theme.typo.lineBase
      [overlaySynthRun (Theme.secondaryText theme) spec.description]
  let cancelBtn : WidgetNode :=
    WidgetNode.focusable spec.cancelButtonId <|
      WidgetNode.rrect
        (BoxStyle.row 0
          |>.withAlign .center
          |>.withJustify .center
          |>.withPadding (Edges.xy (pxToSub 14) (pxToSub 6))
          |>.withFixedSize (pxToSub 88) (pxToSub 34))
        pal.surface
        (CornerRadii.uniform theme.radiusSm)
        (BorderStyle.uniform theme.borderWidth pal.border)
        [WidgetNode.text (BoxStyle.row 0 |>.withFixedSize (pxToSub 60) (pxToSub 18)) theme.typo.lineBase
          [overlaySynthRun (Theme.bodyText theme) spec.cancelLabel]]
  let confirmBg := if spec.dangerConfirm then pal.danger else pal.accent
  let confirmBtn : WidgetNode :=
    WidgetNode.focusable spec.confirmButtonId <|
      WidgetNode.rrect
        (BoxStyle.row 0
          |>.withAlign .center
          |>.withJustify .center
          |>.withPadding (Edges.xy (pxToSub 14) (pxToSub 6))
          |>.withFixedSize (pxToSub 96) (pxToSub 34))
        confirmBg
        (CornerRadii.uniform theme.radiusSm)
        BorderStyle.none
        [WidgetNode.text (BoxStyle.row 0 |>.withFixedSize (pxToSub 68) (pxToSub 18)) theme.typo.lineBase
          [overlaySynthRun { (Theme.bodyText theme) with weight := 600 } spec.confirmLabel]]
  let footerRow : WidgetNode :=
    WidgetNode.box
      (BoxStyle.row (pxToSub 10)
        |>.withAlign .center
        |>.withJustify .end_
        |>.withFixedSize innerW (pxToSub 38))
      [cancelBtn, confirmBtn]
  let sh : ShadowStyle := {
    offsetX := 0
    offsetY := Int.ofNat (pxToSub 8)
    blur := pxToSub 20
    spread := 0
    color := pal.shadowColor
  }
  let dialogCard : WidgetNode :=
    WidgetNode.box
      (BoxStyle.col (pxToSub 12)
        |>.withPadding (Edges.all (pxToSub 16))
        |>.withFixedSize dialogW dialogH
        |>.withBg pal.elevatedSurface
        |>.withRadius theme.radiusLg
        |>.withBorder theme.borderWidth pal.border
        |>.withShadow sh)
      ([titleNode, descNode] ++ bodyChildren ++ [footerRow])
      (some spec.dialogId)
  WidgetNode.box
    (BoxStyle.row 0
      |>.withAlign .center
      |>.withJustify .center
      |>.withFixedSize viewportW viewportH
      |>.withBg 0x00000088)
    [dialogCard]

/-- Case-insensitive substring containment check for filtering `SearchDialog` items. -/
def containsSubstrCI (haystack needle : String) : Bool :=
  if needle.isEmpty then true
  else
    let h := haystack.toLower.toList
    let n := needle.toLower.toList
    let rec startsWith : List Char → List Char → Bool
      | _, [] => true
      | [], _ :: _ => false
      | c1 :: r1, c2 :: r2 => c1 == c2 && startsWith r1 r2
    let rec loop : List Char → Bool
      | [] => false
      | c :: rest => startsWith (c :: rest) n || loop rest
    loop h

/-- Filter `SearchDialogSpec.items` by `spec.query` matching `title`, `subtitle`, or `category`. -/
def filterSearchItems (spec : SearchDialogSpec) : List SearchItem :=
  if spec.query.isEmpty then spec.items
  else
    spec.items.filter fun it =>
      containsSubstrCI it.title spec.query ||
      containsSubstrCI it.subtitle spec.query ||
      containsSubstrCI it.category spec.query

/-- Compute the modal focus trap `List EntityId` for a `SearchDialogSpec`
(search input widget ID followed by all visible filtered item widget IDs). -/
def searchDialogTrapIds (spec : SearchDialogSpec) : List EntityId :=
  let visible := filterSearchItems spec
  spec.inputWidgetId :: visible.map (·.widgetId)

/-- Build a `SearchDialog` (command palette / mission quick-switcher) widget with active filter query,
keyboard selection highlight, shortcut badges, and elevation shadow. -/
def buildSearchDialogWidget (theme : Theme) (cardW : SubPx) (spec : SearchDialogSpec) : WidgetNode :=
  let pal := theme.palette
  let visibleItems := filterSearchItems spec
  let inputH : SubPx := pxToSub 40
  let itemH : SubPx := pxToSub 38
  let listH : SubPx := max itemH (visibleItems.length * itemH + pxToSub 8)
  let totalH : SubPx := inputH + listH + pxToSub 16
  let innerW : SubPx := cardW - pxToSub 16

  let queryDisplay := if spec.query.isEmpty then spec.placeholder else spec.query
  let queryColor := if spec.query.isEmpty then pal.textMuted else pal.textPrimary
  let queryStyle : TextStyle := { (Theme.bodyText theme) with color := queryColor }
  let inputBar : WidgetNode :=
    WidgetNode.focusable spec.inputWidgetId <|
      WidgetNode.rrect
        (BoxStyle.row (pxToSub 8)
          |>.withAlign .center
          |>.withPadding (Edges.xy (pxToSub 12) (pxToSub 8))
          |>.withFixedSize innerW inputH)
        pal.surface
        (CornerRadii.uniform theme.radiusSm)
        (BorderStyle.uniform theme.borderWidth pal.accent)
        [WidgetNode.text
          (BoxStyle.row 0 |>.withFixedSize (innerW - pxToSub 24) (pxToSub 20))
          theme.typo.lineBase
          [overlaySynthRun queryStyle ("⌕ " ++ queryDisplay)]]

  let itemNodes : List WidgetNode :=
    visibleItems.mapIdx fun idx it =>
      let isSelected := idx == spec.selectedIdx
      let rowBg := if isSelected then pal.accentMuted else pal.elevatedSurface
      let rowBorder :=
        if isSelected then BorderStyle.uniform theme.borderWidth pal.accent
        else BorderStyle.none
      let titleStyle : TextStyle := {
        (Theme.bodyText theme) with
        weight := if isSelected then 600 else 400
        color := pal.textPrimary
      }
      let subStyle := Theme.mutedText theme
      let labelRuns :=
        if it.subtitle.isEmpty then [overlaySynthRun titleStyle it.title]
        else [overlaySynthRun titleStyle (it.title ++ "  "), overlaySynthRun subStyle it.subtitle]
      let leftText :=
        WidgetNode.text
          (BoxStyle.row 0 |>.withFixedSize (innerW - pxToSub 92) (pxToSub 20))
          theme.typo.lineBase
          labelRuns
      let rightBadge :=
        WidgetNode.rrect
          (BoxStyle.row 0
            |>.withAlign .center
            |>.withJustify .center
            |>.withFixedSize (pxToSub 64) (pxToSub 22))
          pal.surface
          (CornerRadii.uniform theme.radiusSm)
          (BorderStyle.uniform theme.borderWidth pal.borderSubtle)
          [WidgetNode.text
            (BoxStyle.row 0 |>.withFixedSize (pxToSub 52) (pxToSub 16))
            theme.typo.lineTight
            [overlaySynthRun subStyle (if it.shortcut.isEmpty then it.category else it.shortcut)]]
      WidgetNode.focusable it.widgetId <|
        WidgetNode.rrect
          (BoxStyle.row (pxToSub 8)
            |>.withAlign .center
            |>.withJustify .spaceBetween
            |>.withPadding (Edges.xy (pxToSub 10) (pxToSub 6))
            |>.withFixedSize innerW itemH)
          rowBg
          (CornerRadii.uniform theme.radiusSm)
          rowBorder
          [leftText, rightBadge]

  let sh : ShadowStyle := {
    offsetX := 0
    offsetY := Int.ofNat (pxToSub 6)
    blur := pxToSub 16
    spread := 0
    color := pal.shadowColor
  }
  WidgetNode.box
    (BoxStyle.col (pxToSub 6)
      |>.withPadding (Edges.all (pxToSub 8))
      |>.withFixedSize cardW totalH
      |>.withBg pal.elevatedSurface
      |>.withRadius theme.radiusLg
      |>.withBorder theme.borderWidth pal.border
      |>.withShadow sh)
    (inputBar :: itemNodes)

end LeanUI.Widgets
