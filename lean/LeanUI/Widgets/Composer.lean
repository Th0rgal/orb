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

/-- Apply an atomic `zwp-text-input-v3` `done` batch in protocol order:
1. Delete `delBefore` / `delAfter` around cursor
2. Commit `commitStr`
3. Show `preeditStr` at the updated cursor position. -/
def applyImeBatch (buf : ComposerBuffer) (delBefore delAfter : Nat)
    (commitStr preeditStr : String) : ComposerBuffer :=
  let b1 := buf.deleteAroundCursor delBefore delAfter
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

/-- Build styled `InlineRun`s for a `ComposerBuffer`, highlighting the active IME preedit span
with an underline and accent color when `imePreeditLen > 0`. -/
def buildComposerInlineRuns (theme : Theme) (buf : ComposerBuffer)
    (overrideRuns : List InlineRun := []) : List InlineRun :=
  if !overrideRuns.isEmpty then overrideRuns
  else
    let pal := theme.palette
    if buf.text.isEmpty && buf.imePreeditText.isEmpty then
      let phStyle : TextStyle := { (Theme.bodyText theme) with color := pal.textMuted }
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
      let beforeRun := if beforeStr.isEmpty then [] else [composerSynthRun bodyStyle beforeStr]
      let preeditRun :=
        if buf.imePreeditText.isEmpty then []
        else [composerSynthRun preeditStyle buf.imePreeditText]
      let afterRun := if afterStr.isEmpty then [] else [composerSynthRun bodyStyle afterStr]
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
    (buf : ComposerBuffer) (overrideRuns : List InlineRun := []) : WidgetNode :=
  let pal := theme.palette
  let colW : SubPx := min (pxToSub 748) (availW - pxToSub 68)
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
        [WidgetNode.rrect (BoxStyle.row 0 |>.withFixedSize (pxToSub 10) (pxToSub 2)) pal.textMuted CornerRadii.zero]
        buf.attachButtonId
  let textNode : WidgetNode :=
    WidgetNode.text
      { BoxStyle.row 0 with grow := 1, minHeight := pxToSub 18, maxHeight := pxToSub 18 }
      (pxToSub 18)
      (buildComposerInlineRuns theme buf overrideRuns)
  let hasText := !buf.text.isEmpty || !buf.imePreeditText.isEmpty
  let sendBgCol := if hasText then pal.sendBg else ((pal.sendBg &&& 0xFFFFFF00) ||| 0x47)
  let sendBtn : WidgetNode :=
    withId buf.sendButtonId <|
      WidgetNode.box
        (buttonStyle
          |>.withBg sendBgCol
          |>.withRadius (pxToSub 12))
        [WidgetNode.rrect (BoxStyle.row 0 |>.withFixedSize (pxToSub 6) (pxToSub 6)) pal.sendFg
          (CornerRadii.uniform (pxToSub 1))]
        buf.sendButtonId
  let pill : WidgetNode :=
    WidgetNode.focusable buf.composerWidgetId <|
      WidgetNode.box
        (BoxStyle.row (pxToSub 8)
          |>.withAlign .center
          |>.withPadding (Edges.trbl (pxToSub 9) (pxToSub 10) (pxToSub 9) (pxToSub 12))
          |>.withFixedSize colW (pxToSub 42)
          |>.withBg pillBg
          |>.withRadius (pxToSub 21)
          |>.withBorder theme.borderWidth borderCol)
        [attachBtn, textNode, sendBtn]
  let metaStyle : TextStyle :=
    { (Theme.mutedText theme) with sizeSub := pxToSub 13, lineHeightSub := pxToSub 18, color := pal.textMuted }
  let underRow : WidgetNode :=
    WidgetNode.box
      (BoxStyle.row (pxToSub 12)
        |>.withAlign .center
        |>.withPadding (Edges.trbl 0 (pxToSub 4) 0 (pxToSub 4))
        |>.withFixedSize colW (pxToSub 36))
      [ WidgetNode.text
          (BoxStyle.row 0 |>.withFixedSize (colW - pxToSub 8) (pxToSub 18))
          (pxToSub 18)
          [composerSynthRun metaStyle "selected machine   ·   claudecode   ·   Orb Lorem 4.6 High Fast"] ]
  let chipBar : List WidgetNode :=
    if hasChips then
      [WidgetNode.box
        (BoxStyle.row (pxToSub 6) |>.withAlign .center |>.withFixedSize colW chipRowH)
        (buf.attachments.map (buildAttachmentChipWidget theme))]
    else []
  WidgetNode.box
    (BoxStyle.col 0
      |>.withAlign .center
      |>.withPadding (Edges.trbl (pxToSub 10) (pxToSub 34) 0 (pxToSub 34))
      |>.withFixedSize availW composerH)
    (chipBar ++ [pill, underRow])

end LeanUI.Widgets
