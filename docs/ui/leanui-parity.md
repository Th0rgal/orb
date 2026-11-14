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

`mismatch` is the share of pixels whose RGB differs at all; `> tol` the share where a channel differs by more than the tolerance. Region columns are `mismatch % / SSIM`.

| screen | theme | scale | mismatch % | > tol % | SSIM | sidebar | transcript | composer |
|---|---|---|---:|---:|---:|---:|---:|---:|
| 01_control_empty | dark | 1x | 1.24 | 1.06 | 0.9802 | 3.49 / 0.9419 | 0.94 / 0.9858 | 0.00 / 1.0000 |
| 01_control_empty | dark | 2x | 0.95 | 0.89 | 0.9841 | 2.74 / 0.9519 | 0.70 / 0.9888 | 0.00 / 1.0000 |
| 01_control_empty | light | 1x | 1.24 | 1.12 | 0.9797 | 3.48 / 0.9411 | 0.94 / 0.9852 | 0.00 / 1.0000 |
| 01_control_empty | light | 2x | 0.95 | 0.90 | 0.9839 | 2.73 / 0.9516 | 0.70 / 0.9885 | 0.00 / 1.0000 |
| 02_control_populated | dark | 1x | 1.85 | 1.51 | 0.9703 | 7.53 / 0.8746 | 0.94 / 0.9858 | 0.00 / 1.0000 |
| 02_control_populated | dark | 2x | 1.50 | 1.35 | 0.9722 | 6.43 / 0.8713 | 0.70 / 0.9888 | 0.00 / 1.0000 |
| 02_control_populated | light | 1x | 1.86 | 1.56 | 0.9697 | 7.58 / 0.8734 | 0.94 / 0.9852 | 0.00 / 1.0000 |
| 02_control_populated | light | 2x | 1.51 | 1.35 | 0.9718 | 6.46 / 0.8703 | 0.70 / 0.9885 | 0.00 / 1.0000 |
| 03_mission_transcript | dark | 1x | 10.50 | 5.66 | 0.8640 | 9.49 / 0.8351 | 9.62 / 0.8638 | 20.96 / 0.8983 |
| 03_mission_transcript | dark | 2x | 9.50 | 4.78 | 0.8970 | 7.90 / 0.8441 | 8.65 / 0.9024 | 20.50 / 0.9275 |
| 03_mission_transcript | light | 1x | 10.43 | 8.20 | 0.8591 | 9.56 / 0.8332 | 9.50 / 0.8587 | 21.02 / 0.8891 |
| 03_mission_transcript | light | 2x | 9.40 | 7.32 | 0.8952 | 7.93 / 0.8428 | 8.51 / 0.9008 | 20.55 / 0.9229 |
| 04_mission_split_diff | dark | 1x | 11.98 | 7.47 | 0.8218 | 9.49 / 0.8351 | 11.62 / 0.8128 | 18.28 / 0.8963 |
| 04_mission_split_diff | dark | 2x | 10.48 | 6.14 | 0.8669 | 7.90 / 0.8441 | 10.00 / 0.8655 | 17.78 / 0.9261 |
| 04_mission_split_diff | light | 1x | 12.68 | 9.90 | 0.8153 | 9.56 / 0.8332 | 12.56 / 0.8059 | 18.34 / 0.8876 |
| 04_mission_split_diff | light | 2x | 11.20 | 8.57 | 0.8639 | 7.93 / 0.8428 | 10.98 / 0.8623 | 17.83 / 0.9217 |
| 05_machines_fleet | dark | 1x | 5.08 | 3.51 | 0.9312 | 7.31 / 0.8118 | 5.47 / 0.9446 | 0.00 / 1.0000 |
| 05_machines_fleet | dark | 2x | 4.32 | 2.74 | 0.9515 | 5.67 / 0.8689 | 4.76 / 0.9607 | 0.00 / 1.0000 |
| 05_machines_fleet | light | 1x | 5.09 | 3.51 | 0.9312 | 7.38 / 0.8104 | 5.46 / 0.9450 | 0.00 / 1.0000 |
| 05_machines_fleet | light | 2x | 4.32 | 2.74 | 0.9519 | 5.71 / 0.8683 | 4.76 / 0.9614 | 0.00 / 1.0000 |
| 06_settings_general | dark | 1x | 4.81 | 3.70 | 0.9255 | 2.19 / 0.9521 | 5.35 / 0.9223 | 6.22 / 0.8933 |
| 06_settings_general | dark | 2x | 3.86 | 2.78 | 0.9441 | 1.74 / 0.9649 | 4.33 / 0.9411 | 4.76 / 0.9215 |
| 06_settings_general | light | 1x | 4.80 | 4.53 | 0.9226 | 2.19 / 0.9530 | 5.35 / 0.9180 | 6.18 / 0.8945 |
| 06_settings_general | light | 2x | 3.87 | 3.63 | 0.9425 | 1.74 / 0.9654 | 4.34 / 0.9386 | 4.77 / 0.9226 |
| 07_search_dialog | dark | 1x | 28.05 | 5.98 | 0.9336 | 99.51 / 0.8436 | 17.95 / 0.9420 | 0.01 / 0.9994 |
| 07_search_dialog | dark | 2x | 27.85 | 5.78 | 0.9474 | 99.19 / 0.8817 | 17.74 / 0.9527 | 0.06 / 0.9996 |
| 07_search_dialog | light | 1x | 23.42 | 10.63 | 0.9346 | 52.88 / 0.8466 | 21.05 / 0.9428 | 0.80 / 0.9992 |
| 07_search_dialog | light | 2x | 23.37 | 10.42 | 0.9513 | 53.98 / 0.8978 | 20.75 / 0.9548 | 0.83 / 0.9995 |
| 08_new_mission_dialog | dark | 1x | 1.80 | 1.57 | 0.9698 | 7.53 / 0.8746 | 0.88 / 0.9851 | 0.00 / 1.0000 |
| 08_new_mission_dialog | dark | 2x | 1.41 | 1.27 | 0.9720 | 6.43 / 0.8713 | 0.58 / 0.9886 | 0.00 / 1.0000 |
| 08_new_mission_dialog | light | 1x | 1.81 | 1.57 | 0.9693 | 7.58 / 0.8734 | 0.87 / 0.9847 | 0.00 / 1.0000 |
| 08_new_mission_dialog | light | 2x | 1.42 | 1.27 | 0.9717 | 6.46 / 0.8703 | 0.58 / 0.9883 | 0.00 / 1.0000 |
| 09_toast_notifications | dark | 1x | 8.61 | 2.67 | 0.9400 | 7.53 / 0.8746 | 6.12 / 0.9668 | 31.54 / 0.8221 |
| 09_toast_notifications | dark | 2x | 8.08 | 2.33 | 0.9494 | 6.43 / 0.8713 | 5.72 / 0.9743 | 30.85 / 0.8694 |
| 09_toast_notifications | light | 1x | 7.72 | 4.71 | 0.9384 | 7.58 / 0.8734 | 5.27 / 0.9641 | 28.57 / 0.8290 |
| 09_toast_notifications | light | 2x | 7.17 | 4.26 | 0.9494 | 6.46 / 0.8703 | 4.87 / 0.9734 | 27.74 / 0.8789 |

Mean over 36 measured pairs: mismatch 7.62 %, above tolerance 4.09 %, SSIM 0.9340 (min 0.8153, max 0.9841).

Determinism (a renderer against a second capture of itself; this is not parity):

- SolidJS reference: 36/36 images pixel-identical
- LeanUI: 36/36 images pixel-identical
<!-- parity:end -->

## What the numbers do and do not say

- No screen is pixel-identical to the reference. Mean mismatch over the 36
  pairs is 7.62 % (4.09 % above the 8-level channel tolerance) and mean SSIM is
  0.9340 (min 0.8153 on `04_mission_split_diff_light_1x`, max 0.9841 on
  `01_control_empty_dark_2x`).
- The palettes in `lean/LeanUI/Style.lean` are the SolidJS tokens of
  `orb/src/styles.css` (`scripts/test_leanui_tokens.py` fails when they drift).
  The main, sidebar, composer, card, diff, and dialog surfaces use the same
  tokens in both themes.
- The chrome and screen bodies follow the SolidJS geometry:
  - A 220 px sidebar with a 1 px right border, six top navigation rows (`New
    Agent`, `Inbox`, `Cloud agent`, `Machines`, `Inference`, `Resources`), the
    `Projects` / `Archived` tree (or `Settings` tabs on `06_settings_general`),
    and the 45 px footer bar (`lean/OrbDesktop/Spec/ChromeGeometry.lean` pins
    the outer chrome rectangles at 1x and 2x).
  - A 35 px title row (`New Agent`, `Long mission` with right-side machine and
    diff controls, `Machines`, or `Settings`).
  - Screen-specific bodies in `lean/OrbDesktop/Screens.lean`: the centered New
    Agent composer stack (`01`, `02`, `08`) and toast stack (`09`), the user
    bubble + assistant turn + bottom composer dock (`03`) and split diff pane
    (`04`), the Machines fleet header and table (`05`), the Settings · Account
    rows (`06`), and the full-window scrim + two-pane `Search conversations`
    dialog (`07`).
- Remaining pixel differences come from:
  - Font and glyph rasterization: LeanUI shapes text through HarfBuzz +
    FreeType using the fontconfig match for `sans-serif` / `monospace` (DejaVu
    Sans / DejaVu Sans Mono here) and blends glyphs without subpixel LCD or CSS
    box-shadow blur; SolidJS renders through Chromium's Skia text and shadow
    pipeline.
  - Vector icons: SolidJS draws inline SVG strokes for sidebar rows, header
    buttons, and composer controls, whereas LeanUI uses text glyphs or
    geometric primitives.
  - Scrim quantization on `07_search_dialog`: 8-bit alpha blending over the
    sidebar and canvas produces 1-level rounding differences on a large share of
    the backdrop (`mismatch %`), most of which fall within the 8-level
    tolerance (`> tol %`).
- `08_new_mission_dialog` has no SolidJS modal counterpart: the reference is
  the New Agent page with the prompt typed in, and LeanUI renders the same view.
- The determinism lines compare a renderer with itself. They show that both
  captures are repeatable and nothing else.
