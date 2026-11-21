import OrbDesktop.State
import Orb.ProjectAppearance
import Std.Sync.Mutex
import Std.Data.HashMap

namespace OrbDesktop

/-! Live desktop bootstrap.  The helper deliberately emits a small tab-separated
projection rather than passing credentials through the UI state.  `--headless`
golden paths never call this module and remain deterministic fixtures. -/

/-- Embed the connection-bound HTTP reader, including the GTK Inbox source projection. -/
private def transport : String := include_str "live_transport.py"

private def projectHistoryRules : String := include_str "../../../orb/src/projectHistoryRules.json"
private def modelCatalogRules : String := include_str "../../../orb/src/modelSuccessors.json"

private def splitTab (line : String) : List String :=
  line.splitOn "\t"

private def col (xs : List String) (n : Nat) : String := xs.getD n ""

private def projectRow (idx : Nat) (xs : List String) : ChromeSidebarRow :=
  { widgetId := 1000 + 3 * idx, rowId := "project:" ++ col xs 1, kind := "project"
    title := col xs 2, subtitle := col xs 3
    iconColor := (Orb.ProjectAppearance.rgb? (col xs 4)).map fun rgb => (rgb * 256 + 255).toUInt32 }

private def missionCard (idx : Nat) (xs : List String) : MissionSummaryCard :=
  { widgetId := 1001 + 3 * idx, missionId := col xs 1, title := col xs 2, project := col xs 3
    track := col xs 4, model := col xs 13
    status := col xs 7, updatedLabel := if (col xs 8).isEmpty then col xs 9 else col xs 8
    summaryText := col xs 10, machine := col xs 11, backend := col xs 12,
    effort := col xs 14, permissionMode := col xs 15,
    folder := col xs 16, parentMissionId := col xs 17, callbackParentMissionId := col xs 18,
    forkSource := col xs 19, supersededBy := col xs 20, archiveTag := col xs 21 == "1" }

private def inboxItem (xs : List String) : Option InboxItem := do
  guard (col xs 0 == "U" && col xs 4 == "M" && col xs 5 == col xs 1)
  return { mission := col xs 1, stamp := ← (col xs 2).toNat?, version := ← (col xs 3).toNat?
           card := missionCard 0 (xs.drop 4) }

private def nextMissionWidget (st : DesktopState) : Nat :=
  1001 + 3 * (1 + (st.sidebarRows.foldl (fun n row => max n row.widgetId) 1000 - 1000) / 3)

private def machineCard (idx : Nat) (xs : List String) : FleetMachineCard :=
  { widgetId := 1002 + 3 * idx, machineId := col xs 1, name := col xs 2
    roleLabel := if (col xs 3).isEmpty then col xs 4 else col xs 3
    cpuRamSpec := if (col xs 5).isEmpty then col xs 6 else col xs 5
    state := if (col xs 7).isEmpty then col xs 8 else col xs 7
    ttlLabel := col xs 9, costLabel := col xs 10, activeMissions := (col xs 11).toNat?.getD 0 }

private def liveStateFromProjection (lines : List String) (isDark : Bool) (scale120 : Nat) : Option DesktopState := do
  let header :: lines := lines | none
  let ["C", binding] := splitTab header | none
  let ps := lines.filterMap (fun line => let xs := splitTab line; if col xs 0 == "P" then some xs else none)
  let ms := lines.filterMap (fun line => let xs := splitTab line; if col xs 0 == "M" then some xs else none)
  let ns := lines.filterMap (fun line => let xs := splitTab line; if col xs 0 == "N" then some xs else none)
  let projects := ps.toArray.mapIdx (fun i xs => projectRow i xs) |>.toList
  let missions := ms.toArray.mapIdx (fun i xs => missionCard i xs) |>.toList
  let machines := ns.toArray.mapIdx (fun i xs => machineCard i xs) |>.toList
  let missionRows : List ChromeSidebarRow := missions.map fun m =>
    { widgetId := m.widgetId, rowId := "mission:" ++ m.missionId, kind := "mission", title := m.title, status := m.status }
  let sidebar := [{ widgetId := 101, rowId := "nav:new", kind := "nav", title := "New Agent", shortcut := "⌘N", selected := true },
    { widgetId := 102, rowId := "nav:inbox", kind := "nav", title := "Inbox", shortcut := "⌘I" },
    { widgetId := 112, rowId := "nav:machines", kind := "nav", title := "Machines", shortcut := "⌘3" },
    { widgetId := 113, rowId := "nav:inference", kind := "nav", title := "Inference", shortcut := "⌘4" },
    { widgetId := 109, rowId := "section:missions", kind := "section", title := "Missions" }] ++ missionRows ++
    [{ widgetId := 108, rowId := "section:projects", kind := "section", title := "Projects" }] ++ projects
  return { DesktopState.liveUnavailable isDark scale120 with
    screen := if missions.isEmpty then .controlEmpty else .controlPopulated
    syncCursor := { epoch := 0, seq := 0 }
    connectionBinding := binding
    stream := Orb.Stream.Coalescer.empty
    expandedProjects := match projects with
      | [onlyProject] => [(onlyProject.rowId.drop 8).toString]
      | _ => []
    sidebarRows := sidebar
    missionCards := missions
    fleetMachines := machines, catalogLoading := true }

private inductive ReadKind where
  | roster (previous : String) | catalog (revision : Nat) | providers
  | nativeModels (machine : String)
  | accountRoutes (account provider action value : String)
  | directories (machine path : String)
  | launchMachines (admin : Bool) (harness : String)
  deriving BEq

private structure LiveRead where
  binding : String
  kind : ReadKind
  take : IO (Option (List String))
  stop : IO Unit

private def startLiveRead (binding : String) (kind : ReadKind) (notify : IO Unit) : IO LiveRead := do
  let args := match kind with
    | .roster previous => #["-I", "-c", transport ++ "\nrecover_roster(sys.argv[1])", previous]
    | .nativeModels machine => #["-I", "-c", transport ++ "\nnative_models(*sys.argv[1:])", binding, machine]
    | .accountRoutes account provider action value => #["-I", "-c", transport ++ "\naccount_routes(*sys.argv[1:])", binding, account, provider, action, value]
    | .directories machine path => #["-I", "-c", transport ++ "\nlist_directories(*sys.argv[1:])", binding, machine, path]
    | .launchMachines admin harness => #["-I", "-c", transport ++ "\nlaunch_machines(*sys.argv[1:])", binding, if admin then "admin" else "member", harness]
    | .providers => #["-I", "-c", transport ++ "\nprovider_inventory(sys.argv[1])", binding]
    | .catalog _ => #["-I", "-c", transport ++ "\ncatalog(sys.argv[1], json.loads(sys.argv[2]))", binding, modelCatalogRules]
  let child ← IO.Process.spawn { cmd := "python3", args, stdout := .piped, stderr := .null }
  let mailbox ← Std.Mutex.new (none : Option (List String))
  let reader ← IO.asTask (prio := .dedicated) do
    let out ← try child.stdout.readToEnd catch _ => pure ""
    mailbox.atomically (set (some (out.splitOn "\n")))
    notify
  return { binding, kind, take := mailbox.atomically (modifyGet fun rows => (rows, none)), stop := do
    try child.kill catch _ => pure ()
    discard child.wait
    discard (IO.wait reader) }

/-- Keep recovery and catalog reads off the window thread. A new binding retires
    its predecessor's reader before any result can enter the new session. -/
def withLiveSources {α : Type} (isDark : Bool) (notify : IO Unit)
    (k : (DesktopState → IO (Option DesktopState)) → IO α) : IO α := do
  let slot ← IO.mkRef (none : Option LiveRead)
  let close := do
    if let some r ← slot.swap none then r.stop
  try
    k fun st => do
      if !st.liveData then return none
      let current ← slot.get
      let kind : Option ReadKind := if !st.hasLiveConnection then
          some (.roster (if st.initialRosterPending then "" else st.connectionIssue.code))
        else if st.missionMenu.any (·.page == .picker .machine) && st.launchMachines.isNone && !st.launchMachinesFailed then
          some (.launchMachines (st.fleetMachines.any (·.machineId == "core")) st.draftSettings.backend)
        else if st.missionMenu.any (fun m => m.page == .draftDirectory && m.directoryRows.isNone && !m.listingFailed) &&
            (!st.draftSettings.machine.isEmpty || st.fleetMachines.any (·.machineId == "core")) then
          let machine := if st.draftSettings.machine.isEmpty then "core" else st.draftSettings.machine
          some (.directories machine ((st.missionMenu.map (·.browsePath)).getD ""))
        else if st.screen == .inference && st.providers.isNone && !st.providerReadFailed then some .providers
        else if let some page := st.accountRoutePage then
          if st.screen == .inference && !page.failed && (page.options.isNone || page.pending.isSome) then
            some (.accountRoutes page.account.id page.account.providerType ((page.pending.map (·.action)).getD "") ((page.pending.map (·.value)).getD ""))
          else if st.catalogLoading then some (.catalog st.catalogRevision) else none
        else if st.catalogLoading then some (.catalog st.catalogRevision)
        else (nativeCatalogRequest st).map ReadKind.nativeModels
      -- Navigation may cancel a stale read. A submitted shared account update
      -- must settle before another page fetches the account's saved route.
      if let some source := current then
        if let .accountRoutes _ _ action _ := source.kind then
          if !action.isEmpty && source.binding == st.connectionBinding && some source.kind != kind then
            if (← source.take).isNone then return none
            close
      if current.any (fun r => r.binding != st.connectionBinding || some r.kind != kind) then close
      let some kind := kind | return none
      let source ← match ← slot.get with
        | some r => pure r
        | none => do
          let r ← startLiveRead st.connectionBinding kind notify
          slot.set (some r)
          pure r
      let some lines ← source.take | return none
      close
      if source.binding.isEmpty then
        if let some ready := liveStateFromProjection lines isDark st.scale120 then return some ready
        let issue : ConnectionIssue := match lines.head? with
          | some "F\tmissing" => .missing
          | some "F\tsignin" => .signin
          | some "F\tdenied" => .denied
          | some "F\tinvalid" => .invalid
          | _ => .unavailable
        return if st.initialRosterPending || issue != st.connectionIssue then
          some { st with initialRosterPending := false, connectionIssue := issue } else none
      if let .nativeModels machine := source.kind then
        let ok := lines.head? == some "native-models"
        let menu := st.missionMenu.map fun m => { m with nativeCatalogResult := some ok }
        if !ok then return some { st with missionMenu := menu }
        let rows := lines.filterMap fun line => match splitTab line with
          | ["N", id, name] => some ({ backend := "antigravity", harnessName := "Antigravity CLI", model := id, modelName := name } : CatalogModel)
          | _ => none
        return some (applyNativeCatalog { st with missionMenu := menu } machine rows)
      if let .accountRoutes account _ _ _ := source.kind then
        let some page := st.accountRoutePage | return none
        if page.account.id != account then return none
        if ![some "routes", some "unconfirmed"].contains lines.head? then
          return some { st with accountRoutePage := some { page with failed := true, pending := none } }
        let rows := lines.filterMap fun line => match splitTab line with
          | ["D", action, value, title, detail] => some ({ action, value, title, detail } : AccountRouteOption)
          | _ => none
        let changed := page.pending.isSome
        return some { st with accountRoutePage := some { page with options := some rows, pending := none }
                              catalogLoading := st.catalogLoading || changed
                              catalogRevision := st.catalogRevision + (if changed then 1 else 0)
                              writeError := if lines.head? == some "unconfirmed" then "Core could not confirm the change. Check the current setting." else "" }
      if let .directories .. := source.kind then
        let entries := lines.filterMap fun line => match splitTab line with
          | ["D", path, title] => some (path, title)
          | _ => none
        let menu := st.missionMenu.map fun m => { m with directoryRows := some entries, listingFailed := lines.head? != some "directories" }
        return some { st with missionMenu := menu }
      if let .launchMachines .. := source.kind then
        if lines.head? != some "machines" then return some { st with launchMachinesFailed := true }
        let nodes := lines.filterMap fun line => match splitTab line with
          | ["R", id, title] => some (id, title)
          | _ => none
        return some { st with launchMachines := some nodes }
      if source.kind == .providers then
        if lines.head? != some "accounts" then return some { st with providerReadFailed := true }
        let rows := lines.filterMap fun line =>
          match splitTab line with
          | ["A", id, name, category, personal, globalFlag, providerType] =>
            some ({ id, name, category, providerType, userEnabled := personal == "1", globallyEnabled := globalFlag == "1" } : ProviderAccount)
          | _ => none
        return some { st with providers := some rows }
      let models := lines.filterMap fun line =>
        match splitTab line with
        | ["H", backend, harnessName, model, modelName] =>
          some ({ backend, harnessName, model, modelName } : CatalogModel)
        | _ => none
      return some { st with catalog := models, catalogLoading := false, nativeHarnessAvailable := lines.contains "native-antigravity" }
  finally close

inductive BubbleUpdate where
  | text (title status value : String)
  | unavailable
  | revoked

inductive LiveUpdate where
  | sample (roster : Option (List String)) (bubble : Option BubbleUpdate)
  | invalid

structure LiveSubscription where
  projects : List String
  mission : String
  binding : String
  latest : Std.Mutex (Option LiveUpdate)
  lastBubble : IO.Ref (Option BubbleUpdate)
  stop : IO Unit

private def readSample (line : String) : Option LiveUpdate := do
  match splitTab line with
  | ["R", keys] =>
    guard (keys.startsWith "+")
    let encoded := (keys.drop 1).toString
    return .sample (some (if encoded.isEmpty then [] else encoded.splitOn "\x1f")) none
  | ["B", title, status, text] =>
    return .sample none (some (.text title status ((text.replace "\x1e" "\n").replace "\x1f" "\t")))
  | ["X"] => return .sample none (some .unavailable)
  | ["D"] => return .sample none (some .revoked)
  | _ => none

/-- Each process owns its HTTP deadlines. A pending roster and a pending bubble
    coalesce independently, and neither can supersede session invalidation. -/
private def liveReader (args : Array String) (input : String)
    (latest : Std.Mutex (Option LiveUpdate)) (notify : IO Unit) : IO (IO Unit) := do
  let child ← IO.Process.spawn { cmd := "python3", args, stdin := .piped, stdout := .piped, stderr := .null }
  try
    if !input.isEmpty then child.stdin.putStr input; child.stdin.flush
  catch err =>
    try child.kill catch _ => pure ()
    discard child.wait
    throw err
  let reader ← IO.asTask (prio := .dedicated) do
    try
      repeat
        let line ← child.stdout.getLine
        let some (.sample rows bubble) := readSample (line.dropEnd 1).toString | break
        if !line.endsWith "\n" then break
        latest.atomically (modify fun previous => match previous with
          | some .invalid => previous
          | some (.sample _ (some .revoked)) => previous
          | some (.sample oldRows oldBubble) =>
            some (.sample (rows.orElse fun _ => oldRows) (bubble.orElse fun _ => oldBubble))
          | none => some (.sample rows bubble))
        notify
        if let some .revoked := bubble then return
    catch _ => pure ()
    latest.atomically (set (some LiveUpdate.invalid))
    notify
  return do
    try child.kill catch _ => pure ()
    discard child.wait
    discard (IO.wait reader)

private def subscribe (mission binding : String) (tracked : List MissionSummaryCard) (projects : List String)
    (notify : IO Unit) : IO LiveSubscription := do
  let latest ← Std.Mutex.new (none : Option LiveUpdate)
  let rosterArgs := #["-I", "-c", transport ++ "\npoll(sys.argv[1], sys.argv[2], rules=json.loads(sys.argv[3]))",
    mission, binding, projectHistoryRules]
  let input := String.intercalate "," (tracked.map (·.missionId)) ++ "\n" ++ String.intercalate "\t" projects ++ "\n"
  let stopRoster ← liveReader rosterArgs input latest notify
  let stop ← try
    if mission.isEmpty then pure stopRoster else do
      let stopBubble ← liveReader #["-I", "-c", transport ++ "\npoll_bubble(*sys.argv[1:])", mission, binding] "" latest notify
      pure (do stopBubble; stopRoster)
  catch err =>
    stopRoster
    throw err
  let lastBubble ← IO.mkRef none
  return { mission, binding, projects, latest, lastBubble, stop }

def closeLiveSubscription (slot : IO.Ref (Option LiveSubscription)) : IO Unit := do
  if let some sub ← slot.swap none then sub.stop

/-- Reconcile the latest authorized page with the current rows. Widget IDs stay
stable across reordering so an open menu continues to target the same mission. -/
private def mergeRoster (st : DesktopState) (records : List String) : DesktopState := Id.run do
  let oldRows := Std.HashMap.ofList (st.sidebarRows.map fun row => (row.rowId, row))
  let oldCards := Std.HashMap.ofList (st.missionCards.map fun card => (card.missionId, card))
  let mut idx := 1 + (st.sidebarRows.foldl (fun n row => max n row.widgetId) 1000 - 1000) / 3
  let mut cards := #[]
  let mut rows := (st.sidebarRows.filter (fun row => row.kind != "project" && row.kind != "mission")).toArray
  let mut machines := #[]
  let mut memberships := st.projectMemberships
  for record in records do
    let xs := record.splitOn "\x1c"
    let id := col xs 1
    match col xs 0 with
    | "P" =>
      let row := projectRow idx xs
      if let some old := oldRows.get? row.rowId then
        rows := rows.push { row with widgetId := old.widgetId, selected := old.selected }
      else
        rows := rows.push row
        idx := idx + 1
    | "M" | "K" =>
      let old := oldCards.get? id
      let some card := if col xs 0 == "K" then old else some (missionCard idx xs) | continue
      let card := { card with widgetId := (old.map (·.widgetId)).getD card.widgetId }
      if old.isNone then idx := idx + 1
      let key := "mission:" ++ id
      let row := (oldRows.get? key).getD { widgetId := card.widgetId, rowId := key, kind := "mission", title := card.title }
      cards := cards.push card
      rows := rows.push { row with title := card.title, status := card.status }
    | "G" => memberships := (id, xs.drop 2) :: memberships.filter (·.1 != id)
    | "N" => machines := machines.push (machineCard machines.size xs)
    | _ => continue
  let inboxItems := records.filterMap fun r => inboxItem (r.splitOn "\x1c")
  let refreshing := records.contains "I\x1crefreshing" || records.head? == some "partial-projects"
  let finished := records.contains "I\x1cenabled" || records.contains "I\x1cdisabled"
  let inboxAvailable := finished || (refreshing && st.inboxAvailable)
  let inboxEnabled := if finished then !records.contains "I\x1cdisabled" else st.inboxEnabled
  let inboxItems := if finished then inboxItems else st.inboxItems
  let inboxIndex := (st.currentInboxItem.bind fun item => inboxItems.findIdx? (·.mission == item.mission)).getD
    (min st.inboxIndex (inboxItems.length - 1))
  let updated := { st with
    inboxItems, inboxEnabled, inboxIndex, inboxAvailable, projectMemberships := memberships
    missionCards := cards.toList, sidebarRows := rows.toList, fleetMachines := machines.toList }
  let some selected := updated.selectedCard | return updated
  return { updated with composer := { updated.composer with isRunning := selected.isRunning } }

/-- The window thread owns selection and damage. Each reader owns a fresh,
single-value mailbox, so a retired subscription cannot update a new mission. -/
def readLiveFrame (slot : IO.Ref (Option LiveSubscription)) (scale : Nat) (viewport : LeanUI.Rect)
    (st : DesktopState) (notify : IO Unit := pure ()) : IO (DesktopState × LeanUI.Damage) := do
  let active ← slot.get
  if let some request := st.writeRequest then
    let st := { st with writeRequest := none, writeError := "" }
    let encode := fun (v : LaunchSettings) => String.intercalate "\t" [v.machine, v.backend, v.model, v.effort, v.permission]
    let (action, mid, text) := match request with
      | .inboxRead item _ => ("inbox-read", item.mission, s!"{item.stamp} {item.version}")
      | .providerPreference account enabled => (if enabled then "use-provider" else "skip-provider", account, "")
      | .create => ("create", "", st.draftDirectory ++ String.singleton (Char.ofNat 0) ++ encode st.draftSettings ++ "\t" ++ st.draftProject ++ "\t" ++ st.composer.text)
      | .send mid text => ("send", mid, text)
      | .stop mid => ("stop", mid, "")
      | .archive mid => ("archive", mid, "")
      | .restore mid => ("restore", mid, "")
      | .rename mid title => ("rename", mid, title)
      | .move mid project => ("move", mid, project)
      | .copyId mid => ("copy-id", mid, "")
      | .bulk kind mids project => ("bulk-" ++ kind, "", String.intercalate "\n" (project :: mids))
      | .settings mid field values =>
        let key := match field with
          | .machine => "machine" | .backend => "backend" | .model => "model"
          | .effort => "effort" | .permission => "permission"
        ("settings", mid, key ++ "\t" ++ encode values)
    try
      let r ← IO.Process.output { cmd := "python3", args := #["-I", "-c", transport ++ "\nsys.exit(run_mutation(*sys.argv[1:]))", st.connectionBinding, action, mid] } (input? := some text)
      if action == "archive" && r.exitCode == 2 then
        return ({ st with writeError := "Stop or finish this agent before archiving it." }, some viewport)
      if r.exitCode == 3 then
        return ({ st with writeError := "Choose a Goal-capable harness or remove /goal." }, some viewport)
      if r.exitCode == 4 then
        return ({ st with writeError := "Start a new Goal mission or remove /goal." }, some viewport)
      if r.exitCode == 5 then
        return ({ st with writeError := "Choose an available remote machine for this mission." }, some viewport)
      if r.exitCode != 0 then throw (IO.userError "write failed")
      match request with
      | .providerPreference .. => pure ()
      | _ => closeLiveSubscription slot
      match request with
      | .inboxRead item openItem =>
        let next := { st with inboxItems := st.inboxItems.filter (· != item) }
        if openItem then
          if let some card := st.missionCards.find? (·.missionId == item.mission) then
            return (resetSelection { next with screen := .missionTranscript } (some card), some viewport)
          let card := { item.card with widgetId := nextMissionWidget st }
          let row : ChromeSidebarRow := {
            widgetId := card.widgetId, rowId := "mission:" ++ card.missionId
            kind := "mission", title := card.title, status := card.status }
          let next := { next with
            screen := .missionTranscript, missionCards := card :: next.missionCards, sidebarRows := row :: next.sidebarRows }
          return (resetSelection next (some card), some viewport)
        return (next, some viewport)
      | .providerPreference account enabled =>
        let providers := st.providers.map fun rows =>
          rows.map fun p => if p.id == account then { p with userEnabled := enabled } else p
        return ({ st with providers, nativeCatalog := none, catalogLoading := true, catalogRevision := st.catalogRevision + 1 }, some viewport)
      | .create =>
        let [id,title,status,machine,backend,model,effort,permissionMode,project] := splitTab (r.stdout.dropEnd 1).toString | throw (IO.userError "invalid mission")
        let wid := nextMissionWidget st
        let card := { (default : MissionSummaryCard) with widgetId := wid, missionId := id, title, status, machine, backend, model, effort, permissionMode, project }
        let row := { (default : ChromeSidebarRow) with widgetId := wid, rowId := "mission:" ++ id, kind := "mission", title, status }
        return (resetSelection { st with screen := .missionTranscript, missionCards := card :: st.missionCards, sidebarRows := row :: st.sidebarRows } (some card), some viewport)
      | .archive _ =>
        let next := { st with
          missionCards := st.missionCards.map fun m => if m.missionId == mid then { m with status := "acknowledged" } else m,
          sidebarRows := st.sidebarRows.map fun row => if row.rowId == "mission:" ++ mid then { row with status := "acknowledged" } else row }
        return (if st.openMission == some mid then resetSelection { next with screen := .controlEmpty } none else next, some viewport)
      | .restore _ =>
        return ({ st with
                          missionCards := st.missionCards.map fun m => if m.missionId == mid then { m with status := restoredExecutionStatus m.status, archiveTag := false } else m,
                          sidebarRows := st.sidebarRows.map fun row => if row.rowId == "mission:" ++ mid then { row with status := restoredExecutionStatus row.status } else row }, some viewport)
      | .rename _ title =>
        return ({ st with
                          missionCards := st.missionCards.map fun m => if m.missionId == mid then { m with title } else m,
                          sidebarRows := st.sidebarRows.map fun row => if row.rowId == "mission:" ++ mid then { row with title } else row }, some viewport)
      | .move _ project =>
        let moved := r.stdout.trimAscii.toString.splitOn "\n"
        return ({ st with missionCards := st.missionCards.map fun m => if moved.contains m.missionId then { m with project } else m }, some viewport)
      | .bulk kind _ project =>
        let receipts := (r.stdout.splitOn "\n").map splitTab
        let changed := receipts.filterMap fun xs => if col xs 0 == "ok" then some (col xs 1) else none
        let failed := receipts.filterMap fun xs => if col xs 0 == "failed" then some (col xs 1) else none
        let remove := kind == "delete"
        let nextStatus := fun previous => if kind == "archive" then "acknowledged" else restoredExecutionStatus previous
        let cards := st.missionCards.filterMap fun m =>
          if !changed.contains m.missionId then some m
          else if remove then none else if kind == "move" then some { m with project } else some { m with status := nextStatus m.status, archiveTag := kind == "archive" && m.archiveTag }
        let rows := st.sidebarRows.filterMap fun row =>
          if !changed.contains (row.rowId.drop 8).toString || row.kind != "mission" then some row
          else if remove then none else if kind == "move" then some row else some { row with status := nextStatus row.status }
        let next := { st with
          missionCards := cards, sidebarRows := rows, multiRows := failed.map ("mission:" ++ ·),
          selectionAnchor := none, writeError := if failed.isEmpty then "" else s!"Core did not confirm {kind} for {failed.length} missions" }
        return (if (remove || kind == "archive") && next.openMission.any changed.contains then resetSelection { next with screen := .controlEmpty } none else next, some viewport)
      | .copyId _ => return (st, some viewport)
      | .settings .. =>
        let [machine,backend,model,effort,permissionMode] := splitTab (r.stdout.dropEnd 1).toString | throw (IO.userError "invalid settings response")
        let cards := st.missionCards.map fun m =>
          if m.missionId == mid then { m with machine, backend, model, effort, permissionMode } else m
        return ({ st with missionCards := cards }, some viewport)
      | .send .. => return ({ st with composer := { isRunning := st.composer.isRunning } }, some viewport)
      | .stop _ => return (st, some viewport)
    catch _ =>
      let message := if action == "inbox-read" then "Couldn't mark this item read. Check the Inbox and try again."
        else "Core did not confirm " ++ action
      return ({ st with writeError := message }, some viewport)
  let invalidate := ({ DesktopState.liveUnavailable with theme := st.theme, scale120 := scale }, some viewport)
  let target := if st.hasLiveConnection then some (st.openMission.getD "") else none
  if active.map (·.mission) != target || active.any (fun sub => sub.binding != st.connectionBinding || sub.projects != st.expandedProjects) then
    closeLiveSubscription slot
    if let some mission := target then
      try slot.set (some (← subscribe mission st.connectionBinding st.missionCards st.expandedProjects notify)) catch _ => return invalidate
  let some sub ← slot.get | return (st, none)
  let some update ← sub.latest.atomically (modifyGet (fun v => (v, none))) | return (st, none)
  match update with
  | .invalid => closeLiveSubscription slot; return invalidate
  | .sample roster bubble =>
    -- The roster can finish after a newer transcript read. Keep the selected
    -- conversation's title, status and text together across that arrival.
    if bubble.isSome then sub.lastBubble.set bubble
    let bubble ← sub.lastBubble.get
    let updated := roster.elim st (mergeRoster st)
    let changed := roster.isSome && (updated.missionCards != st.missionCards ||
      updated.inboxItems != st.inboxItems || updated.inboxEnabled != st.inboxEnabled || updated.inboxAvailable != st.inboxAvailable ||
      updated.sidebarRows != st.sidebarRows || updated.fleetMachines != st.fleetMachines || updated.projectMemberships != st.projectMemberships)
    let st := updated
    let cards := st.missionCards
    let rows := st.sidebarRows
    let menu := st.missionMenu.bind fun m =>
      if (m.mission.isEmpty || cards.any (·.missionId == m.mission)) && m.targets.all (fun id => cards.any (·.missionId == id))
      then some m else none
    let st := { st with
      missionMenu := menu,
      multiRows := st.multiRows.filter fun id => rows.any (·.rowId == id) }
    if st.openMission.isSome && st.selectedCard.isNone then
      closeLiveSubscription slot
      let (st, _) := stepDesktopEvent scale viewport st (.activate 101)
      return (st, some viewport)
    if let some .revoked := bubble then
      closeLiveSubscription slot
      let next := { st with
        missionCards := cards.filter (·.missionId != sub.mission)
        sidebarRows := rows.filter (·.rowId != "mission:" ++ sub.mission) }
      return ((stepDesktopEvent scale viewport next (.activate 101)).1, some viewport)
    if let some .unavailable := bubble then
      let (next, damage) := applyLiveText scale viewport st sub.mission ""
      return (next, if changed then some viewport else damage)
    let some (.text title status text) := bubble | return (st, if changed then some viewport else none)
    let (next, damage) := applyLiveText scale viewport st sub.mission text
    let some card := next.selectedCard | return invalidate
    if title == card.title && status == card.status then return (next, if changed then some viewport else damage)
    return ({ next with
      composer := { next.composer with isRunning := ({ card with status } : MissionSummaryCard).isRunning }
      missionCards := next.missionCards.map fun m => if m.missionId == sub.mission then { m with title, status } else m
      sidebarRows := next.sidebarRows.map fun r => if r.widgetId == card.widgetId then { r with title, status } else r }, some viewport)

end OrbDesktop
