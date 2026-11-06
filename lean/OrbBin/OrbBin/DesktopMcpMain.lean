/-
  OrbBin.DesktopMcpMain: Headless Wayland / Sway Desktop Automation MCP Server (`desktop-mcp`).
  Replaces `src/bin/desktop_mcp.rs` in native Lean 4.
  Exposes `desktop_start_session`, `desktop_stop_session`, `desktop_screenshot`, `desktop_type`,
  `desktop_click`, `desktop_mouse_move`, `desktop_scroll`, `desktop_i3_command`, and `desktop_get_text`.
-/
import Std.Sync.Mutex
import OrbBin.PosixExt
import OrbBin.Json
import OrbBin.StdioMcpServer

namespace OrbBin.DesktopMcp

open OrbBin.PosixExt
open OrbBin.Json
open OrbBin.StdioMcpServer

def appVersion : String := "1.3.0"

structure WaylandEnv where
  xdgRuntimeDir  : System.FilePath
  waylandDisplay : String
  swaySocket     : System.FilePath

private def getWorkingDir : IO System.FilePath := do
  match (← getEnvNonEmpty "WORKING_DIR") with
  | some d => return System.FilePath.mk d
  | none => IO.currentDir

private def getResolution : IO String := do
  return (← getEnvNonEmpty "DESKTOP_RESOLUTION").getD "1280x720"

private def parseDisplayNum (display : String) : Except String Nat := do
  let stripped := if display.startsWith ":" then (display.drop 1).toString else display
  match stripped.toNat? with
  | some n => return n
  | none => throw s!"Invalid display format: {display}"

private def waylandEnvForDisplay (display : String) : IO (Except String WaylandEnv) := do
  match parseDisplayNum display with
  | .error e => return .error e
  | .ok num =>
    let wd ← getWorkingDir
    let xdg := wd / ".sandboxed-sh" / "wayland" / toString num
    return .ok {
      xdgRuntimeDir := xdg
      waylandDisplay := "wayland-1"
      swaySocket := xdg / "sway-ipc.sock"
    }

private def waylandEnvPairs (env : WaylandEnv) : Array (String × Option String) := #[
  ("XDG_RUNTIME_DIR", some env.xdgRuntimeDir.toString),
  ("WAYLAND_DISPLAY", some env.waylandDisplay),
  ("SWAYSOCK", some env.swaySocket.toString),
  ("GDK_BACKEND", some "wayland"),
  ("QT_QPA_PLATFORM", some "wayland"),
  ("MOZ_ENABLE_WAYLAND", some "1")
]

private def runWithWayland
    (env : WaylandEnv) (prog : String) (args : Array String) : IO (Except String (String × String × UInt32)) := do
  try
    let out ← IO.Process.output {
      cmd := prog
      args := args
      env := waylandEnvPairs env
    }
    return .ok (out.stdout, out.stderr, out.exitCode)
  catch e =>
    return .error s!"Failed to execute {prog}: {e}"

private def wlrctlMoveAbsolute (env : WaylandEnv) (x y : Int) : IO (Except String Unit) := do
  match (← runWithWayland env "wlrctl" #["pointer", "move", "-20000", "-20000"]) with
  | .error e => return .error e
  | .ok (_, stderr, code) =>
    if code != 0 then return .error s!"wlrctl pointer move failed: {stderr}"
    match (← runWithWayland env "wlrctl" #["pointer", "move", toString x, toString y]) with
    | .error e => return .error e
    | .ok (_, stderr2, code2) =>
      if code2 != 0 then return .error s!"wlrctl pointer move failed: {stderr2}"
      return .ok ()

private def keyForWtype (key : String) : String :=
  let mapped := (key.splitOn "+").map fun part =>
    match part with
    | "ctrl" => "leftctrl"
    | "alt" => "leftalt"
    | "shift" => "leftshift"
    | "super" => "leftmeta"
    | "Return" => "enter"
    | "BackSpace" => "backspace"
    | "Escape" => "esc"
    | "Page_Up" => "pageup"
    | "Page_Down" => "pagedown"
    | other => other
  String.intercalate "+" mapped

private def findBrowserCommand : IO (Option String) := do
  let mut cands : Array String := #[]
  if let some cb ← getEnvNonEmpty "CHROMIUM_BIN" then
    cands := cands.push cb
  if let some br ← getEnvNonEmpty "BROWSER" then
    for seg in br.splitOn ":" do
      let t := seg.trimAscii.toString
      if !t.isEmpty then cands := cands.push t
  for defBin in ["chromium", "chromium-browser", "google-chrome", "google-chrome-stable", "brave-browser", "microsoft-edge", "msedge"] do
    cands := cands.push defBin
  let pathDirs := ((← getEnvNonEmpty "PATH").getD "/usr/local/bin:/usr/bin:/bin").splitOn ":"
  for c in cands do
    if !c.isEmpty then
      if c.startsWith "/" || c.contains '/' then
        if (← statPath c).exists_ then return some c
      else
        for d in pathDirs do
          let full := (System.FilePath.mk d / c).toString
          if (← statPath full).exists_ then return some full
  return none

private def runtimeDisplayPath : IO System.FilePath := do
  let wd ← getWorkingDir
  return wd / ".sandboxed-sh" / "runtime" / "current_display.json"

private def writeDisplayInfo (display : String) : IO (Except String Unit) := do
  let p ← runtimeDisplayPath
  if let some par := p.parent then
    try IO.FS.createDirAll par catch e => return .error s!"Failed to create runtime dir: {e}"
  let epoch ← nowEpoch
  let payload := JVal.obj #[("display", .str display), ("updated_at", .str s!"{epoch}")]
  try
    IO.FS.writeFile p (renderPretty payload)
    return .ok ()
  catch e =>
    return .error s!"Failed to write display info: {e}"

private def clearDisplayInfoIfCurrent (display : String) : IO Unit := do
  let p ← runtimeDisplayPath
  try
    let txt ← IO.FS.readFile p
    if let .ok j := Json.parse txt then
      if j.fieldStr? "display" == some display then
        IO.FS.removeFile p
  catch _ => pure ()

private def spawnDetachedWithEnv
    (prog : String) (args : Array String) (extraEnv : Array (String × String)) : IO (Except String Int64) := do
  let baseEnv ← currentEnvPairs
  let mut merged := baseEnv
  for (k, v) in extraEnv do
    merged := (merged.filter (fun (ek, _) => ek != k)).push (k, v)
  let envStrs := merged.map (fun (k, v) => s!"{k}={v}")
  try
    let sp ← spawnPgrp prog args envStrs false true
    return .ok sp.pid
  catch e =>
    return .error s!"{e}"

/-! ### Tool Handlers -/

private def toolStartSession (counterLock : Std.Mutex Nat) (args : JVal) : IO (Except String String) := do
  let displayNum ← counterLock.atomically do
    let cur ← get
    set (cur + 1)
    return cur
  let displayId := s!":{displayNum}"
  let resolution ← getResolution
  let wenv ← match (← waylandEnvForDisplay displayId) with
    | .ok e => pure e
    | .error err => return .error err
  try IO.FS.removeDirAll wenv.xdgRuntimeDir catch _ => pure ()
  try IO.FS.createDirAll wenv.xdgRuntimeDir catch e => return .error s!"Failed to create runtime dir: {e}"
  let _ ← chmod wenv.xdgRuntimeDir.toString 0o700
  let swayCfg := wenv.xdgRuntimeDir / "sway.config"
  let cfgText :=
    s!"output * resolution {resolution}\ndefault_border none\ndefault_floating_border none\ngaps inner 0\ngaps outer 0\nfocus_follows_mouse no\nseat * hide_cursor 5000\nexec_always true\n"
  try IO.FS.writeFile swayCfg cfgText catch e => return .error s!"Failed to write sway config: {e}"
  let swayEnv := #[
    ("XDG_RUNTIME_DIR", wenv.xdgRuntimeDir.toString),
    ("WAYLAND_DISPLAY", wenv.waylandDisplay),
    ("SWAYSOCK", wenv.swaySocket.toString),
    ("GDK_BACKEND", "wayland"),
    ("QT_QPA_PLATFORM", "wayland"),
    ("MOZ_ENABLE_WAYLAND", "1"),
    ("WLR_BACKENDS", "headless"),
    ("WLR_LIBINPUT_NO_DEVICES", "1")
  ]
  let swayPid ← match (← spawnDetachedWithEnv "sway" #["--unsupported-gpu", "-c", swayCfg.toString] swayEnv) with
    | .ok p => pure p
    | .error e => return .error s!"Failed to start sway: {e}. Is sway installed?"
  IO.sleep 900
  let st0 ← waitpidWnohang swayPid
  if st0 != 0xFFFFFFFF then
    return .error s!"Sway exited immediately with status: {st0}"
  match (← runWithWayland wenv "swaymsg" #["-t", "get_outputs"]) with
  | .error e =>
    let _ ← killSig swayPid 9
    return .error e
  | .ok (_, stderr, code) =>
    if code != 0 then
      let _ ← killSig swayPid 9
      return .error s!"Sway did not become ready: {stderr}"
  let wd ← getWorkingDir
  let screenshotsDir := wd / "screenshots"
  try IO.FS.createDirAll screenshotsDir catch e =>
    let _ ← killSig swayPid 9
    return .error s!"Failed to create screenshots dir: {e}"
  let launchBrowser := (args.fieldBool? "launch_browser").getD false
  let (browserPid?, browserInfoJson) ←
    if launchBrowser then
      let url := (args.fieldStr? "url").getD "about:blank"
      let some browserCmd ← findBrowserCommand | do
        let _ ← killSig swayPid 9
        return .error "Failed to start Chromium: no browser binary found (set CHROMIUM_BIN or BROWSER)"
      let profileDir := wenv.xdgRuntimeDir / "browser-profile"
      let brArgs := #[
        "--no-sandbox", "--disable-setuid-sandbox", "--disable-dev-shm-usage",
        "--force-renderer-accessibility", "--disable-infobars",
        "--disable-session-crashed-bubble", "--disable-restore-session-state",
        "--no-first-run", "--disable-translate", "--disable-default-apps",
        "--disable-popup-blocking", "--disable-prompt-on-repost",
        "--disable-hang-monitor", "--disable-client-side-phishing-detection",
        "--disable-background-networking", "--disable-sync", "--disable-extensions",
        "--ozone-platform=wayland", "--enable-features=UseOzonePlatform",
        "--start-fullscreen", "--new-window",
        s!"--user-data-dir={profileDir}", url
      ]
      let brEnv := #[
        ("XDG_RUNTIME_DIR", wenv.xdgRuntimeDir.toString),
        ("WAYLAND_DISPLAY", wenv.waylandDisplay),
        ("SWAYSOCK", wenv.swaySocket.toString),
        ("GDK_BACKEND", "wayland"),
        ("QT_QPA_PLATFORM", "wayland"),
        ("MOZ_ENABLE_WAYLAND", "1")
      ]
      let cPid ← match (← spawnDetachedWithEnv browserCmd brArgs brEnv) with
        | .ok p => pure p
        | .error e =>
          let _ ← killSig swayPid 9
          return .error s!"Failed to start Chromium: {e}"
      IO.sleep 400
      let bst ← waitpidWnohang cPid
      if bst != 0xFFFFFFFF then
        let _ ← killSig swayPid 9
        return .error s!"Browser exited immediately with status: {bst}"
      IO.sleep 2000
      let _ ← runWithWayland wenv "swaymsg" #["fullscreen", "enable"]
      pure (some cPid, s!", \"browser\": {escapeJsonString browserCmd}, \"browser_pid\": {cPid}, \"url\": {escapeJsonString url}")
    else
      pure (none, "")
  let sessionFile := wd / s!".desktop_session_{displayNum}"
  let mut sessFields : Array (String × JVal) := #[
    ("display", .str displayId),
    ("display_num", JVal.nat displayNum),
    ("sway_pid", JVal.int (Int.ofNat swayPid.toNatClampNeg)),
    ("display_server", .str "wayland"),
    ("compositor", .str "sway-headless"),
    ("resolution", .str resolution),
    ("xdg_runtime_dir", .str wenv.xdgRuntimeDir.toString),
    ("wayland_display", .str wenv.waylandDisplay),
    ("sway_socket", .str wenv.swaySocket.toString),
    ("screenshots_dir", .str screenshotsDir.toString)
  ]
  if let some bp := browserPid? then
    sessFields := sessFields.push ("browser_pid", JVal.int (Int.ofNat bp.toNatClampNeg))
  try
    IO.FS.writeFile sessionFile (renderPretty (.obj sessFields))
  catch e =>
    if let some bp := browserPid? then let _ ← killSig bp 9
    let _ ← killSig swayPid 9
    return .error s!"Failed to write session file: {e}"
  if let .error e ← writeDisplayInfo displayId then
    return .error e
  return .ok s!"\{\"success\": true, \"display\": {escapeJsonString displayId}, \"display_server\": \"wayland\", \"compositor\": \"sway-headless\", \"resolution\": {escapeJsonString resolution}, \"sway_pid\": {swayPid}, \"wayland_display\": {escapeJsonString wenv.waylandDisplay}, \"xdg_runtime_dir\": {escapeJsonString wenv.xdgRuntimeDir.toString}, \"screenshots_dir\": {escapeJsonString screenshotsDir.toString}{browserInfoJson}}"

private def toolStopSession (args : JVal) : IO (Except String String) := do
  let some displayId := args.fieldStr? "display" | return .error "Missing 'display' argument"
  let displayNum ← match parseDisplayNum displayId with
    | .ok n => pure n
    | .error e => return .error e
  let wd ← getWorkingDir
  let sessionFile := wd / s!".desktop_session_{displayNum}"
  let mut killed : Array Int := #[]
  if (← statPath sessionFile.toString).exists_ then
    try
      let txt ← IO.FS.readFile sessionFile
      if let .ok info := Json.parse txt then
        for k in ["sway_pid", "browser_pid", "xvfb_pid", "i3_pid"] do
          if let some p := info.fieldNat? k then
            if p > 0 then
              let _ ← killSig (Int64.ofNat p) 15
              killed := killed.push (Int.ofNat p)
    catch _ => pure ()
    try IO.FS.removeFile sessionFile catch _ => pure ()
  if let .ok wenv ← waylandEnvForDisplay displayId then
    try
      let _ ← IO.Process.output { cmd := "pkill", args := #["-f", s!"WAYLAND_DISPLAY={wenv.waylandDisplay}"] }
    catch _ => pure ()
    try IO.FS.removeDirAll wenv.xdgRuntimeDir catch _ => pure ()
  clearDisplayInfoIfCurrent displayId
  let killedJson := renderCompact (.arr (killed.map JVal.int))
  return .ok s!"\{\"success\": true, \"display\": {escapeJsonString displayId}, \"killed_pids\": {killedJson}}"

private def toolScreenshot (args : JVal) : IO (Except String (String × Option String)) := do
  let some displayId := args.fieldStr? "display" | return .error "Missing 'display' argument"
  if let some waitSec := args.fieldNat? "wait_seconds" then
    if waitSec > 0 then IO.sleep (waitSec * 1000).toUInt32
  let epoch ← nowEpoch
  let shotId ← newUuidV4
  let filename := (args.fieldStr? "filename").getD s!"screenshot_{epoch}_{shotId}.png"
  let wd ← getWorkingDir
  let screenshotsDir := wd / "screenshots"
  try IO.FS.createDirAll screenshotsDir catch e => return .error s!"Failed to create screenshots dir: {e}"
  let filepath := screenshotsDir / filename
  let wenv ← match (← waylandEnvForDisplay displayId) with
    | .ok e => pure e
    | .error err => return .error err
  let mut grimArgs : Array String := #[]
  if let some reg := args.field? "region" then
    if reg.asObj?.isSome then
      let rx := (reg.fieldInt? "x").getD 0
      let ry := (reg.fieldInt? "y").getD 0
      let rw := (reg.fieldInt? "width").getD 100
      let rh := (reg.fieldInt? "height").getD 100
      grimArgs := grimArgs ++ #["-g", s!"{rx},{ry} {rw}x{rh}"]
  grimArgs := grimArgs.push filepath.toString
  match (← runWithWayland wenv "grim" grimArgs) with
  | .error e => return .error e
  | .ok (_, stderr, code) =>
    if code != 0 then return .error s!"Screenshot failed. grim error: {stderr}"
    if !(← statPath filepath.toString).exists_ then
      return .error "Screenshot file was not created"
    let rawBytes ← try IO.FS.readBinFile filepath catch e => return .error s!"Failed to read screenshot: {e}"
    let retImg := (args.fieldBool? "return_image").getD false
    let imgB64? := if retImg then some (base64Encode rawBytes false true) else none
    let resText := s!"\{\"success\": true, \"path\": {escapeJsonString filepath.toString}, \"size_bytes\": {rawBytes.size}}"
    return .ok (resText, imgB64?)

private def toolTypeText (args : JVal) : IO (Except String String) := do
  let some displayId := args.fieldStr? "display" | return .error "Missing 'display' argument"
  let delayMs := (args.fieldNat? "delay_ms").getD 12
  let (cmdKind, inputVal) ←
    if let some txt := args.fieldStr? "text" then pure ("type", txt)
    else if let some k := args.fieldStr? "key" then pure ("key", k)
    else return .error "Either 'text' or 'key' must be provided"
  let wenv ← match (← waylandEnvForDisplay displayId) with
    | .ok e => pure e
    | .error err => return .error err
  let dStr := toString delayMs
  let wArgs :=
    if cmdKind == "type" then #["-d", dStr, inputVal]
    else
      let kw := keyForWtype inputVal
      #["-d", dStr, "-P", kw, "-p", kw]
  match (← runWithWayland wenv "wtype" wArgs) with
  | .error e => return .error e
  | .ok (_, stderr, code) =>
    if code != 0 then return .error s!"wtype failed: {stderr}"
    return .ok s!"\{\"success\": true, \"command\": {escapeJsonString cmdKind}, \"input\": {escapeJsonString inputVal}}"

private def toolClick (args : JVal) : IO (Except String String) := do
  let some displayId := args.fieldStr? "display" | return .error "Missing 'display' argument"
  let some x := args.fieldInt? "x" | return .error "Missing 'x' argument"
  let some y := args.fieldInt? "y" | return .error "Missing 'y' argument"
  let button := (args.fieldStr? "button").getD "left"
  if !(button == "left" || button == "middle" || button == "right") then
    return .error s!"Invalid button: {button}"
  let dbl := (args.fieldBool? "double").getD false
  let wenv ← match (← waylandEnvForDisplay displayId) with
    | .ok e => pure e
    | .error err => return .error err
  if let .error e ← wlrctlMoveAbsolute wenv x y then
    return .error e
  IO.sleep 50
  let clicks := if dbl then 2 else 1
  for _ in [0:clicks] do
    match (← runWithWayland wenv "wlrctl" #["pointer", "click", button]) with
    | .error e => return .error e
    | .ok (_, stderr, code) =>
      if code != 0 then return .error s!"wlrctl pointer click failed: {stderr}"
  return .ok s!"\{\"success\": true, \"x\": {x}, \"y\": {y}, \"button\": {escapeJsonString button}, \"double\": {if dbl then "true" else "false"}}"

private def toolMouseMove (args : JVal) : IO (Except String String) := do
  let some displayId := args.fieldStr? "display" | return .error "Missing 'display' argument"
  let some x := args.fieldInt? "x" | return .error "Missing 'x' argument"
  let some y := args.fieldInt? "y" | return .error "Missing 'y' argument"
  let wenv ← match (← waylandEnvForDisplay displayId) with
    | .ok e => pure e
    | .error err => return .error err
  if let .error e ← wlrctlMoveAbsolute wenv x y then
    return .error e
  return .ok s!"\{\"success\": true, \"x\": {x}, \"y\": {y}}"

private def toolScroll (args : JVal) : IO (Except String String) := do
  let some displayId := args.fieldStr? "display" | return .error "Missing 'display' argument"
  let some amount := args.fieldInt? "amount" | return .error "Missing 'amount' argument"
  let wenv ← match (← waylandEnvForDisplay displayId) with
    | .ok e => pure e
    | .error err => return .error err
  if let (some x, some y) := (args.fieldInt? "x", args.fieldInt? "y") then
    if let .error e ← wlrctlMoveAbsolute wenv x y then
      return .error e
    IO.sleep 50
  match (← runWithWayland wenv "wlrctl" #["pointer", "scroll", toString amount, "0"]) with
  | .error e => return .error e
  | .ok (_, stderr, code) =>
    if code != 0 then return .error s!"wlrctl scroll failed: {stderr}"
    let dir := if amount ≥ 0 then "down" else "up"
    return .ok s!"\{\"success\": true, \"amount\": {amount}, \"direction\": {escapeJsonString dir}}"

private def toolI3Command (args : JVal) : IO (Except String String) := do
  let some displayId := args.fieldStr? "display" | return .error "Missing 'display' argument"
  let some command := args.fieldStr? "command" | return .error "Missing 'command' argument"
  let wenv ← match (← waylandEnvForDisplay displayId) with
    | .ok e => pure e
    | .error err => return .error err
  match (← runWithWayland wenv "swaymsg" #[command]) with
  | .error e => return .error e
  | .ok (stdout, stderr, code) =>
    if code != 0 then return .error s!"swaymsg failed: {stdout} {stderr}"
    let trimmed := stdout.trimAscii.toString
    if trimmed.startsWith "[" || trimmed.startsWith "{" then
      return .ok trimmed
    return .ok s!"\{\"success\": true, \"output\": {escapeJsonString trimmed}}"

private def toolGetText (args : JVal) : IO (Except String String) := do
  let some displayId := args.fieldStr? "display" | return .error "Missing 'display' argument"
  let wd ← getWorkingDir
  let screenshotsDir := wd / "screenshots"
  try IO.FS.createDirAll screenshotsDir catch e => return .error s!"Failed to create screenshots dir: {e}"
  let reqId ← newUuidV4
  let tmpPng := screenshotsDir / s!"_ocr_temp_{reqId}.png"
  let wenv ← match (← waylandEnvForDisplay displayId) with
    | .ok e => pure e
    | .error err => return .error err
  match (← runWithWayland wenv "grim" #[tmpPng.toString]) with
  | .error e =>
    try IO.FS.removeFile tmpPng catch _ => pure ()
    return .error e
  | .ok (_, stderr, code) =>
    if code != 0 then
      try IO.FS.removeFile tmpPng catch _ => pure ()
      return .error s!"Failed to take screenshot for OCR: {stderr}"
    let out ←
      try IO.Process.output { cmd := "tesseract", args := #[tmpPng.toString, "stdout", "-l", "eng"] }
      catch e =>
        try IO.FS.removeFile tmpPng catch _ => pure ()
        return .error s!"Failed to run tesseract: {e}"
    try IO.FS.removeFile tmpPng catch _ => pure ()
    if out.exitCode != 0 then
      return .error s!"Tesseract failed: {out.stderr}"
    return .ok s!"--- OCR Text ---\n{out.stdout.trimAscii}"

/-! ### Tool Schema Definitions -/

private def mkProp (ty desc : String) : JVal :=
  .obj #[("type", .str ty), ("description", .str desc)]

def toolDefinitions : Array JVal := #[
  .obj #[
    ("name", .str "desktop_start_session"),
    ("description", .str "Start a virtual desktop session (Xvfb + i3 window manager). Returns the DISPLAY identifier (e.g., ':99') needed for other desktop_* tools. Call this before using any other desktop tools. Optionally launches Chromium browser."),
    ("inputSchema", .obj #[
      ("type", .str "object"),
      ("properties", .obj #[
        ("launch_browser", mkProp "boolean" "If true, automatically launch Chromium browser after starting the session (default: false)"),
        ("url", mkProp "string" "Optional URL to open in Chromium (only used if launch_browser is true)")
      ]),
      ("required", .arr #[])
    ])
  ],
  .obj #[
    ("name", .str "desktop_stop_session"),
    ("description", .str "Stop a virtual desktop session. Kills Xvfb and all associated processes."),
    ("inputSchema", .obj #[
      ("type", .str "object"),
      ("properties", .obj #[("display", mkProp "string" "The display identifier (e.g., ':99') returned by desktop_start_session")]),
      ("required", .arr #[.str "display"])
    ])
  ],
  .obj #[
    ("name", .str "desktop_screenshot"),
    ("description", .str "Take a screenshot of the virtual desktop. Use wait_seconds (3-5s recommended) after launching apps to let them render."),
    ("inputSchema", .obj #[
      ("type", .str "object"),
      ("properties", .obj #[
        ("display", mkProp "string" "The display identifier (e.g., ':99')"),
        ("wait_seconds", mkProp "number" "Seconds to wait before taking screenshot (default: 0)"),
        ("return_image", mkProp "boolean" "If true, return the image data as base64 for vision analysis (default: false)"),
        ("filename", mkProp "string" "Optional filename for the screenshot"),
        ("region", .obj #[
          ("type", .str "object"),
          ("description", .str "Optional region to capture (x, y, width, height)"),
          ("properties", .obj #[
            ("x", .obj #[("type", .str "integer")]),
            ("y", .obj #[("type", .str "integer")]),
            ("width", .obj #[("type", .str "integer")]),
            ("height", .obj #[("type", .str "integer")])
          ])
        ])
      ]),
      ("required", .arr #[.str "display"])
    ])
  ],
  .obj #[
    ("name", .str "desktop_type"),
    ("description", .str "Send keyboard input. Provide 'text' to type characters or 'key' for special keys (Return, Tab, Escape, ctrl+a, alt+F4, etc.)."),
    ("inputSchema", .obj #[
      ("type", .str "object"),
      ("properties", .obj #[
        ("display", mkProp "string" "The display identifier (e.g., ':99')"),
        ("text", mkProp "string" "Text to type (provide either 'text' OR 'key', not both)"),
        ("key", mkProp "string" "Key combination (e.g., 'Return', 'ctrl+a', 'alt+F4')"),
        ("delay_ms", mkProp "integer" "Delay between keystrokes in milliseconds (default: 12)")
      ]),
      ("required", .arr #[.str "display"])
    ])
  ],
  .obj #[
    ("name", .str "desktop_click"),
    ("description", .str "Click at a specific position. Coordinates are in pixels from top-left (0,0)."),
    ("inputSchema", .obj #[
      ("type", .str "object"),
      ("properties", .obj #[
        ("display", mkProp "string" "The display identifier (e.g., ':99')"),
        ("x", mkProp "integer" "X coordinate in pixels"),
        ("y", mkProp "integer" "Y coordinate in pixels"),
        ("button", .obj #[
          ("type", .str "string"),
          ("enum", .arr #[.str "left", .str "middle", .str "right"]),
          ("description", .str "Mouse button (default: 'left')")
        ]),
        ("double", mkProp "boolean" "Double-click (default: false)")
      ]),
      ("required", .arr #[.str "display", .str "x", .str "y"])
    ])
  ],
  .obj #[
    ("name", .str "desktop_mouse_move"),
    ("description", .str "Move the mouse cursor without clicking."),
    ("inputSchema", .obj #[
      ("type", .str "object"),
      ("properties", .obj #[
        ("display", mkProp "string" "The display identifier (e.g., ':99')"),
        ("x", mkProp "integer" "X coordinate"),
        ("y", mkProp "integer" "Y coordinate")
      ]),
      ("required", .arr #[.str "display", .str "x", .str "y"])
    ])
  ],
  .obj #[
    ("name", .str "desktop_scroll"),
    ("description", .str "Scroll the mouse wheel. Positive = down, negative = up."),
    ("inputSchema", .obj #[
      ("type", .str "object"),
      ("properties", .obj #[
        ("display", mkProp "string" "The display identifier (e.g., ':99')"),
        ("amount", mkProp "integer" "Scroll amount (positive = down, negative = up)"),
        ("x", mkProp "integer" "Optional: X coordinate to scroll at"),
        ("y", mkProp "integer" "Optional: Y coordinate to scroll at")
      ]),
      ("required", .arr #[.str "display", .str "amount"])
    ])
  ],
  .obj #[
    ("name", .str "desktop_i3_command"),
    ("description", .str "Execute i3 window manager commands. Use 'exec chromium --no-sandbox' to launch apps, 'split h/v' for layout, 'focus left/right/up/down' for navigation."),
    ("inputSchema", .obj #[
      ("type", .str "object"),
      ("properties", .obj #[
        ("display", mkProp "string" "The display identifier (e.g., ':99')"),
        ("command", mkProp "string" "The i3 command (e.g., 'exec chromium --no-sandbox', 'split h', 'focus right')")
      ]),
      ("required", .arr #[.str "display", .str "command"])
    ])
  ],
  .obj #[
    ("name", .str "desktop_get_text"),
    ("description", .str "Extract visible text from the desktop using OCR (Tesseract)."),
    ("inputSchema", .obj #[
      ("type", .str "object"),
      ("properties", .obj #[("display", mkProp "string" "The display identifier (e.g., ':99')")]),
      ("required", .arr #[.str "display"])
    ])
  ]
]

private def dispatchTool (counterLock : Std.Mutex Nat) (name : String) (args : JVal) : IO JVal := do
  if name == "desktop_screenshot" then
    match (← toolScreenshot args) with
    | .ok (txt, some b64) =>
      return .obj #[
        ("content", .arr #[
          .obj #[("type", .str "text"), ("text", .str txt)],
          .obj #[("type", .str "image"), ("data", .str b64), ("mimeType", .str "image/png")]
        ]),
        ("isError", .bool false)
      ]
    | .ok (txt, none) =>
      return .obj #[
        ("content", .arr #[.obj #[("type", .str "text"), ("text", .str txt)]]),
        ("isError", .bool false)
      ]
    | .error e =>
      return .obj #[
        ("content", .arr #[.obj #[("type", .str "text"), ("text", .str e)]]),
        ("isError", .bool true)
      ]
  let res ←
    match name with
    | "desktop_start_session" => toolStartSession counterLock args
    | "desktop_stop_session"  => toolStopSession args
    | "desktop_type"          => toolTypeText args
    | "desktop_click"         => toolClick args
    | "desktop_mouse_move"    => toolMouseMove args
    | "desktop_scroll"        => toolScroll args
    | "desktop_i3_command"    => toolI3Command args
    | "desktop_get_text"      => toolGetText args
    | _ => pure (.error s!"Unknown tool: {name}")
  match res with
  | .ok txt =>
    return .obj #[
      ("content", .arr #[.obj #[("type", .str "text"), ("text", .str txt)]]),
      ("isError", .bool false)
    ]
  | .error err =>
    return .obj #[
      ("content", .arr #[.obj #[("type", .str "text"), ("text", .str err)]]),
      ("isError", .bool true)
    ]

def runMain (_args : List String) : IO UInt32 := do
  IO.eprintln "[desktop-mcp] Starting MCP server for desktop tools..."
  let seedDisplay ← match (← getEnvNonEmpty "DISPLAY") with
    | some d =>
      match parseDisplayNum d with
      | .ok n => pure n
      | .error _ => pure 99
    | none => pure 99
  let counterLock ← Std.Mutex.new seedDisplay
  serveStdio fun req _cancelRef => do
    let idVal := req.fieldOrNull "id"
    let method := (req.fieldStr? "method").getD ""
    match method with
    | "initialize" =>
      return jsonRpcSuccess idVal (.obj #[
        ("protocolVersion", .str "2024-11-05"),
        ("serverInfo", .obj #[("name", .str "desktop-mcp"), ("version", .str appVersion)]),
        ("capabilities", .obj #[("tools", .obj #[("listChanged", .bool false)])])
      ])
    | "ping" =>
      return jsonRpcSuccess idVal (.obj #[])
    | "tools/list" =>
      return jsonRpcSuccess idVal (.obj #[("tools", .arr toolDefinitions)])
    | "tools/call" =>
      let params := req.fieldOrNull "params"
      let name := (params.fieldStr? "name").getD ""
      let args := (params.field? "arguments").getD (.obj #[])
      let res ← dispatchTool counterLock name args
      return jsonRpcSuccess idVal res
    | _ =>
      return jsonRpcError idVal (-32601) s!"Method not found: {method}"
  IO.eprintln "[desktop-mcp] Server shutting down"
  return 0

end OrbBin.DesktopMcp
