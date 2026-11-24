import LeanUI.Defs
import LeanUI.Kernel
import LeanUI.Style
import LeanUI.Layout
import LeanUI.Scene
import LeanUI.Widgets.VirtualList
import LeanUI.Widgets.RichText
import LeanUI.Widgets.DiffViewer
import LeanUI.Widgets.MermaidSvg
import LeanUI.Widgets.Overlays
import LeanUI.Widgets.Composer
import OrbDesktop.State
import OrbDesktop.Chrome
/-!
# OrbDesktop.Screens — Pure Declarative Builders for All 9 Canonical Orb Desktop Screens (`0` FFI)

Implements the 9 canonical screens (zero FFI, zero IO, kernel-verified):
1. `01_control_empty` (`/?screen=control`)
2. `02_control_populated` (`/?screen=control&fixture=populated`)
3. `03_mission_transcript` (`/?screen=mission&id=m-active`)
4. `04_mission_split_diff` (`/?screen=mission&id=m-diff&mode=split`)
5. `05_machines_fleet` (`/?screen=machines`)
6. `06_settings_general` (`/?screen=settings&tab=general`)
7. `07_search_dialog` (`/?screen=control&modal=search`)
8. `08_new_mission_dialog` (`/?screen=control&modal=new-mission`)
9. `09_toast_notifications` (`/?screen=control&fixture=toasts`)
-/
namespace OrbDesktop

open LeanUI
open LeanUI.Widgets

/-- Pre-shaped inline text runs optionally supplied by the native HarfBuzz/FreeType shaper. -/
structure ShapedScreenRuns where
  headerTitleRuns : List InlineRun := []
  primarySubtitleRuns : List InlineRun := []
  codeSampleRuns : List InlineRun := []
  streamRuns : List InlineRun := []
  diffDelRuns : List InlineRun := []
  diffAddRuns : List InlineRun := []
  deriving Repr, Inhabited

/-- Helper for a single line of text with explicit `sizePx`, `lineH`, and `color`. -/
def screenTextLine (theme : Theme) (w h sizePx linePx : SubPx) (color : Color)
    (text : String) (weight : Nat := 400) (monospace : Bool := false) : WidgetNode :=
  let base := if monospace then Theme.codeText theme else Theme.bodyText theme
  let st : TextStyle := { base with sizeSub := sizePx, lineHeightSub := linePx, color := color, weight := weight }
  WidgetNode.text (BoxStyle.row 0 |>.withFixedSize w h) linePx [overlaySynthRun st text]


/-! ## 1 & 2 & 8 & 9. New Agent Centered Composer (`01`, `02`, `07`, `08`, `09`) -/

/-- Build the centered `.composer.tall` New Agent card (`x=541..1149, y=378..511`) and optional toast stack. -/
def buildNewAgentBody (st : DesktopState) (mainW bodyH : SubPx) : WidgetNode :=
  let theme := st.theme
  let pal := theme.palette
  let colW : SubPx := pxToSub 608
  let composedText :=
    if st.composer.imePreeditText.isEmpty then st.composer.text
    else
      let chars := st.composer.text.toList
      let cur := ComposerBuffer.clampCursor st.composer.text st.composer.cursorOffset
      String.ofList (chars.take cur) ++ st.composer.imePreeditText ++ String.ofList (chars.drop cur)
  let hasText := !composedText.isEmpty
  let bdrCol := pal.borderStrong
  let placeholderCol : Color := if theme.isDark then 0x676767FF else 0xA3A29CFF
  let txtCol := if hasText then pal.textPrimary else placeholderCol
  let dispText := if hasText then composedText else st.composer.placeholder
  let sendBgCol := pal.sendBg

  let dropBar : WidgetNode :=
    WidgetNode.box
      (BoxStyle.row (pxToSub 16)
        |>.withAlign .center
        |>.withPadding (Edges.trbl 0 0 0 (pxToSub 4))
        |>.withFixedSize colW (pxToSub 24))
       [ WidgetNode.focusable draftProjectPickerId <|
           WidgetNode.box (BoxStyle.row (pxToSub 4) |>.withAlign .center |>.withFixedSize (pxToSub 60) (pxToSub 24))
             [screenTextLine theme (pxToSub 46) (pxToSub 18) (pxToSub 13) (pxToSub 18) pal.textSecondary "Default",
              chromeIcon "chevron-down" pal.textMuted 10]
        , WidgetNode.focusable 720 <|
           WidgetNode.box (BoxStyle.row (pxToSub 4) |>.withAlign .center |>.withFixedSize (pxToSub 150) (pxToSub 24))
             [chromeIcon "server" pal.textMuted 14,
             screenTextLine theme (pxToSub 112) (pxToSub 18) (pxToSub 13) (pxToSub 18) pal.textSecondary "Core (agent-core)",
             chromeIcon "chevron-down" pal.textMuted 10]
        , WidgetNode.focusable draftDirectoryPickerId <|
           WidgetNode.box (BoxStyle.row (pxToSub 4) |>.withAlign .center |>.withFixedSize (pxToSub 60) (pxToSub 24))
             [chromeIcon "folder" pal.textMuted 14,
             screenTextLine theme (pxToSub 42) (pxToSub 18) (pxToSub 13) (pxToSub 18) pal.textSecondary "Folder"]
      ]

  let buttonStyle : BoxStyle :=
    BoxStyle.row 0 |>.withAlign .center |>.withJustify .center
      |>.withFixedSize (pxToSub 24) (pxToSub 24)
  let plusBtn : WidgetNode :=
    WidgetNode.focusable 3 <|
      WidgetNode.rrect buttonStyle pal.plusBg (CornerRadii.uniform (pxToSub 12)) BorderStyle.none
        [chromeIcon "plus" pal.textMuted 16]
  let sendBtn : WidgetNode :=
    WidgetNode.focusable 2 <|
      if hasText then
        WidgetNode.rrect buttonStyle sendBgCol (CornerRadii.uniform (pxToSub 12)) BorderStyle.none
          [WidgetNode.rrect (BoxStyle.row 0 |>.withFixedSize (pxToSub 6) (pxToSub 6)) pal.sendFg (CornerRadii.uniform (pxToSub 1))]
      else
        WidgetNode.box buttonStyle []

  let bottomRow : WidgetNode :=
    WidgetNode.box
      (BoxStyle.row (pxToSub 8)
        |>.withAlign .center
        |>.withFixedSize (pxToSub 582) (pxToSub 24))
      [ plusBtn
       , WidgetNode.focusable 722 <|
           WidgetNode.box (BoxStyle.row (pxToSub 5) |>.withAlign .center
             |>.withPadding (Edges.xy (pxToSub 4) 0) |>.withFixedSize (pxToSub 518) (pxToSub 24))
             [screenTextLine theme (pxToSub 151) (pxToSub 18) (pxToSub 13) (pxToSub 18) pal.textMuted "Orb Lorem 4.6 High Fast",
              chromeIcon "chevron-down" pal.textMuted 12]
      , sendBtn
      ]

  let tallComposer : WidgetNode :=
    WidgetNode.rrect
      (BoxStyle.col (pxToSub 6)
        |>.withPadding (Edges.trbl (pxToSub 11) (pxToSub 13) (pxToSub 9) (pxToSub 13))
        |>.withFixedSize colW (pxToSub 98))
      pal.elevatedSurface
      (CornerRadii.uniform (pxToSub 12))
      (BorderStyle.uniform theme.borderWidth bdrCol)
      [ WidgetNode.focusable 1 <|
          WidgetNode.box
            (BoxStyle.col 0 |>.withPadding (Edges.trbl (pxToSub 2) 0 0 (pxToSub 2))
              |>.withFixedSize (pxToSub 582) (pxToSub 48))
            [screenTextLine theme (pxToSub 580) (pxToSub 20) (pxToSub 13) (pxToSub 20) txtCol dispText]
      , bottomRow
      ]

  let centerStack : WidgetNode :=
    WidgetNode.box
      (BoxStyle.col (pxToSub 10) |>.withFixedSize colW (pxToSub 132))
      [dropBar, tallComposer]

  let toastCard (w h : SubPx) (t : ToastSpec) : WidgetNode :=
    let toastBg : Color := if theme.isDark then 0x191919FF else 0xFAFAFAFF
    let toastBdr : Color := if theme.isDark then 0x333333FF else 0xE0DFD9FF
    let textCol : WidgetNode :=
      WidgetNode.box
        (BoxStyle.col (pxToSub 2) |>.withFixedSize (w - pxToSub 30) (h - pxToSub 18))
        [ screenTextLine theme (w - pxToSub 30) (pxToSub 17) (pxToSub 12) (pxToSub 17) pal.textPrimary t.title 500
        , screenTextLine theme (w - pxToSub 30) (pxToSub 17) (pxToSub 12) (pxToSub 17) pal.textSecondary t.message ]
    let closeIcon := chromeIcon "close" pal.textMuted 14
    let closeBtn := match t.dismissButtonId with
      | some wid => WidgetNode.focusable wid closeIcon
      | none => closeIcon
    WidgetNode.rrect
      (BoxStyle.row (pxToSub 8)
         |>.withAlign .start |>.withJustify .spaceBetween
         |>.withPadding (Edges.trbl (pxToSub 9) (pxToSub 15) (pxToSub 9) (pxToSub 15))
         |>.withFixedSize w h
         |>.withShadow { offsetY := pxToSub 10, blur := pxToSub 32, color := if theme.isDark then 0x0000007F else 0x1E1E1C2D })
      toastBg
      (CornerRadii.uniform (pxToSub 8))
      (BorderStyle.uniform theme.borderWidth toastBdr)
      [ textCol
      , closeBtn ]

  let toastDims (t : ToastSpec) : SubPx × SubPx :=
    match t.id with
    | 901 => (pxToSub 569, pxToSub 54)
    | 902 => (pxToSub 351, pxToSub 54)
    | _   => (pxToSub 608, pxToSub 58)

  let toastRegion : List WidgetNode :=
    if st.toasts.isEmpty then []
    else
      let cards := st.toasts.map fun t =>
        let (tw, th) := toastDims t
        toastCard tw th t
      [ WidgetNode.box (BoxStyle.col 0 |>.withFixedSize colW (pxToSub 212)) []
      , WidgetNode.box
          (BoxStyle.col (pxToSub 8) |>.withAlign .center |>.withFixedSize colW (pxToSub 181))
          cards
      ]

  WidgetNode.box
    (BoxStyle.col 0
      |>.withAlign .center
      |>.withPadding (Edges.trbl (pxToSub 343) 0 0 0)
      |>.withFixedSize mainW bodyH
      |>.withBg pal.canvas)
    ([centerStack] ++ toastRegion)

/-! ## 3. `03_mission_transcript` (`/?screen=mission&id=m-active`) -/

/-- Build one conversation turn (`Step N`, `340 px` tall) in the SolidJS transcript layout. -/
def buildReferenceTurnWidget (theme : Theme) (colW : SubPx) (stepNum : Nat) : WidgetNode :=
  let pal := theme.palette
  let innerW := colW - pxToSub 20
  let codeBgCol : Color := if theme.isDark then 0x1C1C1CFF else 0xF6F5F2FF

  let userPill : WidgetNode :=
    WidgetNode.rrect
      (BoxStyle.row 0
        |>.withAlign .center
        |>.withPadding (Edges.xy (pxToSub 11) (pxToSub 6))
        |>.withFixedSize colW (pxToSub 38))
      pal.elevatedSurface
      (CornerRadii.uniform (pxToSub 10))
      (BorderStyle.uniform theme.borderWidth pal.borderSubtle)
      [screenTextLine theme (colW - pxToSub 22) (pxToSub 21) (pxToSub 13) (pxToSub 21) pal.textPrimary
        s!"Please inspect module {stepNum} and fix what is broken."]

  let cmdRow : WidgetNode :=
    WidgetNode.box
      (BoxStyle.row 0
        |>.withAlign .center
        |>.withPadding (Edges.trbl (pxToSub 2) 0 (pxToSub 14) 0)
        |>.withFixedSize innerW (pxToSub 56))
      [chromeIcon "chevron-right" pal.textFaint 12,
       WidgetNode.box (BoxStyle.row 0 |>.withPadding (Edges.trbl 0 0 0 (pxToSub 6)))
         [screenTextLine theme (pxToSub 120) (pxToSub 21) (pxToSub 13) (pxToSub 21) pal.textMuted "4 commands"]]

  let h2Row : WidgetNode :=
    screenTextLine theme innerW (pxToSub 25) (pxToSub 13) (pxToSub 21) pal.textPrimary s!"Step {stepNum}" 650

  let p1Row : WidgetNode :=
    screenTextLine theme innerW (pxToSub 29) (pxToSub 13) (pxToSub 21) pal.textPrimary
      s!"I looked at module {stepNum} and found that fn_{stepNum} handles the edge case. A few notes:"

  let bullet (text : String) (color : Color) : WidgetNode :=
    WidgetNode.box (BoxStyle.row 0 |>.withFixedSize innerW (pxToSub 21))
      [ screenTextLine theme (pxToSub 18) (pxToSub 21) (pxToSub 13) (pxToSub 21) pal.textPrimary "•"
      , screenTextLine theme (innerW - pxToSub 18) (pxToSub 21) (pxToSub 13) (pxToSub 21) color text ]
  let bullets : WidgetNode :=
    WidgetNode.box
      (BoxStyle.col (pxToSub 3)
        |>.withPadding (Edges.trbl 0 0 (pxToSub 12) 0)
        |>.withFixedSize innerW (pxToSub 81))
      [ bullet "the cache is keyed by path" pal.textPrimary
      , bullet "writes go through commit()" pal.textPrimary
      , bullet "see docs" pal.accent
      ]

  let codeLine (tokens : List (String × Color)) : WidgetNode :=
    let style := { (Theme.codeText theme) with sizeSub := pxToSub 12, lineHeightSub := pxToSub 17, weight := 400 }
    WidgetNode.text (BoxStyle.row 0 |>.withFixedSize (innerW - pxToSub 24) (pxToSub 17))
      (pxToSub 17) (tokens.map fun (text, color) => overlaySynthRun { style with color := color } text)
  let keyword : Color := if theme.isDark then 0x86D3D4FF else 0x007A7AFF
  let functionName : Color := if theme.isDark then 0xE8AE74FF else 0x795E26FF
  let number : Color := if theme.isDark then 0xA2C99EFF else 0x098658FF
  let codeCard : WidgetNode :=
    WidgetNode.rrect
      (BoxStyle.col (pxToSub 4)
        |>.withPadding (Edges.all (pxToSub 12))
        |>.withFixedSize innerW (pxToSub 81))
      codeBgCol
      (CornerRadii.uniform (pxToSub 8))
      (BorderStyle.uniform theme.borderWidth pal.border)
      [ codeLine [("export function ", keyword), (s!"fn_{stepNum}", functionName),
          ("(x: number) {", pal.textPrimary)]
      , codeLine [("  ", pal.textPrimary), ("return", keyword), (" x * ", pal.textPrimary),
          (toString stepNum, number), (" + ", pal.textPrimary), ("1", number), (";", pal.textPrimary)]
      , codeLine [("}", pal.textPrimary)]
      ]

  let closeRow : WidgetNode :=
    WidgetNode.box
      (BoxStyle.row 0
        |>.withAlign .center
        |>.withJustify .spaceBetween
        |>.withPadding (Edges.trbl (pxToSub 14) 0 0 0)
        |>.withFixedSize innerW (pxToSub 35))
      [ screenTextLine theme (innerW - pxToSub 70) (pxToSub 21) (pxToSub 13) (pxToSub 21) pal.textPrimary
          "The change keeps behaviour identical."
      , screenTextLine theme (pxToSub 50) (pxToSub 16) (pxToSub 12) (pxToSub 16) pal.textMuted ""
       ]

  let bodyBlock : WidgetNode :=
    WidgetNode.box
      (BoxStyle.col 0
        |>.withPadding (Edges.xy (pxToSub 10) 0)
        |>.withFixedSize colW (pxToSub 302))
       [cmdRow, h2Row, p1Row, bullets, codeCard, closeRow]

  WidgetNode.box
    (BoxStyle.col 0 |>.withFixedSize colW (pxToSub 345))
    [userPill, bodyBlock]

/-- Human-readable label for Core's persisted conversation status. -/
def conversationStatusLabel (status : String) : String :=
  match status with
  | "awaiting_user" | "waiting_user" | "acknowledged" => "Ready for a follow-up"
  | "blocked" => "Waiting for input"
  | "waiting_background" => "Waiting for background work"
  | _ => (status.replace "_" " ").capitalize

#guard conversationStatusLabel "awaiting_user" == "Ready for a follow-up"
#guard conversationStatusLabel "waiting_background" == "Waiting for background work"

/-- Top banner for on-demand older-turn paging in live transcripts. Always occupies
`transcriptHistoryBannerHeightSub` so loading/error transitions never shift layout. -/
private def buildHistoryBanner (st : DesktopState) (colW : SubPx) (hoverRow : Option WidgetId) : WidgetNode :=
  let theme := st.theme
  let pal := theme.palette
  let label :=
    if st.historyLoading then "Loading older turns…"
    else if st.historyLoadError then "Could not load older turns · Retry"
    else "Load older turns"
  let hovered := !st.historyLoading && hoverRow == some loadOlderTurnsId
  let bg := if hovered then pal.plusBg else pal.elevatedSurface
  let txtColor := if st.historyLoading then pal.textMuted else pal.textSecondary
  let pillW : SubPx := min colW (pxToSub (if st.historyLoadError then 250 else 170))
  let pill := WidgetNode.rrect
    (BoxStyle.row 0
      |>.withAlign .center
      |>.withJustify .center
      |>.withPadding (Edges.xy (pxToSub 12) 0)
      |>.withFixedSize pillW transcriptHistoryBannerHeightSub)
    bg
    (CornerRadii.uniform (pxToSub 8))
    (BorderStyle.uniform theme.borderWidth pal.border)
    [screenTextLine theme (pillW - pxToSub 24) (pxToSub 18) (pxToSub 12) (pxToSub 18) txtColor label 500]
    (if st.historyLoading then none else some loadOlderTurnsId)
  let item := if st.historyLoading then pill else WidgetNode.focusable loadOlderTurnsId pill
  WidgetNode.box
    (BoxStyle.row 0
      |>.withAlign .center
      |>.withJustify .center
      |>.withFixedSize colW transcriptHistoryBannerHeightSub)
    [item]

/-- Build the Mission Transcript body (`03_mission_transcript`) matching the SolidJS transcript column. -/
def buildMissionTranscriptBody (st : DesktopState) (mainW bodyH : SubPx)
    (_runs : ShapedScreenRuns) (hoverRow : Option WidgetId := none) : WidgetNode :=
  let theme := st.theme
  let pal := theme.palette
  let colW : SubPx := min (pxToSub 748) (mainW - pxToSub 48)
  let turn58 := buildReferenceTurnWidget theme colW 58
  let turn59 := buildReferenceTurnWidget theme colW 59
  let workingRow : WidgetNode :=
    WidgetNode.box
      (BoxStyle.row (pxToSub 10)
        |>.withAlign .center
        |>.withPadding (Edges.trbl 0 (pxToSub 10) 0 (pxToSub 20))
        |>.withFixedSize colW (pxToSub 33))
      [ screenTextLine theme (pxToSub 200) (pxToSub 21) (pxToSub 12) (pxToSub 21) pal.textMuted "Working on selected machine…"
      , screenTextLine theme (pxToSub 60) (pxToSub 21) (pxToSub 13) (pxToSub 21) pal.textFaint "11 h 50"
      ]
  let width := transcriptTextWidth mainW
  let historyBanner : List WidgetNode :=
    if st.showsHistoryBanner then [buildHistoryBanner st colW hoverRow] else []
  let (priorRows, nextBand) := buildLiveTurnsNodes theme colW width st.liveTurns
  let currentText := streamedText st
  let liveStreamRow : List WidgetNode :=
    if (splitMermaidFences currentText).any (·.1) then
      (buildOneLiveTurn theme colW width nextBand currentText).1
    else if _runs.streamRuns.isEmpty then []
    else if currentText.contains "\n" then
      -- Multi-line stream text shares the completed-turn rendering so newline
      -- characters and markdown headings never rasterize as literal missing glyphs.
      liveProseLines theme colW width currentText
    else if needsMarkdownLite currentText then
      -- Single-line stream text with markdown markers shares the markdown-lite
      -- prose pipeline, so a one-line `# Title` or `**bold**` never shows its
      -- literal markers.
      match liveProseLine theme colW width currentText with
      | some row => [row]
      | none => []
    else
      -- Plain single-line stream text keeps the pre-shaped fast path: the runs
      -- arrive already shaped with the stream frame, so the renderer paints them
      -- as-is instead of re-synthesizing from raw text (the viewport regression
      -- pins the last atlas glyph's paint position on exactly this path).
      Id.run do
        let (_, _, height) := wrapInlineRuns width theme.typo.lineBase _runs.streamRuns
        return [WidgetNode.box
        (BoxStyle.row 0
          |>.withPadding (Edges.xy (pxToSub 20) (pxToSub 6))
          |>.withFixedSize colW (height + pxToSub 12))
        [WidgetNode.text
          (BoxStyle.row 0 |>.withFixedSize width height)
          theme.typo.lineBase _runs.streamRuns (some 900)]]

  let liveRows := historyBanner ++ priorRows ++ liveStreamRow ++ (st.selectedCard.toList.map fun c =>
    screenTextLine theme colW (pxToSub 21) (pxToSub 12) (pxToSub 21) pal.textMuted (conversationStatusLabel c.status))
  Id.run do
    let rows := if st.liveData then liveRows else [turn58, turn59] ++ liveStreamRow ++ [workingRow]
    let column := WidgetNode.box { BoxStyle.col transcriptColumnGapSub with minWidth := colW, maxWidth := colW } rows
    let child := WidgetNode.box (BoxStyle.col 0 |>.withAlign .center
      |>.withPadding (Edges.trbl (pxToSub 3) 0 0 0)) [column]
    let (_, contentH) := measureNode mainW child.toLayoutNode
    let offset := if !st.liveData && liveStreamRow.isEmpty && !st.scrolledManually then 0 else (st.scroll.onLayout contentH bodyH).topSub
    return WidgetNode.scrollClip (BoxStyle.col 0 |>.withFixedSize mainW bodyH |>.withBg pal.canvas)
      { offsetY := offset } child (some transcriptViewportId) (hitTestable := false)

/-! ## 4. `04_mission_split_diff` (`/?screen=mission&id=m-diff&mode=split`) -/

/-- Build the right-hand diff viewer pane (`562 x 888`) for `04_mission_split_diff`. -/
def buildSplitDiffRightPane (theme : Theme) (paneW paneH : SubPx)
    (delRuns : List InlineRun := []) (addRuns : List InlineRun := [])
    (diffMode : String := "split") (diffRef : String := "Working tree vs HEAD")
    (showClose : Bool := false) (refreshCount : Nat := 0) : WidgetNode :=
  let pal := theme.palette
  let bdr := theme.borderWidth
  let cardW := paneW - pxToSub 24
  let cardInnerW := cardW - pxToSub 2
  let halfW := (cardInnerW - pxToSub 80) / 2
  let hunkBg : Color := if theme.isDark then 0x252525FF else 0xEAE9E5FF
  let delRowBg : Color := if theme.isDark then 0x3B2C2EFF else 0xEAD6D6FF
  let addRowBg : Color := if theme.isDark then 0x223126FF else 0xD7E6D8FF
  let isUnified := diffMode == "unified"

  let toolbar : WidgetNode :=
    WidgetNode.rrect
      (BoxStyle.row (pxToSub 8)
        |>.withAlign .center
        |>.withPadding (Edges.xy (pxToSub 12) (pxToSub 9))
        |>.withFixedSize paneW (pxToSub 45))
      0x00000000
      CornerRadii.zero
      { widths := Edges.trbl 0 0 bdr 0, color := pal.borderSubtle }
      ([ WidgetNode.focusable diffRefId <|
           WidgetNode.rrect
             (BoxStyle.row 0 |>.withAlign .center |>.withPadding (Edges.xy (pxToSub 10) 0) |>.withFixedSize (pxToSub 158) (pxToSub 26))
             pal.elevatedSurface (CornerRadii.uniform (pxToSub 6)) (BorderStyle.uniform bdr pal.border)
             [screenTextLine theme (pxToSub 136) (pxToSub 16) (pxToSub 12) (pxToSub 16) pal.textPrimary diffRef]
      , WidgetNode.rrect
          (BoxStyle.row 0 |>.withAlign .center |>.withFixedSize (pxToSub 100) (pxToSub 25))
          0x00000000 (CornerRadii.uniform (pxToSub 6)) (BorderStyle.uniform bdr pal.border)
          [ WidgetNode.focusable diffUnifiedId <|
              WidgetNode.rrect (BoxStyle.row 0 |>.withAlign .center |>.withJustify .center |>.withFixedSize (pxToSub 57) (pxToSub 23))
                (if isUnified then pal.elevatedSurface else 0x00000000) CornerRadii.zero BorderStyle.none
                [screenTextLine theme (pxToSub 44) (pxToSub 16) (pxToSub 12) (pxToSub 16) (if isUnified then pal.textStrong else pal.textPrimary) "Unified" (if isUnified then 500 else 400)]
          , WidgetNode.focusable diffSplitId <|
              WidgetNode.rrect (BoxStyle.row 0 |>.withAlign .center |>.withJustify .center |>.withFixedSize (pxToSub 41) (pxToSub 23))
                (if isUnified then 0x00000000 else pal.elevatedSurface) CornerRadii.zero BorderStyle.none
                [screenTextLine theme (pxToSub 30) (pxToSub 16) (pxToSub 12) (pxToSub 16) (if isUnified then pal.textPrimary else pal.textStrong) "Split" (if isUnified then 400 else 500)]
          ]
      , WidgetNode.focusable diffRefreshId <|
          WidgetNode.rrect
            (BoxStyle.row 0 |>.withAlign .center |>.withJustify .center |>.withFixedSize (pxToSub 70) (pxToSub 28))
            0x00000000 (CornerRadii.uniform (pxToSub 6)) (BorderStyle.uniform bdr pal.borderSubtle)
            [screenTextLine theme (pxToSub 50) (pxToSub 16) (pxToSub 13) (pxToSub 16) pal.textSecondary (if refreshCount > 0 then s!"Sync {refreshCount}" else "Refresh") 500]
      ] ++ (if showClose then
          [ WidgetNode.box { BoxStyle.row 0 with grow := 1 } []
          , WidgetNode.focusable sidePanelCloseId <|
              WidgetNode.box (BoxStyle.row 0 |>.withAlign .center |>.withJustify .center |>.withFixedSize (pxToSub 24) (pxToSub 24))
                [chromeIcon "close" pal.textMuted 14]
          ]
        else
          [ WidgetNode.box (BoxStyle.row 0 |>.withFixedSize (pxToSub 110) (pxToSub 16)) []
          , screenTextLine theme (pxToSub 68) (pxToSub 16) (pxToSub 12) (pxToSub 16) pal.textPrimary "1 file +1 -1"
          ]))

  let filesBar : WidgetNode :=
    WidgetNode.rrect
      (BoxStyle.row 0
        |>.withAlign .center
        |>.withPadding (Edges.xy (pxToSub 12) (pxToSub 6))
        |>.withFixedSize paneW (pxToSub 37))
      0x00000000
      CornerRadii.zero
      { widths := Edges.trbl 0 0 bdr 0, color := pal.borderSubtle }
      [ WidgetNode.focusable diffFileChipId <|
          WidgetNode.rrect
            (BoxStyle.row (pxToSub 6)
              |>.withAlign .center
              |>.withPadding (Edges.xy (pxToSub 8) (pxToSub 4))
              |>.withFixedSize (pxToSub 229) (pxToSub 24))
            pal.elevatedSurface
            (CornerRadii.uniform (pxToSub 6))
            (BorderStyle.uniform bdr pal.border)
            [ screenTextLine theme (pxToSub 210) (pxToSub 16) (pxToSub 12) (pxToSub 16) pal.textPrimary
                 "M  lean/OrbDesktop/OrbDesktop/Main.lean  +1 -1" ]
      ]

  let shapedCodeLine (w h : SubPx) (fallback : String) (runs : List InlineRun) : WidgetNode :=
    if runs.isEmpty then
      screenTextLine theme (w - pxToSub 12) h (pxToSub 12) (pxToSub 17) pal.textPrimary fallback 400 true
    else
      WidgetNode.text
        (BoxStyle.row 0 |>.withPadding (Edges.xy (pxToSub 6) 0) |>.withFixedSize w h)
        (pxToSub 17) runs

  let splitRow (h : SubPx) (bgL bgR : Color) (lnL codeL lnR codeR : String)
      (codeRunsL codeRunsR : List InlineRun := []) : WidgetNode :=
    WidgetNode.box
      (BoxStyle.row 0 |>.withFixedSize cardInnerW h)
      [ WidgetNode.rrect (BoxStyle.row 0 |>.withPadding (Edges.xy (pxToSub 6) 0) |>.withFixedSize (pxToSub 40) h)
          bgL CornerRadii.zero BorderStyle.none
          [screenTextLine theme (pxToSub 28) (pxToSub 17) (pxToSub 12) (pxToSub 17) pal.textMuted lnL 400 true]
      , WidgetNode.rrect (BoxStyle.row 0 |>.withPadding (Edges.xy (pxToSub 6) 0) |>.withFixedSize halfW h)
           bgL CornerRadii.zero { widths := Edges.trbl 0 bdr 0 0, color := pal.borderSubtle }
             [shapedCodeLine halfW h codeL codeRunsL]
      , WidgetNode.rrect (BoxStyle.row 0 |>.withPadding (Edges.xy (pxToSub 6) 0) |>.withFixedSize (pxToSub 40) h)
          bgR CornerRadii.zero BorderStyle.none
          [screenTextLine theme (pxToSub 28) (pxToSub 17) (pxToSub 12) (pxToSub 17) pal.textMuted lnR 400 true]
      , WidgetNode.rrect (BoxStyle.row 0 |>.withPadding (Edges.xy (pxToSub 6) 0) |>.withFixedSize halfW h)
           bgR CornerRadii.zero BorderStyle.none
             [shapedCodeLine halfW h codeR codeRunsR]
      ]

  let unifiedRow (h : SubPx) (bg : Color) (ln code : String) (runs : List InlineRun := []) : WidgetNode :=
    WidgetNode.box
      (BoxStyle.row 0 |>.withFixedSize cardInnerW h)
      [ WidgetNode.rrect (BoxStyle.row 0 |>.withPadding (Edges.xy (pxToSub 6) 0) |>.withFixedSize (pxToSub 44) h)
          bg CornerRadii.zero BorderStyle.none
          [screenTextLine theme (pxToSub 32) (pxToSub 17) (pxToSub 12) (pxToSub 17) pal.textMuted ln 400 true]
      , WidgetNode.rrect (BoxStyle.row 0 |>.withPadding (Edges.xy (pxToSub 6) 0) |>.withFixedSize (cardInnerW - pxToSub 44) h)
          bg CornerRadii.zero BorderStyle.none
          [shapedCodeLine (cardInnerW - pxToSub 44) h code runs]
      ]

  let diffRows : List WidgetNode :=
    if isUnified then
      [ unifiedRow (pxToSub 17) 0x00000000 "120" "  let availW := viewport.w"
      , unifiedRow (pxToSub 26) delRowBg "121" "- webkit_web_view_load_uri(wv, orb_dev_url);" delRuns
      , unifiedRow (pxToSub 26) addRowBg "121" "+ buildDesktopScreen st availW availH shapedRuns" addRuns
      , unifiedRow (pxToSub 18) 0x00000000 "122" "  let availH := viewport.h"
      ]
    else
      [ splitRow (pxToSub 17) 0x00000000 0x00000000 "120" "let availW := viewport.w" "120" "let availW := viewport.w"
      , splitRow (pxToSub 52) delRowBg addRowBg "121" "-  webkit_web_view_load_uri(wv, orb_dev_url);" "121" "+  buildDesktopScreen st availW availH shapedRuns"
          delRuns addRuns
      , splitRow (pxToSub 18) 0x00000000 0x00000000 "122" "let availH := viewport.h" "122" "let availH := viewport.h"
      ]

  let diffCard : WidgetNode :=
    WidgetNode.rrect
      (BoxStyle.col 0
        |>.withPadding (Edges.all bdr)
        |>.withFixedSize cardW (pxToSub 142))
      pal.elevatedSurface
      (CornerRadii.uniform (pxToSub 8))
      (BorderStyle.uniform bdr pal.border)
      ([ WidgetNode.rrect
          (BoxStyle.row 0
            |>.withAlign .center
            |>.withPadding (Edges.xy (pxToSub 10) 0)
            |>.withFixedSize cardInnerW (pxToSub 30))
          0x00000000
          CornerRadii.zero
          { widths := Edges.trbl 0 0 bdr 0, color := pal.borderSubtle }
           [screenTextLine theme (pxToSub 240) (pxToSub 17) (pxToSub 12) (pxToSub 17) pal.textPrimary "lean/OrbDesktop/OrbDesktop/Main.lean" 400 true]
      , WidgetNode.rrect
          (BoxStyle.row 0
            |>.withAlign .center
            |>.withPadding (Edges.xy (pxToSub 10) 0)
            |>.withFixedSize cardInnerW (pxToSub 23))
          hunkBg
          CornerRadii.zero
          BorderStyle.none
          [screenTextLine theme (cardInnerW - pxToSub 20) (pxToSub 16) (pxToSub 11) (pxToSub 16) pal.textSecondary
            "@@ -120,3 +120,3 @@ def renderDesktopFrame" 400 true]
      ] ++ diffRows)

  WidgetNode.box
    (BoxStyle.col 0
      |>.withFixedSize paneW paneH
      |>.withBg pal.canvas)
    [ toolbar
    , filesBar
    , WidgetNode.box
        (BoxStyle.col 0 |>.withPadding (Edges.all (pxToSub 12)) |>.withFixedSize paneW (paneH - pxToSub 82))
        [diffCard]
    ]

/-! ## 5. `05_machines_fleet` (`/?screen=machines`) -/

/-- Build a `.s-row` inside a `.s-card` for `05_machines_fleet`. -/
def buildMachineRow (theme : Theme) (w h : SubPx) (title desc rightText : String)
    (hasBottomBorder : Bool := false) (showChevron : Bool := true) : WidgetNode :=
  let pal := theme.palette
  let bdr := theme.borderWidth
  WidgetNode.rrect
    (BoxStyle.row 0
      |>.withAlign .center
      |>.withJustify .spaceBetween
      |>.withPadding (Edges.trbl 0 (pxToSub 18) 0 (pxToSub 48))
      |>.withFixedSize w h)
    0x00000000
    CornerRadii.zero
    (if hasBottomBorder then { widths := Edges.trbl 0 0 bdr 0, color := pal.borderSubtle } else BorderStyle.none)
    [ WidgetNode.box
        (BoxStyle.col (pxToSub 2) |>.withFixedSize (w - pxToSub 150) (pxToSub 36))
        [ screenTextLine theme (w - pxToSub 150) (pxToSub 18) (pxToSub 13) (pxToSub 18) pal.textPrimary title
        , screenTextLine theme (w - pxToSub 150) (pxToSub 16) (pxToSub 12) (pxToSub 16) pal.textSecondary desc
        ]
    , WidgetNode.box
        (BoxStyle.row (pxToSub 8) |>.withAlign .center |>.withFixedSize (pxToSub 76) (pxToSub 18))
        ([screenTextLine theme (pxToSub 52) (pxToSub 16) (pxToSub 12) (pxToSub 16) pal.textSecondary rightText] ++
        (if showChevron then [screenTextLine theme (pxToSub 16) (pxToSub 18) (pxToSub 14) (pxToSub 18) pal.textFaint "›"] else []))
    ]

/-- Build the Compute Fleet screen (`05_machines_fleet`) matching the `640 px` SolidJS `.s-inner` column. -/
def buildMachinesFleetBody (st : DesktopState) (mainW bodyH : SubPx) : WidgetNode :=
  let theme := st.theme
  let pal := theme.palette
  let bdr := theme.borderWidth
  let colW : SubPx := pxToSub 640
  let rowW : SubPx := colW - pxToSub 2

  let localCard : WidgetNode :=
    WidgetNode.rrect
      (BoxStyle.col 0 |>.withPadding (Edges.all bdr) |>.withFixedSize colW (pxToSub 62))
      pal.elevatedSurface
      (CornerRadii.uniform (pxToSub 10))
      (BorderStyle.uniform bdr (if st.selectedMachineId == "local" then pal.accent else pal.borderSubtle))
      [WidgetNode.focusable fleetLocalId <| buildMachineRow theme rowW (pxToSub 60) "This Mac" "Available in the Orb desktop app" (if st.selectedMachineId == "local" then "Selected" else "") false]

  let groupBg : Color := if theme.isDark then 0x242424FF else 0xEDECE9FF
  let groupBar : WidgetNode :=
    WidgetNode.rrect
      (BoxStyle.row 0
        |>.withAlign .center
        |>.withJustify .spaceBetween
        |>.withPadding (Edges.xy (pxToSub 14) 0)
        |>.withFixedSize rowW (pxToSub 34))
      groupBg
      CornerRadii.zero
      { widths := Edges.trbl 0 0 bdr 0, color := pal.borderSubtle }
      [ screenTextLine theme (pxToSub 160) (pxToSub 16) (pxToSub 11) (pxToSub 16) pal.textMuted "Managed (boat.dev)" 500
      , screenTextLine theme (pxToSub 120) (pxToSub 16) (pxToSub 11) (pxToSub 16) pal.textMuted "2 online · 3 active"
      ]

  let remoteCard : WidgetNode :=
    WidgetNode.rrect
      (BoxStyle.col 0 |>.withPadding (Edges.all bdr) |>.withFixedSize colW (pxToSub 279))
      pal.elevatedSurface
      (CornerRadii.uniform (pxToSub 10))
      (BorderStyle.uniform bdr pal.borderSubtle)
      [ WidgetNode.focusable fleetCoreId <| buildMachineRow theme rowW (pxToSub 61) "Core" "Connecting · Control plane" (if st.selectedMachineId == "core" then "Selected" else "") true
      , WidgetNode.focusable fleetPrimaryId <| buildMachineRow theme rowW (pxToSub 61) "orb-core-primary" "online" (if st.selectedMachineId == "node-core-01" then "Selected" else "3 active") true
      , groupBar
      , WidgetNode.focusable fleetLargeAId <| buildMachineRow theme rowW (pxToSub 61) "large-a   Managed" "online · 8 vCPU · 16 GB" (if st.selectedMachineId == "mm-large-a" then "Selected" else "2 active") true
      , WidgetNode.focusable fleetDefaultBId <| buildMachineRow theme rowW (pxToSub 60) "default-b   Managed" "online · 4 vCPU · 8 GB" (if st.selectedMachineId == "mm-default-b" then "Selected" else "1 active") false
      ]

  let swCard : WidgetNode :=
    WidgetNode.focusable fleetSoftwareId <|
      WidgetNode.rrect
        (BoxStyle.row 0
          |>.withAlign .center
          |>.withJustify .spaceBetween
          |>.withPadding (Edges.xy (pxToSub 15) 0)
          |>.withFixedSize colW (pxToSub 44))
        pal.elevatedSurface
        (CornerRadii.uniform (pxToSub 10))
        (BorderStyle.uniform bdr pal.borderSubtle)
        [ screenTextLine theme (pxToSub 200) (pxToSub 18) (pxToSub 13) (pxToSub 18) pal.textPrimary "Agent software"
        , screenTextLine theme (pxToSub 16) (pxToSub 18) (pxToSub 14) (pxToSub 18) pal.textFaint "›"
        ]

  let keyCard : WidgetNode :=
    WidgetNode.rrect
      (BoxStyle.row 0
        |>.withAlign .center
        |>.withJustify .spaceBetween
        |>.withPadding (Edges.xy (pxToSub 14) (pxToSub 14))
        |>.withFixedSize colW (pxToSub 76))
      pal.elevatedSurface
      (CornerRadii.uniform (pxToSub 10))
      (BorderStyle.uniform bdr pal.borderSubtle)
      [ WidgetNode.box
          (BoxStyle.col (pxToSub 4) |>.withFixedSize (pxToSub 480) (pxToSub 38))
          [ screenTextLine theme (pxToSub 480) (pxToSub 18) (pxToSub 13) (pxToSub 18) pal.textPrimary "Paloma public key"
          , screenTextLine theme (pxToSub 480) (pxToSub 17) (pxToSub 12) (pxToSub 17) pal.textSecondary "Couldn't read ~/.ssh/paloma.pub" 400 true
          ]
      , WidgetNode.focusable fleetCopyKeyId <|
          WidgetNode.rrect
            (BoxStyle.row 0 |>.withAlign .center |>.withJustify .center |>.withFixedSize (pxToSub 55) (pxToSub 28))
            0x00000000
            (CornerRadii.uniform (pxToSub 6))
            (BorderStyle.uniform bdr pal.border)
            [screenTextLine theme (pxToSub (if st.copiedPalomaKey then 42 else 36)) (pxToSub 16) (pxToSub 13) (pxToSub 16) pal.textSecondary (if st.copiedPalomaKey then "Copied" else "Copy") 500]
      ]

  let innerCol : WidgetNode :=
    WidgetNode.box
      (BoxStyle.col 0 |>.withFixedSize colW (bodyH - pxToSub 36))
      [ screenTextLine theme colW (pxToSub 28) (pxToSub 20) (pxToSub 28) pal.textPrimary "Machines" 600
      , screenTextLine theme colW (pxToSub 38) (pxToSub 13) (pxToSub 18) pal.textSecondary
          "Core metrics stream live. Node heartbeats and managed VMs appear below."
      , screenTextLine theme colW (pxToSub 25) (pxToSub 12) (pxToSub 17) pal.textMuted "Local" 500
      , localCard
      , WidgetNode.box (BoxStyle.col 0 |>.withFixedSize colW (pxToSub 24)) []
      , screenTextLine theme colW (pxToSub 25) (pxToSub 12) (pxToSub 17) pal.textMuted "Remote" 500
      , remoteCard
      , WidgetNode.box (BoxStyle.col 0 |>.withFixedSize colW (pxToSub 20)) []
      , swCard
      , WidgetNode.box (BoxStyle.col 0 |>.withFixedSize colW (pxToSub 24)) []
      , keyCard
      ]

  WidgetNode.box
    (BoxStyle.col 0
      |>.withAlign .center
      |>.withPadding (Edges.trbl (pxToSub 36) 0 0 0)
      |>.withFixedSize mainW bodyH
      |>.withBg pal.canvas)
    [innerCol]

/-! ## 6. `06_settings_general` (`/?screen=settings&tab=general`) -/

/-- Build one `.s-row` inside a Settings `.s-card`. -/
def buildSettingsRow (theme : Theme) (rowW h : SubPx) (title desc rightLabel : String)
    (isButton : Bool := false) (isCode : Bool := false) (hasBottomBorder : Bool := false)
    (isInput : Bool := false) (isSelect : Bool := false) (controlId : Option WidgetId := none) : WidgetNode :=
  let pal := theme.palette
  let bdr := theme.borderWidth
  let inputBg : Color := if theme.isDark then 0x202020FF else 0xFFFFFFFF
  let inputBdr : Color := if theme.isDark then 0x333333FF else 0xD8D8D8FF
  let labelW := rowW - pxToSub (if isInput then 276 else if isSelect then 96 else 148)
  let descH := pxToSub (if desc.contains '\n' then 34 else 17)
  let wrapCtrl (n : WidgetNode) : WidgetNode :=
    match controlId with
    | some cid => WidgetNode.focusable cid n
    | none => n
  let rightNode : WidgetNode :=
    if isInput then
      wrapCtrl <| WidgetNode.rrect
        (BoxStyle.row 0 |>.withAlign .center |>.withPadding (Edges.xy (pxToSub 10) 0) |>.withFixedSize (pxToSub 260) (pxToSub 32))
        inputBg
        (CornerRadii.uniform (pxToSub 6))
        (BorderStyle.uniform bdr inputBdr)
        [screenTextLine theme (pxToSub 240) (pxToSub 16) (pxToSub 12) (pxToSub 16) pal.textPrimary rightLabel]
    else if isSelect then
      wrapCtrl <| WidgetNode.rrect
        (BoxStyle.row 0 |>.withAlign .center |>.withPadding (Edges.xy (pxToSub 10) 0) |>.withFixedSize (pxToSub 80) (pxToSub 32))
        inputBg
        (CornerRadii.uniform (pxToSub 6))
        (BorderStyle.uniform bdr inputBdr)
        [screenTextLine theme (pxToSub 60) (pxToSub 16) (pxToSub 12) (pxToSub 16) pal.textPrimary rightLabel]
    else if rightLabel.isEmpty then
      WidgetNode.box (BoxStyle.row 0 |>.withFixedSize (pxToSub 10) (pxToSub 16)) []
    else if isButton then
      let bw := pxToSub (max 88 (rightLabel.length * 8 + 20))
      wrapCtrl <| WidgetNode.rrect
        (BoxStyle.row 0 |>.withAlign .center |>.withJustify .center |>.withFixedSize bw (pxToSub 28))
        0x00000000
        (CornerRadii.uniform (pxToSub 6))
        BorderStyle.none
        [screenTextLine theme (bw - pxToSub 16) (pxToSub 16) (pxToSub 13) (pxToSub 16) pal.textSecondary rightLabel 500]
    else if isCode then
      let cw := pxToSub (max 60 (rightLabel.length * 8 + 12))
      WidgetNode.rrect
        (BoxStyle.row 0 |>.withAlign .center |>.withJustify .center |>.withFixedSize cw (pxToSub 18))
        pal.codeBg
        (CornerRadii.uniform (pxToSub 4))
        BorderStyle.none
        [screenTextLine theme (cw - pxToSub 8) (pxToSub 14) (pxToSub 12) (pxToSub 14) pal.textPrimary rightLabel 400 true]
    else
      screenTextLine theme (pxToSub 56) (pxToSub 16) (pxToSub 13) (pxToSub 16) pal.textPrimary rightLabel

  WidgetNode.rrect
    (BoxStyle.row 0
      |>.withAlign .center
      |>.withJustify .spaceBetween
      |>.withFixedSize rowW h)
    0x00000000
    CornerRadii.zero
    (if hasBottomBorder then { widths := Edges.trbl 0 0 bdr 0, color := pal.borderSubtle } else BorderStyle.none)
    [ WidgetNode.box
        (BoxStyle.col (pxToSub 2) |>.withFixedSize labelW (pxToSub 19 + descH))
        [ screenTextLine theme labelW (pxToSub 17) (pxToSub 12) (pxToSub 17) pal.textPrimary title
        , screenTextLine theme labelW descH (pxToSub 12) (pxToSub 17) pal.textMuted desc
        ]
    , rightNode
    ]

private def inventoryTarget (theme : Theme) (hover : Option WidgetId) (id : WidgetId) (width height : SubPx) (child : WidgetNode) : WidgetNode :=
  WidgetNode.focusable id <| WidgetNode.box
    (BoxStyle.col 0 |>.withJustify .center |>.withFixedSize width height
      |>.withBg (if hover == some id then (theme.palette.textPrimary &&& 0xFFFFFF00) ||| 0x0C else 0x00000000))
    [child] (some id)

private def routeSettingsBody (st : DesktopState) (page : AccountRoutePage) (hover : Option WidgetId) (width height colW : SubPx) : WidgetNode := Id.run do
  let theme := st.theme
  let pal := theme.palette
  let line := fun (text : String) (color : Color) =>
    screenTextLine theme colW (pxToSub 22) (pxToSub 14) (pxToSub 22) color text
  let back := inventoryTarget theme hover providersBackId colW (pxToSub 42) (line "‹  Inference" pal.textSecondary)
  let heading := screenTextLine theme colW (pxToSub 36) (pxToSub 20) (pxToSub 30) pal.textPrimary page.account.name 600
  let pad := pxToSub 12
  let rowW := colW - 2 * pad
  let rowH := pxToSub 52
  let settings := page.options.getD []
  let options := settings.mapIdx fun i row =>
    let button := match row.action with
      | "routers" => if row.value == "off" then "Turn off" else "Turn on"
      | "vpn" =>
        if row.detail == "Confirm Direct route" then "Confirm"
        else if row.detail == "Retry verification" then "Retry"
        else "Select"
      | "refresh" => if row.title == "Account connection" && row.detail != "Could not load. Retry" then "Refresh" else "Retry"
      | _ => ""
    let body := buildSettingsRow theme rowW rowH row.title row.detail button
      (isButton := true) (hasBottomBorder := i + 1 < settings.length)
    if row.action.isEmpty || page.pending.isSome || page.failed then body
    else inventoryTarget theme hover (providerRouteId i) rowW rowH body
  let card := WidgetNode.rrect
    (BoxStyle.col 0 |>.withPadding (Edges.xy pad 0) |>.withFixedSize colW (rowH * options.length))
    pal.elevatedSurface (CornerRadii.uniform (pxToSub 8))
    (BorderStyle.uniform theme.borderWidth pal.borderSubtle) options
  let status := if page.failed then
      [inventoryTarget theme hover providersRetryId colW (pxToSub 42) (line "Could not load account settings. Retry" pal.textPrimary)]
    else if page.pending.isSome then [line "Saving…" pal.textSecondary]
    else if page.options.isNone then [line "Loading account settings…" pal.textSecondary]
    else if !st.writeError.isEmpty then [line st.writeError pal.textPrimary] else []
  let content := WidgetNode.box (BoxStyle.col (pxToSub 4) |>.withAlign .center)
    ([back, heading] ++ status ++ (if options.isEmpty then [] else [card]))
  return WidgetNode.scrollClip (BoxStyle.col 0 |>.withFixedSize width height)
    { offsetY := st.fleetTopSub } content (some fleetViewportId) (hitTestable := false)

/-- Give long inventories their full scroll extent while shaping only visible rows. -/
private def buildLiveInventory (st : DesktopState) (hover : Option WidgetId) (width height : SubPx) : WidgetNode := Id.run do
  let theme := st.theme
  let colW := min (pxToSub 640) (width - pxToSub 24)
  let rowH := pxToSub 60
  let providers := st.screen == .inference
  if providers then
    if let some page := st.accountRoutePage then return routeSettingsBody st page hover width height colW
  let accounts := st.providers.getD []
  let count := if providers then accounts.length else st.fleetMachines.length
  if count == 0 then
    let message := if !providers then "No machines connected"
      else if st.providerReadFailed then "Could not load accounts. Open Inference to retry."
      else if st.providers.isNone then "Loading accounts…"
      else "No provider accounts"
    return WidgetNode.box (BoxStyle.col 0 |>.withAlign .center |>.withJustify .center |>.withFixedSize width height)
      [screenTextLine theme colW (pxToSub 20) (pxToSub 13) (pxToSub 20) theme.palette.textSecondary message]
  let top := min st.fleetTopSub (count * rowH - height)
  let first := top / rowH
  let limit := height / rowH + 2
  let spacer := fun n => WidgetNode.box (BoxStyle.col 0 |>.withFixedSize colW (n * rowH)) []
  let rows := if providers then ((accounts.drop first).take limit).mapIdx fun i account =>
      let id := providerWidgetId (first + i)
      let availability := if account.globallyEnabled then "Use for my missions" else "Disabled globally"
      let detail := if account.category.isEmpty || account.category == account.name then availability
        else account.category ++ " · " ++ availability
      let preference := if account.userEnabled then "Using" else "Skipped"
      let settingsW := min (pxToSub 84) (colW / 4)
      let primaryW := colW - settingsW
      WidgetNode.box (BoxStyle.row 0 |>.withFixedSize colW rowH)
        [inventoryTarget theme hover id primaryW rowH (buildMachineRow theme primaryW rowH account.name detail preference true false),
         inventoryTarget theme hover (providerSettingsId (first + i)) settingsW rowH
           (screenTextLine theme settingsW (pxToSub 20) (pxToSub 13) (pxToSub 20) theme.palette.textSecondary "Settings ›")]
    else ((st.fleetMachines.drop first).take limit).mapIdx fun i m =>
      let detail := String.intercalate " · " ([m.roleLabel, m.cpuRamSpec].filter (!·.isEmpty))
      let row := buildMachineRow theme colW rowH (if m.name.isEmpty then m.machineId else m.name) detail m.state true false
      inventoryTarget theme hover (liveMachineWidgetId (first + i)) colW rowH row
  let content := WidgetNode.box (BoxStyle.col 0 |>.withAlign .center)
    ([spacer first] ++ rows ++ [spacer (count - first - rows.length)])
  return WidgetNode.scrollClip (BoxStyle.col 0 |>.withFixedSize width height)
    { offsetY := top } content (some fleetViewportId) (hitTestable := false)

/-- Build the Settings (`Account` tab) screen (`06_settings_general`) matching the `600 px` SolidJS column. -/
def buildSettingsGeneralBody (st : DesktopState) (mainW bodyH : SubPx) : WidgetNode :=
  let theme := st.theme
  let pal := theme.palette
  let bdr := theme.borderWidth
  let colW : SubPx := pxToSub 600
  let rowW : SubPx := pxToSub 576
  let themeLabel := if theme.isDark then "Dark" else "Light"

  let sCard (h : SubPx) (rows : List WidgetNode) : WidgetNode :=
    WidgetNode.rrect
      (BoxStyle.col 0
        |>.withPadding (Edges.xy (pxToSub 12) 0)
        |>.withFixedSize colW h)
      pal.elevatedSurface
      (CornerRadii.uniform (pxToSub 10))
      BorderStyle.none
      rows

  let tabsBar : WidgetNode :=
    let tabNode (id : WidgetId) (w : SubPx) (label : String) : WidgetNode :=
      let active := st.settingsTab == label
      WidgetNode.focusable id <|
        if active then
          WidgetNode.rrect
            (BoxStyle.row 0 |>.withAlign .center |>.withFixedSize w (pxToSub 30))
            0x00000000 CornerRadii.zero { widths := Edges.trbl 0 0 bdr 0, color := pal.textPrimary }
            [screenTextLine theme w (pxToSub 18) (pxToSub 13) (pxToSub 18) pal.textPrimary label]
        else
          screenTextLine theme w (pxToSub 18) (pxToSub 13) (pxToSub 18) pal.textMuted label
    WidgetNode.rrect
      (BoxStyle.row (pxToSub 16)
        |>.withAlign .center
        |>.withFixedSize (pxToSub 584) (pxToSub 30))
      0x00000000
      CornerRadii.zero
      { widths := Edges.trbl 0 0 bdr 0, color := pal.borderSubtle }
      [ tabNode settingsTabAccountId (pxToSub 64) "Account"
      , tabNode settingsTabUsersId (pxToSub 48) "Users"
      , tabNode settingsTabTelemetryId (pxToSub 116) "Usage telemetry"
      ]

  let headerBlock : WidgetNode :=
    WidgetNode.box
      (BoxStyle.col (pxToSub 8)
        |>.withPadding (Edges.xy (pxToSub 8) 0)
        |>.withFixedSize colW (pxToSub 122))
      [ screenTextLine theme (pxToSub 584) (pxToSub 22) (pxToSub 16) (pxToSub 22) pal.textPrimary "Account" 500
      , screenTextLine theme (pxToSub 584) (pxToSub 26) (pxToSub 13) (pxToSub 18) pal.textSecondary
          "Your server connection, connected accounts, how Orb looks and usage telemetry."
      , tabsBar
      ]

  let secLabel (txt : String) : WidgetNode :=
    WidgetNode.box
      (BoxStyle.row 0 |>.withPadding (Edges.trbl (pxToSub 26) (pxToSub 8) (pxToSub 8) (pxToSub 8)) |>.withFixedSize colW (pxToSub 51))
      [screenTextLine theme (pxToSub 584) (pxToSub 17) (pxToSub 12) (pxToSub 17) pal.textSecondary txt]

  let apiUrlText := st.settingsApiUrl.text ++ st.settingsApiUrl.imePreeditText
  let connectedDesc :=
    if st.settingsActionNote.isEmpty then "Signed in to http://127.0.0.1:14470."
    else "Status: " ++ st.settingsActionNote
  let backendCard := sCard (pxToSub 125)
    [ buildSettingsRow theme rowW (pxToSub 63) "API URL" "Base URL of the Core backend." apiUrlText false false true true false (some settingsApiUrlId)
    , buildSettingsRow theme rowW (pxToSub 62) "Connected" connectedDesc "Disconnect" true false false false false (some settingsDisconnectId)
    ]

  let githubCard := sCard (pxToSub 62)
    [ buildSettingsRow theme rowW (pxToSub 62) "Mission git & gh credentials"
        "Configure GITHUB_OAUTH_CLIENT_ID on Core to connect." "Connect GitHub" true false false false false (some settingsConnectGhId) ]

  let cloudCard := sCard (pxToSub 79)
    [ buildSettingsRow theme rowW (pxToSub 79) "Connected services"
        "Cloud agents use accounts connected to Core. Connecting an account\ndoes not start work." "Refresh accounts" true false false false false (some settingsRefreshCloudId) ]

  let appearCard := sCard (pxToSub 125)
    [ buildSettingsRow theme rowW (pxToSub 63) "Theme" "Auto follows your desktop appearance." themeLabel false false true false true (some settingsThemeId)
    , buildSettingsRow theme rowW (pxToSub 62) "Background sync" "Active — keeping recent conversations live; pauses automatically on slow links." st.settingsSyncMode false false false false true (some settingsSyncId)
    ]

  let aboutCard := sCard (pxToSub 116)
    [ buildSettingsRow theme rowW (pxToSub 63) "Client build commit" "Orb 0.13.0" "00000000" false true true
    , buildSettingsRow theme rowW (pxToSub 53) "Server build commit" "Reported by the connected Core via /api/health." "Unknown" false true false
    ]

  let innerCol : WidgetNode :=
    WidgetNode.box
      (BoxStyle.col 0 |>.withFixedSize colW (bodyH - pxToSub 32))
      [ headerBlock
      , WidgetNode.box
          (BoxStyle.row 0 |>.withPadding (Edges.xy (pxToSub 8) (pxToSub 4)) |>.withFixedSize colW (pxToSub 25))
          [screenTextLine theme (pxToSub 584) (pxToSub 17) (pxToSub 12) (pxToSub 17) pal.textSecondary "Backend"]
      , backendCard
      , secLabel "GitHub"
      , githubCard
      , secLabel "Cloud accounts"
      , cloudCard
      , secLabel "Appearance"
      , appearCard
      , secLabel "About"
      , aboutCard
      ]

  WidgetNode.box
    (BoxStyle.col 0
      |>.withAlign .center
      |>.withPadding (Edges.trbl (pxToSub 32) 0 0 0)
      |>.withFixedSize mainW bodyH
      |>.withBg pal.canvas)
    [innerCol]

/-! ## 7. Search Dialog Overlay (`07_search_dialog`) -/

/-- Build the full-window Search Dialog modal overlay (`x=295, y=74, w=880, h=580`) over the backdrop scrim. -/
def buildSearchModalOverlay (theme : Theme) (availW availH : SubPx)
    (spec : SearchDialogSpec := defaultSearchDialogSpec)
    (filterTab : String := "All")
    (projectFilter : String := "All projects")
    (timeFilter : String := "Any time")
    (sortOrder : String := "Relevance")
    (useReferenceList : Bool := true)
    (searchBuf : ComposerBuffer := {}) : WidgetNode :=
  let pal := theme.palette
  let bdr := theme.borderWidth
  let scrimCol : Color := if theme.isDark then 0x0000006B else 0x1E1E1C40
  let dlgBg : Color := if theme.isDark then 0x191919FF else 0xFAFAFAFF
  let previewBg : Color := if theme.isDark then 0x161616FF else 0xFDFDFDFF
  let selBg : Color := if theme.isDark then 0x292929FF else 0xE6E6E6FF
  let dlgW : SubPx := pxToSub 880
  let dlgH : SubPx := pxToSub 580
  let innerW : SubPx := pxToSub 878
  let queryDisplay := if spec.query.isEmpty then spec.placeholder else spec.query
  let queryColor := if spec.query.isEmpty then pal.textMuted else pal.textStrong
  let searchCaretPos :=
    if spec.query.isEmpty then 0
    else if searchBuf.displayText == spec.query then
      ComposerBuffer.clampCursor searchBuf.text searchBuf.cursorOffset + searchBuf.imePreeditText.length
    else spec.query.length

  let searchBar : WidgetNode :=
    WidgetNode.box
      (BoxStyle.row (pxToSub 10)
        |>.withAlign .center
        |>.withPadding (Edges.trbl 0 (pxToSub 14) 0 (pxToSub 16))
        |>.withFixedSize innerW (pxToSub 46))
      [ chromeIcon "search" pal.textSecondary 16
      , WidgetNode.focusable spec.inputWidgetId <|
          let stRun : TextStyle := { Theme.bodyText theme with
            sizeSub := pxToSub 15, lineHeightSub := pxToSub 22, color := queryColor, weight := 400 }
          let baseRun := overlaySynthRun stRun queryDisplay
          let run := if spec.query.isEmpty then baseRun else { baseRun with editorStart := some 0 }
          WidgetNode.text
            ({ BoxStyle.row 0 |>.withFixedSize (pxToSub 748) (pxToSub 22) with clip := true })
            (pxToSub 22) [run] none
            (some { owner := spec.inputWidgetId, pos := searchCaretPos, length := spec.query.length, color := pal.textPrimary })
      , WidgetNode.focusable searchClearId <|
          WidgetNode.box
            (BoxStyle.row 0 |>.withAlign .center |>.withJustify .center |>.withFixedSize (pxToSub 22) (pxToSub 22))
            [chromeIcon "close" pal.textMuted 14]
      , WidgetNode.focusable searchEscId <|
          WidgetNode.rrect
            (BoxStyle.row 0 |>.withAlign .center |>.withJustify .center |>.withFixedSize (pxToSub 32) (pxToSub 20))
            0x00000000 (CornerRadii.uniform (pxToSub 4)) (BorderStyle.uniform bdr pal.borderSubtle)
            [screenTextLine theme (pxToSub 22) (pxToSub 15) (pxToSub 11) (pxToSub 15) pal.textMuted "Esc" 500]
      ]

  let filterPill (id : WidgetId) (w : Nat) (label : String) : WidgetNode :=
    let active := filterTab == label
    WidgetNode.focusable id <|
      if active then
        WidgetNode.rrect
          (BoxStyle.row 0 |>.withAlign .center |>.withJustify .center |>.withFixedSize (pxToSub w) (pxToSub 24))
          selBg (CornerRadii.uniform (pxToSub 6)) BorderStyle.none
          [screenTextLine theme (pxToSub (w - 11)) (pxToSub 17) (pxToSub 12) (pxToSub 17) pal.textStrong label 500]
      else
        screenTextLine theme (pxToSub w) (pxToSub 17) (pxToSub 12) (pxToSub 17) pal.textMuted label

  let toolBar : WidgetNode :=
    WidgetNode.box
      (BoxStyle.row (pxToSub 8)
        |>.withAlign .center
        |>.withJustify .spaceBetween
        |>.withPadding (Edges.trbl 0 (pxToSub 12) (pxToSub 9) (pxToSub 10))
        |>.withFixedSize innerW (pxToSub 34))
      [ WidgetNode.box
          (BoxStyle.row (pxToSub 6) |>.withAlign .center |>.withFixedSize (pxToSub 260) (pxToSub 24))
          [ filterPill searchTabAllId 31 "All"
          , filterPill searchTabUserId 38 "User"
          , filterPill searchTabAssistantId 64 "Assistant"
          , filterPill searchTabTitlesId 42 "Titles"
          , filterPill searchTabToolsId 42 "Tools"
          ]
      , WidgetNode.box (BoxStyle.row (pxToSub 2) |>.withAlign .center |>.withFixedSize (pxToSub 250) (pxToSub 24))
          ([ (searchProjectFilterId, projectFilter, 90), (searchTimeFilterId, timeFilter, 76), (searchSortOrderId, sortOrder, 80) ].map fun (fid, label, width) =>
            WidgetNode.focusable fid <|
              WidgetNode.box
                (BoxStyle.row (pxToSub 4) |>.withAlign .center |>.withFixedSize (pxToSub width) (pxToSub 24))
                [screenTextLine theme (pxToSub (width - 20)) (pxToSub 16) (pxToSub 12) (pxToSub 16) pal.textMuted label,
                 chromeIcon "chevron-down" pal.textMuted 12])
      ]

  let headerNode : WidgetNode :=
    WidgetNode.rrect
      (BoxStyle.col 0 |>.withFixedSize innerW (pxToSub 80))
      0x00000000
      CornerRadii.zero
      { widths := Edges.trbl 0 0 bdr 0, color := pal.borderSubtle }
      [searchBar, toolBar]

  let resultRow (wid : WidgetId) (selected : Bool) (title subtitle suffix : String) : WidgetNode :=
    WidgetNode.focusable wid <|
      WidgetNode.rrect
        (BoxStyle.col (pxToSub 3)
          |>.withPadding (Edges.xy (pxToSub 10) (pxToSub 7))
          |>.withFixedSize (pxToSub 347) (pxToSub 52))
        (if selected then selBg else 0x00000000)
        (CornerRadii.uniform (pxToSub 7))
        BorderStyle.none
        [ WidgetNode.box
            (BoxStyle.row 0 |>.withAlign .center |>.withJustify .spaceBetween |>.withFixedSize (pxToSub 327) (pxToSub 18))
            [ screenTextLine theme (pxToSub 210) (pxToSub 18) (pxToSub 13) (pxToSub 18) pal.textStrong title 550
            , screenTextLine theme (pxToSub 104) (pxToSub 15) (pxToSub 11) (pxToSub 15) pal.textMuted subtitle
            ]
        , WidgetNode.box (BoxStyle.row 0 |>.withAlign .center |>.withFixedSize (pxToSub 327) (pxToSub 18))
            [ screenTextLine theme (pxToSub 29) (pxToSub 18) (pxToSub 11) (pxToSub 18) pal.textMuted "Title"
            , WidgetNode.rrect
                (BoxStyle.row 0 |>.withFixedSize (pxToSub 48) (pxToSub 15))
                (if theme.isDark then 0x635A35FF else 0xDCD5BFFF)
                (CornerRadii.uniform (pxToSub 2)) BorderStyle.none
                [screenTextLine theme (pxToSub 48) (pxToSub 15) (pxToSub 12) (pxToSub 15) pal.textStrong "Mission"]
            , screenTextLine theme (pxToSub 250) (pxToSub 18) (pxToSub 12) (pxToSub 18) pal.textSecondary suffix
            ]
        ]

  let defaultFilters :=
    filterTab == "All" && projectFilter == "All projects" &&
    timeFilter == "Any time" && sortOrder == "Relevance"
  let filteredItems := filterSearchItemsWithFilters spec filterTab projectFilter timeFilter sortOrder
  let startIdx := if spec.selectedIdx >= 7 then spec.selectedIdx - 6 else 0
  let resultNodes : List WidgetNode :=
    if useReferenceList && defaultFilters && spec.query == "mission" && spec.items == defaultSearchDialogSpec.items then
      [ resultRow 702 (spec.selectedIdx == 0) "Mission 1 doing some work" "Project 1 · 15m ago" " 1 doing some work"
      , resultRow 703 (spec.selectedIdx == 1) "Mission 2 doing some work" "Project 1 · 15m ago" " 2 doing some work"
      , resultRow 704 (spec.selectedIdx == 2) "Mission 21 doing some work" "Project 1 · 15m ago" " 21 doing some work"
      ]
    else
      ((filteredItems.drop startIdx).take 7).mapIdx fun i it =>
        resultRow it.widgetId (startIdx + i == spec.selectedIdx) it.title it.subtitle (" " ++ it.category)

  let leftPane : WidgetNode :=
    WidgetNode.rrect
      (BoxStyle.col (pxToSub 5)
        |>.withPadding (Edges.all (pxToSub 6))
        |>.withFixedSize (pxToSub 360) (pxToSub 468))
      0x00000000
      CornerRadii.zero
      { widths := Edges.trbl 0 bdr 0 0, color := pal.borderSubtle }
      resultNodes

  let previewTurn (isTarget : Bool) (role body : String) : WidgetNode :=
    WidgetNode.rrect
      (BoxStyle.col (pxToSub 4)
        |>.withPadding (Edges.xy (pxToSub 13) (pxToSub 9))
        |>.withFixedSize (pxToSub 482) (pxToSub 57))
      (if isTarget then (if theme.isDark then 0x1F1F1FFF else 0xF2F2F2FF) else 0x00000000)
      (CornerRadii.uniform (pxToSub 8))
      (if isTarget then
        { widths := Edges.trbl 0 0 0 (pxToSub 3), color := pal.accent }
       else BorderStyle.none)
      [ WidgetNode.box
          (BoxStyle.row 0 |>.withAlign .center |>.withJustify .spaceBetween |>.withFixedSize (pxToSub 456) (pxToSub 16))
          [ screenTextLine theme (pxToSub 80) (pxToSub 16) (pxToSub 11) (pxToSub 16) pal.textSecondary role 550
          , screenTextLine theme (pxToSub 56) (pxToSub 16) (pxToSub 11) (pxToSub 16) pal.textMuted (if isTarget then "16m ago" else "15m ago")
          ]
      , screenTextLine theme (pxToSub 456) (pxToSub 20) (pxToSub 12 + subPerPx / 2) (pxToSub 20)
          (if isTarget then pal.textPrimary else pal.textSecondary) body
      ]

  let selectedTitle :=
    if useReferenceList && defaultFilters && spec.query == "mission" && spec.items == defaultSearchDialogSpec.items then
      match spec.selectedIdx with
      | 1 => "Mission 2 doing some work"
      | 2 => "Mission 21 doing some work"
      | _ => "Mission 1 doing some work"
    else
      (filteredItems[spec.selectedIdx]?.map (·.title)).getD "No matching mission"
  let selectedMeta :=
    if useReferenceList && defaultFilters && spec.query == "mission" && spec.items == defaultSearchDialogSpec.items then
      "Project 1 · 15m ago"
    else
      (filteredItems[spec.selectedIdx]?.map (·.subtitle)).getD ""

  let rightPane : WidgetNode :=
    WidgetNode.rrect
      (BoxStyle.col 0 |>.withFixedSize (pxToSub 518) (pxToSub 468))
      previewBg
      CornerRadii.zero
      BorderStyle.none
      [ WidgetNode.rrect
          (BoxStyle.row 0
            |>.withAlign .start
            |>.withJustify .spaceBetween
            |>.withPadding (Edges.xy (pxToSub 18) (pxToSub 14))
            |>.withFixedSize (pxToSub 518) (pxToSub 64))
          0x00000000
          CornerRadii.zero
          { widths := Edges.trbl 0 0 bdr 0, color := pal.borderSubtle }
          [ WidgetNode.box
              (BoxStyle.col (pxToSub 2) |>.withFixedSize (pxToSub 300) (pxToSub 36))
              [ screenTextLine theme (pxToSub 300) (pxToSub 19) (pxToSub 14) (pxToSub 19) pal.textStrong selectedTitle 600
              , screenTextLine theme (pxToSub 300) (pxToSub 16) (pxToSub 12) (pxToSub 16) pal.textMuted selectedMeta
              ]
          , WidgetNode.focusable searchOpenId <|
              WidgetNode.rrect
                (BoxStyle.row 0 |>.withAlign .center |>.withJustify .center |>.withMargin (Edges.trbl (pxToSub 1) 0 0 0) |>.withFixedSize (pxToSub 67) (pxToSub 26))
                (if theme.isDark then 0x222222FF else 0xF2F2F2FF) (CornerRadii.uniform (pxToSub 6)) (BorderStyle.uniform bdr pal.border)
                [screenTextLine theme (pxToSub 48) (pxToSub 17) (pxToSub 12) (pxToSub 17) pal.textStrong "Open ↵" 500]
          ]
      , WidgetNode.box
          (BoxStyle.col (pxToSub 4)
            |>.withPadding (Edges.xy (pxToSub 18) (pxToSub 10))
            |>.withFixedSize (pxToSub 518) (pxToSub 404))
          [ previewTurn true "User" "Please inspect module 1 and fix what is broken."
          , previewTurn false "Assistant" "The change keeps behaviour identical."
          ]
      ]

  let matchCountLabel :=
    if useReferenceList && defaultFilters && spec.query == "mission" && spec.items == defaultSearchDialogSpec.items then "3 matches"
    else s!"{filteredItems.length} matches"

  let footerNode : WidgetNode :=
    WidgetNode.rrect
      (BoxStyle.row 0
        |>.withAlign .center
        |>.withJustify .spaceBetween
        |>.withPadding (Edges.xy (pxToSub 16) 0)
        |>.withFixedSize innerW (pxToSub 30))
      0x00000000
      CornerRadii.zero
      { widths := Edges.trbl bdr 0 0 0, color := pal.borderSubtle }
      [ screenTextLine theme (pxToSub 160) (pxToSub 16) (pxToSub 11) (pxToSub 16) pal.textMuted "↑↓ Navigate   ↵ Open"
      , screenTextLine theme (pxToSub 64) (pxToSub 16) (pxToSub 11) (pxToSub 16) pal.textMuted matchCountLabel
      ]

  let dlgCard : WidgetNode :=
    -- SearchDialog.css: color-mix(in srgb, var(--fg) 8%, var(--stroke)).
    let channel (shift : Nat) :=
      ((((pal.textPrimary >>> shift.toUInt32) &&& 255).toNat * 8 +
        ((pal.border >>> shift.toUInt32) &&& 255).toNat * 92 + 50) / 100).toUInt32
    let dialogBorder : Color :=
      (channel 24 <<< 24) ||| (channel 16 <<< 16) ||| (channel 8 <<< 8) ||| 255
    WidgetNode.rrect
      (BoxStyle.col 0
        |>.withPadding (Edges.all bdr)
        |>.withFixedSize dlgW dlgH
       |>.withShadow { offsetY := pxToSub 18, blur := pxToSub 48, color := if theme.isDark then 0x0000007F else 0x1E1E1C38 })
      dlgBg
      (CornerRadii.uniform (pxToSub 12))
      (BorderStyle.uniform bdr dialogBorder)
      [ headerNode
      , WidgetNode.box (BoxStyle.row 0 |>.withFixedSize innerW (pxToSub 468)) [leftPane, rightPane]
      , footerNode
      ]
      (some searchDialogCardId)

  WidgetNode.rrect
    (BoxStyle.col 0
      |>.withAlign .center
      |>.withPadding (Edges.trbl (pxToSub 74) 0 0 0)
      |>.withFixedSize availW availH)
    scrimCol
    CornerRadii.zero
    BorderStyle.none
    [dlgCard]

/-! ## 8. Complete `OrbDesktop` Screen Assembly -/

/-- Build the complete declarative `WidgetNode` tree for any `DesktopState`, viewport `(availW, availH)`
in `SubPx`, and optional pre-shaped `ShapedScreenRuns`. `windowEffects` is enabled only by the
live Wayland runtime so deterministic golden renders retain the opaque parity palette. -/
def buildDesktopScreen (st : DesktopState) (availW availH : SubPx)
    (runs : ShapedScreenRuns := {}) (windowEffects : Bool := false) (hoverRow : Option WidgetId := none) : WidgetNode :=
  let st := if windowEffects then { st with theme := Theme.withWindowEffects st.theme } else st
  let theme := st.theme
  let pal := theme.palette
  -- Paint each window surface once. Nested canvas fills otherwise obscure the compositor backdrop.
  let mainFill := pal.canvas
  let st := if windowEffects then
      { st with theme := { theme with palette := { pal with canvas := 0, header := 0 } } }
    else st
  let sidebarW := st.sidebarWidth
  let headerH := chromeHeaderHeightSub
  let composerH := chromeComposerHeightSub
  let mainW : SubPx := availW - sidebarW
  let useRefSidebar := !st.liveData && !runs.headerTitleRuns.isEmpty
  let sidebarNode := buildSidebarChrome st availH useRefSidebar hoverRow
  let headerNode := buildHeaderChrome st mainW runs.headerTitleRuns

  let rightColumn : WidgetNode :=
    match st.screen with
    | .cloud => Id.run do
      let w := min (pxToSub 608) (mainW - pxToSub 32)
      let line := fun width title =>
        screenTextLine theme width (pxToSub 36) (pxToSub 14) (pxToSub 24) pal.textPrimary title
      let button := fun id width title => inventoryTarget theme hoverRow id width (pxToSub 36) (line width title)
      let topic := if st.cloudMission.isEmpty then "connected accounts" else "conversation"
      let heading := if st.cloudMission.isEmpty then "Connected accounts" else
        ((st.missionCards.find? (·.missionId == st.cloudMission)).map (·.title)).getD "Conversation"
      let toolbar := (if st.cloudMission.isEmpty then [] else [button 963 (w / 3) "Back"]) ++
        (if st.cloudFailed || st.cloudLines.isSome then [button 960 (w / 3) (if st.cloudFailed then "Retry" else "Refresh")] else [])
      let status := if st.cloudFailed then [line w ("Could not load " ++ topic ++ ".")]
        else if st.cloudLines.isNone then [line w ("Loading " ++ topic ++ "…")]
        else if st.cloudLines == some [] then [line w (if st.cloudMission.isEmpty then "No connected accounts" else "No turns yet")]
        else []
      let items := st.cloudItems
      let rows := ((items.drop (4 * st.cloudPage)).take 4).mapIdx fun i (mission, title) =>
        if mission.isEmpty then line w title else button (964 + i) w title
      let create := st.cloudCanCreate
      let picks := if create then Id.run do
        let projects := st.cloudProjects
        let profile := (st.cloudAccounts[st.cloudAccountIndex]?.map (·.2.2)).getD ""
        let project := (st.cloudSelectedProject.map (·.title)).getD ""
        let pick := fun id count caption => if count > 1 then button id (w / 2) (caption ++ " ›") else line (w / 2) caption
        return [WidgetNode.box (BoxStyle.row 0) [pick 971 projects.length project, pick 970 st.cloudAccounts.length profile]]
        else []
      let editor := if create || st.cloudAllows "send" then
        let placeholder := if create then "Describe a task for your cloud agent" else "Send follow-up"
        let runs := buildComposerInlineRuns theme { st.cloudDraft with placeholder }
        let innerW := w - pxToSub 32
        let editorH := max (pxToSub (if create then 74 else 50)) (min (pxToSub 150) ((wrapInlineRuns innerW (pxToSub 20) runs).2.2 + pxToSub 20))
        let field := WidgetNode.rrect
          (BoxStyle.col 0 |>.withPadding (Edges.xy (pxToSub 16) (pxToSub 10)) |>.withFixedSize w editorH)
          pal.elevatedSurface (CornerRadii.uniform (pxToSub 12)) (BorderStyle.uniform theme.borderWidth pal.border)
          [WidgetNode.text (BoxStyle.row 0 |>.withFixedSize innerW (editorH - pxToSub 20)) (pxToSub 20) runs]
        [inventoryTarget theme hoverRow 1 w editorH field] ++
          (if st.cloudDraft.text.trimAscii.isEmpty || !st.cloudDraft.imePreeditText.isEmpty then [] else [button 968 (w / 3) (if create then "Create cloud agent" else "Send")])
        else []
      let actions := picks ++ editor ++ (if st.cloudAllows "cancel" then [button 969 (w / 3) "Stop"] else [])
      let errors := if st.writeError.isEmpty then [] else [line w st.writeError]
      let pager := (if st.cloudPage > 0 then [button 961 (w / 3) "Previous"] else []) ++
        (if 4 * (st.cloudPage + 1) < items.length then [button 962 (w / 3) "Next"] else [])
      let body := WidgetNode.box
        (BoxStyle.col (pxToSub 3) |>.withAlign .center |>.withJustify .center |>.withFixedSize mainW (availH - headerH))
        ([WidgetNode.box (BoxStyle.row 0) ([line (w / 3) heading] ++ toolbar)] ++ status ++ rows ++
          [WidgetNode.box (BoxStyle.row 0) pager] ++ actions ++ errors)
      return WidgetNode.box (BoxStyle.col 0 |>.withFixedSize mainW availH |>.withBg mainFill) [headerNode, body]
    | .resources => Id.run do
      let w := min (pxToSub 640) (mainW - pxToSub 24)
      let line := fun (width : SubPx) (t : String) =>
        screenTextLine theme width (pxToSub 32) (pxToSub 14) (pxToSub 24) pal.textPrimary t
      let button := fun id width title =>
        inventoryTarget theme hoverRow id width (pxToSub 32) (line width title)
      let ranges := resourceRanges.mapIdx fun i range =>
        button (955 + i) (w / 7) (if st.resourceRange == range then "✓ " ++ range else range)
      let toolbar := WidgetNode.box (BoxStyle.row 0) (ranges ++ [button 945 (2 * w / 7) "Refresh"])
      let rows := st.resourceRows.getD []
      let controls := WidgetNode.box (BoxStyle.row (pxToSub 6))
        [button 946 (w / 3) "Previous", line (w / 4) s!"{st.resourcePage + 1} / {(rows.length + 3) / 4}",
         button 947 (w / 3) "Next"]
      let items := ((rows.drop (4 * st.resourcePage)).take 4).mapIdx fun i r =>
        let canOpen := !r.mission.isEmpty && st.missionCards.any (·.missionId == r.mission)
        let item := buildMachineRow theme w (pxToSub 60) r.title r.usage (if canOpen then "Open ›" else "") true false
        if canOpen then inventoryTarget theme hoverRow (950 + i) w (pxToSub 60) item else item
      let content := if st.resourceFailed then [line w "Could not load resources. Refresh to retry."]
        else if st.resourceRows.isNone then [line w "Loading resources…"]
        else if rows.isEmpty then [line w s!"No resource usage · {st.resourceRange}"]
        else items ++ (if rows.length > 4 then [controls] else [])
      return WidgetNode.box (BoxStyle.col 0 |>.withAlign .center |>.withFixedSize mainW availH |>.withBg mainFill) (headerNode :: toolbar :: content)
    | .inbox => Id.run do
      let line := fun (w : SubPx) (text : String) => screenTextLine theme w (pxToSub 32) (pxToSub 14) (pxToSub 24) pal.textPrimary text
      let button := fun (id : Nat) (width : SubPx) (title : String) =>
        WidgetNode.focusable id <| WidgetNode.box (BoxStyle.row 0) [line width title] (some id)
      let content := if !st.inboxAvailable then [line mainW "Inbox unavailable. Retrying…"] else match st.currentInboxItem with
        | none => [line mainW "No unread items"]
        | some item =>
          let title := item.card.title
          let index := min st.inboxIndex (st.inboxItems.length - 1)
          [line mainW s!"{index + 1} of {st.inboxItems.length}",
           button 940 mainW ("Open · " ++ title),
           WidgetNode.box (BoxStyle.row (pxToSub 12))
             ([button 941 (pxToSub 96) "Mark read"] ++ (if index > 0 then [button 942 (pxToSub 80) "Previous"] else []) ++
              (if index + 1 < st.inboxItems.length then [button 943 (pxToSub 64) "Next"] else []))]
      return WidgetNode.box (BoxStyle.col 0 |>.withFixedSize mainW availH |>.withBg mainFill) (headerNode :: content)
    | .missionTranscript =>
      let splitH := availH - headerH
      if st.sidePanelOpen then
        let rightW : SubPx := min (pxToSub 480) (mainW / 2)
        let leftW : SubPx := mainW - rightW
        let leftBodyH := splitH - composerH
        let leftTranscript := buildMissionTranscriptBody st leftW leftBodyH runs hoverRow
        let retrySend := st.unconfirmedSend.any (·.2 == st.composer.text)
        let leftComposer := buildComposerWidget theme leftW composerH
          { st.composer with isRunning := st.composer.isRunning && !retrySend } []
          (if st.liveData then some (liveComposerControls st (min (pxToSub 748) (leftW - pxToSub 68))) else none)
        let leftPane : WidgetNode :=
          WidgetNode.rrect
            (BoxStyle.col 0 |>.withFixedSize leftW splitH)
            st.theme.palette.canvas
            CornerRadii.zero
            { widths := Edges.trbl 0 theme.borderWidth 0 0, color := pal.borderSubtle }
            [leftTranscript, leftComposer]
        let rightPane : WidgetNode :=
          if st.sidePanelTab == "diff" then
            buildSplitDiffRightPane theme rightW splitH runs.diffDelRuns runs.diffAddRuns st.diffMode st.diffRef true st.diffRefreshCount
          else
            let title := if st.sidePanelTab == "files" then "Files" else "Side question"
            let bodyMsg := if st.sidePanelTab == "files" then "Workspace files for this mission" else "Ask a side question without interrupting the main turn"
            WidgetNode.box
              (BoxStyle.col (pxToSub 8) |>.withPadding (Edges.all (pxToSub 12)) |>.withFixedSize rightW splitH |>.withBg pal.canvas)
              [ WidgetNode.box (BoxStyle.row 0 |>.withAlign .center |>.withJustify .spaceBetween |>.withFixedSize (rightW - pxToSub 24) (pxToSub 28))
                  [ screenTextLine theme (rightW - pxToSub 56) (pxToSub 20) (pxToSub 14) (pxToSub 20) pal.textPrimary title 600
                  , WidgetNode.focusable sidePanelCloseId <|
                      WidgetNode.box (BoxStyle.row 0 |>.withAlign .center |>.withJustify .center |>.withFixedSize (pxToSub 24) (pxToSub 24))
                        [chromeIcon "close" pal.textMuted 14]
                  ]
              , screenTextLine theme (rightW - pxToSub 24) (pxToSub 20) (pxToSub 12) (pxToSub 20) pal.textSecondary bodyMsg
              ]
        let splitBody : WidgetNode :=
          WidgetNode.box (BoxStyle.row 0 |>.withFixedSize mainW splitH |>.withBg st.theme.palette.canvas)
            [leftPane, rightPane]
        WidgetNode.box
          (BoxStyle.col 0 |>.withFixedSize mainW availH |>.withBg mainFill)
          [headerNode, splitBody]
      else
        let bodyH := availH - headerH - composerH
        let bodyNode := buildMissionTranscriptBody st mainW bodyH runs hoverRow
        let retrySend := st.unconfirmedSend.any (·.2 == st.composer.text)
        let composerNode := buildComposerWidget theme mainW composerH
          { st.composer with isRunning := st.composer.isRunning && !retrySend } []
          (if st.liveData then some (liveComposerControls st (min (pxToSub 748) (mainW - pxToSub 68))) else none)
        WidgetNode.box
          (BoxStyle.col 0 |>.withFixedSize mainW availH |>.withBg mainFill)
          [headerNode, bodyNode, composerNode]
    | .missionSplitDiff =>
      let splitH := availH - headerH
      let leftW : SubPx := pxToSub 688
      let rightW : SubPx := mainW - leftW
      let leftBodyH := splitH - composerH
      let leftTranscript := buildMissionTranscriptBody st leftW leftBodyH runs
      let leftComposer := buildComposerWidget theme leftW composerH st.composer
      let leftPane : WidgetNode :=
        WidgetNode.rrect
          (BoxStyle.col 0 |>.withFixedSize leftW splitH)
          st.theme.palette.canvas
          CornerRadii.zero
          { widths := Edges.trbl 0 theme.borderWidth 0 0, color := pal.borderSubtle }
          [leftTranscript, leftComposer]
      let rightPane :=
        if st.diffMode == "split" && st.diffRef == "Working tree vs HEAD" && st.diffRefreshCount == 0 then
          buildSplitDiffRightPane theme rightW splitH runs.diffDelRuns runs.diffAddRuns
        else
          buildSplitDiffRightPane theme rightW splitH runs.diffDelRuns runs.diffAddRuns st.diffMode st.diffRef false st.diffRefreshCount
      let splitBody : WidgetNode :=
        WidgetNode.box
          (BoxStyle.row 0 |>.withFixedSize mainW splitH |>.withBg st.theme.palette.canvas)
          [leftPane, rightPane]
      WidgetNode.box
        (BoxStyle.col 0 |>.withFixedSize mainW availH |>.withBg mainFill)
        [headerNode, splitBody]
    | .machinesFleet | .inference =>
      let bodyH := availH - headerH
      WidgetNode.box
        (BoxStyle.col 0 |>.withFixedSize mainW availH |>.withBg mainFill)
        [headerNode, if st.hasLiveConnection then buildLiveInventory st hoverRow mainW bodyH else buildMachinesFleetBody st mainW bodyH]
    | .settingsGeneral =>
      let bodyH := availH - headerH
      WidgetNode.box
        (BoxStyle.col 0 |>.withFixedSize mainW availH |>.withBg mainFill)
        [headerNode, if st.liveData then
          let width := min (pxToSub 584) (max 0 (mainW - pxToSub 24))
          let line := fun text color => screenTextLine theme width (pxToSub 28) (pxToSub 14) (pxToSub 20) color text
          let status := if st.initialRosterPending then "Connecting to Core…"
            else if st.hasLiveConnection then "Connected" else st.connectionIssue.title
          let themeLabel := if st.theme.isDark then "Theme · Dark" else "Theme · Light"
          WidgetNode.box (BoxStyle.col (pxToSub 4) |>.withPadding (Edges.all (pxToSub 12)))
            ([line "Account" pal.textPrimary, line status pal.textPrimary] ++
             (if st.accountEndpoint.isEmpty then [] else [line st.accountEndpoint pal.textSecondary]) ++
             (if st.accountUsername.isEmpty then [] else [line ("@" ++ st.accountUsername) pal.textPrimary]) ++
             [inventoryTarget theme hoverRow accountFormId width (pxToSub 40)
                (line (if st.hasLiveConnection then "Manage account…" else "Open sign-in form…") pal.textPrimary),
              inventoryTarget theme hoverRow settingsThemeId width (pxToSub 40)
                (line themeLabel pal.textSecondary)] ++
             (if st.writeError.isEmpty then [] else [line st.writeError pal.textSecondary]))
         else buildSettingsGeneralBody st mainW bodyH]
    | _ =>
      let bodyH := availH - headerH
      WidgetNode.box
        (BoxStyle.col 0 |>.withFixedSize mainW availH |>.withBg mainFill)
         [headerNode, if st.hasLiveConnection then
           let width := min (pxToSub 608) (mainW - pxToSub 32)
           let project := ((st.sidebarRows.find? (·.rowId == "project:" ++ st.draftProject)).map (·.title)).getD "Project"
           let v := currentSettings st ""
           let machine := ((st.launchMachines.getD []).lookup v.machine).getD <|
             ((st.fleetMachines.find? (·.machineId == v.machine)).map (·.name)).getD (if v.machine.isEmpty then "Choose machine" else v.machine)
           let pillStyle := BoxStyle.row (pxToSub 5)
             |>.withAlign .center
             |>.withPadding (Edges.xy (pxToSub 7) (pxToSub 2))
             |>.withRadius (pxToSub 6)
           let pillTextStyle : TextStyle := { Theme.mutedText theme with weight := 500 }
           let pillLabel (txt : String) : WidgetNode :=
             WidgetNode.text ({ BoxStyle.row 0 with maxWidth := pxToSub 170, maxHeight := pxToSub 18, clip := true })
               (pxToSub 18) [overlaySynthRun pillTextStyle txt]
           let projectPicker := WidgetNode.focusable draftProjectPickerId <| WidgetNode.box pillStyle
             [pillLabel project,
              chromeIcon "chevron-down" pal.textMuted 10] (some draftProjectPickerId)
           let destination := WidgetNode.focusable 720 <| WidgetNode.box pillStyle
             [chromeIcon "server" pal.textMuted 14, pillLabel machine,
              chromeIcon "chevron-down" pal.textMuted 10] (some 720)
           let folderLabel := ((st.draftDirectory.splitOn "/").filter (!·.isEmpty)).getLast?.getD (if st.draftDirectory.isEmpty then "Folder" else "/")
           let folderPicker := WidgetNode.focusable draftDirectoryPickerId <| WidgetNode.box pillStyle
             [chromeIcon "folder" pal.textMuted 14, pillLabel folderLabel] (some draftDirectoryPickerId)
           let header := WidgetNode.box (BoxStyle.row (pxToSub 10) |>.withAlign .center |>.withFixedSize width (pxToSub 26))
             ([projectPicker, destination] ++ if v.machine.startsWith "auto-managed" then [] else [folderPicker])
           let voiceButton (id : Nat) (icon : String) :=
             WidgetNode.focusable id <| WidgetNode.box
               (BoxStyle.row 0 |>.withFixedSize (pxToSub 24) (pxToSub 24) |>.withJustify .center |>.withAlign .center
                 |>.withRadius (pxToSub 12) |>.withBg (if hoverRow == some id then pal.plusBg else pal.elevatedSurface))
               [chromeIcon icon pal.textPrimary 16] (some id)
           let mic := if st.voiceAvailable && st.voiceDraft then some <|
             match st.voicePhase with
             | .idle | .choosing =>
               let id := if st.voicePicker then some voiceLanguageId else none
               let chip := WidgetNode.box
                 (BoxStyle.row 0 |>.withFixedSize (pxToSub 32) (pxToSub 24) |>.withJustify .center |>.withAlign .center
                   |>.withRadius (pxToSub 6) |>.withBg (if st.voicePicker && hoverRow == id then pal.plusBg else pal.elevatedSurface))
                 [chromeLabel (pxToSub 18) [overlaySynthRun (Theme.mutedText theme) st.voiceLanguage.toUpper]] id
               let chip := if st.voicePicker then WidgetNode.focusable voiceLanguageId chip else chip
               WidgetNode.box (BoxStyle.row (pxToSub 4))
                 [chip, if st.voicePhase == .choosing then voiceButton voiceCancelId "close" else voiceButton voiceButtonId "microphone"]
             | .recording => WidgetNode.box (BoxStyle.row (pxToSub 4))
                 [voiceButton voiceCancelId "close", voiceButton voiceButtonId "check"]
             | .finishing => voiceButton voiceButtonId "close"
             else none
           WidgetNode.box (BoxStyle.col 0 |>.withJustify .center |>.withAlign .center |>.withFixedSize mainW bodyH)
             [buildComposerWidget theme mainW composerH { st.composer with placeholder := "Describe a task, / for commands, @ for context" } [] (some (liveComposerControls st (width - pxToSub (if mic.isNone then 90 else if st.voicePhase == .idle || st.voicePhase == .choosing then 158 else if st.voicePhase == .recording then 150 else 122)) true)) (some header) mic]
           else if st.initialRosterPending then
             WidgetNode.box (BoxStyle.col 0 |>.withJustify .center |>.withAlign .center |>.withFixedSize mainW bodyH)
               [WidgetNode.rrect (BoxStyle.row 0 |>.withFixedSize (min (pxToSub 748) (mainW - pxToSub 68)) (pxToSub 42))
                 pal.elevatedSurface (CornerRadii.uniform (pxToSub 21))]
           else if st.liveData then screenTextLine theme mainW (pxToSub 32) (pxToSub 13)
             (pxToSub 21) pal.textPrimary st.connectionIssue.hint
           else buildNewAgentBody st mainW bodyH]

  let baseShell : WidgetNode :=
    WidgetNode.box
      (BoxStyle.row 0 |>.withFixedSize availW availH |>.withBg (if windowEffects then 0 else pal.canvas))
      (if st.sidebarHidden then [rightColumn] else [sidebarNode, rightColumn])

  if windowEffects then
    WidgetNode.roundedClip
      (BoxStyle.row 0 |>.withFixedSize availW availH)
      (CornerRadii.uniform (pxToSub 12))
      [baseShell]
  else
    baseShell

end OrbDesktop
