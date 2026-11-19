# Wave 3 validation receipt

Base: `origin/master` at `cb4887d3e`. Recovered source:
`origin/wip/leanui-wave2-partial` at `ce5cff01`. Master's build wrapper was retained.
Worker: managed Boat large, 8 vCPU / 16 GiB, x86_64 Ubuntu 24.04.
No push or credential access was used. Delivery is a git bundle.

## Gates

- `turbo-lean build --project-dir lean/OrbDesktop orb-desktop-native LeanUISpec`:
  65 build jobs passed, including all recovered geometry/composer-damage guards
  and new raster regression guards. The installed CLI lacks `--jobs`; execution
  used `RAYON_NUM_THREADS=2`, a 10000 MiB cap, system clang and library paths.
- `python3 -m unittest -v scripts/test_leanui_tokens.py scripts/test_leanui_parity.py`:
  7 tests passed (numpy and Pillow installed in a workspace virtual environment).
- `scripts/leanui_window_smoke.sh target/native/orb-desktop-native`: passed with
  workspace-installed Weston 13. A normal window attached a shared-memory buffer,
  stayed alive, and exited zero following `xdg_toplevel.close`. Single/all golden
  and benchmark modes exited zero with no compositor available.
- `pnpm build && pnpm check:bundle`: passed. Vite emitted existing chunk/import
  warnings; startup JS remained within its configured budget.
- Playwright reference fixture: 36/36 passed twice; original reference manifest
  verified 36/36 SHA-256 hashes. Chrome 151.0.7922.108, Inter 4.0, DejaVu Sans Mono.
- Native goldens: 36/36 emitted twice; both renderer repeats are pixel-identical.
- Parity CLI: 36 pairs, zero errors; the table and full-precision JSON are in
  `leanui-parity.md` / `leanui-parity-wave3.json`. All 72 crop PNGs are lossless,
  maximum 2100 bytes each.

Native binary SHA-256:
`ca62ca7ea53639a056b34a8dd3fd7eb683c8d439eac8616379c5cdceb930c8d1`.

## U7 follow-up (replacement worker)

The U7 benchmark remains authoritative for the stated 60 fps/WebKit acceptance:
`scripts/bench_desktop.sh` still requires cold startup `<= 60 ms`, frame p50
`<= 2.5 ms`, frame p99 `<= 8.33 ms`, and transcript-open time no slower than
the WebKitGTK baseline. Acceptance was not relaxed.

This follow-up reduces per-frame allocation in the exact native render path:
glyphs, shaped runs, and shaped child nodes are accumulated in arrays, and
committed stream chunks use a single `String.intercalate` join. The U7 stream
spec adds an exact-order regression case in
`OrbDesktop/Spec/StreamDamage.lean`.

Local Linux measurements (`scripts/bench_desktop.sh`, 1470×923, three runs,
60 streamed updates) used the repo's raw Lake fallback and a desktop sysroot.
Sampling attributed 63% of baseline CPU samples to the blur loops. Cropping
shadow masks to the visible area plus their blur halo shifted the largest cost
to rounded boxes; straight strips can determine full coverage without a distance
calculation. All 36 native golden PNGs matched the baseline byte for byte after
both changes. First-frame CRC32 remained 2783534071.

| Local build | Startup ms | Open ms | Frame p50 ms | Frame p99 ms | Peak RSS MiB |
|---|---:|---:|---:|---:|---:|
| `054155ae2` | 1731.32 | 2108.49 | 1260.88 | 1399.22 | 118.27 |
| Shadow crop + integer square-root early exit | 854.04 | 1212.35 | 344.87 | 366.96 | 95.99 |
| Plus rounded-box straight strips | 538.83 | 668.59 | 145.20 | 165.76 | 96.20 |
| Plus changed visible bounds | 995.12 | 1231.57 | 73.60 | 159.91 | 87.78 |

The visible-bounds run verified each of 20 successive stream framebuffers
against a full repaint in a separate invocation (`--verify-repaint --bench 20
--width 1470 --height 923`), plus clip changes and used/unused atlas texel
changes. All 36 golden PNGs remained byte-identical. The last stream update
needed zero draw primitives. The table uses the ordinary three-run benchmark
without the reference renders; startup and transcript-open were slower in this run.

### Stream stage attribution

`ORB_U7_PROFILE=1 orb-desktop-native --bench 20 --width 1470 --height 923`
emits wall-clock nanoseconds to stderr. Compare the last 20 `u7-view-ns` rows
(exclude three startup/open views) and all 20 `u7-paint-ns` rows. Baseline and
candidate used the same raw Lake native build, host, sysroot and stream input.
Means in milliseconds, including zero-raster frames:

| Stage (in log column order) | Instrumented `0d6b7c3f2` | Candidate |
|---|---:|---:|
| Widget construction, shaping and conversion to layout inputs | 9.031 | 8.555 |
| Layout | 1.281 | 1.348 |
| Scene command generation | 53.062 | 0.945 |
| Changed bounds | 0.278 | 0.157 |
| Atlas validation | 12.474 | 10.752 |
| Framebuffer copy | 0.145 | 0.090 |
| Changed-region clear and raster | 4.914 | 4.956 |
| Instance staging | 0.013 | 0.011 |

Profile mode times an explicit framebuffer copy on painted frames in place of
the normal implicit copy-on-write. Only 2/20 frames painted. Raster cost is
therefore about 50 ms per painted frame on average, despite the low stream-wide
mean. The renderer no longer computes unused per-widget damage fingerprints;
the node-record API retains its default behavior. Packed zero buffers avoid
pointer-sized temporary arrays for atlas and filter scratch allocation.

Separate three-run acceptance measurements with profiling disabled:

| Build | Startup ms | Open ms | Frame p50 ms | Frame p99 ms | Peak RSS MiB |
|---|---:|---:|---:|---:|---:|
| Same-build baseline | 990.02 | 1205.54 | 72.41 | 159.16 | 87.94 |
| No unused fingerprints or initial framebuffer | 1071.34 | 1319.42 | 23.08 | 174.94 | 87.69 |
| Plus packed atlas and filter buffers | 1020.83 | 1270.21 | 24.62 | 163.72 | 59.83 |

The final run passes the 64 MiB hard RSS ceiling, not the 45 MiB target or
latency budgets. The 20 independent full-repaint comparisons, clip/atlas
fixtures and all 36 unchanged golden PNGs passed. There is no new on-device
WebKit/m2air comparison.

### Atlas validation and stable labels

Repeated the same native Lake build mode, host, sysroot, viewport and 20-update
stream using the preserved `8b3d174cc` binary and the candidate. Of 20 updates,
18 changed no visible pixels. On those 18 the mean exact atlas validation fell
from 11.804 to 0.238 ms (bounded row comparisons, not hashes), and widget
construction/shaping from 6.972 to 3.968 ms (bounded cache of short resolved
labels, discarded on atlas reset). Layout and lowering still cost 1.326 and
0.899 ms respectively on the candidate.

With `ORB_U7_PROFILE=1`, `u7-startup-ns` separates runtime initialization from
the first render and `u7-update` labels each streamed frame with pixels and
primitive count. In the candidate trace cold init was 8.59 ms; the first frame
was 933.36 ms including 636.77 ms of widget construction/shaping. Stream update
0 painted 53,265 pixels using 151 primitives: 134.55 ms total, 101.51 ms in
changed-region raster. Update 1 painted 2,506 pixels using 24 primitives:
8.37 ms total, 0.46 ms raster. The other 18 did no raster work. Visibility is
determined after shaping/layout and scene diff; the renderer currently needs
the new command stream even to recognize a fully clipped append.

| Unprofiled, 3 runs | Startup ms | Open ms | Frame p50 ms | Frame p99 ms | Peak RSS MiB |
|---|---:|---:|---:|---:|---:|
| `8b3d174cc`, rerun | 951.26 | 1102.21 | 23.82 | 139.23 | 54.53 |
| Row comparison and resolved labels | 972.40 | 1160.68 | 6.99 | 134.49 | 54.72 |

All 20 independent full-frame comparisons, atlas/clip invalidation cases and
36 byte-identical PNGs passed. Budgets remain unchanged; acceptance still fails.

### Strict native build and cold-render follow-up

On `56053d301` kernel ABI found stale generated FFI manifests; Desktop Shell
and parity rejected `LeanUI.FFI.sameRows` at native build time. `51c61264a`
regenerated both manifests. The allowlist check and strict warm-cache edit
regression passed without raw Lake fallback. Both measurements below use the
same pinned turbo-lean native build mode, Linux host, desktop sysroot and
three 1470×923 runs (not the raw Lake numbers above).

| Build | Startup ms | Open ms | Frame p50 ms | Frame p99 ms | Peak RSS MiB |
|---|---:|---:|---:|---:|---:|
| Repair only | 557.30 | 767.98 | 3.86 | 79.04 | 56.03 |
| Atlas page modification, opaque scanlines, scanline-filtered icon segments | 276.72 | 323.77 | 5.24 | 87.79 | 63.43 |

In a separate profile cold widget construction/shaping fell from 339.81 to
145.64 ms. Cold labels include vector-icon mask construction: precomputing
segment geometry and excluding distant segments retains the 16 sample points
and coverage formula. The first changed-region raster (53,265 pixels) fell
from 66.31 to 59.97 ms in the trace, but the unprofiled frame percentiles did
not improve. All independent stream frames, atlas/clip cases and 36 PNGs
matched. Startup and frame budgets still fail; local RSS is below the hard
limit with little headroom.

### Packed native filters and icon coverage

The native RGBA8 blur pass retains the same integer rolling sum, replicated
edge samples and rounding as the Lean reference. Icon coverage uses the same
16 sample positions, round endpoints and threshold, with a Lean fallback for
inputs outside the compact coordinate/size range. Differential checks cover
both filter directions, single-row/column buffers, oversized radii, degenerate
icon segments and multiple scales. All 20 streamed framebuffers, clip/atlas
fixtures and 36 golden PNGs matched. The strict warm-cache build test passed.

Back-to-back on the same shared Linux host, pinned native build mode, unchanged
three-run 1470×923 gate (absolute times vary with host load):

| Build | Startup ms | Open ms | Frame p50 ms | Frame p99 ms | Peak RSS MiB |
|---|---:|---:|---:|---:|---:|
| `1c9df8e21` rerun | 576.82 | 632.72 | 7.93 | 131.90 | 56.27 |
| Packed filters and icon coverage | 451.24 | 542.75 | 7.40 | 51.89 | 56.14 |

Acceptance still fails. In a separate trace the first painted update spent
15.03 ms rasterizing and 36.52 ms building/shaping widgets; the first cold
view spent 349.34 ms in widget construction/shaping. A glyph hash-map trial
was discarded because it measured 67.43 MiB, above the hard ceiling.

### Glyph miss and page-copy profile

A diagnostic relink of the pinned build instrumented generated function entry
and exit and wrapped `lean_copy_sarray_nonlinear` only while inside atlas blits.
The first view was a cold transcript; the next two views exercised open; the
fourth was the first painted stream update. Times below are inclusive (do not
sum upload and copy time). Copy counts exclude explicit growth of a page.

| Stage | Cold `f32589299` | Cold candidate | First update `f32589299` | First update candidate |
|---|---:|---:|---:|---:|
| Rasterized glyph misses | 343 | 343 | 38 | 38 |
| FreeType raster / decode ms | 6.50 / 0.28 | 3.63 / 0.10 | 0.53 / 0.02 | 0.32 / 0.01 |
| HarfBuzz shape ms | 3.06 | 3.37 | 0.05 | 0.05 |
| Bitmap blits / inclusive ms | 345 / 275.78 | 345 / 12.29 | 38 / 23.54 | 38 / 0.19 |
| COW copies / MiB / ms | 344 / 1376 / 274.40 | 0 / 0 / 0 | 38 / 152 / 23.40 | 1 / 0.5 / 0.10 |
| Total view ms | 326.11 | 30.99 | 27.92 | 3.71 |

Five cold font opens totalled 12.06 ms before and 8.95 ms after. Allocation
now assigns UVs in order, queues bitmaps and commits each page's writes in
order before returning the frame. Previous frames remain immutable. Pixel
storage grows in 64-row bands without changing logical shelf dimensions;
validation compares the sampled rectangle against both backing lengths and
falls back to a full repaint if it cannot prove reuse. The full-sized batch
prototype was rejected at 67.56 MiB RSS.

Uninstrumented, same-host back-to-back strict pinned builds, unchanged three-run gate:

| Build | Startup ms | Open ms | Frame p50 ms | Frame p99 ms | Peak RSS MiB |
|---|---:|---:|---:|---:|---:|
| `f32589299` rerun | 439.34 | 495.12 | 7.47 | 55.49 | 60.71 |
| Batched uploads and banded storage | 79.51 | 81.56 | 5.45 | 19.58 | 53.55 |

All 20 independently rendered stream frames and 36 unchanged golden PNGs
matched. The strict warm-cache test passed. Latency gates still fail.

### Hosted vs local after upload batching

The only failed check at `77a7b0b6d` was the full-size [parity benchmark](https://github.com/Th0rgal/orb/actions/runs/44488424974/job/135437617003); both frame percentiles exceeded their budgets. The hosted first-frame CRC was 3085882631, local 2783534071, so use within-host comparisons for changes rather than treating one host as a substitute for the other.

| Three-run build | Startup ms | Open ms | Frame p50 ms | Frame p99 ms | Peak RSS MiB |
|---|---:|---:|---:|---:|---:|
| Hosted `77a7b0b6d` | 35.95 | 38.93 | 2.81 | 8.96 | 47.20 |
| Local strict `77a7b0b6d`, rerun | 70.39 | 81.04 | 5.76 | 19.31 | 53.74 |
| Local strict, single-run measurement + opaque strips + bounded shaping cache | 52.12 | 52.39 | 4.59 | 15.10 | 45.57 |

The first two changes reduced median layout from 1.28 to 0.66 ms and first-update raster from 14.78 to 11.98 ms in separate local traces. Intrinsic measurement avoids allocating positions for a single run; raster copies fully covered opaque interior strips while retaining the original border/corner calculations. Growing text above 128 UTF-8 bytes still goes through HarfBuzz but no longer occupies the shaping cache. The independent stream comparisons, clip/atlas fixtures, all 36 PNGs and the strict warm-cache gate passed. No m2air/WebKit comparison is implied by either Linux measurement.

## Visual gate

**Not accepted:** mean mismatch 5.86%, above 8-level channel tolerance 2.84%,
local RGB SSIM 0.9486. Only 2/36 variants have <1% differing pixels. The report
lists architectural raster/filter differences and remaining missing icons,
formatting and controls separately; these are not asserted to be approved
improvements. LeanUI stays opt-in through `scripts/orb_desktop_dev.sh --native`.
