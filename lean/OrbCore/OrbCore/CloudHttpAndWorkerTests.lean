/-
  OrbCore.CloudHttpAndWorkerTests: End-to-end Hermes (`paloma`) Cloud Agent tests (H1).
  Exercises a loopback mock `hermes-gateway`, multi-user SQLite `CoreStore`, and isolated
  `HERMES_HOME` covering:
  1. Multi-user owner binding (`matchesCloudOwner` + `HERMES_CLOUD_OWNER=prod`: bootstrap admin
     connects when active members exist; members and non-bootstrap admins stay isolated with 403).
  2. `/v1/capabilities` readiness gating (ready vs incompatible missing replay flags).
  3. `GET /api/cloud/hermes/options` (models + efforts for admin, 403 for member).
  4. `GET|PUT /api/cloud/hermes/settings` (runtime health, sessions rollup, YAML/SOUL/.env persistence
     including `telegram_tool_progress`/`telegram_cleanup_progress` and validation errors, 403 for member).
  5. Cloud mission lifecycle: create, idempotency replay, zero-oracle member 403, `effort` reasoning
     wire format, paginated `data.event` live streaming, durable `/cloud/events`, approval `run_id`
     and owner-write isolation, follow-up turn with custom `client_message_id` + model/effort override,
     continuation `session_id` `/cloud/children` provenance, and cancellation via `/stop` + `interrupted`.
-/
import LeanSys.Posix
import OrbCore.CloudHttpAndWorker

namespace OrbCore.CloudHttpAndWorkerTests

open LeanSys.Posix
open OrbBin.Json
open OrbBin.Sqlite
open OrbBin.PosixExt
open OrbCore.Store
open OrbCore.CloudHttpAndWorker

private def check (ok : Bool) (label : String) : IO Unit := do
  unless ok do throw (IO.userError s!"cloud hermes h1: {label}")

private def parseJsonOrThrow (bytes : ByteArray) (label : String) : IO JVal := do
  match OrbBin.Json.parseBytes bytes with
  | .ok jv => return jv
  | .error e => throw (IO.userError s!"cloud hermes h1: invalid JSON ({label}): {e}")

private structure MockHermesState where
  capsStatus : Nat := 200
  capsBody : String := "{\"features\":{\"runs_idempotency\":{\"durable\":true},\"run_events_replay\":true},\"tools\":[{\"name\":\"bash\"}]}"
  modelsBody : String := "{\"data\":[{\"id\":\"hermes-agent\",\"name\":\"Hermes Agent\"},{\"id\":\"openai/gpt-6-astra\",\"displayName\":\"GPT-6 Astra\"}]}"
  run1Status : String := "waiting_for_approval"
  run1Output : String := ""
  run2Status : String := "running"
  stopCalledFor : Array String := #[]
  approvalPayload : String := ""
  runRequests : Array (String × String) := #[]
  runIdByIdem : Array (String × String) := #[]
  runCounter : Nat := 0

private def parseRawHttpReq (raw : String) : String × String × Array (String × String) × String := Id.run do
  let parts := raw.splitOn "\r\n\r\n"
  let head := parts.headD raw
  let body := String.intercalate "\r\n\r\n" parts.tail
  let lines := head.splitOn "\r\n"
  let reqLine := lines.headD ""
  let toks := reqLine.splitOn " "
  let method := toks[0]?.getD "GET"
  let target := toks[1]?.getD "/"
  let mut hdrs : Array (String × String) := #[]
  for ln in lines.tail do
    match ln.splitOn ":" with
    | k :: rest =>
      hdrs := hdrs.push (k.trimAscii.toString.toLower, (String.intercalate ":" rest).trimAscii.toString)
    | _ => pure ()
  return (method, target, hdrs, body)

private def mkHttpResp (status : Nat) (jsonBody : String) : ByteArray :=
  let reason := if status == 200 then "OK" else if status == 202 then "Accepted" else if status == 400 then "Bad Request" else "Error"
  let bodyBytes := jsonBody.toUTF8
  (s!"HTTP/1.1 {status} {reason}\r\nContent-Type: application/json\r\nContent-Length: {bodyBytes.size}\r\nConnection: close\r\n\r\n").toUTF8 ++ bodyBytes

private def readHttpRequestBounded (cfd : Fd) : IO String := do
  let mut acc := ByteArray.empty
  let mut done := false
  for _ in [0:40] do
    if done then break
    match ← readSocketTimed cfd 65536 500 with
    | .bytes chunk =>
      acc := acc ++ chunk
      let s := (String.fromUTF8? acc).getD ""
      if (s.splitOn "\r\n\r\n").length > 1 then
        let parts := s.splitOn "\r\n\r\n"
        let head := parts.headD ""
        let bodyPart := String.intercalate "\r\n\r\n" parts.tail
        let mut contentLen : Nat := 0
        for ln in head.splitOn "\r\n" do
          if ln.toLower.startsWith "content-length:" then
            contentLen := ((ln.drop 15).toString.trimAscii.toString.toNat?).getD 0
        if bodyPart.toUTF8.size >= contentLen then
          done := true
    | .eof | .timeout | .fatal _ =>
      done := true
  return (String.fromUTF8? acc).getD ""

private def spawnMockHermesServer (listenFd : Fd) (stateRef : IO.Ref MockHermesState) (stopRef : IO.Ref Bool) : IO (Task (Except IO.Error Unit)) :=
  IO.asTask (prio := .dedicated) do
    while !(← stopRef.get) do
      match ← tcpAcceptPoll listenFd 50 with
      | .ok cfd =>
        try
          let raw ← readHttpRequestBounded cfd
          let (method, target, hdrs, body) := parseRawHttpReq raw
          let authHdr := (hdrs.find? (fun (k, _) => k == "authorization")).map Prod.snd |>.getD ""
          let idemHdr := (hdrs.find? (fun (k, _) => k == "idempotency-key")).map Prod.snd |>.getD ""
          let st ← stateRef.get
          let (code, respBody) ←
            if authHdr != "Bearer test-hermes-key" then
              pure (401, "{\"error\":\"unauthorized\"}")
            else if method == "GET" && target == "/v1/capabilities" then
              pure (st.capsStatus, st.capsBody)
            else if method == "GET" && target == "/v1/models" then
              pure (200, st.modelsBody)
            else if method == "GET" && target.startsWith "/api/jobs" then
              pure (200, "{\"jobs\":[{\"id\":\"j1\",\"enabled\":true},{\"id\":\"j2\",\"enabled\":false}]}")
            else if method == "POST" && target == "/v1/runs" then
              match st.runIdByIdem.find? (fun (k, _) => k == idemHdr && !idemHdr.isEmpty) with
              | some (_, existingRunId) =>
                pure (202, s!"\{\"run_id\":\"{existingRunId}\",\"status\":\"running\"}")
              | none =>
                let n := st.runCounter + 1
                let runId := s!"run_h1_{n}"
                stateRef.set { st with
                  runCounter := n
                  runRequests := st.runRequests.push (idemHdr, body)
                  runIdByIdem := st.runIdByIdem.push (idemHdr, runId)
                }
                pure (202, s!"\{\"run_id\":\"{runId}\",\"status\":\"running\"}")
            else if method == "GET" && target == "/v1/runs/run_h1_1/events?format=json&after=0" then
              pure (200,
                "{\"events\":[" ++
                "{\"id\":\"1\",\"data\":{\"event\":\"reasoning.available\",\"text\":\"Checking repository state\"}}," ++
                "{\"id\":\"2\",\"data\":{\"event\":\"tool.started\",\"tool\":\"bash\",\"preview\":\"git status\"}}" ++
                "],\"cursor\":\"2\",\"has_more\":true}")
            else if method == "GET" && target == "/v1/runs/run_h1_1/events?format=json&after=2" then
              pure (200,
                "{\"events\":[" ++
                "{\"id\":\"3\",\"data\":{\"event\":\"tool.completed\",\"tool\":\"bash\",\"preview\":\"clean tree\",\"duration\":120}}," ++
                "{\"id\":\"4\",\"data\":{\"event\":\"message.delta\",\"delta\":\"Hello \"}}" ++
                "],\"cursor\":\"4\",\"has_more\":false}")
            else if method == "GET" && target == "/v1/runs/run_h1_1/events?format=json&after=4" then
              if st.run1Status == "completed" then
                pure (200,
                  "{\"events\":[{\"id\":\"5\",\"data\":{\"event\":\"message.delta\",\"delta\":\"world!\"}}],\"cursor\":\"5\",\"has_more\":false}")
              else
                pure (200, "{\"events\":[],\"cursor\":\"4\",\"has_more\":false}")
            else if method == "GET" && target == "/v1/runs/run_h1_1" then
              if st.run1Status == "waiting_for_approval" then
                pure (200,
                  "{\"status\":\"waiting_for_approval\",\"session_id\":\"cont_sess_h1\"," ++
                  "\"approval\":{\"request_id\":\"req_h1_1\",\"command\":\"git status\",\"choices\":[\"once\",\"deny\"]}}")
              else
                pure (200,
                  s!"\{\"status\":\"{st.run1Status}\",\"session_id\":\"cont_sess_h1\",\"output\":{jsonEscape st.run1Output},\"usage\":\{\"total_tokens\":42}}")
            else if method == "POST" && target == "/v1/runs/run_h1_1/approval" then
              stateRef.set { st with approvalPayload := body, run1Status := "completed", run1Output := "Hello world!" }
              pure (200, "{\"ok\":true,\"status\":\"resumed\"}")
            else if method == "GET" && target.startsWith "/v1/runs/run_h1_2/events" then
              pure (200, "{\"events\":[{\"id\":\"1\",\"data\":{\"event\":\"message.delta\",\"delta\":\"Working...\"}}],\"cursor\":\"1\",\"has_more\":false}")
            else if method == "POST" && target == "/v1/runs/run_h1_2/stop" then
              stateRef.set { st with stopCalledFor := st.stopCalledFor.push "run_h1_2", run2Status := "interrupted" }
              pure (200, "{\"ok\":true,\"status\":\"interrupted\"}")
            else if method == "GET" && target == "/v1/runs/run_h1_2" then
              pure (200, s!"\{\"status\":\"{st.run2Status}\",\"session_id\":\"cont_sess_h1\"}")
            else
              pure (404, s!"\{\"error\":\"not_found\",\"target\":{jsonEscape target}}")
          discard <| writeAll cfd (mkHttpResp code respBody)
        finally
          discard <| closeFd cfd
      | .error _ => pure ()

private def restoreEnv (key : String) (prev : Option String) : IO Unit := do
  match prev with
  | some v => setenvVar key v
  | none => unsetenvVar key

def run : IO Unit := do
  -- Pure unit checks: capabilities readiness & effort reasoning encoding
  check ((checkHermesCapabilitiesReady (.obj #[
    ("features", .obj #[("runs_idempotency", .obj #[("durable", .bool true)]), ("run_events_replay", .bool true)])
  ])).isOk) "capabilities ready accepts durable+replay=true"
  check (!(checkHermesCapabilitiesReady (.obj #[
    ("features", .obj #[("runs_idempotency", .obj #[("durable", .bool false)]), ("run_events_replay", .bool true)])
  ])).isOk) "capabilities rejects durable=false"
  check (!(checkHermesCapabilitiesReady (.obj #[
    ("features", .obj #[("runs_idempotency", .obj #[("durable", .bool true)]), ("run_events_replay", .bool false)])
  ])).isOk) "capabilities rejects run_events_replay=false"
  check (effortToHermesReasoning? "none" == some (.obj #[("enabled", .bool false)]))
    "effort=none encodes reasoning.enabled=false"
  check (effortToHermesReasoning? "high" == some (.obj #[("enabled", .bool true), ("effort", .str "high")]))
    "effort=high encodes reasoning object with enabled=true"
  check (effortToHermesReasoning? "" == none && effortToHermesReasoning? "default" == none)
    "empty/default effort omits reasoning override"

  let nonce ← IO.monoNanosNow
  let root := s!"/tmp/orb-hermes-h1-{nonce}"
  let hermesHome := s!"{root}/hermes-home"
  IO.FS.createDirAll hermesHome

  let prevOwner ← IO.getEnv "HERMES_CLOUD_OWNER"
  let prevUrl ← IO.getEnv "HERMES_API_URL"
  let prevHome ← IO.getEnv "HERMES_HOME"
  let prevKey ← IO.getEnv "API_SERVER_KEY"

  let (listenFd, mockPort) ← IO.ofExcept (← tcpListen "127.0.0.1" 0 16)
  let mockRef ← IO.mkRef ({} : MockHermesState)
  let stopRef ← IO.mkRef false
  let serverTask ← spawnMockHermesServer listenFd mockRef stopRef

  try
    -- Prepare isolated HERMES_HOME (config.yaml, SOUL.md, .env, state.db)
    IO.FS.writeFile s!"{hermesHome}/.env" "API_SERVER_KEY=test-hermes-key\nHERMES_ASSISTANT_MODEL=builtin/smart\n"
    IO.FS.writeFile s!"{hermesHome}/config.yaml"
      ("model:\n  default: \"builtin/smart\"\n  provider: \"custom\"\n  base_url: \"http://127.0.0.1:3000/v1\"\n  reasoning_effort: \"\"\n" ++
       "memory:\n  memory_enabled: true\n  user_profile_enabled: true\n  memory_char_limit: 8000\n  user_char_limit: 4000\n" ++
       "compression:\n  enabled: true\n  threshold: 0.5\n" ++
       "display:\n  platforms:\n    telegram:\n      tool_progress: \"new\"\n      cleanup_progress: true\n")
    IO.FS.writeFile s!"{hermesHome}/SOUL.md" "# Initial Paloma Soul\n"

    let nowSec ← nowEpoch
    let .ok sdb ← openSqliteDb s!"{hermesHome}/state.db" ""
      | throw (IO.userError "failed creating mock hermes state.db")
    let _ ← sqliteExecRaw sdb.handle
      ("CREATE TABLE sessions (id TEXT PRIMARY KEY, source TEXT, started_at INTEGER, ended_at INTEGER, " ++
       "message_count INTEGER, tool_call_count INTEGER, input_tokens INTEGER, output_tokens INTEGER);" ++
       s!"INSERT INTO sessions VALUES ('s1','api',{nowSec - 1000},NULL,6,2,600,400);" ++
       s!"INSERT INTO sessions VALUES ('s2','telegram',{nowSec - 100000},{nowSec - 99000},4,1,300,200);")
    sqliteCloseRaw sdb.handle

    setenvVar "HERMES_CLOUD_OWNER" "prod"
    setenvVar "HERMES_API_URL" s!"http://127.0.0.1:{mockPort}"
    setenvVar "HERMES_HOME" hermesHome
    unsetenvVar "API_SERVER_KEY"

    let .ok store ← openCoreStore root 0 "prod"
      | throw (IO.userError "openCoreStore failed")
    try
      -- Multi-user setup: bootstrap admin + active member + member named "prod" + second admin
      let _ ← execParamQuery store.missionsDb
        ("INSERT INTO users (id, username, role, password_hash, disabled, created_at) VALUES " ++
         "('u-admin','admin','admin','h',0,'2026-11-24T00:00:00Z')," ++
         "('u-member','ben','member','h',0,'2026-11-24T00:00:00Z')," ++
         "('u-member-prod','prod','member','h',0,'2026-11-24T00:00:00Z')," ++
         "('u-admin-2','admin2','admin','h',0,'2026-11-24T00:00:00Z');") #[]
      let _ ← IO.ofExcept (← execParamQuery store.missionsDb
        "INSERT INTO model_routing_chains (id, name, models_json, updated_at) VALUES ('custom-chain','Custom Chain','[]','2026-11-24T00:00:00Z');" #[])

      let hub ← newCloudRuntimeHub

      -- 1. GET /api/cloud/accounts: admin sees Paloma available=true; members & other admin see available=false
      let some (admAccCode, _, admAccBody) ← dispatchCloudHttpRoute hub store none 3000 "GET" "/api/cloud/accounts" "/api/cloud/accounts" ByteArray.empty "u-admin" "admin" "u-admin" true false
        | throw (IO.userError "GET /api/cloud/accounts not dispatched")
      check (admAccCode == 200) s!"admin accounts status {admAccCode}"
      let admAccts := (← parseJsonOrThrow admAccBody "admin accounts").asArr?.getD #[]
      let admPaloma := (admAccts.find? (fun a => a.fieldStr? "id" == some "paloma")).getD .null
      check (admPaloma.fieldBool? "available" == some true && (admPaloma.field? "reason") == some .null)
        s!"bootstrap admin sees paloma available in multi-user mode: {renderCompact admPaloma}"

      for (uid, uname, isAdm) in #[("u-member", "ben", false), ("u-member-prod", "prod", false), ("u-admin-2", "admin2", true)] do
        let some (mCode, _, mBody) ← dispatchCloudHttpRoute hub store none 3000 "GET" "/api/cloud/accounts" "/api/cloud/accounts" ByteArray.empty uid uname "u-admin" isAdm false
          | throw (IO.userError "member accounts not dispatched")
        check (mCode == 200) s!"member accounts status {mCode}"
        let mAccts := (← parseJsonOrThrow mBody "member accounts").asArr?.getD #[]
        let mPaloma := (mAccts.find? (fun a => a.fieldStr? "id" == some "paloma")).getD .null
        check (mPaloma.fieldBool? "available" == some false)
          s!"non-owner {uid} sees paloma unavailable"

      -- 2. GET /api/cloud/hermes/options: admin gets 200 (models + efforts); members get 403
      let some (optAdmCode, _, optAdmBody) ← dispatchCloudHttpRoute hub store none 3000 "GET" "/api/cloud/hermes/options" "/api/cloud/hermes/options" ByteArray.empty "u-admin" "admin" "u-admin" true false
        | throw (IO.userError "hermes options not dispatched")
      check (optAdmCode == 200) s!"admin hermes options expected 200, got {optAdmCode}"
      let optJv ← parseJsonOrThrow optAdmBody "admin options"
      let modelIds := (((optJv.fieldOrNull "models").fieldArr? "items").getD #[]).filterMap (·.fieldStr? "id")
      let effortIds := (optJv.fieldArr? "efforts" |>.getD #[]).filterMap (·.fieldStr? "id")
      check (modelIds.contains "" && modelIds.contains "builtin/custom-chain" &&
             modelIds.contains "openai/gpt-6-astra" && !modelIds.contains "hermes-agent")
        s!"hermes options models mismatch: {modelIds}"
      check (effortIds.contains "" && effortIds.contains "none" && effortIds.contains "high" && effortIds.contains "xhigh")
        s!"hermes options efforts mismatch: {effortIds}"

      let some (optMemCode, _, _) ← dispatchCloudHttpRoute hub store none 3000 "GET" "/api/cloud/hermes/options" "/api/cloud/hermes/options" ByteArray.empty "u-member" "ben" "u-admin" false false
        | throw (IO.userError "member hermes options not dispatched")
      check (optMemCode == 403) s!"member hermes options must return 403, got {optMemCode}"

      -- 3. GET|PUT /api/cloud/hermes/settings: member 403; admin reads runtime/sessions and persists updates
      let some (setMemGet, _, _) ← dispatchCloudHttpRoute hub store none 3000 "GET" "/api/cloud/hermes/settings" "/api/cloud/hermes/settings" ByteArray.empty "u-member" "ben" "u-admin" false false
        | throw (IO.userError "member settings GET not dispatched")
      let some (setMemPut, _, _) ← dispatchCloudHttpRoute hub store none 3000 "PUT" "/api/cloud/hermes/settings" "/api/cloud/hermes/settings" "{}".toUTF8 "u-member" "ben" "u-admin" false false
        | throw (IO.userError "member settings PUT not dispatched")
      check (setMemGet == 403 && setMemPut == 403) s!"member settings must return 403, got GET={setMemGet} PUT={setMemPut}"

      let some (setGetCode, _, setGetBody) ← dispatchCloudHttpRoute hub store none 3000 "GET" "/api/cloud/hermes/settings" "/api/cloud/hermes/settings" ByteArray.empty "u-admin" "admin" "u-admin" true false
        | throw (IO.userError "admin settings GET not dispatched")
      check (setGetCode == 200) s!"admin settings GET status {setGetCode}"
      let setJv ← parseJsonOrThrow setGetBody "admin settings GET"
      let rtObj := setJv.fieldOrNull "runtime"
      let sessObj := setJv.fieldOrNull "sessions"
      check (rtObj.fieldBool? "api_server_healthy" == some true && rtObj.fieldBool? "uses_sandboxed_proxy" == some true &&
             setJv.fieldNat? "mcp_tools_count" == some 1 &&
             (setJv.fieldOrNull "jobs").fieldNat? "total" == some 2 &&
             (setJv.fieldOrNull "jobs").fieldNat? "enabled" == some 1)
        s!"settings runtime/jobs mismatch: {renderCompact rtObj}"
      check (sessObj.fieldBool? "available" == some true &&
             sessObj.fieldNat? "total_sessions" == some 2 &&
             sessObj.fieldNat? "active_sessions_24h" == some 1 &&
             sessObj.fieldNat? "total_tokens" == some 1500 &&
             sessObj.fieldNat? "total" == some 2 &&
             sessObj.fieldNat? "open" == some 1)
        s!"settings sessions rollup mismatch: {renderCompact sessObj}"

      -- Validation errors on PUT
      let some (badEffCode, _, _) ← dispatchCloudHttpRoute hub store none 3000 "PUT" "/api/cloud/hermes/settings" "/api/cloud/hermes/settings" "{\"reasoning_effort\":\"turbo\"}".toUTF8 "u-admin" "admin" "u-admin" true false
        | throw (IO.userError "bad effort not dispatched")
      let some (badThreshCode, _, _) ← dispatchCloudHttpRoute hub store none 3000 "PUT" "/api/cloud/hermes/settings" "/api/cloud/hermes/settings" "{\"compression_threshold\":0.02}".toUTF8 "u-admin" "admin" "u-admin" true false
        | throw (IO.userError "bad threshold not dispatched")
      check (badEffCode == 400 && badThreshCode == 400) s!"invalid settings must return 400, got {badEffCode} {badThreshCode}"

      -- Valid PUT persists all fields including telegram_tool_progress, telegram_cleanup_progress, >32k memory limit, SOUL.md, .env
      let putPayload :=
        "{\"default_model\":\"openai/gpt-6-astra\",\"reasoning_effort\":\"high\",\"use_sandboxed_router\":true," ++
        "\"memory_enabled\":false,\"user_profile_enabled\":true,\"memory_char_limit\":64000,\"user_char_limit\":32000," ++
        "\"compression_enabled\":true,\"compression_threshold\":0.75,\"telegram_tool_progress\":\"edit\"," ++
        "\"telegram_cleanup_progress\":false,\"soul_markdown\":\"# Updated Paloma Soul\\n\",\"restart_service\":true}"
      let some (putCode, _, putBody) ← dispatchCloudHttpRoute hub store none 3000 "PUT" "/api/cloud/hermes/settings" "/api/cloud/hermes/settings" putPayload.toUTF8 "u-admin" "admin" "u-admin" true false
        | throw (IO.userError "admin settings PUT not dispatched")
      check (putCode == 200) s!"admin settings PUT status {putCode}"
      let updJv ← parseJsonOrThrow putBody "admin settings PUT"
      check (updJv.fieldStr? "default_model" == some "openai/gpt-6-astra" &&
             updJv.fieldStr? "reasoning_effort" == some "high" &&
             updJv.fieldBool? "memory_enabled" == some false &&
             updJv.fieldNat? "memory_char_limit" == some 64000 &&
             updJv.fieldNat? "user_char_limit" == some 32000 &&
             updJv.fieldStr? "telegram_tool_progress" == some "edit" &&
             updJv.fieldBool? "telegram_cleanup_progress" == some false &&
             updJv.fieldStr? "soul_markdown" == some "# Updated Paloma Soul\n")
        s!"settings PUT round-trip mismatch: {renderCompact updJv}"
      let envAfter ← IO.FS.readFile s!"{hermesHome}/.env"
      check ((envAfter.splitOn "HERMES_ASSISTANT_MODEL=openai/gpt-6-astra").length > 1)
        "settings PUT updated HERMES_ASSISTANT_MODEL in .env"

      -- 4. Cloud mission create: member 403; admin creates + idempotent replay; member with admin's key still 403 (zero oracle)
      let cloudSel : JVal := .obj #[
        ("provider", .str "hermes"),
        ("account", .str "paloma"),
        ("model", .str "builtin/smart"),
        ("model_params", .arr #[.obj #[("id", .str "effort"), ("value", .str "high")]])
      ]
      let createReq : JVal := .obj #[
        ("prompt", .str "Check repo status"),
        ("project", .str "demo"),
        ("idempotency_key", .str "idem-h1-launch-1"),
        ("cloud", cloudSel)
      ]
      let (memCreateCode, _, _) ← handleCloudMissionCreate hub store none 3000 "u-member" "ben" "u-admin" false false createReq cloudSel
      check (memCreateCode == 403) s!"member cloud mission create must return 403, got {memCreateCode}"

      let (admCreateCode, _, admCreateBody) ← handleCloudMissionCreate hub store none 3000 "u-admin" "admin" "u-admin" true false createReq cloudSel
      check (admCreateCode == 200) s!"admin cloud mission create status {admCreateCode}"
      let createdJv ← parseJsonOrThrow admCreateBody "created mission"
      let missionId := (createdJv.fieldStr? "id").getD ""
      check (!missionId.isEmpty) "created cloud mission has id"

      -- Idempotent replay for admin returns 200 with same id; different prompt with same key returns 409; member gets 403
      let (replayCode, _, replayBody) ← handleCloudMissionCreate hub store none 3000 "u-admin" "admin" "u-admin" true false createReq cloudSel
      let replayJv ← parseJsonOrThrow replayBody "replay mission"
      check (replayCode == 200 && replayJv.fieldStr? "id" == some missionId) "idempotent replay returned same mission"
      let diffReq := createReq.setField "prompt" (.str "Different prompt")
      let (conflictCode, _, _) ← handleCloudMissionCreate hub store none 3000 "u-admin" "admin" "u-admin" true false diffReq cloudSel
      check (conflictCode == 409) s!"conflicting idempotency_key must return 409, got {conflictCode}"
      let (memReplayCode, _, _) ← handleCloudMissionCreate hub store none 3000 "u-member" "ben" "u-admin" false false createReq cloudSel
      check (memReplayCode == 403) s!"member replaying admin idempotency_key must return 403, got {memReplayCode}"

      -- Wait for the real background worker spawned by handleCloudMissionCreate to reach `waiting_user`
      let mut reachedWait := false
      for _ in [0:120] do
        let some (_, curExec) ← loadCloudExecutionJson? store missionId | pure ()
        let ph := (((curExec.fieldArr? "turns").getD #[])[0]?.bind (·.fieldStr? "phase")).getD ""
        if ph == "waiting_user" then
          reachedWait := true
          break
        IO.sleep 50
      check reachedWait "turn 1 reached waiting_user with streamed events"

      -- Verify POST /v1/runs wire format (Idempotency-Key + structured model_options.reasoning)
      let stAfterRun1 ← mockRef.get
      check (stAfterRun1.runRequests.size >= 1) "mock hermes received POST /v1/runs"
      let (idem1, body1Str) := stAfterRun1.runRequests[0]!
      let body1Jv ← parseJsonOrThrow body1Str.toUTF8 "run 1 body"
      let reas1 := (body1Jv.fieldOrNull "model_options").fieldOrNull "reasoning"
      check (idem1 == s!"orb:{missionId}:idem-h1-launch-1" &&
             body1Jv.fieldStr? "model" == some "builtin/smart" &&
             reas1.fieldBool? "enabled" == some true &&
             reas1.fieldStr? "effort" == some "high")
        s!"run 1 wire format mismatch: idem={idem1} body={body1Str}"

      -- Verify GET /cloud shows paginated events, tool step, think step, partial result, and approval with run_id
      let some (execCode, _, execBody) ← dispatchCloudHttpRoute hub store none 3000 "GET" s!"/api/control/missions/{missionId}/cloud" s!"/api/control/missions/{missionId}/cloud" ByteArray.empty "u-admin" "admin" "u-admin" true false
        | throw (IO.userError "GET /cloud not dispatched")
      check (execCode == 200) s!"GET /cloud status {execCode}"
      let execJv ← parseJsonOrThrow execBody "GET /cloud"
      let t0 := ((execJv.fieldArr? "turns").getD #[])[0]?.getD .null
      let t0Arts := (t0.fieldArr? "artifacts").getD #[]
      let t0Steps := (t0.fieldArr? "steps").getD #[]
      let app0 := t0Arts[0]?.getD .null
      check (t0.fieldStr? "phase" == some "waiting_user" &&
             t0.fieldStr? "result" == some "Hello " &&
             t0.fieldStr? "session_id" == some "cont_sess_h1" &&
             t0Steps.size == 2 &&
             app0.fieldStr? "kind" == some "hermes_approval" &&
             app0.fieldStr? "run_id" == some "run_h1_1" &&
             (app0.fieldOrNull "request").fieldStr? "request_id" == some "req_h1_1")
        s!"waiting_user turn projection mismatch: {renderCompact t0}"

      -- Verify durable /cloud/events stored all 4 streamed events
      let some (evsCode, _, evsBody) ← dispatchCloudHttpRoute hub store none 3000 "GET" s!"/api/control/missions/{missionId}/cloud/events" s!"/api/control/missions/{missionId}/cloud/events" ByteArray.empty "u-admin" "admin" "u-admin" true false
        | throw (IO.userError "GET /cloud/events not dispatched")
      let evsArr := (← parseJsonOrThrow evsBody "cloud events").asArr?.getD #[]
      check (evsCode == 200 && evsArr.size == 4) s!"expected 4 durable cloud events, got {evsCode} len={evsArr.size}"

      -- Member cannot read admin's cloud mission (404)
      let some (memCloudCode, _, _) ← dispatchCloudHttpRoute hub store none 3000 "GET" s!"/api/control/missions/{missionId}/cloud" s!"/api/control/missions/{missionId}/cloud" ByteArray.empty "u-member" "ben" "u-admin" false false
        | throw (IO.userError "member GET /cloud not dispatched")
      check (memCloudCode == 404) s!"member GET /cloud must return 404, got {memCloudCode}"

      -- Approval validation: invalid choice -> 409; valid choice -> 200 and resumes to completion
      let badApproval := "{\"run_id\":\"run_h1_1\",\"request_id\":\"req_h1_1\",\"choice\":\"always\"}"
      let some (badAppCode, _, _) ← dispatchCloudHttpRoute hub store none 3000 "POST" s!"/api/control/missions/{missionId}/cloud/approval" s!"/api/control/missions/{missionId}/cloud/approval" badApproval.toUTF8 "u-admin" "admin" "u-admin" true false
        | throw (IO.userError "bad approval not dispatched")
      check (badAppCode == 409) s!"invalid approval choice must return 409, got {badAppCode}"

      let goodApproval := "{\"run_id\":\"run_h1_1\",\"request_id\":\"req_h1_1\",\"choice\":\"once\"}"
      let some (okAppCode, _, _) ← dispatchCloudHttpRoute hub store none 3000 "POST" s!"/api/control/missions/{missionId}/cloud/approval" s!"/api/control/missions/{missionId}/cloud/approval" goodApproval.toUTF8 "u-admin" "admin" "u-admin" true false
        | throw (IO.userError "good approval not dispatched")
      check (okAppCode == 200) s!"valid approval expected 200, got {okAppCode}"

      -- Wait for background worker to complete turn 1
      let mut t0Done := false
      for _ in [0:120] do
        let some (_, curExec) ← loadCloudExecutionJson? store missionId | pure ()
        let t := ((curExec.fieldArr? "turns").getD #[])[0]?.getD .null
        if t.fieldStr? "phase" == some "response_complete" then
          check (t.fieldStr? "result" == some "Hello world!" &&
                 ((t.fieldArr? "artifacts").getD #[]).isEmpty &&
                 (t.fieldOrNull "usage").fieldNat? "total_tokens" == some 42)
            s!"completed turn 1 mismatch: {renderCompact t}"
          t0Done := true
          break
        IO.sleep 50
      check t0Done "turn 1 completed cleanly after approval"

      -- 5. Children provenance from resolved continuation session `cont_sess_h1`
      let _ ← execParamQuery store.missionsDb
        ("INSERT INTO missions (id, title, status, backend, working_directory, created_at, updated_at, origin_session_id, owner_user_id) " ++
         "VALUES ('11111111-1111-4111-8111-111111111111','Delegated check','completed','codex','','2026-11-24T00:00:00Z','2026-11-24T00:00:00Z','cont_sess_h1','u-admin');") #[]
      let some (chCode, _, chBody) ← dispatchCloudHttpRoute hub store none 3000 "GET" s!"/api/control/missions/{missionId}/cloud/children" s!"/api/control/missions/{missionId}/cloud/children" ByteArray.empty "u-admin" "admin" "u-admin" true false
        | throw (IO.userError "GET /cloud/children not dispatched")
      let chArr := ((← parseJsonOrThrow chBody "children").fieldArr? "missions").getD #[]
      check (chCode == 200 && chArr.size == 1 && chArr[0]!.fieldStr? "id" == some "11111111-1111-4111-8111-111111111111")
        s!"children lookup via continuation session failed: {renderCompact (.arr chArr)}"

      -- 6. Follow-up turn with custom `client_message_id`, model & effort override (`none` -> enabled=false), then cancellation
      let followReq : JVal := .obj #[
        ("content", .str "Follow-up check"),
        ("client_message_id", .str "followup-h1-2"),
        ("cloud_model", .str "openai/gpt-6-astra"),
        ("cloud_model_params", .arr #[.obj #[("id", .str "effort"), ("value", .str "none")]])
      ]
      let (fCode, _, fBody) ← handleCloudFollowUp hub store none 3000 missionId followReq
      let fJv ← parseJsonOrThrow fBody "follow-up"
      check (fCode == 200 && fJv.fieldStr? "id" == some "followup-h1-2")
        s!"follow-up expected 200 with preserved client_message_id, got {fCode} {renderCompact fJv}"
      -- Idempotent follow-up replay & conflict
      let (fRepCode, _, _) ← handleCloudFollowUp hub store none 3000 missionId followReq
      let (fConfCode, _, _) ← handleCloudFollowUp hub store none 3000 missionId (followReq.setField "content" (.str "Changed"))
      check (fRepCode == 200 && fConfCode == 409) s!"follow-up idempotency mismatch: replay={fRepCode} conflict={fConfCode}"

      -- Wait for background worker to launch turn 2 on `run_h1_2`
      let mut t1Running := false
      for _ in [0:120] do
        let some (_, curExec) ← loadCloudExecutionJson? store missionId | pure ()
        let t := ((curExec.fieldArr? "turns").getD #[])[1]?.getD .null
        if t.fieldStr? "phase" == some "running" && t.fieldStr? "external_id" == some "run_h1_2" then
          t1Running := true
          break
        IO.sleep 50
      check t1Running "follow-up turn 2 launched as run_h1_2"

      let stAfterRun2 ← mockRef.get
      check (stAfterRun2.runRequests.size >= 2) "mock hermes received follow-up POST /v1/runs"
      let (idem2, body2Str) := stAfterRun2.runRequests[1]!
      let body2Jv ← parseJsonOrThrow body2Str.toUTF8 "run 2 body"
      let reas2 := (body2Jv.fieldOrNull "model_options").fieldOrNull "reasoning"
      check (idem2 == s!"orb:{missionId}:followup-h1-2" &&
             body2Jv.fieldStr? "model" == some "openai/gpt-6-astra" &&
             reas2.fieldBool? "enabled" == some false)
        s!"run 2 wire format mismatch: idem={idem2} body={body2Str}"

      -- Cancel turn 2: member denied; admin cancels idempotently; worker sends /stop and settles to cancelled
      let some (memCanc, _, _) ← dispatchCloudHttpRoute hub store none 3000 "POST" s!"/api/control/missions/{missionId}/cloud/cancel" s!"/api/control/missions/{missionId}/cloud/cancel" ByteArray.empty "u-member" "ben" "u-admin" false false
        | throw (IO.userError "member cancel not dispatched")
      check (memCanc == 404) s!"member cancel expected 404, got {memCanc}"

      let some (admCanc1, _, _) ← dispatchCloudHttpRoute hub store none 3000 "POST" s!"/api/control/missions/{missionId}/cloud/cancel" s!"/api/control/missions/{missionId}/cloud/cancel" ByteArray.empty "u-admin" "admin" "u-admin" true false
        | throw (IO.userError "admin cancel not dispatched")
      let some (admCanc2, _, _) ← dispatchCloudHttpRoute hub store none 3000 "POST" s!"/api/control/missions/{missionId}/cloud/cancel" s!"/api/control/missions/{missionId}/cloud/cancel" ByteArray.empty "u-admin" "admin" "u-admin" true false
        | throw (IO.userError "admin cancel 2 not dispatched")
      check (admCanc1 == 200 && admCanc2 == 200) s!"cancel expected 200, got {admCanc1} {admCanc2}"

      let mut t1Cancelled := false
      for _ in [0:120] do
        let some (_, curExec) ← loadCloudExecutionJson? store missionId | pure ()
        let t := ((curExec.fieldArr? "turns").getD #[])[1]?.getD .null
        if t.fieldStr? "phase" == some "cancelled" then
          t1Cancelled := true
          break
        IO.sleep 50
      let stFinal ← mockRef.get
      check (t1Cancelled && stFinal.stopCalledFor.contains "run_h1_2")
        s!"turn 2 cancellation did not settle via /stop: cancelled={t1Cancelled} stops={stFinal.stopCalledFor}"

      -- 7. Capabilities downgrade detection on fresh hub
      mockRef.modify fun s => { s with capsBody := "{\"features\":{\"runs_idempotency\":{\"durable\":false},\"run_events_replay\":false}}" }
      let freshHub ← newCloudRuntimeHub
      let some (downCode, _, downBody) ← dispatchCloudHttpRoute freshHub store none 3000 "GET" "/api/cloud/accounts" "/api/cloud/accounts" ByteArray.empty "u-admin" "admin" "u-admin" true false
        | throw (IO.userError "downgraded accounts not dispatched")
      let downAccts := (← parseJsonOrThrow downBody "downgraded accounts").asArr?.getD #[]
      let downPaloma := (downAccts.find? (fun a => a.fieldStr? "id" == some "paloma")).getD .null
      check (downCode == 200 && downPaloma.fieldBool? "available" == some false &&
             (((downPaloma.fieldStr? "reason").getD "").splitOn "upgrade hermes-gateway").length > 1)
        s!"incompatible capabilities must mark paloma unavailable with upgrade hint: {renderCompact downPaloma}"

      IO.println "[PASS] CloudHttpAndWorkerTests: Hermes H1 end-to-end owner isolation, capabilities, options, settings, streaming, approval, follow-up, and cancel"
    finally
      closeCoreStore store
  finally
    stopRef.set true
    discard <| IO.wait serverTask
    discard <| closeFd listenFd
    restoreEnv "HERMES_CLOUD_OWNER" prevOwner
    restoreEnv "HERMES_API_URL" prevUrl
    restoreEnv "HERMES_HOME" prevHome
    restoreEnv "API_SERVER_KEY" prevKey
    try IO.FS.removeDirAll root catch _ => pure ()

end OrbCore.CloudHttpAndWorkerTests
