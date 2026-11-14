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
# If the build prints "CACHE HIT" after an edit under lean/LeanUI, the binary is
# stale (turbo-lean 0.1.0 keys the package on lean/OrbDesktop only): rebuild
# with TURBO_LEAN_HOME pointing at an empty directory.

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

<!-- parity:begin -->
Reference: SolidJS desktop. Candidate: LeanUI. 36 pairs, 0 errors, tolerance 8.

`mismatch` counts any RGB difference; `> tol` counts pixels with a channel difference above tolerance. Regions show mismatch % / local RGB SSIM.

| screen | theme | scale | mismatch % | > tol % | SSIM | sidebar | transcript | composer |
|---|---|---|---:|---:|---:|---:|---:|---:|
| 01_control_empty | dark | 1x | 1.23 | 1.05 | 0.9820 | 3.42 / 0.9504 | 0.94 / 0.9862 | 0.00 / 1.0000 |
| 01_control_empty | dark | 2x | 0.93 | 0.87 | 0.9854 | 2.66 / 0.9578 | 0.70 / 0.9891 | 0.00 / 1.0000 |
| 01_control_empty | light | 1x | 1.23 | 1.10 | 0.9817 | 3.40 / 0.9501 | 0.94 / 0.9857 | 0.00 / 1.0000 |
| 01_control_empty | light | 2x | 0.93 | 0.88 | 0.9853 | 2.65 / 0.9579 | 0.70 / 0.9889 | 0.00 / 1.0000 |
| 02_control_populated | dark | 1x | 1.77 | 1.37 | 0.9771 | 7.04 / 0.9168 | 0.94 / 0.9862 | 0.00 / 1.0000 |
| 02_control_populated | dark | 2x | 1.42 | 1.27 | 0.9757 | 5.93 / 0.8923 | 0.70 / 0.9891 | 0.00 / 1.0000 |
| 02_control_populated | light | 1x | 1.78 | 1.41 | 0.9769 | 7.07 / 0.9172 | 0.94 / 0.9857 | 0.00 / 1.0000 |
| 02_control_populated | light | 2x | 1.43 | 1.27 | 0.9757 | 5.96 / 0.8931 | 0.70 / 0.9889 | 0.00 / 1.0000 |
| 03_mission_transcript | dark | 1x | 7.51 | 4.43 | 0.9099 | 8.87 / 0.8864 | 5.75 / 0.9118 | 19.91 / 0.9273 |
| 03_mission_transcript | dark | 2x | 6.73 | 3.85 | 0.9235 | 7.26 / 0.8725 | 5.07 / 0.9299 | 19.64 / 0.9454 |
| 03_mission_transcript | light | 1x | 7.40 | 5.10 | 0.9068 | 8.93 / 0.8863 | 5.58 / 0.9088 | 19.96 / 0.9173 |
| 03_mission_transcript | light | 2x | 6.60 | 4.52 | 0.9220 | 7.30 / 0.8731 | 4.88 / 0.9283 | 19.68 / 0.9414 |
| 04_mission_split_diff | dark | 1x | 9.49 | 6.46 | 0.8620 | 8.87 / 0.8864 | 8.44 / 0.8532 | 17.23 / 0.9252 |
| 04_mission_split_diff | dark | 2x | 8.22 | 5.40 | 0.8902 | 7.26 / 0.8725 | 7.12 / 0.8892 | 16.93 / 0.9437 |
| 04_mission_split_diff | light | 1x | 10.16 | 7.34 | 0.8572 | 8.93 / 0.8863 | 9.34 / 0.8483 | 17.28 / 0.9164 |
| 04_mission_split_diff | light | 2x | 8.92 | 6.28 | 0.8878 | 7.30 / 0.8731 | 8.07 / 0.8863 | 16.97 / 0.9402 |
| 05_machines_fleet | dark | 1x | 5.03 | 3.28 | 0.9486 | 7.04 / 0.9166 | 5.45 / 0.9462 | 0.00 / 1.0000 |
| 05_machines_fleet | dark | 2x | 4.32 | 2.72 | 0.9570 | 5.93 / 0.8923 | 4.71 / 0.9631 | 0.00 / 1.0000 |
| 05_machines_fleet | light | 1x | 5.03 | 3.28 | 0.9486 | 7.07 / 0.9170 | 5.45 / 0.9462 | 0.00 / 1.0000 |
| 05_machines_fleet | light | 2x | 4.32 | 2.73 | 0.9576 | 5.96 / 0.8930 | 4.71 / 0.9637 | 0.00 / 1.0000 |
| 06_settings_general | dark | 1x | 4.77 | 3.65 | 0.9299 | 2.20 / 0.9524 | 5.31 / 0.9256 | 6.07 / 0.9032 |
| 06_settings_general | dark | 2x | 3.75 | 2.67 | 0.9478 | 1.74 / 0.9658 | 4.21 / 0.9447 | 4.57 / 0.9276 |
| 06_settings_general | light | 1x | 4.76 | 4.48 | 0.9271 | 2.21 / 0.9534 | 5.30 / 0.9213 | 6.03 / 0.9049 |
| 06_settings_general | light | 2x | 3.76 | 3.53 | 0.9463 | 1.73 / 0.9665 | 4.22 / 0.9423 | 4.59 / 0.9290 |
| 07_search_dialog | dark | 1x | 19.45 | 2.16 | 0.9621 | 90.24 / 0.9855 | 7.87 / 0.9504 | 0.63 / 1.0000 |
| 07_search_dialog | dark | 2x | 19.40 | 1.92 | 0.9689 | 90.29 / 0.9886 | 7.81 / 0.9593 | 0.60 / 1.0000 |
| 07_search_dialog | light | 1x | 15.03 | 2.53 | 0.9625 | 47.88 / 0.9904 | 10.54 / 0.9500 | 0.41 / 1.0000 |
| 07_search_dialog | light | 2x | 15.34 | 2.26 | 0.9697 | 50.29 / 0.9961 | 10.46 / 0.9588 | 0.43 / 1.0000 |
| 08_new_mission_dialog | dark | 1x | 1.73 | 1.43 | 0.9770 | 7.04 / 0.9168 | 0.88 / 0.9860 | 0.00 / 1.0000 |
| 08_new_mission_dialog | dark | 2x | 1.34 | 1.20 | 0.9756 | 5.93 / 0.8923 | 0.59 / 0.9889 | 0.00 / 1.0000 |
| 08_new_mission_dialog | light | 1x | 1.73 | 1.42 | 0.9769 | 7.07 / 0.9172 | 0.87 / 0.9857 | 0.00 / 1.0000 |
| 08_new_mission_dialog | light | 2x | 1.34 | 1.20 | 0.9755 | 5.96 / 0.8931 | 0.58 / 0.9887 | 0.00 / 1.0000 |
| 09_toast_notifications | dark | 1x | 6.14 | 2.45 | 0.9521 | 7.04 / 0.9168 | 4.31 / 0.9731 | 20.16 / 0.8420 |
| 09_toast_notifications | dark | 2x | 5.58 | 2.19 | 0.9560 | 5.93 / 0.8923 | 3.91 / 0.9780 | 19.14 / 0.8816 |
| 09_toast_notifications | light | 1x | 6.45 | 2.43 | 0.9546 | 7.07 / 0.9172 | 4.31 / 0.9725 | 23.32 / 0.8741 |
| 09_toast_notifications | light | 2x | 5.93 | 2.12 | 0.9577 | 5.96 / 0.8931 | 3.88 / 0.9776 | 23.06 / 0.9004 |

Mean over 36 measured pairs: mismatch 5.86 %, above tolerance 2.84 %, SSIM 0.9486 (min 0.8572, max 0.9854).

Determinism (each renderer compared with a second capture of itself):

- SolidJS reference: 36/36 images pixel-identical
- LeanUI: 36/36 images pixel-identical
<!-- parity:end -->

## Wave 3 status and acceptance

LeanUI remains opt-in (`scripts/orb_desktop_dev.sh --native`). The default
SolidJS desktop and its production launcher are unchanged. Wave 2 was recovered
from public commit `ce5cff01`; this branch is based on master `cb4887d3e` and
keeps master's `scripts/build_orb_bins.sh` verbatim.

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
| 01_control_empty | FreeType grayscale glyph coverage and pixel-snapped text origins differ from Chromium Skia; sidebar/topbar SVG icons and composer icons are still missing. Architectural raster difference plus incomplete parity. |
| 02_control_populated | Same text/icon difference, repeated down the project tree; native truncation lacks the reference ellipsis and tree connectors. Incomplete parity. |
| 03_mission_transcript | Native flat runs lack inline code chips, syntax spans, bullet markers and copy controls; browser text/shadows differ. Timestamp and composer controls still differ. Incomplete parity. |
| 04_mission_split_diff | Same transcript differences; native diff header controls, syntax/wrapping and file-pane titlebar differ. Incomplete parity. |
| 05_machines_fleet | Native fleet sidebar still uses an empty project tree and lacks row icons; card typography, badges and border geometry differ. Incomplete parity. |
| 06_settings_general | Native form labels, controls, line wrapping and card metrics differ; native font rendering differs. Incomplete parity. |
| 07_search_dialog | Native blur uses three deterministic box passes approximating a Gaussian; native shadows use three box passes over rounded coverage rather than Skia. Search icons, highlights and several controls still differ. Architectural filter difference plus incomplete parity. |
| 08_new_mission_dialog | SolidJS has no such modal: both captures use New Agent with a typed prompt. Text/icon differences follow 02. Incomplete parity. |
| 09_toast_notifications | Native box-filter shadow differs from the browser's Skia shadow; close/warning icons, padding and typography still differ. Architectural filter difference plus incomplete parity. |

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
constant surfaces, empty images, and zero sigma. The installed turbo-lean 0.1.0
has no `--jobs` switch; use `RAYON_NUM_THREADS=2`, `LEAN_CC=/usr/bin/clang`,
`LIBRARY_PATH=/usr/lib/x86_64-linux-gnu:<lean-prefix>/lib`, and a fresh
workspace-local `TURBO_LEAN_HOME` after edits outside the OrbDesktop package.
This avoids stale cache hits and does not change master's build wrapper.
