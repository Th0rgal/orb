import LeanUI.Defs
import LeanUI.Kernel
import LeanUI.Style
import LeanUI.Layout
import LeanUI.Scene
/-!
# LeanUI.Widgets.Composer — Multi-Line Composer Buffer, Undo/Redo, IME Preedit, Attachments & Drag-Drop (`0` FFI)

Pure multi-line composer state machine and widget builder supporting:
- `ComposerBuffer` with cursor character offset, bounded undo/redo stack (`maxUndoDepth`),
  and Wayland `zwp-text-input-v3` IME preedit span (`imePreeditOffset`, `imePreeditLen`, `imePreeditText`)
- Atomic `applyImeBatch` matching `Event.imeBatch` protocol order (`delBefore`/`delAfter`, `commit`, `preedit`)
- Attachment chips (`ComposerAttachment`) with focusable remove buttons and drag-and-drop hover state (`dragHoverActive`)
- Focusable `WidgetNode` builder with `Kernel.focusBorder`
-/
namespace LeanUI.Widgets

/-- Snapshot of the editable text and cursor offset stored on the undo/redo stacks. -/
structure ComposerSnapshot where
  text : String
  cursorOffset : Nat
  deriving DecidableEq, Repr, Inhabited

/-- Attachment chip attached to a composer message draft. -/
structure ComposerAttachment where
  id : Nat
  fileName : String
  mimeType : String := "text/plain"
  sizeBytes : Nat := 0
  removeButtonId : Option WidgetId := none
  deriving DecidableEq, Repr, Inhabited

/-- Multi-line composer state with cursor offset, bounded undo/redo stacks, IME preedit span,
attachment chips, and drag-and-drop hover indicator. -/
structure ComposerBuffer where
  text : String := ""
  cursorOffset : Nat := 0
  undoStack : List ComposerSnapshot := []
  redoStack : List ComposerSnapshot := []
  maxUndoDepth : Nat := 64
  imePreeditOffset : Nat := 0
  imePreeditLen : Nat := 0
  imePreeditText : String := ""
  attachments : List ComposerAttachment := []
  dragHoverActive : Bool := false
  composerWidgetId : WidgetId := 1
  sendButtonId : Option WidgetId := some 2
  attachButtonId : Option WidgetId := some 3
  /-- A running turn exposes Stop even with an empty follow-up draft. -/
  isRunning : Bool := false
  placeholder : String := "Reply to mission or press Tab to cycle focus..."
  deriving DecidableEq, Repr, Inhabited

namespace ComposerBuffer

/-- Clamp `cursorOffset` into `[0, text.length]`. -/
@[inline] def clampCursor (text : String) (off : Nat) : Nat :=
  min off text.length

/-- Record the current `(text, cursorOffset)` onto `undoStack` (bounded by `maxUndoDepth`) and clear `redoStack`. -/
def pushUndoSnapshot (buf : ComposerBuffer) : ComposerBuffer :=
  let snap : ComposerSnapshot := { text := buf.text, cursorOffset := buf.cursorOffset }
  let nextUndo := (snap :: buf.undoStack).take (max 1 buf.maxUndoDepth)
  { buf with undoStack := nextUndo, redoStack := [] }

/-- Insert committed UTF-8 text at `cursorOffset` and advance the cursor. -/
def insertText (buf : ComposerBuffer) (inserted : String) : ComposerBuffer :=
  if inserted.isEmpty then buf
  else
    let b := buf.pushUndoSnapshot
    let chars := b.text.toList
    let cur := clampCursor b.text b.cursorOffset
    let before := chars.take cur
    let after := chars.drop cur
    let insChars := inserted.toList
    let nextText := String.ofList (before ++ insChars ++ after)
    let nextCursor := cur + insChars.length
    { b with
      text := nextText
      cursorOffset := nextCursor
      imePreeditOffset := nextCursor
      imePreeditLen := 0
      imePreeditText := "" }

/-- Delete `delBefore` characters before `cursorOffset` and `delAfter` characters after `cursorOffset`. -/
def deleteAroundCursor (buf : ComposerBuffer) (delBefore delAfter : Nat) : ComposerBuffer :=
  if delBefore == 0 && delAfter == 0 then buf
  else
    let b := buf.pushUndoSnapshot
    let chars := b.text.toList
    let cur := clampCursor b.text b.cursorOffset
    let keepBeforeCount := cur - min cur delBefore
    let before := chars.take keepBeforeCount
    let after := chars.drop (cur + delAfter)
    let nextText := String.ofList (before ++ after)
    { b with
      text := nextText
      cursorOffset := keepBeforeCount
      imePreeditOffset := keepBeforeCount }

/-- Set or clear the active IME preedit composition string at `cursorOffset`. -/
def setPreedit (buf : ComposerBuffer) (preedit : String) : ComposerBuffer :=
  let cur := clampCursor buf.text buf.cursorOffset
  { buf with
    imePreeditOffset := cur
    imePreeditLen := preedit.length
    imePreeditText := preedit }

/-- Number of complete Unicode scalars covered by a Wayland UTF-8 byte count. -/
private def coveredChars (bytes : Nat) (chars : List Char) : Nat := Id.run do
  let mut remaining := bytes
  let mut count := 0
  for c in chars do
    if remaining < c.utf8Size then break
    remaining := remaining - c.utf8Size
    count := count + 1
    if remaining == 0 then break
  return count

/-- Apply an atomic `zwp-text-input-v3` `done` batch in protocol order:
1. Delete `delBefore` / `delAfter` around cursor
2. Commit `commitStr`
3. Show `preeditStr` at the updated cursor position. -/
def applyImeBatch (buf : ComposerBuffer) (delBefore delAfter : Nat)
    (commitStr preeditStr : String) : ComposerBuffer :=
  let b1 := if delBefore == 0 && delAfter == 0 then buf else
    let chars := buf.text.toList
    let cur := clampCursor buf.text buf.cursorOffset
    buf.deleteAroundCursor (coveredChars delBefore (chars.take cur).reverse)
      (coveredChars delAfter (chars.drop cur))
  let b2 := b1.insertText commitStr
  b2.setPreedit preeditStr

/-- Undo the most recent edit, pushing the current state onto `redoStack`. -/
def undo (buf : ComposerBuffer) : ComposerBuffer :=
  match buf.undoStack with
  | [] => buf
  | prev :: restUndo =>
    let curSnap : ComposerSnapshot := { text := buf.text, cursorOffset := buf.cursorOffset }
    let nextRedo := (curSnap :: buf.redoStack).take (max 1 buf.maxUndoDepth)
    { buf with
      text := prev.text
      cursorOffset := clampCursor prev.text prev.cursorOffset
      undoStack := restUndo
      redoStack := nextRedo
      imePreeditLen := 0
      imePreeditText := "" }

/-- Redo the most recently undone edit, pushing the current state back onto `undoStack`. -/
def redo (buf : ComposerBuffer) : ComposerBuffer :=
  match buf.redoStack with
  | [] => buf
  | next :: restRedo =>
    let curSnap : ComposerSnapshot := { text := buf.text, cursorOffset := buf.cursorOffset }
    let nextUndo := (curSnap :: buf.undoStack).take (max 1 buf.maxUndoDepth)
    { buf with
      text := next.text
      cursorOffset := clampCursor next.text next.cursorOffset
      undoStack := nextUndo
      redoStack := restRedo
      imePreeditLen := 0
      imePreeditText := "" }

/-- Edit an active text field using XKB navigation and editing keys. Leave IME
    preedit to the input method until it commits or cancels. -/
def editKey? (buf : ComposerBuffer) (key mods : UInt32) : Option ComposerBuffer := Id.run do
  if !buf.imePreeditText.isEmpty then return none
  if mods == 2 || mods == 8 then
    if key == 0x7a then return some buf.undo
    if key == 0x79 then return some buf.redo
  if (mods == 3 || mods == 9) && (key == 0x5a || key == 0x7a) then return some buf.redo
  if mods != 0 then return none
  let cur := clampCursor buf.text buf.cursorOffset
  let len := buf.text.length
  if key == 0xff08 then return some (if cur == 0 then buf else buf.deleteAroundCursor 1 0)
  if key == 0xffff then return some (if cur == len then buf else buf.deleteAroundCursor 0 1)
  let pos := match key with
    | 0xff51 => cur - 1
    | 0xff53 => min len (cur + 1)
    | 0xff50 => cur - ((buf.text.toList.take cur).reverse.takeWhile (· != '\n')).length
    | 0xff57 => cur + ((buf.text.toList.drop cur).takeWhile (· != '\n')).length
    | _ => return none
  return some { buf with cursorOffset := pos, imePreeditOffset := pos }

/-- Attach a file/payload chip to the composer buffer. -/
def addAttachment (buf : ComposerBuffer) (att : ComposerAttachment) : ComposerBuffer :=
  { buf with attachments := buf.attachments ++ [att], dragHoverActive := false }

/-- Remove an attachment chip by `id`. -/
def removeAttachment (buf : ComposerBuffer) (attId : Nat) : ComposerBuffer :=
  { buf with attachments := buf.attachments.filter (fun a => a.id != attId) }

/-- Update drag-and-drop hover state. -/
@[inline] def setDragHover (buf : ComposerBuffer) (hover : Bool) : ComposerBuffer :=
  { buf with dragHoverActive := hover }

end ComposerBuffer

/-- Deterministic fallback `InlineRun` synthesizer for composer text, IME preedit, and chips. -/
@[inline] def composerSynthRun (style : TextStyle) (text : String) : InlineRun :=
  let charAdv : SubPx := max (6 * subPerPx) (style.sizeSub / 2)
  let glyphs : List ShapedGlyph :=
    text.toList.mapIdx fun idx c => {
      glyphId := c.toNat
      cluster := idx
      xAdvance := charAdv
      isBreakOpportunity := c == ' '
      isHardBreak := c == '\n'
    }
  { glyphs := glyphs, style := style, allowBreakAfter := true, hardBreakAfter := false }

/-- Keep explicit line breaks and word boundaries through native font shaping. -/
private def composerTextRuns (style : TextStyle) (text : String) : List InlineRun := Id.run do
  let mut out := #[]
  let mut word := ""
  for ch in text.toList do
    if ch == '\n' then
      out := out.push { (composerSynthRun style word) with hardBreakAfter := true }
      word := ""
    else
      word := word.push ch
      if ch == ' ' then
        out := out.push (composerSynthRun style word)
        word := ""
  if !word.isEmpty then out := out.push (composerSynthRun style word)
  return out.toList

/-- Build styled `InlineRun`s for a `ComposerBuffer`, highlighting the active IME preedit span
with an underline and accent color when `imePreeditLen > 0`. -/
def buildComposerInlineRuns (theme : Theme) (buf : ComposerBuffer)
    (overrideRuns : List InlineRun := []) : List InlineRun :=
  if !overrideRuns.isEmpty then overrideRuns
  else
    let pal := theme.palette
    if buf.text.isEmpty && buf.imePreeditText.isEmpty then
      let phStyle : TextStyle := { (Theme.bodyText theme) with
        color := if theme.isDark then 0x676767FF else 0xA3A29CFF }
      [composerSynthRun phStyle buf.placeholder]
    else
      let chars := buf.text.toList
      let cur := ComposerBuffer.clampCursor buf.text buf.cursorOffset
      let beforeStr := String.ofList (chars.take cur)
      let afterStr := String.ofList (chars.drop cur)
      let bodyStyle := Theme.bodyText theme
      let preeditStyle : TextStyle := {
        bodyStyle with
        color := pal.accent
        underline := true
      }
      let beforeRun := composerTextRuns bodyStyle beforeStr
      let preeditRun :=
        if buf.imePreeditText.isEmpty then []
        else [composerSynthRun preeditStyle buf.imePreeditText]
      let afterRun := composerTextRuns bodyStyle afterStr
      beforeRun ++ preeditRun ++ afterRun

/-- Build an attachment chip widget for a single `ComposerAttachment`. -/
def buildAttachmentChipWidget (theme : Theme) (att : ComposerAttachment) : WidgetNode :=
  let pal := theme.palette
  let chipW : SubPx := pxToSub (max 96 (att.fileName.length * 7 + 36))
  let chipH : SubPx := pxToSub 24
  let lblStyle := Theme.secondaryText theme
  let rawChip : WidgetNode :=
    WidgetNode.rrect
      (BoxStyle.row (pxToSub 4)
        |>.withAlign .center
        |>.withPadding (Edges.xy (pxToSub 8) (pxToSub 3))
        |>.withFixedSize chipW chipH)
      pal.surface
      (CornerRadii.uniform theme.radiusSm)
      (BorderStyle.uniform theme.borderWidth pal.border)
      [WidgetNode.text
        (BoxStyle.row 0 |>.withFixedSize (chipW - pxToSub 16) (pxToSub 16))
        theme.typo.lineTight
        [composerSynthRun lblStyle ("📎 " ++ att.fileName)]]
      att.removeButtonId
  match att.removeButtonId with
  | some wid => WidgetNode.focusable wid rawChip
  | none => rawChip

/-- Build the composer dock (`availW x composerH`): optional attachment chips above a pill-shaped
editor centred in a column of at most `748 px`, as `.dock > .col > .composer` in the SolidJS
desktop. The pill holds the round attach button, the text and the send button. -/
def buildComposerWidget (theme : Theme) (availW composerH : SubPx)
    (buf : ComposerBuffer) (overrideRuns : List InlineRun := []) (controls : Option WidgetNode := none) (newAgentHeader : Option WidgetNode := none) : WidgetNode :=
  let pal := theme.palette
  let tall := newAgentHeader.isSome
  let colW : SubPx := if tall then min (pxToSub 608) (availW - pxToSub 32) else min (pxToSub 748) (availW - pxToSub 68)
  let isRunning := buf.isRunning
  let hasChips := !buf.attachments.isEmpty
  let chipRowH : SubPx := pxToSub 28
  let borderCol := if buf.dragHoverActive then pal.accent else pal.border
  let pillBg := if buf.dragHoverActive then pal.accentMuted else pal.elevatedSurface
  let buttonStyle : BoxStyle :=
    BoxStyle.row 0 |>.withAlign .center |>.withJustify .center
      |>.withFixedSize (pxToSub 24) (pxToSub 24)
  let withId (id : Option WidgetId) (node : WidgetNode) : WidgetNode :=
    match id with
    | some wid => WidgetNode.focusable wid node
    | none => node
  let attachBtn : WidgetNode :=
    withId buf.attachButtonId <|
      WidgetNode.box
        (buttonStyle
          |>.withBg pal.plusBg
          |>.withRadius (pxToSub 12))
        [WidgetNode.box
          (BoxStyle.col 0 |>.withAlign .center |>.withFixedSize (pxToSub 10) (pxToSub 10))
          [ WidgetNode.rrect (BoxStyle.row 0 |>.withFixedSize (pxToSub 2) (pxToSub 4)) pal.textMuted CornerRadii.zero
          , WidgetNode.rrect (BoxStyle.row 0 |>.withFixedSize (pxToSub 10) (pxToSub 2)) pal.textMuted CornerRadii.zero
          , WidgetNode.rrect (BoxStyle.row 0 |>.withFixedSize (pxToSub 2) (pxToSub 4)) pal.textMuted CornerRadii.zero ]]
        buf.attachButtonId
  let hasText := !buf.text.isEmpty || !buf.imePreeditText.isEmpty
  -- Two 24px buttons, two 8px gaps, pill padding, text inset and border.
  let placeholderWidth := colW - pxToSub (48 + 16 + 22 + 2) - 2 * theme.borderWidth
  let runs := buildComposerInlineRuns theme buf overrideRuns
  let editH := if tall then max (pxToSub 48) (min (pxToSub 180) (wrapInlineRuns (colW - pxToSub 26) (pxToSub 18) runs).2.2) else pxToSub 18
  let textNode : WidgetNode :=
    WidgetNode.text
      { BoxStyle.row 0 with
        grow := 1
        clip := !hasText
        maxWidth := if tall then colW - pxToSub 26 else if hasText then (BoxStyle.row 0).maxWidth else placeholderWidth
        minHeight := editH
        maxHeight := editH
        padding := Edges.trbl 0 0 0 (pxToSub 2) }
      (pxToSub 18)
      runs
  let sendBgCol := if hasText || isRunning then pal.sendBg else ((pal.sendBg &&& 0xFFFFFF00) ||| 0x47)
  let glyph : WidgetNode := if isRunning then
      WidgetNode.rrect (BoxStyle.row 0 |>.withFixedSize (pxToSub 6) (pxToSub 6)) pal.sendFg
        (CornerRadii.uniform (pxToSub 1))
    else
      .mk none false false (BoxStyle.row 0 |>.withFixedSize (pxToSub 14) (pxToSub 14))
        (.vectorIcon [[(80,130),(80,30)], [(35,75),(80,30),(125,75)]] pal.sendFg) []
  let sendBtn : WidgetNode :=
    withId buf.sendButtonId <|
      WidgetNode.box
        (buttonStyle
          |>.withBg sendBgCol
          |>.withRadius (if isRunning then theme.radiusMd else pxToSub 12))
        [glyph] buf.sendButtonId
  -- The native three-box blur at 16 px matches the falloff of the browser's
  -- `.dock .composer` 18 px CSS shadow; retain its 4 px offset and 8% opacity.
  let pill : WidgetNode :=
    WidgetNode.focusable buf.composerWidgetId <|
      WidgetNode.box
        (BoxStyle.row (pxToSub 8)
          |>.withAlign .center
          |>.withPadding (Edges.trbl (pxToSub 9) (pxToSub 10) (pxToSub 9) (pxToSub 12))
          |>.withFixedSize colW (pxToSub 42)
          |>.withBg pillBg
          |>.withRadius (pxToSub 21)
          |>.withBorder theme.borderWidth borderCol
          |>.withShadow { offsetY := pxToSub 4, blur := pxToSub 16, color := 0x00000014 })
        [attachBtn, textNode, sendBtn]
  let metaStyle : TextStyle :=
    { (Theme.mutedText theme) with sizeSub := pxToSub 12, lineHeightSub := pxToSub 18, color := pal.textMuted }
  let metaText (text : String) (width : SubPx) : WidgetNode :=
    WidgetNode.text (BoxStyle.row 0 |>.withFixedSize width (pxToSub 18))
      (pxToSub 18) [composerSynthRun metaStyle text]
  let selector (text : String) (width : Nat) : WidgetNode :=
    WidgetNode.box (BoxStyle.row (pxToSub 4) |>.withAlign .center
      |>.withFixedSize (pxToSub (width + 14)) (pxToSub 18))
      [metaText text (pxToSub width), .mk none false false (BoxStyle.row 0 |>.withFixedSize (pxToSub 10) (pxToSub 10))
        (.vectorIcon WidgetNode.downChevronPaths pal.textMuted) []]
  let sep := metaText "·" (pxToSub 3)
  let underRow : WidgetNode :=
    WidgetNode.box
      (BoxStyle.row (pxToSub 6)
        |>.withAlign .center
        |>.withPadding (Edges.trbl 0 (pxToSub 12) (pxToSub 2) (pxToSub 12))
        |>.withFixedSize colW (pxToSub 36))
      [ WidgetNode.box (BoxStyle.row 0 |>.withFixedSize (pxToSub 11) (pxToSub 13)) []
      , selector "selected machine" 99, sep
      , selector "claudecode" 66, sep, metaText "Default" (pxToSub 40), sep
      , selector "Default" 40, sep, selector "Supervised" 65 ]
  let chipBar : List WidgetNode :=
    if hasChips then
      [WidgetNode.box
        (BoxStyle.row (pxToSub 6) |>.withAlign .center |>.withFixedSize colW chipRowH)
        (buf.attachments.map (buildAttachmentChipWidget theme))]
    else []
  if let some header := newAgentHeader then
    let toolbar := WidgetNode.box (BoxStyle.row (pxToSub 8) |>.withAlign .center |>.withFixedSize (colW - pxToSub 26) (pxToSub 24))
      ([attachBtn] ++ controls.toList ++ [sendBtn])
    let card := WidgetNode.focusable buf.composerWidgetId <| WidgetNode.box
      (BoxStyle.col (pxToSub 6) |>.withPadding (Edges.trbl (pxToSub 10) (pxToSub 12) (pxToSub 8) (pxToSub 12))
        |>.withFixedSize colW (pxToSub 50 + editH + (if hasChips then chipRowH else 0))
        |>.withBg pillBg |>.withRadius (pxToSub 12) |>.withBorder theme.borderWidth borderCol)
      (chipBar ++ [textNode, toolbar])
    WidgetNode.box (BoxStyle.col (pxToSub 10) |>.withAlign .center) [header, card]
  else
    WidgetNode.box
      (BoxStyle.col 0
        |>.withAlign .center
        |>.withPadding (Edges.trbl (pxToSub 10) (pxToSub 34) 0 (pxToSub 34))
        |>.withFixedSize availW composerH)
      (chipBar ++ [pill, controls.getD underRow])

end LeanUI.Widgets
