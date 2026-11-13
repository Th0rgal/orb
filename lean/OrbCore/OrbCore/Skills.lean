/-
  OrbCore.Skills: Delivered `/skill:NAME` and bare `/NAME` chip selection (`#1553`).
  Strategy comes from the verified `orb_skill_slash_step` gate.
-/
import Orb.Kernel
import OrbBin.Json
import OrbBin.PosixExt

namespace OrbCore.Skills

open OrbBin.Json
open OrbBin.PosixExt

def maxNameLen : UInt32 := 64
def maxSelected : UInt32 := 8

def harnessKind (harness : String) : UInt8 :=
  match harness with
  | "opencode" => 1
  | "claudecode" => 2
  | _ => 0

/-- Native skill directory relative to the working tree. -/
def nativeDirectory (harness : String) : String :=
  match harness with
  | "claudecode" => ".claude/skills"
  | "codex" | "antigravity" => ".agents/skills"
  | "grok" => ".grok/skills"
  | "vibe" => ".vibe/skills"
  | _ => ".opencode/skills"

/-- Library fallback directory used when the native path is absent. -/
def libraryDirectory (harness : String) : String :=
  match harness with
  | "opencode" => ".opencode/skill"
  | "codex" => ".codex/skills"
  | _ => nativeDirectory harness

/-- ASCII `[A-Za-z0-9._-]` without `..`. -/
def nameCharsValid (name : String) : Bool :=
  !name.isEmpty && name.length ≤ 64 && (name.splitOn "..").length == 1 &&
    name.toList.all fun c =>
      ('a' ≤ c && c ≤ 'z') || ('A' ≤ c && c ≤ 'Z') || ('0' ≤ c && c ≤ '9') || c == '.' || c == '_' || c == '-'

/-- Remote installer additionally requires hyphen-separated non-empty `[a-z0-9]+` segments. -/
def remoteInstallable (name : String) : Bool :=
  nameCharsValid name && !name.startsWith "-" && !name.endsWith "-" &&
    !(name.splitOn "-").any fun seg => seg.isEmpty || seg.toList.any fun c =>
      !(('a' ≤ c && c ≤ 'z') || ('0' ≤ c && c ≤ '9'))

def invalidIdentifier : String :=
  "Invalid /skill: identifier (use at most 64 ASCII letters, numbers, '.', '_' or '-', without '..')"

structure AvailableSkill where
  name : String
  path : String
  deriving Repr, DecidableEq

structure SelectedSkill where
  name     : String
  path     : String
  strategy : UInt8
  deriving Repr, DecidableEq

/-- `/skill:` tokens in first-seen order, including duplicates (the gate dedups). -/
def references (prompt : String) : Array String :=
  (prompt.split (fun c => c == ' ' || c == '\t' || c == '\n' || c == '\r')).toArray.filterMap fun w =>
    if w.startsWith "/skill:" then some (w.drop 7).toString else none

def rejectMessage (code : UInt32) (name : String) : String :=
  if code == 1 || code == 2 then invalidIdentifier
  else if code == 3 then s!"Selected skill is not delivered to this mission: {name}"
  else if code == 5 then "Select at most 8 distinct skills"
  else "Skill selection rejected"

/-- Run every `/skill:` reference through `orb_skill_slash_step`. Empty means no chips. -/
def select (prompt harness : String) (available : Array AvailableSkill) : Except String (Array SelectedSkill) := do
  let mut selected : Array SelectedSkill := #[]
  for name in references prompt do
    if selected.any (fun s => s.name == name) then
      continue
    let skill? := available.find? (fun s => s.name == name)
    let verdict := Orb.Kernel.skillSlashStep
      (harnessKind harness)
      (if skill?.isSome then 1 else 0)
      0
      (if nameCharsValid name then 1 else 0)
      (if name.utf8ByteSize > 0xFFFFFFFF then 0xFFFFFFFF else name.utf8ByteSize.toUInt32)
      maxNameLen
      selected.size.toUInt32
      maxSelected
    let lo := verdict.toUInt32
    if (lo &&& 255) != 0 then
      throw (rejectMessage (lo &&& 255) name)
    let some skill := skill? | throw "Selected skill is unavailable"
    let strategy := ((lo >>> 16) &&& 255).toUInt8
    selected := selected.push { name := name, path := skill.path, strategy := strategy }
  pure selected

/-- Append the load-before-acting directive. Names and paths are JSON-escaped. -/
def withDirective (prompt : String) (selected : Array SelectedSkill) : String :=
  if selected.isEmpty then prompt
  else Id.run do
    let mut result := prompt ++ "\n\nSelected skills (load before performing the current request):\n"
    for skill in selected do
      let name := renderCompact (.str skill.name)
      let path := renderCompact (.str skill.path)
      if skill.strategy == 1 then
        result := result ++ s!"- Invoke the Skill tool with name {name}. If unavailable, read {path} and follow its instructions.\n"
      else
        result := result ++ s!"- Read {path} and follow the instructions for skill {name}.\n"
    return result

inductive DeliveryReason where
  | base
  | global
  | project
  | context
  deriving Repr, DecidableEq

def DeliveryReason.asString : DeliveryReason → String
  | .base => "base"
  | .global => "global"
  | .project => "project"
  | .context => "context"

structure DeliveredSkill where
  name        : String
  description : Option String
  reasons     : Array DeliveryReason
  deriving Repr, Inhabited

structure SkillDeliveryPlan where
  skills  : Array DeliveredSkill
  missing : Array String
  deriving Repr

def SkillDeliveryPlan.empty : SkillDeliveryPlan := { skills := #[], missing := #[] }

def planToJson (plan : SkillDeliveryPlan) : String :=
  let skills := plan.skills.map fun s =>
    .obj #[
      ("name", .str s.name),
      ("description", match s.description with | some d => .str d | none => .null),
      ("reasons", .arr (s.reasons.map fun r => .str r.asString))
    ]
  renderCompact (.obj #[("skills", .arr skills), ("missing", .arr (plan.missing.map .str))])

/-- First non-empty `description:` in YAML frontmatter, else the first paragraph (≤220 chars). -/
def extractDescription (content : String) : Option String := Id.run do
  let text := content.replace "\r\n" "\n"
  if text.startsWith "---\n" then
    let rest := (text.drop 4).toString
    let lines := rest.splitOn "\n"
    let mut inFm := true
    let mut desc? : Option String := none
    let mut body : Array String := #[]
    for line in lines do
      if inFm then
        if line == "---" then inFm := false
        else if line.startsWith "description:" then
          let raw := ((line.drop 12).toString).trimAscii.toString
          let v := if raw.startsWith "\"" && raw.endsWith "\"" && raw.length ≥ 2 then ((raw.drop 1).dropEnd 1).toString else raw
          if !v.isEmpty then desc? := some v
      else
        body := body.push line
    if let some d := desc? then return some d
    let paragraph := ((String.intercalate "\n" body.toList).trimAscii.toString.splitOn "\n\n").head?.getD ""
    let p := paragraph.trimAscii.toString
    if p.isEmpty then return none
    return some (if p.length > 220 then (p.take 220).toString else p)
  else
    let p := text.trimAscii.toString
    if p.isEmpty then return none
    let paragraph := (p.splitOn "\n\n").head?.getD p
    return some (if paragraph.length > 220 then (paragraph.take 220).toString else paragraph)

/-- Record a context-delivered skill (`skills/<name>/SKILL.md`), clearing it from `missing`. -/
def extendContext (plan : SkillDeliveryPlan) (name : String) (description : Option String) : SkillDeliveryPlan :=
  if !nameCharsValid name then plan
  else
    let missing := plan.missing.filter (· != name)
    match plan.skills.findIdx? (fun s => s.name == name) with
    | some idx =>
      let prev := plan.skills[idx]!
      let reasons := if prev.reasons.any (· == .context) then prev.reasons else prev.reasons.push .context
      let next := { prev with description := description, reasons := reasons }
      { plan with skills := plan.skills.set! idx next, missing := missing }
    | none =>
      { skills := plan.skills.push { name := name, description := description, reasons := #[.context] }, missing := missing }

def addDelivered (plan : SkillDeliveryPlan) (name : String) (description : Option String) (reason : DeliveryReason) : SkillDeliveryPlan :=
  if !nameCharsValid name then plan
  else match plan.skills.findIdx? (fun s => s.name == name) with
    | some idx =>
      let prev := plan.skills[idx]!
      let reasons := if prev.reasons.any (· == reason) then prev.reasons else prev.reasons.push reason
      { plan with skills := plan.skills.set! idx { prev with reasons := reasons } }
    | none =>
      { plan with skills := plan.skills.push { name := name, description := description, reasons := #[reason] } }

def isPlainProjectKey (slug : String) : Bool :=
  !slug.isEmpty && slug.length ≤ 128 && slug != "." && slug != ".." &&
    slug.toList.all fun c =>
      ('a' ≤ c && c ≤ 'z') || ('A' ≤ c && c ≤ 'Z') || ('0' ≤ c && c ≤ '9') || c == '-' || c == '_' || c == '.'

/-- Scan `<dir>/<name>/SKILL.md` entries sorted by skill name. -/
def scanSkillDir (dir : System.FilePath) : IO (Array (String × Option String × String)) := do
  let entries ← try dir.readDir catch _ => pure #[]
  let sorted := entries.qsort (fun a b => a.fileName < b.fileName)
  let mut out : Array (String × Option String × String) := #[]
  for entry in sorted do
    let name := entry.fileName
    if nameCharsValid name then
      let md := entry.path / "SKILL.md"
      let st ← statPath md.toString
      if st.exists_ && st.isReg && !st.isSymlink then
        let raw ← try IO.FS.readFile md catch _ => pure ""
        out := out.push (name, extractDescription raw, md.toString)
  return out

/-- Build the delivered skill plan for `(workingDir, project?)` from Library + project context. -/
def buildDeliveryPlan (workingDir : String) (project? : Option String) : IO (Except String SkillDeliveryPlan) := do
  let mut plan := SkillDeliveryPlan.empty
  let libDir := System.FilePath.mk workingDir / "library" / "skills"
  for (name, desc, _) in (← scanSkillDir libDir) do
    plan := addDelivered plan name desc .global
  if let some rawProj := project? then
    let slug := rawProj.trimAscii.toString
    if !slug.isEmpty then
      if !isPlainProjectKey slug then
        return .error "Invalid context project"
      let ctxDir := System.FilePath.mk workingDir / "project-files" / slug / "skills"
      for (name, desc, _) in (← scanSkillDir ctxDir) do
        plan := extendContext plan name desc
  return .ok plan

/-- Largest SKILL.md shipped to a node, and the cap on all of them together. -/
def remoteSkillMaxBytes : Nat := 64 * 1024
def remoteSkillTotalBytes : Nat := 256 * 1024

/-- Shell that writes each `(name, SKILL.md)` into the harness's native skill directory of
    the current directory. An existing file is left alone, and a failure never stops the
    turn. Names must already satisfy `remoteInstallable`; content travels as base64. -/
def installScript (harness : String) (files : Array (String × String)) : String :=
  let dir := nativeDirectory harness
  String.join (files.toList.map fun (name, content) =>
    let target := s!"{dir}/{name}"
    s!"[ -e '{target}/SKILL.md' ] || \{ mkdir -p '{target}' && printf %s '{base64Encode content.toUTF8}' | base64 -d > '{target}/SKILL.md'; } 2>/dev/null || true; ")

/-- The delivered skills (`buildDeliveryPlan`: Library plus project context, context wins)
    as an install prelude for a turn that runs on a node, where the Library is not mounted.
    Skills whose names the installer cannot quote safely, or that exceed the size caps, are skipped. -/
def remoteInstallPrelude (workingDir : String) (project? : Option String) (harness : String) : IO String := do
  let libDir := System.FilePath.mk workingDir / "library" / "skills"
  let mut found : Array (String × String) := (← scanSkillDir libDir).map fun (name, _, path) => (name, path)
  if let some slug := project?.map (·.trimAscii.toString) |>.filter (fun s => !s.isEmpty && isPlainProjectKey s) then
    for (name, _, path) in (← scanSkillDir (System.FilePath.mk workingDir / "project-files" / slug / "skills")) do
      found := (found.filter (·.1 != name)).push (name, path)
  let mut files : Array (String × String) := #[]
  let mut total : Nat := 0
  for (name, path) in found do
    if remoteInstallable name then
      let content ← try IO.FS.readFile path catch _ => pure ""
      let size := content.utf8ByteSize
      if size > 0 && size ≤ remoteSkillMaxBytes && total + size ≤ remoteSkillTotalBytes then
        files := files.push (name, content)
        total := total + size
  return installScript (if harness == "claude" then "claudecode" else harness) files

def selectDelivered (workingDir : String) (project? : Option String) (harness prompt : String) :
    IO (Except String (Array SelectedSkill)) := do
  if (references prompt).isEmpty then return .ok #[]
  match ← buildDeliveryPlan workingDir project? with
  | .error e => return .error e
  | .ok plan =>
    let available := plan.skills.map fun s =>
      { name := s.name, path := s!"{nativeDirectory harness}/{s.name}/SKILL.md" : AvailableSkill }
    return select prompt harness available

end OrbCore.Skills
