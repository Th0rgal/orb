# Remaining LeanUI pixel parity

Follow-up to #1822, based on merge commit
`2c36e4608eef19eb2d5c23ae368c36cbe60f3ead`.

The verified pre-merge measurement from
[run 43802006749](https://github.com/Th0rgal/orb/actions/runs/43802006749)
has 36 pairs, 0 measurement errors, 2 variants under 1% mismatch, mean
mismatch 5.01%, mean above-tolerance mismatch 2.70%, and mean SSIM 0.9521.
The worst mismatch is `07_search_dialog`, light, 2x: 14.94%.
These are baseline numbers, not evidence of a follow-up improvement.

## Work queue

## U3 group verdicts at `ad195eee`

These verdicts use the nine pinned SolidJS reference captures verified by the
parity workflow. No reference image, hash, threshold, mask, or comparison
code was changed. The latest complete local measurement is 36/36 pairs, mean
raw mismatch **4.85%**, and **2/36** variants under 1%.

### Search-dialog border

**CLOSED AS IMPROVEMENT.** The native search-dialog border now uses the
reference's 8% foreground/stroke mix; the crop shows the border tone matching
the SolidJS reference more closely, with light 1x mismatch **14.6969% →
14.4888%**. Crop: `crops/search-border-ref.png` beside
`crops/search-border-after.png` (the pre-fix comparison is
`crops/search-border-before.png`). Remaining blur and typography differences
are open renderer work.

### Shared populated sidebar

**CLOSED AS IMPROVEMENT.** Project rows now use the reference folder outline
geometry and an optical text baseline while retaining the 30px row / 31px
pitch; the 2x crop shows the native rows aligned with the reference. Sidebar
region mismatch improved to **4.94% dark 2x / 5.00% light 2x**, and full-frame
`02_control_populated` improved to **1.3090% → 1.1561% dark 2x** and
**1.3122% → 1.1654% light 2x**. Crops:
`crops/sidebar-overview-2x.png`, `crops/sidebar-navigation-2x.png`,
`crops/sidebar-text-2x.png`, and `crops/sidebar-icons-2x.png`.

### Shared composer controls

**CLOSED AS IMPROVEMENT.** The native composer now includes the reference's
centered project/core controls, chevrons, and model indicator; the existing
before/after evidence shows the controls in the same positions and reduces
affected full-frame mismatch (for example new-mission dark 2x **1.345% →
1.287%**). Crop: `crops/08_new_mission_dialog_dark_2x_ref_crop.png` beside
`crops/08_new_mission_dialog_dark_2x_leanui_crop.png`.

### Mission transcript and split diff

**OPEN.** The remaining native text, pane geometry, scrollbar, and composer
differences are not demonstrated improvements. The latest full-frame values
remain **7.05% / 6.12%** for transcript dark 1x/2x and **9.20% / 7.78%** for
split diff dark 1x/2x. Regions and likely fixes are documented by
`crops/03_mission_transcript_dark_2x_ref_crop.png` plus its LeanUI crop and
`crops/04_mission_split_diff_dark_2x_ref_crop.png` plus its LeanUI crop;
geometry and text rasterisation need further renderer work.

### Search-dialog remainder

**OPEN.** The border improvement is closed above, but the group remainder is
not better: the dialog still measures **10.46% dark 2x / 14.08% light 2x**.
The region is the blurred dialog backdrop and dialog typography; fixing
compositing/blur and matching text rasterisation would be required. Crops:
`crops/07_search_dialog_dark_2x_ref_crop.png` and
`crops/07_search_dialog_dark_2x_leanui_crop.png`.

### Machines, toasts, and settings screen-specific regions

**OPEN.** These differences were inspected but are not deliberate improvements
as a whole. The latest full-frame values are machines dark 2x **2.77%**, toasts
dark 2x **5.31%**, and settings dark 2x **3.33%**; the remaining fixes are
fleet/status icons, toast shadow/icon compositing, and settings pane/text
geometry. Crops: `crops/05_machines_fleet_dark_2x_ref_crop.png` with its
LeanUI crop, `crops/09_toast_notifications_dark_2x_ref_crop.png` with its
LeanUI crop, and `crops/06_settings_general_dark_2x_ref_crop.png` with its
LeanUI crop.

The temporary parity workflow trigger for `fix/leanui-parity-remaining` exists
only to run the pinned parity job for this U3 branch; it must be removed before
merging because the workflow has no pull-request trigger.

### Search-dialog border correction

The renderer used `pal.border` directly. `SearchDialog.css` instead mixes
8% foreground into that stroke. Applying the same mix improves raw mismatch:

| variant | before | after |
|---|---:|---:|
| dark 1x | 11.1062% | 10.8981% |
| dark 2x | 11.2641% | 11.0534% |
| light 1x | 14.6969% | 14.4888% |
| light 2x | 14.9429% | 14.7322% |

All other 32 candidate images are unchanged in the local before/after run;
no variant regressed. The full documented comparison reports 2/36 under 1%,
mean 4.99%, worst light 2x search 14.73%. These captures use the pinned private
fonts and the merged-head artifact references. The host's libc++ link selection
required explicitly linking the toolchain library directory after compilation;
CI remains the clean build evidence.

Border crops (light 1x, x=470..570, y=68..90):

| reference | before | after |
|---|---|---|
| ![reference](crops/search-border-ref.png) | ![before](crops/search-border-before.png) | ![after](crops/search-border-after.png) |

Search remains above 1%; blur and typography differences remain renderer work,
not a demonstrated external reference blocker. This correction alone does not
satisfy the new-under-1% merge condition.

- Search dialog: inspect backdrop blur/compositing and sidebar differences
  first; all four variants exceed 11% mismatch, while above-tolerance
  mismatch is below 1.8%.
- Shared sidebar: inspect populated card typography and geometry across
  control, mission, machines, new-mission, and toast screens.
- Mission transcript and split diff: align text, pane geometry, and composer.
- Toasts, settings, and machines: inspect remaining screen-specific regions.
- Re-run the complete 36-variant measurement after rendering changes and
  record improvements and regressions before accepting them.

The `fix/leanui-parity-remaining` branch runs the existing pinned parity
workflow. Keep reference hashes, thresholds, masks, and comparison code
unchanged. U3 remains incomplete until the documented parity criteria pass.
U2 acceptance and the roadmap row are owned by the parent after merged-head
run [43807502974](https://github.com/Th0rgal/orb/actions/runs/43807502974)
passes; this follow-up does not change the roadmap.

### Search border and glyph-phase corrections

The search dialog border correction is committed in `db26c501`. It lowers
search raw mismatch to 10.90/11.05/14.49/14.73% (dark 1x/2x, light 1x/2x).
The follow-up glyph-phase correction uses quarter-pixel FreeType atlas phases
from HarfBuzz advances. Against the same local baseline it changes the shared
sidebar group as follows:

| variant | before | after |
|---|---:|---:|
| populated dark 1x | 1.765% | 1.757% |
| populated dark 2x | 1.360% | 1.336% |
| populated light 1x | 1.778% | 1.774% |
| populated light 2x | 1.363% | 1.339% |

The full local table after both changes is mean mismatch **4.98%**, mean
above tolerance **2.67%**, SSIM **0.9526**. No variant worsened by 0.1 point;
the largest local increase was search light 1x at **+0.008 points**. No group
has newly crossed below 1% yet, so this PR is not mergeable under the U3 rule.


### Shared composer control correction

The centered composer was missing the reference's vector controls: project/core
icons, dropdown chevrons, and the model dropdown indicator. Reusing the existing
LeanUI icon primitives reduces the following raw mismatch values against the same
reference set:

| variant | before | after |
|---|---:|---:|
| control empty dark 1x | 1.195% | 1.140% |
| control empty dark 2x | 0.850% | 0.823% |
| control empty light 1x | 1.192% | 1.137% |
| control empty light 2x | 0.848% | 0.821% |
| new mission dark 2x | 1.345% | 1.287% |
| new mission light 2x | 1.347% | 1.290% |

No variant regressed; the full local mean is 4.96%, SSIM 0.9534, and
**2/36** variants are under 1%. The control empty 2x variants were already
under 1%; no new variant crossed the threshold. The `049b3c8a` commit body
incorrectly reports 4/36; the generated table and this correction supersede it.
