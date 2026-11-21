import OrbDesktop.State
import Orb.ProjectAppearance
import Std.Sync.Mutex
import Std.Data.HashMap

namespace OrbDesktop

/-! Live desktop bootstrap.  The helper deliberately emits a small tab-separated
projection rather than passing credentials through the UI state.  `--headless`
golden paths never call this module and remain deterministic fixtures. -/

/-- Embedded connection-bound HTTP reader and writer. -/
private def transport : String := include_str "live_transport.py"

private def modelCatalogRules : String := include_str "../../../orb/src/modelSuccessors.json"

private def splitTab (line : String) : List String :=
  line.splitOn "\t"

private def col (xs : List String) (n : Nat) : String := xs.getD n ""

private def inboxItem (xs : List String) : Option InboxItem := do
  guard (col xs 0 == "U")
  return { mission := col xs 1, stamp := ← (col xs 2).toNat?, version := ← (col xs 3).toNat? }

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
    forkSource := col xs 19, supersededBy := col xs 20 }

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
    { widgetId := 111, rowId := "nav:cloud", kind := "nav", title := "Cloud agent", shortcut := "⌘2" },
    { widgetId := 112, rowId := "nav:machines", kind := "nav", title := "Machines", shortcut := "⌘3" },
    { widgetId := 113, rowId := "nav:inference", kind := "nav", title := "Inference", shortcut := "⌘4" },
    { widgetId := 114, rowId := "nav:resources", kind := "nav", title := "Resources", shortcut := "⌘6" },
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
    inboxItems := lines.filterMap (fun line => inboxItem (splitTab line))
    inboxAvailable := lines.any (·.startsWith "I\t")
    inboxEnabled := !lines.contains "I\tdisabled"
    missionCards := missions
    fleetMachines := machines, catalogLoading := true }

private inductive ReadKind where
  | roster | recover | catalog (revision : Nat) | providers
  | cloud (mission : String)
  | resources (range : String)
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
    | .roster => #["-I", "-c", transport ++ "\ntry: roster()\nexcept Exception: sys.exit(1)"]
    | .recover => #["-I", "-c", transport ++ "\nrecover_roster()"]
    | .nativeModels machine => #["-I", "-c", transport ++ "\nnative_models(*sys.argv[1:])", binding, machine]
    | .accountRoutes account provider action value => #["-I", "-c", transport ++ "\naccount_routes(*sys.argv[1:])", binding, account, provider, action, value]
    | .directories machine path => #["-I", "-c", transport ++ "\nlist_directories(*sys.argv[1:])", binding, machine, path]
    | .launchMachines admin harness => #["-I", "-c", transport ++ "\nlaunch_machines(*sys.argv[1:])", binding, if admin then "admin" else "member", harness]
    | .cloud mission => #["-I", "-c", transport ++ "\ncloud_inventory(*sys.argv[1:])", binding, mission]
    | .resources range => #["-I", "-c", transport ++ "\nresource_inventory(*sys.argv[1:])", binding, range]
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
          some (if st.initialRosterPending then .roster else .recover)
        else if st.missionMenu.any (·.page == .picker .machine) && st.launchMachines.isNone && !st.launchMachinesFailed then
          some (.launchMachines (st.fleetMachines.any (·.machineId == "core")) st.draftSettings.backend)
        else if st.missionMenu.any (fun m => m.page == .draftDirectory && m.directoryRows.isNone && !m.listingFailed) &&
            (!st.draftSettings.machine.isEmpty || st.fleetMachines.any (·.machineId == "core")) then
          let machine := if st.draftSettings.machine.isEmpty then "core" else st.draftSettings.machine
          some (.directories machine ((st.missionMenu.map (·.browsePath)).getD ""))
        else if st.screen == .cloud && st.cloudLines.isNone && !st.cloudFailed then some (.cloud st.cloudMission)
        else if st.screen == .resources && st.resourceRows.isNone && !st.resourceFailed then some (.resources st.resourceRange)
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
        return if st.initialRosterPending then some { st with initialRosterPending := false } else none
      if let .cloud _ := source.kind then
        if lines.head? != some "cloud" then return some { st with cloudFailed := true }
        let accounts := lines.filterMap fun line => match splitTab line with
          | ["P", provider, account, name] => some (provider, account, name)
          | _ => none
        let selected := st.cloudAccounts[st.cloudAccountIndex]?.bind fun (p, a, _) =>
          accounts.findIdx? fun (provider, account, _) => p == provider && a == account
        let changed := st.cloudMission.isEmpty && !st.cloudAccounts.isEmpty && selected.isNone
        return some { st with
          cloudLines := some (lines.filterMap fun line => (line.dropPrefix? "L\t").map (·.toString)), cloudPage := 0,
          cloudAccounts := accounts, cloudAccountIndex := selected.getD 0,
          cloudDraft := if changed then {} else st.cloudDraft, cloudAttempt := if changed then "" else st.cloudAttempt,
          cloudActions := lines.filterMap fun line => (line.dropPrefix? "A\t").map (·.toString) }
      if let .resources _ := source.kind then
        if lines.head? != some "resources" then return some { st with resourceFailed := true }
        let rows := lines.filterMap fun line => match splitTab line with
          | ["R", mission, title, usage] => some (⟨mission, title, usage⟩ : ResourceRow)
          | _ => none
        return some { st with resourceRows := some rows }
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

inductive LiveUpdate where
  | sample (roster : Option (List String)) (bubble : Option (String × String × String))
  | invalid

structure LiveSubscription where
  mission : String
  binding : String
  latest : Std.Mutex (Option LiveUpdate)
  stop : IO Unit

private def subscribe (mission binding : String) (tracked : List MissionSummaryCard) (notify : IO Unit) : IO LiveSubscription := do
  let child ← IO.Process.spawn {
    cmd := "python3", args := #["-I", "-c", transport ++ "\npoll(*sys.argv[1:])", mission, binding]
    stdin := .piped, stdout := .piped, stderr := .null }
  -- Bootstrap tracks validated IDs from both current and archived pages. Do not expose
  -- the roster in the process list; a new reader gets the current tracked set.
  try
    child.stdin.putStrLn (String.intercalate "," (tracked.map (·.missionId)))
    child.stdin.flush
  catch err =>
    try child.kill catch _ => pure ()
    discard child.wait
    throw err
  let latest ← Std.Mutex.new (none : Option LiveUpdate)
  let reader ← IO.asTask (prio := .dedicated) do
    try
      repeat
        let line ← child.stdout.getLine
        if !line.endsWith "\n" then break
        let kind :: keys :: rest := splitTab (line.dropEnd 1).toString | break
        if keys != "=" && !keys.startsWith "+" then break
        let encoded := (keys.drop 1).toString
        let roster := if keys == "=" then none else some (if encoded.isEmpty then [] else encoded.splitOn "\x1f")
        let bubble ← match kind, rest with
          | "B", [title,status,text] => pure (some (title,status,(text.replace "\x1e" "\n").replace "\x1f" "\t"))
          | "R", [] => pure none
          | _, _ => break
        latest.atomically (modify fun pending =>
          let previous := match pending with
            | some (.sample rows _) => rows
            | _ => none
          some (.sample (roster.orElse fun _ => previous) bubble))
        notify
    finally
      latest.atomically (set (some LiveUpdate.invalid))
      notify
  return { mission, binding, latest, stop := do
    try child.kill catch _ => pure ()
    discard child.wait
    discard (IO.wait reader) }

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
    | "N" => machines := machines.push (machineCard machines.size xs)
    | _ => continue
  let inboxItems := records.filterMap fun r => inboxItem (r.splitOn "\x1c")
  let inboxAvailable := records.any (·.startsWith "I\x1c")
  let inboxEnabled := if inboxAvailable then !records.contains "I\x1cdisabled" else st.inboxEnabled
  let inboxItems := if inboxAvailable then inboxItems else st.inboxItems
  let inboxIndex := (st.currentInboxItem.bind fun item => inboxItems.findIdx? (·.mission == item.mission)).getD
    (min st.inboxIndex (inboxItems.length - 1))
  let updated := { st with inboxItems, inboxEnabled, inboxIndex, inboxAvailable, missionCards := cards.toList, sidebarRows := rows.toList, fleetMachines := machines.toList }
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
      | .cloudCreate provider account project prompt attempt =>
        ("cloud-create", "", String.intercalate "\n" [attempt, provider, account, project, prompt])
      | .cloudSend mid text attempt => ("cloud-send", mid, attempt ++ "\n" ++ text)
      | .cloudCancel mid => ("cloud-cancel", mid, "")
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
      if (action == "cloud-send" || action == "cloud-create") && r.exitCode != 0 then
        return ({ st with cloudAttempt := r.stdout.trimAscii.toString, writeError := "Core did not confirm the request. Submit again to retry." }, some viewport)
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
        return (next, some viewport)
      | .providerPreference account enabled =>
        let providers := st.providers.map fun rows =>
          rows.map fun p => if p.id == account then { p with userEnabled := enabled } else p
        return ({ st with providers, nativeCatalog := none, catalogLoading := true, catalogRevision := st.catalogRevision + 1 }, some viewport)
      | .create =>
        let [id,title,status,machine,backend,model,effort,permissionMode,project] := splitTab (r.stdout.dropEnd 1).toString | throw (IO.userError "invalid mission")
        let wid := 1001 + 3 * (1 + (st.sidebarRows.foldl (fun n row => max n row.widgetId) 1000 - 1000) / 3)
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
                          missionCards := st.missionCards.map fun m => if m.missionId == mid then { m with status := "paused" } else m,
                          sidebarRows := st.sidebarRows.map fun row => if row.rowId == "mission:" ++ mid then { row with status := "paused" } else row }, some viewport)
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
        let status := if kind == "archive" then "acknowledged" else "paused"
        let cards := st.missionCards.filterMap fun m =>
          if !changed.contains m.missionId then some m
          else if remove then none else if kind == "move" then some { m with project } else some { m with status }
        let rows := st.sidebarRows.filterMap fun row =>
          if !changed.contains (row.rowId.drop 8).toString || row.kind != "mission" then some row
          else if remove then none else if kind == "move" then some row else some { row with status }
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
      | .cloudCreate .. =>
        let [_, mid] := r.stdout.trimAscii.toString.splitOn "\n" | throw (IO.userError "invalid cloud mission")
        return (st.openCloud mid, some viewport)
      | .cloudSend .. => return ({ st with cloudDraft := {}, cloudAttempt := "", cloudLines := none }, some viewport)
      | .cloudCancel .. => return ({ st with cloudLines := none }, some viewport)
      | .send .. => return ({ st with composer := { isRunning := st.composer.isRunning } }, some viewport)
      | .stop _ => return (st, some viewport)
    catch _ =>
      let message := if action == "inbox-read" then "Couldn't mark this item read. Check the Inbox and try again."
        else "Core did not confirm " ++ action
      return ({ st with writeError := message }, some viewport)
  let invalidate := ({ DesktopState.liveUnavailable with theme := st.theme, scale120 := scale }, some viewport)
  let target := if st.hasLiveConnection then some (st.openMission.getD "") else none
  if active.map (·.mission) != target || active.any (·.binding != st.connectionBinding) then
    closeLiveSubscription slot
    if let some mission := target then
      try slot.set (some (← subscribe mission st.connectionBinding st.missionCards notify)) catch _ => return invalidate
  let some sub ← slot.get | return (st, none)
  let some update ← sub.latest.atomically (modifyGet (fun v => (v, none))) | return (st, none)
  match update with
  | .invalid => closeLiveSubscription slot; return invalidate
  | .sample roster bubble =>
    let updated := roster.elim st (mergeRoster st)
    let changed := roster.isSome && (updated.missionCards != st.missionCards ||
      updated.inboxItems != st.inboxItems || updated.inboxEnabled != st.inboxEnabled || updated.inboxAvailable != st.inboxAvailable ||
      updated.sidebarRows != st.sidebarRows || updated.fleetMachines != st.fleetMachines)
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
    let some (title,status,text) := bubble | do
      -- No bubble (roster-only or malformed response): never discard other missions.
      let (next, damage) := applyLiveText scale viewport st sub.mission ""
      return (next, if changed then some viewport else damage)
    let (next, damage) := applyLiveText scale viewport st sub.mission text
    let some card := next.selectedCard | return invalidate
    if title == card.title && status == card.status then return (next, if changed then some viewport else damage)
    return ({ next with
      composer := { next.composer with isRunning := ({ card with status } : MissionSummaryCard).isRunning }
      missionCards := next.missionCards.map fun m => if m.missionId == sub.mission then { m with title, status } else m
      sidebarRows := next.sidebarRows.map fun r => if r.widgetId == card.widgetId then { r with title, status } else r }, some viewport)

end OrbDesktop
