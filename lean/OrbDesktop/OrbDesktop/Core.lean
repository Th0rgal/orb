import OrbDesktop.State
import Std.Sync.Mutex

namespace OrbDesktop

/-! Live desktop bootstrap.  The helper deliberately emits a small tab-separated
projection rather than passing credentials through the UI state.  `--headless`
golden paths never call this module and remain deterministic fixtures. -/

/-- Embedded connection-bound HTTP reader and writer. -/
private def transport : String := include_str "live_transport.py"

private def splitTab (line : String) : List String :=
  line.splitOn "\t"

private def col (xs : List String) (n : Nat) : String := xs.getD n ""

private def runProjection : IO (Option (List String)) := do
  let r ← IO.Process.output { cmd := "python3", args := #["-I", "-c", transport ++ "\ntry: roster()\nexcept Exception: sys.exit(1)"] }
  if r.exitCode != 0 then return none
  return some (r.stdout.splitOn "\n" |>.filter (fun x => !x.trimAscii.toString.isEmpty))

private def projectRow (idx : Nat) (xs : List String) : ChromeSidebarRow :=
  { widgetId := 1000 + 3 * idx, rowId := "project:" ++ col xs 1, kind := "project"
    title := col xs 2, subtitle := col xs 3 }

private def missionCard (idx : Nat) (xs : List String) : MissionSummaryCard :=
  { widgetId := 1001 + 3 * idx, missionId := col xs 1, title := col xs 2, project := col xs 3
    track := col xs 4, model := if (col xs 5).isEmpty then col xs 6 else col xs 5
    status := col xs 7, updatedLabel := if (col xs 8).isEmpty then col xs 9 else col xs 8
    summaryText := col xs 10 }

private def machineCard (idx : Nat) (xs : List String) : FleetMachineCard :=
  { widgetId := 1002 + 3 * idx, machineId := col xs 1, name := col xs 2
    roleLabel := if (col xs 3).isEmpty then col xs 4 else col xs 3
    cpuRamSpec := if (col xs 5).isEmpty then col xs 6 else col xs 5
    state := if (col xs 7).isEmpty then col xs 8 else col xs 7
    ttlLabel := col xs 9, costLabel := col xs 10, activeMissions := (col xs 11).toNat?.getD 0 }

def loadLiveState : IO (Option DesktopState) := do
  let some (header :: lines) ← (try runProjection catch _ => pure none) | return none
  let ["C", binding] := splitTab header | return none
  let ps := lines.filterMap (fun line => let xs := splitTab line; if col xs 0 == "P" then some xs else none)
  let ms := lines.filterMap (fun line => let xs := splitTab line; if col xs 0 == "M" then some xs else none)
  let ns := lines.filterMap (fun line => let xs := splitTab line; if col xs 0 == "N" then some xs else none)
  let projects := ps.toArray.mapIdx (fun i xs => projectRow i xs) |>.toList
  let missions := ms.toArray.mapIdx (fun i xs => missionCard i xs) |>.toList
  let machines := ns.toArray.mapIdx (fun i xs => machineCard i xs) |>.toList
  let missionRows : List ChromeSidebarRow := missions.map fun m =>
    { widgetId := m.widgetId, rowId := "mission:" ++ m.missionId, kind := "mission", title := m.title, status := m.status }
  let sidebar := [{ widgetId := 101, rowId := "nav:control", kind := "nav", title := "Control Center", selected := true },
    { widgetId := 109, rowId := "section:missions", kind := "section", title := "Missions" }] ++ missionRows ++
    [{ widgetId := 108, rowId := "section:projects", kind := "section", title := "Projects" }] ++ projects
  return some { DesktopState.liveUnavailable with
    screen := if missions.isEmpty then .controlEmpty else .controlPopulated
    syncCursor := { epoch := 0, seq := 0 }
    connectionBinding := binding
    stream := Orb.Stream.Coalescer.empty
    sidebarRows := sidebar
    missionCards := missions
    fleetMachines := machines }

inductive LiveUpdate where
  | sample (visible : List String) (bubble : Option (String × String × String))
  | invalid

structure LiveSubscription where
  mission : String
  binding : String
  latest : Std.Mutex (Option LiveUpdate)
  stop : IO Unit

private def subscribe (mission binding : String) (tracked : List MissionSummaryCard) : IO LiveSubscription := do
  let child ← IO.Process.spawn {
    cmd := "python3", args := #["-I", "-c", transport ++ "\npoll(*sys.argv[1:])", mission, binding]
    stdin := .piped, stdout := .piped, stderr := .null }
  -- Bootstrap tracks at most 200 validated ASCII mission IDs. Do not expose
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
    finally latest.atomically (set (some LiveUpdate.invalid))
  return { mission, binding, latest, stop := do
    try child.kill catch _ => pure ()
    discard child.wait
    discard (IO.wait reader) }

def closeLiveSubscription (slot : IO.Ref (Option LiveSubscription)) : IO Unit := do
  if let some sub ← slot.swap none then sub.stop

private def freshMessageId : IO String := do
  return (← IO.FS.readFile "/proc/sys/kernel/random/uuid").trimAscii.toString

/-- The window thread owns selection and damage. Each reader owns a fresh,
single-value mailbox, so a retired subscription cannot update a new mission. -/
def readLiveFrame (slot : IO.Ref (Option LiveSubscription)) (scale : Nat) (viewport : LeanUI.Rect)
    (st : DesktopState) : IO (DesktopState × LeanUI.Damage) := do
  let active ← slot.get
  if let some request := st.writeRequest then
    let st := { st with writeRequest := none, writeError := "" }
    let (action, mid, text) := match request with
      | .create => ("create", "", "")
      | .send mid text => ("send", mid, text)
      | .stop mid => ("stop", mid, "")
      | .archive mid => ("archive", mid, "")
    let key ← if action != "send" then pure "" else
      match st.unconfirmedSend with
      | some (id, draft) => if draft == text then pure id else freshMessageId
      | none => freshMessageId
    let st := if action == "send" then { st with unconfirmedSend := some (key, text) } else st
    try
      let r ← IO.Process.output { cmd := "python3", args := #["-I", "-c", transport ++ "\ntry: mutate(*sys.argv[1:])\nexcept Exception: sys.exit(1)", st.connectionBinding, action, mid, key] } (input? := some text)
      if action == "send" && r.exitCode == 2 then
        return ({ st with unconfirmedSend := none, writeError := "Mission busy — draft kept. Send again when idle." }, some viewport)
      if r.exitCode != 0 then throw (IO.userError "write failed")
      closeLiveSubscription slot
      match request with
      | .create =>
        let [id,title,status] := splitTab r.stdout.trimAscii.toString | throw (IO.userError "invalid mission")
        let wid := 1 + st.sidebarRows.foldl (fun n row => max n row.widgetId) 1000
        let card := { (default : MissionSummaryCard) with widgetId := wid, missionId := id, title, status }
        let row := { (default : ChromeSidebarRow) with widgetId := wid, rowId := "mission:" ++ id, kind := "mission", title, status }
        return (resetSelection { st with screen := .missionTranscript, missionCards := card :: st.missionCards, sidebarRows := row :: st.sidebarRows } (some card), some viewport)
      | .archive _ =>
        return (resetSelection { st with screen := .controlEmpty, missionCards := st.missionCards.filter (·.missionId != mid), sidebarRows := st.sidebarRows.filter (·.rowId != "mission:" ++ mid) } none, some viewport)
      | .send .. => return ({ st with unconfirmedSend := none, composer := { isRunning := st.composer.isRunning } }, some viewport)
      | .stop _ => return (st, some viewport)
    catch _ => return ({ st with writeError := if action == "send" then "Send unconfirmed — activate Send to retry" else "Core did not confirm " ++ action }, some viewport)
  let invalidate := ({ DesktopState.liveUnavailable with theme := st.theme, scale120 := scale }, some viewport)
  let target := if st.hasLiveConnection then some (st.openMission.getD "") else none
  if active.map (·.mission) != target || active.any (·.binding != st.connectionBinding) then
    closeLiveSubscription slot
    if let some mission := target then
      try slot.set (some (← subscribe mission st.connectionBinding st.missionCards)) catch _ => return invalidate
  let some sub ← slot.get | return (st, none)
  let some update ← sub.latest.atomically (modifyGet (fun v => (v, none))) | return (st, none)
  match update with
  | .invalid => closeLiveSubscription slot; return invalidate
  | .sample visible bubble =>
    let cards := st.missionCards.filter fun m => visible.contains ("M:" ++ m.missionId)
    let machines := st.fleetMachines.filter fun m => visible.contains ("N:" ++ m.machineId)
    let rows := st.sidebarRows.filter fun r =>
      if r.kind == "mission" then cards.any (·.widgetId == r.widgetId)
      else if r.kind == "project" then visible.contains ("P:" ++ (r.rowId.drop 8).toString) else true
    let pruned := cards.length != st.missionCards.length || machines.length != st.fleetMachines.length || rows.length != st.sidebarRows.length
    let st := { st with missionCards := cards, sidebarRows := rows, fleetMachines := machines }
    if st.openMission.isSome && st.selectedCard.isNone then
      closeLiveSubscription slot
      let (st, _) := stepDesktopEvent scale viewport st (.activate 101)
      return (st, some viewport)
    let some (title,status,text) := bubble | do
      -- No bubble (roster-only or malformed response): never discard other missions.
      let (next, damage) := applyLiveText scale viewport st sub.mission ""
      return (next, if pruned then some viewport else damage)
    let (next, damage) := applyLiveText scale viewport st sub.mission text
    let some card := next.selectedCard | return invalidate
    if title == card.title && status == card.status then return (next, if pruned then some viewport else damage)
    return ({ next with
      composer := { next.composer with isRunning := status == "active" || status == "running" }
      missionCards := next.missionCards.map fun m => if m.missionId == sub.mission then { m with title, status } else m
      sidebarRows := next.sidebarRows.map fun r => if r.widgetId == card.widgetId then { r with title, status } else r }, some viewport)

end OrbDesktop
