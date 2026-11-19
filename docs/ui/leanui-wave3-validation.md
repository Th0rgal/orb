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

## Visual gate

**Not accepted:** mean mismatch 5.86%, above 8-level channel tolerance 2.84%,
local RGB SSIM 0.9486. Only 2/36 variants have <1% differing pixels. The report
lists architectural raster/filter differences and remaining missing icons,
formatting and controls separately; these are not asserted to be approved
improvements. LeanUI stays opt-in through `scripts/orb_desktop_dev.sh --native`.
