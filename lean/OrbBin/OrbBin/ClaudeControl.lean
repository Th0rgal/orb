/-
  OrbBin.ClaudeControl: Shared Pure-Lean Warm Claude Code Bidirectional Stdio Control Driver,
  Permission Mode Protocol (`supervised` / `acceptEdits` / `auto` / `bypassPermissions`),
  Local CLI Harness Discovery (`local_agents_scan`, `local_claude_models`, `local_antigravity_models`),
  and Multi-Harness Execution Supervisor (`claudecode`, `codex`, `opencode`, `antigravity`, `grok`, `vibe`)
  (`0 import Lean`, `0 sorryAx`).
-/
import Std
import Orb.Kernel
import OrbBin.Json
import OrbBin.PosixExt
import OrbBin.GitWorkspace

namespace OrbBin.ClaudeControl

open OrbBin.Json
open OrbBin.PosixExt
open OrbBin.GitWorkspace

/-- Supported native Claude Code permission modes over stdio control protocol. -/
inductive ClaudePermissionMode where
  | supervised        -- CLI `"default"`, prompts via `can_use_tool` stdio for mutating/shell tools
  | acceptEdits       -- CLI `"acceptEdits"`, auto-approves file edits, prompts for shell/destructive
  | auto              -- CLI `"auto"`
  | bypassPermissions -- CLI `"bypassPermissions"` (`full-access`)
  | plan              -- CLI `"plan"`, read-only planning until `ExitPlanMode`
  deriving Repr, BEq, DecidableEq, Inhabited

/-- Parse UI/RPC permission mode string into `ClaudePermissionMode`. -/
def parsePermissionMode (raw : String) : ClaudePermissionMode :=
  match raw.trimAscii.toString with
  | "supervised" | "default" => .supervised
  | "acceptEdits" | "auto-edit" | "autoEdit" => .acceptEdits
  | "auto" => .auto
  | "plan" => .plan
  | "bypassPermissions" | "full-access" | "fullAccess" => .bypassPermissions
  | _ => .bypassPermissions

/-- Canonical CLI `--permission-mode` wire value for Claude Code. -/
def ClaudePermissionMode.toCliWire : ClaudePermissionMode → String
  | .supervised        => "default"
  | .acceptEdits       => "acceptEdits"
  | .auto              => "auto"
  | .bypassPermissions => "bypassPermissions"
  | .plan              => "plan"

/-- Canonical UI label key (`supervised`, `acceptEdits`, `auto`, `bypassPermissions`, `plan`). -/
def ClaudePermissionMode.toUiWire : ClaudePermissionMode → String
  | .supervised        => "supervised"
  | .acceptEdits       => "acceptEdits"
  | .auto              => "auto"
  | .bypassPermissions => "bypassPermissions"
  | .plan              => "plan"

/-- Build CLI arguments for a warm bidirectional Claude Code process. -/
def buildWarmClaudeArgs
    (mode : ClaudePermissionMode)
    (model? : Option String := none)
    (effort? : Option String := none)
    (sessionId : String := "")
    (resumeExisting : Bool := false) : Array String := Id.run do
  let mut args : Array String := #[
    "--print",
    "--input-format", "stream-json",
    "--output-format", "stream-json",
    "--permission-prompt-tool", "stdio",
    "--verbose",
    "--include-partial-messages",
    "--disallowedTools", "CronCreate,CronDelete,CronList"
  ]
  match mode with
  | .bypassPermissions =>
    args := args.push "--dangerously-skip-permissions"
  | .plan =>
    args := args ++ #["--allow-dangerously-skip-permissions", "--permission-mode", "plan"]
  | other =>
    args := args ++ #["--allow-dangerously-skip-permissions", "--permission-mode", other.toCliWire]
  if let some rawModel := model?.map (·.trimAscii.toString) |>.filter (!·.isEmpty) then
    let bare := if rawModel.startsWith "anthropic/" then (rawModel.drop 10).toString else rawModel
    args := args ++ #["--model", bare]
  if let some eff := effort?.map (·.trimAscii.toString) |>.filter (!·.isEmpty) then
    args := args ++ #["--effort", eff]
  let cleanSid := sessionId.trimAscii.toString
  if !cleanSid.isEmpty then
    if resumeExisting then
      args := args ++ #["--resume", cleanSid]
    else
      args := args ++ #["--session-id", cleanSid]
  return args

/-- Encode the initial `initialize` control handshake frame written to Claude's stdin. -/
def encodeInitializeRequest (reqId : String := "orb-init") : String :=
  renderCompact (.obj #[
    ("type", .str "control_request"),
    ("request_id", .str reqId),
    ("request", .obj #[("subtype", .str "initialize")])
  ])

/-- Encode a mid-session `set_permission_mode` control request frame for Claude's stdin. -/
def encodeSetPermissionModeRequest (reqId : String) (mode : ClaudePermissionMode) : String :=
  renderCompact (.obj #[
    ("type", .str "control_request"),
    ("request_id", .str reqId),
    ("request", .obj #[
      ("subtype", .str "set_permission_mode"),
      ("mode", .str mode.toCliWire)
    ])
  ])

/-- Encode a mid-session `set_model` control request frame for Claude's stdin. -/
def encodeSetModelRequest (reqId : String) (model : String) : String :=
  let bare := if model.startsWith "anthropic/" then (model.drop 10).toString else model
  renderCompact (.obj #[
    ("type", .str "control_request"),
    ("request_id", .str reqId),
    ("request", .obj #[
      ("subtype", .str "set_model"),
      ("model", .str bare)
    ])
  ])

/-- Guess MIME media type from file path extension for base64 image blocks. -/
private def guessImageMediaType (path : String) : String :=
  let low := path.toLower
  if low.endsWith ".png" then "image/png"
  else if low.endsWith ".webp" then "image/webp"
  else if low.endsWith ".gif" then "image/gif"
  else "image/jpeg"

/-- Encode a user message frame (`{"type":"user","message":{"role":"user","content":...}}`) for warm Claude stdin. -/
def encodeClaudeUserTurn (prompt : String) (imageBlocks : Array (String × String) := #[]) : String :=
  if imageBlocks.isEmpty then
    renderCompact (.obj #[
      ("type", .str "user"),
      ("message", .obj #[
        ("role", .str "user"),
        ("content", .str prompt)
      ])
    ])
  else
    let imgJvs : Array JVal := imageBlocks.map fun (mediaType, b64) =>
      .obj #[
        ("type", .str "image"),
        ("source", .obj #[
          ("type", .str "base64"),
          ("media_type", .str mediaType),
          ("data", .str b64)
        ])
      ]
    let blocks := imgJvs.push (.obj #[("type", .str "text"), ("text", .str prompt)])
    renderCompact (.obj #[
      ("type", .str "user"),
      ("message", .obj #[
        ("role", .str "user"),
        ("content", .arr blocks)
      ])
    ])

/-- Structured interactive request surfaced from Claude `control_request` (`can_use_tool`) to Desktop/iOS/Android. -/
structure PendingControlRequest where
  requestId    : String
  method       : String   -- "claude_questions" | "plan" | "permission"
  toolName     : String
  originalInput : JVal
  suggestions  : JVal := .arr #[]
  uiParams     : JVal
  deriving Repr, BEq, Inhabited

/-- Parse a Claude stdout JSON object into `some PendingControlRequest` if it is a `control_request` (`can_use_tool`). -/
def parseClaudeControlRequest? (ev : JVal) : Option PendingControlRequest := do
  guard ((ev.fieldStr? "type") == some "control_request")
  let reqId ← ev.fieldStr? "request_id"
  guard (!reqId.isEmpty)
  let reqObj := ev.fieldOrNull "request"
  guard ((reqObj.fieldStr? "subtype") == some "can_use_tool")
  let toolName := (reqObj.fieldStr? "tool_name").getD "Tool"
  let input := match reqObj.field? "input" with
    | some v => v
    | none => .obj #[]
  let suggestions := match reqObj.field? "permission_suggestions" with
    | some (.arr xs) => JVal.arr xs
    | _ => JVal.arr #[]
  if toolName == "AskUserQuestion" then
    return {
      requestId := reqId
      method := "claude_questions"
      toolName := toolName
      originalInput := input
      suggestions := suggestions
      uiParams := input
    }
  else if toolName == "ExitPlanMode" then
    return {
      requestId := reqId
      method := "plan"
      toolName := toolName
      originalInput := input
      suggestions := suggestions
      uiParams := input
    }
  else
    let uiParams := JVal.obj #[
      ("tool", .str toolName),
      ("input", input),
      ("suggestions", suggestions)
    ]
    return {
      requestId := reqId
      method := "permission"
      toolName := toolName
      originalInput := input
      suggestions := suggestions
      uiParams := uiParams
    }

/-- Insert or replace field `k` in a JSON object `jv`. -/
private def upsertJsonField (jv : JVal) (k : String) (v : JVal) : JVal :=
  match jv with
  | .obj fields =>
    let filtered := fields.filter (fun (fk, _) => fk != k)
    .obj (filtered.push (k, v))
  | _ => .obj #[(k, v)]

/-- Translate a UI interaction answer (`{answers}`, `{action: "accept"|"accept_session"|"revise", feedback?}`)
    into the exact Claude `control_response` NDJSON line, plus whether plan implementation mode was approved. -/
def buildClaudeControlResponse (pending : PendingControlRequest) (answer : JVal) : String × Bool :=
  let act := (answer.fieldStr? "action").getD "revise"
  let approvedPlan := pending.method == "plan" && (act == "accept" || act == "accept_session")
  let innerResp : JVal :=
    if pending.method == "claude_questions" then
      let answersVal := match answer.field? "answers" with
        | some a => a
        | none => .obj #[]
      let updated := upsertJsonField pending.originalInput "answers" answersVal
      .obj #[
        ("behavior", .str "allow"),
        ("updatedInput", updated)
      ]
    else if pending.method == "plan" then
      if approvedPlan then
        .obj #[
          ("behavior", .str "allow"),
          ("updatedInput", pending.originalInput)
        ]
      else
        let fb := ((answer.fieldStr? "feedback").filter (fun s => !s.trimAscii.toString.isEmpty)).getD "Please revise the plan."
        .obj #[
          ("behavior", .str "deny"),
          ("message", .str fb)
        ]
    else
      if act == "accept" then
        .obj #[
          ("behavior", .str "allow"),
          ("updatedInput", pending.originalInput)
        ]
      else if act == "accept_session" then
        let baseFields : Array (String × JVal) := #[
          ("behavior", .str "allow"),
          ("updatedInput", pending.originalInput)
        ]
        let withPerms := match pending.suggestions with
          | .arr xs =>
            if xs.isEmpty then
              -- Provide a session-scoped rule for this tool if Claude sent no explicit suggestions
              baseFields.push ("updatedPermissions", .arr #[
                .obj #[
                  ("type", .str "addRules"),
                  ("rules", .arr #[.obj #[("toolName", .str pending.toolName)]]),
                  ("behavior", .str "allow"),
                  ("destination", .str "session")
                ]
              ])
            else
              baseFields.push ("updatedPermissions", .arr xs)
          | _ => baseFields
        .obj withPerms
      else
        let fb := ((answer.fieldStr? "feedback").filter (fun s => !s.trimAscii.toString.isEmpty)).getD "The user declined this action."
        .obj #[
          ("behavior", .str "deny"),
          ("message", .str fb)
        ]
  let envelope := renderCompact (.obj #[
    ("type", .str "control_response"),
    ("response", .obj #[
      ("subtype", .str "success"),
      ("request_id", .str pending.requestId),
      ("response", innerResp)
    ])
  ])
  (envelope, approvedPlan)

/-- Live activity row mirroring `orb/src/localAgents.ts` (`LocalActivity`). -/
structure LocalActivityItem where
  id             : String
  label          : String
  done           : Bool := false
  failed         : Bool := false
  kind           : String := "command"
  background     : Bool := false
  toolUseId?     : Option String := none
  detail?        : Option String := none
  status         : String := "running"
  startedAt      : UInt64 := 0
  updatedAt      : UInt64 := 0
  finishedAt?    : Option UInt64 := none
  thinkingTokens? : Option UInt64 := none
  deriving Repr, BEq, Inhabited

def LocalActivityItem.toJVal (a : LocalActivityItem) : JVal := Id.run do
  let mut fields : Array (String × JVal) := #[
    ("id", .str a.id),
    ("label", .str a.label),
    ("done", .bool a.done),
    ("failed", .bool a.failed),
    ("kind", .str a.kind),
    ("background", .bool a.background),
    ("status", .str a.status),
    ("started_at", .nat a.startedAt.toNat),
    ("updated_at", .nat a.updatedAt.toNat)
  ]
  if let some tid := a.toolUseId? then fields := fields.push ("tool_use_id", .str tid)
  if let some det := a.detail? then fields := fields.push ("detail", .str det)
  if let some fin := a.finishedAt? then fields := fields.push ("finished_at", .nat fin.toNat)
  if let some tok := a.thinkingTokens? then fields := fields.push ("thinking_tokens", .nat tok.toNat)
  return .obj fields

/-- Snapshot of a local or Core-managed CLI run matching `PollLocal` in `orb/src/localAgents.ts`. -/
structure LocalRunState where
  runId          : String
  generation     : UInt64
  harness        : String
  cwd            : String
  worktreePath?  : Option String := none
  permissionMode : ClaudePermissionMode := .bypassPermissions
  text           : String := ""
  done           : Bool := false
  resumed        : Bool := false
  stopping       : Bool := false
  exitCode?      : Option Int := none
  sessionId?     : Option String := none
  error?         : Option String := none
  retryable      : Bool := false
  activities     : Array LocalActivityItem := #[]
  turnCount      : Nat := 0
  deriving Repr, BEq, Inhabited

def LocalRunState.toPollJVal (s : LocalRunState) : JVal := Id.run do
  let mut fields : Array (String × JVal) := #[
    ("text", .str s.text),
    ("done", .bool s.done),
    ("resumed", .bool s.resumed),
    ("activities", .arr (s.activities.map LocalActivityItem.toJVal))
  ]
  if s.stopping then fields := fields.push ("stopping", .bool true)
  if s.retryable then fields := fields.push ("retryable", .bool true)
  match s.exitCode? with
  | some c => fields := fields.push ("exit_code", .int c)
  | none   => fields := fields.push ("exit_code", .null)
  match s.sessionId? with
  | some sid => fields := fields.push ("session_id", .str sid)
  | none     => fields := fields.push ("session_id", .null)
  match s.error? with
  | some err => fields := fields.push ("error", .str err)
  | none     => fields := fields.push ("error", .null)
  if let some wt := s.worktreePath? then
    fields := fields.push ("worktree_path", .str wt)
  fields := fields.push ("permission_mode", .str s.permissionMode.toUiWire)
  return .obj fields

/-- Format human-readable model label from a Claude model ID (`claude-sonnet-5-5` -> `Claude Sonnet 5.5`). -/
def formatClaudeModelDisplayName (id : String) : String := Id.run do
  let body := if id.startsWith "claude-" then (id.drop 7).toString else id
  let mut words : Array String := #[]
  let mut vers : Array String := #[]
  for part in body.splitOn "-" do
    if part.length >= 8 && part.toList.all Char.isDigit then
      break
    else if !part.isEmpty && part.toList.all Char.isDigit then
      vers := vers.push part
    else if !part.isEmpty then
      let cs := part.toList
      let cap := String.ofList (cs.head!.toUpper :: cs.tail!)
      words := words.push cap
  let base := if words.isEmpty then "Claude" else "Claude " ++ String.intercalate " " words.toList
  return if vers.isEmpty then base else base ++ " " ++ String.intercalate "." vers.toList

private def isValidClaudeModelId (s : String) : Bool :=
  s.startsWith "claude-" && s.length > 7 && s.length <= 100 &&
  s.toList.all (fun c => c.isLower || c.isDigit || c == '-')

private def claudeClassAndVersion (modelId : String) : String × Array Nat := Id.run do
  let body := if modelId.startsWith "claude-" then (modelId.drop 7).toString else modelId
  let mut words : Array String := #[]
  let mut vers : Array Nat := #[]
  for part in body.splitOn "-" do
    if part.length >= 8 && part.toList.all Char.isDigit then
      break
    else if let some n := part.toNat? then
      vers := vers.push n
    else if !part.isEmpty then
      words := words.push part
  return (String.intercalate "-" words.toList, vers)

private def versionArrGt (a b : Array Nat) : Bool := Id.run do
  let n := Nat.max a.size b.size
  for i in [0:n] do
    let va := (a[i]?).getD 0
    let vb := (b[i]?).getD 0
    if va != vb then return va > vb
  return false

private def claudeClassRank (cls : String) : Nat :=
  match cls with
  | "opus"   => 0
  | "fable"  => 1
  | "mythos" => 2
  | "sonnet" => 3
  | "haiku"  => 4
  | _        => 5

/-- Extract `(modelId, displayLabel)` pairs from Claude's `control_response` to `initialize`.
    Deduplicates to the newest release per Claude model class (including exact `claude-*` entries
    without a short alias such as `claude-mythos-5-2`) and always orders Opus first so Fable is
    never selected by default. -/
def parseClaudeInitializeModels? (jv : JVal) (expectedReqId : String := "orb-model-discovery") : Option (Array (String × String)) := do
  guard ((jv.fieldStr? "type") == some "control_response")
  let resp := jv.fieldOrNull "response"
  guard ((resp.fieldStr? "request_id") == some expectedReqId)
  let inner := match resp.field? "response" with
    | some r => r
    | none => resp
  let modelsArr ← inner.fieldArr? "models"
  let mut byClass : Array (String × Array Nat × String) := #[]
  for entry in modelsArr do
    let rawVal := (entry.fieldStr? "value").getD ""
    if !rawVal.isEmpty && rawVal != "default" then
      let cand? : Option String :=
        match entry.fieldStr? "resolvedModel" with
        | some resolved => if isValidClaudeModelId resolved then some resolved else if isValidClaudeModelId rawVal then some rawVal else none
        | none => if isValidClaudeModelId rawVal then some rawVal else none
      if let some modelId := cand? then
        let (cls, ver) := claudeClassAndVersion modelId
        if !cls.isEmpty then
          match byClass.findIdx? (fun (c, _, _) => c == cls) with
          | none => byClass := byClass.push (cls, ver, modelId)
          | some idx =>
            let (_, prevVer, _) := byClass[idx]!
            if versionArrGt ver prevVer then
              byClass := byClass.set! idx (cls, ver, modelId)
  let sorted := byClass.qsort fun (c1, _, m1) (c2, _, m2) =>
    let r1 := claudeClassRank c1
    let r2 := claudeClassRank c2
    if r1 != r2 then r1 < r2 else m1 < m2
  return sorted.map fun (_, _, modelId) => (modelId, formatClaudeModelDisplayName modelId)

/-- Group Antigravity Carbon (`gemini-4-carbon-{low,medium,high}` / legacy `agy-model-{low,medium,high}`)
    and Argon (`gemini-4-argon-{low,medium,high}` / legacy `agy-demo-{low,medium,high}`) variants into base `(id, label)` pairs. -/
def groupAntigravityModels (raw : Array (String × String)) : Array (String × String) := Id.run do
  let mut seen : Array String := #[]
  let mut out : Array (String × String) := #[]
  for (rawId, rawLabel) in raw do
    let grouped? : Option (String × String) :=
      if rawId.startsWith "gemini-4-carbon-" then
        let lvl := (rawId.drop 16).toString
        if lvl == "low" || lvl == "medium" || lvl == "high" then some ("gemini-4-carbon", lvl) else none
      else if rawId.startsWith "agy-model-" then
        let lvl := (rawId.drop 10).toString
        if lvl == "low" || lvl == "medium" || lvl == "high" then some ("gemini-4-carbon", lvl) else none
      else if rawId.startsWith "gemini-4-argon-" then
        let lvl := (rawId.drop 15).toString
        if lvl == "low" || lvl == "medium" || lvl == "high" then some ("gemini-4-argon", lvl) else none
      else if rawId.startsWith "agy-demo-" then
        let lvl := (rawId.drop 9).toString
        if lvl == "low" || lvl == "medium" || lvl == "high" then some ("gemini-4-argon", lvl) else none
      else none
    let (id, label) := match grouped? with
      | some (base, lvl) =>
        let suf := if lvl == "low" then " (Low)" else if lvl == "medium" then " (Medium)" else " (High)"
        let stripped := if rawLabel.endsWith suf then (rawLabel.dropEnd suf.length).toString else rawLabel
        (base, stripped)
      | none => (rawId, rawLabel)
    if !seen.contains id then
      seen := seen.push id
      out := out.push (id, label)
  return out

/-- Resolve an executable binary path from an optional override, `PATH`, and standard macOS/Linux user bin locations. -/
def resolveHarnessBinary? (binName : String) (overridePath? : Option String := none) : IO (Option String) := do
  if let some rawOv := overridePath? then
    let ov := rawOv.trimAscii.toString
    if !ov.isEmpty then
      if (← System.FilePath.pathExists (System.FilePath.mk ov)) then
        return some ov
      else
        return none
  let home := ((← IO.getEnv "HOME").getD "").trimAscii.toString
  let pathEnv := ((← IO.getEnv "PATH").getD "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin").trimAscii.toString
  let mut dirs : Array String := (pathEnv.splitOn ":").filter (!·.isEmpty) |>.toArray
  if !home.isEmpty then
    for extra in #[s!"{home}/.local/bin", s!"{home}/.claude/local", s!"{home}/.bun/bin", s!"{home}/.npm-global/bin", s!"{home}/.cargo/bin"] do
      if !dirs.contains extra then dirs := dirs.push extra
  for extraSys in #["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"] do
    if !dirs.contains extraSys then dirs := dirs.push extraSys
  for d in dirs do
    let cand := if d.endsWith "/" then s!"{d}{binName}" else s!"{d}/{binName}"
    if (← System.FilePath.pathExists cand) then
      let stMeta ← lstatInfo cand
      -- bit 0 = exists, ensure not directory (S_IFDIR check via pathExists + file check)
      if stMeta != 0 && !(← System.FilePath.isDir cand) then
        return some cand
  return none

/-- Probe `--version` quickly (bounded output) for an installed binary. -/
private def probeBinaryVersion? (binPath : String) : IO (Option String) := do
  match ← (IO.Process.output {
    cmd := binPath
    args := #["--version"]
    env := #[("CI", some "1"), ("NO_COLOR", some "1")]
  }).toBaseIO with
  | .error _ => return none
  | .ok out =>
    let raw := if !out.stdout.trimAscii.toString.isEmpty then out.stdout else out.stderr
    let firstLine := ((raw.splitOn "\n").headD "").trimAscii.toString
    return if firstLine.isEmpty then none else some ((firstLine.take 80).toString)

/-- Drain complete `\n`-delimited lines from a `ByteArray` accumulator without panicking when multi-byte UTF-8 sequences split across pipe reads. -/
private def drainNewlineByteLines (acc : ByteArray) : Array String × ByteArray := Id.run do
  let mut lines : Array String := #[]
  let mut start : Nat := 0
  for i in [0:acc.size] do
    if acc[i]! == 0x0A then
      let slice := acc.extract start i
      let decoded := (String.fromUTF8? slice).getD ""
      lines := lines.push decoded
      start := i + 1
  let rem := if start == 0 then acc else acc.extract start acc.size
  return (lines, rem)

/-- Discover Claude Code's available models via the zero-inference `initialize` control handshake. -/
def probeClaudeModels (binPath : String) : IO (Except String (Array (String × String))) := do
  if binPath.trimAscii.toString.isEmpty || !(← System.FilePath.pathExists binPath) then
    return .error "Claude Code is unavailable"
  let envPairs ← currentEnvPairs
  let mut envStrs : Array String := #[]
  for (k, v) in envPairs do
    if k != "CLAUDECODE" then
      envStrs := envStrs.push s!"{k}={v}"
  let args := #["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose"]
  let spawned ← match ← (spawnPgrp binPath args envStrs (pipeStdin := true) (nullStdio := true) (pipeStdout := true)).toBaseIO with
    | .error _ => return .error "Claude Code is unavailable"
    | .ok sp => pure sp
  let initLine := encodeInitializeRequest "orb-model-discovery" ++ "\n"
  let _ ← writeFdAll spawned.stdinFd initLine.toUTF8
  closeFdRaw spawned.stdinFd
  -- Read stdout lines for up to ~8 seconds
  let foundRef ← IO.mkRef (none : Option (Array (String × String)))
  let readerTask ← IO.asTask do
    let mut buf := ByteArray.empty
    let mut totalBytes : Nat := 0
    let mut keepReading := true
    while keepReading && totalBytes < 2 * 1024 * 1024 do
      match ← (readFdChunk spawned.stdoutFd 8192).toBaseIO with
      | .error _ => keepReading := false
      | .ok chunk =>
        if chunk.isEmpty then
          keepReading := false
        else
          totalBytes := totalBytes + chunk.size
          let (lines, rem) := drainNewlineByteLines (buf ++ chunk)
          buf := rem
          for ln in lines do
            let clean := ln.trimAscii.toString
            if !clean.isEmpty then
              if let .ok jv := OrbBin.Json.parse clean then
                if let some models := parseClaudeInitializeModels? jv "orb-model-discovery" then
                  foundRef.set (some models)
                  keepReading := false
  let mut waitedMs : Nat := 0
  while waitedMs < 8000 && (← foundRef.get).isNone && ! (← IO.hasFinished readerTask) do
    IO.sleep 50
    waitedMs := waitedMs + 50
  let _ ← killSig (-spawned.pid) 9
  closeFdRaw spawned.stdoutFd
  let _ ← waitpidBlock spawned.pid
  match ← foundRef.get with
  | some models =>
    if models.isEmpty then return .error "Claude Code listed no models"
    else return .ok models
  | none =>
    if waitedMs >= 8000 then return .error "Claude Code model discovery timed out"
    else return .error "Sign in with claude on this computer"

/-- Discover Antigravity (`agy`) models via `agy models`. -/
def probeAntigravityModels (binPath : String) : IO (Except String (Array (String × String))) := do
  if binPath.trimAscii.toString.isEmpty || !(← System.FilePath.pathExists binPath) then
    return .error "Antigravity CLI is not installed"
  match ← (IO.Process.output {
    cmd := binPath
    args := #["models"]
    env := #[("NO_COLOR", some "1")]
  }).toBaseIO with
  | .error _ => return .error "Antigravity model discovery failed"
  | .ok out =>
    if out.exitCode != 0 then
      return .error "Sign in with agy on this computer"
    let mut pairs : Array (String × String) := #[]
    for line in out.stdout.splitOn "\n" do
      let clean := (line.dropEndWhile (· == '\r')).toString
      let cols := clean.splitOn "\t"
      if h : cols.length >= 2 then
        let id := cols[0].trimAscii.toString
        let label := (String.intercalate "\t" cols.tail!).trimAscii.toString
        if !id.isEmpty && !label.isEmpty then
          pairs := pairs.push (id, label)
    let grouped := groupAntigravityModels pairs
    if grouped.isEmpty then
      return .error "No Antigravity models are available for this account"
    return .ok grouped

/-- Scan local agent CLIs (`claudecode`, `codex`, `opencode`, `antigravity`, `grok`, `vibe`) matching `ScanRow[]` in `orb/src/localAgents.ts`. -/
def scanInstalledHarnesses (overrides : JVal := .obj #[]) : IO JVal := do
  let specs : Array (String × String × Bool) := #[
    ("claudecode",  "claude",   true),
    ("codex",       "codex",    true),
    ("opencode",    "opencode", false),
    ("antigravity", "agy",      false),
    ("grok",        "grok",     false),
    ("vibe",        "vibe-acp", false)
  ]
  let mut rows : Array JVal := Array.mkEmpty specs.size
  for (id, defaultBin, planSupported) in specs do
    let ov? := overrides.fieldStr? id
    let path? ← resolveHarnessBinary? defaultBin ov?
    let (installed, ver?) ← match path? with
      | some p =>
        let v? ← probeBinaryVersion? p
        pure (true, v?)
      | none => pure (false, none)
    let mut modelsJv : Array JVal := #[]
    let mut authErr? : Option String := none
    if id == "antigravity" then
      if let some p := path? then
        match ← probeAntigravityModels p with
        | .ok ms => modelsJv := ms.map fun (mId, mLbl) => .arr #[.str mId, .str mLbl]
        | .error e => authErr? := some e
    rows := rows.push (.obj #[
      ("id", .str id),
      ("bin", .str defaultBin),
      ("path", match path? with | some p => .str p | none => .null),
      ("version", match ver? with | some v => .str v | none => .null),
      ("installed", .bool installed),
      ("plan_supported", .bool planSupported),
      ("models", .arr modelsJv),
      ("auth_error", match authErr? with | some e => .str e | none => .null)
    ])
  return .arr rows

/-- Callbacks fired asynchronously as a live harness session emits text deltas, activities, interactive requests, or turn completion. -/
structure HarnessCallbacks where
  onOutputEvent      : JVal → IO Unit := fun _ => pure ()
  onControlRequest   : PendingControlRequest → IO Unit := fun _ => pure ()
  onStructuredEvent  : String → JVal → IO Unit := fun _ _ => pure () -- `(eventType, payload)` for Core `mission_events`
  onTurnFinished     : LocalRunState → IO Unit := fun _ => pure ()

/-- Live warm Claude Code process entry held open across multiple conversational turns. -/
structure WarmClaudeEntry where
  missionId        : String
  binPath          : String
  cwd              : String
  pid              : Int64
  stdinFd          : Int32
  stdoutFd         : Int32
  writeMu          : Std.Mutex Unit
  aliveRef         : IO.Ref Bool
  pendingReqsRef   : IO.Ref (Array PendingControlRequest)
  implementPlanRef : IO.Ref Bool
  permissionModeRef : IO.Ref ClaudePermissionMode

/-- Shared manager supervising warm Claude Code processes and active one-shot CLI runs (`codex`, `opencode`, `antigravity`, `grok`, `vibe`). -/
structure WarmHarnessManager where
  mu           : Std.Mutex Unit
  runsRef      : IO.Ref (Array (String × IO.Ref LocalRunState))
  warmProcsRef : IO.Ref (Array (String × WarmClaudeEntry))
  activePidsRef : IO.Ref (Array (String × Int64))
  callbacksRef : IO.Ref (Array (String × HarnessCallbacks))

/-- Create a fresh `WarmHarnessManager`. -/
def newWarmHarnessManager : IO WarmHarnessManager := do
  return {
    mu := ← Std.Mutex.new ()
    runsRef := ← IO.mkRef #[]
    warmProcsRef := ← IO.mkRef #[]
    activePidsRef := ← IO.mkRef #[]
    callbacksRef := ← IO.mkRef #[]
  }

/-- Look up the current `LocalRunState` for `id`, if any. -/
def getRunState? (mgr : WarmHarnessManager) (id : String) : IO (Option LocalRunState) := do
  let runs ← mgr.runsRef.get
  match runs.find? (fun (k, _) => k == id) with
  | some (_, r) => some <$> r.get
  | none => pure none

/-- List working directories of all currently non-done runs except `excludeId`. -/
def activeRunCwdsExcept (mgr : WarmHarnessManager) (excludeId : String) : IO (Array String) := do
  let runs ← mgr.runsRef.get
  let mut out : Array String := #[]
  for (rid, ref) in runs do
    if rid != excludeId then
      let st ← ref.get
      if !st.done && !st.cwd.isEmpty then
        out := out.push st.cwd
  return out

private def getCallbacksFor (mgr : WarmHarnessManager) (id : String) : IO HarnessCallbacks := do
  let cbs ← mgr.callbacksRef.get
  return ((cbs.find? (fun (k, _) => k == id)).map Prod.snd).getD {}

private def setCallbacksFor (mgr : WarmHarnessManager) (id : String) (cb : HarnessCallbacks) : IO Unit := do
  mgr.mu.atomically do
    let prev ← mgr.callbacksRef.get
    let filtered := prev.filter (fun (k, _) => k != id)
    mgr.callbacksRef.set (filtered.push (id, cb))

private def upsertRunStateRef (mgr : WarmHarnessManager) (id : String) (init : LocalRunState) : IO (IO.Ref LocalRunState) := do
  mgr.mu.atomically do
    let runs ← mgr.runsRef.get
    match runs.find? (fun (k, _) => k == id) with
    | some (_, existingRef) =>
      existingRef.set init
      return existingRef
    | none =>
      let r ← IO.mkRef init
      mgr.runsRef.set (runs.push (id, r))
      return r

/-- Write a single NDJSON line atomically to a warm Claude stdin pipe. -/
private def writeWarmStdinLine (entry : WarmClaudeEntry) (jsonLine : String) : IO Bool := do
  entry.writeMu.atomically do
    if !(← entry.aliveRef.get) then
      return false
    let bytes := (jsonLine ++ "\n").toUTF8
    let rc ← writeFdAll entry.stdinFd bytes
    if rc != 0 then
      entry.aliveRef.set false
      return false
    return true

/-- Answer a pending interactive `control_request` (`AskUserQuestion`, `ExitPlanMode`, or tool `permission`) on `id`. -/
def respondToControlRequest
    (mgr : WarmHarnessManager)
    (id : String)
    (requestId : String)
    (answer : JVal) : IO Bool := do
  let warm? ← mgr.mu.atomically do
    let ws ← mgr.warmProcsRef.get
    pure ((ws.find? (fun (k, _) => k == id)).map Prod.snd)
  let some entry := warm?
    | return false
  let pending? ← entry.writeMu.atomically do
    let ps ← entry.pendingReqsRef.get
    let matched? := ps.find? (fun p => p.requestId == requestId)
    if let some m := matched? then
      entry.pendingReqsRef.set (ps.filter (fun p => p.requestId != m.requestId))
    pure matched?
  let some pending := pending?
    | return false
  let (line, approvedPlan) := buildClaudeControlResponse pending answer
  if approvedPlan then
    entry.implementPlanRef.set true
    entry.permissionModeRef.set .bypassPermissions
  writeWarmStdinLine entry line

/-- Dynamically update Claude's permission mode mid-session over warm stdio. -/
def setSessionPermissionMode
    (mgr : WarmHarnessManager)
    (id : String)
    (mode : ClaudePermissionMode) : IO Bool := do
  let runs ← mgr.runsRef.get
  if let some (_, stRef) := runs.find? (fun (k, _) => k == id) then
    stRef.modify fun s => { s with permissionMode := mode }
  let ws ← mgr.warmProcsRef.get
  match ws.find? (fun (k, _) => k == id) with
  | none => return true
  | some (_, entry) =>
    entry.permissionModeRef.set mode
    let reqId ← newUuidV4
    writeWarmStdinLine entry (encodeSetPermissionModeRequest s!"orb-mode-{reqId}" mode)

/-- Stop any active run or warm Claude process for `id`, signalling the entire process group (`SIGTERM` then `SIGKILL`). -/
def stopHarnessRun (mgr : WarmHarnessManager) (id : String) : IO Unit := do
  let (warm?, oneShotPid?, stateRef?) ← mgr.mu.atomically do
    let ws ← mgr.warmProcsRef.get
    let w? := (ws.find? (fun (k, _) => k == id)).map Prod.snd
    mgr.warmProcsRef.set (ws.filter (fun (k, _) => k != id))
    let pids ← mgr.activePidsRef.get
    let p? := (pids.find? (fun (k, _) => k == id)).map Prod.snd
    mgr.activePidsRef.set (pids.filter (fun (k, _) => k != id))
    let runs ← mgr.runsRef.get
    let r? := (runs.find? (fun (k, _) => k == id)).map Prod.snd
    pure (w?, p?, r?)
  if let some stRef := stateRef? then
    stRef.modify fun s =>
      if s.done then s else { s with stopping := true, done := true, exitCode? := some 143 }
  if let some entry := warm? then
    entry.aliveRef.set false
    closeFdRaw entry.stdinFd
    let _ ← killSig (-entry.pid) 15
    IO.sleep 80
    let st ← waitpidWnohang entry.pid
    if st == 0xFFFFFFFF then
      let _ ← killSig (-entry.pid) 9
      let _ ← waitpidBlock entry.pid
    closeFdRaw entry.stdoutFd
  if let some pid := oneShotPid? then
    let _ ← killSig (-pid) 15
    IO.sleep 80
    let st ← waitpidWnohang pid
    if st == 0xFFFFFFFF then
      let _ ← killSig (-pid) 9
      let _ ← waitpidBlock pid
  if let some stRef := stateRef? then
    let finalSt ← stRef.get
    let cb ← getCallbacksFor mgr id
    cb.onOutputEvent (.obj #[
      ("text", .str finalSt.text),
      ("reset", .bool false),
      ("state", finalSt.toPollJVal)
    ])

/-- Extract short summary label for a Claude tool call (`Bash`, `Edit`, `Write`, `Read`, etc.). -/
private def toolActivityLabel (toolName : String) (input : JVal) : String × Option String :=
  if toolName == "Bash" then
    let desc := (input.fieldStr? "description").getD ""
    let cmd := (input.fieldStr? "command").getD ""
    let lbl := if !desc.isEmpty then desc else if !cmd.isEmpty then (cmd.take 72).toString else "Bash"
    (lbl, if cmd.isEmpty then none else some ((cmd.take 160).toString))
  else if toolName == "Edit" || toolName == "Write" || toolName == "Read" then
    let fp := (input.fieldStr? "file_path").orElse (fun _ => input.fieldStr? "path") |>.getD ""
    let base := ((fp.splitOn "/").getLast?).getD fp
    (if base.isEmpty then toolName else s!"{toolName} {base}", if fp.isEmpty then none else some fp)
  else
    (toolName, none)

/-- Update `LocalRunState` from one parsed Claude NDJSON stdout object, returning `(textDelta, finishedTurn?, errMsg?)`. -/
private def ingestClaudeStdoutEvent
    (stRef : IO.Ref LocalRunState)
    (ev : JVal)
    (nowMs : UInt64)
    (skipLeadingZeroTurnResultRef : IO.Ref Bool) : IO (String × Bool × Option String) := do
  let ty := (ev.fieldStr? "type").getD ""
  if ty == "system" then
    if let some sid := (ev.fieldStr? "session_id").filter (!·.isEmpty) then
      stRef.modify fun s => { s with sessionId? := some sid }
    return ("", false, none)
  else if ty == "stream_event" then
    let inner := ev.fieldOrNull "event"
    let ity := (inner.fieldStr? "type").getD ""
    if ity == "content_block_delta" then
      let deltaObj := inner.fieldOrNull "delta"
      let dty := (deltaObj.fieldStr? "type").getD ""
      if dty == "text_delta" then
        let txt := (deltaObj.fieldStr? "text").getD ""
        if !txt.isEmpty then
          stRef.modify fun s => { s with text := s.text ++ txt }
          return (txt, false, none)
    return ("", false, none)
  else if ty == "assistant" then
    let msg := ev.fieldOrNull "message"
    let mut appendedDelta := ""
    if let some blocks := msg.fieldArr? "content" then
      let curState ← stRef.get
      let mut acts := curState.activities
      let mut curText := curState.text
      for b in blocks do
        let bty := (b.fieldStr? "type").getD ""
        if bty == "tool_use" then
          let tid := (b.fieldStr? "id").getD s!"tool-{acts.size + 1}"
          let tname := (b.fieldStr? "name").getD "Tool"
          let tin := b.fieldOrNull "input"
          let (lbl, det?) := toolActivityLabel tname tin
          if !acts.any (fun a => a.id == tid) then
            acts := acts.push {
              id := tid
              label := lbl
              kind := if tname == "Task" || tname == "Agent" then "agent" else "command"
              toolUseId? := some tid
              detail? := det?
              startedAt := nowMs
              updatedAt := nowMs
            }
        else if bty == "text" then
          let fullTxt := (b.fieldStr? "text").getD ""
          if !fullTxt.isEmpty && curText.isEmpty then
            curText := fullTxt
            appendedDelta := fullTxt
      stRef.modify fun s => { s with activities := acts, text := curText }
    return (appendedDelta, false, none)
  else if ty == "user" then
    let msg := ev.fieldOrNull "message"
    if let some blocks := msg.fieldArr? "content" then
      stRef.modify fun s => Id.run do
        let mut acts := s.activities
        for b in blocks do
          if (b.fieldStr? "type") == some "tool_result" then
            if let some tid := b.fieldStr? "tool_use_id" then
              let isErr := (b.fieldBool? "is_error").getD false
              acts := acts.map fun a =>
                if a.id == tid || a.toolUseId? == some tid then
                  { a with
                    done := true
                    failed := isErr
                    status := if isErr then "failed" else "completed"
                    updatedAt := nowMs
                    finishedAt? := some nowMs }
                else a
        return { s with activities := acts }
    return ("", false, none)
  else if ty == "result" then
    let cur ← stRef.get
    let numTurns := (ev.fieldNat? "num_turns").getD 1
    let isErr := (ev.fieldBool? "is_error").getD false
    let resTxt := (ev.fieldStr? "result").getD ""
    let canSkip ← skipLeadingZeroTurnResultRef.get
    if cur.resumed && canSkip && numTurns == 0 && !isErr && resTxt.trimAscii.toString.isEmpty && cur.text.isEmpty then
      skipLeadingZeroTurnResultRef.set false
      return ("", false, none)
    if let some sid := (ev.fieldStr? "session_id").filter (!·.isEmpty) then
      stRef.modify fun s => { s with sessionId? := some sid }
    let mut delta := ""
    let stNow ← stRef.get
    if !resTxt.isEmpty && stNow.text.isEmpty then
      delta := resTxt
      stRef.modify fun s => { s with text := resTxt }
    if isErr then
      let errMsg := if resTxt.isEmpty then "Claude ended with an error" else resTxt
      return (delta, true, some errMsg)
    return (delta, true, none)
  else
    return ("", false, none)

/-- Read attachment files from `imagePaths` as `(mediaType, base64)` pairs for Claude's multimodal `user` turn. -/
private def loadClaudeImageBlocks (imagePaths : Array String) : IO (Array (String × String)) := do
  let mut out : Array (String × String) := #[]
  for p in imagePaths do
    let clean := p.trimAscii.toString
    if !clean.isEmpty && (← System.FilePath.pathExists clean) then
      if let .ok bytes ← (IO.FS.readBinFile clean).toBaseIO then
        if bytes.size <= 10 * 1024 * 1024 then
          out := out.push (guessImageMediaType clean, base64Encode bytes)
  return out

/-- Spawn or reuse a warm Claude Code process for `missionId` and dispatch a conversational turn over stdin! -/
private def launchOrReuseWarmClaude
    (mgr : WarmHarnessManager)
    (missionId : String)
    (binPath : String)
    (cwd : String)
    (prompt : String)
    (model? : Option String)
    (effort? : Option String)
    (sessionId? : Option String)
    (permMode : ClaudePermissionMode)
    (imagePaths : Array String)
    (stRef : IO.Ref LocalRunState) : IO (Except String Unit) := do
  -- Plan prefix (`/plan ...`) automatically activates Claude's `plan` permission mode
  let trimmed := prompt.trimAscii.toString
  let (effectiveMode, effectivePrompt) :=
    if trimmed == "/plan" then (.plan, "Propose a clear step-by-step plan before making changes.")
    else if trimmed.startsWith "/plan " then (.plan, (trimmed.drop 6).trimAscii.toString)
    else (permMode, prompt)
  stRef.modify fun s => { s with permissionMode := effectiveMode }

  let imgBlocks ← loadClaudeImageBlocks imagePaths
  let existingWarm? ← mgr.mu.atomically do
    let ws ← mgr.warmProcsRef.get
    pure ((ws.find? (fun (k, _) => k == missionId)).map Prod.snd)

  -- Case 1: Reuse live warm Claude process in the same working directory!
  if let some entry := existingWarm? then
    if (← entry.aliveRef.get) && entry.cwd == cwd then
      let prevMode ← entry.permissionModeRef.get
      if prevMode != effectiveMode then
        entry.permissionModeRef.set effectiveMode
        let modeId ← newUuidV4
        let _ ← writeWarmStdinLine entry (encodeSetPermissionModeRequest s!"orb-mode-{modeId}" effectiveMode)
      if let some mdl := model?.filter (!·.trimAscii.toString.isEmpty) then
        let mdlId ← newUuidV4
        let _ ← writeWarmStdinLine entry (encodeSetModelRequest s!"orb-mdl-{mdlId}" mdl)
      let ok ← writeWarmStdinLine entry (encodeClaudeUserTurn effectivePrompt imgBlocks)
      if ok then
        return .ok ()
      -- Warm pipe closed; clean up and respawn seamlessly with `--resume`
      mgr.mu.atomically do
        let ws ← mgr.warmProcsRef.get
        mgr.warmProcsRef.set (ws.filter (fun (k, _) => k != missionId))
      closeFdRaw entry.stdinFd
      closeFdRaw entry.stdoutFd
      let _ ← waitpidWnohang entry.pid

  -- Case 2: Spawn a fresh warm Claude process (`sh -c 'cd "$1" && exec "$2" ...'`)
  let (sid, isResume) ← match sessionId?.map (·.trimAscii.toString) |>.filter (!·.isEmpty) with
    | some existingSid => pure (existingSid, true)
    | none =>
      let freshUuid ← newUuidV4
      pure (freshUuid, false)
  stRef.modify fun s => { s with sessionId? := some sid, resumed := isResume }

  let claudeArgs := buildWarmClaudeArgs effectiveMode model? effort? sid isResume
  let envPairs ← currentEnvPairs
  let mut envStrs : Array String := #[]
  for (k, v) in envPairs do
    if k != "CLAUDECODE" then
      envStrs := envStrs.push s!"{k}={v}"
  -- Use `/bin/sh -c 'cd "$1" && shift && exec "$@"' sh <cwd> <binPath> <claudeArgs...>` so child starts cleanly in `cwd`
  let shArgs := #["-c", "cd \"$1\" && shift && exec \"$@\"", "sh", cwd, binPath] ++ claudeArgs
  let spawned ← match ← (spawnPgrp "/bin/sh" shArgs envStrs (pipeStdin := true) (nullStdio := true) (pipeStdout := true)).toBaseIO with
    | .error e => return .error s!"Failed to start Claude Code: {e}"
    | .ok sp => pure sp

  let writeMu ← Std.Mutex.new ()
  let aliveRef ← IO.mkRef true
  let pendingReqsRef ← IO.mkRef (#[] : Array PendingControlRequest)
  let implementPlanRef ← IO.mkRef false
  let permModeRef ← IO.mkRef effectiveMode
  let entry : WarmClaudeEntry := {
    missionId := missionId
    binPath := binPath
    cwd := cwd
    pid := spawned.pid
    stdinFd := spawned.stdinFd
    stdoutFd := spawned.stdoutFd
    writeMu := writeMu
    aliveRef := aliveRef
    pendingReqsRef := pendingReqsRef
    implementPlanRef := implementPlanRef
    permissionModeRef := permModeRef
  }
  mgr.mu.atomically do
    let ws ← mgr.warmProcsRef.get
    let filtered := ws.filter (fun (k, _) => k != missionId)
    mgr.warmProcsRef.set (filtered.push (missionId, entry))

  -- Send initial `initialize` + first user turn over warm stdin
  let _ ← writeWarmStdinLine entry (encodeInitializeRequest "orb-init")
  let sentOk ← writeWarmStdinLine entry (encodeClaudeUserTurn effectivePrompt imgBlocks)
  if !sentOk then
    return .error "Claude Code closed stdin before receiving prompt"

  -- Background stdout NDJSON stream reader for the lifetime of this warm process
  discard <| IO.asTask (prio := .dedicated) do
    let skipZeroRef ← IO.mkRef isResume
    let mut lineBuf := ByteArray.empty
    let mut keepLoop := true
    while keepLoop do
      match ← (readFdChunk entry.stdoutFd 16384).toBaseIO with
      | .error _ => keepLoop := false
      | .ok chunk =>
        if chunk.isEmpty then
          keepLoop := false
        else
          let (rawLines, rem) := drainNewlineByteLines (lineBuf ++ chunk)
          lineBuf := rem
          for rawLn in rawLines do
            let ln := rawLn.trimAscii.toString
            if !ln.isEmpty then
              if let .ok ev := OrbBin.Json.parse ln then
                let cb ← getCallbacksFor mgr missionId
                if let some ctrlReq := parseClaudeControlRequest? ev then
                  entry.writeMu.atomically do
                    let ps ← entry.pendingReqsRef.get
                    entry.pendingReqsRef.set (ps.push ctrlReq)
                  cb.onStructuredEvent "tool_call" (.obj #[
                    ("tool_call_id", .str ctrlReq.requestId),
                    ("name", .str "ui_native_request"),
                    ("args", .obj #[
                      ("method", .str ctrlReq.method),
                      ("params", ctrlReq.uiParams)
                    ])
                  ])
                  cb.onControlRequest ctrlReq
                else
                  let nowSec ← nowEpoch
                  let nowMs := nowSec * 1000
                  let (delta, turnDone, err?) ← ingestClaudeStdoutEvent stRef ev nowMs skipZeroRef
                  let snap ← stRef.get
                  if !delta.isEmpty then
                    cb.onStructuredEvent "text_delta" (.obj #[("content", .str delta)])
                  cb.onOutputEvent (.obj #[
                    ("text", .str delta),
                    ("reset", .bool false),
                    ("activities", .arr (snap.activities.map LocalActivityItem.toJVal))
                  ])
                  if turnDone then
                    let shouldImplement ← entry.implementPlanRef.modifyGet fun v => (v, false)
                    if shouldImplement && err?.isNone then
                      -- User accepted `ExitPlanMode`: switch to `bypassPermissions` and continue seamlessly!
                      let _ ← writeWarmStdinLine entry (encodeSetPermissionModeRequest "orb-execute" .bypassPermissions)
                      let _ ← writeWarmStdinLine entry (encodeClaudeUserTurn "Implement the approved plan.")
                    else
                      -- Post-turn git checkpoint capture (`Turn 1` after turn 1, `Turn 2` after turn 2, etc.)
                      let nextTurnIdx := snap.turnCount + 1
                      discard <| captureCheckpoint cwd missionId nextTurnIdx s!"post-{snap.generation}" s!"Turn {nextTurnIdx}"
                      stRef.modify fun s =>
                        { s with
                          done := true
                          exitCode? := some (if err?.isSome then 1 else 0)
                          error? := err?
                          turnCount := s.turnCount + 1 }
                      let doneSnap ← stRef.get
                      if !doneSnap.text.isEmpty && err?.isNone then
                        cb.onStructuredEvent "assistant_message" (.obj #[("content", .str doneSnap.text)])
                      if let some em := err? then
                        cb.onStructuredEvent "error" (.obj #[("message", .str em)])
                      cb.onOutputEvent (.obj #[
                        ("text", .str ""),
                        ("reset", .bool false),
                        ("activities", .arr (doneSnap.activities.map LocalActivityItem.toJVal)),
                        ("state", doneSnap.toPollJVal)
                      ])
                      cb.onTurnFinished doneSnap
    -- EOF on stdout: reap child process and mark current turn done if still active
    entry.aliveRef.set false
    mgr.mu.atomically do
      let ws ← mgr.warmProcsRef.get
      mgr.warmProcsRef.set (ws.filter (fun (k, _) => k != missionId))
    closeFdRaw entry.stdinFd
    closeFdRaw entry.stdoutFd
    let rawExit ← waitpidBlock entry.pid
    let curSnap ← stRef.get
    if !curSnap.done then
      let exitInt : Int := Int.ofNat rawExit.toNat
      let errMsg? := if rawExit == 0 then none else some s!"Claude Code exited (code {rawExit})"
      stRef.modify fun s => { s with done := true, exitCode? := some exitInt, error? := errMsg? }
      let finalSnap ← stRef.get
      let cb ← getCallbacksFor mgr missionId
      cb.onOutputEvent (.obj #[
        ("text", .str ""),
        ("reset", .bool false),
        ("state", finalSnap.toPollJVal)
      ])
      cb.onTurnFinished finalSnap
  return .ok ()

/-- Normalize an Antigravity model + optional effort for `agy` CLI 1.5+ (where Carbon and Argon
    bake effort into `gemini-4-carbon-{low,medium,high}` and `gemini-4-argon-{low,medium,high}`). -/
def normalizeAntigravityCliModel (rawModel : String) (eff? : Option String) : String × Option String :=
  let m0 := rawModel.trimAscii.toString
  let m := if m0.startsWith "antigravity/" then (m0.drop 12).toString else m0
  let cleanEff? := eff?.map (·.trimAscii.toString.toLower) |>.filter (fun s => !s.isEmpty)
  let validTier (s : String) : Bool := s == "low" || s == "medium" || s == "high"
  let (baseKind?, variantLvl?) : Option String × Option String :=
    if m == "gemini-4-carbon" || m == "gemini-4-carbon-eap" || m == "agy-model" then
      (some "gemini-4-carbon", none)
    else if m.startsWith "gemini-4-carbon-" && validTier (m.drop 16).toString then
      (some "gemini-4-carbon", some (m.drop 16).toString)
    else if m.startsWith "agy-model-" && validTier (m.drop 10).toString then
      (some "gemini-4-carbon", some (m.drop 10).toString)
    else if m == "gemini-4-argon" || m == "gemini-4-argon-eap" || m == "agy-demo" then
      (some "gemini-4-argon", none)
    else if m.startsWith "gemini-4-argon-" && validTier (m.drop 15).toString then
      (some "gemini-4-argon", some (m.drop 15).toString)
    else if m.startsWith "agy-demo-" && validTier (m.drop 9).toString then
      (some "gemini-4-argon", some (m.drop 9).toString)
    else
      (none, none)
  match baseKind? with
  | some base =>
    let lvl := match cleanEff?.orElse (fun _ => variantLvl?) with
      | some "low" => "low"
      | some "medium" => "medium"
      | _ => "high"
    (s!"{base}-{lvl}", none)
  | none => (m, cleanEff?)

/-- Build CLI invocation `(args, parseKind)` for non-Claude local harnesses (`codex`, `opencode`, `antigravity`, `grok`, `vibe`). -/
private def buildOneShotHarnessArgs
    (harness : String)
    (prompt : String)
    (model? : Option String)
    (effort? : Option String)
    (sessionId? : Option String) : Array String := Id.run do
  let mdl? := model?.map (·.trimAscii.toString) |>.filter (!·.isEmpty)
  let eff? := effort?.map (·.trimAscii.toString) |>.filter (!·.isEmpty)
  let sid? := sessionId?.map (·.trimAscii.toString) |>.filter (!·.isEmpty)
  if harness == "codex" then
    let mut args := #["exec", "--json", "--dangerously-bypass-approvals-and-sandbox", "--skip-git-repo-check"]
    if let some m := mdl? then
      let bare := if m.startsWith "openai/" then (m.drop 7).toString else m
      args := args ++ #["-m", bare]
    if let some e := eff? then
      args := args ++ #["-c", s!"model_reasoning_effort=\"{e}\""]
    if let some s := sid? then
      args := args ++ #["resume", s, prompt]
    else
      args := args.push prompt
    return args
  else if harness == "opencode" then
    let mut args := #["run", "--format", "json"]
    if let some m := mdl? then args := args ++ #["--model", m]
    if let some s := sid? then args := args ++ #["--session", s]
    args := args.push prompt
    return args
  else if harness == "antigravity" then
    let mut args := #["--print"]
    if let some m := mdl? then
      let (fullMdl, remEff?) := normalizeAntigravityCliModel m eff?
      args := args ++ #["--model", fullMdl]
      if let some e := remEff? then
        args := args ++ #["--effort", e]
    else if let some e := eff?.map (·.trimAscii.toString.toLower) |>.filter (fun s => !s.isEmpty) then
      args := args ++ #["--effort", e]
    args := args.push prompt
    return args
  else if harness == "grok" then
    let mut args := #["-p", prompt, "--output-format", "streaming-json"]
    if let some m := mdl? then args := args ++ #["--model", m]
    return args
  else
    -- `vibe` or custom CLI
    return #["--prompt", prompt]

/-- Extract incremental assistant text & session ID from a single stdout line of `codex` / `opencode` / `grok` / plain CLI. -/
private def parseOneShotHarnessLine (harness : String) (rawLine : String) : Option String × String :=
  let trimmed := rawLine.trimAscii.toString
  if trimmed.isEmpty then (none, "")
  else if harness == "codex" || harness == "opencode" || harness == "grok" then
    match OrbBin.Json.parse trimmed with
    | .error _ => (none, "")
    | .ok jv =>
      let sid? := (jv.fieldStr? "thread_id").orElse (fun _ => jv.fieldStr? "sessionID") |>.orElse (fun _ => jv.fieldStr? "session_id")
      let ty := (jv.fieldStr? "type").getD ""
      if ty == "item.completed" then
        let item := jv.fieldOrNull "item"
        if (item.fieldStr? "type") == some "agent_message" then
          (sid?, (item.fieldStr? "text").getD "")
        else (sid?, "")
      else if ty == "text" then
        let part := jv.fieldOrNull "part"
        (sid?, (part.fieldStr? "text").orElse (fun _ => jv.fieldStr? "text") |>.getD "")
      else if ty == "assistant" || ty == "message" then
        (sid?, (jv.fieldStr? "content").orElse (fun _ => jv.fieldStr? "text") |>.getD "")
      else
        (sid?, "")
  else
    (none, rawLine ++ "\n")

/-- Launch a turn for any supported local harness (`claudecode` via warm bidirectional stdio, or one-shot CLI for others).
    Automatically evaluates worktree isolation when requested and captures pre/post-turn git checkpoints! -/
def startHarnessTurn
    (mgr : WarmHarnessManager)
    (id : String)
    (harness : String)
    (binPath : String)
    (requestedCwd : String)
    (prompt : String)
    (generation : UInt64 := 1)
    (model? : Option String := none)
    (effort? : Option String := none)
    (sessionId? : Option String := none)
    (permissionMode : ClaudePermissionMode := .bypassPermissions)
    (worktreeMode : String := "local") -- "local" | "worktree" | "auto"
    (imagePaths : Array String := #[])
    (callbacks : HarnessCallbacks := {})
    (worktreesParentDir? : Option String := none) : IO (Except String LocalRunState) := do
  let resolvedBin? ←
    if !binPath.trimAscii.toString.isEmpty && (← System.FilePath.pathExists binPath.trimAscii.toString) then
      pure (some binPath.trimAscii.toString)
    else
      let defaultBin :=
        if harness == "claudecode" then "claude"
        else if harness == "antigravity" then "agy"
        else if harness == "vibe" then "vibe-acp"
        else harness
      resolveHarnessBinary? defaultBin none
  let some actualBin := resolvedBin?
    | return .error s!"CLI binary for {harness} is not installed"

  -- Resolve optional git worktree isolation via `Orb.Kernel.worktreeDecisionStep`
  let mut effectiveCwd := requestedCwd.trimAscii.toString
  let mut createdWtPath? : Option String := none
  if worktreeMode == "worktree" || worktreeMode == "auto" then
    let otherCwds ← activeRunCwdsExcept mgr id
    let wtStatus ← inspectWorktreeStatus effectiveCwd id otherCwds (preferWorktree := worktreeMode == "worktree") worktreesParentDir?
    if wtStatus.isGitRepo && wtStatus.createWorktree then
      if let .ok wt ← createMissionWorktree effectiveCwd id none worktreesParentDir? then
        effectiveCwd := wt.worktreePath
        createdWtPath? := some wt.worktreePath

  setCallbacksFor mgr id callbacks
  let prevState? ← getRunState? mgr id
  let prevTurns := (prevState?.map (·.turnCount)).getD 0
  let effSid? := sessionId?.filter (!·.trimAscii.toString.isEmpty) |>.orElse (fun _ => prevState?.bind (·.sessionId?))

  -- Best-effort initial baseline git checkpoint (`Turn 0`) before the first turn (zero `.git/index.lock` contention)
  let shortLabel := ((prompt.trimAscii.toString.splitOn "\n").headD "").take 72 |>.toString
  if prevTurns == 0 then
    discard <| captureCheckpoint effectiveCwd id 0 s!"pre-{generation}" shortLabel

  let initState : LocalRunState := {
    runId := id
    generation := generation
    harness := harness
    cwd := effectiveCwd
    worktreePath? := createdWtPath?.orElse (fun _ => prevState?.bind (·.worktreePath?))
    permissionMode := permissionMode
    text := ""
    done := false
    resumed := effSid?.isSome
    sessionId? := effSid?
    activities := #[]
    turnCount := prevTurns
  }
  let stRef ← upsertRunStateRef mgr id initState
  callbacks.onOutputEvent (.obj #[("text", .str ""), ("reset", .bool true), ("activities", .arr #[])])

  if harness == "claudecode" then
    match ← launchOrReuseWarmClaude mgr id actualBin effectiveCwd prompt model? effort? effSid? permissionMode imagePaths stRef with
    | .error e =>
      stRef.modify fun s => { s with done := true, exitCode? := some 1, error? := some e }
      return .error e
    | .ok () =>
      return .ok (← stRef.get)
  else
    let cliArgs := buildOneShotHarnessArgs harness prompt model? effort? effSid?
    let envPairs ← currentEnvPairs
    let envStrs := envPairs.map fun (k, v) => s!"{k}={v}"
    let shArgs := #["-c", "cd \"$1\" && shift && exec \"$@\"", "sh", effectiveCwd, actualBin] ++ cliArgs
    let spawned ← match ← (spawnPgrp "/bin/sh" shArgs envStrs (pipeStdin := false) (nullStdio := true) (pipeStdout := true)).toBaseIO with
      | .error e =>
        stRef.modify fun s => { s with done := true, exitCode? := some 1, error? := some s!"{e}" }
        return .error s!"Failed to start {harness}: {e}"
      | .ok sp => pure sp
    mgr.mu.atomically do
      let pids ← mgr.activePidsRef.get
      mgr.activePidsRef.set ((pids.filter (fun (k, _) => k != id)).push (id, spawned.pid))

    discard <| IO.asTask (prio := .dedicated) do
      let mut buf := ByteArray.empty
      let mut keep := true
      while keep do
        match ← (readFdChunk spawned.stdoutFd 16384).toBaseIO with
        | .error _ => keep := false
        | .ok chunk =>
          if chunk.isEmpty then keep := false
          else
            let (lines, rem) := drainNewlineByteLines (buf ++ chunk)
            buf := rem
            for ln in lines do
              let (sid?, delta) := parseOneShotHarnessLine harness ln
              if let some sid := sid? then
                stRef.modify fun s => { s with sessionId? := some sid }
              if !delta.isEmpty then
                stRef.modify fun s => { s with text := s.text ++ delta }
                let cb ← getCallbacksFor mgr id
                cb.onStructuredEvent "text_delta" (.obj #[("content", .str delta)])
                cb.onOutputEvent (.obj #[("text", .str delta), ("reset", .bool false)])
      closeFdRaw spawned.stdoutFd
      let code ← waitpidBlock spawned.pid
      mgr.mu.atomically do
        let pids ← mgr.activePidsRef.get
        mgr.activePidsRef.set (pids.filter (fun (k, _) => k != id))
      let postTurnIdx := prevTurns + 1
      discard <| captureCheckpoint effectiveCwd id postTurnIdx s!"post-{generation}" s!"Turn {postTurnIdx}"
      let err? := if code == 0 then none else some s!"{harness} exited with code {code}"
      stRef.modify fun s => {
        s with
        done := true
        exitCode? := some (Int.ofNat code.toNat)
        error? := err?
        turnCount := s.turnCount + 1
      }
      let finalSnap ← stRef.get
      let cb ← getCallbacksFor mgr id
      if !finalSnap.text.isEmpty && err?.isNone then
        cb.onStructuredEvent "assistant_message" (.obj #[("content", .str finalSnap.text)])
      if let some em := err? then
        cb.onStructuredEvent "error" (.obj #[("message", .str em)])
      cb.onOutputEvent (.obj #[
        ("text", .str ""),
        ("reset", .bool false),
        ("state", finalSnap.toPollJVal)
      ])
      cb.onTurnFinished finalSnap
    return .ok (← stRef.get)

end OrbBin.ClaudeControl
