import OrbCore.ResourcesAndSystem

namespace OrbCore.ComputeRollupTests

open OrbBin.Json OrbCore.Store OrbCore.Managed OrbCore.ResourcesAndSystem OrbCore.LegacyHydrate

private def check (condition : Bool) (label : String) : IO Unit := do
  unless condition do throw (IO.userError s!"compute rollup: {label}")

/-- The sampler writes one row per machine class and minute, and the overview
    reads the history back instead of a row of zeros. -/
def run (root : String) : IO Unit := do
  let .ok core ← openCoreStore s!"{root}/rollup-core" | throw (IO.userError "rollup core open failed")
  let .ok mc ← openManagedComputeStore s!"{root}/rollup-managed.db" | throw (IO.userError "rollup managed open failed")
  try
    let fleet : ManagedFleetState := { enabled := true, boatEnabled := true, dailyCapCents := 100000, maxConcurrent := 100 }
    let now ← coreEpochSec
    let .ok _ ← execParamQuery core.missionsDb "INSERT INTO missions(id,owner_user_id,project) VALUES('root','','p');" #[]
      | throw (IO.userError "rollup mission fixture failed")
    for (id, size, owner) in #[("held", "large", "root"), ("idle", "small", "")] do
      let .ok _ ← provisionManagedMachine mc fleet {
          id, sandboxName := s!"orb-managed-{id}", provider := "boat", size, ownerMission := owner,
          ownerKind := if owner.isEmpty then "user" else "mission", ttlMinutes := 30, spentCents := 5
        } now | throw (IO.userError "rollup machine fixture failed")
    let rows (query : String) : IO (Array (Array String)) := do
      match ← execParamQuery core.missionsDb query #[] with
      | .ok r => pure (r.extract 1 r.size)
      | .error e => throw (IO.userError s!"compute rollup: query failed: {e}")
    -- The live view uses declared sizes: 8 vCPU held by a mission, 2 idle.
    let live ← liveComputeSources core (some mc)
    let classOf (id : String) := live.sources.find? (·.1 == id)
    check ((classOf "boat:large").map (fun (_, _, _, total, active) => (total, active)) == some (8000, 8000) &&
      (classOf "boat:small").map (fun (_, _, _, total, active) => (total, active)) == some (2000, 0))
      "managed capacity is the declared size, busy when a mission holds it"
    -- Sampling is idempotent within a minute and accumulates across minutes.
    let minute := (now / 60) * 60
    let .ok written ← sampleComputeRollup core (some mc) (minute - 180) | throw (IO.userError "compute rollup: sample failed")
    check (written == live.sources.size) "one row per machine class"
    let .ok _ ← sampleComputeRollup core (some mc) (minute - 180 + 20) | throw (IO.userError "compute rollup: sample failed")
    let .ok _ ← sampleComputeRollup core (some mc) (minute - 60) | throw (IO.userError "compute rollup: sample failed")
    let stored ← rows "SELECT COUNT(*), COUNT(DISTINCT bucket_unix_min) FROM compute_rollup_1m WHERE machine_class='boat:large';"
    check (stored[0]? == some #["2", "2"]) "a second sample in the same minute replaces the first"
    let busy ← rows "SELECT vcpu_allocated, vcpu_busy FROM compute_rollup_1m WHERE machine_class='boat:large' LIMIT 1;"
    check (busy[0]? == some #["8.0", "8.0"]) "allocated and busy vCPU are stored"
    -- The overview shows the samples in their buckets and the live reading last.
    let overview ← buildResourcesOverviewJson core (some mc) #[("range", "30m")]
    let series (id : String) : Array String :=
      let source := (((overview.field? "compute").bind (·.fieldArr? "sources")).getD #[]).find? (·.fieldStr? "id" == some id)
      ((source.bind (·.fieldArr? "series_vcpu")).getD #[]).map renderCompact
    let large := series "boat:large"
    check (large.size == 30) s!"thirty one-minute buckets: {large.size} in {renderCompact overview |>.take 400}"
    check (large[26]? == some "8.000" && large[28]? == some "8.000" && large[27]? == some "0.0" && large[29]? == some "8.000")
      s!"history fills the sampled minutes and leaves the rest empty: {large}"
    check ((series "boat:small").all (fun v => v == "0.0" || v == "0.000")) "an idle class has an idle history"
    -- Old samples are pruned.
    let .ok _ ← execParamQuery core.missionsDb
        "INSERT INTO compute_rollup_1m(bucket_unix_min,machine_class,state,vcpu_busy) VALUES(1,'boat:large','sampled',1.0);" #[]
      | throw (IO.userError "rollup old fixture failed")
    let .ok _ ← sampleComputeRollup core (some mc) minute | throw (IO.userError "compute rollup: sample failed")
    check ((← rows "SELECT COUNT(*) FROM compute_rollup_1m WHERE bucket_unix_min=1;")[0]? == some #["0"]) "samples older than the longest chart are removed"
  finally
    closeManagedComputeStore mc
    closeCoreStore core

end OrbCore.ComputeRollupTests
