/-
  OrbBin.AutomationMcpMain: Mission Automation & Durable Wakeup MCP Server (`automation-manager-mcp`).
  Replaces `src/bin/automation_manager_mcp.rs` in native Lean 4.
  Exposes `list_automations`, `create_automation`, `update_automation`, `delete_automation`,
  `get_execution_history`, `schedule_wakeup`, and `schedule_job_wakeup` over bounded JSON-RPC 2.0 stdio,
  with native HS256 JWT minting via `LeanSys.Auth.hmacSha256Bytes` when `API_TOKEN` is unset.
-/
import LeanSys.Auth
import OrbBin.PosixExt
import OrbBin.Json
import OrbBin.HttpClient
import OrbBin.StdioMcpServer

namespace OrbBin.AutomationMcp

open OrbBin.PosixExt
open OrbBin.Json
open OrbBin.HttpClient
open OrbBin.StdioMcpServer

def wakeupMinSeconds : Nat := 60
def wakeupMaxSeconds : Nat := 3600

private def serviceUserIdentity : IO String := do
  match (← firstEnvNonEmpty ["SANDBOXED_SINGLE_TENANT_USER_ID", "SINGLE_TENANT_USER_ID"]) with
  | some v =>
    let t := v.trimAscii.toString
    return if t.isEmpty then "default" else t
  | none => return "default"

/-- Mint a 24h HS256 service JWT (`{"alg":"HS256","typ":"JWT"}`) using `LeanSys.Auth.hmacSha256Bytes`. -/
def mintServiceJwt (secret : String) : IO String := do
  let now ← nowEpoch
  let exp := now + 86400
  let ident ← serviceUserIdentity
  let headerJson := renderCompact (.obj #[("alg", .str "HS256"), ("typ", .str "JWT")])
  let claimsJson := renderCompact (.obj #[
    ("sub", .str ident),
    ("usr", .str ident),
    ("iat", JVal.uint64 now),
    ("exp", JVal.uint64 exp)
  ])
  let hdrB64 := base64Encode headerJson.toUTF8 true false
  let clmB64 := base64Encode claimsJson.toUTF8 true false
  let signingInput := s!"{hdrB64}.{clmB64}"
  let sigBytes := LeanSys.Auth.hmacSha256Bytes secret.toUTF8 signingInput.toUTF8
  let sigB64 := base64Encode sigBytes true false
  return s!"{signingInput}.{sigB64}"

structure AutomationServer where
  missionId : String
  apiUrl    : String
  apiToken? : Option String

def toolDefinitions : Array JVal := #[
  .obj #[
    ("name", .str "list_automations"),
    ("description", .str "List all automations for the current mission"),
    ("inputSchema", .obj #[
      ("type", .str "object"),
      ("properties", .obj #[
        ("active_only", .obj #[("type", .str "boolean"), ("description", .str "Only return active automations (default: false)")])
      ])
    ])
  ],
  .obj #[
    ("name", .str "create_automation"),
    ("description", .str
      ("Create a scheduled automation. IMPORTANT — use exactly this JSON structure:\n" ++
       "{\n  \"command_source\": { \"type\": \"inline\", \"content\": \"your prompt here\" },\n" ++
       "  \"trigger\": { \"type\": \"cron\", \"expression\": \"0 8 * * *\", \"timezone\": \"Europe/Paris\" },\n" ++
       "  \"fresh_session\": \"always\"\n}\n" ++
       "Trigger types: cron (expression + timezone), interval (seconds), durable_job_terminal (job_id).\n" ++
       "Command source types: inline (content), local_file (path).\n" ++
       "Cron examples: '0 8 * * *' daily 8am, '0 9 * * 1' Mon 9am, '*/30 * * * *' every 30min.")),
    ("inputSchema", .obj #[
      ("type", .str "object"),
      ("required", .arr #[.str "command_source", .str "trigger"]),
      ("properties", .obj #[
        ("command_source", .obj #[
          ("type", .str "object"),
          ("description", .str "Command to execute. Use {\"type\": \"inline\", \"content\": \"prompt text\"} for inline prompts."),
          ("properties", .obj #[
            ("type", .obj #[("type", .str "string"), ("description", .str "One of: inline, local_file")]),
            ("content", .obj #[("type", .str "string"), ("description", .str "The prompt/command text (when type=inline)")]),
            ("path", .obj #[("type", .str "string"), ("description", .str "File path (when type=local_file)")])
          ]),
          ("required", .arr #[.str "type"])
        ]),
        ("trigger", .obj #[
          ("type", .str "object"),
          ("description", .str "When to trigger. Use {\"type\": \"cron\", \"expression\": \"0 8 * * *\", \"timezone\": \"Europe/Paris\"} for cron schedules."),
          ("properties", .obj #[
            ("type", .obj #[("type", .str "string"), ("description", .str "One of: cron, interval, durable_job_terminal, agent_finished, webhook")]),
            ("expression", .obj #[("type", .str "string"), ("description", .str "Cron expression: minute hour day-of-month month day-of-week (when type=cron)")]),
            ("timezone", .obj #[("type", .str "string"), ("description", .str "IANA timezone like Europe/Paris (when type=cron, defaults to UTC)")]),
            ("seconds", .obj #[("type", .str "number"), ("description", .str "Interval in seconds (when type=interval)")]),
            ("job_id", .obj #[("type", .str "string"), ("description", .str "Durable job UUID owned by this mission (when type=durable_job_terminal)")])
          ]),
          ("required", .arr #[.str "type"])
        ]),
        ("fresh_session", .obj #[
          ("type", .str "string"),
          ("enum", .arr #[.str "keep", .str "always", .str "switch"]),
          ("description", .str "Use 'always' for scheduled tasks (fresh context each run). Default: keep.")
        ]),
        ("variables", .obj #[
          ("type", .str "object"),
          ("description", .str "Optional variable substitutions"),
          ("additionalProperties", .obj #[("type", .str "string")])
        ]),
        ("stop_policy", .obj #[
          ("type", .str "object"),
          ("description", .str "Optional lifecycle policy. One-shot durable wakeups use {\"type\":\"after_first_fire\"}."),
          ("properties", .obj #[
            ("type", .obj #[
              ("type", .str "string"),
              ("enum", .arr #[.str "never", .str "when_failing_consecutively", .str "when_all_issues_closed_and_prs_merged", .str "after_first_fire"])
            ]),
            ("count", .obj #[("type", .str "integer"), ("minimum", JVal.nat 1)]),
            ("repo", .obj #[("type", .str "string")])
          ]),
          ("required", .arr #[.str "type"])
        ])
      ])
    ])
  ],
  .obj #[
    ("name", .str "update_automation"),
    ("description", .str "Update an existing automation"),
    ("inputSchema", .obj #[
      ("type", .str "object"),
      ("required", .arr #[.str "id"]),
      ("properties", .obj #[
        ("id", .obj #[("type", .str "string"), ("description", .str "Automation ID to update")]),
        ("command_source", .obj #[("type", .str "object"), ("description", .str "New command source (optional)")]),
        ("trigger", .obj #[("type", .str "object"), ("description", .str "New trigger configuration (optional)")]),
        ("variables", .obj #[
          ("type", .str "object"),
          ("description", .str "New variables (optional)"),
          ("additionalProperties", .obj #[("type", .str "string")])
        ]),
        ("retry_config", .obj #[("type", .str "object"), ("description", .str "New retry configuration (optional)")]),
        ("stop_policy", .obj #[
          ("type", .str "object"),
          ("description", .str "New lifecycle policy (optional)"),
          ("properties", .obj #[
            ("type", .obj #[
              ("type", .str "string"),
              ("enum", .arr #[.str "never", .str "when_failing_consecutively", .str "when_all_issues_closed_and_prs_merged", .str "after_first_fire"])
            ]),
            ("count", .obj #[("type", .str "integer"), ("minimum", JVal.nat 1)]),
            ("repo", .obj #[("type", .str "string")])
          ]),
          ("required", .arr #[.str "type"])
        ]),
        ("fresh_session", .obj #[
          ("type", .str "string"),
          ("enum", .arr #[.str "keep", .str "always", .str "switch"]),
          ("description", .str "New session policy (optional)")
        ]),
        ("active", .obj #[("type", .str "boolean"), ("description", .str "Enable or disable automation")])
      ])
    ])
  ],
  .obj #[
    ("name", .str "delete_automation"),
    ("description", .str "Delete an automation"),
    ("inputSchema", .obj #[
      ("type", .str "object"),
      ("required", .arr #[.str "id"]),
      ("properties", .obj #[("id", .obj #[("type", .str "string"), ("description", .str "Automation ID to delete")])])
    ])
  ],
  .obj #[
    ("name", .str "get_execution_history"),
    ("description", .str "Get execution history for automations in this mission"),
    ("inputSchema", .obj #[
      ("type", .str "object"),
      ("properties", .obj #[
        ("automation_id", .obj #[("type", .str "string"), ("description", .str "Filter by specific automation ID (optional)")]),
        ("limit", .obj #[("type", .str "number"), ("description", .str "Maximum number of executions to return (default: 20)")])
      ])
    ])
  ],
  .obj #[
    ("name", .str "schedule_wakeup"),
    ("description", .str
      ("Schedule a one-shot wake-up that delivers `prompt` back into this mission after `delaySeconds`. " ++
       "Use this when you need to pause and resume work at a wall-clock time. For builds and other durable " ++
       "jobs, use schedule_job_wakeup instead. The wake-up fires exactly once and then auto-disables — " ++
       "call schedule_wakeup again from the resumed turn to keep looping. delaySeconds is clamped to [60, 3600].")),
    ("inputSchema", .obj #[
      ("type", .str "object"),
      ("required", .arr #[.str "delaySeconds", .str "prompt", .str "reason"]),
      ("properties", .obj #[
        ("request_id", .obj #[("type", .str "string"), ("description", .str "Stable unique request ID; reuse for retries of this same request.")]),
        ("delaySeconds", .obj #[
          ("type", .str "integer"),
          ("minimum", JVal.nat wakeupMinSeconds),
          ("maximum", JVal.nat wakeupMaxSeconds),
          ("description", .str "Seconds from now to wake up. Clamped to [60, 3600].")
        ]),
        ("prompt", .obj #[("type", .str "string"), ("description", .str "The message delivered to the mission when the wake-up fires.")]),
        ("reason", .obj #[("type", .str "string"), ("description", .str "One short sentence explaining the chosen delay (for telemetry / UI).")])
      ])
    ])
  ],
  .obj #[
    ("name", .str "schedule_job_wakeup"),
    ("description", .str
      ("Wake this mission exactly once when one of its durable jobs becomes terminal. " ++
       "Prefer this over repeated schedule_wakeup polling for builds, benchmark runs, test suites, " ++
       "and other long compute. The wakeup survives API restarts and fires for completed, failed, " ++
       "cancelled, unknown, or otherwise dead jobs.")),
    ("inputSchema", .obj #[
      ("type", .str "object"),
      ("required", .arr #[.str "jobId", .str "prompt", .str "reason"]),
      ("properties", .obj #[
        ("request_id", .obj #[("type", .str "string"), ("description", .str "Stable unique request ID; reuse for retries of this same request.")]),
        ("jobId", .obj #[("type", .str "string"), ("description", .str "Durable job UUID returned by the durable job launcher.")]),
        ("prompt", .obj #[("type", .str "string"), ("description", .str "Message delivered after the job becomes terminal.")]),
        ("reason", .obj #[("type", .str "string"), ("description", .str "Short telemetry/UI explanation.")])
      ])
    ])
  ]
]

private def handleToolCall (srv : AutomationServer) (toolName : String) (params : JVal) : IO (Except String JVal) := do
  let args := if params.isNull then JVal.obj #[] else params
  match toolName with
  | "list_automations" =>
    let activeOnly := (args.fieldBool? "active_only").getD false
    let url := s!"{srv.apiUrl}/api/control/missions/{srv.missionId}/automations"
    match (← sendJsonRequest "GET" url srv.apiToken? none) with
    | .error e => return .error s!"HTTP request failed: {e}"
    | .ok (status, _, j?) =>
      if status < 200 || status ≥ 300 then return .error s!"API returned error: {status}"
      let some (.arr xs) := j? | return .error "Failed to parse response"
      let filtered := if activeOnly then xs.filter (fun a => a.fieldBool? "active" == some true) else xs
      return .ok (.arr filtered)
  | "create_automation" =>
    let some cmdSrc := args.field? "command_source" | return .error "Invalid params: missing command_source"
    let some trig := args.field? "trigger" | return .error "Invalid params: missing trigger"
    let payload := JVal.obj #[
      ("command_source", cmdSrc),
      ("trigger", trig),
      ("variables", (args.field? "variables").getD (.obj #[])),
      ("retry_config", args.fieldOrNull "retry_config"),
      ("stop_policy", args.fieldOrNull "stop_policy"),
      ("fresh_session", args.fieldOrNull "fresh_session")
    ]
    let url := s!"{srv.apiUrl}/api/control/missions/{srv.missionId}/automations"
    match (← sendJsonRequest "POST" url srv.apiToken? (some payload)) with
    | .error e => return .error s!"HTTP request failed: {e}"
    | .ok (status, bodyTxt, j?) =>
      if status < 200 || status ≥ 300 then return .error s!"API returned error: {bodyTxt}"
      let some j := j? | return .error "Failed to parse response"
      return .ok j
  | "update_automation" =>
    let some rawId := args.fieldStr? "id" | return .error "Invalid params: missing id"
    let some autoId := parseUuidCanonical? rawId | return .error "Invalid automation ID format"
    let payload := JVal.obj #[
      ("command_source", args.fieldOrNull "command_source"),
      ("trigger", args.fieldOrNull "trigger"),
      ("variables", args.fieldOrNull "variables"),
      ("retry_config", args.fieldOrNull "retry_config"),
      ("stop_policy", args.fieldOrNull "stop_policy"),
      ("fresh_session", args.fieldOrNull "fresh_session"),
      ("active", args.fieldOrNull "active")
    ]
    let url := s!"{srv.apiUrl}/api/control/automations/{autoId}"
    match (← sendJsonRequest "PATCH" url srv.apiToken? (some payload)) with
    | .error e => return .error s!"HTTP request failed: {e}"
    | .ok (status, bodyTxt, _) =>
      if status < 200 || status ≥ 300 then return .error s!"API returned error: {bodyTxt}"
      return .ok (.obj #[("success", .bool true)])
  | "delete_automation" =>
    let some rawId := args.fieldStr? "id" | return .error "Invalid params: missing id"
    let some autoId := parseUuidCanonical? rawId | return .error "Invalid automation ID format"
    let url := s!"{srv.apiUrl}/api/control/automations/{autoId}"
    match (← sendJsonRequest "DELETE" url srv.apiToken? none) with
    | .error e => return .error s!"HTTP request failed: {e}"
    | .ok (status, bodyTxt, _) =>
      if status < 200 || status ≥ 300 then return .error s!"API returned error: {bodyTxt}"
      return .ok (.obj #[("success", .bool true)])
  | "get_execution_history" =>
    let limit := (args.fieldNat? "limit").getD 20
    let url ← match args.fieldStr? "automation_id" with
      | some rawId =>
        let some autoId := parseUuidCanonical? rawId | return .error "Invalid automation ID format"
        pure s!"{srv.apiUrl}/api/control/automations/{autoId}/executions?limit={limit}"
      | none =>
        pure s!"{srv.apiUrl}/api/control/missions/{srv.missionId}/automation-executions?limit={limit}"
    match (← sendJsonRequest "GET" url srv.apiToken? none) with
    | .error e => return .error s!"HTTP request failed: {e}"
    | .ok (status, _, j?) =>
      if status < 200 || status ≥ 300 then return .error s!"API returned error: {status}"
      let some j := j? | return .error "Failed to parse response"
      return .ok j
  | "schedule_wakeup" =>
    let delayRaw? := (args.fieldNat? "delaySeconds").orElse (fun _ => args.fieldNat? "delay_seconds")
    let some delayRaw := delayRaw? | return .error "Invalid params: missing delaySeconds"
    let some prompt := args.fieldStr? "prompt" | return .error "Invalid params: missing prompt"
    let some reason := args.fieldStr? "reason" | return .error "Invalid params: missing reason"
    let delay := Nat.min wakeupMaxSeconds (Nat.max wakeupMinSeconds delayRaw)
    let reqId ← match args.fieldStr? "request_id" with
      | some rid => pure rid
      | none => newUuidV4
    let body := JVal.obj #[
      ("command_source", .obj #[("type", .str "inline"), ("content", .str prompt)]),
      ("trigger", .obj #[("type", .str "interval"), ("seconds", JVal.nat delay)]),
      ("stop_policy", .obj #[("type", .str "after_first_fire")]),
      ("fresh_session", .str "keep"),
      ("variables", .obj #[
        ("__wakeup_request_id", .str reqId),
        ("__wakeup_reason", .str reason),
        ("__wakeup_source", .str "automation-manager")
      ]),
      ("start_immediately", .bool false)
    ]
    let url := s!"{srv.apiUrl}/api/control/missions/{srv.missionId}/automations"
    match (← sendJsonRequest "POST" url srv.apiToken? (some body)) with
    | .error e => return .error s!"HTTP request failed: {e}"
    | .ok (status, bodyTxt, j?) =>
      if status < 200 || status ≥ 300 then return .error s!"API returned error: {bodyTxt}"
      let some autoObj := j? | return .error "Failed to parse response"
      return .ok (.obj #[
        ("automation_id", autoObj.fieldOrNull "id"),
        ("delay_seconds", JVal.nat delay),
        ("reason", .str reason),
        ("fires_once", .bool true)
      ])
  | "schedule_job_wakeup" =>
    let jobRaw? := (args.fieldStr? "jobId").orElse (fun _ => args.fieldStr? "job_id")
    let some jobRaw := jobRaw? | return .error "Invalid params: missing jobId"
    let some jobId := parseUuidCanonical? jobRaw | return .error "Invalid durable job ID format"
    let some prompt := args.fieldStr? "prompt" | return .error "Invalid params: missing prompt"
    let some reason := args.fieldStr? "reason" | return .error "Invalid params: missing reason"
    let reqId ← match args.fieldStr? "request_id" with
      | some rid => pure rid
      | none => newUuidV4
    let body := JVal.obj #[
      ("command_source", .obj #[("type", .str "inline"), ("content", .str prompt)]),
      ("trigger", .obj #[("type", .str "durable_job_terminal"), ("job_id", .str jobId)]),
      ("stop_policy", .obj #[("type", .str "after_first_fire")]),
      ("fresh_session", .str "keep"),
      ("variables", .obj #[
        ("__wakeup_request_id", .str reqId),
        ("__wakeup_reason", .str reason),
        ("__wakeup_source", .str "durable-job-terminal")
      ]),
      ("start_immediately", .bool false)
    ]
    let url := s!"{srv.apiUrl}/api/control/missions/{srv.missionId}/automations"
    match (← sendJsonRequest "POST" url srv.apiToken? (some body)) with
    | .error e => return .error s!"HTTP request failed: {e}"
    | .ok (status, bodyTxt, j?) =>
      if status < 200 || status ≥ 300 then return .error s!"API returned error: {bodyTxt}"
      let some autoObj := j? | return .error "Failed to parse response"
      return .ok (.obj #[
        ("automation_id", autoObj.fieldOrNull "id"),
        ("job_id", .str jobId),
        ("reason", .str reason),
        ("fires_once", .bool true)
      ])
  | _ =>
    return .error s!"Unknown method: {toolName}"

def runMain (_args : List String) : IO UInt32 := do
  let some rawMid ← getEnvNonEmpty "MISSION_ID" | do
    IO.eprintln "automation-manager-mcp: MISSION_ID environment variable not set or invalid"
    return 1
  let some missionId := parseUuidCanonical? rawMid | do
    IO.eprintln "automation-manager-mcp: MISSION_ID environment variable not set or invalid"
    return 1
  let mut apiUrl := (← getEnvNonEmpty "API_URL").getD "http://127.0.0.1:3000"
  while apiUrl.endsWith "/" do
    apiUrl := (apiUrl.dropEnd 1).toString
  let apiToken? ← match (← getEnvNonEmpty "API_TOKEN") with
    | some t => pure (some t)
    | none =>
      match (← getEnvNonEmpty "JWT_SECRET") with
      | some sec =>
        let jwt ← mintServiceJwt sec
        pure (some jwt)
      | none => pure none
  let srv : AutomationServer := { missionId, apiUrl, apiToken? }
  serveStdio fun req _cancelRef => do
    let idVal := req.fieldOrNull "id"
    let method := (req.fieldStr? "method").getD ""
    match method with
    | "initialize" =>
      return jsonRpcSuccess idVal (.obj #[
        ("protocolVersion", .str "2024-11-05"),
        ("serverInfo", .obj #[("name", .str "automation-manager"), ("version", .str "0.1.0")]),
        ("capabilities", .obj #[("tools", .obj #[])])
      ])
    | "ping" =>
      return jsonRpcSuccess idVal (.obj #[])
    | "tools/list" =>
      return jsonRpcSuccess idVal (.obj #[("tools", .arr toolDefinitions)])
    | "tools/call" =>
      let some params := req.field? "params" | return jsonRpcError idVal (-32602) "Invalid params"
      if params.asObj?.isNone then return jsonRpcError idVal (-32602) "Invalid params"
      let some toolName := params.fieldStr? "name" | return jsonRpcError idVal (-32602) "Missing tool name"
      let arguments := (params.field? "arguments").getD .null
      match (← handleToolCall srv toolName arguments) with
      | .ok resJson =>
        return jsonRpcSuccess idVal (.obj #[
          ("content", .arr #[.obj #[("type", .str "text"), ("text", .str (renderPretty resJson))]])
        ])
      | .error e =>
        return jsonRpcError idVal (-32000) e
    | _ =>
      return jsonRpcError idVal (-32601) s!"Unknown method: {method}"
  return 0

end OrbBin.AutomationMcp
