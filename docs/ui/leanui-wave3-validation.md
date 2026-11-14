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

## Visual gate

**Not accepted:** mean mismatch 5.86%, above 8-level channel tolerance 2.84%,
local RGB SSIM 0.9486. Only 2/36 variants have <1% differing pixels. The report
lists architectural raster/filter differences and remaining missing icons,
formatting and controls separately; these are not asserted to be approved
improvements. LeanUI stays opt-in through `scripts/orb_desktop_dev.sh --native`.
