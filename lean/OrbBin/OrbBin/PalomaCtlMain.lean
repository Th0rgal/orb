/-
  OrbBin.PalomaCtlMain: Native Lean `palomactl` Control-Plane CLI (`0 import Lean`),
  implementing `models` (`discover`, `export`, `validate`, `diff`, `snapshot update`),
  `status`, `reconcile`, `import-trackers`, `pr-gates` (backed directly by `Orb.Kernel.prGateStep`),
  `set-mode`, `dispatch-plan`, `repair-borrowed-tracks`, `validation-matrix`, and `cluster-lean-errors`.
-/
import Orb.Kernel
import LeanSys.Auth
import OrbBin.PosixExt
import OrbBin.UnicodeAlnum
import OrbBin.Json
import OrbBin.HttpClient

namespace OrbBin.PalomaCtl

open OrbBin.PosixExt
open OrbBin.Json
open OrbBin.HttpClient

def printUsage : IO Unit :=
  IO.println <|
    "usage:\n" ++
    "  palomactl models discover|export|diff|validate|snapshot update\n" ++
    "  palomactl status\n" ++
    "  palomactl reconcile [--api <url> [--token <jwt>] [--dir <trackers>] [slug...]]\n" ++
    "  palomactl import-trackers --api <url> [--token <jwt>] [--dir <trackers>] [--dry-run] [slug...]\n" ++
    "  palomactl pr-gates <owner/repo> <number> [--worker-head <sha>]\n" ++
    "  palomactl set-mode <project> <mode> --until <iso>\n" ++
    "  palomactl dispatch-plan --project <slug>\n" ++
    "  palomactl repair-borrowed-tracks --api <url> [--token <jwt>] [--apply]\n" ++
    "  palomactl validation-matrix [path]\n" ++
    "  palomactl cluster-lean-errors <log-path>"

def valueAfterFlag? (args : List String) (flag : String) : Option String :=
  match args with
  | [] => none
  | a :: b :: rest => if a == flag then some b else valueAfterFlag? (b :: rest) flag
  | [_] => none

def validateProjectSlug (slug : String) : Except String Unit := do
  if slug.isEmpty || slug == "." || slug == ".." || slug.contains '/' || slug.contains '\\' ||
     !slug.all (fun c => c.isAlphanum || c == '-' || c == '_') then
    throw "project slug must be non-empty and contain only ASCII letters, numbers, '-' or '_'"

def prGateRecommendation (code : UInt8) : String :=
  if code == 0 then "already_merged"
  else if code == 1 then "wait_for_ready_for_review"
  else if code == 2 then "closed_without_merge"
  else if code == 3 then "head_changed_since_worker"
  else if code == 4 then "action_required_external"
  else if code == 5 then "blocked_by_policy"
  else if code == 6 then "needs_update_with_base"
  else if code == 7 then "needs_conflict_resolution"
  else if code == 8 then "ready_for_review_or_merge"
  else "needs_checks_or_review"

/-! ### `cluster-lean-errors`: Exact Normalized SHA-256 Diagnostic Clustering -/

def normalizeDiagnostic (line : String) : String := Id.run do
  let mut chars : Array Char := Array.mkEmpty line.length
  let mut inDigits := false
  for ch in line.toList do
    if ch.isDigit then
      if !inDigits then chars := chars.push '#'
      inDigits := true
    else
      inDigits := false
      chars := chars.push ch.toLower
  let raw := String.ofList chars.toList
  let words := (raw.splitToList (fun c => c == ' ' || c == '\t' || c == '\r' || c == '\n')).filter (!·.isEmpty)
  return String.intercalate " " words

structure DiagCluster where
  fingerprint    : String
  representative : String
  count          : Nat
  deriving Repr, Inhabited

def clusterDiagnostics (raw : String) : JVal := Id.run do
  let mut clusters : Array DiagCluster := #[]
  for rawLine in raw.splitOn "\n" do
    let line := rawLine.trimAscii.toString
    if !line.isEmpty then
      let norm := normalizeDiagnostic line
      let fp := LeanSys.Auth.bytesToHexLower (LeanSys.Auth.sha256Bytes norm.toUTF8)
      match clusters.findIdx? (fun c => c.fingerprint == fp) with
      | some idx =>
        let cur := clusters[idx]!
        clusters := clusters.set! idx { cur with count := cur.count + 1 }
      | none =>
        clusters := clusters.push { fingerprint := fp, representative := line, count := 1 }
  let sorted := clusters.qsort (fun a b =>
    if a.count != b.count then a.count > b.count
    else a.representative < b.representative)
  return .arr (sorted.map fun c =>
    .obj #[
      ("fingerprint", .str c.fingerprint),
      ("representative", .str c.representative),
      ("count", .nat c.count)
    ])

/-! ### `pr-gates`: Fixture + `gh` CLI Loader & Direct `Orb.Kernel.prGateStep` Evaluator -/

private def isAcceptedCheckConclusion (c : String) : Bool :=
  let lc := c.trimAscii.toString.toLower
  lc == "success" || lc == "skipped" || lc == "neutral"

def evaluateAndAnnotatePrGates
    (rawGates : JVal) (ownerRepo : String) (number : Nat) (workerHead? : Option String) : JVal := Id.run do
  let state := (rawGates.fieldStr? "state").getD "OPEN"
  let draft := (rawGates.fieldBool? "draft").orElse (fun _ => rawGates.fieldBool? "isDraft") |>.getD false
  let merged := (rawGates.fieldBool? "merged").getD (state.toLower == "merged")
  let mergeable? : Option Bool :=
    match rawGates.field? "mergeable" with
    | some (.bool b) => some b
    | some (.str s) =>
      let ls := s.toLower
      if ls == "mergeable" then some true
      else if ls == "conflicting" then some false
      else none
    | _ => none
  let mergeStateStatus? := (rawGates.fieldStr? "merge_state_status")
    |>.orElse (fun _ => rawGates.fieldStr? "mergeStateStatus")
  let mssLower := (mergeStateStatus?.getD "").toLower
  let blocked := mssLower == "blocked"
  let behind := mssLower == "behind"
  let rawConflicting := (rawGates.fieldBool? "conflicting").getD false
  let conflicting := rawConflicting || mssLower == "dirty" || (mergeable? == some false && !blocked && !behind)
  let checks : Array JVal :=
    match rawGates.fieldArr? "checks" with
    | some arr => arr
    | none =>
      match rawGates.fieldArr? "statusCheckRollup" with
      | some rollup =>
        rollup.map fun item =>
          let name := (item.fieldStr? "name").orElse (fun _ => item.fieldStr? "context") |>.getD ""
          if let some st := item.fieldStr? "status" then
            .obj #[
              ("name", .str name),
              ("status", .str st.toLower),
              ("conclusion", match item.fieldStr? "conclusion" with | some c => .str c.toLower | none => .null)
            ]
          else
            let ctxState := ((item.fieldStr? "state").getD "").toLower
            let st := if ctxState == "success" || ctxState == "failure" || ctxState == "error" then "completed" else "in_progress"
            let concl := if ctxState == "success" then "success" else if ctxState == "failure" || ctxState == "error" then "failure" else ""
            .obj #[
              ("name", .str name),
              ("status", .str st),
              ("conclusion", .str concl)
            ]
      | none => #[]
  let workflowRuns := (rawGates.fieldArr? "workflow_runs").getD #[]
  let checksGreen := !checks.isEmpty && checks.all (fun c =>
    ((c.fieldStr? "status").getD "").toLower == "completed" &&
    match c.fieldStr? "conclusion" with
    | some concl => isAcceptedCheckConclusion concl
    | none => false)
  let actionRequired := workflowRuns.any (fun r =>
    ((r.fieldStr? "status").getD "").toLower == "completed" &&
    ((r.fieldStr? "conclusion").getD "").toLower == "action_required")
  let workflowRunsGreen := workflowRuns.isEmpty || workflowRuns.all (fun r =>
    ((r.fieldStr? "status").getD "").toLower == "completed" &&
    match r.fieldStr? "conclusion" with
    | some concl => isAcceptedCheckConclusion concl
    | none => false)
  let currentHead? := (rawGates.fieldStr? "current_head")
    |>.orElse (fun _ => rawGates.fieldStr? "headRefOid")
  let effectiveWorkerHead? :=
    match workerHead?.filter (!·.trimAscii.isEmpty) with
    | some wh => some wh.trimAscii.toString
    | none => rawGates.fieldStr? "worker_head"
  let exactHead := match effectiveWorkerHead?, currentHead? with
    | some wh, some ch => wh.toLower == ch.toLower
    | _, _ => true
  let closed := state.toLower == "closed"
  let code := Orb.Kernel.prGateStep
    (if merged then 1 else 0)
    (if draft then 1 else 0)
    (if closed then 1 else 0)
    (if exactHead then 1 else 0)
    (if actionRequired then 1 else 0)
    (if blocked then 1 else 0)
    (if behind then 1 else 0)
    (if conflicting then 1 else 0)
    (if checksGreen then 1 else 0)
    (if workflowRunsGreen then 1 else 0)
  let recStr := prGateRecommendation code
  let bugbot := (rawGates.fieldBool? "bugbot_accessible").getD false
  return .obj #[
    ("owner_repo", .str ownerRepo),
    ("number", .nat number),
    ("state", .str state),
    ("draft", .bool draft),
    ("merged", .bool merged),
    ("mergeable", match mergeable? with | some b => .bool b | none => .null),
    ("merge_state_status", match mergeStateStatus? with | some s => .str s | none => .null),
    ("conflicting", .bool conflicting),
    ("checks", .arr checks),
    ("workflow_runs", .arr workflowRuns),
    ("current_head", match currentHead? with | some h => .str h | none => .null),
    ("worker_head", match effectiveWorkerHead? with | some h => .str h | none => .null),
    ("bugbot_accessible", .bool bugbot),
    ("recommendation", .str recStr)
  ]

def loadPrGates (root : System.FilePath) (ownerRepo : String) (number : Nat) : IO (Except String JVal) := do
  let safeRepo := String.intercalate "__" (ownerRepo.splitOn "/")
  let f1 := root / ".paloma" / "fixtures" / s!"pr-{safeRepo}-{number}.json"
  let f2 := root / ".paloma" / "fixtures" / s!"pr-{number}.json"
  for cand in [f1, f2] do
    if (← cand.pathExists) then
      let raw ← IO.FS.readFile cand
      match Json.parse raw with
      | .ok j => return .ok j
      | .error e => return .error s!"invalid PR fixture `{cand}`: {e}"
  let out ← IO.Process.output {
    cmd := "gh"
    args := #[
      "pr", "view", toString number, "--repo", ownerRepo, "--json",
      "state,isDraft,mergeable,mergeStateStatus,headRefOid,statusCheckRollup,mergedAt"
    ]
  }
  if out.exitCode != 0 then
    return .error s!"gh pr view failed: {out.stderr.trimAscii.toString}"
  let prJson ← match Json.parse out.stdout with
    | .ok j => pure j
    | .error e => return .error s!"invalid gh pr view JSON: {e}"
  let merged := match prJson.field? "mergedAt" with
    | some .null | none => false
    | _ => true
  let mut enriched := prJson.setField "merged" (.bool merged)
  if let some headSha := prJson.fieldStr? "headRefOid" then
    let wfOut ← IO.Process.output {
      cmd := "gh"
      args := #[
        "run", "list", "--repo", ownerRepo, "--commit", headSha, "--limit", "100",
        "--json", "name,status,conclusion,headSha,url"
      ]
    }
    if wfOut.exitCode == 0 then
      if let .ok (.arr runs) := Json.parse wfOut.stdout then
        let mut seenWf : Array String := #[]
        let mut mapped : Array JVal := #[]
        for r in runs do
          let nm := (r.fieldStr? "name").getD ""
          if !seenWf.contains nm then
            seenWf := seenWf.push nm
            mapped := mapped.push <| JVal.obj #[
              ("name", .str nm),
              ("status", .str ((r.fieldStr? "status").getD "").toLower),
              ("conclusion", match r.fieldStr? "conclusion" with | some c => .str c.toLower | none => .null),
              ("head_sha", .str ((r.fieldStr? "headSha").orElse (fun _ => r.fieldStr? "head_sha") |>.getD "")),
              ("url", .str ((r.fieldStr? "url").orElse (fun _ => r.fieldStr? "html_url") |>.getD ""))
            ]
        enriched := enriched.setField "workflow_runs" (.arr mapped)
  return .ok enriched

/-! ### TOML / JSON Validation Matrix Parser (`validation-matrix`) -/

private structure TomlLexer where
  cs  : Array Char
  pos : Nat

private def tomlSkipWsAndComments (s : TomlLexer) : TomlLexer := Id.run do
  let mut p := s.pos
  while p < s.cs.size do
    let c := s.cs[p]!
    if c == ' ' || c == '\t' || c == '\r' || c == '\n' then
      p := p + 1
    else if c == '#' then
      p := p + 1
      while p < s.cs.size && s.cs[p]! != '\n' do p := p + 1
    else
      break
  return { s with pos := p }

private def tomlSkipHorizWsAndComment (s : TomlLexer) : TomlLexer := Id.run do
  let mut p := s.pos
  while p < s.cs.size && (s.cs[p]! == ' ' || s.cs[p]! == '\t' || s.cs[p]! == '\r') do
    p := p + 1
  if p < s.cs.size && s.cs[p]! == '#' then
    while p < s.cs.size && s.cs[p]! != '\n' do p := p + 1
  return { s with pos := p }

private def parseHexFixed? (cs : Array Char) (start count : Nat) : Option Nat := Id.run do
  if start + count > cs.size then return none
  let mut acc : Nat := 0
  for i in [0 : count] do
    let c := cs[start + i]!
    let v? :=
      if '0' ≤ c && c ≤ '9' then some (c.toNat - '0'.toNat)
      else if 'a' ≤ c && c ≤ 'f' then some (10 + c.toNat - 'a'.toNat)
      else if 'A' ≤ c && c ≤ 'F' then some (10 + c.toNat - 'A'.toNat)
      else none
    match v? with
    | some d => acc := acc * 16 + d
    | none => return none
  return some acc

private def tomlParseBasicString (s : TomlLexer) : Except String (String × TomlLexer) := do
  let multiline :=
    s.pos + 3 ≤ s.cs.size &&
    s.cs[s.pos]! == '"' && s.cs[s.pos + 1]! == '"' && s.cs[s.pos + 2]! == '"'
  let mut p := if multiline then s.pos + 3 else s.pos + 1
  if multiline && p < s.cs.size then
    if s.cs[p]! == '\r' && p + 1 < s.cs.size && s.cs[p + 1]! == '\n' then p := p + 2
    else if s.cs[p]! == '\n' then p := p + 1
  let mut out : Array Char := #[]
  let mut closed := false
  while p < s.cs.size && !closed do
    if multiline && p + 3 ≤ s.cs.size &&
       s.cs[p]! == '"' && s.cs[p + 1]! == '"' && s.cs[p + 2]! == '"' then
      let mut qCount := 3
      while p + qCount < s.cs.size && qCount < 5 && s.cs[p + qCount]! == '"' do
        qCount := qCount + 1
      if p + qCount < s.cs.size && s.cs[p + qCount]! == '"' then
        throw "six or more consecutive quotes in TOML multiline basic string"
      for _ in [0 : qCount - 3] do
        out := out.push '"'
      p := p + qCount
      closed := true
    else if !multiline && s.cs[p]! == '"' then
      p := p + 1
      closed := true
    else if !multiline && (s.cs[p]! == '\n' || s.cs[p]! == '\r') then
      throw "unterminated TOML basic string"
    else if s.cs[p]! == '\\' then
      if p + 1 ≥ s.cs.size then throw "unterminated TOML escape"
      let esc := s.cs[p + 1]!
      match esc with
      | 'b' => out := out.push '\x08'; p := p + 2
      | 't' => out := out.push '\t'; p := p + 2
      | 'n' => out := out.push '\n'; p := p + 2
      | 'f' => out := out.push '\x0c'; p := p + 2
      | 'r' => out := out.push '\r'; p := p + 2
      | '"' => out := out.push '"'; p := p + 2
      | '\\' => out := out.push '\\'; p := p + 2
      | 'u' =>
        let some cp := parseHexFixed? s.cs (p + 2) 4 | throw "invalid TOML \\uXXXX escape"
        out := out.push (Char.ofNat cp)
        p := p + 6
      | 'U' =>
        let some cp := parseHexFixed? s.cs (p + 2) 8 | throw "invalid TOML \\UXXXXXXXX escape"
        out := out.push (Char.ofNat cp)
        p := p + 10
      | '\n' | '\r' | ' ' | '\t' =>
        if !multiline then throw s!"invalid TOML escape \\{esc}"
        p := p + 1
        let mut sawNewline := false
        while p < s.cs.size && (s.cs[p]! == ' ' || s.cs[p]! == '\t' || s.cs[p]! == '\r' || s.cs[p]! == '\n') do
          if s.cs[p]! == '\n' then sawNewline := true
          p := p + 1
        if !sawNewline then throw "TOML line-ending backslash requires newline"
      | _ => throw s!"invalid TOML escape \\{esc}"
    else
      out := out.push s.cs[p]!
      p := p + 1
  if !closed then throw "unterminated TOML string"
  return (String.ofList out.toList, { s with pos := p })

private def tomlParseLiteralString (s : TomlLexer) : Except String (String × TomlLexer) := do
  let multiline :=
    s.pos + 3 ≤ s.cs.size &&
    s.cs[s.pos]! == '\'' && s.cs[s.pos + 1]! == '\'' && s.cs[s.pos + 2]! == '\''
  let mut p := if multiline then s.pos + 3 else s.pos + 1
  if multiline && p < s.cs.size then
    if s.cs[p]! == '\r' && p + 1 < s.cs.size && s.cs[p + 1]! == '\n' then p := p + 2
    else if s.cs[p]! == '\n' then p := p + 1
  let mut out : Array Char := #[]
  let mut closed := false
  while p < s.cs.size && !closed do
    if multiline && p + 3 ≤ s.cs.size &&
       s.cs[p]! == '\'' && s.cs[p + 1]! == '\'' && s.cs[p + 2]! == '\'' then
      let mut qCount := 3
      while p + qCount < s.cs.size && qCount < 5 && s.cs[p + qCount]! == '\'' do
        qCount := qCount + 1
      if p + qCount < s.cs.size && s.cs[p + qCount]! == '\'' then
        throw "six or more consecutive single quotes in TOML multiline literal string"
      for _ in [0 : qCount - 3] do
        out := out.push '\''
      p := p + qCount
      closed := true
    else if !multiline && s.cs[p]! == '\'' then
      p := p + 1
      closed := true
    else if !multiline && (s.cs[p]! == '\n' || s.cs[p]! == '\r') then
      throw "unterminated TOML literal string"
    else
      out := out.push s.cs[p]!
      p := p + 1
  if !closed then throw "unterminated TOML literal string"
  return (String.ofList out.toList, { s with pos := p })

private def tomlIsBareKeyChar (c : Char) : Bool :=
  ('a' ≤ c && c ≤ 'z') || ('A' ≤ c && c ≤ 'Z') || Char.isDigit c || c == '_' || c == '-'

private def tomlParseKey (s0 : TomlLexer) : Except String (String × TomlLexer) := do
  let s := tomlSkipHorizWsAndComment s0
  if s.pos ≥ s.cs.size then throw "unexpected EOF reading TOML key"
  let c := s.cs[s.pos]!
  if c == '"' then tomlParseBasicString s
  else if c == '\'' then tomlParseLiteralString s
  else
    let mut p := s.pos
    while p < s.cs.size && tomlIsBareKeyChar s.cs[p]! do p := p + 1
    if p == s.pos then throw s!"invalid TOML key character '{c}'"
    return (String.ofList (s.cs.extract s.pos p).toList, { s with pos := p })

private partial def tomlParseValue (s0 : TomlLexer) : Except String (JVal × TomlLexer) := do
  let s := tomlSkipWsAndComments s0
  if s.pos ≥ s.cs.size then throw "unexpected EOF reading TOML value"
  let c := s.cs[s.pos]!
  if c == '"' then
    let (str, s') ← tomlParseBasicString s
    return (.str str, s')
  else if c == '\'' then
    let (str, s') ← tomlParseLiteralString s
    return (.str str, s')
  else if c == '[' then
    let mut cur := tomlSkipWsAndComments { s with pos := s.pos + 1 }
    let mut items : Array JVal := #[]
    while cur.pos < cur.cs.size && cur.cs[cur.pos]! != ']' do
      let (v, nextS) ← tomlParseValue cur
      items := items.push v
      let afterVal := tomlSkipWsAndComments nextS
      if afterVal.pos < afterVal.cs.size && afterVal.cs[afterVal.pos]! == ',' then
        cur := tomlSkipWsAndComments { afterVal with pos := afterVal.pos + 1 }
      else
        cur := afterVal
        if cur.pos < cur.cs.size && cur.cs[cur.pos]! != ']' then
          throw "expected ',' or ']' in TOML array"
    if cur.pos ≥ cur.cs.size || cur.cs[cur.pos]! != ']' then
      throw "unterminated TOML array"
    return (.arr items, { cur with pos := cur.pos + 1 })
  else if c == '{' then
    let mut cur := tomlSkipHorizWsAndComment { s with pos := s.pos + 1 }
    let mut fields : Array (String × JVal) := #[]
    while cur.pos < cur.cs.size && cur.cs[cur.pos]! != '}' do
      let (k, sAfterK) ← tomlParseKey cur
      let sEq := tomlSkipHorizWsAndComment sAfterK
      if sEq.pos ≥ sEq.cs.size || sEq.cs[sEq.pos]! != '=' then
        throw "expected '=' in TOML inline table"
      let (v, sAfterV) ← tomlParseValue { sEq with pos := sEq.pos + 1 }
      fields := (fields.filter (fun (ek, _) => ek != k)).push (k, v)
      let afterField := tomlSkipHorizWsAndComment sAfterV
      if afterField.pos < afterField.cs.size && afterField.cs[afterField.pos]! == ',' then
        cur := tomlSkipHorizWsAndComment { afterField with pos := afterField.pos + 1 }
      else
        cur := afterField
        if cur.pos < cur.cs.size && cur.cs[cur.pos]! != '}' then
          throw "expected ',' or '}' in TOML inline table"
    if cur.pos ≥ cur.cs.size || cur.cs[cur.pos]! != '}' then
      throw "unterminated TOML inline table"
    return (.obj fields, { cur with pos := cur.pos + 1 })
  else
    let mut p := s.pos
    while p < s.cs.size &&
          s.cs[p]! != ' ' && s.cs[p]! != '\t' && s.cs[p]! != '\r' && s.cs[p]! != '\n' &&
          s.cs[p]! != ',' && s.cs[p]! != ']' && s.cs[p]! != '}' && s.cs[p]! != '#' do
      p := p + 1
    let rawTok := String.ofList (s.cs.extract s.pos p).toList
    if rawTok == "true" then return (.bool true, { s with pos := p })
    else if rawTok == "false" then return (.bool false, { s with pos := p })
    else
      let cleaned := String.ofList (rawTok.toList.filter (· != '_'))
      let withoutPlus := if cleaned.startsWith "+" then (cleaned.drop 1).toString else cleaned
      if let some n := withoutPlus.toNat? then
        return (.nat n, { s with pos := p })
      else if withoutPlus.startsWith "-" then
        if let some n := (withoutPlus.drop 1).toString.toNat? then
          return (JVal.int (-(Int.ofNat n)), { s with pos := p })
      throw s!"invalid TOML scalar value `{rawTok}`"

private def normalizeGateTableFields (fields : Array (String × JVal)) : JVal := Id.run do
  let mut g : JVal := .obj #[
    ("dependencies", .arr #[]),
    ("required", .bool true),
    ("mode", .str "incremental"),
    ("reuse", .bool true),
    ("artifacts", .arr #[])
  ]
  for (k, v) in fields do
    let normKey := if k == "depends_on" then "dependencies" else k
    g := g.setField normKey v
  return g

def parseValidationMatrixText (raw : String) : Except String JVal := do
  let trimmed := raw.trimAscii.toString
  if trimmed.startsWith "{" then
    return (← Json.parse trimmed)
  let mut lex : TomlLexer := { cs := raw.toList.toArray, pos := 0 }
  let mut version : Nat := 1
  let mut project? : Option String := none
  let mut profile? : Option String := none
  let mut gates : Array JVal := #[]
  let mut gatesStyle? : Option String := none
  let mut curGate : Option (Array (String × JVal)) := none
  while true do
    lex := tomlSkipWsAndComments lex
    if lex.pos ≥ lex.cs.size then break
    if lex.pos + 2 ≤ lex.cs.size && lex.cs[lex.pos]! == '[' && lex.cs[lex.pos + 1]! == '[' then
      lex := { lex with pos := lex.pos + 2 }
      let (secName, afterSec) ← tomlParseKey lex
      let sClose := tomlSkipHorizWsAndComment afterSec
      if secName != "gates" || sClose.pos + 2 > sClose.cs.size ||
         sClose.cs[sClose.pos]! != ']' || sClose.cs[sClose.pos + 1]! != ']' then
        throw s!"unsupported TOML array-of-tables header `[[{secName}]]`"
      if gatesStyle? == some "inline" then
        throw "cannot redefine static `gates` array with `[[gates]]`"
      gatesStyle? := some "aot"
      if let some g := curGate then
        gates := gates.push (normalizeGateTableFields g)
      curGate := some #[]
      lex := { sClose with pos := sClose.pos + 2 }
    else if lex.cs[lex.pos]! == '[' then
      throw "unexpected TOML table header in validation matrix"
    else
      let (k, afterKey) ← tomlParseKey lex
      let sEq := tomlSkipHorizWsAndComment afterKey
      if sEq.pos ≥ sEq.cs.size || sEq.cs[sEq.pos]! != '=' then
        throw s!"expected '=' after TOML key `{k}`"
      let (vParsed, afterVal) ← tomlParseValue { sEq with pos := sEq.pos + 1 }
      lex := afterVal
      match curGate with
      | none =>
        if k == "version" then
          let some vNat := vParsed.asNat? | throw "version must be an integer"
          version := vNat
        else if k == "project" then
          let some pStr := vParsed.asStr? | throw "project must be a string"
          project? := some pStr
        else if k == "profile" then
          let some profStr := vParsed.asStr? | throw "profile must be a string"
          profile? := some profStr
        else if k == "gates" then
          if gatesStyle?.isSome then
            throw "duplicate `gates` definition in validation matrix"
          let some gArr := vParsed.asArr? | throw "`gates` must be an array of gate tables"
          let mut normArr : Array JVal := Array.mkEmpty gArr.size
          for item in gArr do
            let some fields := item.asObj? | throw "each element of `gates` must be a table"
            normArr := normArr.push (normalizeGateTableFields fields)
          gates := normArr
          gatesStyle? := some "inline"
        else
          throw s!"unknown top-level validation matrix key `{k}`"
      | some g =>
        curGate := some ((g.filter (fun (ek, _) => ek != k)).push (k, vParsed))
  if let some g := curGate then
    gates := gates.push (normalizeGateTableFields g)
  let some project := project? | throw "missing required top-level `project` field"
  return .obj #[
    ("version", .nat version),
    ("project", .str project),
    ("profile", match profile? with | some p => .str p | none => .null),
    ("gates", .arr gates)
  ]

private def validGateId (id : String) : Bool :=
  !id.isEmpty && id.length ≤ 80 && id.all (fun c => c.isAlphanum || c == '_' || c == '-')

partial def checkGateCycle
    (id : String) (gates : Array JVal) (visiting visited : List String) : Except String (List String) := do
  if visited.contains id then return visited
  if visiting.contains id then throw s!"validation gate dependency cycle contains '{id}'"
  let some g := gates.find? (fun x => x.fieldStr? "id" == some id)
    | throw s!"unknown gate '{id}'"
  let deps := ((g.fieldArr? "dependencies").getD #[]).filterMap JVal.asStr?
  let mut vis := visited
  for dep in deps do
    vis ← checkGateCycle dep gates (id :: visiting) vis
  return id :: vis

private def requireStringArrayField (obj : JVal) (field gateCtx : String) (defaultEmpty : Bool := true) : Except String (Array String) := do
  match obj.field? field with
  | none =>
    if defaultEmpty then return #[]
    else throw s!"gate '{gateCtx}' missing required `{field}` array"
  | some (.arr items) =>
    let mut out : Array String := Array.mkEmpty items.size
    for item in items do
      match item with
      | .str s => out := out.push s
      | _ => throw s!"gate '{gateCtx}' field `{field}` must contain only strings"
    return out
  | some _ => throw s!"gate '{gateCtx}' field `{field}` must be an array of strings"

private def requireBoolField (obj : JVal) (field gateCtx : String) (defaultVal : Bool) : Except String Bool := do
  match obj.field? field with
  | none => return defaultVal
  | some (.bool b) => return b
  | some _ => throw s!"gate '{gateCtx}' field `{field}` must be a boolean"

private def requireOptStringField (obj : JVal) (field ctx : String) : Except String (Option String) := do
  match obj.field? field with
  | none | some .null => return none
  | some (.str s) => return some s
  | some _ => throw s!"{ctx} field `{field}` must be a string"

def validateMatrixJson (m : JVal) : Except String JVal := do
  let some topFields := m.asObj?
    | throw "validation matrix must be a JSON/TOML object"
  let allowedTop := #["version", "project", "profile", "gates"]
  for (k, _) in topFields do
    if !allowedTop.contains k then
      throw s!"unknown top-level validation matrix key `{k}`"
  let ver ← match m.field? "version" with
    | none => pure 1
    | some v =>
      match v.asNat? with
      | some n => pure n
      | none => throw "matrix.version must be a non-negative integer"
  if ver != 1 then throw s!"unsupported validation matrix version {ver}"
  let some projRaw := m.fieldStr? "project"
    | throw "matrix.project must be a string"
  let proj := projRaw.trimAscii.toString
  if proj.isEmpty then throw "matrix.project is required"
  let _ ← requireOptStringField m "profile" "matrix"
  let some gates := m.fieldArr? "gates"
    | throw "matrix.gates must be an array"
  if gates.isEmpty then throw "matrix.gates must not be empty"
  let allowedGate := #[
    "id", "description", "command", "cwd", "dependencies", "depends_on",
    "required", "mode", "reuse", "toolchain", "timeout_secs", "artifacts"
  ]
  let mut seen : List String := []
  for g in gates do
    let some gFields := g.asObj?
      | throw "each validation gate must be a table/object"
    for (gk, _) in gFields do
      if !allowedGate.contains gk then
        throw s!"unknown validation gate field `{gk}`"
    let some gid := g.fieldStr? "id"
      | throw "validation gate `id` must be a string"
    if !validGateId gid then throw s!"invalid gate id '{gid}'"
    if seen.contains gid then throw s!"duplicate gate id '{gid}'"
    seen := gid :: seen
    let _ ← requireOptStringField g "description" s!"gate '{gid}'"
    let _ ← requireOptStringField g "cwd" s!"gate '{gid}'"
    let _ ← requireOptStringField g "toolchain" s!"gate '{gid}'"
    let cmd ← requireStringArrayField g "command" gid (defaultEmpty := false)
    if cmd.isEmpty || cmd.any (fun a => a.any (· == '\x00')) then
      throw s!"gate '{gid}' requires a safe, non-empty argv"
    let _ ← requireStringArrayField g "dependencies" gid (defaultEmpty := true)
    let _ ← requireStringArrayField g "depends_on" gid (defaultEmpty := true)
    let _ ← requireStringArrayField g "artifacts" gid (defaultEmpty := true)
    let _ ← requireBoolField g "required" gid true
    let _ ← requireBoolField g "reuse" gid true
    let mode ← match g.field? "mode" with
      | none => pure "incremental"
      | some (.str s) => pure s
      | some _ => throw s!"gate '{gid}' field `mode` must be a string"
    if mode != "incremental" && mode != "clean" then
      throw s!"gate '{gid}' invalid mode '{mode}' (expected 'incremental' or 'clean')"
    match g.field? "timeout_secs" with
    | none | some .null => pure ()
    | some v =>
      match v.asNat? with
      | some n =>
        if n == 0 then throw s!"gate '{gid}' timeout_secs must be positive"
      | none => throw s!"gate '{gid}' timeout_secs must be a positive integer"
  for g in gates do
    let gid := (g.fieldStr? "id").getD ""
    let req ← requireBoolField g "required" gid true
    let depsA ← requireStringArrayField g "dependencies" gid
    let depsB ← requireStringArrayField g "depends_on" gid
    let deps := if !depsA.isEmpty then depsA else depsB
    for dep in deps do
      if dep == gid then throw s!"gate '{gid}' has invalid dependency '{dep}'"
      let some dg := gates.find? (fun x => x.fieldStr? "id" == some dep)
        | throw s!"gate '{gid}' has invalid dependency '{dep}'"
      let depReq ← requireBoolField dg "required" dep true
      if req && !depReq then
        throw s!"required gate '{gid}' depends on optional gate '{dep}'"
  let mut visited : List String := []
  for g in gates do
    let gid := (g.fieldStr? "id").getD ""
    visited ← checkGateCycle gid gates [] visited
  return m

/-! ### `models`: Snapshot-Directory Catalog Validate / Export / Diff / Discover / Update -/

private def isLeapYear (y : Nat) : Bool :=
  (y % 4 == 0 && y % 100 != 0) || (y % 400 == 0)

private def daysInMonth (y m : Nat) : Nat :=
  match m with
  | 1 | 3 | 5 | 7 | 8 | 10 | 12 => 31
  | 4 | 6 | 9 | 11 => 30
  | 2 => if isLeapYear y then 29 else 28
  | _ => 0

/-- Parse an RFC3339 timestamp (`YYYY-MM-DDTHH:MM:SS[.fff](Z|±HH:MM)`) into UTC epoch seconds. -/
def parseRfc3339Epoch? (raw : String) : Option Int := do
  let s := raw.trimAscii.toString
  let (datePart, rest0) ← match s.splitOn "T" with
    | [d, t] => some (d, t)
    | _ => match s.splitOn "t" with
      | [d, t] => some (d, t)
      | _ => none
  let [yStr, mStr, dStr] := datePart.splitOn "-" | none
  if yStr.length != 4 || mStr.length != 2 || dStr.length != 2 then none
  let y ← yStr.toNat?
  let mo ← mStr.toNat?
  let da ← dStr.toNat?
  if y < 1970 || mo < 1 || mo > 12 || da < 1 || da > daysInMonth y mo then none
  let (timePart, tzOffsetSec) ←
    if rest0.endsWith "Z" || rest0.endsWith "z" then
      some ((rest0.dropEnd 1).toString, (0 : Int))
    else if rest0.length > 6 then
      let tzSignPos := rest0.length - 6
      let pfx := (rest0.take tzSignPos).toString
      let sfx := (rest0.drop tzSignPos).toString
      let signChar := sfx.toList.headD ' '
      if signChar != '+' && signChar != '-' then none
      else
        match (sfx.drop 1).toString.splitOn ":" with
        | [ohS, omS] =>
          if ohS.length != 2 || omS.length != 2 then none
          else
            let oh ← ohS.toNat?
            let om ← omS.toNat?
            if oh > 23 || om > 59 then none
            else
              let mag : Int := Int.ofNat (oh * 3600 + om * 60)
              some (pfx, if signChar == '+' then mag else -mag)
        | _ => none
    else none
  let baseTime ← match timePart.splitOn "." with
    | [h] => some h
    | [h, frac] =>
      if !frac.isEmpty && frac.all Char.isDigit then some h else none
    | _ => none
  let [hhS, mmS, ssS] := baseTime.splitOn ":" | none
  if hhS.length != 2 || mmS.length != 2 || ssS.length != 2 then none
  let hh ← hhS.toNat?
  let mm ← mmS.toNat?
  let ss ← ssS.toNat?
  if hh > 23 || mm > 59 || ss > 60 then none
  let mut days : Nat := 0
  for yr in [1970:y] do
    days := days + (if isLeapYear yr then 366 else 365)
  for mn in [1:mo] do
    days := days + daysInMonth y mn
  days := days + (da - 1)
  let utcSec : Int := Int.ofNat (days * 86400 + hh * 3600 + mm * 60 + ss) - tzOffsetSec
  return utcSec

private def isSafeSnapshotSlug (s : String) : Bool :=
  !s.isEmpty && s.length < 100 && s.all (fun c => c.isAlphanum || c == '-' || c == '_')

private def validateSnapshotJson (v : JVal) : Except String (String × String × String × Array JVal) := do
  let some obj := v.asObj?
    | throw "snapshot must be a JSON object"
  let allowedKeys := #["schema_version", "provider_id", "access_profile", "source", "observed_at", "completeness", "models"]
  for (k, _) in obj do
    if !allowedKeys.contains k then
      throw s!"unknown snapshot field: {k}"
  let some schemaVer := v.fieldNat? "schema_version"
    | throw "missing or invalid schema_version"
  if schemaVer != 1 then
    throw "unsupported snapshot schema"
  let providerId := (v.fieldStr? "provider_id").getD ""
  let accessProfile := (v.fieldStr? "access_profile").getD ""
  if !isSafeSnapshotSlug providerId || !isSafeSnapshotSlug accessProfile then
    throw "invalid provider/profile"
  let source := (v.fieldStr? "source").getD ""
  if source != "curated" && source != "discovery" then
    throw "invalid snapshot source"
  let obsOpt := v.field? "observed_at"
  let hasObs ← match obsOpt with
    | none | some .null => pure false
    | some (.str s) =>
      if (parseRfc3339Epoch? s).isNone then
        throw "snapshot observed_at must be valid RFC3339"
      pure true
    | some _ => throw "snapshot observed_at must be string or null"
  if source == "discovery" && !hasObs then
    throw "discovery snapshot needs observed_at"
  let completeness := (v.fieldStr? "completeness").getD ""
  if completeness != "complete" && completeness != "partial" then
    throw "invalid snapshot completeness"
  let some models := v.fieldArr? "models"
    | throw "missing snapshot models array"
  if models.isEmpty then
    throw "empty snapshot cannot replace fallback models"
  let mut seenIds : Array String := #[]
  for m in models do
    let some _ := m.asObj?
      | throw "snapshot model entry must be a JSON object"
    let some mid := m.fieldStr? "id"
      | throw "snapshot model missing required string `id`"
    let some mname := m.fieldStr? "name"
      | throw s!"snapshot model '{mid}' missing required string `name`"
    let _ := mname
    match m.field? "description" with
    | none | some .null | some (.str _) => pure ()
    | some _ => throw s!"snapshot model '{mid}' `description` must be string or null"
    let hasCtrl := mid.toList.any (fun c => c.toNat < 0x20 || c.toNat == 0x7F)
    if mid.trimAscii.toString != mid || mid.isEmpty || mid.length > 256 || hasCtrl ||
       (mid.splitOn "://").length > 1 || mid.contains '@' || seenIds.contains mid then
      throw s!"invalid or duplicate model ID: {mid}"
    if providerId == "zai" && mid == "glm-5.3[1m]" then
      throw "use glm-5.3; context size is metadata, not an API ID"
    seenIds := seenIds.push mid
  return (providerId, accessProfile, completeness, models)

private def snapshotFilename (providerId accessProfile : String) : String :=
  s!"{providerId}-{accessProfile}.json"

def loadSnapshotDir (dir : System.FilePath) : IO (Except String (Array (String × JVal))) := do
  if !(← dir.isDir) then
    return .error s!"read {dir}: not a directory"
  let entries ← try dir.readDir catch e => return .error s!"read {dir}: {e}"
  let mut out : Array (String × JVal) := #[]
  for entry in entries do
    let p := entry.path
    if p.extension == some "json" then
      let raw ← try IO.FS.readFile p catch e => return .error s!"read {p}: {e}"
      let parsed ← match Json.parse raw with
        | .ok j => pure j
        | .error e => return .error s!"parse {p}: {e}"
      match validateSnapshotJson parsed with
      | .error e => return .error s!"{p}: {e}"
      | .ok (prov, prof, _, _) =>
        let expected := snapshotFilename prov prof
        if entry.fileName != expected then
          return .error s!"snapshot filename must match {expected}"
        if out.any (fun (k, _) => k == expected) then
          return .error "duplicate snapshot profile"
        out := out.push (expected, parsed)
  if out.isEmpty then
    return .error s!"no snapshots in {dir}"
  return .ok (out.qsort (fun a b => a.1 < b.1))

def writeSnapshotsToDir (dir : System.FilePath) (snapshots : Array JVal) : IO (Except String Nat) := do
  if snapshots.isEmpty then
    return .error "no successful exportable discoveries; no files changed"
  let mut validated : Array (String × JVal) := #[]
  for s in snapshots do
    match validateSnapshotJson s with
    | .error e => return .error e
    | .ok (prov, prof, _, _) =>
      validated := validated.push (snapshotFilename prov prof, s)
  IO.FS.createDirAll dir
  let pid ← getpid
  let mut seq : Nat := 0
  for (fname, snap) in validated do
    seq := seq + 1
    let tmp := dir / s!".{fname}.{pid}.{seq}.tmp"
    let dest := dir / fname
    IO.FS.writeFile tmp ((renderPretty snap) ++ "\n")
    IO.FS.rename tmp dest
  return .ok validated.size

def mergeSnapshotJson (existing incoming : JVal) : Except String JVal := do
  let (eProv, eProf, _, eModels) ← validateSnapshotJson existing
  let (iProv, iProf, iComp, iModels) ← validateSnapshotJson incoming
  if eProv != iProv || eProf != iProf then
    throw "snapshot profile mismatch"
  if iComp != "partial" then
    return incoming
  let mut byId : Array (String × JVal) := #[]
  for m in eModels do
    let mid := (m.fieldStr? "id").getD ""
    byId := byId.push (mid, m)
  for m in iModels do
    let mid := (m.fieldStr? "id").getD ""
    match byId.findIdx? (fun (k, _) => k == mid) with
    | some idx => byId := byId.set! idx (mid, m)
    | none => byId := byId.push (mid, m)
  let sortedModels := (byId.qsort (fun a b => a.1 < b.1)).map Prod.snd
  let merged := incoming.setField "models" (.arr sortedModels)
  let _ ← validateSnapshotJson merged
  return merged

def snapshotDiffJson (oldSnap newSnap : JVal) : JVal := Id.run do
  let newProv := (newSnap.fieldStr? "provider_id").getD ""
  let newProf := (newSnap.fieldStr? "access_profile").getD ""
  let newComp := (newSnap.fieldStr? "completeness").getD "partial"
  let oldModels := (oldSnap.fieldArr? "models").getD #[]
  let newModels := (newSnap.fieldArr? "models").getD #[]
  let mut added : Array JVal := #[]
  let mut absent : Array JVal := #[]
  let mut changed : Array JVal := #[]
  let sortedNew := newModels.qsort (fun a b => ((a.fieldStr? "id").getD "") < ((b.fieldStr? "id").getD ""))
  let sortedOld := oldModels.qsort (fun a b => ((a.fieldStr? "id").getD "") < ((b.fieldStr? "id").getD ""))
  for nm in sortedNew do
    let nid := (nm.fieldStr? "id").getD ""
    match sortedOld.find? (fun om => (om.fieldStr? "id").getD "" == nid) with
    | none => added := added.push (.str nid)
    | some om =>
      let oldName := (om.fieldStr? "name").getD ""
      let newName := (nm.fieldStr? "name").getD ""
      let oldDesc := om.fieldStr? "description"
      let newDesc := nm.fieldStr? "description"
      if oldName != newName || oldDesc != newDesc then
        changed := changed.push (.str nid)
  for om in sortedOld do
    let oid := (om.fieldStr? "id").getD ""
    if !sortedNew.any (fun nm => (nm.fieldStr? "id").getD "" == oid) then
      absent := absent.push (.str oid)
  return .obj #[
    ("provider_id", .str newProv),
    ("access_profile", .str newProf),
    ("completeness", .str newComp),
    ("added", .arr added),
    ("absent", .arr absent),
    ("removals_authoritative", .bool (newComp == "complete")),
    ("changed", .arr changed)
  ]

private def resolveDir (root : System.FilePath) (raw : String) : System.FilePath :=
  let p := System.FilePath.mk raw
  if p.isAbsolute then p else root / p

def runModelsCmd (root : System.FilePath) (args : List String) : IO (Except String Unit) := do
  match args with
  | "discover" :: rest =>
    let api? ← match valueAfterFlag? rest "--api" with
      | some u => pure (some u)
      | none => firstEnvNonEmpty ["SANDBOXED_API_URL", "HERMES_SANDBOXED_API_URL", "API_URL"]
    let some api := api? | return .error "missing --api or SANDBOXED_API_URL"
    let tok? ← match valueAfterFlag? rest "--token" with
      | some t => pure (some t)
      | none => firstEnvNonEmpty ["SANDBOXED_API_TOKEN", "HERMES_SANDBOXED_API_TOKEN", "API_TOKEN"]
    let base := stripTrailingSlash api
    match (← sendJsonRequest "POST" (base ++ "/api/providers/catalog/refresh") tok? none #[] 300000) with
    | .ok (st, _, _) =>
      if st < 200 || st >= 300 then
        return .error s!"catalog API returned HTTP {st}"
    | .error _ => return .error "catalog API transport error"
    match (← sendJsonRequest "GET" (base ++ "/api/providers/discovery") tok? none #[] 300000) with
    | .ok (st, _, some j) =>
      if st < 200 || st >= 300 then
        return .error s!"catalog API returned HTTP {st}"
      IO.println (renderPretty j)
      return .ok ()
    | .ok (st, _, none) => return .error s!"catalog API returned HTTP {st}"
    | .error _ => return .error "catalog API transport error"
  | "export" :: rest =>
    if let some src := valueAfterFlag? rest "--source" then
      if src != "last-success" then
        return .error "only --source last-success is supported"
    let some outRaw := valueAfterFlag? rest "--output"
      | return .error "missing --output DIR"
    let api? ← match valueAfterFlag? rest "--api" with
      | some u => pure (some u)
      | none => firstEnvNonEmpty ["SANDBOXED_API_URL", "HERMES_SANDBOXED_API_URL", "API_URL"]
    let some api := api? | return .error "missing --api or SANDBOXED_API_URL"
    let tok? ← match valueAfterFlag? rest "--token" with
      | some t => pure (some t)
      | none => firstEnvNonEmpty ["SANDBOXED_API_TOKEN", "HERMES_SANDBOXED_API_TOKEN", "API_TOKEN"]
    let base := stripTrailingSlash api
    match (← sendJsonRequest "GET" (base ++ "/api/providers/snapshots") tok? none #[] 300000) with
    | .ok (st, _, some (.arr snaps)) =>
      if st < 200 || st >= 300 then
        return .error s!"catalog API returned HTTP {st}"
      let outDir := resolveDir root outRaw
      match (← writeSnapshotsToDir outDir snaps) with
      | .error e => return .error e
      | .ok cnt =>
        IO.println <| renderCompact <| JVal.obj #[("written", .nat cnt), ("directory", .str outRaw)]
        return .ok ()
    | .ok (st, _, _) => return .error s!"catalog API returned HTTP {st}"
    | .error _ => return .error "catalog API transport error"
  | "validate" :: rest =>
    let some dirArg := rest.find? (fun s => !s.startsWith "--")
      | return .error "models validate DIR"
    match (← loadSnapshotDir (resolveDir root dirArg)) with
    | .error e => return .error e
    | .ok snaps =>
      IO.println <| renderCompact <| JVal.obj #[("valid", .bool true), ("snapshots", .nat snaps.size)]
      return .ok ()
  | "diff" :: rest =>
    let baseRaw := (valueAfterFlag? rest "--snapshot-dir").getD "catalog/snapshots"
    let incoming? := (valueAfterFlag? rest "--from").orElse (fun _ => rest.find? (fun s => !s.startsWith "--"))
    let some incRaw := incoming?
      | return .error "models diff --snapshot-dir DIR --from DIR"
    let oldSnaps ← match (← loadSnapshotDir (resolveDir root baseRaw)) with
      | .ok s => pure s
      | .error e => return .error e
    let newSnaps ← match (← loadSnapshotDir (resolveDir root incRaw)) with
      | .ok s => pure s
      | .error e => return .error e
    let changes := newSnaps.map fun (fname, newS) =>
      match oldSnaps.find? (fun (k, _) => k == fname) with
      | some (_, oldS) => snapshotDiffJson oldS newS
      | none =>
        let mCount := ((newS.fieldArr? "models").getD #[]).size
        JVal.obj #[("file", .str fname), ("new_profile", .bool true), ("models", .nat mCount)]
    IO.println <| renderPretty <| JVal.obj #[
      ("changes", .arr changes),
      ("missing_profiles_are_preserved", .bool true)
    ]
    return .ok ()
  | "snapshot" :: "update" :: rest =>
    let some fromRaw := valueAfterFlag? rest "--from"
      | return .error "missing --from DIR"
    let destRaw := (valueAfterFlag? rest "--snapshot-dir").getD "catalog/snapshots"
    let oldSnaps ← match (← loadSnapshotDir (resolveDir root destRaw)) with
      | .ok s => pure s
      | .error e => return .error e
    let newSnaps ← match (← loadSnapshotDir (resolveDir root fromRaw)) with
      | .ok s => pure s
      | .error e => return .error e
    let mut prepared : Array JVal := #[]
    for (fname, inc) in newSnaps do
      match oldSnaps.find? (fun (k, _) => k == fname) with
      | some (_, prev) =>
        match mergeSnapshotJson prev inc with
        | .ok m => prepared := prepared.push m
        | .error e => return .error e
      | none => prepared := prepared.push inc
    match (← writeSnapshotsToDir (resolveDir root destRaw) prepared) with
    | .error e => return .error e
    | .ok cnt =>
      IO.println <| renderCompact <| JVal.obj #[("updated", .nat cnt), ("directory", .str destRaw)]
      return .ok ()
  | _ =>
    return .error "models: discover --connected [--api URL] | export --source last-success --output DIR | validate DIR | diff --snapshot-dir DIR --from DIR | snapshot update --from DIR [--snapshot-dir DIR]"

/-! ### `status`, `reconcile`, `set-mode`, `dispatch-plan`, `import-trackers`, `repair-borrowed-tracks` -/

def loadFixtureMissions (root : System.FilePath) : IO (Array JVal) := do
  let p := root / ".paloma" / "fixtures" / "missions.json"
  if !(← p.pathExists) then return #[]
  let raw ← IO.FS.readFile p
  match Json.parse raw with
  | .ok (.arr xs) => return xs
  | .ok v => return (v.fieldArr? "missions").getD #[]
  | .error _ => return #[]

private partial def collectMdFiles (dir : System.FilePath) (acc : Array System.FilePath) : IO (Array System.FilePath) := do
  if !(← dir.isDir) then return acc
  let entries ← try dir.readDir catch _ => pure #[]
  let mut out := acc
  for entry in entries do
    let p := entry.path
    if (← p.isDir) then
      out ← collectMdFiles p out
    else if p.extension == some "md" then
      if !out.contains p then
        out := out.push p
  return out

private def isWordChar (c : Char) : Bool :=
  c.isAlphanum || c == '_'

private def isHexLowerOrUpper (c : Char) : Bool :=
  ('0' ≤ c && c ≤ '9') || ('a' ≤ c && c ≤ 'f') || ('A' ≤ c && c ≤ 'F')

private def isUuidLike36 (s : String) : Bool :=
  match s.splitOn "-" with
  | [p1, p2, p3, p4, p5] =>
    p1.length == 8 && p2.length == 4 && p3.length == 4 && p4.length == 4 && p5.length == 12 &&
    [p1, p2, p3, p4, p5].all (fun p => p.all isHexLowerOrUpper)
  | _ => false

/-- Extract `(missionIdRef, byteCharIdx)` pairs matching `(?i)\bmission(?:[_ -]?id)?[:# ]+([0-9a-f][0-9a-f-]{5,36})\b`. -/
private def extractMissionRefsWithIdx (text : String) : Array (String × Nat) := Id.run do
  let cs := text.toList.toArray
  let n := cs.size
  let mut out : Array (String × Nat) := #[]
  let mut i := 0
  while i + 7 ≤ n do
    let prevWord := i > 0 && isWordChar cs[i - 1]!
    let mWord := String.ofList (cs.extract i (i + 7)).toList
    if !prevWord && mWord.toLower == "mission" then
      let mut j := i + 7
      -- optional `(?:[_ -]?id)?`
      let jSaved := j
      if j < n && (cs[j]! == '_' || cs[j]! == ' ' || cs[j]! == '-') then
        j := j + 1
      if j + 2 ≤ n && (String.ofList (cs.extract j (j + 2)).toList).toLower == "id" then
        j := j + 2
      else
        j := jSaved
      let sepStart := j
      while j < n && (cs[j]! == ':' || cs[j]! == '#' || cs[j]! == ' ') do
        j := j + 1
      if j > sepStart && j < n && isHexLowerOrUpper cs[j]! then
        let idStart := j
        while j < n && (isHexLowerOrUpper cs[j]! || cs[j]! == '-') && (j - idStart) < 37 do
          j := j + 1
        let idLen := j - idStart
        let nextWord := j < n && isWordChar cs[j]!
        if 6 ≤ idLen && idLen ≤ 37 && !nextWord then
          let mid := String.ofList (cs.extract idStart j).toList
          out := out.push (mid, i)
          i := j
        else
          i := i + 1
      else
        i := i + 1
    else
      i := i + 1
  return out

/-- Extract PR numbers matching `(?i)\b(?:pr|pull request)\s*#?(\d+)\b`. -/
private def extractDocPrRefs (text : String) : Array Nat := Id.run do
  let cs := text.toList.toArray
  let n := cs.size
  let mut out : Array Nat := #[]
  let mut i := 0
  while i < n do
    let prevWord := i > 0 && isWordChar cs[i - 1]!
    let mut afterKw? : Option Nat := none
    if !prevWord && i + 2 ≤ n && (String.ofList (cs.extract i (i + 2)).toList).toLower == "pr" then
      if i + 2 == n || !isWordChar cs[i + 2]! then
        afterKw? := some (i + 2)
    if afterKw?.isNone && !prevWord && i + 12 ≤ n &&
       (String.ofList (cs.extract i (i + 12)).toList).toLower == "pull request" then
      if i + 12 == n || !isWordChar cs[i + 12]! then
        afterKw? := some (i + 12)
    match afterKw? with
    | none => i := i + 1
    | some j0 =>
      let mut j := j0
      while j < n && cs[j]!.isWhitespace do j := j + 1
      if j < n && cs[j]! == '#' then j := j + 1
      let dStart := j
      while j < n && cs[j]!.isDigit do j := j + 1
      let nextWord := j < n && isWordChar cs[j]!
      if j > dStart && !nextWord then
        if let some num := (String.ofList (cs.extract dStart j).toList).toNat? then
          out := out.push num
        i := j
      else
        i := i + 1
  return out

private def isRepoSlugChar (c : Char) : Bool :=
  c.isAlphanum || c == '_' || c == '.' || c == '-'

/-- Extract first `owner/repo` matching `(?im)\b(?:repo|repository|github repo|github_repository|owner/repo)\s*[:=]\s*(?:https://github\.com/)?([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)`. -/
private def extractOwnerRepo? (text : String) : Option String := Id.run do
  for rawLine in text.splitOn "\n" do
    let cs := rawLine.toList.toArray
    let n := cs.size
    let mut i := 0
    while i < n do
      let prevWord := i > 0 && isWordChar cs[i - 1]!
      if !prevWord then
        let remLow := (String.ofList (cs.extract i n).toList).toLower
        let mut kwLen := 0
        for kw in ["github_repository", "github repo", "repository", "owner/repo", "repo"] do
          if kwLen == 0 && remLow.startsWith kw then
            let endIdx := i + kw.length
            if endIdx == n || !isWordChar cs[endIdx]! then
              kwLen := kw.length
        if kwLen > 0 then
          let mut j := i + kwLen
          while j < n && (cs[j]! == ' ' || cs[j]! == '\t') do j := j + 1
          if j < n && (cs[j]! == ':' || cs[j]! == '=') then
            j := j + 1
            while j < n && (cs[j]! == ' ' || cs[j]! == '\t') do j := j + 1
            let afterSep := String.ofList (cs.extract j n).toList
            let stripped :=
              if afterSep.startsWith "https://github.com/" then (afterSep.drop 19).toString
              else afterSep
            let scs := stripped.toList.toArray
            let mut k := 0
            while k < scs.size && isRepoSlugChar scs[k]! do k := k + 1
            if k > 0 && k < scs.size && scs[k]! == '/' then
              let owner := String.ofList (scs.extract 0 k).toList
              let mStart := k + 1
              let mut m := mStart
              while m < scs.size && isRepoSlugChar scs[m]! do m := m + 1
              if m > mStart then
                let repo := String.ofList (scs.extract mStart m).toList
                return some s!"{owner}/{repo}"
      i := i + 1
  return none

private def relDocPath (root full : System.FilePath) : String :=
  let rStr := root.toString
  let fStr := full.toString
  let pfx := if rStr.endsWith "/" then rStr else rStr ++ "/"
  if fStr.startsWith pfx then (fStr.drop pfx.length).toString else fStr

def scanProjectDocs (root : System.FilePath) : IO (Array JVal) := do
  let mut paths : Array System.FilePath := #[]
  paths ← collectMdFiles (root / ".paloma" / "projects") paths
  paths ← collectMdFiles (root / "projects") paths
  let docsDir := root / "docs"
  if (← docsDir.isDir) then
    let entries ← try docsDir.readDir catch _ => pure #[]
    for entry in entries do
      let p := entry.path
      if p.extension == some "md" && entry.fileName.startsWith "PALOMA_" && !paths.contains p then
        paths := paths.push p
  let mut out : Array (String × JVal) := #[]
  for p in paths do
    let text ← try IO.FS.readFile p catch _ => pure ""
    let mRefs := (extractMissionRefsWithIdx text).map (fun (m, _) => JVal.str m)
    let prRefs := (extractDocPrRefs text).map JVal.nat
    let ownerRepoVal := match extractOwnerRepo? text with | some r => JVal.str r | none => JVal.null
    let rel := relDocPath root p
    out := out.push (rel, .obj #[
      ("path", .str rel),
      ("mission_refs", .arr mRefs),
      ("pr_refs", .arr prRefs),
      ("owner_repo", ownerRepoVal)
    ])
  return (out.qsort (fun a b => a.1 < b.1)).map Prod.snd

private def findSubstrCharIdx? (cs : Array Char) (pat : Array Char) : Option Nat := Id.run do
  if pat.isEmpty || pat.size > cs.size then return none
  for i in [0 : cs.size - pat.size + 1] do
    let mut ok := true
    for j in [0 : pat.size] do
      if cs[i + j]! != pat[j]! then ok := false
    if ok then return some i
  return none

private def trackerStatusForMission? (text missionId : String) : Option String := Id.run do
  let cs := text.toList.toArray
  let pat := missionId.toList.toArray
  let some startIdx := findSubstrCharIdx? cs pat | return none
  let afterStart := startIdx + pat.size
  let afterCs := cs.extract afterStart cs.size
  let afterText := String.ofList afterCs.toList
  let nextRefs := extractMissionRefsWithIdx afterText
  let limit := Nat.min 500 (match nextRefs[0]? with | some (_, idx) => idx | none => afterCs.size)
  let window := afterCs.extract 0 limit
  let wn := window.size
  let mut i := 0
  while i + 6 ≤ wn do
    let prevWord := i > 0 && isWordChar window[i - 1]!
    let w6 := (String.ofList (window.extract i (i + 6)).toList).toLower
    if !prevWord && w6 == "status" then
      let mut j := i + 6
      let sepStart := j
      while j < wn && (window[j]! == ':' || window[j]! == '=' || window[j]! == ' ') do
        j := j + 1
      if j > sepStart then
        let stStart := j
        while j < wn && ((window[j]!.toLower ≥ 'a' && window[j]!.toLower ≤ 'z') || window[j]! == '_') do
          j := j + 1
        if j > stStart then
          return some (String.ofList (window.extract stStart j).toList).toLower
    i := i + 1
  return none

private def lineHasWordOpen (line : String) : Bool := Id.run do
  let cs := line.toList.toArray
  let n := cs.size
  if n < 4 then return false
  for i in [0 : n - 3] do
    let prevWord := i > 0 && isWordChar cs[i - 1]!
    let nextWord := i + 4 < n && isWordChar cs[i + 4]!
    if !prevWord && !nextWord && (String.ofList (cs.extract i (i + 4)).toList).toLower == "open" then
      return true
  return false

private def lineHasPrNumber (line : String) (number : Nat) : Bool := Id.run do
  let numChars := (toString number).toList.toArray
  let cs := line.toList.toArray
  let n := cs.size
  let mut i := 0
  while i < n do
    if cs[i]! == '#' then
      if i + 1 + numChars.size ≤ n then
        let slice := cs.extract (i + 1) (i + 1 + numChars.size)
        let nextWord := i + 1 + numChars.size < n && isWordChar cs[i + 1 + numChars.size]!
        if slice == numChars && !nextWord then return true
    let prevWord := i > 0 && isWordChar cs[i - 1]!
    if !prevWord && i + 2 ≤ n && (String.ofList (cs.extract i (i + 2)).toList).toLower == "pr" then
      if i + 2 < n && !isWordChar cs[i + 2]! then
        let mut j := i + 2
        while j < n && cs[j]!.isWhitespace do j := j + 1
        if j < n && cs[j]! == '#' then
          j := j + 1
          while j < n && cs[j]!.isWhitespace do j := j + 1
        if j + numChars.size ≤ n then
          let slice := cs.extract j (j + numChars.size)
          let nextWord := j + numChars.size < n && isWordChar cs[j + numChars.size]!
          if slice == numChars && !nextWord then return true
    i := i + 1
  return false

def lineMentionsOpenPr (text : String) (number : Nat) : Bool :=
  (text.splitOn "\n").any fun line => lineHasPrNumber line number && lineHasWordOpen line

private def loadPrFixtureOnly? (root : System.FilePath) (ownerRepo? : Option String) (number : Nat) : IO (Option JVal) := do
  let mut cands : Array System.FilePath := #[]
  if let some repo := ownerRepo? then
    let safe := String.intercalate "__" (repo.splitOn "/")
    cands := cands.push (root / ".paloma" / "fixtures" / s!"pr-{safe}-{number}.json")
  cands := cands.push (root / ".paloma" / "fixtures" / s!"pr-fixture__repo-{number}.json")
  cands := cands.push (root / ".paloma" / "fixtures" / s!"pr-{number}.json")
  for cand in cands do
    if (← cand.pathExists) then
      if let .ok j := Json.parse (← IO.FS.readFile cand) then
        return some j
  return none

def detectLocalDrift (root : System.FilePath) (docs missions : Array JVal) : IO (Array JVal) := do
  let liveIds := missions.filterMap (·.fieldStr? "id")
  let mut drift : Array JVal := #[]
  for doc in docs do
    let docPath := (doc.fieldStr? "path").getD ""
    let text ← try IO.FS.readFile (root / docPath) catch _ => pure ""
    let mRefs := ((doc.fieldArr? "mission_refs").getD #[]).filterMap JVal.asStr?
    for mid in mRefs do
      if !isUuidLike36 mid then
        drift := drift.push <| .obj #[
          ("kind", .str "short_mission_id"),
          ("source", .str docPath),
          ("detail", .str s!"mission ref `{mid}` is not a full UUID")
        ]
      else if !liveIds.contains mid then
        drift := drift.push <| .obj #[
          ("kind", .str "stale_mission_ref"),
          ("source", .str docPath),
          ("detail", .str s!"mission `{mid}` is not in live missions")
        ]
    for m in missions do
      let mid := (m.fieldStr? "id").getD ""
      let liveSt := (m.fieldStr? "status").getD ""
      if !mid.isEmpty && !liveSt.isEmpty then
        if let some found := trackerStatusForMission? text mid then
          if found != liveSt then
            drift := drift.push <| .obj #[
              ("kind", .str "live_mismatch"),
              ("source", .str docPath),
              ("detail", .str s!"mission `{mid}` tracker status `{found}` differs from live `{liveSt}`")
            ]
    let prRefs := ((doc.fieldArr? "pr_refs").getD #[]).filterMap JVal.asNat?
    let ownerRepo? := doc.fieldStr? "owner_repo"
    for prNum in prRefs do
      if lineMentionsOpenPr text prNum then
        if let some prFix ← loadPrFixtureOnly? root ownerRepo? prNum then
          if (prFix.fieldBool? "merged").getD false then
            drift := drift.push <| .obj #[
              ("kind", .str "pr_listed_open_but_merged"),
              ("source", .str docPath),
              ("detail", .str s!"PR #{prNum} is listed open but live PR is merged")
            ]
  return drift

def buildLocalState (root : System.FilePath) : IO JVal := do
  let missions ← loadFixtureMissions root
  let docs ← scanProjectDocs root
  let drift ← detectLocalDrift root docs missions
  let mut counts : Array (String × Nat) := #[]
  for m in missions do
    let rawSt := (m.fieldStr? "status").getD ""
    let st := if rawSt.isEmpty then "unknown" else rawSt
    match counts.findIdx? (fun (k, _) => k == st) with
    | some idx =>
      let (k, n) := counts[idx]!
      counts := counts.set! idx (k, n + 1)
    | none => counts := counts.push (st, 1)
  let sortedCounts := counts.qsort (fun a b => a.1 < b.1)
  let ts ← nowEpoch
  return .obj #[
    ("generated_at", .str s!"{ts}"),
    ("project_docs", .arr docs),
    ("mission_counts", .obj (sortedCounts.map fun (k, n) => (k, .nat n))),
    ("missions", .arr missions),
    ("drift", .arr drift)
  ]

private def driftKindDebugName (kind : String) : String :=
  match kind with
  | "short_mission_id" => "ShortMissionId"
  | "stale_mission_ref" => "StaleMissionRef"
  | "pr_listed_open_but_merged" => "PrListedOpenButMerged"
  | "live_mismatch" => "LiveMismatch"
  | other => other

def renderStatusText (state : JVal) : String := Id.run do
  let docs := ((state.fieldArr? "project_docs").getD #[]).size
  let missions := ((state.fieldArr? "missions").getD #[]).size
  let drift := (state.fieldArr? "drift").getD #[]
  let mut out := s!"paloma control-plane status\nproject_docs={docs}\nmissions={missions}\n"
  if let some mc := (state.field? "mission_counts") >>= JVal.asObj? then
    for (st, cnt) in mc do
      out := out ++ s!"mission_status.{st}={(cnt.asNat?).getD 0}\n"
  out := out ++ s!"drift={drift.size}\n"
  for d in drift do
    let k := driftKindDebugName ((d.fieldStr? "kind").getD "")
    let det := (d.fieldStr? "detail").getD ""
    let src := (d.fieldStr? "source").getD ""
    out := out ++ s!"- {k}: {det} ({src})\n"
  return out

def renderStatusMd (state : JVal) : String := Id.run do
  let gen := (state.fieldStr? "generated_at").getD "0"
  let mut out := s!"# Paloma Status\n\nGenerated: `{gen}`\n\n## Mission Counts\n\n"
  let mc := ((state.field? "mission_counts") >>= JVal.asObj?).getD #[]
  if mc.isEmpty then
    out := out ++ "- none\n"
  else
    for (st, cnt) in mc do
      out := out ++ s!"- `{st}`: {(cnt.asNat?).getD 0}\n"
  out := out ++ "\n## Drift\n\n"
  let drift := (state.fieldArr? "drift").getD #[]
  if drift.isEmpty then
    out := out ++ "- none\n"
  else
    for d in drift do
      let k := driftKindDebugName ((d.fieldStr? "kind").getD "")
      let det := (d.fieldStr? "detail").getD ""
      let src := (d.fieldStr? "source").getD ""
      out := out ++ s!"- `{k}`: {det} ({src})\n"
  return out

/-! ### `import-trackers`, `set-mode`, and `dispatch-plan` Helpers -/

private def positionalSlugs (rest : List String) : Array String := Id.run do
  let mut out : Array String := #[]
  let mut skip := false
  for arg in rest do
    if skip then
      skip := false
    else if arg == "--api" || arg == "--token" || arg == "--dir" then
      skip := true
    else if !arg.startsWith "--" then
      out := out.push arg
  return out

private def resolveTrackersDir (root : System.FilePath) (rest : List String) : IO (Except String System.FilePath) := do
  let dirRaw? ← match valueAfterFlag? rest "--dir" with
    | some d => pure (some d)
    | none => getEnvNonEmpty "HERMES_PROJECTS_DIR"
  let some dirRaw := dirRaw?
    | return .error "missing --dir <trackers> (or HERMES_PROJECTS_DIR)"
  let dir := resolveDir root dirRaw
  if !(← dir.isDir) then
    return .error s!"tracker directory {dir} is not a directory"
  return .ok dir

private def listTrackerFiles (dir : System.FilePath) (only : Array String) : IO (Except String (Array (String × System.FilePath))) := do
  let entries ← try dir.readDir catch e => return .error s!"read {dir}: {e}"
  let mut files : Array (String × System.FilePath) := #[]
  for entry in entries do
    let p := entry.path
    if p.extension == some "md" then
      if let some stem := p.fileStem then
        if (validateProjectSlug stem).isOk then
          if only.isEmpty || only.contains stem then
            files := files.push (stem, p)
  return .ok (files.qsort (fun a b => a.1 < b.1))

def runImportTrackers (root : System.FilePath) (rest : List String) : IO (Except String Unit) := do
  let api? ← match valueAfterFlag? rest "--api" with
    | some u => pure (some u)
    | none => firstEnvNonEmpty ["SANDBOXED_API_URL", "HERMES_SANDBOXED_API_URL", "API_URL"]
  let some api := api? | return .error "missing --api <url> (or SANDBOXED_API_URL)"
  let tok? ← match valueAfterFlag? rest "--token" with
    | some t => pure (some t)
    | none => firstEnvNonEmpty ["SANDBOXED_API_TOKEN", "HERMES_SANDBOXED_API_TOKEN", "API_TOKEN"]
  let dir ← match (← resolveTrackersDir root rest) with
    | .ok d => pure d
    | .error e => return .error e
  let dryRun := rest.contains "--dry-run"
  let only := positionalSlugs rest
  let files ← match (← listTrackerFiles dir only) with
    | .ok f => pure f
    | .error e => return .error e
  let mut reports : Array JVal := #[]
  let base := stripTrailingSlash api
  for (slug, path) in files do
    let content ← try IO.FS.readFile path catch e => return .error s!"read {path}: {e}"
    let payload := JVal.obj #[
      ("source_path", .str path.toString),
      ("content", .str content),
      ("dry_run", .bool dryRun),
      ("actor", .str "palomactl")
    ]
    match (← sendJsonRequest "POST" s!"{base}/api/projects/{slug}/imports" tok? (some payload) #[] 60000) with
    | .error e => return .error e
    | .ok (200, _, body?) =>
      let b := body?.getD (.obj #[])
      let itemsCount : JVal := match b.fieldArr? "items" with
        | some xs => .nat xs.size
        | none => .null
      reports := reports.push <| JVal.obj #[
        ("slug", .str slug),
        ("path", .str path.toString),
        ("created", (b.field? "created").getD .null),
        ("claims", (b.field? "claims").getD .null),
        ("already_imported", (b.field? "already_imported").getD .null),
        ("ambiguities", (b.field? "ambiguities").getD .null),
        ("receipt_id", (b.field? "receipt_id").getD .null),
        ("items", itemsCount)
      ]
    | .ok (404, _, _) =>
      reports := reports.push <| JVal.obj #[
        ("slug", .str slug),
        ("path", .str path.toString),
        ("skipped", .str "not a roster project")
      ]
    | .ok (other, rawBody, _) =>
      reports := reports.push <| JVal.obj #[
        ("slug", .str slug),
        ("path", .str path.toString),
        ("error", .str s!"HTTP {other}: {rawBody}")
      ]
  IO.println <| renderPretty <| JVal.obj #[
    ("dry_run", .bool dryRun),
    ("reports", .arr reports)
  ]
  return .ok ()

private def stripEndPunct (s : String) : String := Id.run do
  let mut cs := s.toList
  while !cs.isEmpty do
    let last := cs.getLast!
    if last == ':' || last == '.' || last == ')' then
      cs := cs.dropLast
    else
      break
  return String.ofList cs

private def isTrackerCode (rawTok : String) : Bool :=
  let tok := stripEndPunct rawTok
  if tok.isEmpty || tok.length > 12 then false
  else
    let cs := tok.toList
    let first := cs.headD '0'
    let isAsciiAlpha := fun (c : Char) => ('a' ≤ c && c ≤ 'z') || ('A' ≤ c && c ≤ 'Z')
    let isAsciiAlnum := fun (c : Char) => isAsciiAlpha c || Char.isDigit c
    let lastIsDigit := Char.isDigit (cs.getLastD ' ')
    let hasDigit := cs.any Char.isDigit
    let allAllowed := cs.all (fun c => isAsciiAlnum c || c == '-')
    let alphaCnt := (cs.filter isAsciiAlpha).length
    isAsciiAlpha first && hasDigit && lastIsDigit && allAllowed && alphaCnt ≤ 6

def normalizeTrackKey (raw : String) : String := Id.run do
  let mut out : Array Char := #[]
  let mut lastDash := true
  for ch in raw.trimAscii.toString.toList do
    if OrbBin.UnicodeAlnum.isUnicodeAlnum ch then
      out := out.push (OrbBin.UnicodeAlnum.toUnicodeLower ch)
      lastDash := false
    else if !lastDash then
      out := out.push '-'
      lastDash := true
  if !out.isEmpty && out.back! == '-' then
    out := out.pop
  return String.ofList out.toList

private def trackerKeyFromTitle (title : String) : String :=
  let words := ((title.splitToList Char.isWhitespace).filter (!·.isEmpty)).take 5
  let norm := normalizeTrackKey (String.intercalate "-" words)
  let capped := String.ofList (norm.toList.take 40)
  if capped.endsWith "-" then (capped.dropEnd 1).toString else capped

structure ParsedTrackerItem where
  key     : String
  checked : Bool
  line    : Nat
  deriving Repr, BEq, Inhabited

def parseTrackerMarkdown (content : String) : Array ParsedTrackerItem := Id.run do
  let lines := content.splitOn "\n"
  let mut items : Array ParsedTrackerItem := #[]
  for idx in [0 : lines.length] do
    let raw := lines[idx]!
    let trimmedStart := String.ofList (raw.toList.dropWhile Char.isWhitespace)
    let restOpt :=
      if trimmedStart.startsWith "- [" then some (trimmedStart.drop 3).toString
      else if trimmedStart.startsWith "* [" then some (trimmedStart.drop 3).toString
      else none
    if let some rest0 := restOpt then
      if let mark :: afterBracket := rest0.splitOn "]" then
        if !afterBracket.isEmpty then
          let markTrim := mark.trimAscii.toString
          let checked? :=
            if markTrim == "x" || markTrim == "X" then some true
            else if markTrim.isEmpty then some false
            else none
          if let some checked := checked? then
            let text := (String.intercalate "]" afterBracket).trimAscii.toString
            if !text.isEmpty then
              let firstWord := ((text.splitToList Char.isWhitespace).filter (!·.isEmpty)).headD ""
              let firstClean := stripEndPunct firstWord
              let parts := firstClean.splitOn "/"
              let key :=
                if !parts.isEmpty && parts.all isTrackerCode then
                  normalizeTrackKey parts.head!
                else
                  trackerKeyFromTitle text
              if !key.isEmpty then
                items := items.push { key, checked, line := idx + 1 }
  return items

def runReconcileLive (root : System.FilePath) (api : String) (rest : List String) : IO (Except String Unit) := do
  let tok? ← match valueAfterFlag? rest "--token" with
    | some t => pure (some t)
    | none => firstEnvNonEmpty ["SANDBOXED_API_TOKEN", "HERMES_SANDBOXED_API_TOKEN", "API_TOKEN"]
  let dir ← match (← resolveTrackersDir root rest) with
    | .ok d => pure d
    | .error e => return .error e
  let only := positionalSlugs rest
  let files ← match (← listTrackerFiles dir only) with
    | .ok f => pure f
    | .error e => return .error e
  let base := stripTrailingSlash api
  let mut projects : Array JVal := #[]
  for (slug, path) in files do
    let content ← try IO.FS.readFile path catch e => return .error s!"read {path}: {e}"
    match (← sendJsonRequest "GET" s!"{base}/api/projects/{slug}/situation" tok? none #[] 60000) with
    | .error e => return .error e
    | .ok (404, _, _) => pure ()
    | .ok (status, rawBody, sit?) =>
      if status != 200 then
        projects := projects.push <| JVal.obj #[
          ("slug", .str slug),
          ("error", .str s!"HTTP {status}: {rawBody}")
        ]
      else
        let situation := sit?.getD (.obj #[])
        let sitItems := (situation.fieldArr? "items").getD #[]
        let mut plan : Array (String × String) := #[]
        for it in sitItems do
          if let (some k, some ds) := (it.fieldStr? "key", it.fieldStr? "derived_state") then
            plan := (plan.filter (fun (ek, _) => ek != k)).push (k, ds)
        let sortedPlan := plan.qsort (fun a b => a.1 < b.1)
        let mut drift : Array JVal := #[]
        let mut mdKeys : Array String := #[]
        for item in parseTrackerMarkdown content do
          if !mdKeys.contains item.key then
            mdKeys := mdKeys.push item.key
          match sortedPlan.find? (fun (pk, _) => pk == item.key) with
          | none =>
            drift := drift.push <| .obj #[
              ("kind", .str "markdown_item_missing_in_plan"),
              ("key", .str item.key),
              ("line", .nat item.line)
            ]
          | some (_, st) =>
            let planDone := st == "satisfied" || st == "claim_only"
            if item.checked && !planDone then
              drift := drift.push <| .obj #[
                ("kind", .str "markdown_checked_but_track_open"),
                ("key", .str item.key),
                ("line", .nat item.line),
                ("derived_state", .str st)
              ]
            else if !item.checked && planDone then
              drift := drift.push <| .obj #[
                ("kind", .str "markdown_open_but_track_done"),
                ("key", .str item.key),
                ("line", .nat item.line),
                ("derived_state", .str st)
              ]
        for (pk, st) in sortedPlan do
          if st != "cancelled" && !mdKeys.contains pk then
            drift := drift.push <| .obj #[
              ("kind", .str "plan_track_missing_in_markdown"),
              ("key", .str pk),
              ("derived_state", .str st)
            ]
        projects := projects.push <| .obj #[
          ("slug", .str slug),
          ("summary", (situation.field? "summary").getD .null),
          ("drift", .arr drift)
        ]
  IO.println <| renderPretty <| JVal.obj #[
    ("projects", .arr projects),
    ("note", .str "read-only; the plan (project_tracks) is the truth, Markdown is narrative")
  ]
  return .ok ()

private def explorationLimitForMode (mode : String) : Option Nat :=
  match mode with
  | "conservative" => some 0
  | "normal" => some 1
  | "aggressive" => some 3
  | "very_aggressive" => some 5
  | _ => none

private def loadProjectModePolicy (root : System.FilePath) (project : String) : IO (String × String × Nat) := do
  let modeFile := root / ".paloma" / "modes" / s!"{project}.json"
  let nowSec := Int.ofNat (← nowEpoch).toNat
  if (← modeFile.pathExists) then
    if let .ok j := Json.parse (← IO.FS.readFile modeFile) then
      let m := (j.fieldStr? "mode").getD "normal"
      let u := (j.fieldStr? "until").getD "unset"
      if let some expLimit := explorationLimitForMode m then
        if let some untilSec := parseRfc3339Epoch? u then
          if untilSec > nowSec then
            return (m, u, expLimit)
  return ("normal", "unset", 1)

private def loadFixtureTasks (root : System.FilePath) : IO (Except String (Array JVal)) := do
  let p := root / ".paloma" / "fixtures" / "tasks.json"
  if !(← p.pathExists) then return .ok #[]
  let raw ← IO.FS.readFile p
  match Json.parse raw with
  | .ok (.arr xs) => return .ok xs
  | .ok v => return .ok ((v.fieldArr? "tasks").getD #[])
  | .error e => return .error s!"parse {p}: {e}"

private def intentRequestsExploration (intent : String) : Bool := Id.run do
  let toks := (intent.splitToList (fun c => !c.isAlphanum)).filter (!·.isEmpty)
  let keywords := #["proof", "prove", "explore", "explores", "explored", "exploring", "exploration", "exploratory"]
  for tok in toks do
    if keywords.contains tok.toLower then
      return true
  return false

private def isExplorationTask (t : JVal) : Bool :=
  (t.fieldStr? "lane").getD "" == "exploration" ||
  match t.fieldStr? "intent" with
  | some intent => intentRequestsExploration intent
  | none => false

private def taskFixtureId (t : JVal) : String :=
  (t.fieldStr? "id").orElse (fun _ => t.fieldStr? "task_key") |>.getD ""

def buildDispatchPlanJson (root : System.FilePath) (project : String) : IO (Except String JVal) := do
  let (modeName, _, expLimit) ← loadProjectModePolicy root project
  let tasks ← match (← loadFixtureTasks root) with
    | .ok ts => pure ts
    | .error e => return .error e
  let ready := tasks.filter fun t =>
    let proj := (t.fieldStr? "project").getD ""
    let st := (t.fieldStr? "status").getD ""
    proj == project && (st == "ready" || st == "pending")
  if ready.isEmpty then
    return .ok <| JVal.obj #[
      ("project", .str project),
      ("mode", .str modeName),
      ("safe_lane_max_workers", .nat 1),
      ("exploration_lane_max_workers", .nat expLimit),
      ("dispatch", .arr #[]),
      ("reason", .str "no_ready_tasks")
    ]
  let mut safe : Array JVal := #[]
  let mut exploration : Array JVal := #[]
  for t in ready do
    if isExplorationTask t then exploration := exploration.push t
    else safe := safe.push t
  let sortedSafe := safe.qsort (fun a b => taskFixtureId a < taskFixtureId b)
  let sortedExp := exploration.qsort (fun a b => taskFixtureId a < taskFixtureId b)
  let mut dispatch : Array JVal := #[]
  if sortedSafe.size > 0 then
    dispatch := dispatch.push <| JVal.obj #[
      ("task_id", .str (taskFixtureId sortedSafe[0]!)),
      ("lane", .str "safe"),
      ("max_workers", .nat 1),
      ("gate_protected", .bool true)
    ]
  let expTake := Nat.min expLimit sortedExp.size
  for i in [0:expTake] do
    dispatch := dispatch.push <| JVal.obj #[
      ("task_id", .str (taskFixtureId sortedExp[i]!)),
      ("lane", .str "exploration"),
      ("max_workers", .nat 1),
      ("isolated_branch", .bool true)
    ]
  let reasonVal : JVal := if dispatch.isEmpty then .str "no_schedulable_tasks" else .null
  return .ok <| JVal.obj #[
    ("project", .str project),
    ("mode", .str modeName),
    ("safe_lane_max_workers", .nat 1),
    ("exploration_lane_max_workers", .nat expLimit),
    ("dispatch", .arr dispatch),
    ("reason", reasonVal)
  ]

def runPalomaCtl (args : List String) : IO (Except String Unit) := do
  let rootEnv ← getEnvNonEmpty "PALOMACTL_ROOT"
  let cwd ← IO.currentDir
  let root := (rootEnv.map System.FilePath.mk).getD cwd
  match args with
  | [] | ["-h"] | ["--help"] | ["help"] =>
    printUsage
    return .ok ()
  | ["--version"] | ["-V"] =>
    IO.println "palomactl 1.3.0 (Lean 4)"
    return .ok ()
  | "models" :: rest =>
    runModelsCmd root rest
  | "status" :: _ =>
    let st ← buildLocalState root
    IO.print (renderStatusText st)
    return .ok ()
  | "reconcile" :: rest =>
    if let some api := valueAfterFlag? rest "--api" then
      runReconcileLive root api rest
    else
      let st ← buildLocalState root
      let cdir := root / ".paloma"
      IO.FS.createDirAll cdir
      let sj := cdir / "status.json"
      let sm := cdir / "status.md"
      IO.FS.writeFile sj ((renderPretty st) ++ "\n")
      IO.FS.writeFile sm (renderStatusMd st)
      let driftLen := ((st.fieldArr? "drift").getD #[]).size
      IO.println s!"wrote {sj}\nwrote {sm}\ndrift={driftLen}"
      return .ok ()
  | "import-trackers" :: rest =>
    runImportTrackers root rest
  | "pr-gates" :: repo :: numStr :: rest =>
    let some num := numStr.toNat? | return .error "PR number must be numeric"
    let workerHead? := valueAfterFlag? rest "--worker-head"
    let rawGates ← match (← loadPrGates root repo num) with
      | .ok g => pure g
      | .error e => return .error e
    let annotated := evaluateAndAnnotatePrGates rawGates repo num workerHead?
    IO.println (renderPretty annotated)
    if let some recStr := annotated.fieldStr? "recommendation" then
      IO.println s!"recommendation={recStr}"
    return .ok ()
  | "pr-gates" :: _ =>
    return .error "usage: palomactl pr-gates <owner/repo> <number> [--worker-head <sha>]"
  | "set-mode" :: project :: mode :: rest =>
    if let .error e := validateProjectSlug project then return .error e
    let some untilIso := valueAfterFlag? rest "--until" | return .error "missing --until <iso>"
    let some untilSec := parseRfc3339Epoch? untilIso
      | return .error "--until must be RFC3339/ISO timestamp"
    let nowSec := Int.ofNat (← nowEpoch).toNat
    if untilSec <= nowSec then
      return .error "--until must be in the future"
    let some expLimit := explorationLimitForMode mode
      | return .error "mode must be conservative|normal|aggressive|very_aggressive"
    let mdir := root / ".paloma" / "modes"
    IO.FS.createDirAll mdir
    let policy := JVal.obj #[
      ("project", .str project),
      ("mode", .str mode),
      ("until", .str untilIso),
      ("safe_lane_max_workers", .nat 1),
      ("exploration_lane_max_workers", .nat expLimit)
    ]
    IO.FS.writeFile (mdir / s!"{project}.json") ((renderPretty policy) ++ "\n")
    IO.println (renderPretty policy)
    return .ok ()
  | "set-mode" :: _ =>
    return .error "usage: palomactl set-mode <project> <mode> --until <iso>"
  | "dispatch-plan" :: rest =>
    let some project := valueAfterFlag? rest "--project" | return .error "missing --project <slug>"
    if let .error e := validateProjectSlug project then return .error e
    match (← buildDispatchPlanJson root project) with
    | .ok plan =>
      IO.println (renderPretty plan)
      return .ok ()
    | .error e => return .error e
  | "repair-borrowed-tracks" :: rest =>
    let api? ← match valueAfterFlag? rest "--api" with
      | some u => pure (some u)
      | none => firstEnvNonEmpty ["SANDBOXED_API_URL", "HERMES_SANDBOXED_API_URL", "API_URL"]
    let some api := api? | return .error "missing --api <url> (or SANDBOXED_API_URL)"
    let tok? ← match valueAfterFlag? rest "--token" with
      | some t => pure (some t)
      | none => firstEnvNonEmpty ["SANDBOXED_API_TOKEN", "HERMES_SANDBOXED_API_TOKEN", "API_TOKEN"]
    let apply := rest.contains "--apply"
    let dryStr := if apply then "false" else "true"
    let url := stripTrailingSlash api ++
      s!"/api/control/repair/borrowed-tracks?dry_run={dryStr}"
    match (← sendJsonRequest "POST" url tok?) with
    | .ok (200, _, some j) =>
      IO.println (renderPretty j)
      return .ok ()
    | .ok (st, body, _) => return .error s!"HTTP {st}: {body}"
    | .error e => return .error e
  | "validation-matrix" :: rest =>
    let mPath := match rest.head? with
      | some p => System.FilePath.mk p
      | none => root / ".sandboxed" / "validation.toml"
    let raw ← try IO.FS.readFile mPath catch e => return .error s!"read validation matrix {mPath}: {e}"
    match parseValidationMatrixText raw >>= validateMatrixJson with
    | .ok m =>
      IO.println (renderPretty m)
      return .ok ()
    | .error e => return .error e
  | "cluster-lean-errors" :: path :: _ =>
    let raw ← try IO.FS.readFile path catch e => return .error s!"read {path}: {e}"
    IO.println (renderPretty (clusterDiagnostics raw))
    return .ok ()
  | "cluster-lean-errors" :: [] =>
    return .error "missing log path"
  | unknown :: _ =>
    printUsage
    return .error s!"unknown command {unknown}"

def runMain (args : List String) : IO UInt32 := do
  match (← runPalomaCtl args) with
  | .ok () => return 0
  | .error err =>
    IO.eprintln s!"palomactl: {err}"
    return 1

end OrbBin.PalomaCtl
