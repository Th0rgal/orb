# LeanUI parity against the SolidJS desktop

How close the LeanUI desktop (`lean/OrbDesktop`, opt-in) is to the SolidJS
desktop (`orb/`), measured per screen. The SolidJS screenshots are the
reference; the LeanUI frames are the candidate.

## Reproduce

```sh
# 1. Reference: 36 screenshots of the SolidJS desktop (9 screens, dark/light, 1x/2x).
cd orb && bun install --frozen-lockfile
ORB_REFERENCE_OUT=/tmp/ref node node_modules/.bin/playwright test \
  -c playwright.leanui-reference.config.ts --reporter=line
(cd /tmp/ref && sha256sum -c --quiet "$OLDPWD/../docs/ui/leanui-parity-reference.sha256")

# 2. Candidate: the same 36 frames from LeanUI.
cd .. && scripts/build_orb_bins.sh --only orb-desktop-native --out-dir "$PWD/target/native"
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
The workflow measurement is 2/36 variants under 1%, mean mismatch 5.01%.
The table below remains the prior checked-in measurement; the regenerated table
and crops are in that run's artifact. U3 is not complete.

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
| 01_control_empty | dark | 1x | 1.19 | 1.07 | 0.9836 | 3.48 / 0.9605 | 0.87 / 0.9863 | 0.00 / 1.0000 |
| 01_control_empty | dark | 2x | 0.85 | 0.76 | 0.9865 | 2.70 / 0.9636 | 0.57 / 0.9895 | 0.00 / 1.0000 |
| 01_control_empty | light | 1x | 1.19 | 1.09 | 0.9833 | 3.47 / 0.9604 | 0.87 / 0.9859 | 0.00 / 1.0000 |
| 01_control_empty | light | 2x | 0.85 | 0.77 | 0.9864 | 2.69 / 0.9638 | 0.57 / 0.9893 | 0.00 / 1.0000 |
| 02_control_populated | dark | 1x | 1.77 | 1.41 | 0.9817 | 7.30 / 0.9476 | 0.87 / 0.9863 | 0.00 / 1.0000 |
| 02_control_populated | dark | 2x | 1.36 | 1.18 | 0.9775 | 6.12 / 0.9025 | 0.57 / 0.9895 | 0.00 / 1.0000 |
| 02_control_populated | light | 1x | 1.78 | 1.42 | 0.9814 | 7.38 / 0.9474 | 0.87 / 0.9859 | 0.00 / 1.0000 |
| 02_control_populated | light | 2x | 1.36 | 1.19 | 0.9775 | 6.15 / 0.9032 | 0.57 / 0.9893 | 0.00 / 1.0000 |
| 03_mission_transcript | dark | 1x | 7.09 | 4.35 | 0.9163 | 8.94 / 0.9162 | 5.75 / 0.9118 | 15.56 / 0.9431 |
| 03_mission_transcript | dark | 2x | 6.23 | 3.75 | 0.9268 | 7.26 / 0.8866 | 5.07 / 0.9299 | 14.53 / 0.9558 |
| 03_mission_transcript | light | 1x | 6.24 | 4.76 | 0.9139 | 9.03 / 0.9156 | 5.65 / 0.9088 | 7.23 / 0.9407 |
| 03_mission_transcript | light | 2x | 5.26 | 4.15 | 0.9257 | 7.29 / 0.8872 | 4.91 / 0.9283 | 5.51 / 0.9552 |
| 04_mission_split_diff | dark | 1x | 9.13 | 6.38 | 0.8676 | 8.94 / 0.9162 | 8.54 / 0.8519 | 13.05 / 0.9422 |
| 04_mission_split_diff | dark | 2x | 7.83 | 5.33 | 0.8931 | 7.26 / 0.8866 | 7.20 / 0.8885 | 12.57 / 0.9537 |
| 04_mission_split_diff | light | 1x | 9.26 | 7.09 | 0.8631 | 9.03 / 0.9156 | 9.49 / 0.8470 | 7.08 / 0.9377 |
| 04_mission_split_diff | light | 2x | 7.87 | 6.00 | 0.8909 | 7.29 / 0.8872 | 8.18 / 0.8855 | 5.49 / 0.9530 |
| 05_machines_fleet | dark | 1x | 3.69 | 3.24 | 0.9535 | 7.30 / 0.9476 | 3.55 / 0.9468 | 0.00 / 1.0000 |
| 05_machines_fleet | dark | 2x | 2.95 | 2.68 | 0.9588 | 6.11 / 0.9026 | 2.77 / 0.9635 | 0.00 / 1.0000 |
| 05_machines_fleet | light | 1x | 3.70 | 3.25 | 0.9536 | 7.38 / 0.9475 | 3.54 / 0.9469 | 0.00 / 1.0000 |
| 05_machines_fleet | light | 2x | 2.95 | 2.69 | 0.9594 | 6.14 / 0.9033 | 2.77 / 0.9641 | 0.00 / 1.0000 |
| 06_settings_general | dark | 1x | 4.41 | 3.81 | 0.9340 | 1.90 / 0.9885 | 4.88 / 0.9239 | 6.07 / 0.9032 |
| 06_settings_general | dark | 2x | 3.35 | 2.83 | 0.9496 | 1.49 / 0.9826 | 3.70 / 0.9437 | 4.57 / 0.9276 |
| 06_settings_general | light | 1x | 4.18 | 3.88 | 0.9319 | 1.90 / 0.9885 | 4.57 / 0.9208 | 6.03 / 0.9049 |
| 06_settings_general | light | 2x | 3.14 | 2.89 | 0.9485 | 1.47 / 0.9828 | 3.41 / 0.9420 | 4.59 / 0.9290 |
| 07_search_dialog | dark | 1x | 11.11 | 1.71 | 0.9682 | 38.91 / 0.9960 | 7.08 / 0.9568 | 0.03 / 1.0000 |
| 07_search_dialog | dark | 2x | 11.26 | 1.47 | 0.9738 | 40.25 / 0.9971 | 7.01 / 0.9643 | 0.07 / 1.0000 |
| 07_search_dialog | light | 1x | 14.70 | 1.77 | 0.9683 | 46.96 / 0.9963 | 10.27 / 0.9569 | 0.41 / 1.0000 |
| 07_search_dialog | light | 2x | 14.94 | 1.47 | 0.9738 | 49.09 / 0.9975 | 10.17 / 0.9642 | 0.43 / 1.0000 |
| 08_new_mission_dialog | dark | 1x | 1.77 | 1.43 | 0.9815 | 7.30 / 0.9476 | 0.88 / 0.9860 | 0.00 / 1.0000 |
| 08_new_mission_dialog | dark | 2x | 1.37 | 1.20 | 0.9771 | 6.12 / 0.9025 | 0.59 / 0.9889 | 0.00 / 1.0000 |
| 08_new_mission_dialog | light | 1x | 1.78 | 1.43 | 0.9813 | 7.38 / 0.9474 | 0.87 / 0.9857 | 0.00 / 1.0000 |
| 08_new_mission_dialog | light | 2x | 1.37 | 1.21 | 0.9770 | 6.15 / 0.9032 | 0.58 / 0.9887 | 0.00 / 1.0000 |
| 09_toast_notifications | dark | 1x | 6.13 | 2.49 | 0.9567 | 7.30 / 0.9476 | 4.24 / 0.9732 | 20.16 / 0.8420 |
| 09_toast_notifications | dark | 2x | 5.51 | 2.10 | 0.9578 | 6.12 / 0.9025 | 3.78 / 0.9784 | 19.14 / 0.8816 |
| 09_toast_notifications | light | 1x | 6.45 | 2.43 | 0.9591 | 7.38 / 0.9474 | 4.24 / 0.9726 | 23.32 / 0.8741 |
| 09_toast_notifications | light | 2x | 5.87 | 2.03 | 0.9594 | 6.15 / 0.9032 | 3.75 / 0.9780 | 23.06 / 0.9004 |

Mean over 36 measured pairs: mismatch 5.00 %, above tolerance 2.69 %, SSIM 0.9522 (min 0.8631, max 0.9865).

Determinism (each renderer compared with a second capture of itself):

- SolidJS reference: 36/36 images pixel-identical
- LeanUI: 36/36 images pixel-identical
<!-- parity:end -->

## Wave 3 status and acceptance

LeanUI remains opt-in (`scripts/orb_desktop_dev.sh --native`). The default
SolidJS desktop and its production launcher are unchanged. Wave 2 was recovered
from public commit `ce5cff01`; this branch is based on the current `master` tip
and keeps master's `scripts/build_orb_bins.sh` verbatim.

**The <1% acceptance gate is not yet satisfied.** Architectural differences
below are disclosed for review, not approved improvements. Missing icons,
formatting and controls are remaining parity work; they must not be counted as
intentional improvements simply because native rendering differs.

Wave 3 fixes zero-ink glyphs painting stray marks, minimum character advances
stretching text, regular-face substitution for bold/medium/monospace text,
search backdrop blur and dark scrim opacity, search preview surface/timestamp,
transcript vertical rhythm, and the running composer's placeholder/Stop state.
Inter Regular/Medium/SemiBold/Bold and DejaVu Sans Mono are selected explicitly
through fontconfig; install `fonts-inter` and `fonts-dejavu-core` before capture.

The first and repeated SolidJS captures use Chrome 151.0.7922.108, Inter 4.0,
1470x923 at 1x/2x, and the fixed clock in the capture fixture. The first capture
matches **all 36** hashes in `leanui-parity-reference.sha256`. Do not update
reference hashes to make a candidate pass. The JSON report is emitted by the
comparison CLI; it preserves errors and per-region measurements.

The SSIM implementation is mean **local RGB SSIM**, uniform 7x7 window,
population covariance, 8-bit constants C1=6.5025 and C2=58.5225, valid windows.
Wave 2's recovered helper was absent, so its exact SSIM window implementation
could not be recovered. Mismatch and tolerance metrics reproduce Wave 2's
7.62% / 4.09% baseline; compare SSIM only within this implementation.
Regions are the full 220px sidebar, main transcript below the 35px title and
above the 819px dock boundary, and main composer from y=819 to the bottom.
For screens without a composer the final region is still that geometric band.

## Remaining differences and crops

Every canonical variant has a lossless paired crop below, including variants
under 1%. Coordinates are logical pixels; the tool multiplies by the filename's
scale. Each PNG is at most 5 KB. These are **SolidJS before / LeanUI after**
crops, not a claim that every changed pixel is an improvement. Full-frame
metrics above include every pixel: no masks, excluded icons, or crop-only scores.

| Screen | Remaining reason; disposition |
|---|---|
| 01_control_empty | Sidebar/topbar cached vector icons, tall-composer focus border (`pal.borderStrong`), placeholder color (`--placeholder`), and empty-state hidden send button now match SolidJS; residual diff (`0.85%` at 2×, `1.19%` at 1×) is FreeType grayscale glyph coverage vs Chromium Skia. |
| 02_control_populated | Sidebar project tree connectors, status rings, Inbox count, and mission ellipsis truncation added; residual diff (`1.36%` at 2×, `1.77%` at 1×) is FreeType vs Skia text/stroke rasterization down the 30-row sidebar. |
| 03_mission_transcript | Composer dock drop-shadow (`offsetY=4, blur=16, alpha=0x14`), placeholder color, `+` glyph, stop-button radius, and metadata chevrons added (`20.0% → 6.1%` light composer diff); remaining diff is inline code chips, syntax spans, and box-shadow quantization. |
| 04_mission_split_diff | Shares the `03` composer dock and sidebar improvements (`17.0% → 6.1%` light composer diff); remaining diff is diff header controls, syntax spans, and line wrapping. |
| 05_machines_fleet | Added `.m-group-bar` fill (`#242424` / `#edece9`) and populated sidebar icons (`4.29% → 3.69%` 1×, `3.49% → 2.95%` 2×); remaining diff is fleet row status icons and FreeType vs Skia text rasterization. |
| 06_settings_general | Added settings sidebar spacing/footer, active `Account` tab indicator, `API URL` `<input>` box, `Theme`/`Background sync` `<select>` boxes, and borderless `.s-btn` action buttons (`5.14% → 4.19%` 1×, `3.89% → 3.15%` 2×; sidebar `1.47%` / SSIM `0.9885`). |
| 07_search_dialog | Straight-alpha 8-bit `blendOver` compositing reduces the dark mismatch to `11.11%` / `11.26%` at 1×/2× and light to `14.70%` / `14.94%`; above-tolerance is `1.71%` / `1.47%` in both themes, with SSIM `0.9682` / `0.9738` dark and `0.9683` / `0.9738` light. Residual diff is three-pass box blur vs Skia Gaussian backdrop filtering. |
| 08_new_mission_dialog | Centered New Agent composer with typed prompt, focus border, and active send button (`1.37%` at 2×, `1.77%` at 1×, SSIM `0.9815`). |
| 09_toast_notifications | Premultiplied shadow compositing over the New Agent shell (`2.10%` above-tolerance at 2×, SSIM `0.9578`); residual diff is three-pass box shadow vs Skia shadow and toast alert/close icons. |

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

<!-- parity:crop 05_machines_fleet_dark_1x 540 180 50 16 -->
dark, 1x: [SolidJS](crops/05_machines_fleet_dark_1x_ref_crop.png) → [LeanUI](crops/05_machines_fleet_dark_1x_leanui_crop.png).

<!-- parity:crop 05_machines_fleet_dark_2x 540 180 50 16 -->
dark, 2x: [SolidJS](crops/05_machines_fleet_dark_2x_ref_crop.png) → [LeanUI](crops/05_machines_fleet_dark_2x_leanui_crop.png).

<!-- parity:crop 05_machines_fleet_light_1x 540 180 50 16 -->
light, 1x: [SolidJS](crops/05_machines_fleet_light_1x_ref_crop.png) → [LeanUI](crops/05_machines_fleet_light_1x_leanui_crop.png).

<!-- parity:crop 05_machines_fleet_light_2x 540 180 50 16 -->
light, 2x: [SolidJS](crops/05_machines_fleet_light_2x_ref_crop.png) → [LeanUI](crops/05_machines_fleet_light_2x_leanui_crop.png).

### 06_settings_general

<!-- parity:crop 06_settings_general_dark_1x 553 230 50 16 -->
dark, 1x: [SolidJS](crops/06_settings_general_dark_1x_ref_crop.png) → [LeanUI](crops/06_settings_general_dark_1x_leanui_crop.png).

<!-- parity:crop 06_settings_general_dark_2x 553 230 50 16 -->
dark, 2x: [SolidJS](crops/06_settings_general_dark_2x_ref_crop.png) → [LeanUI](crops/06_settings_general_dark_2x_leanui_crop.png).

<!-- parity:crop 06_settings_general_light_1x 553 230 50 16 -->
light, 1x: [SolidJS](crops/06_settings_general_light_1x_ref_crop.png) → [LeanUI](crops/06_settings_general_light_1x_leanui_crop.png).

<!-- parity:crop 06_settings_general_light_2x 553 230 50 16 -->
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
