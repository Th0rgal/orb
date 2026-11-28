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
  let account := splitTab ((lines.find? (·.startsWith "A\t")).getD "")
  let sidebar := [{ widgetId := 101, rowId := "nav:new", kind := "nav", title := "New Agent", shortcut := "⌘N", selected := true },
    { widgetId := 102, rowId := "nav:inbox", kind := "nav", title := "Inbox", shortcut := "⌘I" },
    { widgetId := 111, rowId := "nav:cloud", kind := "nav", title := "Cloud agent", shortcut := "⌘2" },
    { widgetId := 112, rowId := "nav:machines", kind := "nav", title := "Machines", shortcut := "⌘3" },
    { widgetId := 113, rowId := "nav:inference", kind := "nav", title := "Inference", shortcut := "⌘4" },
    { widgetId := 114, rowId := "nav:resources", kind := "nav", title := "Resources", shortcut := "⌘6" },
    { widgetId := 109, rowId := "section:missions", kind := "section", title := "Missions" }] ++ missionRows ++
    [{ widgetId := 108, rowId := "section:projects", kind := "section", title := "Projects" }] ++ projects ++ [settingsFooter]
  return { DesktopState.liveUnavailable isDark scale120 with
    screen := if missions.isEmpty then .controlEmpty else .controlPopulated
    syncCursor := { epoch := 0, seq := 0 }
    accountEndpoint := col account 1
    accountUsername := col account 2
    connectionBinding := binding
    stream := Orb.Stream.Coalescer.empty
    expandedProjects := match projects with
      | [onlyProject] => [(onlyProject.rowId.drop 8).toString]
      | _ => []
    sidebarRows := sidebar
    missionCards := missions
    fleetMachines := machines, catalogLoading := true }

private inductive ReadKind where
  | roster (previous : String) | account | catalog (revision : Nat) | providers
  | cloud (mission : String)
  | resources (range : String)
  | nativeModels (machine : String)
  | accountRoutes (account provider action value : String) (poll : Bool := false)
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
    | .account => #["-I", "-c", transport ++ "\nobserve_account(sys.argv[1])", binding]
    | .roster previous => #["-I", "-c", transport ++ "\nrecover_roster(sys.argv[1])", previous]
    | .nativeModels machine => #["-I", "-c", transport ++ "\nnative_models(*sys.argv[1:])", binding, machine]
    | .accountRoutes account provider action value poll =>
      #["-I", "-c", transport ++ "\naccount_routes(*sys.argv[1:])", binding, account, provider, action, value, if poll then "poll" else ""]
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
          some (.roster (if st.initialRosterPending then "" else st.connectionIssue.code))
        else if st.screen == .settingsGeneral then some .account
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
          if st.screen == .inference && !page.failed && (page.options.isNone || page.pending.isSome || page.polling) then
            let poll := page.options.isSome && page.pending.isNone && page.polling
            some (.accountRoutes page.account.id page.account.providerType ((page.pending.map (·.action)).getD "") ((page.pending.map (·.value)).getD "") poll)
          else if st.catalogLoading then some (.catalog st.catalogRevision) else none
        else if st.catalogLoading then some (.catalog st.catalogRevision)
        else (nativeCatalogRequest st).map ReadKind.nativeModels
      -- Navigation may cancel a stale read. A submitted shared account update
      -- must settle before another page fetches the account's saved route.
      if let some source := current then
        if let .accountRoutes _ _ action _ _ := source.kind then
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
        if let some ready := liveStateFromProjection lines isDark st.scale120 then
          return some (if st.screen == .settingsGeneral then
            { ready with screen := .settingsGeneral, sidebarRows := ready.sidebarRows.map fun r => { r with selected := r.widgetId == 103 } } else ready)
        let issue : ConnectionIssue := match lines.head? with
          | some "F\tmissing" => .missing
          | some "F\tsignin" => .signin
          | some "F\tdenied" => .denied
          | some "F\tinvalid" => .invalid
          | _ => .unavailable
        return if st.initialRosterPending || issue != st.connectionIssue then
          some { st with initialRosterPending := false, connectionIssue := issue } else none
      if source.kind == .account then
        let ["A", endpoint, username] := splitTab (lines.head?.getD "") |
          return some { DesktopState.liveUnavailable isDark st.scale120 with
            theme := st.theme, screen := .settingsGeneral, initialRosterPending := true }
        slot.set (some (← startLiveRead st.connectionBinding .account notify))
        return if st.accountUsername == username && st.accountEndpoint == endpoint then none
          else some { st with accountEndpoint := endpoint, accountUsername := username }
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
        let flows := lines.filterMap fun line => match splitTab line with
          | ["F", lens, source, target, value, deg] =>
            some ({ lens, source, target, value, degraded := deg == "1" } : ResourceFlowLink)
          | _ => none
        let summary := lines.findSome? fun line => match splitTab line with
          | ["S", throttled, bTok, actV, totV] =>
            some ({ throttled429 := throttled.toNat?.getD 0, bTokPerH := bTok, activeVcpu := actV, totalVcpu := totV } : ResourceSummary)
          | _ => none
        return some { st with resourceRows := some rows, resourceFlows := flows, resourceSummary := summary }
      if let .nativeModels machine := source.kind then
        let ok := lines.head? == some "native-models"
        let menu := st.missionMenu.map fun m => { m with nativeCatalogResult := some ok }
        if !ok then return some { st with missionMenu := menu }
        let rows := lines.filterMap fun line => match splitTab line with
          | ["N", id, name] => some ({ backend := "antigravity", harnessName := "Antigravity CLI", model := id, modelName := name } : CatalogModel)
          | _ => none
        return some (applyNativeCatalog { st with missionMenu := menu } machine rows)
      if let .accountRoutes account provider _ _ isPoll := source.kind then
        let some page := st.accountRoutePage | return none
        if page.account.id != account then return none
        let header := splitTab (lines.head?.getD "")
        let status := col header 0
        let shouldPoll := col header 1 == "poll"
        if status != "routes" && status != "unconfirmed" then
          return some { st with accountRoutePage := some { page with failed := true, pending := none, polling := false } }
        let rows := lines.filterMap fun line => match splitTab line with
          | ["D", action, value, title, detail] => some ({ action, value, title, detail } : AccountRouteOption)
          | _ => none
        let changed := page.pending.isSome
        let writeError := if status == "unconfirmed" then "Core could not confirm the change. Check the current setting."
          else if isPoll then st.writeError else ""
        if shouldPoll then
          slot.set (some (← startLiveRead st.connectionBinding (.accountRoutes account provider "" "" true) notify))
        let nextPage := { page with options := some rows, pending := none, polling := shouldPoll }
        if !changed && page == nextPage && st.writeError == writeError then return none
        return some { st with accountRoutePage := some nextPage
                              catalogLoading := st.catalogLoading || changed
                              catalogRevision := st.catalogRevision + (if changed then 1 else 0)
                              writeError }
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
        let canAdmin := match lines.findSome? fun line => match splitTab line with
          | ["P", "admin", flag] => some (flag == "1")
          | _ => none with
          | some v => v
          | none => st.providerCanAdmin
        let healthMap : List (String × String × Nat × String) := lines.filterMap fun line =>
          match splitTab line with
          | ["H", aid, state, cd, detail] => some (aid, state, cd.toNat?.getD 0, detail)
          | _ => none
        let rows := lines.filterMap fun line =>
          match splitTab line with
          | ["A", id, name, category, personal, globalFlag, providerType] =>
            let h := healthMap.find? (·.1 == id)
            let (hState, hCd, hDetail) := match h with
              | some (_, hs, cd, det) => (hs, cd, det)
              | none => ("", 0, "")
            some ({
              id, name, category, providerType,
              userEnabled := personal == "1",
              globallyEnabled := globalFlag == "1",
              healthState := hState,
              cooldownSecs := hCd,
              healthDetail := hDetail
            } : ProviderAccount)
          | _ => none
        let chainsLoaded := lines.any (· == "CS\t1")
        let chains := if chainsLoaded then
            lines.filterMap fun line =>
              match splitTab line with
              | ["C", cid, cname, isDef, summary] =>
                some ({ id := cid, name := cname, isDefault := isDef == "1", entriesSummary := summary } : RoutingChainSummary)
              | _ => none
          else st.routingChains
        return some { st with providers := some rows, providerReadFailed := false, providerCanAdmin := canAdmin, routingChains := chains }
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

inductive OlderHistoryUpdate where
  | page (requestedCursor : Int) (batch : HistoryBatch)
  | failed (requestedCursor : Int)

inductive LiveUpdate where
  | sample (roster : Option (List String)) (bubble : Option BubbleUpdate)
      (history : Option HistoryBatch) (older : Option OlderHistoryUpdate)
  | invalid

structure LiveSubscription where
  projects : List String
  mission : String
  binding : String
  latest : Std.Mutex (Option LiveUpdate)
  lastBubble : IO.Ref (Option BubbleUpdate)
  olderFetch : IO.Ref (Option (Int × IO Unit))
  stop : IO Unit

private def parseHistoryTurnKind : String → HistoryTurnKind
  | "p" => .plainAssistant
  | "c" => .unmatchedCanonical
  | _ => .other

private def parseHistoryEntries (packed : String) : List (String × String × HistoryTurnKind) :=
  if packed.isEmpty then []
  else (packed.splitOn "\x1d").filterMap fun raw =>
    match raw.splitOn "\x1c" with
    | [tid, kindStr, body] =>
      let turn := (body.replace "\x1e" "\n").replace "\x1f" "\t"
      if turn.isEmpty then none else some (tid, turn, parseHistoryTurnKind kindStr)
    | [tid, body] =>
      let turn := (body.replace "\x1e" "\n").replace "\x1f" "\t"
      if turn.isEmpty then none else some (tid, turn, .other)
    | _ =>
      let turn := (raw.replace "\x1e" "\n").replace "\x1f" "\t"
      if turn.isEmpty then none else some ("", turn, .other)

private def parseHistoryBatch (hasMoreStr cursorStr packed : String) : HistoryBatch :=
  let nextCursor := cursorStr.toInt?
  let hasMore := hasMoreStr == "1" && nextCursor.isSome
  let parsed := parseHistoryEntries packed
  { turns := parsed.map (fun (tid, turn, _) => (tid, turn))
    turnKinds := parsed.map (fun (_, _, kind) => kind)
    hasMore
    nextCursor := if hasMore then nextCursor else none }

private def readSample (line : String) : Option LiveUpdate := do
  match splitTab line with
  | ["R", keys] =>
    guard (keys.startsWith "+")
    let encoded := (keys.drop 1).toString
    return .sample (some (if encoded.isEmpty then [] else encoded.splitOn "\x1f")) none none none
  | ["B", title, status, text] =>
    return .sample none (some (.text title status ((text.replace "\x1e" "\n").replace "\x1f" "\t"))) none none
  -- One bounded atomic bootstrap message, oldest first (cold-open initial window + paging cursor).
  | ["HS", hasMoreStr, cursorStr, packed] =>
    return .sample none none (some (parseHistoryBatch hasMoreStr cursorStr packed)) none
  | ["HS", packed] =>
    let parsed := parseHistoryEntries packed
    return .sample none none (some {
      turns := parsed.map (fun (tid, turn, _) => (tid, turn))
      turnKinds := parsed.map (fun (_, _, kind) => kind) }) none
  -- One on-demand older history page, oldest first (originating cursor stamped by `startOlderFetch`).
  | ["HO", hasMoreStr, cursorStr, packed] =>
    return .sample none none none (some (.page 0 (parseHistoryBatch hasMoreStr cursorStr packed)))
  | ["HE"] => return .sample none none none (some (.failed 0))
  | ["X"] => return .sample none (some .unavailable) none none
  | ["D"] => return .sample none (some .revoked) none none
  | _ => none

private def stampOlderCursor (cursor : Int) : OlderHistoryUpdate → OlderHistoryUpdate
  | .page _ batch => .page cursor batch
  | .failed _ => .failed cursor

private def mergeLiveUpdate (previous : Option LiveUpdate) (rows : Option (List String))
    (bubble : Option BubbleUpdate) (history : Option HistoryBatch) (older : Option OlderHistoryUpdate) :
    Option LiveUpdate :=
  match previous with
  | some .invalid => previous
  | some (.sample _ (some .revoked) _ _) => previous
  | some (.sample oldRows oldBubble oldHistory oldOlder) =>
    some (.sample (rows.orElse fun _ => oldRows) (bubble.orElse fun _ => oldBubble)
      (history.orElse fun _ => oldHistory) (older.orElse fun _ => oldOlder))
  | none => some (.sample rows bubble history older)

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
        let some (.sample rows bubble history older) := readSample (line.dropEnd 1).toString | break
        if !line.endsWith "\n" then break
        latest.atomically (modify fun previous => mergeLiveUpdate previous rows bubble history older)
        notify
        if let some .revoked := bubble then return
    catch _ => pure ()
    latest.atomically (set (some LiveUpdate.invalid))
    notify
  return do
    try child.kill catch _ => pure ()
    discard child.wait
    discard (IO.wait reader)

/-- One-shot background fetch for an on-demand older transcript page. A 401 or
    session rotation exits without a valid frame and invalidates the session;
    403/404 emits `D` (revoked); transient errors emit `HE` so the cursor stays retryable. -/
private def startOlderFetch (mission binding : String) (cursor : Int)
    (latest : Std.Mutex (Option LiveUpdate)) (notify : IO Unit) : IO (IO Unit) := do
  let args := #["-I", "-c", transport ++ "\nfetch_older_turns(*sys.argv[1:])",
    mission, binding, toString cursor]
  let child ← IO.Process.spawn { cmd := "python3", args, stdin := .null, stdout := .piped, stderr := .null }
  let cancelled ← IO.mkRef false
  let reader ← IO.asTask (prio := .dedicated) do
    try
      let line ← child.stdout.getLine
      if (← cancelled.get) then return
      if line.endsWith "\n" then
        if let some (.sample rows bubble history older) := readSample (line.dropEnd 1).toString then
          if bubble.isSome || older.isSome then
            let stamped := older.map (stampOlderCursor cursor)
            latest.atomically (modify fun previous => mergeLiveUpdate previous rows bubble history stamped)
            notify
            return
    catch _ => pure ()
    unless (← cancelled.get) do
      latest.atomically (set (some LiveUpdate.invalid))
      notify
  return do
    cancelled.set true
    try child.kill catch _ => pure ()
    discard child.wait
    discard (IO.wait reader)

private def subscribe (mission binding : String) (tracked : List MissionSummaryCard) (projects : List String)
    (notify : IO Unit) : IO LiveSubscription := do
  let latest ← Std.Mutex.new (none : Option LiveUpdate)
  let olderFetch ← IO.mkRef (none : Option (Int × IO Unit))
  let rosterArgs := #["-I", "-c", transport ++ "\npoll(sys.argv[1], sys.argv[2], rules=json.loads(sys.argv[3]))",
    mission, binding, projectHistoryRules]
  let input := String.intercalate "," (tracked.map (·.missionId)) ++ "\n" ++ String.intercalate "\t" projects ++ "\n"
  let stopRoster ← liveReader rosterArgs input latest notify
  let stop ← try
    if mission.isEmpty then pure stopRoster else do
      let stopBubble ← liveReader #["-I", "-c", transport ++ "\npoll_bubble(*sys.argv[1:])", mission, binding] "" latest notify
      pure (do
        if let some (_, stopOlder) ← olderFetch.swap none then stopOlder
        stopBubble
        stopRoster)
  catch err =>
    stopRoster
    throw err
  let lastBubble ← IO.mkRef none
  return { mission, binding, projects, latest, lastBubble, olderFetch, stop }

def closeLiveSubscription (slot : IO.Ref (Option LiveSubscription)) : IO Unit := do
  if let some sub ← slot.swap none then sub.stop

/-- Reconcile the latest authorized page with the current rows. Widget IDs stay
stable across reordering so an open menu continues to target the same mission. -/
private def mergeRoster (st : DesktopState) (records : List String) : DesktopState := Id.run do
  let oldRows := Std.HashMap.ofList (st.sidebarRows.map fun row => (row.rowId, row))
  let oldCards := Std.HashMap.ofList (st.missionCards.map fun card => (card.missionId, card))
  let mut idx := 1 + (st.sidebarRows.foldl (fun n row => max n row.widgetId) 1000 - 1000) / 3
  let projectOnly := records.head? == some "partial-projects"
  let incoming := Std.HashSet.ofList (if !projectOnly then [] else records.filterMap fun record =>
    match record.splitOn "\x1c" with
    | "M" :: id :: _ => some id
    | _ => none)
  let mut cards := if projectOnly then (st.missionCards.filter fun card => !incoming.contains card.missionId).toArray else #[]
  let mut rows := (st.sidebarRows.filter fun row =>
    if projectOnly then row.kind != "mission" || !incoming.contains (row.rowId.drop 8).toString
    else row.kind != "project" && row.kind != "mission").toArray
  let mut machines := if projectOnly then st.fleetMachines.toArray else #[]
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
  if !projectOnly then
    let projects := Std.HashSet.ofList (rows.toList.filterMap fun row =>
      if row.kind == "project" then some (row.rowId.drop 8).toString else none)
    memberships := memberships.filter fun entry => projects.contains entry.1
  let inboxItems := records.filterMap fun r => inboxItem (r.splitOn "\x1c")
  -- An unfinished project or ancestor window keeps the last complete badge and items.
  let refreshing := records.contains "I\x1crefreshing" || records.head? == some "partial-projects"
  let finished := records.contains "I\x1cenabled" || records.contains "I\x1cdisabled"
  let inboxAvailable := finished || (refreshing && st.inboxAvailable)
  let inboxEnabled := if finished then !records.contains "I\x1cdisabled" else st.inboxEnabled
  let inboxItems := if finished then inboxItems else st.inboxItems
  let inboxIndex := (st.currentInboxItem.bind fun item => inboxItems.findIdx? (·.mission == item.mission)).getD
    (min st.inboxIndex (inboxItems.length - 1))
  let updated := { st with
    inboxItems, inboxEnabled, inboxIndex, projectMemberships := memberships
    inboxAvailable := if projectOnly then st.inboxAvailable else inboxAvailable
    missionCards := cards.toList, sidebarRows := rows.toList, fleetMachines := machines.toList }
  let some selected := updated.selectedCard | return updated
  return { updated with composer := { updated.composer with isRunning := selected.isRunning } }

/-- The window thread owns selection and damage. Each reader owns a fresh,
single-value mailbox, so a retired subscription cannot update a new mission. -/
def readLiveFrame (slot : IO.Ref (Option LiveSubscription)) (scale : Nat) (viewport : LeanUI.Rect)
    (st : DesktopState) (notify : IO Unit := pure ())
    (logicalSubSize? : Option (LeanUI.SubPx × LeanUI.SubPx) := none) : IO (DesktopState × LeanUI.Damage) := do
  if st.openAccountForm then
    let st := { st with openAccountForm := false, writeError := "" }
    try
      let launcher := (← IO.getEnv "ORB_ACCOUNT_LAUNCHER").getD "orb-desktop"
      let child ← IO.Process.spawn {
        cmd := launcher, args := #["--webkit", "--account-settings"]
        stdin := .null, stdout := .null, stderr := .null }
      discard <| IO.asTask (prio := .dedicated) (discard child.wait : IO Unit)
      return (st, some viewport)
    catch _ => return ({ st with writeError := "Could not open the account form." }, some viewport)
  let active ← slot.get
  if let some request := st.writeRequest then
    let st := { st with writeRequest := none, writeError := "" }
    let encode := fun (v : LaunchSettings) => String.intercalate "\t" [v.machine, v.backend, v.model, v.effort, v.permission]
    let (action, mid, text) := match request with
      | .inboxRead item _ => ("inbox-read", item.mission, s!"{item.stamp} {item.version}")
      | .providerPreference account enabled => (if enabled then "use-provider" else "skip-provider", account, "")
      | .providerReorder ids => ("reorder-providers", "", String.intercalate "\n" ids)
      | .providerClearHealth account => ("clear-provider-health", account, "")
      | .chainSetDefault chainId => ("set-default-chain", chainId, "")
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
    let freshKey := do return (← IO.FS.readFile "/proc/sys/kernel/random/uuid").trimAscii.toString
    let key ← if action != "send" then pure "" else
      match st.unconfirmedSend with
      | some (id, draft) => if draft == text then pure id else freshKey
      | none => freshKey
    let st := if action == "send" then { st with unconfirmedSend := some (key, text) } else st
    try
      let r ← IO.Process.output { cmd := "python3", args := #["-I", "-c", transport ++ "\nsys.exit(run_mutation(*sys.argv[1:]))", st.connectionBinding, action, mid, key] } (input? := some text)
      if action == "send" && r.exitCode == 2 then
        return ({ st with unconfirmedSend := none, writeError := "Mission busy — draft kept. Send again when idle." }, some viewport)
      if action == "archive" && r.exitCode == 2 then
        return ({ st with writeError := "Stop or finish this agent before archiving it." }, some viewport)
      if r.exitCode == 3 then
        return ({ st with writeError := "Choose a Goal-capable harness or remove /goal." }, some viewport)
      if r.exitCode == 4 then
        return ({ st with unconfirmedSend := none, writeError := "Start a new Goal mission or remove /goal." }, some viewport)
      if r.exitCode == 5 then
        return ({ st with writeError := "Choose an available remote machine for this mission." }, some viewport)
      if (action == "cloud-send" || action == "cloud-create") && r.exitCode != 0 then
        return ({ st with cloudAttempt := r.stdout.trimAscii.toString, writeError := "Core did not confirm the request. Submit again to retry." }, some viewport)
      if r.exitCode != 0 then throw (IO.userError "write failed")
      let st ← match request with
        | .providerPreference .. | .providerReorder .. | .providerClearHealth .. | .chainSetDefault .. => pure st
        | _ => do
          closeLiveSubscription slot
          pure { st with historyLoading := false }
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
      | .providerReorder _ | .providerClearHealth _ | .chainSetDefault _ =>
        return ({ st with providers := none, providerReadFailed := false, nativeCatalog := none, catalogLoading := true, catalogRevision := st.catalogRevision + 1 }, some viewport)
      | .create =>
        let [id,title,status,machine,backend,model,effort,permissionMode,project] := splitTab (r.stdout.dropEnd 1).toString | throw (IO.userError "invalid mission")
        let wid := nextMissionWidget st
        let card := { (default : MissionSummaryCard) with widgetId := wid, missionId := id, title, status, machine, backend, model, effort, permissionMode, project }
        let row := { (default : ChromeSidebarRow) with widgetId := wid, rowId := "mission:" ++ id, kind := "mission", title, status }
        let base := pushNavScreen { st with missionCards := card :: st.missionCards, sidebarRows := row :: st.sidebarRows } .missionTranscript (some id)
        return (resetSelection base (some card), some viewport)
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
      | .cloudCreate .. =>
        let [_, mid] := r.stdout.trimAscii.toString.splitOn "\n" | throw (IO.userError "invalid cloud mission")
        return (st.openCloud mid, some viewport)
      | .cloudSend .. => return ({ st with cloudDraft := {}, cloudAttempt := "", cloudLines := none, imeResetGen := st.imeResetGen + 1 }, some viewport)
      | .cloudCancel .. => return ({ st with cloudLines := none }, some viewport)
      | .send .. => return ({ st with unconfirmedSend := none, scroll := st.scroll.pinBottom, composer := { isRunning := st.composer.isRunning }, imeResetGen := st.imeResetGen + 1, attachCount := 0 }, some viewport)
      | .stop _ => return (st, some viewport)
    catch _ =>
      let message := if action == "inbox-read" then "Couldn't mark this item read. Check the Inbox and try again."
        else if action == "send" then "Send unconfirmed — activate Send to retry"
        else "Core did not confirm " ++ action
      return ({ st with writeError := message }, some viewport)
  let invalidate := ({ DesktopState.liveUnavailable with
    theme := st.theme, scale120 := scale, initialRosterPending := true
    screen := if st.screen == .settingsGeneral then .settingsGeneral else .controlEmpty }, some viewport)
  let target := if st.hasLiveConnection then some (st.openMission.getD "") else none
  if active.map (·.mission) != target || active.any (fun sub => sub.binding != st.connectionBinding || sub.projects != st.expandedProjects) then
    closeLiveSubscription slot
    if let some mission := target then
      try slot.set (some (← subscribe mission st.connectionBinding st.missionCards st.expandedProjects notify)) catch _ => return invalidate
  let some sub ← slot.get | return (st, none)
  let (st, startDamage) ← do
    if st.historyLoading && st.openMission == some sub.mission then
      if st.historyHasMore then
        if let some cursor := st.historyNextCursor then
          if (← sub.olderFetch.get).isNone then
            try
              let stopOlder ← startOlderFetch sub.mission sub.binding cursor sub.latest notify
              sub.olderFetch.set (some (cursor, stopOlder))
              pure (st, none)
            catch _ =>
              pure ({ st with historyLoading := false, historyLoadError := true },
                some (transcriptDamageRect scale viewport st.sidebarWidth))
          else pure (st, none)
        else
          pure ({ st with historyLoading := false },
            some (transcriptDamageRect scale viewport st.sidebarWidth))
      else
        pure ({ st with historyLoading := false },
          some (transcriptDamageRect scale viewport st.sidebarWidth))
    else pure (st, none)
  let some update ← sub.latest.atomically (modifyGet (fun v => (v, none))) | return (st, startDamage)
  match update with
  | .invalid => closeLiveSubscription slot; return invalidate
  | .sample roster bubble history older =>
    let isUnavailable := match bubble with | some .unavailable => true | _ => false
    -- Retire any in-flight older-page fetch when its result arrives or access is lost.
    -- A tail-only recovery-merge `HS` keeps an in-flight older fetch alive if its cursor still matches.
    if older.isSome || isUnavailable then
      if let some (_, stopOlder) ← sub.olderFetch.swap none then stopOlder
    -- The roster can finish after a newer transcript read. Keep the selected
    -- conversation's title, status and text together across that arrival.
    -- A fresh `/open` (`HS`) precedes an incoming `B` frame; if `HS` is drained
    -- before `B` arrives, drop any pre-recovery retained bubble so stale text
    -- cannot re-populate `st.stream` and duplicate a turn on the empty `B`.
    if bubble.isSome then sub.lastBubble.set bubble
    else if history.isSome then sub.lastBubble.set none
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
      -- Drop the retained reply and discard any stale coalesced older page;
      -- access loss clears the transcript rather than archiving or prepending.
      sub.lastBubble.set none
      let (next, damage) :=
        if st.liveTurns.isEmpty && (streamedText st).isEmpty && !st.showsHistoryBanner then (st, none)
        else (clearLiveTranscript st, some (transcriptDamageRect scale viewport st.sidebarWidth))
      return (next, startDamage.orElse (fun _ => if changed then some viewport else damage))
    -- Cold open / recovery: the persisted timeline populates or merges completed
    -- turns before the bubble frame is applied to the same state.
    let (st, histDamage, historyReplaced) := match history with
      | some batch => applyHistoryBatchEx scale viewport st sub.mission batch
      | none => (st, none, false)
    if historyReplaced then
      if let some (_, stopOlder) ← sub.olderFetch.swap none then stopOlder
    let (st, olderDamage) := match older with
      | some (.page reqCursor batch) =>
        if historyReplaced then (st, none)
        else applyOlderHistoryBatch scale viewport st sub.mission batch (some reqCursor) logicalSubSize?
      | some (.failed reqCursor) =>
        if historyReplaced then (st, none)
        else if st.openMission == some sub.mission && st.historyHasMore && st.historyNextCursor == some reqCursor then
          ({ st with historyLoading := false, historyLoadError := true },
           some (transcriptDamageRect scale viewport st.sidebarWidth))
        else (st, none)
      | none => (st, none)
    let pageDamage := startDamage.orElse fun _ => histDamage.orElse fun _ => olderDamage
    let some (.text title status text) := bubble | return (st, pageDamage.orElse (fun _ => if changed then some viewport else none))
    let (next, damage) := applyLiveText scale viewport st sub.mission text
    let some card := next.selectedCard | return invalidate
    if title == card.title && status == card.status then
      return (next, pageDamage.orElse (fun _ => if changed then some viewport else damage))
    return ({ next with
      composer := { next.composer with isRunning := ({ card with status } : MissionSummaryCard).isRunning }
      missionCards := next.missionCards.map fun m => if m.missionId == sub.mission then { m with title, status } else m
      sidebarRows := next.sidebarRows.map fun r => if r.widgetId == card.widgetId then { r with title, status } else r }, some viewport)

end OrbDesktop
