import Std.Data.HashMap
import Std.Data.HashSet
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
  | cloud
  | resources
  | inbox               -- authenticated unread responses
  | inference           -- authenticated provider accounts
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
  | .inbox              => "live-inbox"
  | .cloud              => "cloud-agent"
  | .resources          => "resources"
  | .inference          => "inference"
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
  | .inbox              => "live-inbox"
  | .cloud              => "cloud-agent"
  | .resources          => "resources"
  | .inference          => "providers"
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
  | .inbox              => "/?screen=inbox"
  | .cloud              => "/?screen=cloud-agent"
  | .resources          => "/?screen=resources"
  | .inference          => "/?screen=inference"
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
  | .inbox              => "Inbox"
  | .cloud              => "Cloud agent"
  | .resources          => "Resources"
  | .inference          => "Inference"
  | .settingsGeneral    => "Settings"
  | .searchDialog       => "New Agent"
  | .newMissionDialog   => "New Agent"
  | .toastNotifications => "New Agent"

/-- Parse a screen identifier or route query into a `ScreenId`. -/
def parse? (s : String) : Option ScreenId :=
  match s with
  | "cloud-agent" | "/?screen=cloud-agent" => some .cloud
  | "resources" | "/?screen=resources" => some .resources
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
  iconColor : Option Color := none
  status : String := "" -- `"running"`, `"completed"`, `"attention"`, `""`
  archiveOnly : Bool := false
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
  folder : String := ""
  parentMissionId : String := ""
  callbackParentMissionId : String := ""
  forkSource : String := ""
  supersededBy : String := ""
  archiveTag : Bool := false
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
def fleetViewportId : WidgetId := 972

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

structure ProviderAccount where
  id : String
  name : String
  category : String
  userEnabled : Bool
  globallyEnabled : Bool
  providerType : String := ""
  deriving BEq, Repr, Inhabited

def providerWidgetId (index : Nat) : WidgetId := 6000000 + index

def providerSettingsId (index : Nat) : WidgetId := 7000000 + index
def providerRouteId (index : Nat) : WidgetId := 8000000 + index
def providersBackId : WidgetId := 5999998
def providersRetryId : WidgetId := 5999999

structure AccountRouteOption where
  action : String
  value : String
  title : String
  detail : String
  deriving BEq, Repr, Inhabited

structure AccountRoutePage where
  account : ProviderAccount
  previousTop : SubPx := 0
  options : Option (List AccountRouteOption) := none
  pending : Option AccountRouteOption := none
  failed : Bool := false
  deriving BEq, Repr, Inhabited

def resourceRanges := ["30m", "1h", "6h", "24h", "7d"]

structure ResourceRow where
  mission : String
  title : String
  usage : String
  deriving BEq, Repr, Inhabited

structure InboxItem where
  mission : String
  stamp : Nat
  version : Nat
  deriving BEq, Repr, Inhabited

inductive LiveWrite where
  | cloudCreate (provider account project prompt attempt : String)
  | cloudSend (mission text attempt : String)
  | cloudCancel (mission : String)
  | inboxRead (item : InboxItem) (openItem : Bool)
  | providerPreference (account : String) (enabled : Bool)
  | create
  | send (mission text : String)
  | stop (mission : String)
  | archive (mission : String)
  | restore (mission : String)
  | rename (mission title : String)
  | move (mission project : String)
  | copyId (mission : String)
  | bulk (action : String) (missions : List String) (project : String)
  | settings (mission : String) (field : SettingField) (values : LaunchSettings)
  deriving Repr, Inhabited, BEq

inductive MissionMenuPage where
  | actions | destinations | draftProject | draftDirectory | rename | settings | confirmDelete | picker (field : SettingField)
  deriving BEq, Repr, Inhabited

structure MissionMenu where
  mission : String
  x : Int
  y : Int
  trigger : Nat := 0
  targets : List String := []
  mixed : Bool := false
  nativeCatalogResult : Option Bool := none
  page : MissionMenuPage := .actions
  first : Nat := 0
  highlighted : Nat := 0
  draft : ComposerBuffer := {}
  browsePath : String := ""
  directoryRows : Option (List (String × String)) := none
  listingFailed : Bool := false
  deriving Repr, Inhabited

inductive VoicePhase where
  | idle | recording | finishing | choosing
  deriving BEq, Repr, Inhabited

def voiceLanguageId : Nat := 747
def voiceButtonId : Nat := 745
def voiceCancelId : Nat := 746

inductive ConnectionIssue where
  | unavailable | missing | signin | denied | invalid
  deriving BEq, Repr, Inhabited

def ConnectionIssue.code : ConnectionIssue → String
  | .unavailable => "unavailable"
  | .missing => "missing"
  | .signin => "signin"
  | .denied => "denied"
  | .invalid => "invalid"

def ConnectionIssue.title : ConnectionIssue → String
  | .unavailable => "Core unavailable"
  | .missing => "Connect to Core"
  | .signin => "Sign in to Core"
  | .denied => "Access denied"
  | .invalid => "Invalid saved connection"

def ConnectionIssue.hint : ConnectionIssue → String
  | .unavailable => "Retrying the connection to Core…"
  | .missing => "Open Orb Settings → Account to connect."
  | .signin | .invalid => "Reconnect in Orb Settings → Account."
  | .denied => "Check your account’s access to this Core."

/-- Complete single-owner pure state of the Orb Desktop shell. -/
structure DesktopState where
  voiceLanguage : String := ""
  voicePicker : Bool := false
  voiceAvailable : Bool := false
  voiceBinding : String := ""
  voiceGeneration : Nat := 0
  voicePhase : VoicePhase := .idle
  screen : ScreenId := .missionTranscript
  theme : Theme := orbDarkTheme
  scale120 : Nat := 120
  scroll : ScrollPolicyState := {}
  sidebarHidden : Bool := false
  rosterTopSub : SubPx := 0
  fleetTopSub : SubPx := 0
  stream : StreamCoalescer := Orb.Stream.Coalescer.empty
  liveData : Bool := false
  initialRosterPending : Bool := false
  connectionIssue : ConnectionIssue := .unavailable
  accountEndpoint : String := ""
  accountUsername : String := ""
  openAccountForm : Bool := false
  connectionBinding : String := ""
  writeRequest : Option LiveWrite := none
  writeError : String := ""
  missionMenu : Option MissionMenu := none
  draftSettings : LaunchSettings := {}
  draftProject : String := ""
  nativeHarnessAvailable : Bool := false
  nativeCatalog : Option (String × List CatalogModel) := none
  draftDirectory : String := ""
  catalog : List CatalogModel := []
  catalogLoading : Bool := false
  catalogRevision : Nat := 0
  providers : Option (List ProviderAccount) := none
  providerReadFailed : Bool := false
  accountRoutePage : Option AccountRoutePage := none
  projectMemberships : List (String × List String) := []
  expandedProjects : List String := []
  expandedMissions : List String := []
  archivesOpen : Bool := false
  multiRows : List String := []
  selectionAnchor : Option String := none
  heldSelectionKeys : List UInt32 := []
  openMission : Option String := none
  syncCursor : SyncCursorState := {}
  badgePhase : Nat := 0
  sidebarRows : List ChromeSidebarRow := []
  cloudMission : String := ""
  cloudLines : Option (List String) := none
  cloudAccounts : List (String × String × String) := []
  cloudAccountIndex : Nat := 0
  cloudProject : String := ""
  cloudActions : List String := []
  cloudDraft : ComposerBuffer := {}
  cloudAttempt : String := ""
  cloudFailed : Bool := false
  cloudPage : Nat := 0
  resourceRows : Option (List ResourceRow) := none
  resourceFailed : Bool := false
  resourcePage : Nat := 0
  resourceRange : String := "6h"
  inboxItems : List InboxItem := []
  inboxAvailable : Bool := false
  inboxEnabled : Bool := true
  inboxIndex : Nat := 0
  missionCards : List MissionSummaryCard := []
  fleetMachines : List FleetMachineCard := []
  launchMachines : Option (List (String × String)) := none
  launchMachinesFailed : Bool := false
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

def settingsFooter : ChromeSidebarRow :=
  { widgetId := 103, rowId := "nav:settings", kind := "footer", title := "Settings" }

def accountFormId : Nat := 972

/-- A failed bootstrap or invalidated identity must not fall back to golden fixtures. -/
def DesktopState.liveUnavailable (isDark := true) (scale120 := 120) : DesktopState :=
  { liveData := true, sidebarRows := [settingsFooter], screen := .controlEmpty, theme := if isDark then orbDarkTheme else orbLightTheme
    scale120, syncCursor := { epoch := 0, seq := 0 } }

def DesktopState.selectedCard (st : DesktopState) : Option MissionSummaryCard :=
  st.openMission.bind fun mid => st.missionCards.find? (·.missionId == mid)

def DesktopState.hasLiveConnection (st : DesktopState) : Bool := st.liveData && !st.connectionBinding.isEmpty

def DesktopState.currentInboxItem (st : DesktopState) : Option InboxItem :=
  st.inboxItems[min st.inboxIndex (st.inboxItems.length - 1)]?

def DesktopState.headerTitle (st : DesktopState) : String :=
  if st.initialRosterPending then "Connecting to Core…"
  else if st.liveData && !st.hasLiveConnection then st.connectionIssue.title
  else if (st.screen == .controlEmpty || st.screen == .controlPopulated) && st.openMission.isNone && !st.draftProject.isEmpty then
    ((st.sidebarRows.find? (·.rowId == "project:" ++ st.draftProject)).map (·.title)).getD st.draftProject
  else (st.selectedCard.map (·.title)).getD st.screen.headerTitle

def MissionSummaryCard.isArchived (card : MissionSummaryCard) : Bool :=
  card.archiveTag || card.status == "acknowledged"

def restoredExecutionStatus (status : String) : String :=
  if status == "acknowledged" then "paused" else status

def MissionSummaryCard.isRunning (card : MissionSummaryCard) : Bool :=
  card.status == "active" || card.status == "running"

def DesktopState.openCloud (st : DesktopState) (mission : String) : DesktopState :=
  { st with screen := .cloud, cloudMission := mission, cloudLines := none, cloudFailed := false,
            cloudPage := 0, cloudActions := [], cloudDraft := {}, cloudAttempt := "", cloudProject := "", writeError := "" }

def DesktopState.voiceDraft (st : DesktopState) : Bool :=
  st.hasLiveConnection && st.openMission.isNone && st.writeRequest.isNone &&
    (st.screen == .controlEmpty || st.screen == .controlPopulated)

def resetSelection (st : DesktopState) (card : Option MissionSummaryCard) : DesktopState :=
  let cloud := card.filter fun c => st.screen == .missionTranscript && c.backend.startsWith "cloud_"
  let st := cloud.elim st fun c => st.openCloud c.missionId
  let mid := if cloud.isSome then none else card.map (·.missionId)
  { st with
    voicePhase := .idle, voiceGeneration := st.voiceGeneration + 1, openMission := mid, missionMenu := none, stream := { shown := [], pending := [], renders := 1 }, scroll := {}
    composer := { isRunning := card.any (·.isRunning) }
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

def DesktopState.sidebarWidth (st : DesktopState) : SubPx :=
  if st.sidebarHidden then 0 else chromeSidebarWidthSub

def sidebarToggleId : WidgetId := 117

/-- Title row height in logical `SubPx`: `--tb-h` (`35 px`). -/
@[inline] def chromeHeaderHeightSub : SubPx := pxToSub 35

/-- Composer dock height in logical `SubPx` (`104 px`): `10 px` above the `42 px` composer, the
`36 px` row under it and `16 px` below. -/
@[inline] def chromeComposerHeightSub : SubPx := pxToSub 104

/-- Device-pixel band the composer paints into: right of the sidebar, the composer dock at the
bottom of `viewport` (device pixels), rounded outward. -/
def composerDamageRect (scale120 : Nat) (viewport : Rect) (sidebarWidth := chromeSidebarWidthSub) : Rect :=
  let x0 := floorDev scale120 (Int.ofNat sidebarWidth)
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
    let dmg := if composer != st.composer && st.screen == .missionTranscript then composerDamageRect scale120 viewport st.sidebarWidth else viewport
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

def catalogDestination (st : DesktopState) (mid : String) : String :=
  let machine := (currentSettings st mid).machine
  if machine.isEmpty && st.fleetMachines.any (·.machineId == "core") then "core" else machine

def destinationCatalog (st : DesktopState) (mid : String) : List CatalogModel :=
  let native := match st.nativeCatalog with
    | some (machine, rows) => if machine == catalogDestination st mid then rows else []
    | none => []
  st.catalog ++ native

/-- A successful destination refresh can invalidate a new draft's explicit choice.
    Existing mission settings remain Core-owned. -/
def applyNativeCatalog (st : DesktopState) (machine : String) (rows : List CatalogModel) : DesktopState :=
  let draft := st.draftSettings
  let missing := st.missionMenu.any (·.mission.isEmpty) && catalogDestination st "" == machine &&
    draft.backend == "antigravity" && !draft.model.isEmpty && !rows.any (·.model == draft.model)
  { st with nativeCatalog := some (machine, rows), draftSettings := if missing then { draft with model := "" } else draft }

def nativeCatalogRequest (st : DesktopState) : Option String := do
  let menu ← st.missionMenu
  guard (st.nativeHarnessAvailable && menu.nativeCatalogResult.isNone && (menu.page == .picker .backend ||
    (menu.page == .picker .model && (currentSettings st menu.mission).backend == "antigravity")))
  let machine := catalogDestination st menu.mission
  guard (!machine.isEmpty)
  return machine

def settingChoices (st : DesktopState) (mid : String) (field : SettingField) : List (String × String) :=
  let values := currentSettings st mid
  match field with
  | .machine =>
    let localMachines := st.fleetMachines.filter (·.machineId == "core")
    (if localMachines.isEmpty then [] else [("", "Default machine")]) ++ (localMachines.map fun m => (m.machineId, m.name)) ++ st.launchMachines.getD []
  | .backend => ((destinationCatalog st mid).map fun c => (c.backend, c.harnessName)).eraseDups
  | .model => ((destinationCatalog st mid).filter (·.backend == values.backend)).map fun c => (c.model, c.modelName)
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
    | .machine => { prev with machine := value, model := if prev.backend == "antigravity" && prev.machine != value then "" else prev.model }
    | .backend =>
      let model := (((destinationCatalog st mid).find? (·.backend == value)).map (·.model)).getD ""
      { prev with backend := value, effort := "", permission := "supervised", model }
    | .model => { prev with model := value }
    | .effort => { prev with effort := value }
    | .permission => { prev with permission := value }
  if mid.isEmpty then
    { st with missionMenu := none, draftSettings := next,
              draftDirectory := if prev.machine == next.machine then st.draftDirectory else "" }
  else { st with missionMenu := none, writeRequest := some (.settings mid field next) }

private def selectableRow (r : ChromeSidebarRow) := r.kind == "mission" || r.kind == "project"

def missionDisclosureId (widgetId : Nat) : Nat := 4000000 + widgetId

def draftProjectPickerId : Nat := 738
def draftDirectoryPickerId : Nat := 739

def projectNewAgentId (widgetId : Nat) : Nat := 5000000 + widgetId

/-- A disclosure shares its row's hover background. Section headings and
the scroll container have no hover background. -/
def DesktopState.sidebarHoverRow (st : DesktopState) (hit : Option WidgetId) : Option WidgetId := do
  let id ← hit
  let rowId := if id >= projectNewAgentId 0 then id - projectNewAgentId 0
    else if id >= missionDisclosureId 0 then id - missionDisclosureId 0 else id
  let row ← st.sidebarRows.find? (·.widgetId == rowId)
  if ["nav", "project", "mission", "footer"].contains row.kind then some rowId else none

def DesktopState.cloudProjects (st : DesktopState) : List ChromeSidebarRow :=
  st.sidebarRows.filter (·.kind == "project")

def DesktopState.cloudSelectedProject (st : DesktopState) : Option ChromeSidebarRow :=
  if st.cloudProject.isEmpty then st.cloudProjects.head?
  else st.cloudProjects.find? (·.rowId == st.cloudProject)

def DesktopState.cloudCanCreate (st : DesktopState) : Bool :=
  st.screen == .cloud && st.cloudMission.isEmpty && st.cloudLines.isSome &&
    !st.cloudAccounts.isEmpty && st.cloudSelectedProject.isSome

def DesktopState.cloudAllows (st : DesktopState) (action : String) : Bool :=
  st.screen == .cloud && !st.cloudMission.isEmpty && st.cloudLines.isSome && st.cloudActions.contains action

/-- Empty mission ID denotes a passive account, status or conversation line. -/
def DesktopState.cloudItems (st : DesktopState) : List (String × String) := Id.run do
  let inventory := (st.cloudLines.getD []).map fun t => ("", t)
  if !st.cloudMission.isEmpty then return inventory
  let conversations := st.missionCards.filter (·.backend.startsWith "cloud_")
  return inventory ++ conversations.map fun c => (c.missionId, "Open · " ++ c.title)

def DesktopState.hoverTarget (st : DesktopState) (hit : Option WidgetId) : Option WidgetId := do
  if hit == some voiceLanguageId || hit == some voiceButtonId || hit == some voiceCancelId then return ← hit
  let id ← hit
  if st.screen == .cloud && id >= 960 && id < 972 then some id
  else if st.screen == .resources && id >= 945 && id < 960 then some id
  else if st.screen == .inference && id >= providersBackId then some id else st.sidebarHoverRow hit

def DesktopState.sidebarHoverDamage (st : DesktopState) (regions : List (WidgetId × Rect)) (scale : Nat)
    (previous next : Option WidgetId) : Damage := Id.run do
  if previous == next then return none
  let a := st.hoverTarget previous
  let b := st.hoverTarget next
  if a == b then return none
  let mut damage : Damage := none
  for id in [a, b] do
    if let some widget := id then
      if let some (_, rect) := regions.find? (·.1 == widget) then
        damage := Damage.add damage (roundRectOut scale rect)
  return damage

private def missionBranchRows (rows : Array ChromeSidebarRow)
    (cards : Std.HashMap Nat MissionSummaryCard) (expanded : List String) : Array ChromeSidebarRow := Id.run do
  let mut parents : Std.HashMap String String := {}
  let ids := rows.foldl (fun (acc : Std.HashSet String) row => acc.insert row.rowId) {}
  for row in rows do
    if let some card := cards.get? row.widgetId then
      let launch := if card.parentMissionId == card.forkSource then "" else card.parentMissionId
      let parent := "mission:" ++ (if launch.isEmpty then card.callbackParentMissionId else launch)
      if ids.contains parent && parent != row.rowId then
        parents := parents.insert row.rowId parent
  -- Detach every member of a legacy cycle. Once a path has been checked,
  -- another branch can stop there even when a long chain shares that path.
  let mut checked : Std.HashSet String := {}
  for row in rows do
    if !checked.contains row.rowId then
      let mut path : Array String := #[]
      let mut positions : Std.HashMap String Nat := {}
      let mut id := row.rowId
      for _ in [:rows.size + 1] do
        if id.isEmpty || checked.contains id then break
        if let some start := positions.get? id then
          for member in path.extract start path.size do
            parents := parents.erase member
          break
        positions := positions.insert id path.size
        path := path.push id
        id := parents.getD id ""
      for member in path do checked := checked.insert member
  let mut children : Std.HashMap String (Array ChromeSidebarRow) := {}
  for row in rows do
    let parent := parents.getD row.rowId ""
    children := children.insert parent ((children.getD parent #[]).push row)
  -- Walk the forest once. Hidden descendants still contribute to a closed
  -- controller's launched-work count, as they do in the WebKit tree.
  let mut bottomUp := []
  let mut pending := (children.getD "" #[]).toList.map (fun row => (row, "", 0, true))
  for _ in [:rows.size] do
    let (row, parent, depth, shown) :: rest := pending | break
    bottomUp := (row, parent, depth, shown) :: bottomUp
    let showChildren := shown && expanded.contains row.rowId
    let nested := children.getD row.rowId #[]
    pending := nested.toList.map (fun child => (child, row.rowId, depth + 1, showChildren)) ++ rest
  let mut totals : Std.HashMap String Nat := {}
  let mut visible := []
  for (row, parent, depth, shown) in bottomUp do
    let launched := totals.getD row.rowId 0
    let card := cards.get? row.widgetId
    let archived := row.status == "acknowledged" || card.any (·.archiveTag)
    if archived && launched == 0 then
      visible := { row with archiveOnly := true } :: visible
      continue
    if !parent.isEmpty then
      totals := totals.insert parent (totals.getD parent 0 + launched + 1)
    if shown then
      visible := { row with depth, badge := launched } :: visible
  return visible.toArray

/-- Keep the complete roster for updates and context actions. Only the visible
    projection participates in rendering and shift-range selection. -/
def DesktopState.visibleProjectRows (st : DesktopState) : List ChromeSidebarRow := Id.run do
  let projects := st.sidebarRows.filter (·.kind == "project")
  if !st.hasLiveConnection then return st.sidebarRows
  let cards := st.missionCards.foldl (fun (index : Std.HashMap Nat MissionSummaryCard) card =>
    index.insert card.widgetId card) {}
  let projectOf := fun id => ((cards.get? id).map (·.project)).getD ""
  let mut active := #[]
  let mut archived := #[]
  let memberships := Std.HashMap.ofList (st.projectMemberships.map fun (slug, ids) => (slug, Std.HashSet.ofList ids))
  for row in st.sidebarRows do
    if row.kind == "mission" then
      let project := projectOf row.widgetId
      let membership := memberships.get? (if project.isEmpty then "default" else project)
      let mid := (row.rowId.drop 8).toString
      if st.openMission == some mid || membership.all (·.contains mid) then active := active.push row
      else if row.status == "acknowledged" || (cards.get? row.widgetId).any (·.archiveTag) then
        archived := archived.push { row with archiveOnly := true }
  let mut grouped : Std.HashMap String (Array ChromeSidebarRow) := {}
  let projectKeys := Std.HashSet.ofList (projects.map (fun row => (row.rowId.drop 8).toString))
  let mut unassigned := #[]
  let mut slug := ""
  for row in missionBranchRows active cards st.expandedMissions do
    if row.archiveOnly then
      archived := archived.push row
      continue
    if row.depth == 0 then
      let project := projectOf row.widgetId
      slug := if project.isEmpty then "default" else project
    if projectKeys.contains slug then
      grouped := grouped.insert slug ((grouped.getD slug #[]).push { row with depth := row.depth + 1 })
    else
      unassigned := unassigned.push row
  let mut visible := (st.sidebarRows.filterMap fun row =>
    if row.rowId == "nav:inbox" then
      if st.inboxEnabled then some { row with badge := st.inboxItems.length } else none
    else if row.kind == "project" || row.kind == "mission" || row.rowId == "section:missions" then none
    else some row).toArray
  for project in projects do
    let key := (project.rowId.drop 8).toString
    visible := visible.push project
    if st.expandedProjects.contains key then
      visible := visible ++ grouped.getD key #[]
  visible := visible ++ unassigned
  return (visible ++ archived).toList

/-- Connector geometry follows visible preorder, independently of the selected row. -/
def sidebarTreeBranches (rows : List ChromeSidebarRow) :
    List (ChromeSidebarRow × Bool × Bool × List Nat) := Id.run do
  let mut siblings : List Nat := []
  let mut nextDepth := 0
  let mut marked := []
  for row in rows.reverse do
    let depth := row.depth
    siblings := siblings.filter (· ≤ depth)
    marked := (row, !siblings.contains depth, decide (nextDepth > depth)) :: marked
    if !siblings.contains depth then siblings := depth :: siblings
    nextDepth := depth
  let mut rails : List Nat := []
  let mut result := #[]
  for (row, last, children) in marked do
    rails := rails.filter (· < row.depth)
    result := result.push (row, last, children, rails.map (row.depth - ·))
    if row.depth > 0 && !last then rails := row.depth :: rails
  return result.toList

def toggleSelection (st : DesktopState) (row : ChromeSidebarRow) (extend : Bool) : DesktopState := Id.run do
  let ids := (st.visibleProjectRows.filter (fun r => selectableRow r && (st.archivesOpen || !r.archiveOnly))).map (·.rowId)
  if extend then
    if let some anchor := st.selectionAnchor then
      let a := ids.idxOf anchor
      let b := ids.idxOf row.rowId
      if a < ids.length && b < ids.length then
        let range := (ids.drop (min a b)).take ((max a b) - (min a b) + 1)
        return { st with multiRows := (st.multiRows ++ range).eraseDups }
  let rows := if st.multiRows.contains row.rowId then st.multiRows.filter (· != row.rowId) else row.rowId :: st.multiRows
  return { st with multiRows := rows, selectionAnchor := some row.rowId }

/-- Context-clicks outside an explicit selection discard its targets and range anchor. -/
def contextSelection (st : DesktopState) (rowId : String) : DesktopState :=
  if st.multiRows.isEmpty || st.multiRows.contains rowId then st
  else { st with multiRows := [], selectionAnchor := none }

def missionMenuRows (st : DesktopState) (menu : MissionMenu) : List MissionMenuRow := Id.run do
  if menu.page == .draftDirectory then
    let path := menu.draft.text ++ menu.draft.imePreeditText
    let valid := path.isEmpty || path.startsWith "/"
    let children : List MissionMenuRow := (menu.directoryRows.getD []).mapIdx fun i (full, name) =>
      { id := 2000000 + i, label := name, value := full, icon := "folder" }
    let notice : List MissionMenuRow := if menu.listingFailed then
      [{ id := 729, label := "Folder listing unavailable", icon := "folder" }] else []
    return [{ id := 1, label := if path.isEmpty then "Absolute folder path" else path, icon := "folder" },
      { id := if valid then 716 else 729, label := if path.isEmpty then "Use default folder" else if valid then "Use this folder" else "Enter an absolute path", icon := "check" }] ++ children ++ notice
  if menu.page == .draftProject then
    return (st.sidebarRows.filter (·.kind == "project")).mapIdx fun i p =>
      { id := 2000000 + i, label := p.title, value := (p.rowId.drop 8).toString,
        icon := if p.rowId == "project:" ++ st.draftProject then "check" else "folder" }
  if let .picker field := menu.page then
    let choices := settingChoices st menu.mission field
    if st.catalogLoading && (field == .backend || field == .model) then
      return [{ id := 729, label := "Loading choices…", icon := "list" }]
    let rows : List MissionMenuRow := choices.mapIdx fun i (value, label) => { id := 2000000 + i, label, icon := "list", value }
    if field == .machine && st.launchMachines.isNone then
      return rows ++ [{ id := 729, label := if st.launchMachinesFailed then "Could not load remote machines. Reopen to retry." else "Loading remote machines…", icon := "list" }]
    if (nativeCatalogRequest st).isSome then
      return rows ++ [{ id := 729, label := "Checking Antigravity models…", icon := "list" }]
    if menu.nativeCatalogResult == some false then
      return rows ++ [{ id := 729, label := "Antigravity unavailable. Reopen to retry.", icon := "list" }]
    if rows.isEmpty then return [{ id := 719, label := "No available choices", icon := "list" }]
    return rows
  let clear : MissionMenuRow := { id := 727, label := "Clear selection", icon := "close", separatorBefore := true }
  if menu.mixed then return [{ id := 729, label := "No shared actions", icon := "list" }, clear]
  if menu.targets.length > 1 then
    if menu.page == .confirmDelete then
      return [{ id := 715, label := "Cancel", icon := "back" },
        { id := 728, label := s!"Delete {menu.targets.length} selected missions", icon := "close", action := some (.bulk "delete" menu.targets "") }]
    if menu.page == .destinations then
      return [{ id := 715, label := "Move to", icon := "back" }] ++ (st.sidebarRows.filter (·.kind == "project")).mapIdx fun i p =>
        { id := 2000000 + i, label := p.title, icon := "folder", action := some (.bulk "move" menu.targets (p.rowId.drop 8).toString) }
    let archived := st.missionCards.filter fun c => menu.targets.contains c.missionId && c.isArchived
    let restore := archived.map (·.missionId)
    let archive := menu.targets.filter fun id => !restore.contains id
    let move : List MissionMenuRow := if st.sidebarRows.any (·.kind == "project") then
      [{ id := 711, label := s!"Move {menu.targets.length} agents to", icon := "folder" }] else []
    return move ++ (if archive.isEmpty then [] else [{
      id := 712, label := s!"Archive {archive.length} conversations", icon := "archive",
      action := some (.bulk "archive" archive "") }]) ++ (if restore.isEmpty then [] else
      [{ id := 725, label := s!"Restore {restore.length} conversations", icon := "archive", action := some (.bulk "restore" restore "") }]) ++
      [{ id := 726, label := s!"Delete {menu.targets.length} agents…", icon := "close", separatorBefore := true }, clear]
  let card? := st.missionCards.find? (·.missionId == menu.mission)
  let currentProject := (card?.map (·.project)).getD ""
  let projects := st.sidebarRows.filter fun r => r.kind == "project" && r.rowId != "project:" ++ currentProject
  if menu.page == .settings then
    let v := currentSettings st menu.mission
    let navigation : List MissionMenuRow := if menu.trigger == 714 then [] else [{ id := 715, label := "Mission settings", icon := "back" }]
    let machine : List MissionMenuRow := if menu.mission.isEmpty then
      [{ id := 720, label := "Machine · " ++ (if v.machine.isEmpty then "Choose machine" else v.machine), icon := "nav:machines" }] else []
    return navigation ++ machine ++ [
      { id := 721, label := "Harness · " ++ v.backend, icon := "list" },
      { id := 722, label := "Model · " ++ (if v.model.isEmpty then "Default" else v.model), icon := "s:models" }] ++
      (if ["codex", "antigravity", "claudecode"].contains v.backend then
        [{ id := 723, label := "Effort · " ++ (if v.effort.isEmpty then "Default" else v.effort), icon := "list" }] else []) ++
      (if v.backend == "claudecode" then
        [{ id := 724, label := "Permissions · " ++ v.permission, icon := "nav:settings" }] else []) ++
      (if menu.trigger == 714 || projects.isEmpty then [] else [{ id := 711, label := "Move to", icon := "folder", separatorBefore := true }])
  let some card := card? | return []
  match menu.page with
  | .picker _ | .confirmDelete | .draftProject | .draftDirectory => return []
  | .actions =>
    return [{ id := 710, label := "Rename…", icon := "rename" }] ++
      (if projects.isEmpty then [] else [{ id := 711, label := "Move to", icon := "folder" }]) ++
      [{ id := 712, label := if card.isArchived then "Restore" else "Archive", icon := "archive",
         action := some (if card.isArchived then .restore card.missionId else .archive card.missionId) },
       { id := 713, label := "Copy mission ID", icon := "copy", action := some (.copyId card.missionId), separatorBefore := true },
       { id := 714, label := "Mission settings", icon := "nav:settings" }]
  | .destinations =>
    return [{ id := 715, label := "Move to", icon := "back" }] ++ projects.mapIdx fun i p =>
      { id := 2000000 + i, label := p.title, icon := "folder",
        action := some (.move card.missionId (p.rowId.drop 8).toString) }
  | .rename =>
    return [{ id := 1, label := menu.draft.text ++ menu.draft.imePreeditText, icon := "rename" },
      { id := 716, label := "Save", icon := "check", action := some (.rename card.missionId menu.draft.text) }]
  | .settings => return []

def menuFocusChange (before after : DesktopState) : Option Nat :=
  match before.missionMenu, after.missionMenu with
  | some old, none => some old.trigger
  | old, some menu =>
    let fleetLoaded := menu.page == .picker .machine && before.launchMachines.isNone && after.launchMachines.isSome
    if !fleetLoaded && old.all (·.nativeCatalogResult == menu.nativeCatalogResult) && before.catalogLoading == after.catalogLoading && old.any (fun m => m.page == menu.page && m.highlighted == menu.highlighted && m.trigger == menu.trigger) then none
    else ((missionMenuRows after menu)[menu.highlighted]?).map (·.id)
  | _, _ => none

/-- Opening a live draft gives the editor keyboard focus even when New Agent
    was invoked while the empty draft screen was already visible. -/
def desktopFocusChange (before after : DesktopState) (ev : Event) : Option Nat :=
  if before.voicePhase != .idle && before.voicePhase != after.voicePhase && after.voiceDraft then some 1
  else if let some target := menuFocusChange before after then some target
  else if before.screen == .inference && after.screen == .inference then
    match before.accountRoutePage, after.accountRoutePage with
    | none, some _ => some providersBackId
    | some page, none => ((after.providers.getD []).findIdx? (·.id == page.account.id)).map providerSettingsId
    | _, _ => none
  else if after.screen == .settingsGeneral && before.screen != after.screen then some accountFormId
  else if after.screen == .cloud && before.screen != .cloud then some 111
  else if after.screen == .cloud && before.cloudMission != after.cloudMission then some (if after.cloudMission.isEmpty then 111 else 963)
  else if after.screen == .resources && before.screen != .resources then some 114
  else if after.screen == .resources && after.resourceRows.isSome && before.resourcePage != after.resourcePage then
    some (if before.resourcePage < after.resourcePage then 947 else 946)
  else if after.screen == .inbox && before.screen != .inbox then some (if after.inboxItems.isEmpty then 102 else 940)
  else if after.hasLiveConnection && after.missionMenu.isNone && after.screen == .controlEmpty then
    let shortcut := match ev with
      | .key key mods .pressed => (key == 0x6e || key == 0x4e) && mods &&& 0x0a != 0
      | _ => false
    if shortcut || before.screen != after.screen || before.draftProject != after.draftProject then some 1 else none
  else none

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
    return (st, none)
  | .windowFocus false => return close
  | .activate 729 => return (st, none)
  | .activate 719 => return close
  | .activate 727 => return ({ st with missionMenu := none, multiRows := [], selectionAnchor := none }, some viewport)
  | .activate 726 => return update { menu with page := .confirmDelete, first := 0, highlighted := 0 }
  | .activate 710 =>
    let title := (st.missionCards.find? (·.missionId == menu.mission)).map (·.title) |>.getD ""
    return update { menu with page := .rename, first := 0, highlighted := 0, draft := { text := title, cursorOffset := title.length } }
  | .activate 711 => return update { menu with page := .destinations, first := 0, highlighted := 0 }
  | .activate 714 => return update { menu with page := .settings, first := 0, highlighted := 0 }
  | .activate 715 => return update { menu with page := .actions, first := 0, highlighted := 0 }
  | .activate id =>
    let some row := (missionMenuRows st menu).find? (·.id == id) | return (st, none)
    if menu.page == .draftDirectory && id >= 2000000 then
      return update { menu with browsePath := row.value, first := 0, highlighted := 1, directoryRows := none,
                                draft := { text := row.value, cursorOffset := row.value.length } }
    if menu.page == .draftDirectory && id == 716 && menu.draft.imePreeditText.isEmpty then
      return ({ st with draftDirectory := menu.draft.text, missionMenu := none, voicePhase := .idle }, some viewport)
    if menu.page == .draftProject then
      return ({ st with draftProject := row.value, missionMenu := none, voicePhase := .idle }, some viewport)
    if menu.page == .settings then
      if let some field := settingTrigger id then
        let next := { menu with page := .picker field, first := 0, highlighted := 0 }
        if field == .machine then return ({ st with missionMenu := some next, launchMachines := none, launchMachinesFailed := false }, some viewport)
        return update next
    if let .picker field := menu.page then return (chooseSetting st menu.mission field row.value, some viewport)
    let some action := row.action | return (st, none)
    if menu.page == .rename && (menu.draft.text.trimAscii.isEmpty || !menu.draft.imePreeditText.isEmpty) then return (st, none)
    return ({ st with missionMenu := none, writeRequest := some action }, some viewport)
  | _ =>
    if menu.page != .rename && menu.page != .draftDirectory then return (st, none)
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
    if st.voiceDraft && st.voiceAvailable && st.missionMenu.isNone then
      if let .activate id := ev then
        if id == voiceCancelId && st.voicePhase != .idle then
          return ({ st with voicePhase := .idle }, some viewport)
        if id == voiceLanguageId && st.voicePicker && st.voicePhase == .idle then
          return ({ st with voicePhase := .choosing, voiceBinding := st.connectionBinding, voiceGeneration := st.voiceGeneration + 1 }, some viewport)
        if id == voiceButtonId then
          match st.voicePhase with
          | .idle => return ({ st with voicePhase := .recording, voiceBinding := st.connectionBinding, voiceGeneration := st.voiceGeneration + 1 }, some viewport)
          | .recording => return ({ st with voicePhase := .finishing }, some viewport)
          | .choosing => return (st, none)
          | .finishing => return ({ st with voicePhase := .idle }, some viewport)
      if let .key 0xff1b _ .pressed := ev then
        if st.voicePhase != .idle then return ({ st with voicePhase := .idle }, some viewport)
    let toggle := match ev with
      | .activate id => id == sidebarToggleId
      | .key 0x62 mods .pressed => mods == 2 || mods == 8
      | _ => false
    if toggle && st.missionMenu.isNone then
      return ({ st with sidebarHidden := !st.sidebarHidden }, some viewport)
    let settings := match ev with
      | .activate 103 => true
      | .key 0x2c mods .pressed => mods == 2 || mods == 8
      | _ => false
    if settings then
      let next := resetSelection { st with screen := .settingsGeneral, modal := .none, multiRows := [], writeError := "" } none
      return ({ next with sidebarRows := next.sidebarRows.map fun r => { r with selected := r.widgetId == 103 } }, some viewport)
    if st.screen == .settingsGeneral then
      match ev with
      | .text _ | .preedit .. | .imeBatch .. | .composerReturn .. => return (st, none)
      | _ => pure ()
      if let .activate id := ev then
        if id == accountFormId then return ({ st with openAccountForm := true }, some viewport)
    if !st.hasLiveConnection || st.writeRequest.isSome then return (st, none)
    if let .key key _ state := ev then
      if [0xffe1,0xffe2,0xffe3,0xffe4,0xffeb,0xffec].contains key then
        let held := st.heldSelectionKeys.filter (· != key)
        return ({ st with heldSelectionKeys := if state == .released then held else key :: held }, none)
      if key == 0xff1b && st.missionMenu.isNone && !st.multiRows.isEmpty then
        return ({ st with multiRows := [], selectionAnchor := none }, some viewport)
    if let .windowFocus false := ev then
      return ({ st with missionMenu := none, heldSelectionKeys := [] }, if st.missionMenu.isSome then some viewport else none)
    if let some menu := st.missionMenu then return stepMissionMenu st menu ev viewport
    if st.cloudCanCreate || st.cloudAllows "send" then
      let draft := match ev with
        | .text text => st.cloudDraft.insertText text
        | .imeBatch db da text preedit _ _ => st.cloudDraft.applyImeBatch db da text preedit
        | .preedit text _ _ => st.cloudDraft.setPreedit text
        | .composerReturn true => st.cloudDraft.insertText "\n"
        | _ => st.cloudDraft
      if draft != st.cloudDraft then
        return ({ st with
                  cloudDraft := draft, cloudAttempt := if draft.text == st.cloudDraft.text then st.cloudAttempt else "",
                  cloudProject := (st.cloudSelectedProject.map (·.rowId)).getD "" }, some viewport)
    match ev with
    | .text _ | .preedit .. | .imeBatch .. =>
      if st.selectedCard.isNone && st.screen != .controlEmpty && st.screen != .controlPopulated then return (st, none)
    | _ => pure ()
    let navId := match ev with
      | .activate id => id
      | .key key mods .pressed =>
        -- XKB reports modifiers even when the key was held before this window gained focus.
        if mods &&& 0x0a == 0 then 0
        else if key == 0x69 || key == 0x49 then 102
        else if key == 0x32 then 111
        else if key == 0x36 then 114
        else if key == 0x34 then 113
        else if key == 0x33 then 112
        else if key == 0x6e || key == 0x4e then 101 else 0
      | _ => 0
    if navId == 102 && !st.inboxEnabled then return (st, none)
    if [101, 102, 111, 112, 113, 114].contains navId then
      let screen := if navId == 111 then ScreenId.cloud else if navId == 114 then .resources else if navId == 102 then .inbox else if navId == 113 then .inference else if navId == 112 then .machinesFleet else .controlEmpty
      let next := resetSelection { st with screen, fleetTopSub := 0, writeError := "", accountRoutePage := none } none
      -- These pages share the New Agent draft. A mission follow-up belongs only to its transcript.
      let next := if st.openMission.isNone then
          { next with composer := { st.composer with imePreeditText := "" } }
        else { next with draftProject := "" }
      let next := if navId == 111 then next.openCloud "" else next
      let next := if navId == 114 then { next with resourceRows := none, resourceFailed := false, resourcePage := 0 } else next
      let next := if navId == 113 then { next with providers := none, providerReadFailed := false } else next
      return ({ next with sidebarRows := next.sidebarRows.map fun row => { row with selected := row.widgetId == navId } }, some viewport)
    if st.screen == .inference then
      if let some page := st.accountRoutePage then
        if navId == providersBackId || (ev matches .key 0xff1b _ .pressed) then
          return ({ st with accountRoutePage := none, fleetTopSub := page.previousTop, writeError := "" }, some viewport)
        if navId == providersRetryId && page.failed then
          return ({ st with accountRoutePage := some { page with options := none, pending := none, failed := false }, writeError := "" }, some viewport)
        if navId >= providerRouteId 0 && !page.failed && page.pending.isNone then
          if let some row := (page.options.getD [])[navId - providerRouteId 0]? then
            if row.action == "refresh" then
              return ({ st with accountRoutePage := some { page with options := none }, writeError := "" }, some viewport)
            if row.action == "vpn" || row.action == "routers" then
              return ({ st with accountRoutePage := some { page with pending := some row }, writeError := "" }, some viewport)
      else if navId >= providerSettingsId 0 then
        if let some account := (st.providers.getD [])[navId - providerSettingsId 0]? then
          return ({ st with accountRoutePage := some { account, previousTop := st.fleetTopSub }, fleetTopSub := 0, writeError := "" }, some viewport)
    if st.screen == .cloud then
      if st.cloudCanCreate then
        let projects := st.cloudProjects
        if navId == 970 then
          return ({ st with cloudAccountIndex := (st.cloudAccountIndex + 1) % st.cloudAccounts.length, cloudAttempt := "" }, some viewport)
        if navId == 971 then
          let index := projects.findIdx (·.rowId == (st.cloudSelectedProject.map (·.rowId)).getD "")
          let some next := projects[(index + 1) % projects.length]? | return (st, none)
          return ({ st with cloudProject := next.rowId, cloudAttempt := "" }, some viewport)
        if navId == 968 || (ev matches .composerReturn false) then
          let some (provider, account, _) := st.cloudAccounts[st.cloudAccountIndex]? | return (st, none)
          let some project := st.cloudSelectedProject | return (st, none)
          let prompt := st.cloudDraft.text.trimAscii.toString
          if prompt.isEmpty || !st.cloudDraft.imePreeditText.isEmpty then return (st, none)
          return ({ st with writeRequest := some (.cloudCreate provider account (project.rowId.drop 8).toString prompt st.cloudAttempt) }, none)
      if st.cloudAllows "send" && (navId == 968 || (ev matches .composerReturn false)) &&
          !st.cloudDraft.text.trimAscii.isEmpty && st.cloudDraft.imePreeditText.isEmpty then
        return ({ st with writeRequest := some (.cloudSend st.cloudMission st.cloudDraft.text st.cloudAttempt) }, none)
      if st.cloudAllows "cancel" && navId == 969 then
        return ({ st with writeRequest := some (.cloudCancel st.cloudMission) }, none)
      let items := st.cloudItems
      if navId == 960 && (st.cloudLines.isSome || st.cloudFailed) then
        return ({ st with cloudLines := none, cloudFailed := false, cloudPage := 0 }, some viewport)
      if !st.cloudMission.isEmpty && (navId == 963 || (ev matches .key 0xff1b 0 .pressed)) then
        return (st.openCloud "", some viewport)
      if navId == 961 || (ev matches .key 0xff55 0 .pressed) then
        return ({ st with cloudPage := st.cloudPage - 1 }, some viewport)
      if navId == 962 || (ev matches .key 0xff56 0 .pressed) then
        return ({ st with cloudPage := min ((items.length - 1) / 4) (st.cloudPage + 1) }, some viewport)
      if navId >= 964 && navId < 968 then
        if let some (mission, _) := items[4 * st.cloudPage + navId - 964]? then
          if !mission.isEmpty then
            return (st.openCloud mission, some viewport)
      if ev matches .composerReturn .. then return (st, none)
    if st.screen == .resources then
      if navId == 945 then
        return ({ st with resourceRows := none, resourceFailed := false, resourcePage := 0 }, some viewport)
      if navId >= 955 && navId < 960 then
        let range := resourceRanges.getD (navId - 955) "6h"
        return ({ st with resourceRange := range, resourceRows := none, resourceFailed := false, resourcePage := 0 }, some viewport)
      let rows := st.resourceRows.getD []
      if navId == 946 || (ev matches .key 0xff55 0 .pressed) then
        return ({ st with resourcePage := st.resourcePage - 1 }, some viewport)
      if navId == 947 || (ev matches .key 0xff56 0 .pressed) then
        return ({ st with resourcePage := min ((rows.length - 1) / 4) (st.resourcePage + 1) }, some viewport)
      if navId >= 950 && navId < 954 then
        if let some row := rows[4 * st.resourcePage + navId - 950]? then
          if let some card := st.missionCards.find? (fun c => !row.mission.isEmpty && c.missionId == row.mission) then
            return (resetSelection { st with screen := .missionTranscript } (some card), some viewport)
      if ev matches .composerReturn .. then return (st, none)
    if st.screen == .inbox then
      let index := min st.inboxIndex (st.inboxItems.length - 1)
      if navId == 942 || (ev matches .key 0xff52 _ .pressed) then
        return ({ st with inboxIndex := index - 1 }, some viewport)
      if navId == 943 || (ev matches .key 0xff54 _ .pressed) then
        return ({ st with inboxIndex := min (index + 1) (st.inboxItems.length - 1) }, some viewport)
      if navId == 940 || navId == 941 then
        if !st.inboxAvailable then return (st, none)
        let some item := st.currentInboxItem | return (st, none)
        return ({ st with writeRequest := some (.inboxRead item (navId == 940)) }, none)
      match ev with
      | .text _ | .imeBatch .. | .preedit .. | .composerReturn .. => return (st, none)
      | _ => pure ()
    if st.screen == .inference && st.accountRoutePage.isNone && navId >= providerWidgetId 0 then
      if let some account := (st.providers.getD [])[navId - providerWidgetId 0]? then
        return ({ st with writeRequest := some (.providerPreference account.id (!account.userEnabled)) }, none)
    if let .composerReturn shift := ev then
      if st.screen == .inference || st.screen == .machinesFleet then return (st, none)
      if !st.composer.imePreeditText.isEmpty then return (st, none)
      if shift then return stepDesktopInput scale120 viewport st (.text "\n")
      if st.composer.isRunning then return (st, none)
    let activation := match ev with
      | .activate id => some id
      | .composerReturn false => some 2
      | _ => none
    if let some id := activation then
      if id >= missionDisclosureId 0 then
        if let some row := st.sidebarRows.find? (fun r => r.kind == "mission" && missionDisclosureId r.widgetId == id) then
          let expanded := if st.expandedMissions.contains row.rowId then
              st.expandedMissions.erase row.rowId else row.rowId :: st.expandedMissions
          return ({ st with expandedMissions := expanded }, some viewport)
      if let some row := st.sidebarRows.find? (fun r => r.widgetId == id && selectableRow r) then
        if !st.heldSelectionKeys.isEmpty then
          return (toggleSelection st row (st.heldSelectionKeys.any fun k => k == 0xffe1 || k == 0xffe2), some viewport)
      if let some project := st.sidebarRows.find? (fun r => r.widgetId == id && r.kind == "project") then
        let slug := (project.rowId.drop 8).toString
        let expanded := if st.expandedProjects.contains slug then st.expandedProjects.erase slug else slug :: st.expandedProjects
        return ({ st with expandedProjects := expanded }, some viewport)
      if id >= projectNewAgentId 0 then
        if let some project := st.sidebarRows.find? (fun r => r.kind == "project" && projectNewAgentId r.widgetId == id) then
          let next := resetSelection { st with screen := .controlEmpty, draftProject := (project.rowId.drop 8).toString, writeError := "" } none
          return (next, some viewport)
      if id == 914 then return ({ st with writeError := "" }, some viewport)
      if id == 730 then return ({ st with archivesOpen := !st.archivesOpen }, some viewport)
      if id == 2 && st.selectedCard.isNone then
        if (st.screen == .controlEmpty || st.screen == .controlPopulated) &&
            !st.composer.text.trimAscii.isEmpty && st.composer.imePreeditText.isEmpty then
          if st.draftSettings.backend == "antigravity" && st.draftSettings.model.isEmpty then
            return ({ st with writeError := "Choose an Antigravity model for this machine." }, some viewport)
          return ({ st with voicePhase := .idle, writeRequest := some .create }, none)
        return (st, none)
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
        if st.openMission == some card.missionId then return ({ st with multiRows := [], selectionAnchor := none }, some viewport)
        return (resetSelection { st with screen := .missionTranscript, multiRows := [], selectionAnchor := none } (some card), some viewport)
  return stepDesktopInput scale120 viewport st ev

/-- Device-pixel band occupied by the live transcript. Stream deltas repaint this band only; the
sidebar, header and composer retain their framebuffer pixels. -/
def transcriptDamageRect (scale120 : Nat) (viewport : Rect) (sidebarWidth := chromeSidebarWidthSub) : Rect :=
  let x0 := floorDev scale120 (Int.ofNat sidebarWidth)
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
    ({ st with stream := stream' }, Damage.add none (transcriptDamageRect scale120 viewport st.sidebarWidth))

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
