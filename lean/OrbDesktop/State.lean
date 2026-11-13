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
  | .controlEmpty       => "Control Center — Empty Workspace"
  | .controlPopulated   => "Control Center — Active Missions & Approvals"
  | .missionTranscript  => "Mission m-active — Wave 3 OrbDesktop Replacement"
  | .missionSplitDiff   => "Mission m-diff — Split Side-by-Side Diff Review"
  | .machinesFleet      => "Compute Fleet — Managed VMs & Static Nodes"
  | .settingsGeneral    => "Settings — General & Appearance"
  | .searchDialog       => "Control Center — Command Palette (Cmd+K)"
  | .newMissionDialog   => "Control Center — Launch New Mission"
  | .toastNotifications => "Control Center — Live Telemetry & Notifications"

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
  kind : String         -- `"nav"`, `"section"`, `"project"`, `"mission"`
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

/-- Complete single-owner pure state of the Orb Desktop shell. -/
structure DesktopState where
  screen : ScreenId := .missionTranscript
  theme : Theme := orbDarkTheme
  scale120 : Nat := 120
  scroll : ScrollPolicyState := {}
  stream : StreamCoalescer := Orb.Stream.Coalescer.empty
  syncCursor : SyncCursorState := {}
  sidebarRows : List ChromeSidebarRow := []
  missionCards : List MissionSummaryCard := []
  fleetMachines : List FleetMachineCard := []
  toasts : List ToastSpec := []
  modal : ActiveModal := .none
  composer : ComposerBuffer := {}
  deriving Repr, Inhabited

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
  , { widgetId := 103, rowId := "nav:settings", kind := "nav", title := "Settings", shortcut := "⌘,", badge := 0, selected := isSettings }
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
    | .missionTranscript => "turbo-lean build LeanUI LeanUISpec --project-dir lean"
    | .missionSplitDiff  => "Review split side-by-side diff for OrbDesktop/Screens.lean"
    | _                  => ""
  let comp0 : ComposerBuffer := {
    composerWidgetId := 1
    sendButtonId := some 2
    attachButtonId := some 3
    placeholder := "Reply to mission or press Cmd+K to open command palette..."
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
    { owner := some 1, traps := [] }
  | .searchPalette spec =>
    let trap := searchDialogTrapIds spec
    { owner := some spec.inputWidgetId, traps := [trap] }
  | .newMission dlg titleF repoF modelSel =>
    let trap := [titleF.id, repoF.id, modelSel.triggerId] ++ dialogTrapIds dlg
    { owner := some titleF.id, traps := [trap] }

/-- Pure event reducer for `DesktopState` (updates scroll, composer IME/text edits, and focus). -/
def stepDesktopEvent (st : DesktopState) (ev : Event) : DesktopState × Damage :=
  match ev with
  | .text utf8 =>
    ({ st with composer := st.composer.insertText utf8 }, none)
  | .preedit utf8 _ _ =>
    ({ st with composer := st.composer.setPreedit utf8 }, none)
  | .imeBatch db da commit preedit _ _ =>
    ({ st with composer := st.composer.applyImeBatch db da commit preedit }, none)
  | _ => (st, none)

end OrbDesktop
