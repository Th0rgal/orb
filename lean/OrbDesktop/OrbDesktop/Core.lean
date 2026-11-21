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
    { widgetId := 112, rowId := "nav:machines", kind := "nav", title := "Machines", shortcut := "⌘3" },
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

private structure LiveRead where
  binding : String
  take : IO (Option (List String))
  stop : IO Unit

private def startLiveRead (binding : String) (initial : Bool) (notify : IO Unit) : IO LiveRead := do
  let args := if initial then #["-I", "-c", transport ++ "\ntry: roster()\nexcept Exception: sys.exit(1)"]
    else if binding.isEmpty then #["-I", "-c", transport ++ "\nrecover_roster()"]
    else #["-I", "-c", transport ++ "\ncatalog(sys.argv[1], json.loads(sys.argv[2]))", binding, modelCatalogRules]
  let child ← IO.Process.spawn { cmd := "python3", args, stdout := .piped, stderr := .null }
  let mailbox ← Std.Mutex.new (none : Option (List String))
  let reader ← IO.asTask (prio := .dedicated) do
    let out ← try child.stdout.readToEnd catch _ => pure ""
    mailbox.atomically (set (some (out.splitOn "\n")))
    notify
  return { binding, take := mailbox.atomically (modifyGet fun rows => (rows, none)), stop := do
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
      if current.any (·.binding != st.connectionBinding) then close
      if st.hasLiveConnection && !st.catalogLoading then return none
      let source ← match ← slot.get with
        | some r => pure r
        | none => do
          let r ← startLiveRead st.connectionBinding st.initialRosterPending notify
          slot.set (some r)
          pure r
      let some lines ← source.take | return none
      close
      if source.binding.isEmpty then
        if let some ready := liveStateFromProjection lines isDark st.scale120 then return some ready
        return if st.initialRosterPending then some { st with initialRosterPending := false } else none
      let models := lines.filterMap fun line =>
        match splitTab line with
        | ["H", backend, harnessName, model, modelName] =>
          some ({ backend, harnessName, model, modelName } : CatalogModel)
        | _ => none
      return some { st with catalog := models, catalogLoading := false }
  finally close

inductive LiveUpdate where
  | sample (visible : List String) (bubble : Option (String × String × String))
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
        let visible := if keys.isEmpty then [] else keys.splitOn "\x1f"
        let bubble ← match kind, rest with
          | "B", [title,status,text] => pure (some (title,status,(text.replace "\x1e" "\n").replace "\x1f" "\t"))
          | "R", [] => pure none
          | _, _ => break
        latest.atomically (set (some (LiveUpdate.sample visible bubble)))
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

/-- The window thread owns selection and damage. Each reader owns a fresh,
single-value mailbox, so a retired subscription cannot update a new mission. -/
def readLiveFrame (slot : IO.Ref (Option LiveSubscription)) (scale : Nat) (viewport : LeanUI.Rect)
    (st : DesktopState) (notify : IO Unit := pure ()) : IO (DesktopState × LeanUI.Damage) := do
  let active ← slot.get
  if let some request := st.writeRequest then
    let st := { st with writeRequest := none, writeError := "" }
    let encode := fun (v : LaunchSettings) => String.intercalate "\t" [v.machine, v.backend, v.model, v.effort, v.permission]
    let (action, mid, text) := match request with
      | .create => ("create", "", encode st.draftSettings ++ "\t" ++ st.draftProject ++ "\t" ++ st.composer.text)
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
      let r ← IO.Process.output { cmd := "python3", args := #["-I", "-c", transport ++ "\ntry: mutate(*sys.argv[1:])\nexcept MissionNotIdle: sys.exit(2)\nexcept Exception: sys.exit(1)", st.connectionBinding, action, mid] } (input? := some text)
      if action == "archive" && r.exitCode == 2 then
        return ({ st with writeError := "Stop or finish this agent before archiving it." }, some viewport)
      if r.exitCode != 0 then throw (IO.userError "write failed")
      closeLiveSubscription slot
      match request with
      | .create =>
        let [id,title,status,machine,backend,model,effort,permissionMode,project] := splitTab (r.stdout.dropEnd 1).toString | throw (IO.userError "invalid mission")
        let wid := 1 + st.sidebarRows.foldl (fun n row => max n row.widgetId) 1000
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
      | .send .. => return ({ st with composer := { isRunning := st.composer.isRunning } }, some viewport)
      | .stop _ => return (st, some viewport)
    catch _ => return ({ st with writeError := "Core did not confirm " ++ action }, some viewport)
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
  | .sample visible bubble =>
    let cards := st.missionCards.filter fun m => visible.contains ("M:" ++ m.missionId)
    let fleetRows := visible.filterMap fun key =>
      if key.startsWith "N:" then some ("N" :: (key.drop 2).toString.splitOn "\x1c") else none
    let machines := fleetRows.toArray.mapIdx (fun i xs => machineCard i xs) |>.toList
    let rows := st.sidebarRows.filter fun r =>
      if r.kind == "mission" then cards.any (·.widgetId == r.widgetId)
      else if r.kind == "project" then visible.contains ("P:" ++ (r.rowId.drop 8).toString) else true
    let statuses := visible.foldl (fun (acc : Std.HashMap String String) key =>
      match key.splitOn ":" with
      | ["S", id, status] => acc.insert id status
      | _ => acc) {}
    let changed := cards.any fun c => (statuses.get? c.missionId).any (· != c.status)
    let cards := if changed then cards.map (fun c =>
      { c with status := (statuses.get? c.missionId).getD c.status }) else cards
    let rows := if changed then rows.map (fun r =>
      if r.kind == "mission" then { r with status := (statuses.get? ((r.rowId.drop 8).toString)).getD r.status }
      else r) else rows
    let pruned := cards.length != st.missionCards.length || machines != st.fleetMachines || rows.length != st.sidebarRows.length
    let menu := st.missionMenu.bind fun m =>
      if (m.mission.isEmpty || cards.any (·.missionId == m.mission)) && m.targets.all (fun id => cards.any (·.missionId == id))
      then some m else none
    let st := { st with
      missionCards := cards, sidebarRows := rows, fleetMachines := machines, missionMenu := menu,
      multiRows := st.multiRows.filter fun id => rows.any (·.rowId == id) }
    if st.openMission.isSome && st.selectedCard.isNone then
      closeLiveSubscription slot
      let (st, _) := stepDesktopEvent scale viewport st (.activate 101)
      return (st, some viewport)
    let some (title,status,text) := bubble | do
      -- No bubble (roster-only or malformed response): never discard other missions.
      let (next, damage) := applyLiveText scale viewport st sub.mission ""
      return (next, if pruned || changed then some viewport else damage)
    let (next, damage) := applyLiveText scale viewport st sub.mission text
    let some card := next.selectedCard | return invalidate
    if title == card.title && status == card.status then return (next, if pruned || changed then some viewport else damage)
    return ({ next with
      composer := { next.composer with isRunning := status == "active" || status == "running" }
      missionCards := next.missionCards.map fun m => if m.missionId == sub.mission then { m with title, status } else m
      sidebarRows := next.sidebarRows.map fun r => if r.widgetId == card.widgetId then { r with title, status } else r }, some viewport)

end OrbDesktop
