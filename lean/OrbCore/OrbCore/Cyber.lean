/-
  OrbCore.Cyber: Fail-closed Codex Cyber Access selection, execution binding, and
  native `/goal` gating (`#1497`). Explicit selections never grant provider access.
-/
import Orb.Kernel
import OrbCore.Store
import OrbBin.Json
import OrbBin.PosixExt

namespace OrbCore.Cyber

open OrbCore.Store
open OrbBin.Json
open OrbBin.PosixExt

def nilRevision : String := "00000000-0000-0000-0000-000000000000"

def defaultCodexModel : String := "gpt-6.1-sol"

def nativeGoalExplicitCyberRefusal : String :=
  "unsupported_access_program: native goal continuations cannot confirm a per-turn cyber selection. Choose Automatic explicitly for this goal."

def clientSelectionConflict : String :=
  "Cyber selection changed or this client cannot honor it. Reload before launching; no turn was started."

def proxyBindingRequired : String := "Explicit cyber programs require an execution-bound key"

def proxySelectionConflict : String := "Cyber request conflicts with the saved mission selection"

inductive Mode where
  | standard
  | daybreak
  | automatic
  deriving Repr, DecidableEq, Inhabited

def Mode.asSnake : Mode → String
  | .standard => "standard"
  | .daybreak => "daybreak"
  | .automatic => "automatic"

def parseMode? (s : String) : Option Mode :=
  match s.trimAscii.toString.toLower with
  | "standard" => some .standard
  | "daybreak" => some .daybreak
  | "automatic" => some .automatic
  | _ => none

def bareModel (model : String) : String :=
  (model.splitOn "/").getLast?.getD model

/-- OpenAI retired these Daybreak aliases on 2026-10-28; the underlying models remain. -/
def retiredAliasError? (model : String) : Option String :=
  match bareModel model with
  | "gpt-daybreak-blue-latest" =>
    some "OpenAI retired the 'gpt-daybreak-blue-latest' alias on 2026-10-28. Select a specific Daybreak Blue model such as gpt-6.1-sol with Cyber Access set to Daybreak."
  | "gpt-daybreak-red-latest" =>
    some "OpenAI retired the 'gpt-daybreak-red-latest' alias on 2026-10-28. Select a specific Daybreak Red model such as gpt-5.6-cyber."
  | _ => none

/-- Snake-case provider program used on the Core HTTP proxy (`access_programs.cyber`). -/
def Mode.program (mode : Mode) (model : String) : Except String (Option String) := do
  if let some err := retiredAliasError? model then
    throw err
  let model := bareModel model
  match mode with
  | .automatic => pure none
  | .standard =>
    if model.startsWith "gpt-daybreak-" || model == "gpt-5.6-cyber" then
      throw "This model requires Daybreak. Choose Automatic or Daybreak, or select a general-purpose model."
    else
      pure (some "standard")
  | .daybreak =>
    match model with
    | "gpt-6-sol" | "gpt-6.1-sol" | "gpt-6-astra" | "gpt-5.6-sol" => pure (some "daybreak_blue")
    | "gpt-5.6-cyber" => pure (some "daybreak_red")
    | _ => throw "Daybreak compatibility is not known for this model. Keep the model and choose Standard or Automatic."

/-- Camel-case program used by the native Codex app-server. -/
def Mode.native (mode : Mode) (model : String) : Except String (Option String) := do
  match ← mode.program model with
  | none => pure none
  | some p =>
    pure (some (match p with
      | "daybreak_blue" => "daybreakBlue"
      | "daybreak_red" => "daybreakRed"
      | _ => "standard"))

def validateGoalSelection (mode : Mode) (isGoalRequest : Bool) : Except String Unit := do
  if isGoalRequest && mode != .automatic then
    throw nativeGoalExplicitCyberRefusal

/-- `/goal` only, and only when the rest is empty or begins with whitespace. -/
def parseGoalPrefix? (prompt : String) : Option String :=
  let t := prompt.trimAscii.toString
  if t == "/goal" then some ""
  else if t.startsWith "/goal" then
    let rest := (t.drop 5).toString
    match rest.toList.head? with
    | some c => if c == ' ' || c == '\t' || c == '\n' || c == '\r' then some rest.trimAscii.toString else none
    | none => some ""
  else none

structure Selection where
  mode     : Mode
  revision : String
  deriving Repr, DecidableEq, Inhabited

def Selection.automatic : Selection := { mode := .automatic, revision := nilRevision }

private def cyberDir (workingDir : String) : System.FilePath :=
  System.FilePath.mk workingDir / "mission-cyber"

private def selectionPath (workingDir missionId : String) : System.FilePath :=
  cyberDir workingDir / s!"{missionId}.json"

private def pendingPath (workingDir missionId : String) : System.FilePath :=
  cyberDir workingDir / s!"{missionId}.next.json"

private def bindingPath (workingDir missionId : String) : System.FilePath :=
  cyberDir workingDir / s!"{missionId}.binding.json"

def receiptPath (workingDir missionId : String) : System.FilePath :=
  cyberDir workingDir / s!"{missionId}.receipt.json"

private def ensureCyberDir (workingDir : String) : IO (Except String Unit) := do
  ensurePrivateDir0700 (cyberDir workingDir)

def selectionToJson (sel : Selection) : String :=
  renderCompact (.obj #[("mode", .str sel.mode.asSnake), ("revision", .str sel.revision)])

def parseSelection? (raw : String) : Option Selection := do
  let jv ← (parse raw).toOption
  let mode ← parseMode? ((jv.fieldStr? "mode").getD "")
  let rev ← parseUuidCanonical? ((jv.fieldStr? "revision").getD "")
  some { mode := mode, revision := rev }

private def readSelectionFile? (path : System.FilePath) : IO (Except String (Option Selection)) := do
  if !(← path.pathExists) then return .ok none
  let raw ← IO.FS.readFile path
  match parseSelection? raw with
  | some sel => return .ok (some sel)
  | none => return .error "corrupt"

/-- Pending next-turn selection wins; missing files are Automatic. Corrupt JSON fails closed. -/
def readSelection (workingDir missionId : String) : IO (Except String Selection) := do
  match ← readSelectionFile? (pendingPath workingDir missionId) with
  | .error _ => return .error "The next-turn cyber setting is unreadable."
  | .ok (some sel) => return .ok sel
  | .ok none =>
    match ← readSelectionFile? (selectionPath workingDir missionId) with
    | .error _ => return .error "The mission cyber setting is unreadable; refusing to guess a program."
    | .ok (some sel) => return .ok sel
    | .ok none => return .ok Selection.automatic

def writePending (workingDir missionId : String) (sel : Selection) : IO (Except String Unit) := do
  match ← ensureCyberDir workingDir with
  | .error e => return .error e
  | .ok () => writeAtomicPrivate0600 (pendingPath workingDir missionId) (selectionToJson sel).toUTF8

def writeCommitted (workingDir missionId : String) (sel : Selection) : IO (Except String Unit) := do
  match ← ensureCyberDir workingDir with
  | .error e => return .error e
  | .ok () =>
    match ← writeAtomicPrivate0600 (selectionPath workingDir missionId) (selectionToJson sel).toUTF8 with
    | .error e => return .error e
    | .ok () =>
      try IO.FS.removeFile (pendingPath workingDir missionId) catch _ => pure ()
      return .ok ()

/-- Promote the pending selection only when the client still agrees with what was saved. -/
def promote (workingDir missionId : String) (mode : Mode) (revision : String) : IO (Except String Selection) := do
  match ← readSelection workingDir missionId with
  | .error e => return .error e
  | .ok saved =>
    if saved.mode == mode && saved.revision == revision then
      match ← writeCommitted workingDir missionId saved with
      | .error e => return .error e
      | .ok () => return .ok saved
    else
      return .error clientSelectionConflict

def validateClientSelection (saved : Selection) (mode? : Option Mode) (revision? : Option String) : Except String Unit := do
  if mode? == some saved.mode && revision? == some saved.revision then
    pure ()
  else if mode?.isNone && revision?.isNone && saved.mode == .automatic then
    pure ()
  else
    throw clientSelectionConflict

structure Binding where
  revision : String
  key      : String
  model    : String
  deriving Repr, DecidableEq

def parseBinding? (raw : String) : Option Binding := do
  let jv ← (parse raw).toOption
  match jv.asArr? with
  | some xs =>
    let rev ← parseUuidCanonical? ((xs[0]?.bind JVal.asStr?).getD "")
    let key ← xs[1]?.bind JVal.asStr?
    let model ← xs[2]?.bind JVal.asStr?
    if key.isEmpty then none else some { revision := rev, key := key, model := model }
  | none =>
    let rev ← parseUuidCanonical? ((jv.fieldStr? "revision").getD "")
    let key ← jv.fieldStr? "key"
    let model := (jv.fieldStr? "model").getD ""
    if key.isEmpty then none else some { revision := rev, key := key, model := model }

def writeBinding (workingDir missionId : String) (b : Binding) : IO (Except String Unit) := do
  match ← ensureCyberDir workingDir with
  | .error e => return .error e
  | .ok () =>
    let body := renderCompact (.arr #[.str b.revision, .str b.key, .str b.model])
    writeAtomicPrivate0600 (bindingPath workingDir missionId) body.toUTF8

def readBinding? (workingDir missionId : String) : IO (Option Binding) := do
  let path := bindingPath workingDir missionId
  if !(← path.pathExists) then return none
  let raw ← IO.FS.readFile path
  return parseBinding? raw

structure Receipt where
  revision       : String
  requestedModel : String
  program        : String
  model          : String
  deriving Repr, DecidableEq

def parseReceipt? (raw : String) : Option Receipt := do
  let jv ← (parse raw).toOption
  let rev ← parseUuidCanonical? ((jv.fieldStr? "revision").getD "")
  let requested ← jv.fieldStr? "requested_model"
  let program ← jv.fieldStr? "program"
  let model ← jv.fieldStr? "model"
  some { revision := rev, requestedModel := requested, program := program, model := model }

def readReceipt? (workingDir missionId : String) : IO (Option Receipt) := do
  let path := receiptPath workingDir missionId
  if !(← path.pathExists) then return none
  let raw ← IO.FS.readFile path
  return parseReceipt? raw

def writeReceipt (workingDir missionId : String) (r : Receipt) : IO (Except String Unit) := do
  match ← ensureCyberDir workingDir with
  | .error e => return .error e
  | .ok () =>
    let body := renderCompact (.obj #[
      ("revision", .str r.revision),
      ("requested_model", .str r.requestedModel),
      ("program", .str r.program),
      ("model", .str r.model)
    ])
    writeAtomicPrivate0600 (receiptPath workingDir missionId) body.toUTF8

def knownCyberProgram (p : String) : Bool :=
  p == "standard" || p == "daybreak_blue" || p == "daybreak_red"

def receiptIsCurrent (backend modelOverride : String) (clientPlaced : Bool) (sel : Selection) (r : Receipt) : Bool :=
  backend == "codex" && !clientPlaced && r.revision == sel.revision &&
    (if modelOverride.isEmpty then defaultCodexModel else modelOverride) == r.requestedModel &&
    knownCyberProgram r.program

def selectionNote : String :=
  "Selection saved for the next launch. Account authorization is checked by the provider; activation is not confirmed by a successful save."

def selectionResponse (sel : Selection) : String :=
  renderCompact (.obj #[
    ("mode", .str sel.mode.asSnake),
    ("revision", .str sel.revision),
    ("status", .str "requested"),
    ("confirmed_program", .null),
    ("note", .str selectionNote)
  ])

def confirmedResponse (sel : Selection) (r : Receipt) : String :=
  renderCompact (.obj #[
    ("mode", .str sel.mode.asSnake),
    ("revision", .str sel.revision),
    ("status", .str "confirmed"),
    ("confirmed_program", .str r.program),
    ("confirmed_model", .str r.model),
    ("note", .str selectionNote)
  ])

/-- `remote=true` checks the saved model against the requested mode; local routes never refuse here. -/
def capabilityRefusal? (remote : Bool) (mode : Mode) (model? : Option String) : Option String :=
  if !remote then none
  else
    match mode.program (model?.getD defaultCodexModel) with
    | .ok _ => none
    | .error e => some e

def capabilitiesJson (remote : Bool) (mode : Mode) (model? : Option String) : String :=
  let refusal? := capabilityRefusal? remote mode model?
  renderCompact (.obj #[
    ("version", JVal.nat 2),
    ("request_field", .str "cyber_access"),
    ("native_goals_explicit", .bool false),
    ("route_supported", .bool refusal?.isNone),
    ("refusal", match refusal? with | none => .null | some e => .str e)
  ])

/-- The transport hint cannot override the operator's execution-bound selection.
    `selection = none` means the request is not execution-bound. -/
def enforceProxySelection (selection? : Option Selection) (model : String)
    (header? bodyProgram? : Option String) : Except String (Option String) := do
  match selection? with
  | none =>
    if header?.isSome || bodyProgram?.isSome then
      throw proxyBindingRequired
    else
      pure none
  | some sel =>
    let expected ← sel.mode.program model
    if let some h := header? then
      if some h != expected then throw proxySelectionConflict
    if let some v := bodyProgram? then
      if some v != expected || expected.isNone then throw proxySelectionConflict
    pure expected

/-- OpenAI `/v1/responses` with no user, password, query, or fragment. Empty key falls back to OAuth. -/
def cyberEntrySupported (provider bareModelId baseUrl apiKey : String) (hasOauth cliOwned : Bool) : Bool :=
  provider == "openai" &&
    (bareModelId == "gpt-6-sol" || bareModelId == "gpt-6.1-sol" || bareModelId == "gpt-6-astra" ||
     bareModelId == "gpt-5.6-sol" || bareModelId == "gpt-5.6-cyber" || bareModelId == "gpt-5.5") &&
    (if !apiKey.isEmpty then
      baseUrl == "https://api.openai.com/v1/responses" || baseUrl == "https://api.openai.com:443/v1/responses"
     else
      hasOauth && !cliOwned)

/-- Inject `"access_programs":{"cyber":program}` into an upstream JSON object body. -/
def injectAccessProgram (body : ByteArray) (program : String) : Except String ByteArray := do
  let raw := String.fromUTF8? body |>.getD ""
  let jv ← match parse raw with
    | .ok v => pure v
    | .error _ => throw "upstream body is not json"
  match jv with
  | .obj fields =>
    let filtered := fields.filter (fun (k, _) => k != "access_programs")
    let next := filtered.push ("access_programs", .obj #[("cyber", .str program)])
    pure (renderCompact (.obj next)).toUTF8
  | _ => throw "upstream body is not a json object"

/-- Read `/access_programs/cyber` from a JSON object, if present. -/
def bodyCyberProgram? (raw : String) : Option String := do
  let jv ← (parse raw).toOption
  let access ← jv.field? "access_programs"
  access.fieldStr? "cyber"

/-- Observe one SSE `data:` payload. Returns `(program, model)` when it confirms `expectedProgram`. -/
def observeSseData? (data expectedProgram : String) : Option (String × String) := do
  let jv ← (parse data).toOption
  let typ := (jv.fieldStr? "type").getD ""
  if typ != "response.created" && typ != "response.completed" then none
  let response ← jv.field? "response"
  let program ← response.field? "access_programs" >>= fun a => a.fieldStr? "cyber"
  if program != expectedProgram || !knownCyberProgram program then none
  let model ← response.fieldStr? "model"
  if model.isEmpty then none
  some (program, model)

/-- Validate Codex `/goal` prompt shape (`non-empty objective` and `no images`) via `orb_codex_goal_launch_step`. -/
def validateGoalMessage (prompt : String) (hasImages : Bool) : Except String Unit := do
  if let some obj := parseGoalPrefix? prompt then
    let verdict := Orb.Kernel.codexGoalLaunchStep
      1
      (if obj.isEmpty then 0 else 1)
      (if hasImages then 1 else 0)
      0 1 1 1 0 0
    if verdict == 6 then
      throw "Codex /goal requires a non-empty objective after `/goal`."
    if verdict == 7 then
      throw "Codex /goal does not accept image attachments on the goal-opening turn."

end OrbCore.Cyber
