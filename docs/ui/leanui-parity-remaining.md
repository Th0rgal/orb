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

### U3 verdict table

All seven groups are **OPEN**: these are measured improvements toward the
reference, but no remaining difference has been shown to be intentional and
better native rendering.

| group | verdict | before → after | crop | remaining fix |
|---|---|---|---|---|
| Search dialog | **OPEN** | light 1x **14.6969% → 14.4888%**; dark/light 2x **10.46% / 14.08%** | `crops/07_search_dialog_dark_2x_ref_crop.png` + `crops/07_search_dialog_dark_2x_leanui_crop.png` | Match backdrop blur/compositing and dialog typography; border correction is progress, not closure. |
| Shared populated sidebar | **OPEN** | dark 2x **1.3090% → 1.1560%**; light 2x **1.3122% → 1.1653%** | `crops/sidebar-followup-ref-after-2x.png` + `crops/sidebar-followup-diff-2x.png` | Match remaining text coverage, status rings, and icon geometry; native text remains lighter. |
| Shared composer controls | **OPEN** | new-mission dark 2x **1.2874% → 1.1345%**; light 2x **1.2897% → 1.1427%** | `crops/composer-icons-dark-2x.png` | Match remaining control glyph and text rasterisation differences. |
| Mission transcript and split diff | **OPEN** | transcript dark **7.05% / 6.12%** at 1x/2x; split diff dark **9.20% / 7.78%** at 1x/2x | `crops/03_mission_transcript_dark_2x_ref_crop.png` + LeanUI crop; `crops/04_mission_split_diff_dark_2x_ref_crop.png` + LeanUI crop | Fix pane geometry, scrollbar, composer, and text rendering. |
| Machines fleet | **OPEN** | dark 2x **2.77%** | `crops/05_machines_fleet_dark_2x_ref_crop.png` + LeanUI crop | Fix fleet/status icons and remaining sidebar text/geometry. |
| Toast notifications | **OPEN** | dark 2x **5.31%** | `crops/09_toast_notifications_dark_2x_ref_crop.png` + LeanUI crop | Fix toast shadow and alert/close icon compositing. |
| Settings general | **OPEN** | dark 2x **3.33%** | `crops/06_settings_general_dark_2x_ref_crop.png` + LeanUI crop | Fix settings pane and text geometry. |

The last parity run covering renderer code was green
[43842885377](https://github.com/Th0rgal/orb/actions/runs/43842885377) at
`ad195eee`. The branch trigger was removed in `cd4474cf`, so the docs-only head
`cd4474cf` has no new renderer parity run. U3 remains open for all seven groups.

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
close the group: U3 requires deliberate improvement with reference/before/after
crop evidence, and remaining differences must be shown to be intentional and
better native rendering.

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
unchanged. U3 closes group by group on a listed deliberate improvement shown with reference/before/after crops; groups without that evidence remain open.
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
has newly crossed below 1% yet; the group remains open because the remaining
differences have not been shown to be intentional and better native rendering.


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
| new mission dark 2x | 1.2874% | 1.1345% |
| new mission light 2x | 1.2897% | 1.1427% |

No variant regressed; the full local mean after the destination-icon correction
is 4.85%, with **2/36** variants under 1%, and the largest regression is
**+0.00015 percentage points**. The control empty 2x variants were already
under 1%; no new variant crossed the threshold. The `049b3c8a` commit body
incorrectly reports 4/36; the generated table and this correction supersede it.
The group remains OPEN because the residual differences have not been shown to
be intentional and better native rendering.
