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

/-- Elevation shadow helper for Orb Desktop cards. -/
@[inline] def desktopCardShadow (pal : Palette) : ShadowStyle :=
  { offsetX := 0
    offsetY := Int.ofNat (pxToSub 4)
    blur := pxToSub 10
    spread := 0
    color := pal.shadowColor }

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
  let hasText := !st.composer.text.isEmpty
  let bdrCol := pal.borderStrong
  let placeholderCol : Color := if theme.isDark then 0x676767FF else 0xA3A29CFF
  let txtCol := if hasText then pal.textPrimary else placeholderCol
  let dispText := if hasText then st.composer.text else st.composer.placeholder
  let sendBgCol := pal.sendBg

  let dropBar : WidgetNode :=
    WidgetNode.box
      (BoxStyle.row (pxToSub 16)
        |>.withAlign .center
        |>.withPadding (Edges.trbl 0 0 0 (pxToSub 4))
        |>.withFixedSize colW (pxToSub 24))
       [ WidgetNode.box (BoxStyle.row (pxToSub 4) |>.withAlign .center |>.withFixedSize (pxToSub 60) (pxToSub 24))
           [screenTextLine theme (pxToSub 46) (pxToSub 18) (pxToSub 13) (pxToSub 18) pal.textSecondary "Default",
            chromeIcon "chevron-down" pal.textMuted 10]
        , WidgetNode.box (BoxStyle.row (pxToSub 4) |>.withAlign .center |>.withFixedSize (pxToSub 150) (pxToSub 24))
            [chromeIcon "server" pal.textMuted 14,
            screenTextLine theme (pxToSub 112) (pxToSub 18) (pxToSub 13) (pxToSub 18) pal.textSecondary "Core (agent-core)",
            chromeIcon "chevron-down" pal.textMuted 10]
        , WidgetNode.box (BoxStyle.row (pxToSub 4) |>.withAlign .center |>.withFixedSize (pxToSub 60) (pxToSub 24))
            [chromeIcon "folder" pal.textMuted 14,
            screenTextLine theme (pxToSub 42) (pxToSub 18) (pxToSub 13) (pxToSub 18) pal.textSecondary "Folder"]
      ]

  let buttonStyle : BoxStyle :=
    BoxStyle.row 0 |>.withAlign .center |>.withJustify .center
      |>.withFixedSize (pxToSub 24) (pxToSub 24)
  let plusBtn : WidgetNode :=
    WidgetNode.rrect buttonStyle pal.plusBg (CornerRadii.uniform (pxToSub 12)) BorderStyle.none
      [chromeIcon "plus" pal.textMuted 16]
  let sendBtn : WidgetNode :=
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
       , WidgetNode.box (BoxStyle.row (pxToSub 5) |>.withAlign .center
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
      [ WidgetNode.box
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
      , chromeIcon "close" pal.textMuted 14 ]

  let toastRegion : List WidgetNode :=
    match st.toasts with
    | [t1, t2, t3] =>
      [ WidgetNode.box (BoxStyle.col 0 |>.withFixedSize colW (pxToSub 212)) []
      , WidgetNode.box
          (BoxStyle.col (pxToSub 8) |>.withAlign .center |>.withFixedSize colW (pxToSub 181))
          [ toastCard (pxToSub 569) (pxToSub 54) t1
          , toastCard (pxToSub 351) (pxToSub 54) t2
          , toastCard (pxToSub 608) (pxToSub 58) t3
          ]
      ]
    | _ => []

  WidgetNode.box
    (BoxStyle.col 0
      |>.withAlign .center
      |>.withPadding (Edges.trbl (pxToSub 343) 0 0 0)
      |>.withFixedSize mainW bodyH
      |>.withBg pal.canvas)
    ([centerStack] ++ toastRegion)

def buildControlEmptyBody (st : DesktopState) (mainW bodyH : SubPx) : WidgetNode :=
  buildNewAgentBody st mainW bodyH

def buildControlPopulatedBody (st : DesktopState) (mainW bodyH : SubPx) : WidgetNode :=
  buildNewAgentBody st mainW bodyH

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

def transcriptTextWidth (mainW : SubPx) := min (pxToSub 748) (mainW - pxToSub 48) - pxToSub 40

/-- Build the Mission Transcript body (`03_mission_transcript`) matching the SolidJS transcript column. -/
def buildMissionTranscriptBody (st : DesktopState) (mainW bodyH : SubPx)
    (_runs : ShapedScreenRuns) : WidgetNode :=
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
  let liveStreamRow : List WidgetNode :=
    if _runs.streamRuns.isEmpty then []
    else Id.run do
      let width := transcriptTextWidth mainW
      let (_, _, height) := wrapInlineRuns width theme.typo.lineBase _runs.streamRuns
      return [WidgetNode.box
      (BoxStyle.row 0
        |>.withPadding (Edges.xy (pxToSub 20) (pxToSub 6))
        |>.withFixedSize colW (height + pxToSub 12))
      [WidgetNode.text
        (BoxStyle.row 0 |>.withFixedSize width height)
        theme.typo.lineBase _runs.streamRuns (some 900)]]

  let liveRows := liveStreamRow ++ (st.selectedCard.toList.map fun c =>
    screenTextLine theme colW (pxToSub 21) (pxToSub 12) (pxToSub 21) pal.textMuted c.status)
  Id.run do
    let rows := if st.liveData then liveRows else [turn58, turn59] ++ liveStreamRow ++ [workingRow]
    let column := WidgetNode.box { BoxStyle.col (pxToSub 23) with minWidth := colW, maxWidth := colW } rows
    let child := WidgetNode.box (BoxStyle.col 0 |>.withAlign .center
      |>.withPadding (Edges.trbl (pxToSub 3) 0 0 0)) [column]
    let (_, contentH) := measureNode mainW child.toLayoutNode
    let offset := if !st.liveData && liveStreamRow.isEmpty then 0 else (st.scroll.onLayout contentH bodyH).topSub
    return WidgetNode.scrollClip (BoxStyle.col 0 |>.withFixedSize mainW bodyH |>.withBg pal.canvas)
      { offsetY := offset } child (some transcriptViewportId)

/-! ## 4. `04_mission_split_diff` (`/?screen=mission&id=m-diff&mode=split`) -/

/-- Build the right-hand diff viewer pane (`562 x 888`) for `04_mission_split_diff`. -/
def buildSplitDiffRightPane (theme : Theme) (paneW paneH : SubPx)
    (delRuns : List InlineRun := []) (addRuns : List InlineRun := []) : WidgetNode :=
  let pal := theme.palette
  let bdr := theme.borderWidth
  let cardW := paneW - pxToSub 24
  let cardInnerW := cardW - pxToSub 2
  let halfW := (cardInnerW - pxToSub 80) / 2
  let hunkBg : Color := if theme.isDark then 0x252525FF else 0xEAE9E5FF
  let delRowBg : Color := if theme.isDark then 0x3B2C2EFF else 0xEAD6D6FF
  let addRowBg : Color := if theme.isDark then 0x223126FF else 0xD7E6D8FF

  let toolbar : WidgetNode :=
    WidgetNode.rrect
      (BoxStyle.row (pxToSub 8)
        |>.withAlign .center
        |>.withPadding (Edges.xy (pxToSub 12) (pxToSub 9))
        |>.withFixedSize paneW (pxToSub 45))
      0x00000000
      CornerRadii.zero
      { widths := Edges.trbl 0 0 bdr 0, color := pal.borderSubtle }
      [ WidgetNode.rrect
          (BoxStyle.row 0 |>.withAlign .center |>.withPadding (Edges.xy (pxToSub 10) 0) |>.withFixedSize (pxToSub 158) (pxToSub 26))
          pal.elevatedSurface (CornerRadii.uniform (pxToSub 6)) (BorderStyle.uniform bdr pal.border)
          [screenTextLine theme (pxToSub 136) (pxToSub 16) (pxToSub 12) (pxToSub 16) pal.textPrimary "Working tree vs HEAD"]
      , WidgetNode.rrect
          (BoxStyle.row 0 |>.withAlign .center |>.withFixedSize (pxToSub 100) (pxToSub 25))
          0x00000000 (CornerRadii.uniform (pxToSub 6)) (BorderStyle.uniform bdr pal.border)
          [ WidgetNode.box (BoxStyle.row 0 |>.withAlign .center |>.withJustify .center |>.withFixedSize (pxToSub 57) (pxToSub 23))
              [screenTextLine theme (pxToSub 44) (pxToSub 16) (pxToSub 12) (pxToSub 16) pal.textPrimary "Unified"]
          , WidgetNode.rrect (BoxStyle.row 0 |>.withAlign .center |>.withJustify .center |>.withFixedSize (pxToSub 41) (pxToSub 23))
              pal.elevatedSurface CornerRadii.zero BorderStyle.none
              [screenTextLine theme (pxToSub 30) (pxToSub 16) (pxToSub 12) (pxToSub 16) pal.textStrong "Split" 500]
          ]
      , WidgetNode.rrect
          (BoxStyle.row 0 |>.withAlign .center |>.withJustify .center |>.withFixedSize (pxToSub 70) (pxToSub 28))
          0x00000000 (CornerRadii.uniform (pxToSub 6)) (BorderStyle.uniform bdr pal.borderSubtle)
          [screenTextLine theme (pxToSub 50) (pxToSub 16) (pxToSub 13) (pxToSub 16) pal.textSecondary "Refresh" 500]
      , WidgetNode.box (BoxStyle.row 0 |>.withFixedSize (pxToSub 110) (pxToSub 16)) []
      , screenTextLine theme (pxToSub 68) (pxToSub 16) (pxToSub 12) (pxToSub 16) pal.textPrimary "1 file +1 -1"
      ]

  let filesBar : WidgetNode :=
    WidgetNode.rrect
      (BoxStyle.row 0
        |>.withAlign .center
        |>.withPadding (Edges.xy (pxToSub 12) (pxToSub 6))
        |>.withFixedSize paneW (pxToSub 37))
      0x00000000
      CornerRadii.zero
      { widths := Edges.trbl 0 0 bdr 0, color := pal.borderSubtle }
      [ WidgetNode.rrect
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

  let diffCard : WidgetNode :=
    WidgetNode.rrect
      (BoxStyle.col 0
        |>.withPadding (Edges.all bdr)
        |>.withFixedSize cardW (pxToSub 142))
      pal.elevatedSurface
      (CornerRadii.uniform (pxToSub 8))
      (BorderStyle.uniform bdr pal.border)
      [ WidgetNode.rrect
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
      , splitRow (pxToSub 17) 0x00000000 0x00000000 "120" "let availW := viewport.w" "120" "let availW := viewport.w"
      , splitRow (pxToSub 52) delRowBg addRowBg "121" "-  webkit_web_view_load_uri(wv, orb_dev_url);" "121" "+  buildDesktopScreen st availW availH shapedRuns"
          delRuns addRuns
      , splitRow (pxToSub 18) 0x00000000 0x00000000 "122" "let availH := viewport.h" "122" "let availH := viewport.h"
      ]

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

def buildMissionSplitDiffBody (st : DesktopState) (mainW bodyH : SubPx) : WidgetNode :=
  buildMissionTranscriptBody st mainW bodyH {}

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

/-- Only materialize machine rows intersecting the viewport. A long fleet keeps
    its full scroll extent while text shaping stays bounded by window height. -/
private def buildLiveMachines (st : DesktopState) (width height : SubPx) : WidgetNode := Id.run do
  let theme := st.theme
  let pal := theme.palette
  let colW := min (pxToSub 640) (width - pxToSub 24)
  let rowH := pxToSub 60
  let count := st.fleetMachines.length
  if count == 0 then
    return WidgetNode.box (BoxStyle.col 0 |>.withAlign .center |>.withJustify .center |>.withFixedSize width height)
      [screenTextLine theme colW (pxToSub 20) (pxToSub 13) (pxToSub 20) pal.textSecondary "No machines connected"]
  let top := min st.fleetTopSub (count * rowH - height)
  let first := top / rowH
  let visible := (st.fleetMachines.drop first).take (height / rowH + 2)
  let spacer := fun n => WidgetNode.box (BoxStyle.col 0 |>.withFixedSize colW (n * rowH)) []
  let rows := visible.map fun m =>
    let detail := String.intercalate " · " ([m.roleLabel, m.cpuRamSpec].filter (!·.isEmpty))
    buildMachineRow theme colW rowH (if m.name.isEmpty then m.machineId else m.name) detail m.state true false
  let content := WidgetNode.box (BoxStyle.col 0 |>.withAlign .center)
    ([spacer first] ++ rows ++ [spacer (count - first - visible.length)])
  return WidgetNode.scrollClip (BoxStyle.col 0 |>.withFixedSize width height)
    { offsetY := top } content (some fleetViewportId)

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
      (BorderStyle.uniform bdr pal.borderSubtle)
      [buildMachineRow theme rowW (pxToSub 60) "This Mac" "Available in the Orb desktop app" "" false]

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
      [ buildMachineRow theme rowW (pxToSub 61) "Core" "Connecting · Control plane" "" true
      , buildMachineRow theme rowW (pxToSub 61) "orb-core-primary" "online" "3 active" true
      , groupBar
      , buildMachineRow theme rowW (pxToSub 61) "large-a   Managed" "online · 8 vCPU · 16 GB" "2 active" true
      , buildMachineRow theme rowW (pxToSub 60) "default-b   Managed" "online · 4 vCPU · 8 GB" "1 active" false
      ]

  let swCard : WidgetNode :=
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
      , WidgetNode.rrect
          (BoxStyle.row 0 |>.withAlign .center |>.withJustify .center |>.withFixedSize (pxToSub 55) (pxToSub 28))
          0x00000000
          (CornerRadii.uniform (pxToSub 6))
          (BorderStyle.uniform bdr pal.border)
          [screenTextLine theme (pxToSub 36) (pxToSub 16) (pxToSub 13) (pxToSub 16) pal.textSecondary "Copy" 500]
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
    (isInput : Bool := false) (isSelect : Bool := false) : WidgetNode :=
  let pal := theme.palette
  let bdr := theme.borderWidth
  let inputBg : Color := if theme.isDark then 0x202020FF else 0xFFFFFFFF
  let inputBdr : Color := if theme.isDark then 0x333333FF else 0xD8D8D8FF
  let labelW := rowW - pxToSub (if isInput then 276 else if isSelect then 96 else 148)
  let descH := pxToSub (if desc.contains '\n' then 34 else 17)
  let rightNode : WidgetNode :=
    if isInput then
      WidgetNode.rrect
        (BoxStyle.row 0 |>.withAlign .center |>.withPadding (Edges.xy (pxToSub 10) 0) |>.withFixedSize (pxToSub 260) (pxToSub 32))
        inputBg
        (CornerRadii.uniform (pxToSub 6))
        (BorderStyle.uniform bdr inputBdr)
        [screenTextLine theme (pxToSub 240) (pxToSub 16) (pxToSub 12) (pxToSub 16) pal.textPrimary rightLabel]
    else if isSelect then
      WidgetNode.rrect
        (BoxStyle.row 0 |>.withAlign .center |>.withPadding (Edges.xy (pxToSub 10) 0) |>.withFixedSize (pxToSub 80) (pxToSub 32))
        inputBg
        (CornerRadii.uniform (pxToSub 6))
        (BorderStyle.uniform bdr inputBdr)
        [screenTextLine theme (pxToSub 60) (pxToSub 16) (pxToSub 12) (pxToSub 16) pal.textPrimary rightLabel]
    else if rightLabel.isEmpty then
      WidgetNode.box (BoxStyle.row 0 |>.withFixedSize (pxToSub 10) (pxToSub 16)) []
    else if isButton then
      let bw := pxToSub (max 88 (rightLabel.length * 8 + 20))
      WidgetNode.rrect
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
    WidgetNode.rrect
      (BoxStyle.row (pxToSub 16)
        |>.withAlign .center
        |>.withFixedSize (pxToSub 584) (pxToSub 30))
      0x00000000
      CornerRadii.zero
      { widths := Edges.trbl 0 0 bdr 0, color := pal.borderSubtle }
      [ WidgetNode.rrect
          (BoxStyle.row 0 |>.withAlign .center |>.withFixedSize (pxToSub 64) (pxToSub 30))
          0x00000000 CornerRadii.zero { widths := Edges.trbl 0 0 bdr 0, color := pal.textPrimary }
          [screenTextLine theme (pxToSub 64) (pxToSub 18) (pxToSub 13) (pxToSub 18) pal.textPrimary "Account"]
      , screenTextLine theme (pxToSub 48) (pxToSub 18) (pxToSub 13) (pxToSub 18) pal.textMuted "Users"
      , screenTextLine theme (pxToSub 116) (pxToSub 18) (pxToSub 13) (pxToSub 18) pal.textMuted "Usage telemetry"
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

  let backendCard := sCard (pxToSub 125)
    [ buildSettingsRow theme rowW (pxToSub 63) "API URL" "Base URL of the Core backend." "http://127.0.0.1:14470" false false true true false
    , buildSettingsRow theme rowW (pxToSub 62) "Connected" "Signed in to http://127.0.0.1:14470." "Disconnect" true false false
    ]

  let githubCard := sCard (pxToSub 62)
    [ buildSettingsRow theme rowW (pxToSub 62) "Mission git & gh credentials"
        "Configure GITHUB_OAUTH_CLIENT_ID on Core to connect." "Connect GitHub" true false false ]

  let cloudCard := sCard (pxToSub 79)
    [ buildSettingsRow theme rowW (pxToSub 79) "Connected services"
        "Cloud agents use accounts connected to Core. Connecting an account\ndoes not start work." "Refresh accounts" true false false ]

  let appearCard := sCard (pxToSub 125)
    [ buildSettingsRow theme rowW (pxToSub 63) "Theme" "Auto follows your desktop appearance." themeLabel false false true false true
    , buildSettingsRow theme rowW (pxToSub 62) "Background sync" "Active — keeping recent conversations live; pauses automatically on slow links." "Auto" false false false false true
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
def buildSearchModalOverlay (theme : Theme) (availW availH : SubPx) : WidgetNode :=
  let pal := theme.palette
  let bdr := theme.borderWidth
  let scrimCol : Color := if theme.isDark then 0x0000006B else 0x1E1E1C40
  let dlgBg : Color := if theme.isDark then 0x191919FF else 0xFAFAFAFF
  let previewBg : Color := if theme.isDark then 0x161616FF else 0xFDFDFDFF
  let selBg : Color := if theme.isDark then 0x292929FF else 0xE6E6E6FF
  let dlgW : SubPx := pxToSub 880
  let dlgH : SubPx := pxToSub 580
  let innerW : SubPx := pxToSub 878

  let searchBar : WidgetNode :=
    WidgetNode.box
      (BoxStyle.row (pxToSub 10)
        |>.withAlign .center
        |>.withPadding (Edges.trbl 0 (pxToSub 14) 0 (pxToSub 16))
        |>.withFixedSize innerW (pxToSub 46))
      [ chromeIcon "search" pal.textSecondary 16
      , screenTextLine theme (pxToSub 748) (pxToSub 22) (pxToSub 15) (pxToSub 22) pal.textStrong "mission"
      , WidgetNode.box
          (BoxStyle.row 0 |>.withAlign .center |>.withJustify .center |>.withFixedSize (pxToSub 22) (pxToSub 22))
          [chromeIcon "close" pal.textMuted 14]
      , WidgetNode.rrect
          (BoxStyle.row 0 |>.withAlign .center |>.withJustify .center |>.withFixedSize (pxToSub 32) (pxToSub 20))
          0x00000000 (CornerRadii.uniform (pxToSub 4)) (BorderStyle.uniform bdr pal.borderSubtle)
          [screenTextLine theme (pxToSub 22) (pxToSub 15) (pxToSub 11) (pxToSub 15) pal.textMuted "Esc" 500]
      ]

  let toolBar : WidgetNode :=
    WidgetNode.box
      (BoxStyle.row (pxToSub 8)
        |>.withAlign .center
        |>.withJustify .spaceBetween
        |>.withPadding (Edges.trbl 0 (pxToSub 12) (pxToSub 9) (pxToSub 10))
        |>.withFixedSize innerW (pxToSub 34))
      [ WidgetNode.box
          (BoxStyle.row (pxToSub 6) |>.withAlign .center |>.withFixedSize (pxToSub 260) (pxToSub 24))
          [ WidgetNode.rrect
              (BoxStyle.row 0 |>.withAlign .center |>.withJustify .center |>.withFixedSize (pxToSub 31) (pxToSub 24))
              selBg (CornerRadii.uniform (pxToSub 6)) BorderStyle.none
              [screenTextLine theme (pxToSub 20) (pxToSub 17) (pxToSub 12) (pxToSub 17) pal.textStrong "All" 500]
          , screenTextLine theme (pxToSub 38) (pxToSub 17) (pxToSub 12) (pxToSub 17) pal.textMuted "User"
          , screenTextLine theme (pxToSub 64) (pxToSub 17) (pxToSub 12) (pxToSub 17) pal.textMuted "Assistant"
          , screenTextLine theme (pxToSub 42) (pxToSub 17) (pxToSub 12) (pxToSub 17) pal.textMuted "Titles"
          , screenTextLine theme (pxToSub 42) (pxToSub 17) (pxToSub 12) (pxToSub 17) pal.textMuted "Tools"
          ]
      , WidgetNode.box (BoxStyle.row (pxToSub 2) |>.withAlign .center |>.withFixedSize (pxToSub 250) (pxToSub 24))
          ([ ("All projects", 90), ("Any time", 76), ("Relevance", 80) ].map fun (label, width) =>
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

  let resultRow (selected : Bool) (title suffix : String) : WidgetNode :=
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
          , screenTextLine theme (pxToSub 104) (pxToSub 15) (pxToSub 11) (pxToSub 15) pal.textMuted "Project 1 · 15m ago"
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

  let leftPane : WidgetNode :=
    WidgetNode.rrect
      (BoxStyle.col (pxToSub 5)
        |>.withPadding (Edges.all (pxToSub 6))
        |>.withFixedSize (pxToSub 360) (pxToSub 468))
      0x00000000
      CornerRadii.zero
      { widths := Edges.trbl 0 bdr 0 0, color := pal.borderSubtle }
      [ resultRow true "Mission 1 doing some work" " 1 doing some work"
      , resultRow false "Mission 2 doing some work" " 2 doing some work"
      , resultRow false "Mission 21 doing some work" " 21 doing some work"
      ]

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
              [ screenTextLine theme (pxToSub 300) (pxToSub 19) (pxToSub 14) (pxToSub 19) pal.textStrong "Mission 1 doing some work" 600
              , screenTextLine theme (pxToSub 300) (pxToSub 16) (pxToSub 12) (pxToSub 16) pal.textMuted "Project 1 · 15m ago"
              ]
          , WidgetNode.rrect
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
      , screenTextLine theme (pxToSub 64) (pxToSub 16) (pxToSub 11) (pxToSub 16) pal.textMuted "3 matches"
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
    (runs : ShapedScreenRuns := {}) (windowEffects : Bool := false) : WidgetNode :=
  let st := if windowEffects then { st with theme := Theme.withWindowEffects st.theme } else st
  let theme := st.theme
  let pal := theme.palette
  -- Paint each window surface once. Nested canvas fills otherwise obscure the compositor backdrop.
  let mainFill := pal.canvas
  let st := if windowEffects then
      { st with theme := { theme with palette := { pal with canvas := 0, header := 0 } } }
    else st
  let sidebarW := chromeSidebarWidthSub
  let headerH := chromeHeaderHeightSub
  let composerH := chromeComposerHeightSub
  let mainW : SubPx := availW - sidebarW
  let useRefSidebar := !st.liveData && !runs.headerTitleRuns.isEmpty
  let sidebarNode := buildSidebarChrome st availH useRefSidebar
  let headerNode := buildHeaderChrome st mainW runs.headerTitleRuns

  let rightColumn : WidgetNode :=
    match st.screen with
    | .missionTranscript =>
      let bodyH := availH - headerH - composerH
      let bodyNode := buildMissionTranscriptBody st mainW bodyH runs
      let composerNode := buildComposerWidget theme mainW composerH st.composer []
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
      let rightPane := buildSplitDiffRightPane theme rightW splitH runs.diffDelRuns runs.diffAddRuns
      let splitBody : WidgetNode :=
        WidgetNode.box
          (BoxStyle.row 0 |>.withFixedSize mainW splitH |>.withBg st.theme.palette.canvas)
          [leftPane, rightPane]
      WidgetNode.box
        (BoxStyle.col 0 |>.withFixedSize mainW availH |>.withBg mainFill)
        [headerNode, splitBody]
    | .machinesFleet =>
      let bodyH := availH - headerH
      WidgetNode.box
        (BoxStyle.col 0 |>.withFixedSize mainW availH |>.withBg mainFill)
        [headerNode, if st.hasLiveConnection then buildLiveMachines st mainW bodyH else buildMachinesFleetBody st mainW bodyH]
    | .settingsGeneral =>
      let bodyH := availH - headerH
      WidgetNode.box
        (BoxStyle.col 0 |>.withFixedSize mainW availH |>.withBg mainFill)
        [headerNode, buildSettingsGeneralBody st mainW bodyH]
    | _ =>
      let bodyH := availH - headerH
      WidgetNode.box
        (BoxStyle.col 0 |>.withFixedSize mainW availH |>.withBg mainFill)
         [headerNode, if st.hasLiveConnection then
           WidgetNode.box (BoxStyle.col 0 |>.withJustify .center |>.withAlign .center |>.withFixedSize mainW bodyH)
             [buildComposerWidget theme mainW composerH { st.composer with placeholder := "Describe a task, / for commands, @ for context" }
               [] (some (liveComposerControls st (min (pxToSub 748) (mainW - pxToSub 68))))]
           else if st.liveData then screenTextLine theme mainW (pxToSub 32) (pxToSub 13)
           (pxToSub 21) pal.textMuted "Core unavailable"
           else buildNewAgentBody st mainW bodyH]

  let baseShell : WidgetNode :=
    WidgetNode.box
      (BoxStyle.row 0 |>.withFixedSize availW availH |>.withBg (if windowEffects then 0 else pal.canvas))
      [sidebarNode, rightColumn]

  if windowEffects then
    WidgetNode.roundedClip
      (BoxStyle.row 0 |>.withFixedSize availW availH)
      (CornerRadii.uniform (pxToSub 12))
      [baseShell]
  else
    baseShell

end OrbDesktop
