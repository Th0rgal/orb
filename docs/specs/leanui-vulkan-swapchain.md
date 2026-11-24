# LeanUI Vulkan 1.3 Swapchain & Instanced GPU SDF Renderer Specification

Engineering and formal specification for Track 4 of the **Orb Desktop Craft & Hybrid LeanUI Roadmap**: migrating `LeanUI` (`lean/OrbDesktop/`) from full-frame CPU `wl_shm` presentation to a zero-copy `VK_KHR_wayland_surface` + `VK_KHR_swapchain` presentation path (Phase 1) and an instanced GPU SDF + glyph-atlas renderer (Phase 2), while preserving the strict `<= 220` LOC C-shim ceiling, zero-Rust invariant, and bit-deterministic `--headless-golden` parity pipeline.

---

## 1. Current Bottleneck Analysis (Codebase-Grounded)

### 1.1 Exact End-to-End Frame Pipeline Today

Despite loading `vkGetInstanceProcAddr` in `initVulkan` (`lean/OrbDesktop/LeanUI/Vulkan.lean:78-98`) and serializing `GpuPrimInstance` records into a 64 KiB native scratch buffer in `stageInstances` (`Vulkan.lean:122-148`), **no Vulkan instance, device, swapchain, or draw call is ever submitted**. Every live Wayland frame executes entirely on a single CPU thread and presents via full-frame `wl_shm` copies:

```text
Runtime.runWindow (LeanUI/Runtime.lean:517)
 └─ Runtime.stepFrameWithRegions (Runtime.lean:293)
     ├─ 1. Wayland.pumpEvents (LeanUI/Wayland.lean:815) -> stepEvent -> Damage accumulation
     ├─ 2. Quiescence gate: if !needsRedraw st.damage -> quiescentSkips + 1 (early return)
     ├─ 3. renderDesktopView (OrbDesktop/Main.lean:259)
     │     ├─ Text.GlyphAtlasCache.beginUploads (LeanUI/Text.lean:312)
     │     ├─ HarfBuzz shaping + FreeType rasterization into shelf-packed RGBA8 AtlasPageBuffer
     │     ├─ Layout.layoutNode + Scene.buildSceneFromLayout -> Scene (Array Prim)
     │     └─ Text.GlyphAtlasCache.finishUploads (Text.lean:315)
     ├─ 4. Vulkan.renderFrameDamage / renderFrame (LeanUI/Vulkan.lean:702, 584)
     │     ├─ changedBounds + samplesUnchanged (FFI.sameRows) + scrollBand (FFI.scrollRows)
     │     ├─ rasterizeSceneInto (Vulkan.lean:348-576): CPU SDF + C helpers
     │     │     (lean_ui_blend_rect, lean_ui_blit_glyph, lean_ui_box_axis in c/lean_ui_vulkan.c)
     │     │     -> premultiplied RGBA8 ByteArray (VulkanContext.framebuffer)
     │     └─ stageInstances (Vulkan.lean:122-148): packs 80-byte records, copies <= 65536 B to scratchPtr (unused)
     └─ 5. Wayland.present (LeanUI/Wayland.lean:669-684)
           ├─ FFI.presentArgb -> lean_ui_present_argb (c/lean_ui_vulkan.c:182-197)
           │     FULL-FRAME RGBA->BGRA swizzle into mmap'd wl_shm back buffer (bufA or bufB)
           ├─ wl_surface.attach(buf, 0, 0)                  (opcode 1)
           ├─ wp_viewport.set_destination(pendingW, pendingH) (opcode 2)
           ├─ wl_surface.damage_buffer(0, 0, bw, bh)        (opcode 9 — ALWAYS full buffer!)
           └─ wl_surface.commit()                           (opcode 6)
                └─ Wayland compositor copies entire wl_shm buffer into a GPU texture
```

### 1.2 Exact Memory Footprint & Bandwidth Cost

`WaylandClient.deviceBufferSize` (`Wayland.lean:526-527`) computes physical dimensions via `Kernel.bufferSize scale120 logical = (logical * scale120 + 119) / 120`. `ShmBuffers` (`Wayland.lean:470-481, 654-665`) allocates a single `memfd` pool of `bw * bh * 4 * 2` bytes (`bufA` and `bufB`, format `wlShmFormatArgb8888 = 0`, little-endian `B, G, R, A`), in addition to `VulkanContext.framebuffer` (`bw * bh * 4` bytes).

| Viewport / Mode | Logical | `scale120` | Device Buffer (`bw × bh`) | Pixels / Frame | 1 Frame (RGBA8) | `ShmBuffers` + `fb` RSS | Swizzle R+W / Frame (`presentArgb`) | Swizzle Write @ 120 Hz | Swizzle R+W + Compositor Upload @ 120 Hz |
| --- | --- | ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Canonical 1x | `1470 × 923` | `120` | `1470 × 923` | 1,356,810 | 5.43 MB (5.18 MiB) | 16.28 MB | 10.85 MB | 0.65 GB/s | 1.95 GB/s |
| 1080p 1x | `1920 × 1080` | `120` | `1920 × 1080` | 2,073,600 | 8.29 MB (7.91 MiB) | 24.88 MB | 16.59 MB | 1.00 GB/s | 2.99 GB/s |
| **HiDPI Retina 2x (`m2air`)** | **`1470 × 923`** | **`240`** | **`2940 × 1846`** | **5,427,240** | **21.71 MB (20.70 MiB)** | **65.13 MB** | **43.42 MB** | **2.61 GB/s** | **7.82 GB/s** |

### 1.3 Five Concrete Bottlenecks Identified in Current Code

1. **Unconditional Full-Frame CPU Swizzle & Compositor Upload (`Wayland.lean:678-683`):**
   Even when `renderFrameDamage` repaints a tiny dirty rectangle (e.g., a 16×16 sidebar spinner or single composer cursor), `Wayland.present` calls `FFI.presentArgb` across all `bw * bh * 4` bytes (`21.71 MB` at 2x Retina) and sends `wl_surface.damage_buffer(0, 0, bw, bh)`. Every single presented frame therefore forces `43.42 MB` of CPU DRAM R+W bandwidth plus a `21.71 MB` compositor SHM-to-GPU upload (`65.13 MB/frame` total transfer = `7.82 GB/s` at 120 Hz).
2. **Single-Threaded CPU Rasterization on Full-Viewport / Effect Frames (`Vulkan.lean:348-576`):**
   - `hasGlobalEffect` (`Vulkan.lean:596-599`) disables partial damage whenever a scene contains `.backdropBlur`, `.layerPush`, or `.layerPop`, forcing full-frame CPU rasterization.
   - `Prim.backdropBlur` (`Vulkan.lean:332-343`) executes 6 full-frame passes (`3 × (horizontal + vertical)` via `FFI.boxAxis`), allocating 6 transient `21.71 MB` `ByteArray`s (`130.3 MB` allocated, `260.5 MB` DRAM R+W per modal frame at 2x).
   - `Prim.layerPush` (`Vulkan.lean:388-391`) allocates a full-viewport `21.71 MB` zeroed `ByteArray` per nesting level and composites pixel-by-pixel in interpreted/compiled Lean loops (`Vulkan.lean:399-412`).
   - `Prim.shadow` (`Vulkan.lean:477-495`) allocates a halo mask buffer and runs 6-pass `blurBackdrop` on CPU, then loops per pixel in Lean.
3. **No Frame Pacing or Buffer-Release Synchronization (`Wayland.lean:255, 480, 676`):**
   `Wayland.lean:255` defines `tagFrameCallback := 13` and resolves `wl_callback_interface`, but `wl_surface.frame` (opcode 3) is **never marshaled**. `ShmBuffers` also toggles `frontIsB := !shm.frontIsB` without listening for `wl_buffer.release`, risking overwriting a buffer still being sampled by the compositor during scroll or stream bursts.
4. **Silent 64 KiB SSBO Truncation (`Vulkan.lean:88, 146`):**
   `initVulkan` hardcodes `scratchCap := 65536` (`819` instances at 80 B/instance). `stageInstances` silently skips `FFI.memWrite` when `buf.size > scratchCap`. Realistic transcript views emit 1,500–6,000 primitives (`120–480 KiB`).
5. **Existing `Vulkan.lean` ↔ `shaders/scene_sdf.glsl` Contract Divergences:**
   - `stageInstances` (`Vulkan.lean:126-141`) packs `dst`, `uv`, `clip`, and `radii` as **32-bit integers** (`Int32`/`UInt32`), whereas `shaders/scene_sdf.glsl:16-22` declares them as **IEEE-754 `vec4` floats** — reading raw integer bits as floats yields denormals/garbage.
   - `Prim.rrect` (`Vulkan.lean:425-430`) emits only `kind = 0` with `aux0 = bt` (dropping per-side borders `(bt, br, bb, bl)` and border color).
   - `Prim.linear` (`Vulkan.lean:432-437`) emits `kind = 0` with `aux0 = c1`; `scene_sdf.glsl` has no gradient branch.
   - `Prim.shadow` (`Vulkan.lean:463-469`) passes `dst := expanded` to the shader, causing `scene_sdf.glsl:82,99` to compute `sdRoundedBox` against the *expanded* box rather than the casting rect `r`.
   - `Prim.mask` (`Vulkan.lean:541-546`) passes `aux0 = pageIdx`, while `scene_sdf.glsl:28` binds a single `sampler2D uAtlas` and ignores `aux0`.

---

## 2. Target GPU Architecture (Two-Phase Design)

Both phases sit behind a unified `RenderBackend` abstraction owned by `VulkanContext`, keeping `LeanUI.Runtime`, `LeanUI.Layout`, `LeanUI.Scene`, and `OrbDesktop.*` backend-agnostic.

```text
                    ┌──────────────────────────────────────────┐
                    │         LeanUI.Runtime / Scene           │
                    │  (Single-owner state, Damage, Atlas)     │
                    └────────────────────┬─────────────────────┘
                                         │
           ┌─────────────────────────────┼──────────────────────────────┐
           ▼                             ▼                              ▼
  [CPU Reference + wl_shm]    [Phase 1: vkPresent]          [Phase 2: vkInstanced]
  --headless / --headless-    --gpu=present /               --gpu / ORB_LEANUI_GPU=1
  golden* / ORB_LEANUI_GPU=0  ORB_LEANUI_GPU=present        (default on verified HW ICDs)
           │                             │                              │
  rasterizeSceneInto          rasterizeSceneInto (dirty)    GpuPrimInstance SSBO (80B)
           │                             │                  + dirty atlas sub-uploads
  FFI.presentArgb (21.7MB)    vkCmdCopyBufferToImage2       + shaders/scene_sdf.glsl (SPV)
           │                  (dirty rect ONLY -> persistent+ layer targets + box-blur comp
  wl_shm double buffer        GPU backing RGBA8 image)                  │
                              -> vkCmdBlitImage2 (GPU       vkCmdBeginRendering (VK 1.3)
                                 RGBA->BGRA swizzle)                    │
                              -> VkSwapchainKHR             -> VkSwapchainKHR
                              -> vkQueuePresentKHR          -> vkQueuePresentKHR
                                 (+ VK_KHR_incremental_present) (+ VK_KHR_incremental_present)
```

### 2.1 Phase 1: Zero-Copy GPU Present & Swapchain (`VK_KHR_wayland_surface` + `VK_KHR_swapchain`)

Phase 1 eliminates the `21.71 MB` CPU byte-swizzle and compositor SHM upload while keeping the already-verified CPU rasterizer (`rasterizeSceneInto`) unchanged as the pixel generator.

#### 2.1.1 Instance, Surface, Device & Format Selection
1. **Instance Extensions:** `VK_KHR_surface`, `VK_KHR_wayland_surface` (optional: `VK_EXT_debug_utils` when `ORB_LEANUI_VK_VALIDATION=1`).
   - `VkApplicationInfo.apiVersion = VK_API_VERSION_1_3` (`(1 << 22) | (3 << 12)`).
2. **Surface Creation:** `vkCreateWaylandSurfaceKHR(instance, &{ sType = VK_STRUCTURE_TYPE_WAYLAND_SURFACE_CREATE_INFO_KHR, display = wl.display, surface = wl.window.surface }, NULL, &surface)`.
   - `lean_ui_wayland.c:20-21` already uses `wl_display_prepare_read` / `wl_display_read_events`, which safely coexists with Mesa WSI's private Wayland event queue.
3. **Physical Device Selection:**
   - Filter devices supporting Vulkan >= 1.3, `VK_KHR_swapchain`, and a queue family with `VK_QUEUE_GRAPHICS_BIT | VK_QUEUE_TRANSFER_BIT` plus `vkGetPhysicalDeviceWaylandPresentationSupportKHR(phys, qfi, wl.display) == VK_TRUE` and `vkGetPhysicalDeviceSurfaceSupportKHR == VK_TRUE`.
   - Score preference: `INTEGRATED_GPU` / `DISCRETE_GPU` > `VIRTUAL_GPU` > `CPU` (Lavapipe).
   - **Software ICD policy:** If the only available ICD has `deviceType == VK_PHYSICAL_DEVICE_TYPE_CPU` (e.g. Lavapipe), **automatically fall back to `wl_shm`** in interactive sessions unless `ORB_LEANUI_GPU=lavapipe` (or `--gpu-readback` in CI tests) is explicitly set. Running CPU rasterization + software Vulkan swapchain adds latency with zero hardware benefit.
4. **Device Extensions & Vulkan 1.3 Features:**
   - Required: `VK_KHR_swapchain`.
   - Required Vulkan 1.3 core features: `synchronization2 = VK_TRUE`, `dynamicRendering = VK_TRUE` (Phase 2).
   - Optional (queried at device creation): `VK_KHR_incremental_present`, `VK_KHR_push_descriptor`, `VK_KHR_maintenance6`.
5. **Surface Format (`*_UNORM`, NEVER `*_SRGB`):**
   - `LeanUI.Vulkan.blendOver` (`Vulkan.lean:200-210`) performs Porter-Duff `SRC_OVER` in **sRGB-encoded 8-bit space** to match Chromium/WebKit/SolidJS.
   - Format priority list:
     1. `VK_FORMAT_B8G8R8A8_UNORM` + `VK_COLOR_SPACE_SRGB_NONLINEAR_KHR` (universal on Wayland/Mesa/NVIDIA).
     2. `VK_FORMAT_R8G8B8A8_UNORM` + `VK_COLOR_SPACE_SRGB_NONLINEAR_KHR` (eliminates swizzle even on direct copy).
     3. Reject `*_SRGB` formats (hardware sRGB encoding on write would break blending and golden parity); if no `*_UNORM` 8-bit format exists, fall back to `wl_shm`.
6. **Composite Alpha:**
   - Prefer `VK_COMPOSITE_ALPHA_PRE_MULTIPLIED_BIT_KHR` when live window effects use translucent chrome (`clearColor = 0x00000000` in `OrbDesktop/Main.lean:341`), matching `wl_shm` premultiplied ARGB8888 (`RepaintCheck.lean:9-17`).
   - Fall back to `VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR` if the compositor does not advertise `PRE_MULTIPLIED` (forcing opaque `pal.canvas` clear).

#### 2.1.2 Present Mode Evaluation & `wl_surface.frame` Pacing

| Present Mode | Latency | Tearing | Power / Burst Behavior | Policy in LeanUI |
| --- | --- | --- | --- | --- |
| `VK_PRESENT_MODE_MAILBOX_KHR` | Lowest (1 vblank, newest frame wins) | None | Drops superseded frames without stalling CPU; requires `minImageCount >= 3`. Can waste GPU/CPU work if unpaced. | **Preferred when available**, paired with `wl_surface.frame` pacing so we render at most once per compositor repaint cycle while avoiding `vkAcquireNextImageKHR` stalls during resize/occlusion. |
| `VK_PRESENT_MODE_FIFO_KHR` | 1–2 vblanks | None | Always supported (spec-mandated). Blocks in `vkAcquireNextImageKHR` or `vkQueuePresentKHR` when swapchain is full or surface is occluded/minimized unless gated by `wl_surface.frame`. | **Universal default fallback** when `MAILBOX` is unavailable; strictly gated by `wl_surface.frame` so occluded windows never wedge the Wayland input loop. |
| `VK_PRESENT_MODE_IMMEDIATE_KHR` | Lowest | Yes (tears) | Uncapped frame rate. | **Disabled in normal use.** Allowed only when `ORB_LEANUI_PRESENT_MODE=immediate` during raw throughput benchmarks (`--bench`). |

**`wl_surface.frame` Pacing Protocol:**
- Wire `wl_surface.frame` (opcode 3, signature `"n"`, interface `wl_callback`, `tagFrameCallback = 13` already reserved in `Wayland.lean:255`).
- Add `frameCallbackPending : Bool` to `WaylandClient`:
  - When a frame is about to be presented (and `!frameCallbackPending`), request `wl_surface.frame` on `wl_surface` immediately **before** `vkQueuePresentKHR` (so Mesa WSI's `wl_surface.commit` inside `vkQueuePresentKHR` commits the frame callback atomically with the new buffer!).
  - Do **not** call `wl_surface.commit()` manually on the Vulkan path — `vkQueuePresentKHR` owns the commit.
  - While `frameCallbackPending == true`, `Runtime.runWindow` continues pumping input/live-stream events and coalescing `Damage` (`Damage.add`), deferring the next render+present until `wl_callback.done` (opcode 0, `tagFrameCallback`) arrives and clears `frameCallbackPending := false`.
  - When `needsRedraw st.damage == false` upon `wl_callback.done`, **do not request another frame callback** — the loop goes completely quiescent (`0` redraws, `0%` idle CPU).
  - Safety watchdog: if a compositor withholds `wl_callback.done` (occluded/minimized window), input & `xdg_toplevel.configure` events still wake `poll()` immediately because `vkAcquireNextImageKHR` is never called while `frameCallbackPending == true`.

#### 2.1.3 Zero-CPU-Swizzle Partial-Damage Upload (Phase 1)
Because a Vulkan swapchain rotates across 2–3 distinct `VkImage`s whose contents are undefined/stale after presentation, Phase 1 maintains **one persistent device-local backing image** (`VK_FORMAT_R8G8B8A8_UNORM`, `TRANSFER_DST | TRANSFER_SRC`) plus a ring of `MAX_FRAMES_IN_FLIGHT = 2` persistently mapped `HOST_VISIBLE | HOST_COHERENT` staging buffers:
1. CPU `renderFrameDamage` produces the updated RGBA8 pixels inside `dirtyRect` (`dx, dy, dw, dh`).
2. Copy **only the `dw × dh × 4` bytes of `dirtyRect`** (not `21.71 MB`!) into the active staging buffer (`bufferRowLength = 0`, tightly packed rows via a strided row write). For a 400×40 streaming text line at 2x, this copies **64 KB** instead of **21.71 MB** (**339× less CPU memory traffic**).
3. Record into the frame's command buffer:
   - `vkCmdPipelineBarrier2`: transition backing image to `TRANSFER_DST_OPTIMAL`.
   - `vkCmdCopyBufferToImage2`: upload `dirtyRect` from staging buffer into the persistent `R8G8B8A8_UNORM` backing image.
   - `vkCmdPipelineBarrier2`: transition backing image -> `TRANSFER_SRC_OPTIMAL`, acquired swapchain image (`UNDEFINED`) -> `TRANSFER_DST_OPTIMAL`.
   - `vkCmdBlitImage2` (1:1 nearest filter) from persistent `R8G8B8A8_UNORM` backing image to swapchain `B8G8R8A8_UNORM` image (the GPU performs the RGBA→BGRA channel swizzle in hardware during the copy; if swapchain format is `R8G8B8A8_UNORM`, use `vkCmdCopyImage2`).
   - `vkCmdPipelineBarrier2`: transition swapchain image -> `PRESENT_SRC_KHR`.
4. Submit via `vkQueueSubmit2` and present via `vkQueuePresentKHR` (chaining `VkPresentRegionsKHR` with `dirtyRect` when `VK_KHR_incremental_present` is enabled).

#### 2.1.4 Resize, Fractional Scaling & `wp_viewporter` Interaction
- `wp_fractional_scale_v1.preferred_scale` (`Wayland.lean:724-728`) updates `scale120`; `xdg_toplevel.configure` (`Wayland.lean:717-721`) updates `(pendingW, pendingH)`; `xdg_surface.configure` (`Wayland.lean:696-701`) acks the serial and emits `Event.resize`.
- Desired swapchain extent is `WaylandClient.deviceBufferSize = (bufferSize scale120 pendingW, bufferSize scale120 pendingH)`, clamped to `surfaceCaps.minImageExtent .. surfaceCaps.maxImageExtent` (note: on Wayland, `surfaceCaps.currentExtent` is `(0xFFFFFFFF, 0xFFFFFFFF)`, meaning the client chooses the extent).
- **Fractional scale attachment rule:** Before `vkQueuePresentKHR`, issue `wp_viewport.set_destination(pendingW, pendingH)` (opcode 2, `Wayland.lean:681`) whenever `(pendingW, pendingH)` changed since the last present. Because `wp_viewport` state is double-buffered on `wl_surface`, Mesa WSI's `wl_surface.commit` inside `vkQueuePresentKHR` applies the swapchain buffer (`bw × bh`) and logical destination (`pendingW × pendingH`) atomically in the same Wayland commit — zero stretched-frame glitches during resize or monitor hot-plug.
- **Swapchain recreation triggers:**
  1. `(bw, bh) != swapchain.extent` (logical resize or `scale120` change).
  2. `vkAcquireNextImageKHR` returns `VK_ERROR_OUT_OF_DATE_KHR` (recreate immediately before drawing; skip presenting stale frame).
  3. `vkQueuePresentKHR` returns `VK_ERROR_OUT_OF_DATE_KHR` or `VK_SUBOPTIMAL_KHR` (mark `swapchainDirty := true` so the next frame recreates cleanly; do not drop the already-presented frame on `SUBOPTIMAL_KHR`).
- **Zero-extent guard:** If `bw == 0 || bh == 0` (minimized/unmapped), destroy or defer swapchain creation and suspend rendering until a non-zero configure arrives.
- **Swapchain recreation sequence:** `vkDeviceWaitIdle` -> recreate `VkSwapchainKHR` passing `oldSwapchain := prevSwapchain` -> `vkDestroySwapchainKHR(prevSwapchain)` -> resize persistent backing image / image views / per-image `renderFinished` semaphores -> mark full viewport damage (`markFullDamage`).

#### 2.1.5 Graceful Fallback Matrix (`wl_shm`)
Fallback to `Wayland.present` (`wl_shm`) is automatic, silent-safe (logged once in `VulkanContext.fallbackReason`), and never crashes startup when any of the following holds:
- `--headless`, `--headless-golden`, `--headless-golden-all`, `--self-test`, or `--verify-repaint` (unless `--gpu-readback` is explicitly requested).
- `ORB_LEANUI_GPU=0` or `--no-gpu`.
- `dlopen("libvulkan.so.1")` returns `0` or `vkCreateInstance` fails.
- No Vulkan 1.3 physical device supports `VK_KHR_wayland_surface` + `VK_KHR_swapchain` + `*_UNORM` format.
- Only a CPU software ICD (`VK_PHYSICAL_DEVICE_TYPE_CPU`, e.g., Lavapipe) is present and `ORB_LEANUI_GPU` is not set to `lavapipe` / `force`.
- Unrecoverable `VK_ERROR_DEVICE_LOST` at runtime -> tear down Vulkan handles, set `backend := .cpuShm`, allocate `ShmBuffers` on next `Wayland.present`, and mark full damage.

---

### 2.2 Phase 2: Instanced GPU SDF + Glyph Atlas Rendering

Phase 2 retires CPU rasterization on live GPU sessions by executing the `Scene` directly in a Vulkan 1.3 dynamic-rendering pass using `shaders/scene_sdf.glsl` (compiled to SPIR-V) and GPU-resident glyph atlas textures.

#### 2.2.1 Unified 80-Byte `GpuPrimInstance` Contract (Fixing Current Divergences)
Keep the 80-byte `std430` stride (`5 × 16 B`, cache-line friendly), but align `Vulkan.lean:stageInstances` and `shaders/scene_sdf.glsl` on **exact integer geometry fields** so Lean avoids float conversion and both CPU/GPU consume identical integer pixel coordinates:

```glsl
struct PrimInstance {
    ivec4 dstRect;     // (x, y, w, h) in device pixels (exact integer match to LeanUI.Rect)
    ivec4 uvRect;      // (u, v, uw, vh) in atlas texels; for kind=1 (rrect border): (bt, br, bb, bl)
    ivec4 clipRect;    // (cx, cy, cw, ch) axis-aligned scissor in device pixels
    uvec4 radii;       // (tl, tr, br, bl) in device pixels
    uvec4 packedColor; // .x = 0xRRGGBBAA (primary color)
                       // .y = kind (0..7) | (roundedClipIdx << 8)
                       // .z = aux0 (borderColor / c1 / blurSigma / atlasPageIdx)
                       // .w = aux1 (layerAlpha[7:0] | angleDeg[23:8] | flags[31:24])
};
```

| `kind` | `LeanUI.Prim` Source | `uvRect` Meaning | `packedColor.x` | `aux0` (`packedColor.z`) | `aux1` (`packedColor.w`) |
| --- | --- | --- | --- | --- | --- |
| `0` | `.quad` / `.rrect` fill | unused `(0,0,0,0)` | `fill` (`0xRRGGBBAA`) | unused | `layerAlpha` |
| `1` | `.quad` / `.rrect` border | `(bt, br, bb, bl)` per-side widths | `borderCol` | unused | `layerAlpha` |
| `2` | `.shadow` | unexpanded casting rect `(rx, ry, rw, rh)` while `dstRect` is `expanded` | `shadowCol` | `blur` (px) | `layerAlpha` |
| `3` | `.glyph (isColor=false)` / `.mask` | atlas `(u, v, w, h)` | `color` | `pageIdx` (`0..7`) | `layerAlpha` |
| `4` | `.glyph (isColor=true)` | atlas `(u, v, w, h)` | `color` (alpha mod) | `pageIdx` (`0..7`) | `layerAlpha` |
| `5` | `.image` | source `(u, v, w, h)` | tint `0xFFFFFFFF` | `texSlot` | `layerAlpha` |
| `6` | `.linear` | unused | `c0` | `c1` | `layerAlpha \| (angleDeg << 8)` |
| `7` | `layerPop` composite | layer source `(x0, y0, w, h)` | `0xFFFFFFFF` | `layerSlot` | `opacity` (`0..255`) |

**Dynamic SSBO Ring:** Replace the fixed `65536`-byte `scratchPtr` cap with a per-frame-in-flight (`2×`) persistently mapped `VK_BUFFER_USAGE_STORAGE_BUFFER_BIT` buffer starting at **1 MiB** (`13,107` instances) and growing by 2× (up to 16 MiB) on demand, destroying the old buffer only after its fence retires.

#### 2.2.2 Shader Compilation & Embedding
- Compile `shaders/scene_sdf.glsl` (vertex + fragment stages via `-DVERTEX_SHADER` / `-DFRAGMENT_SHADER`) and `shaders/blur_box.comp.glsl` (separable box blur for `.backdropBlur` and exact `.shadow` mode) at **build time** via `glslangValidator -V --target-env vulkan1.3` (or `glslc`) into deterministic SPIR-V word arrays checked into `lean/OrbDesktop/LeanUI/Shaders.lean` (verified up-to-date in CI).
- Runtime creates `VkShaderModule` directly from the embedded `ByteArray` — **zero runtime dependency on `glslang`, `shaderc`, or filesystem shader paths**.

#### 2.2.3 Premultiplied Blending State
The fragment shader outputs **premultiplied RGBA** (`vec4(rgb * effA, effA)` for straight-alpha primitives and `vec4(tex.rgb * effA, tex.a * effA)` or `vec4(tex.rgb * modA, tex.a * modA)` for premultiplied color glyphs / layer composites), and the graphics pipeline configures:
- `srcColorBlendFactor = VK_BLEND_FACTOR_ONE`, `dstColorBlendFactor = VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA`, `colorBlendOp = VK_BLEND_OP_ADD`
- `srcAlphaBlendFactor = VK_BLEND_FACTOR_ONE`, `dstAlphaBlendFactor = VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA`, `alphaBlendOp = VK_BLEND_OP_ADD`

This single blend state handles straight-alpha SDF shapes, R8 glyph masks, premultiplied BGRA emoji, and `layerPop` offscreen layer composites in one pipeline without pipeline rebinds.

#### 2.2.4 Dirty Glyph Atlas Page Uploads (`Text.lean` Integration)
`GlyphAtlasCache` (`LeanUI/Text.lean:291-325`) already brackets per-frame glyph mutations with `beginUploads` / `finishUploads` and accumulates `pendingUploads : Array (Nat × Rect × RasterizedGlyph)`!
- Extend `GlyphAtlasCache` with `gpuDirtyRects : Array (Nat × Rect)` and `generation : UInt64` (incremented on `resetAll`):
  - `finishUploads` preserves the newly blitted `(pageIdx, rect)` entries into `gpuDirtyRects` (consumed and cleared after GPU submission).
  - For each atlas page `p` (`1024 × 1024` `VK_FORMAT_R8G8B8A8_UNORM`, `VK_IMAGE_TILING_OPTIMAL`, up to `MAX_ATLAS_PAGES = 8` bound as `sampler2D uAtlas[8]` in descriptor set 0 binding 1, with `VK_FILTER_NEAREST` for crisp 1:1 texel sampling):
    - Lazily create the GPU `VkImage` + `VkImageView` when `p >= gpuPages.size`.
    - On `generation` change (`resetAll`), clear/re-upload active rows; otherwise upload **only the `(rect.w × rect.h × 4)` sub-region** for each entry in `gpuDirtyRects` via staging buffer + `vkCmdCopyBufferToImage2`, followed by a single `vkCmdPipelineBarrier2` (`TRANSFER_WRITE` -> `FRAGMENT_SHADER_READ`, `TRANSFER_DST_OPTIMAL` -> `SHADER_READ_ONLY_OPTIMAL`).
  - Typical steady-state frame (warm glyph cache): **0 bytes uploaded**. Streaming turn with 20 new glyphs: **~12 KiB uploaded** (vs 4 MiB whole-page upload).
  - Note: Also fix `Vulkan.lean:502` / `Text.lean:507` so color glyphs allocated on `page > 0` carry `pageIdx` in `Prim.glyph` (or `.mask` color flag) instead of hardcoding `pages[0]`.

#### 2.2.5 Hierarchical Clipping (`clipPush`, `clipPushRounded`, `clipPop`)
1. **Axis-aligned `clipPush` / `clipPop`:**
   - Maintained on Lean's `clipStack` during `Scene` -> `GpuPrimInstance` lowering (exact `intersectRect` intersection).
   - Stored per instance in `inst.clipRect` (for per-fragment clipping) **and** emitted as hardware `vkCmdSetScissor` across contiguous draw batches sharing the same scissor rect to avoid fragment-shader invocation outside clipped scroll viewports.
2. **Rounded `clipPushRounded r radii`:**
   - Maintain a flat per-frame `ClipNode` SSBO (binding 2, 32 bytes/node: `ivec4 rect`, `uvec4 radii`, plus `int parentIdx` packed or 48 bytes/node; max depth 8).
   - Each instance encodes its active `roundedClipIdx` in `packedColor.y >>> 8` (`0` = no rounded clip).
   - In the fragment shader, while `clipIdx != 0`, walk the parent chain (at most 8 steps, typically 1), evaluate `sdRoundedBox` against each rounded clip rect, multiply coverage by `clamp(0.5 - dClip, 0.0, 1.0)`, and discard if `0`.
   - Zero extra render passes, no stencil buffer required, exact anti-aliased nested rounded clips. (CPU reference `Vulkan.lean:383` should apply the identical `sdfRoundedRect16` clip coverage so CPU and GPU stay in parity.)

#### 2.2.6 Offscreen Layers (`layerPush`/`layerPop`) & `backdropBlur`
A `Scene` is lowered into an ordered list of **Render Passes** (typically 1 pass when no `layerPush`/`backdropBlur` is present; N+1 passes when modals or opacity groups appear):
1. **Pooled Offscreen Layer Targets:** Maintain a small pool (depth up to 4) of `VK_FORMAT_R8G8B8A8_UNORM` `VkImage`s (`COLOR_ATTACHMENT | SAMPLED | STORAGE`), sized to the viewport (or rounded up to 256-px buckets to avoid reallocating on every resize).
2. **`layerPush opacity`:**
   - Flush current instanced draw batch (`vkCmdDraw(4, batchCount, 0, batchStart)`).
   - End current dynamic rendering pass (`vkCmdEndRendering`), transition layer target `L[depth]` to `COLOR_ATTACHMENT_OPTIMAL`, clear only `curClip` (`renderArea = curClip`, `clearColor = (0,0,0,0)`), and `vkCmdBeginRendering` targeting `L[depth]`.
3. **`layerPop`:**
   - Flush layer batch, `vkCmdEndRendering`, barrier `L[depth]` (`COLOR_ATTACHMENT_WRITE` -> `FRAGMENT_SHADER_READ`, `SHADER_READ_ONLY_OPTIMAL`).
   - Resume parent target (`loadOp = VK_ATTACHMENT_LOAD_OP_LOAD`) and emit a single `kind = 7` quad over `top.clip` sampling `L[depth]` modulated by `top.opacity / 255.0`.
4. **`backdropBlur sigma`:**
   - Flush current batch, `vkCmdEndRendering`, barrier target -> `GENERAL` / `SHADER_READ_ONLY_OPTIMAL`.
   - Dispatch `shaders/blur_box.comp.glsl` (16×16 workgroups, or separable 1D workgroups matching `blurBackdrop`'s exact radii `[sigma - 1, sigma - 1, sigma]` in `uint32` fixed-point arithmetic across ping-pong transient images).
   - Copy/write blurred result back to the active target and resume rendering (`LOAD_OP_LOAD`). At 2940×1846, 6 separable GPU passes take **~0.4–0.9 ms** on Apple M2 Honeykrisp vs **~35–60 ms** on CPU.

#### 2.2.7 Partial Damage on GPU (`VK_KHR_incremental_present` vs Backing Target)
Unlike single-buffered CPU `framebuffer`, a Vulkan swapchain cycles through `N` (`2` or `3`) images whose prior contents are `(N-1)` frames old:
- **Strategy A (Default for Phase 2 — Full-Scene Instanced Redraw + `VK_KHR_incremental_present`):**
  - Re-render the full scene directly into the acquired swapchain image (`LOAD_OP_CLEAR` with `clearColor`) in a single instanced `vkCmdDraw(4, N_inst, 0, 0)` pass (`~0.2–0.6 ms` on hardware GPUs for 2,000–6,000 quads/glyphs), while still passing the exact `dirtyRect` from `RuntimeState.damage` via `VkPresentRegionsKHR` (`VK_KHR_incremental_present`) so the Wayland compositor only recomposites the changed region.
  - Zero buffer-age complexity, zero extra GPU memory for a full-size persistent backing target, and always immune to swapchain image rotation artifacts.
- **Strategy B (Optional Scissor-Damaged Persistent Backing Target):**
  - Available behind `ORB_LEANUI_GPU_PARTIAL=1` for low-power integrated GPUs on huge static scenes: render only `changedBounds` with `LOAD_OP_LOAD` + `vkCmdSetScissor(dirtyRect)` onto a persistent `R8G8B8A8_UNORM` image, then `vkCmdBlitImage2` / `vkCmdCopyImage2` (dirty rect or full) to the swapchain image. Only enabled when `!hasGlobalEffect scene`.

---

## 3. Strict `<= 220` LOC C Shim & Zero-Rust Architecture

### 3.1 Current Shim Inventory & CI Constraints

Repository CI enforces **zero `.rs` files** and **`<= 220` LOC per `.c` shim** (`.github/workflows/ci.yml:163-172`, `.github/workflows/kernel-abi.yml:225-266`, `lean/OrbDesktop/c/lean_ui.h:5-6`). Every `@[extern]` symbol in `LeanUI.FFI` must also be allowlisted in `lean/OrbDesktop/turbo-lean.toml` (generated by `scripts/gen_turbo_lean_ffi.py`).

| C File | Current LOC | Headroom to 220 | Role |
| --- | ---: | ---: | --- |
| `lean/OrbDesktop/c/lean_ui_vulkan.c` | **218** | **2 LOC** | CPU raster helpers (`blit_glyph`, `blend_rect`, `scroll_rows`, `same_rows`, `icon_mask`, `box_axis`, `present_argb`) + generic `dl_sym`, `call` (6 args), `mem_{alloc,free,write,read}` |
| `lean/OrbDesktop/c/lean_ui_wayland.c` | **218** | **2 LOC** | Wayland wire bridge + XKB + `memfd` |
| `lean/OrbDesktop/c/lean_ui_text.c` | 198 | 22 LOC | Fontconfig + FreeType + HarfBuzz |
| `lean/OrbDesktop/c/lean_ui_sidebar.c` | 37 | 183 LOC | Embedded GTK sidebar bridge |

Because `lean_ui_vulkan.c` is at **218/220 LOC**, **no new functions may be added to `lean_ui_vulkan.c`**.

### 3.2 Complete Vulkan 1.3 Entry-Point & ABI Argument Audit

`lean_ui_call` (`lean_ui_vulkan.c:152-164`) invokes `typedef uint64_t (*fn6_t)(uint64_t, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t)`. On LP64 Linux (`x86_64` SysV and `aarch64` AAPCS64 — all Wayland targets), pointers, `VkFlags`, `uint32_t`, `VkDeviceSize`, and both dispatchable and non-dispatchable `VkHandle`s are passed in general-purpose integer registers (`rdi..r9` / `x0..x5`).

| Vulkan 1.3 Entry Point | Arg Count | Return Type | Fits `call6`? | Notes |
| --- | ---: | --- | :---: | --- |
| `vkGetInstanceProcAddr` / `vkGetDeviceProcAddr` | 2 | `PFN` (ptr) | Yes | Only `vkGetInstanceProcAddr` uses `dlSym` |
| `vkCreateInstance` / `vkDestroyInstance` | 3 / 2 | `VkResult` / `void` | Yes | `pAllocator = 0` (`NULL`) |
| `vkEnumeratePhysicalDevices` / `vkGetPhysicalDeviceProperties` | 3 / 2 | `VkResult` / `void` | Yes | |
| `vkGetPhysicalDeviceQueueFamilyProperties` / `MemoryProperties` | 3 / 2 | `void` | Yes | |
| `vkGetPhysicalDeviceWaylandPresentationSupportKHR` | 3 | `VkBool32` | Yes | |
| `vkGetPhysicalDeviceSurface{Support,Capabilities,Formats,PresentModes}KHR` | 3–4 | `VkResult` | Yes | |
| `vkCreateWaylandSurfaceKHR` / `vkDestroySurfaceKHR` | 4 / 3 | `VkResult` / `void` | Yes | |
| `vkCreateDevice` / `vkDestroyDevice` / `vkGetDeviceQueue` | 4 / 2 / 4 | `VkResult` / `void` | Yes | |
| `vkCreateSwapchainKHR` / `vkDestroySwapchainKHR` / `vkGetSwapchainImagesKHR` | 4 / 3 / 4 | `VkResult` / `void` | Yes | |
| `vkAcquireNextImageKHR` (or `vkAcquireNextImage2KHR`) | **6** (or 3) | `VkResult` | Yes | All integer/u64/ptr |
| `vkQueueSubmit2` / `vkQueuePresentKHR` / `vkDeviceWaitIdle` | 4 / 2 / 1 | `VkResult` | Yes | Vulkan 1.3 `Submit2` avoids 5+ args |
| `vkCreate/Destroy{CommandPool,Fence,Semaphore,Buffer,Image,ImageView,Sampler,ShaderModule}` | 3–4 | `VkResult` / `void` | Yes | |
| `vkAllocateMemory` / `vkFreeMemory` / `vkMapMemory` / `vkUnmapMemory` | 4 / 3 / **6** / 2 | `VkResult` / `void` | Yes | |
| `vkAllocateCommandBuffers` / `vkBeginCommandBuffer` / `vkEndCommandBuffer` / `vkResetCommandBuffer` | 2–3 | `VkResult` | Yes | |
| `vkWaitForFences` / `vkResetFences` | 5 / 3 | `VkResult` | Yes | |
| `vkCreateDescriptorSetLayout` / `vkCreatePipelineLayout` / `vkCreateDescriptorPool` / `vkAllocateDescriptorSets` / `vkUpdateDescriptorSets` | 3–5 | `VkResult` / `void` | Yes | |
| `vkCreateGraphicsPipelines` / `vkCreateComputePipelines` | **6** | `VkResult` | Yes | |
| `vkCmdBeginRendering` / `vkCmdEndRendering` (Vulkan 1.3) | 2 / 1 | `void` | Yes | Eliminates `VkRenderPass` & `VkFramebuffer` |
| `vkCmdPipelineBarrier2` / `vkCmdCopyBufferToImage2` / `vkCmdCopyImageToBuffer2` / `vkCmdBlitImage2` / `vkCmdCopyImage2` (Vulkan 1.3) | 2 | `void` | Yes | Eliminates 10-arg `vkCmdPipelineBarrier` |
| `vkCmdBindPipeline` / `vkCmdSetViewport` / `vkCmdSetScissor` / `vkCmdDraw` / `vkCmdDispatch` | 3–5 | `void` | Yes | |
| `vkCmdPushConstants` | **6** | `void` | Yes | |
| `vkCmdPushDescriptorSetKHR` (`VK_KHR_push_descriptor`) | **6** | `void` | Yes | Optional extension |
| **`vkCmdBindDescriptorSets`** | **8** | **`void`** | **NO (> 6 args)** | Needs `call8` or `VK_KHR_push_descriptor` / `vkCmdBindDescriptorSets2` (`maintenance6`) |

**Three ABI Hazards in Relying Exclusively on `lean_ui_call`:**
1. **`vkCmdBindDescriptorSets` takes 8 arguments** — if a Vulkan 1.3 ICD lacks both `VK_KHR_push_descriptor` and `VK_KHR_maintenance6`, `call6` cannot bind descriptor sets at all.
2. **Strict-C11 `void` function-pointer cast UB:** `lean_ui_call` casts `void`-returning `vkCmd*` / `vkDestroy*` pointers to `uint64_t (*)(...)`. While tolerated by GCC/Clang on x86_64/aarch64 without sanitizers, `-fsanitize=cfi-icall` / UBSan rejects mismatched return types.
3. **Sub-rect strided upload efficiency:** Copying a dirty rect `(dx, dy, dw, dh)` from `VulkanContext.framebuffer` (`ByteArray`) into a mapped staging buffer via per-row `FFI.memWrite` incurs `dh` Lean `ByteArray.extract` allocations (`1,846` allocations at 2x height) unless a single zero-allocation `lean_ui_mem_write_rect` helper performs the strided `memcpy` in C.

### 3.3 Recommended Shim Design: Dedicated `c/lean_ui_vk_bridge.c` (`<= 120` LOC)

Compare the two architectural options:

| Criterion | Option A (Recommended): Thin Call/Copy Bridge `c/lean_ui_vk_bridge.c` (`~90` LOC) | Option B: C WSI Wrapper `c/lean_ui_vk_swapchain.c` (`~215` LOC) |
| --- | --- | --- |
| Build dependencies | **Zero** (`#include <lean/lean.h>` only; no `libvulkan-dev` headers required in `lakefile.lean` or Nix!) | Requires `<vulkan/vulkan_core.h>` + `<vulkan/vulkan_wayland.h>` (`libvulkan-dev`) |
| Ownership of Vulkan state machine & struct packing | **100% Lean** (`LeanUI/VulkanSwapchain.lean` — testable, auditable, matches `LeanUI/Wayland.lean` design) | Split between C and Lean |
| LOC headroom | `~90 / 220` LOC (130 LOC margin) | `~210 / 220` LOC (fragile margin) |
| Solves `vkCmdBindDescriptorSets` (8 args), `void` UB, & strided upload | **Yes** | Yes |

**Exact Proposed Symbol List for `lean/OrbDesktop/c/lean_ui_vk_bridge.c` (~90 LOC, strictly `<= 220` LOC):**

```c
/* 1. Typed void-returning call bridge (0..8 integer/pointer args, 64-byte ByteArray) — zero C11 return-type UB. */
lean_obj_res lean_ui_vk_call_void8(size_t fn, b_lean_obj_arg args, lean_obj_arg w);

/* 2. Typed int32_t (VkResult) call bridge (0..8 integer/pointer args) — returns sign-extended int64 / UInt32 VkResult. */
lean_obj_res lean_ui_vk_call_res8(size_t fn, b_lean_obj_arg args, lean_obj_arg w);

/* 3. Zero-allocation strided rectangle copy from a Lean RGBA8 ByteArray into mapped VkDeviceMemory staging pointer.
 *    Packs `rows` rows of `rowBytes` starting at byte offset `srcOff` with stride `srcStride` tightly into `dstPtr`. */
lean_obj_res lean_ui_vk_copy_rect(size_t dstPtr, b_lean_obj_arg src, size_t srcOff,
                                  size_t srcStride, size_t rowBytes, size_t rows, lean_obj_arg w);

/* 4. Zero-allocation bulk copy of native memory -> ByteArray for GPU readback verification.
 *    (Reuses existing lean_ui_mem_read when stride == rowBytes; adds strided unpack if rowPitch > rowBytes.) */
lean_obj_res lean_ui_vk_read_rect(size_t srcPtr, size_t srcStride, size_t rowBytes, size_t rows, lean_obj_arg w);
```

**LP64 Struct Layout Safety (Lean-side):**
All Vulkan structs packed in `LeanUI/VulkanStructs.lean` target LP64 little-endian (`x86_64` and `aarch64` Linux), with an explicit unit test (`tests/VkStructAbiCheck.c`, compiled only in CI tests, not linked into the binary) asserting `sizeof` and `offsetof` against `<vulkan/vulkan.h>` for every struct Lean serializes (`VkInstanceCreateInfo`, `VkWaylandSurfaceCreateInfoKHR`, `VkDeviceCreateInfo`, `VkSwapchainCreateInfoKHR`, `VkRenderingInfo`, `VkSubmitInfo2`, `VkPresentInfoKHR`, `VkPresentRegionsKHR`, `VkImageMemoryBarrier2`, `VkBufferImageCopy2`, `VkImageBlit2`, `VkGraphicsPipelineCreateInfo`). Any struct mismatch fails CI immediately before runtime.

**Build & Governance Registration Checklist for `c/lean_ui_vk_bridge.c`:**
1. Add `lean_ui_vk_bridge_o` target to `lean/OrbDesktop/lakefile.lean` (`-std=c11 -O2 -Wall -Wextra -Werror -fPIC`) and link into `liblean_ui_c`.
2. Add the 4 `@[extern]` declarations to `lean/OrbDesktop/LeanUI/FFI.lean` and regenerate `lean/OrbDesktop/turbo-lean.toml` via `python3 scripts/gen_turbo_lean_ffi.py`.
3. Add all `lean/OrbDesktop/c/lean_ui_*.c` files (including `lean_ui_vk_bridge.c`) to the `<= 220` LOC loop in `.github/workflows/ci.yml:168`.

---

## 4. Formal Invariants & `--headless-golden` Determinism Guarantee

### 4.1 Strict Backend Isolation & Mode Selection

The deterministic CPU reference rasterizer (`Vulkan.rasterizeSceneInto`) remains the **sole authority** for golden PNG generation, SolidJS parity checks (`scripts/leanui_parity.py`), and `OrbDesktop.RepaintCheck` / `OrbDesktop.Spec.RasterParity`.

| CLI Flag / Env Var | Effective Backend | Allowed in `--headless-golden*`? |
| --- | --- | --- |
| `--headless`, `--headless-golden`, `--headless-golden-all`, `--self-test`, `--verify-repaint` | **Always `cpuReference`** (ignores `ORB_LEANUI_GPU=1`) | Yes (forced) |
| `--no-gpu` or `ORB_LEANUI_GPU=0` | `cpuShm` (`wl_shm` double buffer) | N/A |
| `--gpu=present` or `ORB_LEANUI_GPU=present` | Phase 1 `vkPresent` (auto-fallback to `cpuShm`) | N/A |
| `--gpu` or `ORB_LEANUI_GPU=1` (or `=instanced`) | Phase 2 `vkInstanced` (auto-fallback `vkPresent` -> `cpuShm`) | N/A |
| `ORB_LEANUI_GPU=lavapipe` | Enables `vkPresent`/`vkInstanced` on `VK_PHYSICAL_DEVICE_TYPE_CPU` | N/A |
| `--gpu-readback <out_dir>` (CI differential test flag only) | Offscreen Vulkan `TRANSFER_SRC` readback -> PNG | Dedicated parity harness only (never overwrites canonical CPU goldens) |

### 4.2 Differential Parity Harness & Exact Channel Delta Bounds

To prove that Phase 1 and Phase 2 match the deterministic CPU reference across all 36 canonical screens (`9 screens × 2 themes × 2 scales` at `1470×923` 1x and `2940×1846` 2x):

1. **Offscreen Vulkan Readback Mode (`--gpu-readback`):**
   - Creates a `VK_FORMAT_R8G8B8A8_UNORM` offscreen target with `VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT` (no Wayland display required — runs headless in CI!).
   - Renders each of the 36 canonical scenes through the exact same Phase 1 / Phase 2 command-buffer builder used for swapchain frames.
   - Copies the rendered image to a `HOST_VISIBLE | HOST_CACHED` buffer via `vkCmdCopyImageToBuffer2`, invalidates mapped memory, and encodes via `Vulkan.encodeRGBA8ToPNG`.
2. **Differential Comparison (`scripts/leanui_parity.py`):**
   Compares `--headless-golden-all <cpu_dir>` against `--gpu-readback <gpu_dir>` across all 36 pairs on:
   - **CI (`ubuntu-24.04` / `uruk`)**: Mesa Lavapipe Vulkan 1.3 + `VK_LAYER_KHRONOS_validation` (zero validation errors required).
   - **`m2air`**: Apple M2 Asahi / Mesa Honeykrisp Vulkan 1.3.
   - **`dgx-spark`**: NVIDIA proprietary Vulkan 1.3 ICD.
3. **Exact Rounding Rules & Per-Primitive Max Channel Delta Bounds (`Δ = max_{c ∈ {R,G,B,A}} |cpu_c - gpu_c|`):**

| Primitive / Path | CPU Reference Rule (`Vulkan.lean`) | GPU Rule (`scene_sdf.glsl` / Pipeline) | Exact Tolerance Gate |
| --- | --- | --- | --- |
| **Phase 1 (`vkPresent`) all primitives** | `rasterizeSceneInto` RGBA8 | `vkCmdCopyBufferToImage2` + `vkCmdBlitImage2` (1:1 nearest `UNORM`) | **`max Δ = 0` (100% bit-exact across all 36 goldens)** |
| **Phase 2 solid opaque pixel-aligned `.quad` / `.rrect` (`fa == 255`, `radii == 0`)** | Constant-color scanline copy | `cov = 1.0`, `out = baseColor` | **`max Δ = 0` (bit-exact)** |
| **Phase 2 alpha-blended interior & R8/BGRA8 `.glyph` / `.mask`** | `blendOver`: `(c*a + d*(255-a) + 127) / 255` | IEEE-754 fp32 premul blend -> hardware `UNORM8` round-to-nearest-even | **`max Δ <= 1` LSB** (differs only on exact `.5` half-way tie-breaking; `>= 99.5%` pixels exact) |
| **Phase 2 SDF rounded corners & `.rrect` borders** | `sdfRoundedRect16`: `1/16`-px fixed-point `isqrt`, `cov = ((8 - d16) * 255) / 16` | `sdRoundedBox`: fp32 `length()`, `cov = clamp(0.5 - d, 0.0, 1.0)` | **`max Δ <= 2` LSB** on 1-px AA corner arc (`0` on straight edges/interior) |
| **Phase 2 `.backdropBlur`** | `blurBackdrop`: 3-pass separable box blur `[σ-1, σ-1, σ]`, `(sum + w/2) / w` | `blur_box.comp.glsl` using exact `uint32` sliding sum `(sum + r) / (2*r + 1)` | **`max Δ = 0` (bit-exact)** in `uint32` compute shader (`<= 1` LSB if fp32) |
| **Phase 2 `.shadow`** | 3-pass separable box blur of rounded-rect mask (`sigma = blur / 2`) | **Preferred:** same `blur_box.comp.glsl` over shadow halo (`max Δ <= 1` LSB). **Fast path:** Evan Wallace analytical erf-box approximation (`max Δ <= 3` LSB) | **`max Δ <= 1` LSB** (box-blur path) or **`<= 3` LSB** (analytical path) |
| **Overall 36-Golden GPU-vs-CPU CI Gate** | All 36 screens (`1x` + `2x`, `dark` + `light`) | Same 36 scenes via `--gpu-readback` | **`0` pixels with `Δ > 3`**, **`> tol(2)` < 0.05%**, **min `SSIM >= 0.9995`**, **repeat determinism `36/36` pixel-identical on same ICD** |

### 4.3 Formal State-Machine Invariants (`LeanUI/Spec/SwapchainSpec.lean`)

The swapchain & synchronization state machine is modeled as a pure Lean 4 kernel (`0 import Lean`, `0 sorryAx`) matching the proof structure of `LeanUI/Spec/DamageSpec.lean` and `LeanUI/Spec/AtlasSpec.lean`, with theorems checked by `turbo-lean --json audit-spec` (`vacuous_specs == 0`, `trivial_specs == 0`):

```lean
inductive SwapchainPhase where
  | uninitialized
  | ready (extentW extentH : Nat) (imageCount : Nat)
  | suspendedZeroExtent
  | needsRecreate (extentW extentH : Nat)
  | deviceLostFallbackShm
  | destroyed

inductive ImageSlotState where
  | available
  | acquired (frameSlot : Fin 2)
  | submitted (frameSlot : Fin 2)
```

Five mandatory invariants proved over `SwapchainState`:

1. **Acquire/Present Pairing & Bounded In-Flight Conservation (`ConservedResource`):**
   - At all times, `count(slot ∈ images | slot != available) <= min(MAX_FRAMES_IN_FLIGHT, imageCount)` (`MAX_FRAMES_IN_FLIGHT = 2`).
   - Every `vkAcquireNextImageKHR` returning `SUCCESS` or `SUBOPTIMAL_KHR` transitions `images[imgIdx]` from `available -> acquired(slot)` and requires either a matching `vkQueuePresentKHR` (`acquired -> submitted -> available` on next acquire/wait) or `recreate`/`destroy` (`vkDeviceWaitIdle`, resetting all slots to `available`).
   - **No-deadlock fence rule:** `vkResetFences(f[slot])` is executed **strictly after** `vkAcquireNextImageKHR` succeeds and immediately before `vkQueueSubmit2` — NEVER before `vkAcquireNextImageKHR`. If acquire returns `VK_ERROR_OUT_OF_DATE_KHR`, `f[slot]` remains signaled so the next frame's `vkWaitForFences` cannot deadlock.
2. **Semaphore Ownership Disjointness (`ScopedAuthority`):**
   - `imageAvailable[slot]` is indexed by `frameSlot : Fin 2` (protected by `inFlightFence[slot]`).
   - `renderFinished[imgIdx]` is indexed by **`swapchainImageIndex : Fin imageCount`** (NOT `frameSlot`!), preventing the Vulkan spec violation where `vkQueueSubmit2` re-signals a `renderFinished` semaphore still queued in the presentation engine when `imageCount >= 3`.
3. **Resize-in-Flight & Zero-Extent Recovery:**
   - `phase = ready w h n` implies `w > 0 ∧ h > 0 ∧ n >= 2`.
   - Whenever `(bw, bh) != (w, h)` or `OUT_OF_DATE_KHR` occurs, presentation is forbidden until `recreate` completes (`vkDeviceWaitIdle`, pass `oldSwapchain`, destroy `oldSwapchain` unconditionally even if `vkCreateSwapchainKHR` fails).
   - Whenever `bw == 0 ∨ bh == 0`, transition to `suspendedZeroExtent` (no `vkCreateSwapchainKHR` with zero extent, which is invalid Vulkan usage).
4. **Strict Teardown Order & Zero-UAF (`StickyFence`):**
   - Lifecycle ordering invariant:
     $$\text{destroy}(\text{pipelines, buffers, images, sync}) \prec \text{vkDestroySwapchainKHR} \prec \text{vkDestroyDevice} \prec \text{vkDestroySurfaceKHR} \prec \text{vkDestroyInstance} \prec \text{wl\_display\_disconnect}$$
   - `lifetime(wl_display) > lifetime(VkSurfaceKHR)` and `lifetime(wl_surface) > lifetime(VkSurfaceKHR)`.
   - `Runtime.shutdownRuntime` (`Runtime.lean:571-581`) already invokes `Vulkan.shutdownVulkan` before `Wayland.closeWindow`; `SwapchainSpec` makes `destroyed` an absorbing state (`StickyFence`) so no GPU call or Wayland present can fire after shutdown.
5. **Quiescence Preservation (`DamageSpec.redraw_iff_dirty`):**
   - When `needsRedraw st.damage = false`, `SwapchainState` is untouched (`acquireCount`, `submitCount`, `presentCount` unchanged; `quiescentSkips` increments by 1).

---

## 5. Measured Benchmark & Rollout Plan

### 5.1 Benchmark Suite (Extending `--bench` & `scripts/bench_desktop.sh`)

Extend `OrbDesktop/Main.lean:runDesktopBench` (`Main.lean:521-585`) and `scripts/bench_desktop.sh` with five reproducible scenarios, each emitting structured JSON and verified with `error_count == 0` and `quiescent_redraws == 0`:

| Scenario ID | Viewport & Scale | Workload | Primary Metric | Target Budget (p50 / p99) |
| --- | --- | --- | --- | --- |
| `1080p_1x` | `1920 × 1080` @ `scale120=120` | 20 full + 20 partial transcript frames | Frame time + upload bytes | **p50 < 2.0 ms / p99 < 4.0 ms** |
| `hidpi_2x` | `2940 × 1846` (`1470×923` @ `scale120=240`) | 20 full + 20 partial Retina frames (dark & light) | Frame time + MB/s transfer | **p50 < 4.0 ms / p99 < 8.33 ms** |
| `scroll_burst_120hz` | `2940 × 1846` @ `scale120=240` | 120 consecutive wheel scroll ticks on 500-line diff + markdown transcript | Sustained 120 Hz pacing & dropped frames | **p50 < 3.5 ms / p99 < 8.33 ms** (0 missed vblanks @ 120 Hz) |
| `stream_markdown_turn` | `2940 × 1846` @ `scale120=240` | 60 coalesced streaming markdown deltas (`Orb.Stream.Coalescer`) + syntax code blocks | Partial damage + glyph atlas upload bytes | **p50 < 2.5 ms / p99 < 6.0 ms**, atlas upload < 16 KiB/frame |
| `resize_storm` | `900×600` ↔ `2940×1846`, scales `120, 150, 180, 240` | 60 rapid `xdg_toplevel.configure` + `preferred_scale` transitions | Swapchain recreate time + RSS delta | **Recreate < 16 ms**, **0 validation errors**, **0 leaked handles**, RSS delta < 4 MiB |

Global non-regression gates (preserving `scripts/bench_desktop.sh:145-153`):
- **Cold startup (`cold_ms`):** `<= 60 ms` on `wl_shm`; Vulkan device/pipeline init amortized/cached (`VkPipelineCache` persisted in `$XDG_CACHE_HOME/orb-desktop/vk_pipeline.cache`) so warm Vulkan startup stays `<= 80 ms`.
- **Steady-state RSS:** `<= 64 MiB` hard ceiling (`<= 45 MiB` target at 1x).
- **Idle CPU / Quiescence:** `0.0%` CPU and `0` submits when quiescent (`framesRendered` frozen, `quiescentSkips` advancing).

### 5.2 Instrumentation Counters (`RuntimeState` & `VulkanContext`)

Add lightweight monotonic counters (zero allocations on the hot path; dumped in `--bench` JSON and `ORB_U7_PROFILE=1` stderr lines):

- **`VulkanContext` (`lean/OrbDesktop/LeanUI/Vulkan.lean`):**
  - `backend : RenderBackend` (`cpuShm | vkPresent | vkInstanced`)
  - `icdName : String` and `presentMode : UInt32`
  - `fallbackReason : Option String`
  - `swapchainRecreates : Nat`
  - `lastAcquireNs : UInt64`, `lastUploadNs : UInt64`, `lastSubmitNs : UInt64`, `lastPresentNs : UInt64`
  - `lastUploadBytes : Nat` (Phase 1 dirty-rect staging bytes), `lastAtlasUploadBytes : Nat`, `lastSsboBytes : Nat`
- **`RuntimeState` (`lean/OrbDesktop/LeanUI/Runtime.lean`):**
  - `presentCount : Nat`
  - `frameCallbackSkips : Nat` (frames coalesced while waiting for `wl_callback.done`)
  - `lastFrameTotalNs : UInt64`

### 5.3 Target Hardware & CI Verification Matrix

| Host / Environment | Architecture & OS | Vulkan ICD / Compositor | Role in Rollout |
| --- | --- | --- | --- |
| **`m2air`** | `aarch64` NixOS, Apple M2 (16 GB) | Mesa **Honeykrisp** (Asahi Vulkan 1.3), HiDPI `2940×1846` @ 2x Wayland | Primary interactive target: HiDPI 2x latency, 120 Hz scroll burst, `wp_fractional_scale_v1` + `wp_viewporter`, power/idle check |
| **`uruk` / GitHub Actions CI** | `x86_64` Ubuntu 24.04 | Mesa **Lavapipe** (Vulkan 1.3 software ICD) + `VK_LAYER_KHRONOS_validation` + headless Weston | Mandatory PR CI gate: `SwapchainSpec` Lean proof audit, `VkStructAbiCheck`, zero validation errors, 36-golden `--gpu-readback` vs `--headless-golden-all` differential parity |
| **`dgx-spark`** | `aarch64` Ubuntu (20 cores, 119 GB) | **NVIDIA** proprietary Vulkan 1.3 ICD | Native `aarch64` build host + discrete-GPU validation (`MAILBOX` vs `FIFO`, `VK_KHR_incremental_present`, `resize_storm`, 36-golden NVIDIA readback parity) |

### 5.4 Phased Rollout & Kill-Switch Plan

1. **Stage 0 — Foundations & Parity Fixes (Low Risk):**
   - Wire `wl_surface.frame` (`tagFrameCallback = 13`) + `wl_buffer.release` on `wl_shm` (immediately eliminates over-submission even before Vulkan).
   - Fix `shaders/scene_sdf.glsl` ↔ `Vulkan.lean` `PrimInstance` `ivec4`/`uvec4` layout, `Prim.shadow` unexpanded rect, `Prim.rrect` borders, `Prim.linear`, and `Prim.mask` multi-page indexing; add `c/lean_ui_vk_bridge.c` (`<= 120` LOC) + `VkStructAbiCheck` + `LeanUI/Spec/SwapchainSpec.lean`.
2. **Stage 1 — Phase 1 (`vkPresent`) Opt-In & Validation:**
   - Land `VK_KHR_wayland_surface` + `VK_KHR_swapchain` + dirty-rect GPU upload/blit behind `--gpu=present` / `ORB_LEANUI_GPU=present`.
   - Gate merge on: `0` validation errors on Lavapipe CI, `0`-LSB bit-exact parity across all 36 goldens (`--gpu-readback`), and measured `hidpi_2x` p50/p99 improvement on `m2air` & `dgx-spark`.
3. **Stage 2 — Phase 2 (`vkInstanced`) Opt-In & Differential Parity Gate:**
   - Land precompiled SPIR-V `scene_sdf.glsl` + `blur_box.comp.glsl`, dynamic SSBO ring, dirty atlas sub-uploads, rounded clip SSBO, and pooled offscreen layers behind `--gpu` / `ORB_LEANUI_GPU=1`.
   - Gate merge on: 36-golden differential parity (`max Δ <= 3`, `SSIM >= 0.9995`) on Lavapipe CI + `m2air` Honeykrisp + `dgx-spark` NVIDIA, plus `scroll_burst_120hz` p99 `< 8.33 ms`.
4. **Stage 3 — Default-On for Hardware Vulkan 1.3 ICDs:**
   - Flip default on live Wayland sessions to `vkInstanced` when a hardware Vulkan 1.3 ICD is detected (automatic `wl_shm` fallback for headless, Lavapipe, or missing ICD).
   - Retain `ORB_LEANUI_GPU=0` / `--no-gpu` as a permanent instant kill switch and keep `--headless-golden*` permanently pinned to the deterministic CPU reference rasterizer.
