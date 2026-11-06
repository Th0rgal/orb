/-
  OrbBin.WorkspaceMcpMain: Host/Container Workspace MCP Server (`workspace-mcp`).
  Replaces `src/bin/workspace_mcp.rs` in native Lean 4.
  Exposes `delete_file`, `fetch_url`, `grep_search`, `list_directory`, `read_file`,
  `search_files`, `update_skill`, and `write_file` over bounded JSON-RPC 2.0 stdio.
-/
import Std.Sync.Mutex
import OrbBin.PosixExt
import OrbBin.Json
import OrbBin.HttpClient
import OrbBin.StdioMcpServer

namespace OrbBin.WorkspaceMcp

open OrbBin.PosixExt
open OrbBin.Json
open OrbBin.HttpClient
open OrbBin.StdioMcpServer

def appVersion : String := "1.3.0"

private def containerRootFromPath? (path : System.FilePath) : Option System.FilePath := Id.run do
  let parts := (path.toString.splitOn "/").toArray
  let mut acc : Array String := #[]
  let mut i := 0
  while i < parts.size do
    let comp := parts[i]!
    acc := acc.push comp
    if comp == "containers" && i + 1 < parts.size then
      acc := acc.push parts[i + 1]!
      let joined := String.intercalate "/" acc.toList
      return some (System.FilePath.mk (if joined.isEmpty then "/" else joined))
    i := i + 1
  return none

private def isInsideContainer : IO Bool := do
  let wsExists := (← statPath "/workspaces").exists_
  let hostContExists := (← statPath "/root/.sandboxed-sh/containers").exists_
  return wsExists && !hostContExists

private def translateHostPathForContainer (hostPath : String) (workspaceRoot? : Option String) : String :=
  if let some root := workspaceRoot? then
    if !root.isEmpty && hostPath.startsWith root then
      let rel := (hostPath.drop root.length).toString
      if rel.startsWith "/" then rel else "/" ++ rel
    else
      match hostPath.splitOn "/containers/" with
      | _ :: after :: _ =>
        match after.splitOn "/" with
        | _ :: rest =>
          if rest.isEmpty then hostPath else "/" ++ String.intercalate "/" rest
        | [] => hostPath
      | _ => hostPath
  else
    match hostPath.splitOn "/containers/" with
    | _ :: after :: _ =>
      match after.splitOn "/" with
      | _ :: rest =>
        if rest.isEmpty then hostPath else "/" ++ String.intercalate "/" rest
      | [] => hostPath
    | _ => hostPath

def hydrateWorkspaceEnv (overridePath? : Option System.FilePath) : IO System.FilePath := do
  let cwd ← IO.currentDir
  let ws ← match overridePath? with
    | some p => pure p
    | none =>
      match (← getEnvNonEmpty "SANDBOXED_SH_WORKSPACE") with
      | some s => pure (System.FilePath.mk s)
      | none => pure cwd
  if (← getEnvNonEmpty "SANDBOXED_SH_WORKSPACE").isNone then
    setenvVar "SANDBOXED_SH_WORKSPACE" ws.toString
  if (← getEnvNonEmpty "SANDBOXED_SH_WORKSPACE_TYPE").isNone then
    match containerRootFromPath? ws with
    | some root =>
      setenvVar "SANDBOXED_SH_WORKSPACE_TYPE" "container"
      if (← getEnvNonEmpty "SANDBOXED_SH_WORKSPACE_ROOT").isNone then
        setenvVar "SANDBOXED_SH_WORKSPACE_ROOT" root.toString
    | none =>
      setenvVar "SANDBOXED_SH_WORKSPACE_TYPE" "host"
  return ws

private def extractWorkspaceFromInitialize? (params : JVal) : Option System.FilePath := Id.run do
  if let some p := params.fieldStr? "rootPath" then
    return some (System.FilePath.mk p)
  if let some uri := params.fieldStr? "rootUri" then
    if uri.startsWith "file://" then
      return some (System.FilePath.mk (uri.drop 7).toString)
  if let some folders := params.fieldArr? "workspaceFolders" then
    for folder in folders do
      if let some p := folder.fieldStr? "path" then
        return some (System.FilePath.mk p)
      if let some uri := folder.fieldStr? "uri" then
        if uri.startsWith "file://" then
          return some (System.FilePath.mk (uri.drop 7).toString)
  return none

private def runtimeWorkspacePath : IO System.FilePath := do
  if let some p ← getEnvNonEmpty "SANDBOXED_SH_RUNTIME_WORKSPACE_FILE" then
    return System.FilePath.mk p
  let home := (← getEnvNonEmpty "HOME").getD "/root"
  return System.FilePath.mk home / ".sandboxed-sh" / "runtime" / "current_workspace.json"

private def loadRuntimeWorkspace? : IO (Option JVal) := do
  let gPath ← runtimeWorkspacePath
  let global? ←
    try
      let txt ← IO.FS.readFile gPath
      pure (Json.parse txt).toOption
    catch _ => pure none
  if let some gs := global? then
    if let some wsRoot := gs.fieldStr? "workspace_root" then
      let localPath := System.FilePath.mk wsRoot / ".sandboxed-sh_context.json"
      if (← statPath localPath.toString).exists_ then
        try
          let ltxt ← IO.FS.readFile localPath
          if let .ok ls := Json.parse ltxt then
            return some ls
        catch _ => pure ()
  return global?

private def applyRuntimeWorkspace (wsLock : Std.Mutex System.FilePath) : IO Unit := do
  let some state ← loadRuntimeWorkspace? | return
  let insideCont ← isInsideContainer
  let wsRootEnv ← getEnvNonEmpty "SANDBOXED_SH_WORKSPACE_ROOT"
  if (← getEnvNonEmpty "SANDBOXED_SH_WORKSPACE").isNone then
    if let some dir := state.fieldStr? "working_dir" then
      let eff := if insideCont then translateHostPathForContainer dir wsRootEnv else dir
      setenvVar "SANDBOXED_SH_WORKSPACE" eff
      wsLock.atomically (set (System.FilePath.mk eff))
  if (← getEnvNonEmpty "SANDBOXED_SH_WORKSPACE_NAME").isNone then
    if let some nm := state.fieldStr? "workspace_name" then
      setenvVar "SANDBOXED_SH_WORKSPACE_NAME" nm
  if insideCont then
    unsetenvVar "SANDBOXED_SH_WORKSPACE_ROOT"
    setenvVar "SANDBOXED_SH_WORKSPACE_TYPE" "host"
  if let some ctxRoot := state.fieldStr? "context_root" then
    let eff := if insideCont then translateHostPathForContainer ctxRoot wsRootEnv else ctxRoot
    setenvVar "SANDBOXED_SH_CONTEXT_ROOT" eff
  if let some mid := state.fieldStr? "mission_id" then
    setenvVar "SANDBOXED_SH_MISSION_ID" mid
  if let some mctx := state.fieldStr? "mission_context" then
    let eff := if insideCont then translateHostPathForContainer mctx wsRootEnv else mctx
    setenvVar "SANDBOXED_SH_MISSION_CONTEXT" eff
  if let some cdn := state.fieldStr? "context_dir_name" then
    setenvVar "SANDBOXED_SH_CONTEXT_DIR_NAME" cdn

private def resolvePath (rawPath : String) (workingDir : System.FilePath) : (System.FilePath × Bool) :=
  let p := System.FilePath.mk rawPath
  if rawPath.startsWith "/" then (p, true) else (workingDir / p, false)

private def padLineNum4 (n : Nat) : String :=
  let s := toString n
  if s.length ≥ 4 then s
  else String.ofList (List.replicate (4 - s.length) ' ') ++ s

private def splitLines (s : String) : Array String :=
  let raw := (s.splitOn "\n").toArray
  let trimmed :=
    if !raw.isEmpty && raw[raw.size - 1]!.isEmpty && s.endsWith "\n" then
      raw.extract 0 (raw.size - 1)
    else raw
  trimmed.map (fun l => if l.endsWith "\r" then (l.dropEnd 1).toString else l)

/-! ### Tool Implementations -/

private def execReadFile (args : JVal) (workingDir : System.FilePath) : IO (Except String String) := do
  let some pathStr := args.fieldStr? "path" | return .error "Missing 'path' argument"
  let (resolved, _) := resolvePath pathStr workingDir
  let st ← statPath resolved.toString
  if !st.exists_ then
    return .error s!"File not found: {pathStr} (resolved to: {resolved})"
  let bytes ←
    try IO.FS.readBinFile resolved
    catch e => return .error s!"{e}"
  match String.fromUTF8? bytes with
  | none =>
    return .ok s!"Binary file detected: {resolved} ({bytes.size} bytes)\n\nCannot display binary content directly."
  | some content =>
    let lines := splitLines content
    let total := lines.size
    let startOpt := args.fieldNat? "start_line"
    let endOpt := args.fieldNat? "end_line"
    if startOpt.isSome || endOpt.isSome then
      let s0 := Nat.min total ((startOpt.getD 1) - 1)
      let e0 := Nat.min total (endOpt.getD total)
      let (lo, hi) := if s0 > e0 then (e0, s0) else (s0, e0)
      if lo ≥ total then
        return .ok s!"File has {total} lines, requested start line {lo + 1} is beyond end of file"
      let mut out : Array String := #[]
      for idx in [lo:hi] do
        out := out.push s!"{padLineNum4 (idx + 1)}| {lines[idx]!}"
      return .ok (String.intercalate "\n" out.toList)
    let mut out : Array String := #[]
    for idx in [0:total] do
      out := out.push s!"{padLineNum4 (idx + 1)}| {lines[idx]!}"
    return .ok (String.intercalate "\n" out.toList)

private def isAsciiPunct (c : Char) : Bool :=
  let n := c.toNat
  (0x21 ≤ n && n ≤ 0x2F) || (0x3A ≤ n && n ≤ 0x40) || (0x5B ≤ n && n ≤ 0x60) || (0x7B ≤ n && n ≤ 0x7E)

private def execWriteFile (args : JVal) (workingDir : System.FilePath) : IO (Except String String) := do
  let some pathStr := args.fieldStr? "path" | return .error "Missing 'path' argument"
  let some content := args.fieldStr? "content" | return .error "Missing 'content' argument"
  let (resolved, wasAbs) := resolvePath pathStr workingDir
  if let some parent := resolved.parent then
    try IO.FS.createDirAll parent catch e => return .error s!"{e}"
  try IO.FS.writeFile resolved content catch e => return .error s!"{e}"
  let written ← try IO.FS.readFile resolved catch e => return .error s!"{e}"
  if written.utf8ByteSize != content.utf8ByteSize then
    return .error s!"Write verification failed: expected {content.utf8ByteSize} bytes, got {written.utf8ByteSize}"
  let mut warnings : Array String := #[]
  let fenceCount := (content.splitOn "```").length - 1
  if fenceCount % 2 != 0 then
    warnings := warnings.push "Content has unclosed code block (odd number of ```)"
  let trimmed := content.trimAscii.toString
  if !trimmed.isEmpty then
    let cs := trimmed.toList
    if let some lastCh := cs.getLast? then
      if lastCh.isAlpha && !trimmed.endsWith "etc" then
        let ls := splitLines trimmed
        let lastLine := if ls.isEmpty then "" else ls[ls.size - 1]!
        let endsPunct := match lastLine.toList.getLast? with | some c => isAsciiPunct c | none => false
        if lastLine.length < 80 && !endsPunct then
          warnings := warnings.push "Content may be truncated (ends mid-sentence)"
  if trimmed.endsWith "#" || trimmed.endsWith "##" || trimmed.endsWith "###" then
    warnings := warnings.push "Content ends with empty heading"
  let disp := if wasAbs then pathStr else resolved.toString
  let mut res := s!"Successfully wrote {content.utf8ByteSize} bytes to {disp}"
  if !warnings.isEmpty then
    res := res ++ "\n\n⚠️ **POTENTIAL TRUNCATION WARNINGS:**\n"
    for w in warnings do
      res := res ++ s!"- {w}\n"
  return .ok res

private def execDeleteFile (args : JVal) (workingDir : System.FilePath) : IO (Except String String) := do
  let some pathStr := args.fieldStr? "path" | return .error "Missing 'path' argument"
  let (resolved, _) := resolvePath pathStr workingDir
  let st ← statPath resolved.toString
  if !st.exists_ then
    return .error s!"File not found: {pathStr} (resolved to: {resolved})"
  try IO.FS.removeFile resolved catch e => return .error s!"{e}"
  return .ok s!"Successfully deleted {resolved}"

partial def walkDirList (dir : System.FilePath) (depth maxDepth : Nat) : IO (Array String) := do
  if depth > maxDepth then return #[]
  let rawEntries ← try dir.readDir catch _ => pure #[]
  let sorted := rawEntries.qsort (fun a b => a.fileName < b.fileName)
  let mut out : Array String := #[]
  let indent := String.ofList (List.replicate ((depth - 1) * 2) ' ')
  for entry in sorted do
    let st ← statPath entry.path.toString
    if st.isDir && !st.isSymlink then
      out := out.push s!"{indent}{entry.fileName}/"
      if depth < maxDepth then
        let children ← walkDirList entry.path (depth + 1) maxDepth
        out := out ++ children
    else
      out := out.push s!"{indent}{entry.fileName}"
  return out

private def resolveTargetPath (p : System.FilePath) : IO (Option System.FilePath) := do
  let st ← statPath p.toString
  if !st.exists_ then return none
  if st.isSymlink then
    try return some (← IO.FS.realPath p) catch _ => return none
  return some p

def execListDirectory (args : JVal) (workingDir : System.FilePath) : IO (Except String String) := do
  let some pathStr := args.fieldStr? "path" | return .error "Missing 'path' argument"
  let maxDepth := (args.fieldNat? "max_depth").getD 3
  let (resolved, _) := resolvePath pathStr workingDir
  let some targetRoot ← resolveTargetPath resolved
    | return .error s!"Directory not found: {pathStr} (resolved to: {resolved})"
  let st ← statPath targetRoot.toString
  if !st.isDir then
    return .error s!"Not a directory: {pathStr}"
  if maxDepth == 0 then
    return .ok "Directory is empty"
  let entries ← walkDirList targetRoot 1 maxDepth
  if entries.isEmpty then return .ok "Directory is empty"
  return .ok (String.intercalate "\n" entries.toList)

private def findSubstrFrom? (haystack needle : String) (startIdx : Nat) : Option Nat := Id.run do
  let hs := haystack.toList.toArray
  let ns := needle.toList.toArray
  if ns.isEmpty then return some startIdx
  if startIdx + ns.size > hs.size then return none
  for i in [startIdx : hs.size - ns.size + 1] do
    let mut ok := true
    for k in [0:ns.size] do
      if ok && hs[i + k]! != ns[k]! then ok := false
    if ok then return some i
  return none

private def globMatch (pattern text : String) : Bool := Id.run do
  let parts := (pattern.splitOn "*").toArray
  if parts.size == 1 then return pattern == text
  let mut pos := 0
  for i in [0:parts.size] do
    let part := parts[i]!
    if !part.isEmpty then
      match findSubstrFrom? text part pos with
      | none => return false
      | some idx =>
        if i == 0 && idx != pos then return false
        pos := idx + part.length
  if !pattern.endsWith "*" then
    let last := parts[parts.size - 1]!
    if !last.isEmpty then return text.endsWith last
  return true

partial def walkSearchFiles (dir : System.FilePath) (patLower : String) (isGlob : Bool) (acc : IO.Ref (Array String)) : IO Unit := do
  if (← acc.get).size ≥ 100 then return
  let entries ← try dir.readDir catch _ => pure #[]
  for entry in entries do
    if (← acc.get).size ≥ 100 then return
    let st ← statPath entry.path.toString
    if st.isDir && !st.isSymlink then
      walkSearchFiles entry.path patLower isGlob acc
    else if st.isReg then
      let fname := entry.fileName.toLower
      let matched := if isGlob then globMatch patLower fname else (findSubstrFrom? fname patLower 0).isSome
      if matched then
        let cur ← acc.get
        if cur.size < 100 then
          acc.set (cur.push entry.path.toString)

private def execSearchFiles (args : JVal) (workingDir : System.FilePath) : IO (Except String String) := do
  let some pattern := args.fieldStr? "pattern" | return .error "Missing 'pattern' argument"
  let pathStr := (args.fieldStr? "path").getD "."
  let (resolved, _) := resolvePath pathStr workingDir
  let some targetRoot ← resolveTargetPath resolved
    | return .error s!"Directory not found: {pathStr} (resolved to: {resolved})"
  let st ← statPath targetRoot.toString
  if !st.isDir then
    return .error s!"Not a directory: {pathStr}"
  let patLower := pattern.toLower
  let isGlob := pattern.contains '*'
  let acc ← IO.mkRef (#[] : Array String)
  walkSearchFiles targetRoot patLower isGlob acc
  let mut matchesArr ← acc.get
  if matchesArr.isEmpty then
    return .ok s!"No files matching '{pattern}' found"
  if matchesArr.size ≥ 100 then
    matchesArr := matchesArr.push "... (results truncated, showing first 100)"
  return .ok (String.intercalate "\n" matchesArr.toList)

private def whichExists (prog : String) : IO Bool := do
  try
    let out ← IO.Process.output { cmd := "which", args := #[prog] }
    return out.exitCode == 0
  catch _ => return false

private def execGrepSearch (args : JVal) (workingDir : System.FilePath) : IO (Except String String) := do
  let some pattern := args.fieldStr? "pattern" | return .error "Missing 'pattern' argument"
  let pathStr := (args.fieldStr? "path").getD "."
  let filePattern? := args.fieldStr? "file_pattern"
  let caseSensitive := (args.fieldBool? "case_sensitive").getD false
  let (resolved, _) := resolvePath pathStr workingDir
  let hasRg ← whichExists "rg"
  let out ←
    if hasRg then
      let mut rgArgs := #["--line-number", "--no-heading", "--color=never"]
      if !caseSensitive then rgArgs := rgArgs.push "-i"
      if let some fp := filePattern? then rgArgs := rgArgs ++ #["-g", fp]
      rgArgs := rgArgs ++ #["--", pattern, resolved.toString]
      IO.Process.output { cmd := "rg", args := rgArgs }
    else
      let mut gArgs := #["-rn"]
      if !caseSensitive then gArgs := gArgs.push "-i"
      if let some fp := filePattern? then gArgs := gArgs ++ #["--include", fp]
      gArgs := gArgs ++ #[pattern, resolved.toString]
      IO.Process.output { cmd := "grep", args := gArgs }
  if out.exitCode != 0 && out.exitCode != 1 && !out.stderr.isEmpty then
    return .error s!"Search error: {out.stderr}"
  if out.stdout.isEmpty then
    return .ok s!"No matches found for pattern: {pattern}"
  let lines := splitLines out.stdout
  let limited := if lines.size > 100 then lines.extract 0 100 else lines
  let joined := String.intercalate "\n" limited.toList
  if lines.size ≥ 100 then
    return .ok s!"{joined}\n\n... (showing first 100 matches)"
  return .ok joined

private def extractTextFromHtml (html : String) : String := Id.run do
  let mut out : Array Char := Array.mkEmpty html.length
  let mut inTag := false
  for c in html.toList do
    if c == '<' then inTag := true
    else if c == '>' then
      inTag := false
      out := out.push ' '
    else if !inTag then
      out := out.push c
  let collapsed := String.intercalate " " ((String.ofList out.toList).splitOn " " |>.filter (fun w => !w.trimAscii.toString.isEmpty))
  return collapsed
    |>.replace "&amp;" "&"
    |>.replace "&lt;" "<"
    |>.replace "&gt;" ">"
    |>.replace "&quot;" "\""
    |>.replace "&#39;" "'"
    |>.replace "&nbsp;" " "

private def execFetchUrl (args : JVal) : IO (Except String String) := do
  let some url := args.fieldStr? "url" | return .error "Missing 'url' argument"
  let hdrs := #[("User-Agent", "Mozilla/5.0 (compatible; Sandboxed/1.0)")]
  match (← sendRequestFollowingRedirects "GET" url hdrs ByteArray.empty 60000) with
  | .error e => return .error e
  | .ok resp =>
    if resp.status < 200 || resp.status ≥ 300 then
      return .error s!"HTTP error: {resp.status}"
    let ct := (resp.headers.find? (fun (k, _) => k.toLower == "content-type")).map Prod.snd |>.getD ""
    let body := (String.fromUTF8? resp.body).getD ""
    let ext :=
      if (findSubstrFrom? ct "application/json" 0).isSome then "json"
      else if (findSubstrFrom? ct "text/html" 0).isSome then "html"
      else if (findSubstrFrom? ct "text/csv" 0).isSome then "csv"
      else if (findSubstrFrom? ct "xml" 0).isSome then "xml"
      else "txt"
    let disp := if (findSubstrFrom? ct "text/html" 0).isSome then extractTextFromHtml body else body
    if body.utf8ByteSize > 20000 then
      let uid ← newUuidV4
      let fp := System.FilePath.mk "/tmp" / s!"fetch_{uid}.{ext}"
      IO.FS.writeFile fp body
      let previewChars := disp.toList.take 2000
      let preview := String.ofList previewChars
      let suffix := if disp.length > preview.length then "\n..." else ""
      return .ok s!"Response too large ({body.utf8ByteSize} bytes). Full content saved to: {fp}\n\nPreview (first {preview.length} chars):\n{preview}{suffix}"
    return .ok disp

private def execUpdateSkill (args : JVal) : IO (Except String String) := do
  let some skillName := args.fieldStr? "skill_name" | return .error "Missing 'skill_name' argument"
  let some content := args.fieldStr? "content" | return .error "Missing 'content' argument"
  let filePath? := args.fieldStr? "file_path"
  if (findSubstrFrom? skillName ".." 0).isSome || skillName.contains '/' || skillName.contains '\\' then
    return .error "Invalid skill name: contains path separators or '..'"
  let apiBase := (← getEnvNonEmpty "SANDBOXED_SH_API_URL").getD "http://127.0.0.1:3000"
  let authTok? ← getEnvNonEmpty "SANDBOXED_SH_API_TOKEN"
  let url ← match filePath? with
    | some rp =>
      if (findSubstrFrom? rp ".." 0).isSome then
        return .error "Invalid file_path: contains '..'"
      pure s!"{apiBase}/api/library/skill/{skillName}/files/{rp}"
    | none =>
      pure s!"{apiBase}/api/library/skill/{skillName}"
  let payload := JVal.obj #[("content", .str content)]
  match (← sendJsonRequest "PUT" url authTok? (some payload)) with
  | .error e => return .error e
  | .ok (status, bodyTxt, _) =>
    if 200 ≤ status && status < 300 then
      let tgt := filePath?.getD "SKILL.md"
      return .ok s!"Successfully updated skill '{skillName}' (file: {tgt}). Changes will sync to workspaces."
    else
      return .error s!"Failed to update skill: {status} - {bodyTxt}"

/-! ### Tool Schema Definitions (Sorted Alphabetically) -/

private def mkSchemaProp (ty desc : String) : JVal :=
  .obj #[("type", .str ty), ("description", .str desc)]

def toolDefinitions : Array JVal := #[
  .obj #[
    ("name", .str "delete_file"),
    ("description", .str "Delete a file. Use relative paths to delete workspace files, or absolute paths for system files (use with caution)."),
    ("inputSchema", .obj #[
      ("type", .str "object"),
      ("properties", .obj #[("path", mkSchemaProp "string" "File path. Use relative paths (e.g., 'temp/old_file.txt') for workspace files.")]),
      ("required", .arr #[.str "path"])
    ])
  ],
  .obj #[
    ("name", .str "fetch_url"),
    ("description", .str "Fetch the content of a URL. For small responses (<20KB), returns the content directly. For large responses, saves the full content to /tmp/ and returns the file path with a preview. Useful for reading documentation, APIs, or downloading data."),
    ("inputSchema", .obj #[
      ("type", .str "object"),
      ("properties", .obj #[("url", mkSchemaProp "string" "The URL to fetch")]),
      ("required", .arr #[.str "url"])
    ])
  ],
  .obj #[
    ("name", .str "grep_search"),
    ("description", .str "Search for a pattern in file contents using regex. Searches workspace by default. Great for finding function definitions, usages, or patterns."),
    ("inputSchema", .obj #[
      ("type", .str "object"),
      ("properties", .obj #[
        ("pattern", mkSchemaProp "string" "Regex pattern to search for"),
        ("path", mkSchemaProp "string" "Directory to search. Defaults to workspace ('.'). Use relative paths for subdirectories or absolute for system search."),
        ("file_pattern", mkSchemaProp "string" "Optional: only search files matching this glob (e.g., '*.rs', '*.py', '*.log')"),
        ("case_sensitive", mkSchemaProp "boolean" "Whether search is case-sensitive (default: false)")
      ]),
      ("required", .arr #[.str "pattern"])
    ])
  ],
  .obj #[
    ("name", .str "list_directory"),
    ("description", .str "List files and directories. Use '.' for current workspace, relative paths like 'src/', or absolute paths for system directories."),
    ("inputSchema", .obj #[
      ("type", .str "object"),
      ("properties", .obj #[
        ("path", mkSchemaProp "string" "Directory path. Use '.' for workspace root, relative paths (e.g., 'src/', 'output/') for subdirectories, or absolute paths for system dirs."),
        ("max_depth", mkSchemaProp "integer" "Maximum depth to traverse (default: 3)")
      ]),
      ("required", .arr #[.str "path"])
    ])
  ],
  .obj #[
    ("name", .str "read_file"),
    ("description", .str "Read a file's contents. Use relative paths like 'src/main.rs' (recommended) or absolute paths like '/etc/hosts' for system files."),
    ("inputSchema", .obj #[
      ("type", .str "object"),
      ("properties", .obj #[
        ("path", mkSchemaProp "string" "File path. Use relative paths (e.g., 'output/data.json') for workspace files, or absolute paths (e.g., '/var/log/app.log') for system files."),
        ("start_line", mkSchemaProp "integer" "Optional: start reading from this line number (1-indexed)"),
        ("end_line", mkSchemaProp "integer" "Optional: stop reading at this line number (inclusive)")
      ]),
      ("required", .arr #[.str "path"])
    ])
  ],
  .obj #[
    ("name", .str "search_files"),
    ("description", .str "Search for files by name pattern (glob-style). Searches workspace by default, or specify a path."),
    ("inputSchema", .obj #[
      ("type", .str "object"),
      ("properties", .obj #[
        ("pattern", mkSchemaProp "string" "File name pattern to search for (e.g., '*.rs', 'test_*.py', 'README*')"),
        ("path", mkSchemaProp "string" "Directory to search in. Defaults to workspace ('.'). Use relative paths or absolute for system-wide search.")
      ]),
      ("required", .arr #[.str "pattern"])
    ])
  ],
  .obj #[
    ("name", .str "update_skill"),
    ("description", .str "Update skill content in the library. Writes to SKILL.md or additional reference files. Changes are synced to all workspaces that use this skill. Use this to keep skill data (like reference materials, examples, or instructions) up to date."),
    ("inputSchema", .obj #[
      ("type", .str "object"),
      ("properties", .obj #[
        ("skill_name", mkSchemaProp "string" "Name of the skill to update (folder name in library/skill/)"),
        ("content", mkSchemaProp "string" "The new content for SKILL.md (the main skill file)"),
        ("file_path", mkSchemaProp "string" "Optional: path to a reference file within the skill (e.g., 'references/examples.md'). If provided, updates this file instead of SKILL.md")
      ]),
      ("required", .arr #[.str "skill_name", .str "content"])
    ])
  ],
  .obj #[
    ("name", .str "write_file"),
    ("description", .str "Write content to a file. Use relative paths like 'output/report.md' (recommended) to stay in your workspace. Creates parent directories as needed."),
    ("inputSchema", .obj #[
      ("type", .str "object"),
      ("properties", .obj #[
        ("path", mkSchemaProp "string" "File path. Use relative paths (e.g., 'output/report.md', 'temp/data.json') for workspace files."),
        ("content", mkSchemaProp "string" "The content to write to the file")
      ]),
      ("required", .arr #[.str "path", .str "content"])
    ])
  ]
]

private def runTool (name : String) (args : JVal) (workingDir : System.FilePath) : IO JVal := do
  let res ←
    match name with
    | "read_file"      => execReadFile args workingDir
    | "write_file"     => execWriteFile args workingDir
    | "delete_file"    => execDeleteFile args workingDir
    | "list_directory" => execListDirectory args workingDir
    | "search_files"   => execSearchFiles args workingDir
    | "grep_search"    => execGrepSearch args workingDir
    | "fetch_url"      => execFetchUrl args
    | "update_skill"   => execUpdateSkill args
    | _ => pure (.error s!"Unknown tool: {name}")
  match res with
  | .ok txt =>
    return .obj #[
      ("content", .arr #[.obj #[("type", .str "text"), ("text", .str txt)]]),
      ("isError", .bool false)
    ]
  | .error err =>
    let msg := if err.startsWith "Unknown tool:" then err else s!"Tool error: {err}"
    return .obj #[
      ("content", .arr #[.obj #[("type", .str "text"), ("text", .str msg)]]),
      ("isError", .bool true)
    ]

def runMain (_args : List String) : IO UInt32 := do
  IO.eprintln "[workspace-mcp] Starting MCP server for workspace tools..."
  let initialWs ← hydrateWorkspaceEnv none
  let wsLock ← Std.Mutex.new initialWs
  serveStdio fun req _cancelRef => do
    let idVal := req.fieldOrNull "id"
    let method := (req.fieldStr? "method").getD ""
    match method with
    | "initialize" =>
      let params := req.fieldOrNull "params"
      if let some p := extractWorkspaceFromInitialize? params then
        let resolved ← hydrateWorkspaceEnv (some p)
        wsLock.atomically (set resolved)
      applyRuntimeWorkspace wsLock
      return jsonRpcSuccess idVal (.obj #[
        ("protocolVersion", .str "2024-11-05"),
        ("serverInfo", .obj #[("name", .str "workspace-mcp"), ("version", .str appVersion)]),
        ("capabilities", .obj #[("tools", .obj #[("listChanged", .bool false)])])
      ])
    | "ping" =>
      return jsonRpcSuccess idVal (.obj #[])
    | "tools/list" =>
      return jsonRpcSuccess idVal (.obj #[("tools", .arr toolDefinitions)])
    | "tools/call" =>
      applyRuntimeWorkspace wsLock
      let params := req.fieldOrNull "params"
      let name := (params.fieldStr? "name").getD ""
      let args := (params.field? "arguments").getD (.obj #[])
      let cwd ← wsLock.atomically get
      let toolRes ← runTool name args cwd
      return jsonRpcSuccess idVal toolRes
    | _ =>
      return jsonRpcError idVal (-32601) s!"Method not found: {method}"
  return 0

end OrbBin.WorkspaceMcp
