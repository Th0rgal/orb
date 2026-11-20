import Orb.Kernel
import Orb.Scroll
import Orb.Stream
import Orb.Transcript
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
/-!
# OrbDesktop.State — Pure Orb Desktop Shell State Model & Cross-Client Contracts (`0` FFI)

Implements the pure `OrbDesktop` state model (zero FFI, zero IO, kernel-verified),
composing directly with `Orb.Kernel`, `Orb.Scroll`, `Orb.Stream`, `Orb.Transcript`,
`OrbClient.Reducers`, and `OrbLocald.NativeChrome` and driving all 9 canonical Orb Desktop
screens across Dark/Light themes and `1.0x`/`2.0x` HiDPI scale factors.
-/
namespace OrbDesktop

open LeanUI
open LeanUI.Widgets

/-- The 9 canonical Orb Desktop screens for the `9 × 2 themes × 2 scales = 36` golden suite. -/
inductive ScreenId where
  | controlEmpty        -- `01_control_empty` (`/?screen=control`)
  | controlPopulated    -- `02_control_populated` (`/?screen=control&fixture=populated`)
  | missionTranscript   -- `03_mission_transcript` (`/?screen=mission&id=m-active`)
  | missionSplitDiff    -- `04_mission_split_diff` (`/?screen=mission&id=m-diff&mode=split`)
  | machinesFleet       -- `05_machines_fleet` (`/?screen=machines`)
  | settingsGeneral     -- `06_settings_general` (`/?screen=settings&tab=general`)
  | searchDialog        -- `07_search_dialog` (`/?screen=control&modal=search`)
  | newMissionDialog    -- `08_new_mission_dialog` (`/?screen=control&modal=new-mission`)
  | toastNotifications  -- `09_toast_notifications` (`/?screen=control&fixture=toasts`)
  deriving DecidableEq, Repr, Inhabited

namespace ScreenId

/-- All 9 canonical screens in deterministic golden order. -/
def all : List ScreenId :=
  [ .controlEmpty
  , .controlPopulated
  , .missionTranscript
  , .missionSplitDiff
  , .machinesFleet
  , .settingsGeneral
  , .searchDialog
  , .newMissionDialog
  , .toastNotifications
  ]

/-- Canonical `<screen>` file stem (`01_control_empty` .. `09_toast_notifications`). -/
def fileStem : ScreenId → String
  | .controlEmpty       => "01_control_empty"
  | .controlPopulated   => "02_control_populated"
  | .missionTranscript  => "03_mission_transcript"
  | .missionSplitDiff   => "04_mission_split_diff"
  | .machinesFleet      => "05_machines_fleet"
  | .settingsGeneral    => "06_settings_general"
  | .searchDialog       => "07_search_dialog"
  | .newMissionDialog   => "08_new_mission_dialog"
  | .toastNotifications => "09_toast_notifications"

/-- Short W0 alias name (`inbox`, `transcript`, `streaming`, `diff`, `math-mermaid`, `search`, `settings`, `approvals`, `side-question`). -/
def w0Alias : ScreenId → String
  | .controlEmpty       => "inbox"
  | .controlPopulated   => "approvals"
  | .missionTranscript  => "transcript"
  | .missionSplitDiff   => "diff"
  | .machinesFleet      => "streaming"
  | .settingsGeneral    => "settings"
  | .searchDialog       => "search"
  | .newMissionDialog   => "math-mermaid"
  | .toastNotifications => "side-question"

/-- Canonical URL route corresponding to each screen. -/
def routeQuery : ScreenId → String
  | .controlEmpty       => "/?screen=control"
  | .controlPopulated   => "/?screen=control&fixture=populated"
  | .missionTranscript  => "/?screen=mission&id=m-active"
  | .missionSplitDiff   => "/?screen=mission&id=m-diff&mode=split"
  | .machinesFleet      => "/?screen=machines"
  | .settingsGeneral    => "/?screen=settings&tab=general"
  | .searchDialog       => "/?screen=control&modal=search"
  | .newMissionDialog   => "/?screen=control&modal=new-mission"
  | .toastNotifications => "/?screen=control&fixture=toasts"

/-- Human-readable header breadcrumb title for each screen. -/
def headerTitle : ScreenId → String
  | .controlEmpty       => "New Agent"
  | .controlPopulated   => "New Agent"
  | .missionTranscript  => "Long mission"
  | .missionSplitDiff   => "Long mission"
  | .machinesFleet      => "Machines"
  | .settingsGeneral    => "Settings"
  | .searchDialog       => "New Agent"
  | .newMissionDialog   => "New Agent"
  | .toastNotifications => "New Agent"

/-- Parse a screen identifier or route query into a `ScreenId`. -/
def parse? (s : String) : Option ScreenId :=
  match s with
  | "01_control_empty"       | "control_empty"       | "inbox"         | "/?screen=control" => some .controlEmpty
  | "02_control_populated"   | "control_populated"   | "approvals"     | "/?screen=control&fixture=populated" => some .controlPopulated
  | "03_mission_transcript"  | "mission_transcript"  | "transcript"    | "/?screen=mission&id=m-active" => some .missionTranscript
  | "04_mission_split_diff"  | "mission_split_diff"  | "diff"          | "/?screen=mission&id=m-diff&mode=split" => some .missionSplitDiff
  | "05_machines_fleet"      | "machines_fleet"      | "machines"      | "streaming" | "/?screen=machines" => some .machinesFleet
  | "06_settings_general"    | "settings_general"    | "settings"      | "/?screen=settings&tab=general" => some .settingsGeneral
  | "07_search_dialog"       | "search_dialog"       | "search"        | "/?screen=control&modal=search" => some .searchDialog
  | "08_new_mission_dialog"  | "new_mission_dialog"  | "new-mission"   | "math-mermaid" | "/?screen=control&modal=new-mission" => some .newMissionDialog
  | "09_toast_notifications" | "toast_notifications" | "toasts"        | "side-question" | "/?screen=control&fixture=toasts" => some .toastNotifications
  | _ => none

/-- Golden filename `<screen>_<theme>_<scale>.png`, e.g. `01_control_empty_dark_1x.png`. -/
def goldenFileName (scr : ScreenId) (isDark : Bool) (scale120 : Nat) : String :=
  let th := if isDark then "dark" else "light"
  let sc := if scale120 >= 240 then "2x" else "1x"
  s!"{scr.fileStem}_{th}_{sc}.png"

end ScreenId

/-! ## 1. Pure Orb Contracts (`Orb.Scroll`, `Orb.Stream`, `Orb.Transcript`, `OrbClient.Reducers`) -/

/-- Conversation scroll policy state mirroring `Orb.Scroll.State`. -/
structure ScrollPolicyState where
  pinned : Bool := true
  topSub : SubPx := 0
  deriving DecidableEq, Repr, Inhabited

namespace ScrollPolicyState

/-- Within 24 logical px of the bottom, downward reader scroll re-pins to bottom (`Orb.Scroll.near`). -/
@[inline] def nearBottomSub : SubPx := pxToSub Orb.Scroll.near.toNat

/-- Convert `ScrollPolicyState` to `Orb.Scroll.State` in integer logical pixels. -/
@[inline] def toOrbScrollState (s : ScrollPolicyState) : Orb.Scroll.State :=
  { pinned := s.pinned, top := Int.ofNat (s.topSub / subPerPx) }

/-- Apply a layout height update while preserving pinned follow or anchor offset (`Orb.Scroll.layout`). -/
def onLayout (s : ScrollPolicyState) (contentSub viewportSub : SubPx) : ScrollPolicyState :=
  let lim := scrollLimit contentSub viewportSub
  if s.pinned then
    { pinned := true, topSub := lim }
  else
    { pinned := false, topSub := clampScrollOffset contentSub viewportSub s.topSub }

/-- Apply reader scroll delta in `SubPx` (`Orb.Scroll.userScroll` + `Kernel.scrollStep`). -/
def onUserScroll (s : ScrollPolicyState) (contentSub viewportSub : SubPx) (deltaY : Int) : ScrollPolicyState :=
  let nextTop := scrollStep contentSub viewportSub s.topSub deltaY
  let lim := scrollLimit contentSub viewportSub
  if nextTop < s.topSub then
    { pinned := false, topSub := nextTop }
  else if lim - min lim nextTop <= nearBottomSub then
    { pinned := true, topSub := nextTop }
  else
    { s with topSub := nextTop }

end ScrollPolicyState

/-- Streaming delta coalescer wrapping `Orb.Stream.Coalescer`. -/
abbrev StreamCoalescer := Orb.Stream.Coalescer String

instance : Inhabited StreamCoalescer := ⟨Orb.Stream.Coalescer.empty⟩

namespace StreamCoalescer

@[inline] def pushDelta (c : StreamCoalescer) (delta : String) : StreamCoalescer :=
  if delta.isEmpty then c else Orb.Stream.push c [delta]

@[inline] def flushFrame (c : StreamCoalescer) : StreamCoalescer :=
  Orb.Stream.frame c

end StreamCoalescer

/-- Injective turn-key allocator delegating directly to `Orb.Transcript.TurnKey` and `Orb.Transcript.allocTurnKeys`. -/
abbrev TranscriptTurnKey := Orb.Transcript.TurnKey

instance : Inhabited TranscriptTurnKey := ⟨{ tag := 0, item := 0, gen := 0 }⟩

@[inline] def allocTranscriptTurnKeys (cs : List Orb.Transcript.CandidateKey) : List TranscriptTurnKey :=
  Orb.Transcript.allocTurnKeys cs

/-- Monotonic client sync cursor mirroring `OrbClient.Reducers.SyncCursorState`. -/
structure SyncCursorState where
  epoch : UInt64 := 1
  seq : UInt64 := 42
  deriving DecidableEq, Repr, Inhabited

namespace SyncCursorState

/-- Advance `(epoch, seq)` iff incoming frame is valid, authenticated, and strictly newer in `epoch` or `seq`. -/
@[inline] def step (cur : SyncCursorState) (inEpoch inSeq : UInt64) (valid authOk : Bool) :
    Bool × SyncCursorState :=
  if valid && authOk && (inEpoch > cur.epoch || (inEpoch == cur.epoch && inSeq > cur.seq)) then
    (true, { epoch := inEpoch, seq := inSeq })
  else
    (false, cur)

end SyncCursorState

/-! ## 2. Orb Desktop Domain Models (Sidebar, Missions, Fleet, Settings, Modals, Toasts) -/

/-- Sidebar navigation row mirroring `OrbLocald.NativeChrome.SidebarRow`. -/
structure ChromeSidebarRow where
  widgetId : WidgetId
  rowId : String
  kind : String         -- `"nav"`, `"section"`, `"project"`, `"mission"`, `"footer"`
  depth : Nat := 0
  title : String
  subtitle : String := ""
  status : String := "" -- `"running"`, `"completed"`, `"attention"`, `""`
  shortcut : String := ""
  badge : Nat := 0
  selected : Bool := false
  attention : Bool := false
  deriving DecidableEq, Repr, Inhabited

/-- Summary card for a mission in the Control Center (`02_control_populated`). -/
structure MissionSummaryCard where
  widgetId : WidgetId
  missionId : String
  title : String
  project : String
  track : String
  model : String
  backend : String := ""
  machine : String := ""
  effort : String := ""
  permissionMode : String := ""
  status : String       -- `"running"`, `"awaiting_approval"`, `"completed"`
  updatedLabel : String
  summaryText : String
  deriving DecidableEq, Repr, Inhabited

/-- Managed VM or static compute node entry for `05_machines_fleet`. -/
structure FleetMachineCard where
  widgetId : WidgetId
  machineId : String
  name : String
  roleLabel : String
  cpuRamSpec : String
  state : String        -- `"running"`, `"ready"`, `"provisioning"`
  ttlLabel : String
  costLabel : String
  activeMissions : Nat
  deriving DecidableEq, Repr, Inhabited

/-- Active modal overlay state on the Orb Desktop shell. -/
inductive ActiveModal where
  | none
  | searchPalette (spec : SearchDialogSpec)
  | newMission (dialog : DialogSpec) (titleField : FieldSpec) (repoField : FieldSpec) (modelSelect : SelectSpec)
  deriving DecidableEq, Repr, Inhabited

def rosterViewportId : WidgetId := 970
def transcriptViewportId : WidgetId := 971

structure LaunchSettings where
  machine : String := ""
  backend : String := ""
  model : String := ""
  effort : String := ""
  permission : String := "supervised"
  deriving Repr, Inhabited, BEq

structure CatalogModel where
  backend : String
  harnessName : String
  model : String
  modelName : String
  deriving Repr, Inhabited, BEq

inductive SettingField where
  | machine | backend | model | effort | permission
  deriving Repr, Inhabited, BEq

inductive LiveWrite where
  | create
  | send (mission text : String)
  | stop (mission : String)
  | archive (mission : String)
  | restore (mission : String)
  | rename (mission title : String)
  | move (mission project : String)
  | copyId (mission : String)
  | settings (mission : String) (field : SettingField) (values : LaunchSettings)
  deriving Repr, Inhabited, BEq

inductive MissionMenuPage where
  | actions | destinations | rename | settings | picker (field : SettingField)
  deriving BEq, Repr, Inhabited

structure MissionMenu where
  mission : String
  x : Int
  y : Int
  trigger : Nat := 0
  page : MissionMenuPage := .actions
  first : Nat := 0
  highlighted : Nat := 0
  draft : ComposerBuffer := {}
  deriving Repr, Inhabited

/-- Complete single-owner pure state of the Orb Desktop shell. -/
structure DesktopState where
  screen : ScreenId := .missionTranscript
  theme : Theme := orbDarkTheme
  scale120 : Nat := 120
  scroll : ScrollPolicyState := {}
  rosterTopSub : SubPx := 0
  stream : StreamCoalescer := Orb.Stream.Coalescer.empty
  liveData : Bool := false
  connectionBinding : String := ""
  writeRequest : Option LiveWrite := none
  writeError : String := ""
  missionMenu : Option MissionMenu := none
  draftSettings : LaunchSettings := {}
  catalog : List CatalogModel := []
  openMission : Option String := none
  syncCursor : SyncCursorState := {}
  sidebarRows : List ChromeSidebarRow := []
  missionCards : List MissionSummaryCard := []
  fleetMachines : List FleetMachineCard := []
  toasts : List ToastSpec := []
  modal : ActiveModal := .none
  composer : ComposerBuffer := {}
  /-- Mission actions exposed by the native interaction layer. -/
  missionCreated : Bool := false
  messageSent : Bool := false
  missionStopped : Bool := false
  missionArchived : Bool := false
  sidePanelOpen : Bool := false
  deriving Repr, Inhabited

/-- A failed bootstrap or invalidated identity must not fall back to golden fixtures. -/
def DesktopState.liveUnavailable (isDark := true) (scale120 := 120) : DesktopState :=
  { liveData := true, screen := .controlEmpty, theme := if isDark then orbDarkTheme else orbLightTheme
    scale120, syncCursor := { epoch := 0, seq := 0 } }

def DesktopState.selectedCard (st : DesktopState) : Option MissionSummaryCard :=
  st.openMission.bind fun mid => st.missionCards.find? (·.missionId == mid)

def DesktopState.hasLiveConnection (st : DesktopState) : Bool := st.liveData && !st.connectionBinding.isEmpty

def DesktopState.headerTitle (st : DesktopState) : String :=
  if !st.writeError.isEmpty then st.writeError
  else if st.liveData && !st.hasLiveConnection then "Core unavailable"
  else (st.selectedCard.map (·.title)).getD st.screen.headerTitle

def resetSelection (st : DesktopState) (card : Option MissionSummaryCard) : DesktopState :=
  let mid := card.map (·.missionId)
  { st with
    openMission := mid, missionMenu := none, stream := { shown := [], pending := [], renders := 1 }, scroll := {}
    composer := { isRunning := (card.map (·.status)) == some "active" || (card.map (·.status)) == some "running" }
    messageSent := false, missionStopped := false, missionArchived := false, sidePanelOpen := false
    sidebarRows := st.sidebarRows.map fun row => { row with selected := row.widgetId == (card.map (·.widgetId)).getD 101 } }

/-! ## 3. Canonical Screen Fixtures (`01` .. `09`) -/

/-- Default sidebar rows highlighting the active `ScreenId`. -/
def defaultSidebarRows (scr : ScreenId) : List ChromeSidebarRow :=
  let isControl :=
    match scr with
    | .controlEmpty | .controlPopulated | .searchDialog | .newMissionDialog | .toastNotifications => true
    | _ => false
  let isTranscript := scr == .missionTranscript
  let isDiff := scr == .missionSplitDiff
  let isMachines := scr == .machinesFleet
  let isSettings := scr == .settingsGeneral
  [ { widgetId := 101, rowId := "nav:control", kind := "nav", title := "Control Center", shortcut := "⌘1", badge := if scr == .controlPopulated then 3 else 0, selected := isControl }
  , { widgetId := 102, rowId := "nav:machines", kind := "nav", title := "Compute Fleet", shortcut := "⌘2", badge := 4, selected := isMachines }
  , { widgetId := 103, rowId := "nav:settings", kind := "footer", title := "Settings", selected := isSettings }
  , { widgetId := 108, rowId := "section:projects", kind := "section", title := "Projects" }
  , { widgetId := 104, rowId := "proj:lean-ui", kind := "project", depth := 0, title := "lean-ui (Native Shell)", subtitle := "v4.35.0" }
  , { widgetId := 105, rowId := "m:m-active", kind := "mission", depth := 1, title := "W3: OrbDesktop Shell", status := "running", shortcut := "m-active", selected := isTranscript }
  , { widgetId := 106, rowId := "m:m-diff", kind := "mission", depth := 1, title := "W2B: Split Diff Viewer", status := "completed", shortcut := "m-diff", selected := isDiff }
  , { widgetId := 107, rowId := "m:m-spec", kind := "mission", depth := 1, title := "W1: 124/124 Spec Gate", status := "completed", shortcut := "m-spec" }
  ]

/-- Canonical populated mission cards for `02_control_populated`, `07_search_dialog`, `08_new_mission_dialog`, and `09_toast_notifications`. -/
def defaultMissionCards : List MissionSummaryCard :=
  [ { widgetId := 211
      missionId := "m-active"
      title := "Wave 3 — OrbDesktop Shell Replacement & 36-Golden Parity"
      project := "lean-ui"
      track := "w3-orb-desktop"
      model := "builtin/smart"
      status := "running"
      updatedLabel := "fixed 12:00 UTC"
      summaryText := "Replacing WebKitGTK + SolidJS with pure Lean 4 Layout, Scene, Widgets, and Vulkan 1.3 SDF." }
  , { widgetId := 212
      missionId := "m-approve"
      title := "Approval Required — Production Release Sign-off & Bundle Harvest"
      project := "lean-ui"
      track := "release-gate"
      model := "opus-4-6"
      status := "awaiting_approval"
      updatedLabel := "fixed 11:58 UTC"
      summaryText := "Touch ID / operator approval requested before publishing attested git bundle to main." }
  , { widgetId := 213
      missionId := "m-diff"
      title := "Wave 2B — Reusable Widget Library & Canary Verification"
      project := "lean-ui"
      track := "w2-canary"
      model := "builtin/smart"
      status := "completed"
      updatedLabel := "fixed 11:45 UTC"
      summaryText := "VirtualList, RichText, DiffViewer, MermaidSvg, Overlays, and Composer verified." }
  ]

/-- Canonical compute fleet cards for `05_machines_fleet`. -/
def defaultFleetMachines : List FleetMachineCard :=
  [ { widgetId := 221
      machineId := "mm-large-a"
      name := "large-a (boat.dev EU)"
      roleLabel := "Managed VM · Zen 5 AVX-512"
      cpuRamSpec := "8 vCPU · 16 GB RAM · 125 GB NVMe"
      state := "running"
      ttlLabel := "TTL 55m remaining"
      costLabel := "$0.072 / hr"
      activeMissions := 2 }
  , { widgetId := 222
      machineId := "mm-default-b"
      name := "default-b (boat.dev EU)"
      roleLabel := "Managed VM · Gate Verifier"
      cpuRamSpec := "4 vCPU · 8 GB RAM · 50 GB NVMe"
      state := "ready"
      ttlLabel := "TTL 42m remaining"
      costLabel := "$0.036 / hr"
      activeMissions := 1 }
  , { widgetId := 223
      machineId := "node-core-01"
      name := "orb-core-primary"
      roleLabel := "Static Fleet Host · Primary"
      cpuRamSpec := "16 vCPU · 32 GB RAM · 512 GB NVMe"
      state := "running"
      ttlLabel := "Always-On Static"
      costLabel := "$0.000 / hr"
      activeMissions := 3 }
  ]

/-- Canonical command palette (`07_search_dialog`) specification. -/
def defaultSearchDialogSpec : SearchDialogSpec :=
  { inputWidgetId := 701
    query := "mission"
    placeholder := "Search missions, commands, or files..."
    selectedIdx := 0
    items := [
      { widgetId := 702, title := "Mission: Wave 3 — OrbDesktop Shell Replacement", subtitle := "lean-ui · running", category := "Mission", shortcut := "↵" },
      { widgetId := 703, title := "Mission: Wave 2B — Split Diff & Widget Library", subtitle := "lean-ui · completed", category := "Mission", shortcut := "⌘2" },
      { widgetId := 704, title := "Command: Launch New Mission...", subtitle := "Open modal mission launcher", category := "Command", shortcut := "⌘N" },
      { widgetId := 705, title := "View: Compute Fleet & Managed VMs", subtitle := "3 nodes online", category := "Navigation", shortcut := "⌘M" }
    ] }

/-- Canonical New Mission modal dialog (`08_new_mission_dialog`) components. -/
def defaultNewMissionModal : ActiveModal :=
  let dlg : DialogSpec := {
    dialogId := 800
    title := "Launch New Mission"
    description := "Configure target repository, track identity, and reasoning model."
    confirmLabel := "Launch"
    cancelLabel := "Cancel"
    confirmButtonId := 805
    cancelButtonId := 804
    dangerConfirm := false
  }
  let titleField : FieldSpec := {
    id := 801
    label := "Mission Title"
    value := "Verify Wave 3 OrbDesktop 36-golden suite"
    placeholder := "Enter mission title..."
  }
  let repoField : FieldSpec := {
    id := 802
    label := "Project & Track"
    value := "lean-ui / w3-orb-desktop"
    placeholder := "project / track"
  }
  let modelSelect : SelectSpec := {
    triggerId := 803
    label := "Model Override"
    selectedIdx := 0
    isOpen := false
    options := [
      { value := "builtin/smart", label := "builtin/smart (Opencode Fast)", optionWidgetId := 811 },
      { value := "opus-4-6", label := "claude-opus-4-6 (Deep Review)", optionWidgetId := 812 }
    ]
  }
  .newMission dlg titleField repoField modelSelect

/-- Canonical toast notifications stack for `09_toast_notifications`. -/
def defaultToastStack : List ToastSpec :=
  [ { id := 901
      kind := .success
      title := "Mechanical Gate 1 Passed (124/124 Tight Specs)"
      message := "All 124 kernel-checked specifications verified with zero vacuous theorems in LeanUISpec."
      dismissButtonId := some 911 }
  , { id := 902
      kind := .info
      title := "Managed VM large-a Enrolled"
      message := "8 vCPU / 16 GB RAM ready on Zen 5 AVX-512 node."
      dismissButtonId := some 912 }
  , { id := 903
      kind := .warning
      title := "VM TTL Notice (15m Remaining)"
      message := "Call extend_managed_machine or harvest bundle before expiry."
      dismissButtonId := some 913 }
  ]

/-- Construct the canonical `DesktopState` for any `ScreenId`, theme (`isDark`), and `scale120`. -/
def DesktopState.forScreen (scr : ScreenId) (isDark : Bool := true) (scale120 : Nat := 120) : DesktopState :=
  let th := if isDark then orbDarkTheme else orbLightTheme
  let modalState : ActiveModal :=
    match scr with
    | .searchDialog     => .searchPalette defaultSearchDialogSpec
    | .newMissionDialog => defaultNewMissionModal
    | _                 => .none
  let toastsList : List ToastSpec :=
    match scr with
    | .toastNotifications => defaultToastStack
    | _                   => []
  let cardsList : List MissionSummaryCard :=
    match scr with
    | .controlEmpty => []
    | _             => defaultMissionCards
  let composerText : String :=
    match scr with
    | .newMissionDialog  => "Verify Wave 3 OrbDesktop 36-golden suite"
    | _                  => ""
  let comp0 : ComposerBuffer := {
    composerWidgetId := 1
    sendButtonId := some 2
    attachButtonId := some 3
    isRunning := scr == .missionTranscript || scr == .missionSplitDiff
    placeholder := if scr == .missionTranscript || scr == .missionSplitDiff then "Send follow-up" else "Describe a task, / for commands, @ for context"
  }
  let comp1 := if composerText.isEmpty then comp0 else comp0.insertText composerText
  { screen := scr
    theme := th
    scale120 := scale120
    scroll := { pinned := true, topSub := 0 }
    stream := { shown := ["Wave 3 OrbDesktop native Wayland + Vulkan 1.3 shell ready."], pending := [], renders := 1 }
    syncCursor := { epoch := 1, seq := 42 }
    sidebarRows := defaultSidebarRows scr
    missionCards := cardsList
    fleetMachines := defaultFleetMachines
    toasts := toastsList
    modal := modalState
    composer := comp1 }

/-- Compute the initial `FocusState` (including modal focus traps when a dialog is open) for a `DesktopState`. -/
def DesktopState.initialFocusState (st : DesktopState) : FocusState :=
  match st.modal with
  | .none =>
    { owner := none, traps := [] }
  | .searchPalette spec =>
    let trap := searchDialogTrapIds spec
    { owner := some spec.inputWidgetId, traps := [trap] }
  | .newMission dlg titleF repoF modelSel =>
    let trap := [titleF.id, repoF.id, modelSel.triggerId] ++ dialogTrapIds dlg
    { owner := some titleF.id, traps := [trap] }

/-- Sidebar width in logical `SubPx`: `--sb-w` of the SolidJS desktop (`220 px`). -/
@[inline] def chromeSidebarWidthSub : SubPx := pxToSub 220

/-- Title row height in logical `SubPx`: `--tb-h` (`35 px`). -/
@[inline] def chromeHeaderHeightSub : SubPx := pxToSub 35

/-- Composer dock height in logical `SubPx` (`104 px`): `10 px` above the `42 px` composer, the
`36 px` row under it and `16 px` below. -/
@[inline] def chromeComposerHeightSub : SubPx := pxToSub 104

/-- Device-pixel band the composer paints into: right of the sidebar, the composer dock at the
bottom of `viewport` (device pixels), rounded outward. -/
def composerDamageRect (scale120 : Nat) (viewport : Rect) : Rect :=
  let x0 := floorDev scale120 (Int.ofNat chromeSidebarWidthSub)
  let h := ceilDev scale120 (Int.ofNat chromeComposerHeightSub)
  { x := viewport.x + x0, y := viewport.bottom - h, w := viewport.w - x0, h := h }

/-- Pure event reducer for `DesktopState`. A text, preedit or IME edit damages the composer
band exactly when it changed the composer buffer; `viewport` is the window in device pixels. -/
private def stepDesktopInput (scale120 : Nat) (viewport : Rect) (st : DesktopState) (ev : Event) :
    DesktopState × Damage :=
  let composer :=
    match ev with
    | .text utf8 => st.composer.insertText utf8
    | .preedit utf8 _ _ => st.composer.setPreedit utf8
    | .imeBatch db da commit preedit _ _ => st.composer.applyImeBatch db da commit preedit
    | _ => st.composer
  let actionState :=
    match ev with
    | .activate 2 =>
      if !st.composer.text.isEmpty then { st with messageSent := true, composer := { st.composer with text := "", cursorOffset := 0 } }
      else if st.composer.isRunning then { st with missionStopped := true, composer := { st.composer with isRunning := false } }
      else st
    | .activate 101 => { st with screen := .controlEmpty, modal := .none }
    | .activate 102 => { st with screen := .controlPopulated, modal := .none }
    | .activate 103 => { st with screen := .settingsGeneral, modal := .none }
    | .activate 111 => { st with sidePanelOpen := !st.sidePanelOpen }
    | .activate 106 => { st with missionArchived := true }
    | .activate 805 =>
      match st.modal with
      | .newMission _ _ _ _ => { st with missionCreated := true, modal := .none }
      | _ => st
    | .activate 804 => { st with modal := .none }
    | .activate 911 => { st with toasts := st.toasts.drop 1 }
    | .activate 912 => { st with toasts := st.toasts.drop 1 }
    | .activate 913 => { st with toasts := st.toasts.drop 1 }
    | .key 0x1b _ .pressed => { st with modal := .none }
    | _ => st
  let next :=
    match ev with
    | .activate 2 => actionState
    | _ => { actionState with composer := composer }
  let actionChanged :=
    match ev with
    | .activate 2 => st.composer.isRunning || !st.composer.text.isEmpty
    | .activate 101 | .activate 102 | .activate 103 | .activate 106 | .activate 111
    | .activate 804 | .activate 805 | .activate 911 | .activate 912 | .activate 913
    | .key 0x1b _ .pressed => true
    | _ => false
  if !actionChanged && composer == st.composer then (st, none)
  else
    -- Only the transcript has a fixed bottom composer. Other screens can center
    -- the editor; without its layout bounds use the full viewport.
    let dmg := if composer != st.composer && st.screen == .missionTranscript then composerDamageRect scale120 viewport else viewport
    let next := if next.openMission.isSome && next.screen != .missionTranscript then
      resetSelection next none else next
    (next, Damage.add none dmg)

/-- Menu rows are resolved against the clicked mission, independently of the transcript selection. -/
structure MissionMenuRow where
  id : Nat
  label : String
  icon : String
  action : Option LiveWrite := none
  separatorBefore : Bool := false
  value : String := ""
  deriving Repr, Inhabited

def currentSettings (st : DesktopState) (mid : String) : LaunchSettings :=
  match st.missionCards.find? (·.missionId == mid) with
  | some c => { machine := c.machine, backend := c.backend, model := c.model, effort := c.effort,
                permission := if c.permissionMode.isEmpty then "supervised" else c.permissionMode }
  | none => st.draftSettings

def settingChoices (st : DesktopState) (mid : String) (field : SettingField) : List (String × String) :=
  let values := currentSettings st mid
  match field with
  | .machine => [("", "Default machine")] ++ st.fleetMachines.map fun m => (m.machineId, m.name)
  | .backend => (st.catalog.map fun c => (c.backend, c.harnessName)).eraseDups
  | .model => (st.catalog.filter (·.backend == values.backend)).map fun c => (c.model, c.modelName)
  | .effort =>
    let levels := if values.backend == "antigravity" then ["low", "medium", "high"]
      else if ["claudecode", "codex"].contains values.backend then ["low", "medium", "high", "xhigh", "max"] else []
    [("", "Default effort")] ++ levels.map fun l => (l,l)
  | .permission => [("supervised","Supervised"), ("acceptEdits","Auto-edit"), ("auto","Auto"), ("bypassPermissions","Bypass permissions")]

def settingTrigger (id : Nat) : Option SettingField :=
  match id with
  | 720 => some .machine | 721 => some .backend | 722 => some .model
  | 723 => some .effort | 724 => some .permission | _ => none

private def chooseSetting (st : DesktopState) (mid : String) (field : SettingField) (value : String) : DesktopState :=
  let prev := currentSettings st mid
  let next := match field with
    | .machine => { prev with machine := value }
    | .backend => { prev with backend := value, effort := "", permission := "supervised",
                       model := ((st.catalog.find? (·.backend == value)).map (·.model)).getD "" }
    | .model => { prev with model := value }
    | .effort => { prev with effort := value }
    | .permission => { prev with permission := value }
  if mid.isEmpty then { st with missionMenu := none, draftSettings := next }
  else { st with missionMenu := none, writeRequest := some (.settings mid field next) }

def missionMenuRows (st : DesktopState) (menu : MissionMenu) : List MissionMenuRow := Id.run do
  if let .picker field := menu.page then
    let choices := settingChoices st menu.mission field
    if choices.isEmpty then return [{ id := 719, label := "No available choices", icon := "list" }]
    return choices.mapIdx fun i (value, label) => { id := 2000000 + i, label, icon := "list", value }
  let some card := st.missionCards.find? (·.missionId == menu.mission) | return []
  let projects := st.sidebarRows.filter fun r => r.kind == "project" && r.rowId != "project:" ++ card.project
  match menu.page with
  | .picker _ => return []
  | .actions =>
    return [{ id := 710, label := "Rename…", icon := "rename" }] ++
      (if projects.isEmpty then [] else [{ id := 711, label := "Move to", icon := "folder" }]) ++
      [{ id := 712, label := if card.status == "acknowledged" then "Restore" else "Archive", icon := "archive",
         action := some (if card.status == "acknowledged" then .restore card.missionId else .archive card.missionId) },
       { id := 713, label := "Copy mission ID", icon := "copy", action := some (.copyId card.missionId), separatorBefore := true },
       { id := 714, label := "Mission settings", icon := "nav:settings" }]
  | .destinations =>
    return [{ id := 715, label := "Move to", icon := "back" }] ++ projects.mapIdx fun i p =>
      { id := 2000000 + i, label := p.title, icon := "folder",
        action := some (.move card.missionId (p.rowId.drop 8).toString) }
  | .rename =>
    return [{ id := 1, label := menu.draft.text ++ menu.draft.imePreeditText, icon := "rename" },
      { id := 716, label := "Save", icon := "check", action := some (.rename card.missionId menu.draft.text) }]
  | .settings =>
    return [{ id := 715, label := "Mission settings", icon := "back" },
      { id := 717, label := "Project: " ++ card.project, icon := "folder" },
      { id := 718, label := "Model: " ++ card.model, icon := "s:models" }]

def menuFocusChange (before after : DesktopState) : Option Nat :=
  match before.missionMenu, after.missionMenu with
  | some old, none => some old.trigger
  | old, some menu =>
    if old.any (fun m => m.page == menu.page && m.highlighted == menu.highlighted && m.trigger == menu.trigger) then none
    else ((missionMenuRows after menu)[menu.highlighted]?).map (·.id)
  | _, _ => none

private def stepMissionMenu (st : DesktopState) (menu : MissionMenu) (ev : Event) (viewport : Rect) :
    DesktopState × Damage := Id.run do
  let update := fun m => ({ st with missionMenu := some m }, some viewport)
  let close := ({ st with missionMenu := none }, some viewport)
  let items := missionMenuRows st menu
  match ev with
  | .scroll _ _ _ dy =>
    let index := if dy > 0 then min (items.length - 1) (menu.first + 1) else menu.first - 1
    return update { menu with first := index, highlighted := index }
  | .key key _ state =>
    if state == .released then return (st, none)
    if key == 0xff1b then return close
    if key == 0xff52 || key == 0xff54 then
      let i := if key == 0xff52 then menu.highlighted - 1 else min (items.length - 1) (menu.highlighted + 1)
      return update { menu with highlighted := i, first := min i (max menu.first (i - 5)) }
    if key == 0xff51 && menu.page == .destinations then return update { menu with page := .actions, first := 0, highlighted := 1 }
    if key == 0xff53 && menu.page == .actions && (items[menu.highlighted]?.map (·.id)) == some 711 then
      return update { menu with page := .destinations, first := 0, highlighted := 0 }
    if key == 0xff08 && menu.page == .rename then return update { menu with draft := menu.draft.applyImeBatch 1 0 "" "" }
    return (st, none)
  | .windowFocus false => return close
  | .activate 719 => return close
  | .activate 710 =>
    let title := (st.missionCards.find? (·.missionId == menu.mission)).map (·.title) |>.getD ""
    return update { menu with page := .rename, first := 0, highlighted := 0, draft := { text := title, cursorOffset := title.length } }
  | .activate 711 => return update { menu with page := .destinations, first := 0, highlighted := 0 }
  | .activate 714 => return update { menu with page := .settings, first := 0, highlighted := 0 }
  | .activate 715 => return update { menu with page := .actions, first := 0, highlighted := 0 }
  | .activate id =>
    let some row := (missionMenuRows st menu).find? (·.id == id) | return (st, none)
    if let .picker field := menu.page then return (chooseSetting st menu.mission field row.value, some viewport)
    let some action := row.action | return (st, none)
    if menu.page == .rename && (menu.draft.text.trimAscii.isEmpty || !menu.draft.imePreeditText.isEmpty) then return (st, none)
    return ({ st with missionMenu := none, writeRequest := some action }, some viewport)
  | _ =>
    if menu.page != .rename then return (st, none)
    let draft := match ev with
      | .text text => menu.draft.insertText text
      | .imeBatch db da text preedit _ _ => menu.draft.applyImeBatch db da text preedit
      | .preedit text _ _ => menu.draft.setPreedit text
      | _ => menu.draft
    if draft == menu.draft then return (st, none)
    return update { menu with draft }

def stepDesktopEvent (scale120 : Nat) (viewport : Rect) (st : DesktopState) (ev : Event) :
    DesktopState × Damage := Id.run do
  if st.liveData then
    if !st.hasLiveConnection || st.writeRequest.isSome then return (st, none)
    if let some menu := st.missionMenu then return stepMissionMenu st menu ev viewport
    match ev with
    | .text _ | .preedit .. | .imeBatch .. =>
      if st.selectedCard.isNone then return (st, none)
    | _ => pure ()
    if let .activate id := ev then
      if id == 805 then return ({ st with writeRequest := some .create }, some viewport)
      if id == 2 || id == 106 then
        let some card := st.selectedCard | return (st, none)
        let request := if id == 106 then
            if st.composer.isRunning then none else some (.archive card.missionId)
          else if st.composer.isRunning then some (.stop card.missionId)
          else if st.composer.imePreeditText.isEmpty && !st.composer.text.isEmpty then
            some (.send card.missionId st.composer.text)
          else none
        return ({ st with writeRequest := request }, none)
      if let some card := st.missionCards.find? (·.widgetId == id) then
        if st.openMission == some card.missionId then return (st, none)
        return (resetSelection { st with screen := .missionTranscript } (some card), some viewport)
  return stepDesktopInput scale120 viewport st ev

/-- Device-pixel band occupied by the live transcript. Stream deltas repaint this band only; the
sidebar, header and composer retain their framebuffer pixels. -/
def transcriptDamageRect (scale120 : Nat) (viewport : Rect) : Rect :=
  let x0 := floorDev scale120 (Int.ofNat chromeSidebarWidthSub)
  let y0 := ceilDev scale120 (Int.ofNat chromeHeaderHeightSub)
  let bottom := viewport.bottom - ceilDev scale120 (Int.ofNat chromeComposerHeightSub)
  { x := viewport.x + x0, y := viewport.y + y0, w := viewport.w - x0, h := max 0 (bottom - (viewport.y + y0)) }

/-- Queue a streamed text delta without requesting a redraw. The next display tick flushes all
queued deltas together, using the coalescer proved in `Orb.Stream`. -/
def enqueueStreamDelta (st : DesktopState) (delta : String) : DesktopState :=
  { st with stream := st.stream.pushDelta delta }

/-- Compatibility name for callers that already use the reducer vocabulary. -/
abbrev pushStreamDelta := enqueueStreamDelta

/-- The committed streamed text in display order. -/
def streamedText (st : DesktopState) : String :=
  String.intercalate "" st.stream.shown

/-- Flush one display frame of streamed text. Empty frames are true no-ops; a burst of deltas
produces one transcript damage rectangle and one coalescer render. -/
def flushStreamFrame (scale120 : Nat) (viewport : Rect) (st : DesktopState) : DesktopState × Damage :=
  let stream' := st.stream.flushFrame
  if stream'.renders == st.stream.renders then
    (st, none)
  else
    ({ st with stream := stream' }, Damage.add none (transcriptDamageRect scale120 viewport))

/-- Queue and flush a batch at the display boundary. This is the native adapter for the
`Orb.Stream.Coalescer` contract: N deltas become one visible frame. -/
def applyStreamFrame (scale120 : Nat) (viewport : Rect) (st : DesktopState)
    (deltas : List String) : DesktopState × Damage :=
  let queued := deltas.foldl pushStreamDelta st
  flushStreamFrame scale120 viewport queued

/-- RemoteDispatch emits cumulative content, including authoritative corrections. -/
def applyLiveText (scale : Nat) (viewport : Rect) (st : DesktopState) (mission text : String) :
    DesktopState × Damage :=
  if !st.liveData || st.screen != .missionTranscript || st.openMission != some mission || streamedText st == text then
    (st, none)
  else
    -- Even an empty replacement is a real frame (turn boundary / access loss).
    flushStreamFrame scale viewport { st with stream := { st.stream with shown := [], pending := [text] } }

end OrbDesktop
