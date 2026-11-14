/-
  OrbCore.Skills: Delivered `/skill:NAME` and bare `/NAME` chip selection (`#1553`).
  Strategy comes from the verified `orb_skill_slash_step` gate.
-/
import Orb.Kernel
import OrbBin.Json
import OrbBin.PosixExt
import OrbCore.Spec

namespace OrbCore.Skills

open OrbBin.Json
open OrbBin.PosixExt
open OrbCore.Spec

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

private def unquoteYamlScalar (raw : String) : String :=
  let v := raw.trimAscii.toString
  if v.length ≥ 2 && ((v.startsWith "\"" && v.endsWith "\"") || (v.startsWith "'" && v.endsWith "'")) then
    (((v.drop 1).dropEnd 1).toString).trimAscii.toString
  else
    v

/-- Parse `metadata.sandboxed.audience` and `metadata.sandboxed.scope` from `SKILL.md` YAML frontmatter. -/
def parseSandboxedMeta (markdown : String) : Option (Array String) × Option String := Id.run do
  let text := (markdown.replace "\r\n" "\n").replace "\uFEFF" ""
  if !text.startsWith "---\n" then
    return (none, none)
  let rest := (text.drop 4).toString
  let lines := rest.splitOn "\n"
  let mut yaml : Array String := #[]
  let mut closed := false
  for line in lines do
    if !closed then
      if line == "---" then closed := true
      else yaml := yaml.push line
  if !closed then
    return (none, none)
  let indentOf (s : String) : Nat := s.length - s.trimAsciiStart.toString.length
  let mut audience? : Option (Array String) := none
  let mut scope? : Option String := none
  let mut metaIndent? : Option Nat := none
  let mut sandIndent? : Option Nat := none
  let mut i : Nat := 0
  while i < yaml.size do
    let line := yaml[i]!
    let trimmed := line.trimAscii.toString
    if trimmed.isEmpty || trimmed.startsWith "#" then
      i := i + 1
      continue
    let ind := indentOf line
    if let some si := sandIndent? then
      if ind ≤ si then sandIndent? := none
    if let some mi := metaIndent? then
      if ind ≤ mi then
        metaIndent? := none
        sandIndent? := none
    if metaIndent?.isNone then
      if trimmed == "metadata:" then metaIndent? := some ind
      i := i + 1
      continue
    if sandIndent?.isNone then
      if trimmed == "sandboxed:" then sandIndent? := some ind
      i := i + 1
      continue
    if trimmed.startsWith "audience:" then
      let val := ((trimmed.drop 9).toString).trimAscii.toString
      if val.isEmpty then
        let mut items : Array String := #[]
        let mut j := i + 1
        while j < yaml.size do
          let t := yaml[j]!.trimAscii.toString
          if t.startsWith "-" then
            let item := unquoteYamlScalar ((t.drop 1).toString)
            if !item.isEmpty then items := items.push item
            j := j + 1
          else if t.isEmpty then
            j := j + 1
          else
            break
        audience? := some items
        i := j
        continue
      else
        let inner :=
          if val.startsWith "[" && val.endsWith "]" && val.length ≥ 2 then
            ((val.drop 1).dropEnd 1).toString
          else val
        let items := (inner.splitOn ",").toArray.filterMap fun part =>
          let u := unquoteYamlScalar part
          if u.isEmpty then none else some u
        audience? := some items
    else if trimmed.startsWith "scope:" then
      let v := unquoteYamlScalar ((trimmed.drop 6).toString)
      if !v.isEmpty then scope? := some v
    i := i + 1
  return (audience?, scope?)

def effectiveAudience (markdown : String) : Array String :=
  let raw := (parseSandboxedMeta markdown).1.getD #["mission", "local"]
  raw.filterMap fun a =>
    let clean := a.trimAscii.toString.toLower
    if clean.isEmpty then none else some clean

/-- First non-empty `description:` in YAML frontmatter, else the first paragraph (≤220 chars). -/
def extractDescription (content : String) : Option String := Id.run do
  let text := (content.replace "\r\n" "\n").replace "\uFEFF" ""
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
          let v := unquoteYamlScalar ((line.drop 12).toString)
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
def scanSkillDir (dir : System.FilePath) (requireMissionAudience : Bool := false) :
    IO (Array (String × Option String × String)) := do
  let dirSt ← statPath dir.toString
  if dirSt.isSymlink then return #[]
  let entries ← try dir.readDir catch _ => pure #[]
  let sorted := entries.qsort (fun a b => a.fileName < b.fileName)
  let mut out : Array (String × Option String × String) := #[]
  for entry in sorted do
    let name := entry.fileName
    if nameCharsValid name && !name.startsWith "." then
      let md := entry.path / "SKILL.md"
      let st ← statPath md.toString
      let entrySt ← statPath entry.path.toString
      if !entrySt.isSymlink && st.exists_ && st.isReg && !st.isSymlink then
        let raw ← try IO.FS.readFile md catch _ => pure ""
        if !requireMissionAudience || (effectiveAudience raw).contains "mission" then
          out := out.push (name, extractDescription raw, md.toString)
  return out

/-- Resolve the active Library checkout root on Core (`LIBRARY_PATH`, `.sandboxed-sh/library`,
    `{storeRoot}/library`, or `{workingDir}/library`). -/
def resolveLibraryRoot (workingDir : String) (storeRoot : String := "") : IO String := do
  if let some p ← IO.getEnv "LIBRARY_PATH" then
    let pt := p.trimAscii.toString
    if !pt.isEmpty then return pt
  let mut cands : Array String := #[s!"{workingDir}/.sandboxed-sh/library"]
  if !storeRoot.trimAscii.isEmpty then
    cands := cands.push s!"{storeRoot}/library"
  cands := cands.push s!"{workingDir}/library"
  for c in cands do
    if (← (System.FilePath.mk c).pathExists) then return c
  return s!"{workingDir}/.sandboxed-sh/library"

/-- Only the bootstrap principal (or legacy empty scope) uses host Library settings. -/
def isLibraryOwner (ownerUserId bootstrapAdminId : String) : Bool :=
  ownerUserId.isEmpty || orbLibraryScopeGate (if ownerUserId == bootstrapAdminId then 1 else 0) 0 == 1

/-- Owner-only fallback candidate; members never consult host overrides or legacy paths.
    Callers must reject invalid IDs before using this pure path constructor. -/
def libraryRootCandidate (ownerUserId bootstrapAdminId workingDir storeRoot : String) : String :=
  if isLibraryOwner ownerUserId bootstrapAdminId then
    s!"{workingDir}/.sandboxed-sh/library"
  else s!"{storeRoot}/library/users/{ownerUserId}"

def validLibraryScope (ownerUserId _bootstrapAdminId : String) : Bool :=
  ownerUserId.isEmpty || (nameCharsValid ownerUserId && ownerUserId != ".")

def resolveLibraryRootFor (ownerUserId : String) (workingDir storeRoot bootstrapAdminId : String) : IO String := do
  unless validLibraryScope ownerUserId bootstrapAdminId do
    throw (IO.userError "library_invalid_user_scope")
  if isLibraryOwner ownerUserId bootstrapAdminId then
    resolveLibraryRoot workingDir storeRoot
  else
    for candidate in #[s!"{storeRoot}/library", s!"{storeRoot}/library/users",
        libraryRootCandidate ownerUserId bootstrapAdminId workingDir storeRoot] do
      if (← statPath candidate).isSymlink then throw (IO.userError "library_invalid_user_scope")
    pure (libraryRootCandidate ownerUserId bootstrapAdminId workingDir storeRoot)

/-- Project context uses the same stored, tenant-prefixed slug as ProjectFilesAndController.
    Public callers pass unscoped slugs; remote mission records already hold scoped slugs. -/
def contextProjectKey (ownerUserId bootstrapAdminId slug : String) : Option String := do
  if isLibraryOwner ownerUserId bootstrapAdminId then
    if isPlainProjectKey slug then some slug else none
  else
    let userPrefix := ownerUserId ++ ":"
    let raw := if slug.startsWith userPrefix then (slug.drop userPrefix.length).toString else slug
    if isPlainProjectKey raw then some (userPrefix ++ raw) else none

private def projectSkillDirectory (workingDir storeRoot ownerUserId bootstrapAdminId slug : String) : System.FilePath :=
  let root := if !isLibraryOwner ownerUserId bootstrapAdminId && !storeRoot.isEmpty then storeRoot else workingDir
  System.FilePath.mk root / "project-files" / slug / "skills"

/-- Build the delivered skill plan for `(workingDir, project?)` from Library + project context. -/
def buildDeliveryPlan (workingDir : String) (project? : Option String) (storeRoot ownerUserId bootstrapAdminId : String) :
    IO (Except String SkillDeliveryPlan) := do
  unless validLibraryScope ownerUserId bootstrapAdminId do return .error "library_invalid_user_scope"
  let mut plan := SkillDeliveryPlan.empty
  let libRoot := System.FilePath.mk (← resolveLibraryRootFor ownerUserId workingDir storeRoot bootstrapAdminId)
  for sub in #["skill", "skills"] do
    let sdir := libRoot / sub
    if (← sdir.pathExists) && (← sdir.isDir) then
      for (name, desc, _) in (← scanSkillDir sdir true) do
        plan := addDelivered plan name desc .global
  if let some rawProj := project? then
    let slug := rawProj.trimAscii.toString
    if !slug.isEmpty then
      let some slug := contextProjectKey ownerUserId bootstrapAdminId slug
        | return .error "Invalid context project"
      let ctxDir := projectSkillDirectory workingDir storeRoot ownerUserId bootstrapAdminId slug
      for (name, desc, _) in (← scanSkillDir ctxDir false) do
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
def remoteInstallPrelude (workingDir : String) (project? : Option String) (harness : String)
    (storeRoot ownerUserId bootstrapAdminId : String) : IO String := do
  let libRoot := System.FilePath.mk (← resolveLibraryRootFor ownerUserId workingDir storeRoot bootstrapAdminId)
  let mut found : Array (String × String) := #[]
  for sub in #["skill", "skills"] do
    let sdir := libRoot / sub
    if (← sdir.pathExists) && (← sdir.isDir) then
      for (name, _, path) in (← scanSkillDir sdir true) do
        if !(found.any (·.1 == name)) then
          found := found.push (name, path)
  if let some slug := project?.bind (fun s => contextProjectKey ownerUserId bootstrapAdminId s.trimAscii.toString) then
    for (name, _, path) in (← scanSkillDir (projectSkillDirectory workingDir storeRoot ownerUserId bootstrapAdminId slug) false) do
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

def selectDelivered (workingDir : String) (project? : Option String) (harness prompt : String)
    (storeRoot ownerUserId bootstrapAdminId : String) : IO (Except String (Array SelectedSkill)) := do
  unless validLibraryScope ownerUserId bootstrapAdminId do return .error "library_invalid_user_scope"
  if (references prompt).isEmpty then return .ok #[]
  match ← buildDeliveryPlan workingDir project? storeRoot ownerUserId bootstrapAdminId with
  | .error e => return .error e
  | .ok plan =>
    let available := plan.skills.map fun s =>
      { name := s.name, path := s!"{nativeDirectory harness}/{s.name}/SKILL.md" : AvailableSkill }
    return select prompt harness available

end OrbCore.Skills
