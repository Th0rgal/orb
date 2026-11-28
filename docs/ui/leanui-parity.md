# LeanUI parity against the SolidJS desktop

How close the LeanUI desktop (`lean/OrbDesktop`, opt-in) is to the SolidJS
desktop (`orb/`), measured per screen. The SolidJS screenshots are the
reference; the LeanUI frames are the candidate.

On startup and during recovery, the native window distinguishes an absent or invalid saved connection, a rejected session (401), denied access (403), and temporary Core unavailability. Connection details and response bodies never appear in these messages. A change of failure reason updates the open window and a successful roster read restores navigation.

## Reproduce

```sh
# 1. Reference: capture the versioned SolidJS baseline, not the candidate UI.
# Run from the repository root. Use the pinned Chrome and fonts described below.
git fetch origin 6d1e7a27174b681f558285d673938880ddcc2706
git worktree add --detach .ci/leanui/reference-source 6d1e7a27174b681f558285d673938880ddcc2706
ROOT="$PWD"
cd .ci/leanui/reference-source/orb && bun install --frozen-lockfile
ORB_REFERENCE_OUT=/tmp/ref node node_modules/.bin/playwright test \
  -c playwright.leanui-reference.config.ts --reporter=line
(cd /tmp/ref && sha256sum -c --quiet "$ROOT/docs/ui/leanui-parity-reference.sha256")

# 2. Candidate: the same 36 frames from LeanUI.
cd "$ROOT" && scripts/build_orb_bins.sh --only orb-desktop-native --out-dir "$PWD/target/native"
target/native/orb-desktop-native --headless-golden-all /tmp/native --width 1470 --height 923
# LeanUI sources now live under lean/OrbDesktop/LeanUI, inside the package.
# Their edits invalidate turbo-lean's source cache; keep the same TURBO_LEAN_HOME.

# 3. Measure (needs numpy and Pillow) and rewrite the table below.
python3 scripts/leanui_parity.py --reference /tmp/ref --native /tmp/native \
  --out /tmp/parity-diff --require 36 --table docs/ui/leanui-parity.md
```

The reference capture uses the mock Core in `orb/tests/appPerfCore.ts`, a fixed
clock (2026-10-20T12:00:00Z), a 1470x923 viewport, reduced motion, and Chrome
with `--disable-gpu --disable-partial-raster`. It was taken with Chrome
151.0.7922.108 on Ubuntu 24.04 with Inter 4.0 (`fonts-inter`) and DejaVu Sans
Mono installed; `leanui-parity-reference.sha256` holds the hashes of that run.
Another Chrome version or font set will not reproduce them. The PNGs are not in
the repository.

## Results

### U3 final measurement (post-U2, U5a–U8)

Final U3 measurement over all 36 canonical variants (`9 screens × 2 themes × 2 scales`)
after U2 (`#1822`) and U5a–U8 (`#2246`, `#2255`, `#2270`, `#2226`, `#2271`) landed on
`origin/master` (`885932336`):

- **Overall:** **4.39%** mean raw mismatch (down from **4.91%** on pre-U3 `master`
  `885932336` and **5.01%** on verified baseline
  [43802006749](https://github.com/Th0rgal/orb/actions/runs/43802006749)), **2.17%**
  above tolerance (`tol = 8`, down from **2.58%**), mean local RGB SSIM **0.9690**
  (up from **0.9615**, min **0.9096**, max **0.9903**).
- **Determinism:** LeanUI **36/36** images pixel-identical across repeated captures;
  pinned SolidJS reference (`6d1e7a27174b681f558285d673938880ddcc2706`) verified
  **36/36** against `docs/ui/leanui-parity-reference.sha256` with zero hash changes.
- **Zero regressions:** every variant either stays under 1% (`01_control_empty_dark_2x`
  at **0.79%**) or improves / holds steady against `master` (`885932336`) while preserving
  intentional post-baseline craft improvements: `#2192` (`b44e5088b`, higher-contrast
  light-mode sidebar selection/border/tree-lines) and `#2201` (`f48fe700e`, squircle L4
  corner rounding).
- **U7 & U8 non-regression:** `--verify-repaint --bench 20` and `--bench-long 60` pass
  with `error_count = 0`; `scripts/bench_desktop.sh` passes the 60fps U7 gate
  (`frame_p50_ms = 2.06 ms <= 2.5 ms`, `frame_p99_ms = 5.97 ms <= 8.33 ms`,
  `long_transcript` `p50 = 1.51 ms`); Lavapipe GPU differential parity passes across all
  36 canonical screens and all 8 primitives.

The table and all 72 lossless crops (`<= 5 KB` each) below were regenerated directly by
the documented `scripts/leanui_parity.py` command.

### Earlier U3 reproduction, exact PR head (`3c2e6a1a1`)

Prior intermediate measurement (`3c2e6a1a1740dc91d076d0eda7708f4940a47ea5`, **4.68%**
mean raw mismatch, **2/36** under 1%) from pinned
[workflow 44202839412](https://github.com/Th0rgal/orb/actions/runs/44202839412) predated
the post-baseline `#2192` light-mode sidebar contrast refinement and `#2201` squircle
corners, which raised pre-U3 `master` (`885932336`) to **4.91%** before this final U3
parity pass reduced mean mismatch to **4.39%**.

The U2 prerequisite is covered by the same exact-head run: the native build
used `scripts/build_orb_bins.sh --only orb-desktop-native` with both fallback
variables unset, `scripts/orb_desktop_dev.sh --native` attached a Wayland
buffer under Weston/Xvfb, and the process remained alive. Reference hashes
verified 36/36; native goldens emitted 36/36; parity/token tests and native
window smoke passed.

Regenerated the table and declared crops from the native renderer at
`2fb35f99`, which includes the previous U3 follow-up (#1849). The native build
used pinned turbo-lean `aee2d179` with both fallback variables unset, on
Ubuntu 24.04 aarch64 with Inter 4.0. Its self-test and the seven parity/token
tests pass. Reference PNGs were recovered from verified run
[43869155079](https://github.com/Th0rgal/orb/actions/runs/43869155079), rather
than recaptured on a different Chromium architecture. This is a baseline:
**2/36** variants are under 1%, and the remaining groups are still open.

The current-master capture in
[44172956130](https://github.com/Th0rgal/orb/actions/runs/44172956130) fails
20 reference hashes. Final acceptance requires resolving that reproduction
failure as well as the renderer differences; the stored hashes are unchanged.

The difference is confined to 2–3 pixels in each affected model label or
chevron, following #1850's label clipping change. Both the workflow and local
commands now pin the reference source to the last verified capture revision,
`6d1e7a27174b681f558285d673938880ddcc2706`, while building the candidate from
the PR head. This preserves all 36 reference hashes and the comparison method.

### Reproduction check, 16 November 2026

The branch-triggered `.github/workflows/leanui-parity.yml` downloads Chrome for
Testing 151.0.7922.108 and uses a private fontconfig directory. A private browser
can also be selected locally with `ORB_REFERENCE_CHROME=/absolute/path/to/chrome`
in the reference command above. This changes browser selection only.

Reference verification passes **36/36** in pinned Ubuntu 24.04
[run 43802006749](https://github.com/Th0rgal/orb/actions/runs/43802006749).
Only the four split-diff reference hashes were refreshed: commit `e201d833`
changed the displayed mock filename to `lean/OrbDesktop/OrbDesktop/Main.lean`.
The intermittent transcript mismatch was the custom scrollbar's 900ms hide
timer, not font loading: the 2x dark difference occupied only x=2918..2933,
y=1648..1833 (2793 pixels). Capture now explicitly establishes the stored visible
2x transcript thumb and waits for the split-pane thumb to hide. No transcript
hash, threshold, mask, or comparison method changed; no known-flaky exceptions
are needed. The workflow fails on hash disagreement and preserves captures.
The verified baseline measurement is 2/36 variants under 1%, mean mismatch
5.01%; the exact-head table and crops below are the final U3 measurement.

U2's launch check passed on Ubuntu 24.04 in the same green workflow,
[run 43802006749](https://github.com/Th0rgal/orb/actions/runs/43802006749):
`scripts/orb_desktop_dev.sh --native`, with both fallback variables unset,
attached Wayland buffers and remained alive under Weston/Xvfb. Its
[artifact](https://github.com/Th0rgal/orb/actions/runs/43795949652/artifacts/14194448300)
contains `.ci/leanui/u2/native-window.png` and the protocol/build log.
The existing CI step `Native LeanUI build and warm-cache invalidation` invokes
`python3 scripts/test_native_desktop_cache.py`: it runs the same build script,
checks a deliberately invalid source edit, rebuilds, and runs `--self-test`;
it does not launch the normal window.

Host requirement: native linking needs libc++ compatible with the installed Lean runtime (uruk's libc++18 conflicts with its bundled Clang23 runtime).

<!-- parity:begin -->
Reference: SolidJS desktop. Candidate: LeanUI. 36 pairs, 0 errors, tolerance 8.

`mismatch` counts any RGB difference; `> tol` counts pixels with a channel difference above tolerance. Regions show mismatch % / local RGB SSIM.

| screen | theme | scale | mismatch % | > tol % | SSIM | sidebar | transcript | composer |
|---|---|---|---:|---:|---:|---:|---:|---:|
| 01_control_empty | dark | 1x | 1.14 | 1.03 | 0.9872 | 3.44 / 0.9694 | 0.82 / 0.9886 | 0.00 / 1.0000 |
| 01_control_empty | dark | 2x | 0.79 | 0.70 | 0.9896 | 2.53 / 0.9731 | 0.53 / 0.9915 | 0.00 / 1.0000 |
| 01_control_empty | light | 1x | 1.54 | 1.45 | 0.9860 | 6.09 / 0.9630 | 0.81 / 0.9882 | 0.00 / 1.0000 |
| 01_control_empty | light | 2x | 1.20 | 1.12 | 0.9888 | 5.28 / 0.9689 | 0.53 / 0.9913 | 0.00 / 1.0000 |
| 02_control_populated | dark | 1x | 1.65 | 1.22 | 0.9880 | 6.82 / 0.9743 | 0.82 / 0.9886 | 0.00 / 1.0000 |
| 02_control_populated | dark | 2x | 1.10 | 0.84 | 0.9885 | 4.60 / 0.9657 | 0.53 / 0.9915 | 0.00 / 1.0000 |
| 02_control_populated | light | 1x | 2.08 | 1.65 | 0.9867 | 9.70 / 0.9680 | 0.81 / 0.9882 | 0.00 / 1.0000 |
| 02_control_populated | light | 2x | 1.53 | 1.27 | 0.9877 | 7.45 / 0.9616 | 0.53 / 0.9913 | 0.00 / 1.0000 |
| 03_mission_transcript | dark | 1x | 5.52 | 3.18 | 0.9489 | 8.18 / 0.9636 | 3.73 / 0.9467 | 15.55 / 0.9347 |
| 03_mission_transcript | dark | 2x | 4.65 | 2.57 | 0.9530 | 5.66 / 0.9540 | 3.15 / 0.9530 | 15.07 / 0.9488 |
| 03_mission_transcript | light | 1x | 5.02 | 3.63 | 0.9476 | 11.01 / 0.9565 | 3.36 / 0.9467 | 8.77 / 0.9325 |
| 03_mission_transcript | light | 2x | 4.10 | 3.03 | 0.9523 | 8.45 / 0.9495 | 2.78 / 0.9531 | 7.66 / 0.9476 |
| 04_mission_split_diff | dark | 1x | 7.30 | 4.88 | 0.9125 | 8.18 / 0.9636 | 6.18 / 0.9012 | 13.01 / 0.9363 |
| 04_mission_split_diff | dark | 2x | 5.89 | 3.75 | 0.9273 | 5.66 / 0.9540 | 4.91 / 0.9207 | 12.53 / 0.9499 |
| 04_mission_split_diff | light | 1x | 7.76 | 5.56 | 0.9096 | 11.01 / 0.9565 | 6.94 / 0.8992 | 7.68 / 0.9352 |
| 04_mission_split_diff | light | 2x | 6.35 | 4.44 | 0.9255 | 8.45 / 0.9495 | 5.73 / 0.9194 | 6.67 / 0.9493 |
| 05_machines_fleet | dark | 1x | 2.57 | 2.07 | 0.9760 | 6.82 / 0.9744 | 2.10 / 0.9719 | 0.00 / 1.0000 |
| 05_machines_fleet | dark | 2x | 2.39 | 2.09 | 0.9670 | 4.59 / 0.9658 | 2.33 / 0.9617 | 0.00 / 1.0000 |
| 05_machines_fleet | light | 1x | 3.00 | 2.49 | 0.9748 | 9.72 / 0.9681 | 2.09 / 0.9717 | 0.00 / 1.0000 |
| 05_machines_fleet | light | 2x | 2.82 | 2.52 | 0.9665 | 7.45 / 0.9617 | 2.32 / 0.9618 | 0.00 / 1.0000 |
| 06_settings_general | dark | 1x | 3.14 | 2.78 | 0.9649 | 1.90 / 0.9915 | 3.31 / 0.9585 | 4.57 / 0.9639 |
| 06_settings_general | dark | 2x | 1.92 | 1.50 | 0.9765 | 1.32 / 0.9912 | 1.94 / 0.9735 | 3.16 / 0.9719 |
| 06_settings_general | light | 1x | 3.53 | 3.21 | 0.9628 | 4.61 / 0.9851 | 3.30 / 0.9570 | 4.55 / 0.9636 |
| 06_settings_general | light | 2x | 2.34 | 1.94 | 0.9754 | 4.10 / 0.9870 | 1.95 / 0.9728 | 3.16 / 0.9719 |
| 07_search_dialog | dark | 1x | 10.55 | 1.44 | 0.9718 | 37.81 / 0.9962 | 6.59 / 0.9616 | 0.03 / 1.0000 |
| 07_search_dialog | dark | 2x | 10.30 | 1.26 | 0.9750 | 36.01 / 0.9976 | 6.59 / 0.9659 | 0.07 / 1.0000 |
| 07_search_dialog | light | 1x | 14.50 | 1.84 | 0.9717 | 47.64 / 0.9957 | 9.89 / 0.9617 | 0.41 / 1.0000 |
| 07_search_dialog | light | 2x | 14.28 | 1.65 | 0.9750 | 46.13 / 0.9974 | 9.87 / 0.9659 | 0.43 / 1.0000 |
| 08_new_mission_dialog | dark | 1x | 1.63 | 1.21 | 0.9903 | 6.82 / 0.9743 | 0.79 / 0.9919 | 0.00 / 1.0000 |
| 08_new_mission_dialog | dark | 2x | 1.08 | 0.82 | 0.9894 | 4.60 / 0.9657 | 0.50 / 0.9928 | 0.00 / 1.0000 |
| 08_new_mission_dialog | light | 1x | 2.05 | 1.62 | 0.9892 | 9.70 / 0.9680 | 0.78 / 0.9916 | 0.00 / 1.0000 |
| 08_new_mission_dialog | light | 2x | 1.50 | 1.25 | 0.9887 | 7.45 / 0.9616 | 0.50 / 0.9927 | 0.00 / 1.0000 |
| 09_toast_notifications | dark | 1x | 5.72 | 2.05 | 0.9710 | 6.82 / 0.9743 | 4.21 / 0.9745 | 16.89 / 0.9408 |
| 09_toast_notifications | dark | 2x | 4.96 | 1.51 | 0.9745 | 4.60 / 0.9657 | 3.81 / 0.9797 | 15.60 / 0.9490 |
| 09_toast_notifications | light | 1x | 6.49 | 2.48 | 0.9696 | 9.70 / 0.9680 | 4.04 / 0.9740 | 21.69 / 0.9395 |
| 09_toast_notifications | light | 2x | 5.74 | 1.94 | 0.9736 | 7.45 / 0.9616 | 3.62 / 0.9794 | 20.67 / 0.9484 |

Mean over 36 measured pairs: mismatch 4.39 %, above tolerance 2.17 %, SSIM 0.9690 (min 0.9096, max 0.9903).

Determinism (each renderer compared with a second capture of itself):

- SolidJS reference: not measured
- LeanUI: 36/36 images pixel-identical
<!-- parity:end -->

## U3 final parity pass and status

LeanUI (`orb-desktop-native`) remains opt-in (`--leanui`, with default Linux desktop
cutover tracked separately under `U4`); macOS keeps its existing WebKit shell.

This post-U2/U5a–U8 measurement records `01_control_empty_dark_2x` at **0.79%** (`< 1%`)
and improves or holds steady on all 36 variants (`4.91% → 4.39%` mean mismatch,
`2.58% → 2.17%` `> tol`, `0.9615 → 0.9690` SSIM, zero regressions vs pre-U3 `master`
`885932336`), with lossless paired reference/candidate crops (`<= 5 KB` each) for all 36
variants. Remaining differences `>= 1%` reflect a mix of **intentional post-baseline
craft refinements** (`#2192` light-mode sidebar contrast and `#2201` squircle corners)
and **open renderer/rasterization differences** (FreeType grayscale glyph coverage vs
Skia, 3-pass box blur/shadow vs Skia Gaussian on `03`/`07`/`09`, and mono line-wrap
breaks on `04`) that remain honestly documented rather than masked or waived. This pass
fixes concrete parity defects across all affected screens while preserving `#2192`,
`#2201`, U6 interactive controls, U7 60fps partial-repaint/scroll reuse, and U8 window
effects:

- **Transcript (`03_mission_transcript`):** added the 14px top canvas fade gradient
  (with fast row-wise `FFI.blendRect` rasterization and `scrollBand` top-fade preservation
  so U7 `FFI.scrollRows` stays active), aligned the 370px turn vertical rhythm, added bold
  `module N`, inline `<code>` chips (`fn_N`, `commit()`), primary+accent `"see docs"` link
  split, code-block Copy icon, and composer under-row cloud icon + `○ 3%` context meter.
- **Split diff (`04_mission_split_diff`):** added the full-height split divider and 35px
  right pane header (`expand`, `split-pane`, `sidebar`, `search`, `Files | Changes`
  segmented toggle, `refresh`, `close`), toolbar select chevron, borderless `Refresh`,
  colored `+1`/`-1` counters, 299px files chip with `M` badge, right-aligned vertically
  centered gutter line numbers, and `rt.monoFont` (`12px` mono `pal.textPrimary`) diff
  shaping with exact column wrap width.
- **Machines (`05_machines_fleet`):** restored exact subtitle copy, left row icons
  (`laptop`, `server`, `nav:machines`), uppercase `"MANAGED (BOAT.DEV)"` group header with
  chevron, bordered `Managed` pills, exact card heights (`280px` remote card, `32px` gap,
  `63px` borderless key card with borderless `Copy`), and right-aligned counts/chevrons.
- **Settings (`06_settings_general`):** fixed header/tabs height (`95px`), `71px`
  `Account` underline, exact `Backend` heading offset, multi-line `\n` description
  splitting on `Connected services` (eliminating collision with `Refresh accounts`), exact
  card heights (`125`, `61`, `79`, `124`, `124`), muted disabled `Connect GitHub`,
  `<select>` double chevrons, and transparent commit code labels.
- **Search dialog (`07_search_dialog`):** matched `#1f1f1f` dark `Open ↵` surface,
  exact filter-tab widths/gaps, and right-aligned filter dropdowns, timestamps, and match
  count.
- **Toast notifications (`09_toast_notifications`):** matched exact toast widths/heights
  (`568×54`, `352×53`, `608×58`), light border `#d8d8d8`, warning `alert-circle` icon on
  Toast 3, and vertically centered close `×`.
- **Topbar chrome (`01`–`09`):** lifted topbar title optical baseline (`lineHeightSub :=
  pxToSub 17`) to match sidebar rows.

The first and repeated SolidJS captures use Chrome 151.0.7922.108, Inter 4.0,
1470x923 at 1x/2x, and the fixed clock in the capture fixture. The first capture
matches **all 36** hashes in `leanui-parity-reference.sha256`. Do not update
reference hashes to make a candidate pass. The JSON report is emitted by the
comparison CLI; it preserves errors and per-region measurements.

The SSIM implementation is mean **local RGB SSIM**, uniform 7x7 window,
population covariance, 8-bit constants C1=6.5025 and C2=58.5225, valid windows.
Regions are the full 220px sidebar, main transcript below the 35px title and
above the 819px dock boundary, and main composer from y=819 to the bottom.
For screens without a composer the final region is still that geometric band.

## U3 per-variant evidence

Each row gives the pre-U3 `origin/master` (`885932336`, post-U2/U5a–U8) full-frame
mismatch, the exact-head mismatch after this pass, delta in percentage points, and the
paired lossless crop. Values are full-frame mismatch; crops show the corresponding
renderer region and are not masked scores.

| variant | pre-U3 master (`885932336`) → exact head | improvement | crops |
|---|---:|---:|---|
| `01_control_empty_dark_1x` | 1.14% → **1.14%** | +0.00 pp | [ref](crops/01_control_empty_dark_1x_ref_crop.png) / [LeanUI](crops/01_control_empty_dark_1x_leanui_crop.png) |
| `01_control_empty_dark_2x` | 0.80% → **0.79%** (`< 1%`) | +0.01 pp | [ref](crops/01_control_empty_dark_2x_ref_crop.png) / [LeanUI](crops/01_control_empty_dark_2x_leanui_crop.png) |
| `01_control_empty_light_1x` | 1.54% → **1.54%** | +0.00 pp | [ref](crops/01_control_empty_light_1x_ref_crop.png) / [LeanUI](crops/01_control_empty_light_1x_leanui_crop.png) |
| `01_control_empty_light_2x` | 1.21% → **1.20%** | +0.01 pp | [ref](crops/01_control_empty_light_2x_ref_crop.png) / [LeanUI](crops/01_control_empty_light_2x_leanui_crop.png) |
| `02_control_populated_dark_1x` | 1.65% → **1.65%** | +0.00 pp | [ref](crops/02_control_populated_dark_1x_ref_crop.png) / [LeanUI](crops/02_control_populated_dark_1x_leanui_crop.png) |
| `02_control_populated_dark_2x` | 1.11% → **1.10%** | +0.01 pp | [ref](crops/02_control_populated_dark_2x_ref_crop.png) / [LeanUI](crops/02_control_populated_dark_2x_leanui_crop.png) |
| `02_control_populated_light_1x` | 2.08% → **2.08%** | +0.00 pp | [ref](crops/02_control_populated_light_1x_ref_crop.png) / [LeanUI](crops/02_control_populated_light_1x_leanui_crop.png) |
| `02_control_populated_light_2x` | 1.53% → **1.53%** | +0.00 pp | [ref](crops/02_control_populated_light_2x_ref_crop.png) / [LeanUI](crops/02_control_populated_light_2x_leanui_crop.png) |
| `03_mission_transcript_dark_1x` | 6.88% → **5.52%** | +1.36 pp | [ref](crops/03_mission_transcript_dark_1x_ref_crop.png) / [LeanUI](crops/03_mission_transcript_dark_1x_leanui_crop.png) |
| `03_mission_transcript_dark_2x` | 5.94% → **4.65%** | +1.29 pp | [ref](crops/03_mission_transcript_dark_2x_ref_crop.png) / [LeanUI](crops/03_mission_transcript_dark_2x_leanui_crop.png) |
| `03_mission_transcript_light_1x` | 6.58% → **5.02%** | +1.56 pp | [ref](crops/03_mission_transcript_light_1x_ref_crop.png) / [LeanUI](crops/03_mission_transcript_light_1x_leanui_crop.png) |
| `03_mission_transcript_light_2x` | 5.53% → **4.10%** | +1.43 pp | [ref](crops/03_mission_transcript_light_2x_ref_crop.png) / [LeanUI](crops/03_mission_transcript_light_2x_leanui_crop.png) |
| `04_mission_split_diff_dark_1x` | 8.67% → **7.30%** | +1.37 pp | [ref](crops/04_mission_split_diff_dark_1x_ref_crop.png) / [LeanUI](crops/04_mission_split_diff_dark_1x_leanui_crop.png) |
| `04_mission_split_diff_dark_2x` | 7.20% → **5.89%** | +1.31 pp | [ref](crops/04_mission_split_diff_dark_2x_ref_crop.png) / [LeanUI](crops/04_mission_split_diff_dark_2x_leanui_crop.png) |
| `04_mission_split_diff_light_1x` | 9.28% → **7.76%** | +1.52 pp | [ref](crops/04_mission_split_diff_light_1x_ref_crop.png) / [LeanUI](crops/04_mission_split_diff_light_1x_leanui_crop.png) |
| `04_mission_split_diff_light_2x` | 7.77% → **6.35%** | +1.42 pp | [ref](crops/04_mission_split_diff_light_2x_ref_crop.png) / [LeanUI](crops/04_mission_split_diff_light_2x_leanui_crop.png) |
| `05_machines_fleet_dark_1x` | 3.63% → **2.57%** | +1.06 pp | [ref](crops/05_machines_fleet_dark_1x_ref_crop.png) / [LeanUI](crops/05_machines_fleet_dark_1x_leanui_crop.png) |
| `05_machines_fleet_dark_2x` | 2.74% → **2.39%** | +0.35 pp | [ref](crops/05_machines_fleet_dark_2x_ref_crop.png) / [LeanUI](crops/05_machines_fleet_dark_2x_leanui_crop.png) |
| `05_machines_fleet_light_1x` | 4.05% → **3.00%** | +1.05 pp | [ref](crops/05_machines_fleet_light_1x_ref_crop.png) / [LeanUI](crops/05_machines_fleet_light_1x_leanui_crop.png) |
| `05_machines_fleet_light_2x` | 3.17% → **2.82%** | +0.35 pp | [ref](crops/05_machines_fleet_light_2x_ref_crop.png) / [LeanUI](crops/05_machines_fleet_light_2x_leanui_crop.png) |
| `06_settings_general_dark_1x` | 3.85% → **3.14%** | +0.71 pp | [ref](crops/06_settings_general_dark_1x_ref_crop.png) / [LeanUI](crops/06_settings_general_dark_1x_leanui_crop.png) |
| `06_settings_general_dark_2x` | 2.71% → **1.92%** | +0.79 pp | [ref](crops/06_settings_general_dark_2x_ref_crop.png) / [LeanUI](crops/06_settings_general_dark_2x_leanui_crop.png) |
| `06_settings_general_light_1x` | 4.24% → **3.53%** | +0.71 pp | [ref](crops/06_settings_general_light_1x_ref_crop.png) / [LeanUI](crops/06_settings_general_light_1x_leanui_crop.png) |
| `06_settings_general_light_2x` | 3.14% → **2.34%** | +0.80 pp | [ref](crops/06_settings_general_light_2x_ref_crop.png) / [LeanUI](crops/06_settings_general_light_2x_leanui_crop.png) |
| `07_search_dialog_dark_1x` | 10.69% → **10.55%** | +0.14 pp | [ref](crops/07_search_dialog_dark_1x_ref_crop.png) / [LeanUI](crops/07_search_dialog_dark_1x_leanui_crop.png) |
| `07_search_dialog_dark_2x` | 10.43% → **10.30%** | +0.13 pp | [ref](crops/07_search_dialog_dark_2x_ref_crop.png) / [LeanUI](crops/07_search_dialog_dark_2x_leanui_crop.png) |
| `07_search_dialog_light_1x` | 14.54% → **14.50%** | +0.04 pp | [ref](crops/07_search_dialog_light_1x_ref_crop.png) / [LeanUI](crops/07_search_dialog_light_1x_leanui_crop.png) |
| `07_search_dialog_light_2x` | 14.31% → **14.28%** | +0.03 pp | [ref](crops/07_search_dialog_light_2x_ref_crop.png) / [LeanUI](crops/07_search_dialog_light_2x_leanui_crop.png) |
| `08_new_mission_dialog_dark_1x` | 1.63% → **1.63%** | +0.00 pp | [ref](crops/08_new_mission_dialog_dark_1x_ref_crop.png) / [LeanUI](crops/08_new_mission_dialog_dark_1x_leanui_crop.png) |
| `08_new_mission_dialog_dark_2x` | 1.08% → **1.08%** | +0.00 pp | [ref](crops/08_new_mission_dialog_dark_2x_ref_crop.png) / [LeanUI](crops/08_new_mission_dialog_dark_2x_leanui_crop.png) |
| `08_new_mission_dialog_light_1x` | 2.06% → **2.05%** | +0.01 pp | [ref](crops/08_new_mission_dialog_light_1x_ref_crop.png) / [LeanUI](crops/08_new_mission_dialog_light_1x_leanui_crop.png) |
| `08_new_mission_dialog_light_2x` | 1.50% → **1.50%** | +0.00 pp | [ref](crops/08_new_mission_dialog_light_2x_ref_crop.png) / [LeanUI](crops/08_new_mission_dialog_light_2x_leanui_crop.png) |
| `09_toast_notifications_dark_1x` | 6.01% → **5.72%** | +0.29 pp | [ref](crops/09_toast_notifications_dark_1x_ref_crop.png) / [LeanUI](crops/09_toast_notifications_dark_1x_leanui_crop.png) |
| `09_toast_notifications_dark_2x` | 5.24% → **4.96%** | +0.28 pp | [ref](crops/09_toast_notifications_dark_2x_ref_crop.png) / [LeanUI](crops/09_toast_notifications_dark_2x_leanui_crop.png) |
| `09_toast_notifications_light_1x` | 6.72% → **6.49%** | +0.23 pp | [ref](crops/09_toast_notifications_light_1x_ref_crop.png) / [LeanUI](crops/09_toast_notifications_light_1x_leanui_crop.png) |
| `09_toast_notifications_light_2x` | 5.99% → **5.74%** | +0.25 pp | [ref](crops/09_toast_notifications_light_2x_ref_crop.png) / [LeanUI](crops/09_toast_notifications_light_2x_leanui_crop.png) |

## Remaining differences and crops

Every canonical variant has a lossless paired crop below, including variants
under 1%. Coordinates are logical pixels; the tool multiplies by the filename's
scale. Each PNG is at most 5 KB. These are **SolidJS before / LeanUI after**
crops, not a claim that every changed pixel is an improvement. Full-frame
metrics above include every pixel: no masks, excluded icons, or crop-only scores.

| Screen | Remaining reason; disposition |
|---|---|
| 01_control_empty | `01_control_empty_dark_2x` is **0.79%** (`< 1%`); remaining dark diff (`1.14%` 1x) is FreeType grayscale glyph coverage vs Skia and `#2201` squircle corners; light-mode sidebar delta (`1.20%` 2x / `1.54%` 1x) is intentional `#2192` light-mode sidebar contrast (`#dcdcd7` selection, `#c8c7c0` border, `#c6c5be` tree rails). |
| 02_control_populated | Populated sidebar tree connectors, status rings, Inbox count, and ellipsis truncation (`1.10%` dark 2x / `1.65%` dark 1x, SSIM `0.9885`); residual diff is FreeType vs Skia text/stroke rasterization down the 30-row sidebar, `#2201` squircle corners, and intentional `#2192` light-mode contrast. |
| 03_mission_transcript | Reduced by **1.29–1.56 pp** (`5.52%` dark 1x / `4.65%` dark 2x / `4.10%` light 2x, SSIM `0.9530`) via 14px top fade mask, exact 370px turn pitch, bold `module N`, inline `<code>` chips, `"see docs"` link split, code-block Copy icon, and composer under-row cloud + `○ 3%` meter; residual diff is 1-LSB box-shadow quantization around the dock (`d=1..2`), FreeType vs Skia glyph coverage, and `#2192`/`#2201`. |
| 04_mission_split_diff | Reduced by **1.31–1.52 pp** (`7.30%` dark 1x / `5.89%` dark 2x, SSIM `0.9273`) via full-height split divider, 35px right pane header + `Files \| Changes` toggle, toolbar select chevron & colored `+1 -1`, 299px files chip with `M` badge, centered gutter line numbers, and `rt.monoFont` diff shaping; residual diff is line-wrap breaks, FreeType vs Skia mono glyph coverage, and `#2192`/`#2201`. |
| 05_machines_fleet | Reduced by **0.35–1.06 pp** (`2.57%` dark 1x / `2.39%` dark 2x, SSIM `0.9760`) via exact subtitle copy, row left icons, `"MANAGED (BOAT.DEV)"` header + chevron, `Managed` pills, exact card heights, and borderless key card/`Copy`; residual diff is FreeType vs Skia text/icon rasterization and `#2192`/`#2201`. |
| 06_settings_general | Reduced by **0.71–0.80 pp** (`3.14%` dark 1x / `1.92%` dark 2x, SSIM `0.9765`) via exact header/tab/card heights, multi-line `\n` description wrapping on `Connected services`, muted `Connect GitHub`, `<select>` double chevrons, and transparent commit codes; residual diff is FreeType vs Skia glyph coverage and `#2192`/`#2201`. |
| 07_search_dialog | Reduced to `10.55%` / `10.30%` dark (`> tol` `1.44%` / `1.26%`, SSIM `0.9750`) and `14.50%` / `14.28%` light (`> tol` `1.84%` / `1.65%`, SSIM `0.9750`) via `#1f1f1f` `Open ↵` fill and exact tab/filter/timestamp/footer alignment; `~8–11%` of raw mismatch is `d=1..2` from 3-pass box blur vs Skia Gaussian backdrop filtering (`0.00% > tol` in dark sidebar). |
| 08_new_mission_dialog | Centered New Agent composer with typed prompt, focus border, and active send button (`1.08%` dark 2x / `1.63%` dark 1x, SSIM `0.9903`); residual diff is FreeType vs Skia glyph coverage, `#2201` squircles, and intentional `#2192` light-mode sidebar contrast. |
| 09_toast_notifications | Reduced by **0.23–0.29 pp** (`5.72%` dark 1x / `4.96%` dark 2x, `> tol` `1.51%`, SSIM `0.9745`) via exact toast dimensions (`568×54`, `352×53`, `608×58`), `#d8d8d8` light border, Toast 3 warning `alert-circle` icon, and centered close `×`; residual `d=1..2` (`~3.35%`) is 3-pass box shadow vs Skia shadow halo. |

### 01_control_empty

<!-- parity:crop 01_control_empty_dark_1x 14 43 50 16 -->
dark, 1x: [SolidJS](crops/01_control_empty_dark_1x_ref_crop.png) → [LeanUI](crops/01_control_empty_dark_1x_leanui_crop.png).

<!-- parity:crop 01_control_empty_dark_2x 14 43 50 16 -->
dark, 2x: [SolidJS](crops/01_control_empty_dark_2x_ref_crop.png) → [LeanUI](crops/01_control_empty_dark_2x_leanui_crop.png).

<!-- parity:crop 01_control_empty_light_1x 14 43 50 16 -->
light, 1x: [SolidJS](crops/01_control_empty_light_1x_ref_crop.png) → [LeanUI](crops/01_control_empty_light_1x_leanui_crop.png).

<!-- parity:crop 01_control_empty_light_2x 14 43 50 16 -->
light, 2x: [SolidJS](crops/01_control_empty_light_2x_ref_crop.png) → [LeanUI](crops/01_control_empty_light_2x_leanui_crop.png).

### 02_control_populated

<!-- parity:crop 02_control_populated_dark_1x 14 265 50 16 -->
dark, 1x: [SolidJS](crops/02_control_populated_dark_1x_ref_crop.png) → [LeanUI](crops/02_control_populated_dark_1x_leanui_crop.png).

<!-- parity:crop 02_control_populated_dark_2x 14 265 50 16 -->
dark, 2x: [SolidJS](crops/02_control_populated_dark_2x_ref_crop.png) → [LeanUI](crops/02_control_populated_dark_2x_leanui_crop.png).

<!-- parity:crop 02_control_populated_light_1x 14 265 50 16 -->
light, 1x: [SolidJS](crops/02_control_populated_light_1x_ref_crop.png) → [LeanUI](crops/02_control_populated_light_1x_leanui_crop.png).

<!-- parity:crop 02_control_populated_light_2x 14 265 50 16 -->
light, 2x: [SolidJS](crops/02_control_populated_light_2x_ref_crop.png) → [LeanUI](crops/02_control_populated_light_2x_leanui_crop.png).

### 03_mission_transcript

<!-- parity:crop 03_mission_transcript_dark_1x 481 268 50 16 -->
dark, 1x: [SolidJS](crops/03_mission_transcript_dark_1x_ref_crop.png) → [LeanUI](crops/03_mission_transcript_dark_1x_leanui_crop.png).

<!-- parity:crop 03_mission_transcript_dark_2x 481 268 50 16 -->
dark, 2x: [SolidJS](crops/03_mission_transcript_dark_2x_ref_crop.png) → [LeanUI](crops/03_mission_transcript_dark_2x_leanui_crop.png).

<!-- parity:crop 03_mission_transcript_light_1x 481 268 50 16 -->
light, 1x: [SolidJS](crops/03_mission_transcript_light_1x_ref_crop.png) → [LeanUI](crops/03_mission_transcript_light_1x_leanui_crop.png).

<!-- parity:crop 03_mission_transcript_light_2x 481 268 50 16 -->
light, 2x: [SolidJS](crops/03_mission_transcript_light_2x_ref_crop.png) → [LeanUI](crops/03_mission_transcript_light_2x_leanui_crop.png).

### 04_mission_split_diff

<!-- parity:crop 04_mission_split_diff_dark_1x 930 200 50 16 -->
dark, 1x: [SolidJS](crops/04_mission_split_diff_dark_1x_ref_crop.png) → [LeanUI](crops/04_mission_split_diff_dark_1x_leanui_crop.png).

<!-- parity:crop 04_mission_split_diff_dark_2x 930 200 50 16 -->
dark, 2x: [SolidJS](crops/04_mission_split_diff_dark_2x_ref_crop.png) → [LeanUI](crops/04_mission_split_diff_dark_2x_leanui_crop.png).

<!-- parity:crop 04_mission_split_diff_light_1x 930 200 50 16 -->
light, 1x: [SolidJS](crops/04_mission_split_diff_light_1x_ref_crop.png) → [LeanUI](crops/04_mission_split_diff_light_1x_leanui_crop.png).

<!-- parity:crop 04_mission_split_diff_light_2x 930 200 50 16 -->
light, 2x: [SolidJS](crops/04_mission_split_diff_light_2x_ref_crop.png) → [LeanUI](crops/04_mission_split_diff_light_2x_leanui_crop.png).

### 05_machines_fleet

The Local and Remote sections appear as soon as Machines opens. A pending or unavailable managed-provider catalog leaves existing machines visible. Configured providers without a machine get their group when the catalog arrives.

<!-- parity:crop 05_machines_fleet_dark_1x 540 180 50 16 -->
dark, 1x: [SolidJS](crops/05_machines_fleet_dark_1x_ref_crop.png) → [LeanUI](crops/05_machines_fleet_dark_1x_leanui_crop.png).

<!-- parity:crop 05_machines_fleet_dark_2x 540 180 50 16 -->
dark, 2x: [SolidJS](crops/05_machines_fleet_dark_2x_ref_crop.png) → [LeanUI](crops/05_machines_fleet_dark_2x_leanui_crop.png).

<!-- parity:crop 05_machines_fleet_light_1x 540 180 50 16 -->
light, 1x: [SolidJS](crops/05_machines_fleet_light_1x_ref_crop.png) → [LeanUI](crops/05_machines_fleet_light_1x_leanui_crop.png).

<!-- parity:crop 05_machines_fleet_light_2x 540 180 50 16 -->
light, 2x: [SolidJS](crops/05_machines_fleet_light_2x_ref_crop.png) → [LeanUI](crops/05_machines_fleet_light_2x_leanui_crop.png).

### 06_settings_general

These crops show the cloud-account title and the restored second description
line. Other settings differences remain open; these are correction evidence,
not deliberate-improvement exemptions.

<!-- parity:crop 06_settings_general_dark_1x 553 514 60 28 -->
dark, 1x: [SolidJS](crops/06_settings_general_dark_1x_ref_crop.png) → [LeanUI](crops/06_settings_general_dark_1x_leanui_crop.png).

<!-- parity:crop 06_settings_general_dark_2x 553 514 60 28 -->
dark, 2x: [SolidJS](crops/06_settings_general_dark_2x_ref_crop.png) → [LeanUI](crops/06_settings_general_dark_2x_leanui_crop.png).

<!-- parity:crop 06_settings_general_light_1x 553 514 60 28 -->
light, 1x: [SolidJS](crops/06_settings_general_light_1x_ref_crop.png) → [LeanUI](crops/06_settings_general_light_1x_leanui_crop.png).

<!-- parity:crop 06_settings_general_light_2x 553 514 60 28 -->
light, 2x: [SolidJS](crops/06_settings_general_light_2x_ref_crop.png) → [LeanUI](crops/06_settings_general_light_2x_leanui_crop.png).

### 07_search_dialog

<!-- parity:crop 07_search_dialog_dark_1x 306 90 50 16 -->
dark, 1x: [SolidJS](crops/07_search_dialog_dark_1x_ref_crop.png) → [LeanUI](crops/07_search_dialog_dark_1x_leanui_crop.png).

<!-- parity:crop 07_search_dialog_dark_2x 306 90 50 16 -->
dark, 2x: [SolidJS](crops/07_search_dialog_dark_2x_ref_crop.png) → [LeanUI](crops/07_search_dialog_dark_2x_leanui_crop.png).

<!-- parity:crop 07_search_dialog_light_1x 306 90 50 16 -->
light, 1x: [SolidJS](crops/07_search_dialog_light_1x_ref_crop.png) → [LeanUI](crops/07_search_dialog_light_1x_leanui_crop.png).

<!-- parity:crop 07_search_dialog_light_2x 306 90 50 16 -->
light, 2x: [SolidJS](crops/07_search_dialog_light_2x_ref_crop.png) → [LeanUI](crops/07_search_dialog_light_2x_leanui_crop.png).

### 08_new_mission_dialog

<!-- parity:crop 08_new_mission_dialog_dark_1x 14 265 50 16 -->
dark, 1x: [SolidJS](crops/08_new_mission_dialog_dark_1x_ref_crop.png) → [LeanUI](crops/08_new_mission_dialog_dark_1x_leanui_crop.png).

<!-- parity:crop 08_new_mission_dialog_dark_2x 14 265 50 16 -->
dark, 2x: [SolidJS](crops/08_new_mission_dialog_dark_2x_ref_crop.png) → [LeanUI](crops/08_new_mission_dialog_dark_2x_leanui_crop.png).

<!-- parity:crop 08_new_mission_dialog_light_1x 14 265 50 16 -->
light, 1x: [SolidJS](crops/08_new_mission_dialog_light_1x_ref_crop.png) → [LeanUI](crops/08_new_mission_dialog_light_1x_leanui_crop.png).

<!-- parity:crop 08_new_mission_dialog_light_2x 14 265 50 16 -->
light, 2x: [SolidJS](crops/08_new_mission_dialog_light_2x_ref_crop.png) → [LeanUI](crops/08_new_mission_dialog_light_2x_leanui_crop.png).

### 09_toast_notifications

<!-- parity:crop 09_toast_notifications_dark_1x 576 732 50 16 -->
dark, 1x: [SolidJS](crops/09_toast_notifications_dark_1x_ref_crop.png) → [LeanUI](crops/09_toast_notifications_dark_1x_leanui_crop.png).

<!-- parity:crop 09_toast_notifications_dark_2x 576 732 50 16 -->
dark, 2x: [SolidJS](crops/09_toast_notifications_dark_2x_ref_crop.png) → [LeanUI](crops/09_toast_notifications_dark_2x_leanui_crop.png).

<!-- parity:crop 09_toast_notifications_light_1x 576 732 50 16 -->
light, 1x: [SolidJS](crops/09_toast_notifications_light_1x_ref_crop.png) → [LeanUI](crops/09_toast_notifications_light_1x_leanui_crop.png).

<!-- parity:crop 09_toast_notifications_light_2x 576 732 50 16 -->
light, 2x: [SolidJS](crops/09_toast_notifications_light_2x_ref_crop.png) → [LeanUI](crops/09_toast_notifications_light_2x_leanui_crop.png).

## Helper CLI and validation

`leanui_parity.py --reference DIR --native DIR [--out DIR] [--json FILE]
[--table FILE] [--tolerance 8] [--require N] [--reference-repeat DIR]
[--native-repeat DIR] [--crops-dir DIR]` uses numpy and Pillow. `--out`
writes absolute RGB difference PNGs. `--json` includes pairs, region metrics,
errors and optional repeat comparisons. Missing pairs, invalid names, unreadable
files, different dimensions, empty sets, wrong required counts, and differing
repeat captures return nonzero. A high parity mismatch is reported, not hidden
behind a successful process status: the visual acceptance gate is separate.

`--table` replaces exactly one `parity:begin` / `parity:end` HTML comment
block, preserving all other prose. Crop declarations use
`<!-- parity:crop canonical_stem x y width height -->`; `--crops-dir` requires
`--table`, writes `{canonical_stem}_ref_crop.png` and
`{canonical_stem}_leanui_crop.png`, and never resizes or quantizes pixels.

Run:

```sh
python3 -m unittest -v scripts/test_leanui_tokens.py scripts/test_leanui_parity.py
scripts/leanui_window_smoke.sh target/native/orb-desktop-native
```

The smoke requires Weston with its headless backend and kiosk shell, Python 3,
`timeout`, and `rg`. It maps a real Wayland window, checks buffer attachment and
one second of liveness, then injects `xdg_toplevel.close` through a protocol
relay that preserves shared-memory file descriptors. The normal app must exit
zero. Single/all goldens and `--bench` must exit zero without a compositor.
`WESTON` selects the compositor executable; packaged-module relocation may use
Weston's `WESTON_MODULE_MAP` and `LD_LIBRARY_PATH` in restricted environments.

Build validation includes `LeanUISpec`: recovered geometry/damage guards plus
`OrbDesktop.Spec.RasterParity` for whitespace paint, blur impulse response,
constant surfaces, empty images, and zero sigma. The native package owns both
`LeanUI/` and `OrbDesktop/` module trees and its C shims in `c/`, using the
default package-local source directory. Use the pinned turbo-lean revision in
`lean/turbo-lean-revision`. No raw-Lake fallback or cache reset is needed after
LeanUI edits.

### Opening the window with a slow Core

The native window maps immediately with its title bar and a composer placeholder while the first roster request runs. A successful response populates the same window. A failed first read shows the connection hint and starts background recovery. A replaced session must discard the previous identity’s roster before showing the new one.

### Changes from a second client

An open sidebar must pick up missions and projects created in another client, including a child whose parent was already visible. A new roster page updates titles, placement and archive status. Rows retain their widget identity across a reorder. A mission displaced from a limited page stays visible while its individual presence check remains authorized. Session revocation clears the previous account’s data.

When a selected mission advances from pending to active, the composer shows Stop on the same update as the active sidebar row. A roster snapshot and bubble that both report active must give the same button as a bubble arriving before the roster. Preserve the draft across that transition.

Inference loads the signed-in user's provider inventory when opened. Each account shows its personal routing preference and any global disablement. Clicking a row changes only the signed-in user's preference. The confirmed response must name that account and return the requested preference. Reopening Inference reads the setting from Core, and a change invalidates any in-flight model catalog from before the update.

The live sidebar keeps Account Settings in its footer during startup, recovery and normal use. Ctrl+, or Super+, opens it even with the sidebar hidden. Opening Settings reads the saved endpoint and the identity returned by Core. A pending roster, an expired session and a forbidden request have separate states. Changing the saved credential retires the previous account’s identity and roster before displaying the next account.

The keyboard-focusable account action opens the desktop Backend form in a private WebKit window. Passwords go through its masked field and existing HTTP login. Locald serializes credential changes against the on-disk connection. A disconnect supplies the endpoint and session token that the form displayed. If another client switches accounts first, the newer credential survives. The form reports a storage failure and keeps its previous state when the credential store is read-only.

The Settings button beside a provider opens the connection settings for that account. Core supplies the selectable countries, the saved route, exit verification and whether the user may change it. An Antigravity account also shows whether alternative routers may use it. Opening the page only reads settings. A change sends one PUT and reads both settings again, including after a timeout or refusal. A failure to load one section leaves the other usable. Escape returns keyboard focus and scroll position to the account in the inventory.
New Agent keeps the project, machine and working directory above its multiline draft. Choosing a project preserves the draft. Choosing a different machine clears the previous machine’s directory. The folder menu lists directories through the selected machine’s filesystem API and also accepts an absolute path. Creating the mission sends that path in `working_directory`, the selected project in `project` and the original multiline prompt in `prompt`.

Opening the New Agent machine picker reads the connected user's current remote-node inventory. A member with zero personal VMs can choose an available shared worker such as uruk. Core remains available to callers whose machine inventory includes Core. The picker checks the typed-launch capability, node availability, administrative scope and harness quarantine. Closing or reopening the picker retires its pending read.

Picker labels stay inside the clickable row. The model picker accommodates provider-qualified names and elides overflow at narrow viewport widths. Clicking the Astra suffix selects Astra, including when Sol was previously selected.

At narrow composer widths the native client exposes placement, harness, model and effort through the Mission settings menu. A draft offers machine selection. An existing mission keeps its placement. The empty prompt truncates before the send button.

A global sidebar page may contain a worker whose controller last ran before the
page boundary. Core returns up to eight generations of authorized parents when
the native sidebar requests ancestor context. The limit and offset select the
initial page. An inaccessible parent ends that branch, including when an older
ancestor is independently visible. Ordinary paginated callers retain their
existing page size. Multiple workers referencing a controller produce one row.

Opening a project shows the cached activity rows immediately, then loads the same project history and older open conversations as the WebKit sidebar. A completed project read determines which rows belong in that project's tree. A mission kept in the global activity cache can still receive updates after it leaves the tree. An older controller outside the history page remains visible when an eligible child needs it for context.

Replay this sequence with two projects. Fill the global page with recent activity from the first project. Expand the second, whose controller and child are older than the global page. Both appear when the project read completes. An older completed sibling outside the project history stays hidden. Collapse and reopen while a read is pending, refresh the global roster, then replay a transient failure. The expanded tree keeps the last successful project membership until a newer project read or an explicit move, archive or access revocation changes it. Switching account discards the previous account's membership. A project-only update also preserves the current Inbox entries and availability until the next full roster response.

On expansion the first complete project membership and its mission cards may arrive before the global mission, archive and machine lists. This sample owns only the named memberships and supplied cards. The following full sample reuses those same project reads. A short all-status project page exhausts the open list as well. A full page still requires the bounded open scan and ancestor resolution.

The Misc project (Core slug `default`) contains unassigned mission roots whenever the project is present. Collapsing Misc hides those roots and their descendants. The sidebar connects each expanded folder or controller to its children at the icon center. A continued sibling keeps its vertical rail through nested rows. The last visible sibling ends in a rounded elbow at its own icon, irrespective of selection.

A committed Wayland IME batch can replace text on both sides of the caret.
One Undo restores the original text and caret. Redo reapplies the complete
replacement. Preedit-only updates preserve the edit history.

Opening the harness picker requests the native Antigravity catalog for the selected destination and current login. Other harnesses remain selectable while discovery runs. An empty successful catalog removes that destination's native choices. A failed refresh offers a retry on reopening, and a different destination never inherits those model rows.

The installed GTK sidebar treats the Core `archived` tag independently of execution status. LeanUI excludes tagged and acknowledged workers from project badges and places them under Archived. An archived ancestor needed to reach a visible worker appears once in its project. Restoring a tag-only archive clears the tag and preserves execution status.
