/-
  OrbNode.PiRpc: Pure-Lean `sandboxed-node pi-rpc` Driver (`#2258`).
  Drives `pi --mode rpc --session <mission_session.jsonl>` over strict LF-delimited JSONL,
  enforcing `Orb.Kernel.piRpcStep` (mutually exclusive `set_model`, `StickyFence` on `aborted`/`closed`,
  RPC `id`-correlated rollback) and `Orb.Kernel.piMcpConfigGate` (zero secrets in `argv`,
  confined `.jsonl` session paths, `readonly`/`plan` enforcement), and reaping the full child
  process group (including any child `turbo-lean mcp` stdio server) on exit or abort.
-/
import Orb.Kernel
import Orb.PiHarness
import OrbBin.Json
import OrbBin.PosixExt

namespace OrbNode.PiRpc

open Orb.Kernel
open OrbBin.Json
open OrbBin.PosixExt

structure PiRpcTurnConfig where
  cwd            : String
  prompt         : String := ""
  binPath        : String := "pi"
  provider?      : Option String := none
  model?         : Option String := none
  switchModel?   : Option String := none
  thinking?      : Option String := none
  sessionFile?   : Option String := none
  extensionPath? : Option String := none
  plan           : Bool := false
  readOnly       : Bool := false
  deriving Repr, Inhabited

/-- Validate a session file path (absolute or relative): non-empty, `.jsonl` suffix,
    zero `..` path traversal segments, zero backslashes or NUL bytes. -/
def isSafePiSessionFilePath (raw : String) : Bool :=
  let p := raw.trimAscii.toString
  if p.isEmpty then false
  else if p.startsWith "/" then
    let stripped := (p.dropWhile (· == '/')).toString
    piSessionRelPathSafe stripped
  else
    piSessionRelPathSafe p

/-- Parse `provider/model` or bare `model` for Pi `--provider` / `--model` / `set_model`.
    Orb-proxied models (e.g. `builtin/smart`, `anthropic/claude-opus-5-5`, `openai/gpt-6.1-sol`)
    live under provider `"orb"` inside the mission's `models.json`. -/
def splitPiProviderModel (raw : String) (defaultProvider : String := "orb") : String × String :=
  let clean := raw.trimAscii.toString
  if clean.startsWith "orb/" then
    ("orb", (clean.drop 4).toString)
  else
    (defaultProvider, clean)

/-- Check that no Orb secret value leaks into a constructed `argv` array. -/
def argvContainsSecret (args : Array String) (secretValues : Array String) : Bool :=
  secretValues.any fun sec =>
    let s := sec.trimAscii.toString
    !s.isEmpty && args.any (fun a => (a.splitOn s).length > 1)

/-- Build `pi --mode rpc` CLI arguments without ever placing secret tokens in `argv`. -/
def buildPiRpcArgs (cfg : PiRpcTurnConfig) : Array String := Id.run do
  let mut args : Array String := #["--mode", "rpc"]
  if let some sf := cfg.sessionFile?.map (·.trimAscii.toString) |>.filter (!·.isEmpty) then
    args := args ++ #["--session", sf]
  else
    args := args.push "--no-session"
  if let some ext := cfg.extensionPath?.map (·.trimAscii.toString) |>.filter (!·.isEmpty) then
    args := args ++ #["--extension", ext]
  if let some rawM := cfg.model?.map (·.trimAscii.toString) |>.filter (!·.isEmpty) then
    let (prov, mid) := splitPiProviderModel rawM (cfg.provider?.getD "orb")
    if !prov.isEmpty then
      args := args ++ #["--provider", prov]
    if !mid.isEmpty then
      args := args ++ #["--model", mid]
  else if let some prov := cfg.provider?.map (·.trimAscii.toString) |>.filter (!·.isEmpty) then
    args := args ++ #["--provider", prov]
  if let some th := cfg.thinking?.map (·.trimAscii.toString) |>.filter (!·.isEmpty) then
    args := args ++ #["--thinking", th]
  if cfg.plan || cfg.readOnly then
    args := args.push "--plan"
  return args

/-- Encode a strict LF-terminated JSONL RPC command for Pi stdin. -/
def encodePiRpcLine (fields : Array (String × JVal)) : ByteArray :=
  (renderCompact (.obj fields) ++ "\n").toUTF8

def encodePiGetState (reqId : String) : ByteArray :=
  encodePiRpcLine #[("id", .str reqId), ("type", .str "get_state")]

def encodePiPrompt (reqId message : String) : ByteArray :=
  encodePiRpcLine #[("id", .str reqId), ("type", .str "prompt"), ("message", .str message)]

def encodePiSetModel (reqId provider modelId : String) : ByteArray :=
  encodePiRpcLine #[
    ("id", .str reqId),
    ("type", .str "set_model"),
    ("provider", .str provider),
    ("modelId", .str modelId)
  ]

def encodePiSetThinking (reqId level : String) : ByteArray :=
  encodePiRpcLine #[("id", .str reqId), ("type", .str "set_thinking_level"), ("level", .str level)]

def encodePiAbort (reqId : String) : ByteArray :=
  encodePiRpcLine #[("id", .str reqId), ("type", .str "abort")]

/-- Drain complete LF (`\n`) delimited lines from a byte buffer (strict Pi RPC framing,
    stripping only trailing `\r` and never splitting on U+2028/U+2029). -/
private def drainLfLines (acc : ByteArray) : Array String × ByteArray := Id.run do
  let mut lines : Array String := #[]
  let mut start : Nat := 0
  for i in [0:acc.size] do
    if acc[i]! == 0x0A then
      let slice := acc.extract start i
      let decoded := (String.fromUTF8? slice).getD ""
      let clean := if decoded.endsWith "\r" then (decoded.dropEnd 1).toString else decoded
      lines := lines.push clean
      start := i + 1
  let rem := if start == 0 then acc else acc.extract start acc.size
  return (lines, rem)

/-- Parse `sandboxed-node pi-rpc` CLI flags. -/
def parsePiRpcArgs (cwd : String) : List String → Option PiRpcTurnConfig
  | [] => some { cwd := cwd }
  | "--plan" :: rest => (parsePiRpcArgs cwd rest).map ({ · with plan := true, readOnly := true })
  | "--readonly" :: rest => (parsePiRpcArgs cwd rest).map ({ · with readOnly := true })
  | "--bin" :: v :: rest => (parsePiRpcArgs cwd rest).map ({ · with binPath := v })
  | "--provider" :: v :: rest => (parsePiRpcArgs cwd rest).map ({ · with provider? := some v })
  | "--model" :: v :: rest => (parsePiRpcArgs cwd rest).map ({ · with model? := some v })
  | "--switch-model" :: v :: rest => (parsePiRpcArgs cwd rest).map ({ · with switchModel? := some v })
  | "--effort" :: v :: rest => (parsePiRpcArgs cwd rest).map ({ · with thinking? := some v })
  | "--thinking" :: v :: rest => (parsePiRpcArgs cwd rest).map ({ · with thinking? := some v })
  | "--session" :: v :: rest => (parsePiRpcArgs cwd rest).map ({ · with sessionFile? := some v })
  | "--extension" :: v :: rest => (parsePiRpcArgs cwd rest).map ({ · with extensionPath? := some v })
  | _ => none

/-- Check `piMcpConfigGate` pre-flight before spawning `pi --mode rpc`. -/
def preflightPiConfigGate
    (cfg : PiRpcTurnConfig)
    (args : Array String)
    (secretValues : Array String) : Bool :=
  let sessionOk := match cfg.sessionFile? with
    | some sf => isSafePiSessionFilePath sf
    | none => true
  let inp : PiMcpPolicyInput := {
    secretsInArgv := argvContainsSecret args secretValues
    agentDirMode0700 := true
    configFileMode0600 := true
    sessionPathConfined := sessionOk
    sandboxedMcpHttpOnly := true
    readOnlyMode := cfg.plan || cfg.readOnly
    toolIsMutating := false
  }
  piMcpConfigGate inp

/-- Drive one `pi --mode rpc` turn inside its own process group, gating transitions with `piRpcStep`,
    forwarding every non-fenced JSONL event line to `onLine`, and reaping the entire process group
    (including child `turbo-lean mcp` stdio helpers) before returning. -/
def runPiRpcTurn
    (cfg : PiRpcTurnConfig)
    (envPairs : Array (String × String))
    (onLine : String → IO Unit) : IO UInt32 := do
  let args := buildPiRpcArgs cfg
  let secretVals := envPairs.filterMap fun (k, v) =>
    if k == "SANDBOXED_MCP_TOKEN" || k == "SANDBOXED_PROXY_API_KEY" then some v else none
  if !preflightPiConfigGate cfg args secretVals then
    let errLine := renderCompact (.obj #[
      ("type", .str "error"),
      ("error", .obj #[("message", .str "Pi preflight rejected by pi_mcp_config_gate (unsafe session path or secret in argv)")])
    ])
    onLine errLine
    return 2
  let mut envStrs : Array String := #[]
  let mut hasReadonly := false
  let mut hasOffline := false
  for (k, v) in envPairs do
    if k == "ORB_PI_READONLY" then hasReadonly := true
    if k == "PI_OFFLINE" then hasOffline := true
    envStrs := envStrs.push s!"{k}={v}"
  if (cfg.plan || cfg.readOnly) && !hasReadonly then
    envStrs := envStrs.push "ORB_PI_READONLY=1"
  if !hasOffline then
    envStrs := envStrs.push "PI_OFFLINE=1"
  let shArgs := #["-c", "cd \"$1\" && shift && exec \"$@\"", "sh", cfg.cwd, cfg.binPath] ++ args
  let sp ← match ← (spawnPgrp "/bin/sh" shArgs envStrs (pipeStdin := true) (nullStdio := true) (pipeStdout := true)).toBaseIO with
    | .ok s => pure s
    | .error e =>
      let errLine := renderCompact (.obj #[
        ("type", .str "error"),
        ("error", .obj #[("message", .str s!"Failed to spawn pi RPC process: {e}")])
      ])
      onLine errLine
      return 127
  let send := fun (b : ByteArray) => do discard <| writeFdAll sp.stdinFd b
  let initModel := (cfg.model?.map (·.trimAscii.toString) |>.filter (!·.isEmpty)).getD "orb/builtin/smart"
  let mut sess : PiRpcSession := { phase := .idle, activeModel := initModel }
  let mut failed := false
  let mut finished := false
  let mut promptSent := false
  let mut buf := ByteArray.empty
  let reportError := fun (msg : String) =>
    onLine (renderCompact (.obj #[
      ("type", .str "error"),
      ("error", .obj #[("message", .str ((msg.take 1000).toString))])
    ]))

  -- 1. Probe session state first so Core captures sessionId/sessionFile immediately.
  send (encodePiGetState "orb-state")

  -- 2. Apply optional explicit mid-session model switch before prompt, tracked via `piRpcStep`.
  let switchReqNum : Nat := 2
  let mut awaitingSwitch := false
  if let some rawSw := cfg.switchModel?.map (·.trimAscii.toString) |>.filter (!·.isEmpty) then
    let (swProv, swMid) := splitPiProviderModel rawSw (cfg.provider?.getD "orb")
    let (s1, _) := piRpcStep sess (.setModel switchReqNum s!"{swProv}/{swMid}")
    sess := s1
    awaitingSwitch := true
    send (encodePiSetModel "orb-switch" swProv swMid)

  if !awaitingSwitch then
    let (sRun, _) := piRpcStep sess (.startTurn 1)
    sess := sRun
    promptSent := true
    send (encodePiPrompt "orb-prompt" cfg.prompt)

  while !finished do
    let chunk ← match ← (readFdChunk sp.stdoutFd 16384).toBaseIO with
      | .ok c => pure c
      | .error _ => pure ByteArray.empty
    if chunk.isEmpty then
      let (sClosed, _) := piRpcStep sess (.processExit 1)
      sess := sClosed
      if !finished then
        failed := true
        reportError "Pi RPC process ended before agent_end"
      break
    let (lines, rem) := drainLfLines (buf ++ chunk)
    buf := rem
    for ln in lines do
      let clean := ln.trimAscii.toString
      if clean.isEmpty then continue
      if piRpcIsFenced sess then
        continue
      let .ok jv := OrbBin.Json.parse clean | continue
      let evTy := (jv.fieldStr? "type").getD ""
      if evTy == "response" then
        let rid := (jv.fieldStr? "id").getD ""
        let cmd := (jv.fieldStr? "command").getD ""
        let ok := (jv.fieldBool? "success").getD false
        let err := (jv.fieldStr? "error").getD "pi_rpc_command_failed"
        if rid == "orb-state" && ok then
          let data := jv.fieldOrNull "data"
          let sid := (data.fieldStr? "sessionId").getD ""
          let sfile := (data.fieldStr? "sessionFile").getD ""
          let mdlObj := data.fieldOrNull "model"
          let mdlId := (mdlObj.fieldStr? "id").getD ""
          if !sid.isEmpty || !sfile.isEmpty then
            onLine (renderCompact (.obj #[
              ("type", .str "pi_session"),
              ("sessionId", .str sid),
              ("sessionFile", .str sfile),
              ("model", .str mdlId)
            ]))
        else if rid == "orb-switch" then
          let (sNext, outc) := piRpcStep sess (.rpcResponse switchReqNum ok err)
          sess := sNext
          awaitingSwitch := false
          match outc with
          | .switchRolledBack restored reason =>
            onLine clean
            failed := true
            reportError s!"Pi rejected set_model (rolled back to {restored}): {reason}"
            let (sAb, _) := piRpcStep sess .abort
            sess := sAb
            finished := true
          | _ =>
            onLine clean
            if !promptSent then
              let (sRun, _) := piRpcStep sess (.startTurn 1)
              sess := sRun
              promptSent := true
              send (encodePiPrompt "orb-prompt" cfg.prompt)
        else if !ok then
          onLine clean
          failed := true
          reportError s!"Pi RPC command '{cmd}' failed: {err}"
          let (sAb, _) := piRpcStep sess .abort
          sess := sAb
          finished := true
      else if evTy == "tool_execution_start" then
        let cid := (jv.fieldStr? "toolCallId").getD "tool"
        let (sNext, outc) := piRpcStep sess (.toolStart cid)
        sess := sNext
        if piRpcOutcomeEmitsOutput outc then
          onLine clean
      else if evTy == "tool_execution_end" then
        let cid := (jv.fieldStr? "toolCallId").getD "tool"
        let (sNext, outc) := piRpcStep sess (.toolEnd cid)
        sess := sNext
        if piRpcOutcomeEmitsOutput outc || !piRpcIsFenced sess then
          onLine clean
      else if evTy == "message_update" then
        let ame := jv.fieldOrNull "assistantMessageEvent"
        let ameTy := (ame.fieldStr? "type").getD ""
        if ameTy == "text_delta" then
          let d := (ame.fieldStr? "delta").getD ""
          let (sNext, outc) := piRpcStep sess (.textDelta d)
          sess := sNext
          if piRpcOutcomeEmitsOutput outc then
            onLine clean
        else
          onLine clean
      else if evTy == "agent_end" then
        onLine clean
        let (sNext, _) := piRpcStep sess .turnEnd
        sess := sNext
        -- Inspect final assistant message stopReason for errors
        let msgs := (jv.fieldArr? "messages").getD #[]
        if let some last := msgs.back? then
          let sr := (last.fieldStr? "stopReason").getD ""
          if sr == "error" || sr == "aborted" then
            failed := true
        finished := true
      else if evTy == "extension_error" then
        onLine clean
      else
        onLine clean
      if finished then break

  -- Clean teardown of `pi` and its child process group (including `turbo-lean mcp` stdio helper).
  closeFdRaw sp.stdinFd
  let mut exited := false
  let mut exitCode : UInt32 := 0
  for _ in [0:40] do
    if !exited then
      let rc ← waitpidWnohang sp.pid
      if rc != 0xFFFFFFFF then
        exited := true
        exitCode := rc
      else
        IO.sleep 50
  if !exited then
    let _ ← killSig (-sp.pid) 15
    for _ in [0:20] do
      if !exited then
        let rc ← waitpidWnohang sp.pid
        if rc != 0xFFFFFFFF then
          exited := true
          exitCode := rc
        else
          IO.sleep 50
  if !exited then
    let _ ← killSig (-sp.pid) 9
    exitCode ← waitpidBlock sp.pid
  else
    -- Ensure any lingering descendant in the process group (e.g. detached turbo-lean mcp) is terminated.
    let _ ← killSig (-sp.pid) 15
  closeFdRaw sp.stdoutFd
  if failed then return 1
  if exitCode != 0 then return exitCode
  return 0

end OrbNode.PiRpc
