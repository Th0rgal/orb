import OrbCore.ManagedSpawnActions

namespace OrbCore.ManagedSpawnActionsTests

open OrbCore.Store OrbCore.ManagedSpawnActions OrbBin.Json

private def check (condition : Bool) (label : String) : IO Unit := do
  unless condition do throw (IO.userError s!"managed action: {label}")

private def waitSettled (store : CoreStore) (id : String) (owner : Owner) : IO JVal := do
  for _ in [0:1000] do
    let .ok (some value) ← read? store id owner
      | throw (IO.userError "managed action missing")
    let state := (value.fieldStr? "state").getD ""
    if state != "accepted" && state != "running" then return value
    IO.sleep 5
  throw (IO.userError "managed action did not settle")

def run (store : CoreStore) : IO Unit := do
  let owner : Owner := { userId := "action-user", missionId := "action-mission" }
  let args := JVal.obj #[("provider", .str "boat"), ("size", .str "small")]
  let count ← IO.mkRef (0 : Nat)
  let release ← IO.mkRef false
  let finished ← IO.mkRef false
  let work : IO (Except String JVal) := do
    count.modify (· + 1)
    for _ in [0:1000] do
      if ← release.get then
        finished.set true
        return .ok (.obj #[("id", .str "managed-ready"), ("state", .str "ready")])
      IO.sleep 5
    finished.set true
    return .error "test_release_timeout"
  let .ok accepted ← submit store owner "prompt-spawn" args work
    | throw (IO.userError "spawn acceptance failed")
  check (!(← finished.get) && accepted.fieldStr? "state" == some "accepted")
    "receipt returned before readiness"
  let some id := accepted.fieldStr? "action_id" | throw (IO.userError "missing action ID")
  let .ok repeated ← submit store owner "prompt-spawn" args work
    | throw (IO.userError "pending retry failed")
  check (repeated.fieldStr? "action_id" == some id) "pending retry replays one action"
  check (!(← submit store owner "prompt-spawn" (args.setField "size" (.str "large")) work).isOk)
    "changed request conflicts before dispatch"
  check (!(← read? store id { owner with userId := "other-user" }).isOk &&
    !(← read? store id { owner with missionId := "other-mission" }).isOk)
    "receipt tenant and mission isolation"
  release.set true
  let settled ← waitSettled store id owner
  check (settled.fieldStr? "state" == some "succeeded" && (← count.get) == 1 &&
    ((settled.field? "result").getD .null).fieldStr? "id" == some "managed-ready")
    "one execution and real terminal result"
  let .ok replay ← submit store owner "prompt-spawn" args work
    | throw (IO.userError "settled retry failed")
  check (replay.fieldStr? "action_id" == some id && (← count.get) == 1)
    "settled retry never reexecutes"

  let immediate : IO (Except String JVal) := do
    count.modify (· + 1)
    return .ok (.obj #[])
  let a ← IO.asTask (prio := .dedicated) (submit store owner "concurrent-spawn" args immediate)
  let b ← IO.asTask (prio := .dedicated) (submit store owner "concurrent-spawn" args immediate)
  let .ok av ← IO.ofExcept a.get | throw (IO.userError "concurrent submit A failed")
  let .ok bv ← IO.ofExcept b.get | throw (IO.userError "concurrent submit B failed")
  check (av.fieldStr? "action_id" == bv.fieldStr? "action_id") "concurrent inserts have one winner"
  let some concurrentId := av.fieldStr? "action_id" | throw (IO.userError "concurrent action ID missing")
  discard <| waitSettled store concurrentId owner
  check ((← count.get) == 2) "concurrent retries execute exactly once"

  let .ok failed ← submit store owner "uncertain-spawn" args
      (pure (.error "provider_transport_failed_outcome_uncertain"))
    | throw (IO.userError "uncertain submission rejected")
  let some uncertainId := failed.fieldStr? "action_id" | throw (IO.userError "uncertain action ID missing")
  let uncertain ← waitSettled store uncertainId owner
  check (uncertain.fieldStr? "state" == some "uncertain") "transport failure is not success"
  let .ok replayUncertain ← submit store owner "uncertain-spawn" args immediate
    | throw (IO.userError "uncertain replay rejected")
  check (replayUncertain.fieldStr? "state" == some "uncertain" && (← count.get) == 2)
    "uncertain receipt is a permanent replay fence"
  check (!(← submit store owner "" args immediate).isOk) "stable key required"
  check (ManagedSpawnActions.uncertain "provider_http_error:vm-1" && ManagedSpawnActions.uncertain "managed_bootstrap_timeout:provider_cleanup_pending:vm-1" &&
    !ManagedSpawnActions.uncertain "provider_at_capacity" && !ManagedSpawnActions.uncertain "managed_bootstrap_timeout")
    "an error naming a machine is never a clean failure"
  let .ok (some prior) ← replay? store owner "prompt-spawn" args | throw (IO.userError "replay lookup failed")
  check (prior.fieldStr? "action_id" == some id && !(← replay? store owner "prompt-spawn" (args.setField "size" (.str "large"))).isOk &&
    (← replay? store owner "never-used" args).toOption == some none && (← isSpawnAction store id))
    "replay lookup returns the stored receipt, conflicts on changed arguments, and is empty for a new key"
  let .ok previewed ← submit store owner "preview-spawn" args (pure (.ok (.obj #[("id", .str "final")])))
      (pure (.ok ())) (.obj #[("id", .str "preview")])
    | throw (IO.userError "preview submit failed")
  check (((previewed.field? "result").getD .null).fieldStr? "id" == some "preview") "accepted receipt carries the provisioning preview"
  let refused ← IO.mkRef false
  check (!(← submit store owner "refused-spawn" args (do refused.set true; return .ok (.obj #[]))
      (pure (.error "provider_at_capacity"))).isOk && (← replay? store owner "refused-spawn" args).toOption == some none &&
    !(← refused.get)) "a preflight refusal creates no receipt and runs nothing"

end OrbCore.ManagedSpawnActionsTests
