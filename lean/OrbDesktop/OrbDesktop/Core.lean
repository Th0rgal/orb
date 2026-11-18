import OrbDesktop.State

namespace OrbDesktop

/-! Live desktop bootstrap.  The helper deliberately emits a small tab-separated
projection rather than passing credentials through the UI state.  `--headless`
golden paths never call this module and remain deterministic fixtures. -/

private def pythonProjection : String :=
  "import json,os,sys,urllib.request\n" ++
  "p=os.path.expanduser('~/.orb/connection.json')\n" ++
  "try: c=json.load(open(p)); base=c.get('api_url',c.get('endpoint','')).rstrip('/'); tok=c.get('token','')\n" ++
  "except Exception: sys.exit(2)\n" ++
  "def get(path):\n" ++
  " try:\n" ++
  "  r=urllib.request.Request(base+path,headers={'Authorization':'Bearer '+tok}); return json.load(urllib.request.urlopen(r,timeout=4))\n" ++
  " except Exception: return None\n" ++
  "def s(v): return str(v or '').replace('\\t',' ').replace('\\n',' ')\n" ++
  "for x in (get('/api/projects') or {}).get('projects',[]): print('P\\t'+s(x.get('slug'))+'\\t'+s(x.get('name',x.get('slug')))+'\\t'+s(x.get('description')))\n" ++
  "# The same authenticated control stream is the freshness contract used by WebKit: /api/control/stream.\n" ++
  "ms=get('/api/control/missions?limit=200') or []\n" ++
  "if isinstance(ms,dict): ms=ms.get('missions',[])\n" ++
  "for x in ms: print('M\\t'+'\\t'.join(s(x.get(k)) for k in ('id','title','project','track','model','model_override','status','updated_at','created_at','summary','prompt')))\n" ++
  "xs=get('/api/machines') or []\n" ++
  "if isinstance(xs,dict): xs=xs.get('machines',xs.get('nodes',[]))\n" ++
  "for x in xs: print('N\\t'+'\\t'.join(s(x.get(k)) for k in ('id','name','role','provider','cpu_ram','size','state','status','expires_at','cost','active_missions')))"

private def splitTab (line : String) : List String :=
  line.splitOn "\t"

private def col (xs : List String) (n : Nat) : String := xs.getD n ""

private def runProjection : IO (Option (List String)) := do
  let r ← IO.Process.output { cmd := "python3", args := #["-c", pythonProjection] }
  if r.exitCode != 0 then return none
  return some (r.stdout.splitOn "\n" |>.filter (fun x => !x.trimAscii.toString.isEmpty))

private def projectRow (idx : Nat) (xs : List String) : ChromeSidebarRow :=
  { widgetId := 1000 + idx, rowId := "project:" ++ col xs 1, kind := "project"
    title := col xs 2, subtitle := col xs 3 }

private def missionCard (idx : Nat) (xs : List String) : MissionSummaryCard :=
  { widgetId := 1100 + idx, missionId := col xs 1, title := col xs 2, project := col xs 3
    track := col xs 4, model := if (col xs 5).isEmpty then col xs 6 else col xs 5
    status := col xs 7, updatedLabel := if (col xs 8).isEmpty then col xs 9 else col xs 8
    summaryText := if (col xs 10).isEmpty then col xs 11 else col xs 10 }

private def machineCard (idx : Nat) (xs : List String) : FleetMachineCard :=
  { widgetId := 1200 + idx, machineId := col xs 1, name := col xs 2
    roleLabel := if (col xs 3).isEmpty then col xs 4 else col xs 3
    cpuRamSpec := if (col xs 5).isEmpty then col xs 6 else col xs 5
    state := if (col xs 7).isEmpty then col xs 8 else col xs 7
    ttlLabel := col xs 9, costLabel := col xs 10, activeMissions := (col xs 11).toNat?.getD 0 }

def loadLiveState : IO (Option DesktopState) := do
  let some lines ← runProjection | return none
  let ps := lines.filterMap (fun line => let xs := splitTab line; if col xs 0 == "P" then some xs else none)
  let ms := lines.filterMap (fun line => let xs := splitTab line; if col xs 0 == "M" then some xs else none)
  let ns := lines.filterMap (fun line => let xs := splitTab line; if col xs 0 == "N" then some xs else none)
  if ps.isEmpty && ms.isEmpty && ns.isEmpty then return none
  let projects := ps.toArray.mapIdx (fun i xs => projectRow i xs) |>.toList
  let missions := ms.toArray.mapIdx (fun i xs => missionCard i xs) |>.toList
  let machines := ns.toArray.mapIdx (fun i xs => machineCard i xs) |>.toList
  let sidebar := [{ widgetId := 101, rowId := "nav:control", kind := "nav", title := "Control Center", selected := true },
    { widgetId := 108, rowId := "section:projects", kind := "section", title := "Projects" }] ++ projects
  return some { (DesktopState.forScreen .controlPopulated) with
    screen := .controlPopulated
    sidebarRows := sidebar
    missionCards := missions
    fleetMachines := machines }

end OrbDesktop
