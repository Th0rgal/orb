import LeanUI.Style
import OrbDesktop.Chrome

/-!
# OrbDesktop.Tests.WindowEffects — Pure Lean U8 contract checks (`0` FFI)

Verifies the pure surface-alpha contract (`Theme.withWindowEffects`), 60-step spinner phase
(`liveSpinnerPhase`), case-insensitive status classification (`liveBadgeKind`), and
`liveMissionLead` vector paths & tones (active 4-quadrant rotation, paused bars, Bot fallback
for `awaiting_user` / idle) without requiring native C FFI libraries. Pixel-level CPU, Vulkan 1.3
GPU readback, and hybrid `EmbeddedSidebar` parity are checked natively in `orb-desktop-native --self-test`
(`windowEffectsSelfTest`) and `tests/test_u8_window_effects_parity.py`.
-/

open LeanUI OrbDesktop

private def check (cond : Bool) (msg : String) : IO Unit := do
  unless cond do
    throw (IO.userError s!"WindowEffects pure check failed: {msg}")

def main : IO Unit := do
  -- 1. Surface alphas match orb/src/styles.css [data-platform="linux"]
  let darkEff := Theme.withWindowEffects orbDarkTheme
  let lightEff := Theme.withWindowEffects orbLightTheme
  check ((darkEff.palette.sidebar &&& 0xFF) == 199) "dark sidebar alpha must be 199 (78%)"
  check ((lightEff.palette.sidebar &&& 0xFF) == 184) "light sidebar alpha must be 184 (72%)"
  check ((darkEff.palette.canvas &&& 0xFF) == 255 && (darkEff.palette.header &&& 0xFF) == 255)
    "dark main surface must be 100% solid (255)"
  check ((lightEff.palette.canvas &&& 0xFF) == 255 && (lightEff.palette.header &&& 0xFF) == 255)
    "light main surface must be 100% solid (255)"
  check ((orbDarkTheme.palette.sidebar &&& 0xFF) == 255 && (orbLightTheme.palette.sidebar &&& 0xFF) == 255)
    "headless opaque themes must remain opaque (255)"

  -- 2. Status vocabulary & case-insensitivity parity with WebKit/GTK
  for s in ["active", "ACTIVE", "running", "RUNNING", "starting", "resuming", "working", "in_progress", "processing", "streaming"] do
    check (liveBadgeKind s == "loader") s!"expected loader for {s}"
  for s in ["paused", "PAUSED", "interrupted", "cancelled", "canceled", "CANCELED"] do
    check (liveBadgeKind s == "pause") s!"expected pause for {s}"
  for s in ["failed", "FAILED", "blocked", "error", "errored", "not_feasible", "timed_out", "waiting_for_approval"] do
    check (liveBadgeKind s == "alert") s!"expected alert for {s}"
  for s in ["pending", "queued", "awaiting_wakeup", "waiting_background"] do
    check (liveBadgeKind s == "clock") s!"expected clock for {s}"
  for s in ["completed", "COMPLETED", "succeeded"] do
    check (liveBadgeKind s == "check") s!"expected check for {s}"
  for s in ["awaiting_user", "awaiting_approval", "AWAITING_APPROVAL", "idle", ""] do
    check (liveBadgeKind s == "") s!"expected empty (Bot fallback) for {s}"

  -- 3. Full 60-step spinner sweep (0..59)
  let seen := (List.range 60).map fun i => liveSpinnerPhase ((i * 1000 + 59) / 60)
  check (seen.eraseDups.length == 60) s!"expected 60 distinct spinner phases, got {seen.eraseDups.length}"

  -- 4. Active 4-quadrant arcs, paused bars, and awaiting_user Bot fallback
  let activePaths (ph : Nat) := match (liveMissionLead orbDarkTheme "active" ph).payloadOf with
    | .vectorIcon ps col none _ => (ps, col)
    | _ => ([], 0)
  let (a0, c0) := activePaths 0
  let (a15, _) := activePaths 15
  let (a30, _) := activePaths 30
  let (a45, _) := activePaths 45
  check (c0 == orbDarkTheme.palette.accent) "active spinner tone must be accent"
  check (a0 != a15 && a15 != a30 && a30 != a45 && a45 != a0 && a0 != a30)
    "active spinner must rotate across all 4 quadrants"

  match (liveMissionLead orbDarkTheme "paused" 0).payloadOf with
  | .vectorIcon ps col none _ =>
    check (ps == [[(55, 36), (55, 125)], [(105, 36), (105, 125)]]) "paused badge must draw two vertical bars"
    check (col == orbDarkTheme.palette.textMuted) "paused badge tone must be textMuted"
  | _ => check false "paused badge must be a vectorIcon"

  match (liveMissionLead orbDarkTheme "awaiting_user" 0).payloadOf with
  | .vectorIcon ps col none _ =>
    check (ps == chromeIconPaths "mission") "awaiting_user must fall back to Bot icon paths"
    check (col == orbDarkTheme.palette.textMuted) "awaiting_user Bot tone must be textMuted"
  | _ => check false "awaiting_user must render Bot vectorIcon"

  IO.println "WindowEffects pure U8 checks: ok"
