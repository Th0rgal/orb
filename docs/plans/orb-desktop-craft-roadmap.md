# Orb Desktop Craft & Hybrid LeanUI Roadmap (2026-11-24)

## Goal
Deliver a cohesive, instant, Cursor-grade desktop experience across both **pure `--leanui`** and **`--leanui-hybrid`** on Linux/Wayland (`m2air`) and macOS, while capturing every speed and quality lesson from our 2026-11-23/24 overnight and roadmap sprints.

## Architecture Principle
- **`--leanui-hybrid` is the pragmatic daily driver** where **Lean owns native chrome, state, and instant overlays** (`orb-locald`, `Orb.Kernel`, native LeanUI sidebar, and next: top bar + `Cmd+K`/`Ctrl+K` Search palette) while **WebKitGTK serves strictly as the GPU-accelerated rich-content viewport** (120fps conversation scrolling, Sankey Resources chart, Inference routing chains, Machines telemetry, DiffViewer/Mermaid).
- **Pure `--leanui`** remains our zero-WebKit native client and gets all immediate UX/typography/scrolling craft fixes (caret, overlay scrollbar, pill focus polish, wheel coalescing, HarfBuzz caching), plus a scoped investigation/track for a real `VK_KHR_wayland_surface` GPU swapchain.

## Typography Standard (aligned with `omarchnix.nix`)
| Surface | Font Stack | Notes |
| --- | --- | --- |
| **UI chrome, sidebar, buttons, agent discussions** | `'IBM Plex Sans', 'Inter', system-ui, sans-serif` | Regular `400` body/inputs, Medium `500` pills/controls/sidebar, SemiBold `600` headers. |
| **Code, paths, SHAs, diffs, terminal, code editor** | `'Lilex Nerd Font', 'Lilex', 'IBM Plex Mono', ui-monospace, monospace` | Tabular numerals, ligatures in code editor. |
| **Markdown file reader (Files Editor preview ONLY)** | `'IBM Plex Serif', 'EB Garamond', 'Michelangelus', Georgia, serif` | Editorial long-form typography **strictly for rendered `.md` files in the Files Editor preview mode** — **never** in agent discussion transcripts, and **never** when toggled into code/source mode (`Cmd+/` or `Ctrl+/`). |
| **Emoji** | `'Noto Color Emoji'` | System fallback. |

## Tracks (Execute in Parallel across Disjoint Surfaces)

### Track 1 — Pure `--leanui` Input, Scrollbar & Focus Craft (`lean/OrbDesktop/**`)
- **1a. Phase A PR (already opened from `fix/leanui-text-caret`):**
  - Native 1.5px vertical caret bar (`TextCaretSpec` + `emitTextCaret`) in focused composers & Search input.
  - `IBM Plex Sans` + `Lilex`/`IBM Plex Mono` font stack in `LeanUI/Runtime.lean`.
  - Rounded `6px` pill focus & padding on `Project` / `Choose machine` / `Folder`.
  - Sleek `6px` Cursor/GTK3-style right-edge overlay scrollbar thumb on `scrollClip` containers.
  - Per-frame `.scroll` event coalescing + 2048-entry / 512-byte HarfBuzz shaped-run cache.
- **1b. Draggable Scrollbar & Quiet Pointer Focus:**
  - Support pointer press/drag on the right-edge scrollbar thumb (and track jump) in `LeanUI/Runtime.lean` / `LeanUI/Scene.lean`.
  - Enforce `AGENTS.md` Cursor-style quiet focus: buttons/pills/dropdowns stay quiet (no persistent harsh focus border) on pointer click, showing `1px solid focusRing` only on keyboard `:focus-visible` navigation; text inputs show focus cleanly via border step + vertical caret.
  - Add unit + Wayland regression tests covering caret positioning, scrollbar geometry/drag, quiet click focus, and coalesced scroll.

### Track 2 — Web UI Typography & Editorial Markdown Files Mode (`orb/src/**`)
- Update `orb/src/styles.css` (`--sans`, `--mono`, plus a new `--serif-editorial` token: `'IBM Plex Serif', 'EB Garamond', 'Michelangelus', Georgia, serif`) so `--leanui-hybrid` and `--leanui` share identical typography.
- In the **Files Editor** (`orb/src/` Markdown preview renderer), apply `var(--serif-editorial)` with comfortable reading measure/line-height **only** when rendering a Markdown file in preview mode:
  - Must **NOT** affect agent conversation/transcript messages.
  - Must **NOT** affect code/source editing mode (toggling `Cmd+/` or `Ctrl+/` immediately switches back to `var(--mono)`).
- Add Playwright browser tests verifying computed `font-family` in all three states:
  1. Files Editor Markdown preview → editorial serif (`IBM Plex Serif` / `--serif-editorial`).
  2. Files Editor Markdown code mode (`Cmd+/`) → monospace (`--mono`).
  3. Mission discussion transcript → sans (`--sans`).

### Track 3 — Push More Native Lean Chrome into `--leanui-hybrid` (`linux_shell/**` + `lean/OrbDesktop/**`)
- Keep WebKitGTK strictly for the GPU-accelerated main document/visualization pane (Conversations, Resources Sankey, Inference routing chains, Machines telemetry, Settings).
- Audit and design/implement the next native LeanUI chrome promotions inside `--leanui-hybrid`:
  - Native LeanUI instant Search palette (`Cmd+K`/`Ctrl+K`) and/or unified top bar chrome over the existing `EmbeddedSidebar` IPC channel, keeping a single source of truth in `OrbDesktop` and zero duplicate parsers/state.
  - Ensure `gtk_leanui_model.c` stays `<= 220` LOC (CI C-shim limit!).

### Track 4 — Pure `--leanui` GPU Acceleration Scoping (`lean/OrbDesktop/c/lean_ui_vulkan.c` + `LeanUI/Vulkan.lean`)
- Write a crisp design spec (`docs/specs/leanui-vulkan-swapchain.md`) and prototype/benchmark replacing CPU `wl_shm` blitting with a real `VK_KHR_wayland_surface` GPU swapchain (or DMABUF/Vulkan texture upload) so pure `--leanui` hits 120fps on HiDPI Retina displays without regressing `--headless-golden` determinism.

## Operational & Delegation Guidelines (Sprint Learnings — Mandatory)

1. **Delegate on build-capable fleet hosts ONLY:**
   - Place all `orb` Lean/PR/build subagents on **`uruk`**, **`ashur`**, or **`dgx-spark`** (all three have `libssl-dev`, Lean toolchains, and `gh` / `development-identity` auth).
   - **Never** place Orb build/PR workers on `babylon`, `nippur`, or `lagash`.
2. **Parallelize across disjoint trees:**
   - Run Track 1 (`lean/OrbDesktop/**`), Track 2 (`orb/src/**`), and Track 3 (`linux_shell/**`) concurrently with separate subagents.
   - Pre-note any shared files (`Runtime.lean`, `State.lean`) so merges/rebases take <2 minutes.
3. **Two-tier review cadence (quality without slowdown):**
   - Run a **read-only Gemini 4 Carbon** (`pro` / `gemini-4-carbon`) first-pass architecture & security review on every non-trivial PR.
   - Once Carbon's findings are fixed with targeted commits and regression tests, use fast **Gemini 4 Neon** (`gemini-4-neon`) to re-verify those exact fixes instead of re-running a full Carbon pass.
4. **Fast CI rules (already live since `#2166`):**
   - `.github/workflows/nix.yml` now excludes `!lean/OrbDesktop/**`, so pure LeanUI PRs no longer burn 45–50 minutes on `orb-core` Nix builds.
   - Merge PRs only when all relevant checks (`CI/Test`, `Orb Desktop Shell`, `LeanUI parity`, `Orb browser`, `Format & Hygiene`, `Policy Lint`) are 100% green.
   - Keep every C shim `<= 220` LOC and zero `.rs` files.
5. **Final packaging & rollout:**
   - After all tracks merge to `Th0rgal/orb` `master`, bump `orb` in `Th0rgal/omarchnix` via PR, verify 4/4 CI green, and merge.
   - For aarch64 `orb-desktop` builds on `dgx-spark`, use detached native `nix build github:Th0rgal/omarchnix/<branch>#orb-desktop --no-link --print-out-paths --max-jobs 2 --cores 4` (never remote `nix copy` over flaky WireGuard).
   - Deploy `agent-core` only if backend (`lean/OrbCore/**`, `lean/OrbNode/**`, `lean/OrbBin/**`) changed.
6. **Hygiene & guardrails:**
   - Never touch Thomas's personal missions/projects, AirVPN sessions, or local checkouts.
   - Destroy any temporary managed VMs and archive temporary QA missions when done.
   - Maintain clear status on your mission board (`write_mission_board`) so Thomas can inspect progress anytime.
