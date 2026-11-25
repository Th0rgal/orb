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
5. **Existing `Vulkan.lean` ↔ Repo-Root `shaders/scene_sdf.glsl` Contract & CPU Parity Divergences:**
   - `stageInstances` (`Vulkan.lean:126-141`) packs `dst`, `uv`, `clip`, and `radii` as **32-bit integers** (`Int32`/`UInt32`), whereas repo-root `shaders/scene_sdf.glsl:16-22` declares them as **IEEE-754 `vec4` floats** — reading raw integer bits as floats yields denormals/garbage.
   - `Prim.rrect` (`Vulkan.lean:425-430`) emits only `kind = 0` with `aux0 = bt` (dropping per-side borders `(bt, br, bb, bl)` and border color).
   - `Prim.linear` (`Vulkan.lean:432-449`) ignores `_angle` on CPU (hardcoding vertical top-to-bottom interpolation) and emits `kind = 0` with `aux0 = c1`; `shaders/scene_sdf.glsl` has no gradient branch.
   - `Prim.shadow` (`Vulkan.lean:463-469`) passes `dst := expanded` to the shader, causing `shaders/scene_sdf.glsl:82,99` to compute `sdRoundedBox` against the *expanded* box rather than the casting rect `r`.
   - Production text shaping (`OrbDesktop/Main.lean:88-131` `shapeDesktopRuns` → `LeanUI/Layout.lean:10-23` `ShapedGlyph` → `LeanUI/Scene.lean:179-205` `emitWrappedLineGlyphs` → `Prim.glyph`) drops `entry.page`, and `Vulkan.lean:502, 686` hardcodes `atlas.pages[0]?`. Meanwhile `Prim.mask` (`Vulkan.lean:541-546`) passes `aux0 = pageIdx`, while `shaders/scene_sdf.glsl:28` binds a single `sampler2D uAtlas` and ignores `aux0`.
   - CPU `Prim.layerPop` (`Vulkan.lean:402-412`) and CPU color glyph blitting (`c/lean_ui_vulkan.c:28-31` `colored = 1` and `Vulkan.lean:525-533`) pass already-premultiplied RGB into straight-alpha `blendOver`, causing double-premultiplication on semi-transparent layers and color emoji edges.

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
7. **Swapchain `imageUsage` & Format Feature Verification:**
   - Query `surfaceCaps.supportedUsageFlags` (`vkGetPhysicalDeviceSurfaceCapabilitiesKHR`) and optimal tiling format features (`vkGetPhysicalDeviceFormatProperties`).
   - **Required `VkSwapchainCreateInfoKHR.imageUsage`:** `VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT` (all checked as a subset of `surfaceCaps.supportedUsageFlags`), plus verifying `VK_FORMAT_FEATURE_BLIT_DST_BIT` (required for Phase 1 `vkCmdBlitImage2` RGBA→BGRA swizzle and Phase 2 `backdropBlur` blit-back) and `VK_FORMAT_FEATURE_BLIT_SRC_BIT` (required for Phase 2 `backdropBlur` blit-out).
   - **Never** request `VK_IMAGE_USAGE_STORAGE_BIT` on swapchain images (not guaranteed for `B8G8R8A8_UNORM` or Wayland WSI).
   - If the surface lacks `TRANSFER_SRC_BIT` (needed only by `backdropBlur` blit-out in Phase 2), Phase 1 may proceed with `COLOR_ATTACHMENT_BIT | TRANSFER_DST_BIT`; if `TRANSFER_DST_BIT` or `VK_FORMAT_FEATURE_BLIT_DST_BIT` (or `COLOR_ATTACHMENT_BIT` for Phase 2 direct rendering) is missing, fall back cleanly to the internal `R8G8B8A8_UNORM` backing target (or `wl_shm`).

#### 2.1.2 Present Mode Evaluation & `wl_surface.frame` Pacing

| Present Mode | Latency | Tearing | Power / Burst Behavior | Policy in LeanUI |
| --- | --- | --- | --- | --- |
| `VK_PRESENT_MODE_MAILBOX_KHR` | Lowest (1 vblank, newest frame wins) | None | Drops superseded frames without stalling CPU; requires `minImageCount >= 3`. Can waste GPU/CPU work if unpaced. | **Preferred when available**, paired with `wl_surface.frame` pacing so we render at most once per compositor repaint cycle while avoiding `vkAcquireNextImageKHR` stalls during resize/occlusion. |
| `VK_PRESENT_MODE_FIFO_KHR` | 1–2 vblanks | None | Always supported (spec-mandated). Blocks in `vkAcquireNextImageKHR` or `vkQueuePresentKHR` when swapchain is full or surface is occluded/minimized unless gated by `wl_surface.frame`. | **Universal default fallback** when `MAILBOX` is unavailable; strictly gated by `wl_surface.frame` so occluded windows never wedge the Wayland input loop. |
| `VK_PRESENT_MODE_IMMEDIATE_KHR` | Lowest | Yes (tears) | Uncapped frame rate. | **Disabled in normal use.** Allowed only when `ORB_LEANUI_PRESENT_MODE=immediate` during raw throughput benchmarks (`--bench-wsi`). |

**`wl_surface.frame` Pacing Protocol & `wl_callback` Proxy Lifecycle:**
- Wire `wl_surface.frame` (opcode 3, signature `"n"`, interface `wl_callback`, `tagFrameCallback = 13` already reserved in `Wayland.lean:255`).
- **`wl_proxy_destroy` (NEVER `WL_MARSHAL_FLAG_DESTROY`):** `wl_callback` has **zero client requests** (`method_count == 0` in `wl_callback_interface`). Calling `wl_proxy_marshal_array_flags` with `WL_MARSHAL_FLAG_DESTROY` emits an invalid opcode and crashes the client with Wayland `EPROTO`; conversely, leaving completed or abandoned `wl_callback` proxies alive leaks client-side `wl_proxy` objects and object IDs on every frame.
  - Resolve `wl_proxy_destroy` via `FFI.dlSym "libwayland-client.so.0" "wl_proxy_destroy"` in `Wayland.openWindow` (stored as `fnProxyDestroy : USize` on `WindowHandles`).
  - Track `frameCallbackProxy : USize := 0` and `frameCallbackPending : Bool := false` on `WaylandClient` (invariant: `frameCallbackPending == (frameCallbackProxy != 0)`), with a single helper `cancelFrameCallback` that invokes `wl_proxy_destroy(frameCallbackProxy)` when non-zero and resets both fields.
- **Request placement:** When a frame is about to be presented (and `!frameCallbackPending`), marshal `wl_surface.frame` immediately **before** `vkQueuePresentKHR` (recording the returned proxy in `frameCallbackProxy` and setting `frameCallbackPending := true`) so Mesa WSI's `wl_surface.commit()` inside `vkQueuePresentKHR` commits the frame callback atomically with the new buffer. Do **not** call `wl_surface.commit()` manually on the Vulkan path — `vkQueuePresentKHR` owns the commit.
- **Four mandatory `wl_callback` destroy/clear sites:**
  1. **`wl_callback.done` (opcode 0, `tagFrameCallback = 13`) in `Wayland.stepWireEvent`:** Call `wl_proxy_destroy(ev.proxy)`; if `ev.proxy == st.frameCallbackProxy`, reset `frameCallbackProxy := 0` and `frameCallbackPending := false`.
  2. **Non-`VK_SUCCESS` / non-`VK_SUBOPTIMAL_KHR` return from `vkQueuePresentKHR`:** When `vkQueuePresentKHR` returns `VK_ERROR_OUT_OF_DATE_KHR`, `VK_ERROR_SURFACE_LOST_KHR`, or `VK_ERROR_DEVICE_LOST`, Mesa WSI aborts the `wl_surface.commit()`, so the compositor will never receive or fire the pending `wl_callback`. Immediately call `cancelFrameCallback` so rendering cannot permanently deadlock.
  3. **`xdg_surface.configure` (opcode 0, `tagXdgSurface`) in `Wayland.stepWireEvent` (`Wayland.lean:696-701`):** Because `stepWireEvent` eagerly sends `xdg_surface.ack_configure(serial)` immediately upon configure, tiling compositors and unminimize transitions wait for a subsequent surface commit before delivering `wl_callback.done`. `xdg_surface.configure` MUST invoke `cancelFrameCallback` and bypass `frameCallbackPending` for resize/configure commits so an acked configure never wedges tiling resize or unminimize.
  4. **`Wayland.closeWindow` (`Wayland.lean:687-690`):** Invoke `cancelFrameCallback` before `wl_display_disconnect`.
- **Quiescence & anti-busy-spin rule in `Runtime.runWindow` (`Runtime.lean:527-568`):**
  - While `frameCallbackPending == true` (and no pending `xdg_surface.configure` bypass is active), `Runtime.runWindow` continues pumping Wayland input/configure events and live-stream mailbox updates, coalescing `Damage` (`Damage.add`), and defers rendering + `vkAcquireNextImageKHR` until `wl_callback.done` arrives.
  - **Busy-spin prevention:** Currently `Runtime.lean:565` gates waiting on `else if rt.running && !workPending rt.app then ...`. Whenever redraw is deferred solely because `frameCallbackPending == true`, `Runtime.runWindow` **MUST still block via `timedWait`** (sleeping on the Wayland fd + `wakeFd` in `withWindowWait`, even when `workPending rt.app == true`) rather than spinning at 100% CPU until `wl_callback.done` or a `wakeFd`/configure event arrives.
  - When `needsRedraw st.damage == false` upon `wl_callback.done`, **do not request another frame callback** — the loop goes completely quiescent (`0` redraws, `0%` idle CPU).
  - Occluded/minimized safety: if a compositor withholds `wl_callback.done`, input and `xdg_toplevel.configure` / `xdg_surface.configure` events still wake `poll()` immediately because `vkAcquireNextImageKHR` is never called while `frameCallbackPending == true`.

#### 2.1.3 Zero-CPU-Swizzle Partial-Damage Upload (Phase 1)
Because a Vulkan swapchain rotates across 2–3 distinct `VkImage`s whose contents are undefined/stale after presentation, Phase 1 maintains **one persistent device-local backing image** (`VK_FORMAT_R8G8B8A8_UNORM`, `TRANSFER_DST | TRANSFER_SRC`) plus a ring of `MAX_FRAMES_IN_FLIGHT = 2` persistently mapped `HOST_VISIBLE | HOST_COHERENT` staging buffers:

- **Authoritative Dirty-Rect Tracking (`VulkanContext.lastUploadedDirtyRect`):**
  `Vulkan.renderFrameDamage` (`Vulkan.lean:702-753`) ignores the caller's `dirty` argument after checking `fullDamage`, recomputes the actual mutated region via `changedBounds vp prev.scene scene`, may shift an entire `band` via `scrollBand` + `FFI.scrollRows` (`Vulkan.lean:735-739`), falls back to full `renderFrame` on **5 branches** (`previousPaint == none`, `fullDamage || dimension/clear/size mismatch || hasGlobalEffect`, `changedBounds == none`, `prev.pages.size != atlas.pages.size`, and `!samplesUnchanged`), and can return early when `dirty.w == 0 || dirty.h == 0`. Furthermore, `Runtime.stepFrameWithRegions` (`Runtime.lean:338`) clears `st.damage := none` *before* returning to `Runtime.runWindow` (`Runtime.lean:562-564`). Reading `st.damage` or the caller's `dirty` rect at present time would therefore silently corrupt pixels or skip uploads.
  - Add **`lastUploadedDirtyRect : Option Rect := none`** directly to `VulkanContext`:
    - `renderFrame` (`Vulkan.lean:584`) sets `lastUploadedDirtyRect := some { x := 0, y := 0, w := ctx.width, h := ctx.height }` (covering all 5 fallback branches automatically).
    - `renderFrameDamage` (`Vulkan.lean:702`) sets `lastUploadedDirtyRect := none` on the empty-dirty early return (`dirty.w == 0 || dirty.h == 0`), and `lastUploadedDirtyRect := some clipped` (where `clipped := intersectRect vp dirty`, with `dirty` returned by `changedBounds`) on normal partial frames. Because `scrollBand` constrains `band` and the repainted tail `paint` to lie inside `dirty`, `clipped` conservatively encloses **every** pixel modified by both `FFI.scrollRows` and `rasterizeSceneInto`.
  - Phase 1's staging upload and `VkPresentRegionsKHR` **MUST read exclusively from `ctx.lastUploadedDirtyRect`** (never from `RuntimeState.damage`). Whenever swapchain recreation allocates or resets the persistent backing image, force a full-viewport upload (`fullViewport`) on the next present regardless of `lastUploadedDirtyRect`.

- **Bounded Chunked/Tiled Staging Upload (RSS Ceiling Compliance):**
  At 2x HiDPI (`2940×1846`), two full-frame staging buffers would cost `43.42 MiB` on top of CPU `framebuffer` (`21.71 MiB`), threatening the steady-state RSS ceiling. Cap each per-frame staging buffer at **4 MiB** (`8 MiB` total across `MAX_FRAMES_IN_FLIGHT = 2`):
  1. Let `uploadRect` be `ctx.lastUploadedDirtyRect` (or `fullViewport` after backing-image creation/resize). If `uploadRect == none` or empty, skip the staging copy (if no configure/recreate commit is required, skip presenting altogether).
  2. When `uploadRect.w * uploadRect.h * 4 <= stagingCap` (all typical partial-damage frames — e.g. a 400×40 streaming text line at 2x is **64 KiB**, **339× less** than `21.71 MB`), copy `uploadRect` in one `lean_ui_vk_copy_rect` call (`bufferRowLength = 0`) and emit one `vkCmdCopyBufferToImage2`.
  3. When `uploadRect.w * uploadRect.h * 4 > stagingCap` (e.g. a full-viewport 2x frame of `21.71 MB`), split `uploadRect` into horizontal **row strips** of `stripH = max 1 (stagingCap / (uploadRect.w * 4))` rows, submitting chunked `lean_ui_vk_copy_rect` + `vkCmdCopyBufferToImage2` transfers (waiting on the transfer fence between chunks or using a single synchronous chunk loop during full-frame refreshes) so staging memory never exceeds `8 MiB` total.
  4. Record into the frame's command buffer:
     - `vkCmdPipelineBarrier2`: transition backing image to `TRANSFER_DST_OPTIMAL`.
     - `vkCmdCopyBufferToImage2`: upload `uploadRect` (or strip) from staging buffer into the persistent `R8G8B8A8_UNORM` backing image.
     - `vkCmdPipelineBarrier2`: transition backing image -> `TRANSFER_SRC_OPTIMAL`, acquired swapchain image (`UNDEFINED`) -> `TRANSFER_DST_OPTIMAL`.
     - `vkCmdBlitImage2` (1:1 nearest filter) from persistent `R8G8B8A8_UNORM` backing image to swapchain `B8G8R8A8_UNORM` image (the GPU performs the RGBA→BGRA channel swizzle in hardware during the copy; if swapchain format is `R8G8B8A8_UNORM`, use `vkCmdCopyImage2`).
     - `vkCmdPipelineBarrier2`: transition swapchain image -> `PRESENT_SRC_KHR`.
  5. Submit via `vkQueueSubmit2` and present via `vkQueuePresentKHR` (chaining `VkPresentRegionsKHR` with `uploadRect` when `VK_KHR_incremental_present` is enabled).

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
Fallback to `Wayland.present` (`wl_shm`) is automatic, silent-safe (logged once in `VulkanContext.fallbackReason`), tears down any partially created Vulkan handles in reverse lifecycle order (Invariant 4), and never crashes startup when any of the following holds:
- `--headless`, `--headless-golden`, `--headless-golden-all`, `--self-test`, `--verify-repaint`, or `--gtk-sidebar-host` (unless `--gpu-readback` is explicitly requested).
- `ORB_LEANUI_GPU=0` or `--no-gpu`.
- `dlopen("libvulkan.so.1")` returns `0`, `vkCreateInstance` fails, or **`vkCreateWaylandSurfaceKHR`**, **`vkCreateDevice`**, or **`vkCreateSwapchainKHR`** returns a non-success `VkResult` (e.g., headless Weston running `--renderer=pixman` in `leanui-parity.yml:161` where Wayland WSI swapchain creation is unsupported).
- No Vulkan 1.3 physical device supports `VK_KHR_wayland_surface` + `VK_KHR_swapchain` + `*_UNORM` format + required `imageUsage` / `VK_FORMAT_FEATURE_BLIT_DST_BIT`.
- Only a CPU software ICD (`VK_PHYSICAL_DEVICE_TYPE_CPU`, e.g., Lavapipe) is present and `ORB_LEANUI_GPU` is not set to `lavapipe` / `force`.
- Unrecoverable `VK_ERROR_DEVICE_LOST` at runtime -> cancel any pending `frameCallbackProxy`, tear down Vulkan handles (`vkDeviceWaitIdle` if valid, then destroy in reverse order), set `backend := .cpuShm`, allocate `ShmBuffers` on next `Wayland.present`, and mark full damage.

---

### 2.2 Phase 2: Instanced GPU SDF + Glyph Atlas Rendering

Phase 2 retires CPU rasterization on live GPU sessions by executing the `Scene` directly in a Vulkan 1.3 dynamic-rendering pass using repo-root `shaders/scene_sdf.glsl` and `shaders/blur_box.comp.glsl` (compiled to SPIR-V) and GPU-resident glyph atlas textures. On the Phase 2 `vkInstanced` path, `VulkanContext.framebuffer` remains `ByteArray.empty` (`0` bytes, never allocated except in `--gpu-readback` PNG export) and `previousPaint` stays `none` (skipping `PaintSnapshot` retention), immediately reclaiming `>= 21.71 MiB` of CPU heap at 2x HiDPI.

#### 2.2.1 Unified 80-Byte `GpuPrimInstance` Contract & Pipeline Geometry
Keep the 80-byte `std430` stride (`5 × 16 B`, cache-line friendly), but align `Vulkan.lean:stageInstances` and repo-root `shaders/scene_sdf.glsl` on **exact integer geometry fields** so Lean avoids float conversion and both CPU/GPU consume identical integer pixel coordinates:

```glsl
struct PrimInstance {
    ivec4 dstRect;     // (x, y, w, h) in device pixels (exact integer match to LeanUI.Rect)
    ivec4 uvRect;      // (u, v, uw, vh) in source texels; for kind=1 (rrect border): (bt, br, bb, bl)
    ivec4 clipRect;    // (cx, cy, cw, ch) axis-aligned scissor in device pixels
    uvec4 radii;       // (tl, tr, br, bl) in device pixels
    uvec4 packedColor; // .x = 0xRRGGBBAA (primary color)
                       // .y = kind (0..7) | (roundedClipIdx << 8)
                       // .z = aux0 (borderColor / c1 / blurSigma / atlasPageIdx / layerSlot / texSlot)
                       // .w = aux1 (layerAlpha[7:0] | angleDeg[23:8] | flags[31:24])
};
```

| `kind` | `LeanUI.Prim` Source | `uvRect` Meaning | `packedColor.x` | `aux0` (`packedColor.z`) | `aux1` (`packedColor.w`) |
| --- | --- | --- | --- | --- | --- |
| `0` | `.quad` / `.rrect` fill | unused `(0,0,0,0)` | `fill` (`0xRRGGBBAA`) | unused | `layerAlpha` |
| `1` | `.quad` / `.rrect` border | `(bt, br, bb, bl)` per-side widths | `borderCol` | unused | `layerAlpha` |
| `2` | `.shadow` (compute mask composite) | shadow halo source `(0, 0, mw, mh)` inside `uShadowTex`; `dstRect` is clamped `expanded` | `shadowCol` | `blur` (px) | `layerAlpha` |
| `3` | `.glyph (isColor=false)` / `.mask` | atlas `(u, v, w, h)` | `color` | `pageIdx` (`0..7`) | `layerAlpha` |
| `4` | `.glyph (isColor=true)` | atlas `(u, v, w, h)` | `color` (alpha mod) | `pageIdx` (`0..7`) | `layerAlpha` |
| `5` | `.image` | source `(u, v, w, h)` in `uImageTex` | tint `0xFFFFFFFF` | `texSlot` | `layerAlpha` |
| `6` | `.linear` | unused | `c0` | `c1` | `layerAlpha \| (angleDeg << 8)` |
| `7` | `layerPop` composite | unused (sampled at `vFragCoord / pc.layerTexSize`) | `0xFFFFFFFF` | `layerSlot` (`0..3`) | `opacity` (`0..255`) |

- **Graphics Pipeline Input Assembly & Rasterizer State:**
  - `VkPipelineInputAssemblyStateCreateInfo.topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP` (matching `shaders/scene_sdf.glsl:38` `corner = vec2(gl_VertexIndex & 1, (gl_VertexIndex >> 1) & 1)` generating `(0,0), (1,0), (0,1), (1,1)` per `vkCmdDraw(4, batchCount, 0, batchStart)`).
  - `VkPipelineRasterizationStateCreateInfo.cullMode = VK_CULL_MODE_NONE` (so Vulkan's Y-down NDC quad winding can never cull instanced quads).
- **Asymmetric `.rrect` Border SDF (`kind = 1`, matching `Vulkan.lean:251-261`):**
  - Unpack `(bt, br, bb, bl) = vec4(inst.uvRect)`.
  - Compute inner half-size `innerHalf = max(halfSize - 0.5 * vec2(bl + br, bt + bb), vec2(0.0))` and **asymmetric inner center offset `pInner = p - 0.5 * vec2(bl - br, bt - bb)`**.
  - Compute per-corner `innerRadii = max(vec4(inst.radii) - vec4(max(bt, bl), max(bt, br), max(bb, br), max(bb, bl)), vec4(0.0))`.
  - Evaluate `dOuter = sdRoundedBox(p, halfSize, vec4(inst.radii))` and `dInner = sdRoundedBox(pInner, innerHalf, innerRadii)`; `cov = clamp(0.5 - dOuter, 0.0, 1.0) * clamp(0.5 + dInner, 0.0, 1.0)`.
- **Reconciled `.linear` `angleDeg` Semantics (`kind = 6`):**
  - Currently `Vulkan.lean:432-449` ignores `_angle` and always interpolates vertically, while `Scene.lean:86` defaults `angleDeg := 90`. In Stage 0, reconcile **both** CPU (`Vulkan.lean:432`) and GPU (`shaders/scene_sdf.glsl` `kind = 6`) on the standard CSS `linear-gradient` angle convention (`0°` = bottom-to-top, `90°` = left-to-right, `180°` = top-to-bottom):
    - Direction unit vector `dir = vec2(sin(rad), -cos(rad))` (`rad = radians(float(angleDeg % 360))`).
    - Gradient half-length `halfLen = max(abs(dir.x) * halfSize.x + abs(dir.y) * halfSize.y, 1e-4)`.
    - Normalized stop `t = clamp(dot(p, dir) / (2.0 * halfLen) + 0.5, 0.0, 1.0)`; linearly interpolate straight-alpha `mix(c0, c1, t)` (matching integer `(c0*(1-t) + c1*t)` on CPU) before applying SDF rounded-box coverage `cov`.

**Dynamic SSBO Ring:** Replace the fixed `65536`-byte `scratchPtr` cap with a per-frame-in-flight (`2×`) persistently mapped `VK_BUFFER_USAGE_STORAGE_BUFFER_BIT` buffer starting at **1 MiB** (`13,107` instances) and growing by 2× (up to 16 MiB) on demand, destroying the old buffer only after its fence retires.

#### 2.2.2 Shader Compilation, Repo-Root Path & CI Drift Check
- Both shaders live at the **repository root** (`shaders/scene_sdf.glsl` and `shaders/blur_box.comp.glsl`, matching existing `shaders/scene_sdf.glsl` and NOT `lean/OrbDesktop/shaders/`).
- Compile `shaders/scene_sdf.glsl` (vertex + fragment stages via `-DVERTEX_SHADER` / `-DFRAGMENT_SHADER`) and `shaders/blur_box.comp.glsl` (separable `uint32` box blur for `.backdropBlur` and `.shadow`) at **build time** via `glslangValidator -V --target-env vulkan1.3` into deterministic SPIR-V word arrays checked into `lean/OrbDesktop/LeanUI/Shaders.lean`.
- Add `scripts/gen_leanui_shaders.py --check` (analogous to `scripts/gen_turbo_lean_ffi.py --check`) to CI so any edit to `shaders/*.glsl` without regenerating `lean/OrbDesktop/LeanUI/Shaders.lean` fails immediately, and update `ci/domains.toml:80` from `"shaders/scene_sdf.glsl"` to `"shaders/*"`.
- Runtime creates `VkShaderModule` directly from the embedded `ByteArray` — **zero runtime dependency on `glslang`, `shaderc`, or filesystem shader paths**.

#### 2.2.3 Premultiplied Blending State & CPU Double-Premultiplication Fix
Both CPU and GPU commit unambiguously to **premultiplied RGBA8** framebuffers and offscreen layer targets:
- **GPU fragment shader outputs:**
  - Straight-alpha primitives (`kind = 0, 1, 2, 3, 6`): `vec4(baseColor.rgb * effA, effA)` where `effA = baseColor.a * cov * layerAlpha`.
  - Premultiplied texture sources (`kind = 4` FreeType `FT_PIXEL_MODE_BGRA` color glyphs, `kind = 7` `layerPop` offscreen layer targets, and premultiplied `.image` `kind = 5`): **`vec4(tex.rgb * modA, tex.a * modA)`** (where `modA = baseColor.a * layerAlpha` for `kind = 4`, `opacity / 255.0` for `kind = 7`). Never multiply `tex.rgb` by `tex.a` again.
- **Graphics pipeline blend state:**
  - `srcColorBlendFactor = VK_BLEND_FACTOR_ONE`, `dstColorBlendFactor = VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA`, `colorBlendOp = VK_BLEND_OP_ADD`
  - `srcAlphaBlendFactor = VK_BLEND_FACTOR_ONE`, `dstAlphaBlendFactor = VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA`, `alphaBlendOp = VK_BLEND_OP_ADD`
  - This single blend state handles straight-alpha SDF shapes, R8 glyph masks, premultiplied color emoji, and `layerPop` offscreen layer composites in one pipeline without pipeline rebinds.
- **Mandatory Stage 0 CPU Double-Premultiplication Fix:**
  - `Vulkan.lean:402-412` (`Prim.layerPop`) currently passes already-premultiplied `layerBuf` RGB channels into straight-alpha `blendOver`, multiplying RGB by `la` a second time. Replace with premultiplied source-over: `out_c = min 255 ((lr * top.opacity + 127) / 255 + (dr * (255 - la) + 127) / 255)`, `out_a = min 255 (la + (da * (255 - la) + 127) / 255)`.
  - `c/lean_ui_vulkan.c:28-31` (`lean_ui_blit_glyph` when `colored = 1`) and its Lean fallback (`Vulkan.lean:525-533`) likewise pass FreeType's premultiplied color glyph RGB into `c * a / 255`. Fix both to compute premultiplied source-over `d[i] = min(255, (s[i] * sa + 127) / 255 + (d[i] * (255 - a) + 127) / 255)` matching GPU `vec4(tex.rgb * modA, tex.a * modA)`.

#### 2.2.4 Dirty Glyph Atlas Page Uploads (`VK_IMAGE_VIEW_TYPE_2D_ARRAY` & Multi-Page Pipeline)
`GlyphAtlasCache` (`LeanUI/Text.lean:291-325`) already brackets per-frame glyph mutations with `beginUploads` / `finishUploads` and accumulates `pendingUploads : Array (Nat × Rect × RasterizedGlyph)`:
- **Core Vulkan 1.3 Valid Atlas Image (`sampler2DArray`, NOT `sampler2D uAtlas[8]`):**
  - Indexing a `sampler2D uAtlas[8]` array with per-instance `aux0` (`pageIdx`) is dynamically non-uniform and violates `VUID-RuntimeSpirv-NonUniform-06274` unless `shaderSampledImageArrayNonUniformIndexing` + `nonuniformEXT` are enabled.
  - Instead, allocate a single **`VK_IMAGE_VIEW_TYPE_2D_ARRAY`** image (`1024 × 1024`, fixed `arrayLayers = MAX_ATLAS_PAGES = 8`, `VK_FORMAT_R8G8B8A8_UNORM`, `VK_IMAGE_TILING_OPTIMAL`, `VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_SAMPLED_BIT`) bound as `layout(set = 0, binding = 1) uniform sampler2DArray uAtlas` with `VK_FILTER_NEAREST` and `VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE`.
  - Sample via `texture(uAtlas, vec3(vUV, float(clamp(pageIdx, 0u, 7u))))` — 100% core Vulkan 1.3 valid with zero descriptor-indexing extensions.
- **Dirty Sub-Uploads & `GlyphAtlasCache.resetAll` GPU Clear:**
  - Extend `GlyphAtlasCache` with `gpuDirtyRects : Array (Nat × Rect)` and `generation : UInt64` (incremented on `resetAll`):
    - `finishUploads` preserves newly blitted `(pageIdx, rect)` entries into `gpuDirtyRects` (consumed and cleared after GPU submission).
    - **Handling `GlyphAtlasCache.resetAll` (`LeanUI/Text.lean:327-331`):** `resetAll` resets every page's CPU backing to `page.rgba := ByteArray.empty` (0 bytes, lazily reallocated on next blit). Therefore, when `generation` advances, the GPU renderer **MUST clear all layers of `uAtlas` via `vkCmdClearColorImage`** (in `TRANSFER_DST_OPTIMAL`, clear color `(0, 0, 0, 0)`, `layerCount = 8`) rather than trying to upload empty `page.rgba` buffers, and then apply any subsequent `gpuDirtyRects` sub-uploads.
    - On normal frames, upload **only the `(rect.w × rect.h × 4)` sub-region** for each entry in `gpuDirtyRects` targeting `baseArrayLayer = pageIdx` via staging buffer + `vkCmdCopyBufferToImage2`, followed by one `vkCmdPipelineBarrier2` (`TRANSFER_WRITE` -> `FRAGMENT_SHADER_READ`, `TRANSFER_DST_OPTIMAL` -> `SHADER_READ_ONLY_OPTIMAL`).
  - Typical steady-state frame (warm glyph cache): **0 bytes uploaded**. Streaming turn with 20 new glyphs: **~12 KiB uploaded** (vs 4 MiB whole-page upload).
- **Production Multi-Page Glyph Fix (`Main` → `Layout` → `Scene` → `Vulkan`):**
  Production desktop text flows through `OrbDesktop.Main.shapeDesktopRuns` (`OrbDesktop/Main.lean:88-131`) → `Layout.ShapedGlyph` (`LeanUI/Layout.lean:10-23`) → `Scene.emitWrappedLineGlyphs` (`LeanUI/Scene.lean:179-205`) → `Prim.glyph` (`LeanUI/Defs.lean:61`), **not** `Text.layoutTextRun` (`Text.lean:507`). To support multi-page atlases (`page >= 1`) without silently sampling page `0`:
  1. Add `atlasPage : Nat := 0` to `Layout.ShapedGlyph` (`LeanUI/Layout.lean:10-23`).
  2. Populate `atlasPage := entry.page` in `OrbDesktop.Main.shapeDesktopRuns` (`OrbDesktop/Main.lean:118-129`).
  3. Add `atlasPage : Nat := 0` to `Prim.glyph` (`LeanUI/Defs.lean:61`), pass `pg.glyph.atlasPage` in `Scene.emitWrappedLineGlyphs` (`Scene.lean:204`) and `entry.page` in `Text.layoutTextRun` (`Text.lean:506-511`).
  4. Read `atlas.pages[atlasPage]?` in `Vulkan.rasterizeSceneInto` (`Vulkan.lean:502`) and check `idx == atlasPage` in `samplesUnchanged` (`Vulkan.lean:686`), packing `aux0 := atlasPage.toUInt32` for both `kind = 3` and `kind = 4`.

#### 2.2.5 Hierarchical Clipping (`clipPush`, `clipPushRounded`, `clipPop`)
1. **Axis-aligned `clipPush` / `clipPop`:**
   - Maintained on Lean's `clipStack` during `Scene` -> `GpuPrimInstance` lowering (exact `intersectRect` intersection).
   - Stored per instance in `inst.clipRect` (for per-fragment clipping) **and** emitted as hardware `vkCmdSetScissor` across contiguous draw batches sharing the same scissor rect to avoid fragment-shader invocation outside clipped scroll viewports.
2. **Rounded `clipPushRounded r radii`:**
   - Maintain a flat per-frame `ClipNode` SSBO (set 0 binding 2, 48 bytes/node: `ivec4 rect`, `uvec4 radii`, `uvec4 meta` where `meta.x = parentIdx`; max depth 8).
   - Each instance encodes its active `roundedClipIdx` in `packedColor.y >>> 8` (`0` = no rounded clip).
   - In the fragment shader, while `clipIdx != 0`, walk the parent chain (at most 8 steps, typically 1), evaluate `sdRoundedBox` against each rounded clip rect, multiply coverage by `clamp(0.5 - dClip, 0.0, 1.0)`, and discard if `0`.
   - Zero extra render passes, no stencil buffer required, exact anti-aliased nested rounded clips. Updating CPU reference `Vulkan.lean:383` (`clipPushRounded`) from axis-aligned `intersectRect` to `sdfRoundedRect16` clip coverage changes rounded-clip edge pixels and therefore **requires regenerating `docs/ui/leanui-parity.md` and `docs/ui/crops/*`** in the same Stage 0 commit so CI parity checks remain synchronized.

#### 2.2.6 Descriptor Set 0 Layout, Offscreen Layers (`layerPush`/`layerPop`), `backdropBlur` & Compute `.shadow`
A `Scene` is lowered into an ordered list of **Render Passes** (typically 1 pass when no `layerPush`/`backdropBlur`/`.shadow` is present; additional passes only when modals, shadows, or opacity groups appear).

**Explicit Descriptor Set 0 & Push Constant Layout (Zero Non-Uniform Indexing):**
- **Push Constants (32 bytes):** `vec2 viewportSize`, `vec2 atlasSize`, `vec2 layerTexSize`, `vec2 imageTexSize`.
- **Binding 0 (`STORAGE_BUFFER`, VS + FS):** `InstanceBuffer` (`PrimInstance instances[]`).
- **Binding 1 (`COMBINED_IMAGE_SAMPLER`, FS):** `sampler2DArray uAtlas` (fixed 8-layer `1024×1024` `R8G8B8A8_UNORM` glyph/mask atlas for `kind = 3, 4`; UV = `(uvRect.xy + corner * uvRect.zw) / max(pc.atlasSize, vec2(1.0))`).
- **Binding 2 (`STORAGE_BUFFER`, FS):** `ClipBuffer` (`ClipNode clips[]` for nested `clipPushRounded`).
- **Binding 3 (`COMBINED_IMAGE_SAMPLER`, FS):** `sampler2DArray uLayers` (fixed 4-layer `R8G8B8A8_UNORM` pooled offscreen layer target array for `kind = 7` `layerPop`, indexed by `clamp(aux0, 0u, 3u)`; **normalized UV = `vFragCoord / max(pc.layerTexSize, vec2(1.0))`** — i.e., `vFragCoord / viewportSize` when unbucketed, **NEVER** `/ pc.atlasSize`!).
- **Binding 4 (`COMBINED_IMAGE_SAMPLER`, FS):** `sampler2D uAuxTex` (explicitly bound per batch for `kind = 5` `.image` and `kind = 2` compute-blurred `.shadow` halo mask; **normalized UV = `(uvRect.xy + corner * uvRect.zw) / max(pc.imageTexSize, vec2(1.0))`**, never `/ pc.atlasSize`).

**Offscreen Layer & Compute Blur Passes:**
1. **Pooled Offscreen Layer Targets:** Maintain a single 4-layer `VK_IMAGE_VIEW_TYPE_2D_ARRAY` (`R8G8B8A8_UNORM`, `COLOR_ATTACHMENT | SAMPLED | TRANSFER_SRC | TRANSFER_DST`) sized to the viewport (or rounded up to 256-px buckets, passing actual backing extent in `pc.layerTexSize`), with per-layer `VK_IMAGE_VIEW_TYPE_2D` attachment views `L[0..3]` for `vkCmdBeginRendering`.
2. **`layerPush opacity` (with `renderArea` Clamping):**
   - Clamp the render area strictly to `clampedClip := intersectRect curClip { x := 0, y := 0, w := vw, h := vh }` (guaranteeing `offset >= 0` and `offset + extent <= attachmentExtent`, satisfying `VUID-VkRenderingInfo-pNext-06077` and `VUID-VkRenderingInfo-pNext-06079`).
   - If `clampedClip.isEmpty` (`w <= 0 || h <= 0`), push a `skipped := true` frame onto the Lean layer stack and **skip** `vkCmdBeginRendering`/clearing/drawing until the matching `layerPop` (which also emits no `kind = 7` draw).
   - Otherwise flush the current draw batch (`vkCmdDraw(4, batchCount, 0, batchStart)`), `vkCmdEndRendering`, transition layer `L[depth]` to `COLOR_ATTACHMENT_OPTIMAL`, and `vkCmdBeginRendering` targeting `L[depth]` with `renderArea = clampedClip`, `loadOp = CLEAR`, `clearColor = (0,0,0,0)`.
3. **`layerPop`:**
   - If the top layer was `skipped`, pop and continue. Otherwise flush the layer batch, `vkCmdEndRendering`, barrier layer `L[depth]` (`COLOR_ATTACHMENT_WRITE` -> `FRAGMENT_SHADER_READ`, `SHADER_READ_ONLY_OPTIMAL`), resume parent target (`loadOp = VK_ATTACHMENT_LOAD_OP_LOAD`, `renderArea = clampedViewport`), and emit a single `kind = 7` quad over `clampedClip` sampling `uLayers` layer `depth` at `vFragCoord / pc.layerTexSize` modulated by `top.opacity / 255.0`.
4. **`backdropBlur sigma` (Blit-to-`R8G8B8A8_UNORM`-Compute-Blit-Back — Never `STORAGE_BIT` on Swapchain):**
   - Because Wayland `B8G8R8A8_UNORM` swapchain images do not guarantee `VK_IMAGE_USAGE_STORAGE_BIT`, `backdropBlur` **never** binds a swapchain image as a compute `storage image`.
   - Instead: flush current batch -> `vkCmdEndRendering` -> transition active target to `TRANSFER_SRC_OPTIMAL` and compute ping-pong image `P0` (`R8G8B8A8_UNORM`, `STORAGE | TRANSFER_SRC | TRANSFER_DST`) to `TRANSFER_DST_OPTIMAL` -> **`vkCmdBlitImage2`** (1:1 nearest) active target -> `P0` (hardware `BGRA -> RGBA` swizzle).
   - Transition `P0`, `P1` to `GENERAL` and dispatch 6 separable `shaders/blur_box.comp.glsl` passes (`16×16` workgroups implementing `blurBackdrop`'s exact radii `[sigma - 1, sigma - 1, sigma]` in `uint32` fixed-point arithmetic `(sum + r) / (2 * r + 1)`, edge-replicated, bit-exact with `c/lean_ui_vulkan.c:111-139`).
   - Transition final blurred ping-pong image to `TRANSFER_SRC_OPTIMAL` and active target to `TRANSFER_DST_OPTIMAL` -> **`vkCmdBlitImage2`** (1:1 nearest) back to the active target (hardware `RGBA -> BGRA` swizzle) -> transition active target to `COLOR_ATTACHMENT_OPTIMAL` -> resume `vkCmdBeginRendering` (`LOAD_OP_LOAD`). At 2940×1846, 6 separable GPU passes + 2 blits take **~0.5–1.0 ms** on Apple M2 Honeykrisp vs **~35–60 ms** on CPU.
5. **`.shadow` Compute 3-Pass Box Blur (Mandated for Parity):**
   - Analytical `erf`-box approximations deviate **4–15 LSB** from CPU's 3-pass separable box blur of a rounded-rect mask (`Vulkan.lean:477-495`), violating the `Δ <= 3` parity gate.
   - Mandate the exact compute shadow path: render the rounded-rect coverage mask for casting rect `r` into a clamped halo sub-region (`mx, my, mw, mh`) of the ping-pong `R8G8B8A8_UNORM` compute image, run `shaders/blur_box.comp.glsl` with `[sigma - 1, sigma - 1, sigma]` (`sigma = blur / 2`), and composite the resulting blurred alpha mask onto the active target via a `kind = 2` quad sampling `uAuxTex` tinted by `shadowCol`. This achieves **`max Δ <= 1` LSB** (`0` on straight edges) with zero parity compromises.

#### 2.2.7 Partial Damage on GPU (`VK_KHR_incremental_present` vs Backing Target)
Unlike single-buffered CPU `framebuffer`, a Vulkan swapchain cycles through `N` (`2` or `3`) images whose prior contents are `(N-1)` frames old:
- **Strategy A (Default for Phase 2 — Full-Scene Instanced Redraw + `VK_KHR_incremental_present`):**
  - Re-render the full scene directly into the acquired swapchain image (`LOAD_OP_CLEAR` with `clearColor`, `renderArea = { (0,0), (bw,bh) }`) in a single instanced `vkCmdDraw(4, N_inst, 0, 0)` pass (`~0.2–0.6 ms` on hardware GPUs for 2,000–6,000 quads/glyphs), while still passing the authoritative dirty rectangle from `ctx.lastUploadedDirtyRect` (captured before `Runtime.stepFrameWithRegions` clears `st.damage := none`) via `VkPresentRegionsKHR` (`VK_KHR_incremental_present`) so the Wayland compositor only recomposites the changed region.
  - Zero buffer-age complexity, zero extra GPU memory for a full-size persistent backing target, and always immune to swapchain image rotation artifacts.
- **Strategy B (Optional Scissor-Damaged Persistent Backing Target):**
  - Available behind `ORB_LEANUI_GPU_PARTIAL=1` for low-power integrated GPUs on huge static scenes: render only `ctx.lastUploadedDirtyRect` (clamped to `(0, 0, bw, bh)`, skipping if empty) with `LOAD_OP_LOAD` + `vkCmdSetScissor(dirtyRect)` onto a persistent `R8G8B8A8_UNORM` image, then `vkCmdBlitImage2` / `vkCmdCopyImage2` (dirty rect or full) to the swapchain image. Only enabled when `!hasGlobalEffect scene`.

---

## 3. Strict `<= 220` LOC C Shim & Zero-Rust Architecture

### 3.1 Current Shim Inventory & CI Constraints

Repository CI enforces **zero `.rs` files** and **`<= 220` LOC per `.c` shim** (`.github/workflows/ci.yml:163-172`, `.github/workflows/kernel-abi.yml:225-266`, `lean/OrbDesktop/c/lean_ui.h:5-6`). Every `@[extern]` symbol in `LeanUI.FFI` must also be allowlisted in both `lean/turbo-lean.toml` and `lean/OrbDesktop/turbo-lean.toml` (generated by `scripts/gen_turbo_lean_ffi.py`).

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
| `vkGetInstanceProcAddr` / `vkGetDeviceProcAddr` | 2 | `PFN` (64-bit ptr) | Yes (`lean_ui_call`) | **MUST keep `lean_ui_call` (`uint64_t` return)** — never `call_res8` (`int32_t`) |
| `vkCreateInstance` / `vkDestroyInstance` | 3 / 2 | `VkResult` / `void` | Yes | `pAllocator = 0` (`NULL`) |
| `vkEnumeratePhysicalDevices` / `vkGetPhysicalDeviceProperties` | 3 / 2 | `VkResult` / `void` | Yes | |
| `vkGetPhysicalDeviceFeatures2` | 2 | `void` | Yes | Verifies Vulkan 1.3 `synchronization2` & `dynamicRendering` |
| `vkEnumerateDeviceExtensionProperties` | 4 | `VkResult` | Yes | Checks `VK_KHR_swapchain`, `incremental_present`, `push_descriptor`, `maintenance6` |
| `vkGetPhysicalDeviceFormatProperties` | 3 | `void` | Yes | Verifies `VK_FORMAT_FEATURE_BLIT_DST_BIT` / `BLIT_SRC_BIT` / `STORAGE_IMAGE_BIT` |
| `vkGetPhysicalDeviceQueueFamilyProperties` / `MemoryProperties` | 3 / 2 | `void` | Yes | |
| `vkGetPhysicalDeviceWaylandPresentationSupportKHR` | 3 | `VkBool32` | Yes | |
| `vkGetPhysicalDeviceSurface{Support,Capabilities,Formats,PresentModes}KHR` | 3–4 | `VkResult` | Yes | |
| `vkCreateWaylandSurfaceKHR` / `vkDestroySurfaceKHR` | 4 / 3 | `VkResult` / `void` | Yes | |
| `vkCreateDevice` / `vkDestroyDevice` / `vkGetDeviceQueue` | 4 / 2 / 4 | `VkResult` / `void` | Yes | |
| `vkCreateSwapchainKHR` / `vkDestroySwapchainKHR` / `vkGetSwapchainImagesKHR` | 4 / 3 / 4 | `VkResult` / `void` | Yes | |
| `vkAcquireNextImageKHR` (or `vkAcquireNextImage2KHR`) | **6** (or 3) | `VkResult` | Yes | All integer/u64/ptr |
| `vkQueueSubmit2` / `vkQueuePresentKHR` / `vkDeviceWaitIdle` | 4 / 2 / 1 | `VkResult` | Yes | Vulkan 1.3 `Submit2` avoids 5+ args |
| `vkCreate/Destroy{CommandPool,Fence,Semaphore,Buffer,Image,ImageView,Sampler,ShaderModule}` | 3–4 | `VkResult` / `void` | Yes | |
| `vkGetBufferMemoryRequirements` / `vkGetImageMemoryRequirements` | 3 | `void` | Yes | Queries size, alignment, and `memoryTypeBits` |
| `vkBindBufferMemory` / `vkBindImageMemory` | 4 | `VkResult` | Yes | Binds `VkDeviceMemory` at `VkDeviceSize` offset |
| `vkAllocateMemory` / `vkFreeMemory` / `vkMapMemory` / `vkUnmapMemory` | 4 / 3 / **6** / 2 | `VkResult` / `void` | Yes | |
| `vkInvalidateMappedMemoryRanges` | 3 | `VkResult` | Yes | Required before reading `HOST_CACHED` `--gpu-readback` memory |
| `vkAllocateCommandBuffers` / `vkBeginCommandBuffer` / `vkEndCommandBuffer` / `vkResetCommandBuffer` | 2–3 | `VkResult` | Yes | |
| `vkWaitForFences` / `vkResetFences` | 5 / 3 | `VkResult` | Yes | |
| `vkCreateDescriptorSetLayout` / `vkCreatePipelineLayout` / `vkCreateDescriptorPool` / `vkAllocateDescriptorSets` / `vkUpdateDescriptorSets` | 3–5 | `VkResult` / `void` | Yes | |
| `vkCreateGraphicsPipelines` / `vkCreateComputePipelines` | **6** | `VkResult` | Yes | |
| `vkCmdBeginRendering` / `vkCmdEndRendering` (Vulkan 1.3) | 2 / 1 | `void` | Yes | Eliminates `VkRenderPass` & `VkFramebuffer` |
| `vkCmdClearColorImage` | **6** | `void` | Yes | Clears `uAtlas` layers on `GlyphAtlasCache.resetAll` generation bump |
| `vkCmdPipelineBarrier2` / `vkCmdCopyBufferToImage2` / `vkCmdCopyImageToBuffer2` / `vkCmdBlitImage2` / `vkCmdCopyImage2` (Vulkan 1.3) | 2 | `void` | Yes | Eliminates 10-arg `vkCmdPipelineBarrier` |
| `vkCmdBindPipeline` / `vkCmdSetViewport` / `vkCmdSetScissor` / `vkCmdDraw` / `vkCmdDispatch` | 3–5 | `void` | Yes | |
| `vkCmdPushConstants` | **6** | `void` | Yes | |
| `vkCmdPushDescriptorSetKHR` (`VK_KHR_push_descriptor`) | **6** | `void` | Yes | Optional extension |
| **`vkCmdBindDescriptorSets`** | **8** | **`void`** | **NO (> 6 args)** | Needs `call_void8` or `VK_KHR_push_descriptor` / `vkCmdBindDescriptorSets2` (`maintenance6`) |

**Three ABI & Performance Hazards in Relying Exclusively on `lean_ui_call`:**
1. **`vkCmdBindDescriptorSets` takes 8 arguments** — if a Vulkan 1.3 ICD lacks both `VK_KHR_push_descriptor` and `VK_KHR_maintenance6`, `call6` cannot bind descriptor sets at all.
2. **Return-type / LP64 ABI soundness (NOT strict ISO C11 or CFI-icall):** `lean_ui_call` casts `void`-returning `vkCmd*` / `vkDestroy*` pointers to `uint64_t (*)(...)`. Splitting generic dispatch into `void`-returning (`call_void8`) and `int32_t`-returning (`call_res8`) 8-argument trampolines aligns return-register conventions and is **sound under the LP64 SysV `x86_64` and AAPCS64 `aarch64` ABIs** (all Linux Wayland targets: non-variadic callees read only their declared integer register/stack slots and ignore trailing unused arguments). However, calling an `N`-parameter function through an 8-parameter pointer is **not strict ISO C11** (C11 §6.3.2.3p8) and is **incompatible with `-fsanitize=cfi-icall` / UBSan's `-fsanitize=function`** (if sanitizer builds are enabled, compile `lean_ui_vk_bridge.c` with `-fno-sanitize=function`). Crucially, **64-bit pointer-returning** loader entry points (`vkGetInstanceProcAddr`, `vkGetDeviceProcAddr`) **MUST continue using `lean_ui_call` (`uint64_t` return)** so 64-bit function pointers are never truncated by `call_res8` (`int32_t`).
3. **Sub-rect strided upload efficiency:** Copying a dirty rect `(dx, dy, dw, dh)` from `VulkanContext.framebuffer` (`ByteArray`) into a mapped staging buffer via per-row `FFI.memWrite` incurs `dh` Lean `ByteArray.extract` allocations (`1,846` allocations at 2x height) unless a single zero-allocation `lean_ui_vk_copy_rect` helper performs the bounded strided `memcpy` in C.

### 3.3 Recommended Shim Design: Dedicated `c/lean_ui_vk_bridge.c` (`<= 120` LOC)

Compare the two architectural options:

| Criterion | Option A (Recommended): Thin Call/Copy Bridge `c/lean_ui_vk_bridge.c` (`~100` LOC) | Option B: C WSI Wrapper `c/lean_ui_vk_swapchain.c` (`~215` LOC) |
| --- | --- | --- |
| Build dependencies | **Zero** (`#include <lean/lean.h>` only; no `libvulkan-dev` headers required in `lakefile.lean` or Nix!) | Requires `<vulkan/vulkan_core.h>` + `<vulkan/vulkan_wayland.h>` (`libvulkan-dev`) |
| Ownership of Vulkan state machine & struct packing | **100% Lean** (`LeanUI/VulkanSwapchain.lean` — testable, auditable, matches `LeanUI/Wayland.lean` design) | Split between C and Lean |
| LOC headroom | `~100 / 220` LOC (120 LOC margin) | `~210 / 220` LOC (fragile margin) |
| Solves `vkCmdBindDescriptorSets` (8 args), return-type mismatch, & bounded strided upload | **Yes** (LP64 SysV `x86_64` / AAPCS64 `aarch64` sound) | Yes |

**Exact Proposed Symbol List for `lean/OrbDesktop/c/lean_ui_vk_bridge.c` (~100 LOC, strictly `<= 220` LOC):**

```c
/* 1. Void-returning 0..8 integer/pointer-arg trampoline (64-byte ByteArray) — LP64 SysV x86_64 / AAPCS64 sound
 *    (not strict ISO C11 or -fsanitize=cfi-icall). Used for vkCmd* / vkDestroy* / vkGet* void entry points. */
lean_obj_res lean_ui_vk_call_void8(size_t fn, b_lean_obj_arg args, lean_obj_arg w);

/* 2. int32_t (VkResult / VkBool32) 0..8 integer/pointer-arg trampoline — returns sign-extended Int64 / UInt32.
 *    NEVER used for 64-bit pointer returns (vkGetInstanceProcAddr / vkGetDeviceProcAddr keep lean_ui_call). */
lean_obj_res lean_ui_vk_call_res8(size_t fn, b_lean_obj_arg args, lean_obj_arg w);

/* 3. Zero-allocation, bounds-checked strided rectangle copy from a Lean RGBA8 ByteArray into mapped
 *    VkDeviceMemory staging pointer (`dstCap` = mapped staging capacity in bytes).
 *    Validates non-null dstPtr when rows*rowBytes > 0, overflow-safe `rows <= dstCap / rowBytes`,
 *    and `fits_rows(srcLen, srcOff, srcStride, rowBytes, rows)` before packing `rows` tightly into dstPtr. */
lean_obj_res lean_ui_vk_copy_rect(size_t dstPtr, size_t dstCap, b_lean_obj_arg src, size_t srcOff,
                                  size_t srcStride, size_t rowBytes, size_t rows, lean_obj_arg w);

/* 4. Zero-allocation, overflow-safe strided copy of native memory -> ByteArray for GPU readback verification.
 *    Validates `srcStride >= rowBytes`, overflow-safe `rows <= SIZE_MAX / rowBytes` (and `srcPtr != 0` when
 *    total > 0) before calling `lean_alloc_sarray(1, rows * rowBytes, rows * rowBytes)`. */
lean_obj_res lean_ui_vk_read_rect(size_t srcPtr, size_t srcStride, size_t rowBytes, size_t rows, lean_obj_arg w);
```

**LP64 Struct Layout Safety (Lean-side):**
All Vulkan structs packed in `LeanUI/VulkanStructs.lean` target LP64 little-endian (`x86_64` and `aarch64` Linux), with an explicit unit test (`tests/VkStructAbiCheck.c`, compiled only in CI tests, not linked into the binary) asserting `sizeof` and `offsetof` against `<vulkan/vulkan.h>` for every struct Lean serializes (`VkInstanceCreateInfo`, `VkWaylandSurfaceCreateInfoKHR`, `VkDeviceCreateInfo`, `VkSwapchainCreateInfoKHR`, `VkRenderingInfo`, `VkSubmitInfo2`, `VkPresentInfoKHR`, `VkPresentRegionsKHR`, `VkImageMemoryBarrier2`, `VkBufferImageCopy2`, `VkImageBlit2`, `VkGraphicsPipelineCreateInfo`). Any struct mismatch fails CI immediately before runtime.

**Build, Packaging, NixOS & Governance Registration Checklist:**
1. **`lean/OrbDesktop/lakefile.lean`:** Add `lean_ui_vk_bridge_o` target and link into `liblean_ui_c`; add `"-Wall", "-Wextra", "-Werror"` to **all** `lean_ui_*_o` targets (`lean_ui_wayland_o`, `lean_ui_text_o`, `lean_ui_vulkan_o`, `lean_ui_sidebar_o`, `lean_ui_vk_bridge_o`; currently lines 23–56 pass only `-std=c11 -O2 -fPIC`).
2. **FFI Allowlists (`lean/turbo-lean.toml` & `lean/OrbDesktop/turbo-lean.toml`):** Add the 4 `@[extern]` declarations to `lean/OrbDesktop/LeanUI/FFI.lean` and run `python3 scripts/gen_turbo_lean_ffi.py` (which updates **both** `lean/turbo-lean.toml` and `lean/OrbDesktop/turbo-lean.toml`, enforced by `--check`).
3. **C Shim `<= 220` LOC Enforcement (BOTH workflows):** Add all `lean/OrbDesktop/c/lean_ui_*.c` files (`lean_ui_wayland.c`, `lean_ui_text.c`, `lean_ui_vulkan.c`, `lean_ui_sidebar.c`, `lean_ui_vk_bridge.c`) to the `<= 220` LOC checks in **both** `.github/workflows/ci.yml:168` AND `.github/workflows/kernel-abi.yml:238-266`.
4. **NixOS (`m2air`) `libvulkan.so.1` Runtime Discovery (`nix/package.nix` & `nix/desktop.nix`):**
   - `nix/package.nix:226` already lists `vulkan-loader` in `buildInputs`, but `LD_LIBRARY_PATH` (`line 232`), `runtimeDependencies` (`lines 352-355`), `patchelf --add-rpath` (`line 379`), and `installCheckPhase` (`lines 387-392`) only include `[openssl sqlite]`. Because `libvulkan.so.1` is loaded via `dlopen("libvulkan.so.1")` (not `DT_NEEDED`), `patchelf --shrink-rpath` strips `vulkan-loader` from `orb-desktop-native`'s `DT_RUNPATH` on NixOS.
   - Update `nix/package.nix` to include `vulkan-loader` (when `buildDesktop && stdenv.hostPlatform.isLinux && vulkan-loader != null`) in `runtimeDependencies` and `patchelf --add-rpath` (plus an `installCheckPhase` assertion that `orb-desktop-native`'s `DT_RUNPATH` contains `vulkan-loader`).
   - Update `nix/desktop.nix:41-43` (`makeBinaryWrapper` for `orb-desktop-native`) to add `--suffix LD_LIBRARY_PATH : "${lib.makeLibraryPath [vulkan-loader]}:/run/opengl-driver/lib"` so NixOS `m2air` resolves both `libvulkan.so.1` and system Honeykrisp/Mesa ICDs cleanly.
5. **CI Domains, Build Driver, Apt Deps & Spec Audit Wiring:**
   - `ci/domains.toml`: update line 80 from `"shaders/scene_sdf.glsl"` to `"shaders/*"` (so `shaders/blur_box.comp.glsl` and SPIR-V drift checks run on shader edits), and route `lean/OrbDesktop/LeanUI/Spec/*` and `lean/OrbDesktop/c/*` to include `wf:kernel-abi` in addition to `orb-desktop-shell`.
   - `scripts/build_orb_bins.sh`: build the `LeanUISpec` target alongside `orb-desktop-native` (`lines 227-228, 350-358`) so `LeanUI/Spec/SwapchainSpec.lean` and sibling proof shards are always compiled with the desktop binary.
   - `.github/workflows/ci.yml` (`orb-desktop-shell`, line 489) and `.github/workflows/leanui-parity.yml` (`line 69`): add `mesa-vulkan-drivers`, `vulkan-validationlayers`, `libvulkan-dev`, and `glslang-tools` to `apt-get install`.
   - `.github/workflows/kernel-abi.yml` (`lines 284-310`): add `./scripts/turbo_lean.sh --json audit-spec` + `python3 scripts/check_spec_audit.py` gates for `lean/OrbDesktop/LeanUI/Spec/SwapchainSpec.lean` and `lean/OrbDesktop/LeanUI/Spec/MutantSuite.lean` (adding negative-witness swapchain mutants to `LeanUI/Spec/MutantSuite.lean`).
   - Add `scripts/gen_leanui_shaders.py --check` to CI to guarantee zero SPIR-V drift between repo-root `shaders/*.glsl` and `lean/OrbDesktop/LeanUI/Shaders.lean`.

---

## 4. Formal Invariants & `--headless-golden` Determinism Guarantee

### 4.1 Strict Backend Isolation & Mode Selection

The deterministic CPU reference rasterizer (`Vulkan.rasterizeSceneInto`) remains the **sole authority** for golden PNG generation, SolidJS parity checks (`scripts/leanui_parity.py`), and `OrbDesktop.RepaintCheck` / `OrbDesktop.Spec.RasterParity`. It is also the fallback for every `OrbDesktop.EmbeddedSidebar` surface.

| CLI Flag / Env Var | Effective Backend | Allowed in `--headless-golden*`? |
| --- | --- | --- |
| `--headless`, `--headless-golden`, `--headless-golden-all`, `--self-test`, `--verify-repaint` | **Always `cpuReference`** (ignores `ORB_LEANUI_GPU=1` / `--gpu`) | Yes (forced) |
| **`--gtk-sidebar-host`** (`OrbDesktop/EmbeddedSidebar.lean`, `--leanui-hybrid`) | Sidebar: `vkInstanced` on its `wl_subsurface`, `cpuReference` + `wl_shm`/cairo on `GPU_FALLBACK`. `Cmd+Shift+F` palette: headless `vkInstanced` offscreen + readback (`PaletteGpu`), `cpuReference` when no hardware device. Both honour `ORB_LEANUI_GPU=0` and `=lavapipe` | No |
| `--no-gpu` or `ORB_LEANUI_GPU=0` | `cpuShm` (`wl_shm` double buffer) | N/A |
| `--gpu=present` or `ORB_LEANUI_GPU=present` | Phase 1 `vkPresent` (auto-fallback to `cpuShm`) | N/A |
| `--gpu` or `ORB_LEANUI_GPU=1` (or `=instanced`) | Phase 2 `vkInstanced` (auto-fallback `vkPresent` -> `cpuShm`) | N/A |
| `ORB_LEANUI_GPU=lavapipe` | Enables `vkPresent`/`vkInstanced` on `VK_PHYSICAL_DEVICE_TYPE_CPU` | N/A |
| `--gpu-readback <out_dir>` (CI differential test flag only) | Offscreen Vulkan `TRANSFER_SRC` readback -> PNG | Dedicated parity harness only (never overwrites canonical CPU goldens) |

**CLI Flag Wiring Requirement:** Wire `--headless`, `--no-gpu`, `--gpu`, `--gpu=present`, `--gpu=instanced`, and `--gpu-readback <out_dir>` into **both** `Runtime.parseRuntimeArgs` (`LeanUI/Runtime.lean:54`) and `OrbDesktop.parseDesktopArgs` (`OrbDesktop/Main.lean:54`) (preferring shared delegation from `parseDesktopArgs` to `parseRuntimeArgs` so the two parsers cannot diverge). `FFI.sidebarHost` still receives the palette as RGBA bytes, so the GPU palette path reads its frame back; the instanced output stays within `max Δ ≤ 2` per channel of `cpuReference` in both themes (`--bench-embedded` reports the delta).

### 4.1.1 Embedded sidebar frame cache and auto-hide scrollbar (`--leanui-hybrid`)

GTK resends the whole row model on every sidebar paint. `EmbeddedSidebarCache` keeps the parsed rows (skipped when the row lines are unchanged), the shaped tree (reused for scroll-only frames, where only the roster `ScrollSpec` is patched by `withRosterScroll`), and a `widgetId → (unshaped, shaped)` row memo. A row is reused only when its unshaped subtree is `BEq`-equal, so a spinner tick reshapes just the running rows. The memo is dropped when the device scale changes or the glyph atlas `generation` moves, including a reset in the middle of a frame. `embeddedSidebarCacheSelfTest` (in `--self-test`) checks that cached frames have the same prims and hit payload as uncached ones.

Scene lowering skips any subtree that `subtreeOutsideClipY` proves lies wholly above or below an ancestor clip. That covers layout boxes, shadow extent and a 48 logical px allowance per node. The subtree keeps its tab order. Every prim it would emit is scissored away, so all 36 `--headless-golden-all` PNGs are byte-identical with and without culling.

The roster scrollbar is an auto-hide overlay: hidden at rest, fully visible while the offset changes and for `scrollbarHoldMs = 600` ms afterwards, then a linear `scrollbarFadeMs = 180` ms fade (`scrollbarFade`). The first hit-payload line is `<scroll limit px> <wake ms>`. GTK arms one `g_timeout` for a non-zero wake value, so the fade animates without a permanent tick.

### 4.2 Differential Parity Harness & Exact Channel Delta Bounds

To prove that Phase 1 and Phase 2 match the deterministic CPU reference across all 36 canonical screens (`9 screens × 2 themes × 2 scales` at `1470×923` 1x and `2940×1846` 2x) **plus** a synthetic translucent all-primitives fixture:

1. **Offscreen Vulkan Readback Mode (`--gpu-readback`):**
   - Creates a `VK_FORMAT_R8G8B8A8_UNORM` offscreen target with `VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT` (no Wayland display required — runs headless in CI!).
   - Renders each of the 36 canonical scenes and the synthetic all-primitives fixture through the exact same Phase 1 / Phase 2 command-buffer builder used for swapchain frames.
   - Copies the rendered image to a `HOST_VISIBLE | HOST_CACHED` buffer via `vkCmdCopyImageToBuffer2`, calls `vkInvalidateMappedMemoryRanges`, reads pixels via `lean_ui_vk_read_rect`, and encodes via `Vulkan.encodeRGBA8ToPNG`.
2. **Differential Comparison (`scripts/leanui_parity.py` Upgrades & Synthetic All-Primitives Fixture):**
   - **Existing limitations in `scripts/leanui_parity.py`:** `read()` (`leanui_parity.py:15-17`) currently converts PNGs to `'RGB'` (silently dropping the Alpha channel), and `main()` (`leanui_parity.py:177`) returns `int(bool(result['errors']))` — always exiting `0` regardless of channel delta, `above_tolerance`, or `SSIM`. Furthermore, the 36 canonical screens (opaque `pal.canvas` background) never exercise `kind = 4` (color glyphs), `kind = 5` (`.image`), `kind = 6` (`.linear`), `kind = 7` (`layerPush`/`layerPop`), translucent `clearColor = 0x00000000` chrome, or multi-page glyphs (`pageIdx >= 1`).
   - **Mandatory harness extensions:**
     - Add **`--rgba`** to `scripts/leanui_parity.py` (reading 4-channel `RGBA` so `Δ = max_{c ∈ {R,G,B,A}} |cpu_c - gpu_c|` verifies alpha parity).
     - Add hard-fail CI gate flags **`--max-delta <N>`**, **`--max-above-tol <pct>`**, and **`--min-ssim <float>`** to `scripts/leanui_parity.py` that append threshold breaches to `result['errors']` and exit non-zero on failure.
     - Add a **synthetic translucent all-primitives parity fixture** (rendered on `clearColor = 0x00000000` under `--headless-golden-all-prims` / `--gpu-readback-all-prims`) exercising every primitive kind (`0..7`): solid & translucent `.quad`/`.rrect` with asymmetric borders, compute `.shadow`, `.glyph` (`isColor = false` and `isColor = true` color emoji across `pageIdx >= 1` by filling page 0 first), `.mask`, `.image`, angled `.linear` gradients (`0°`, `45°`, `90°`, `180°`), nested `clipPushRounded`, nested `layerPush`/`layerPop` opacity groups, and `.backdropBlur`.
   - Run both the 36 canonical pairs and the synthetic `--rgba` all-primitives fixture on:
     - **CI (`ubuntu-24.04` / `uruk`)**: Mesa Lavapipe Vulkan 1.3 + `VK_LAYER_KHRONOS_validation` (zero validation errors required).
     - **`m2air`**: Apple M2 Asahi / Mesa Honeykrisp Vulkan 1.3.
     - **`dgx-spark`**: NVIDIA proprietary Vulkan 1.3 ICD.
3. **Exact Rounding Rules & Per-Primitive Max Channel Delta Bounds (`Δ = max_{c ∈ {R,G,B,A}} |cpu_c - gpu_c|`):**

| Primitive / Path | CPU Reference Rule (`Vulkan.lean`) | GPU Rule (`shaders/scene_sdf.glsl` / `blur_box.comp.glsl`) | Exact Tolerance Gate |
| --- | --- | --- | --- |
| **Phase 1 (`vkPresent`) all primitives** | `rasterizeSceneInto` RGBA8 | `vkCmdCopyBufferToImage2` + `vkCmdBlitImage2` (1:1 nearest `UNORM`) | **`max Δ = 0` (100% bit-exact across all 36 goldens + synthetic fixture)** |
| **Phase 2 solid opaque pixel-aligned `.quad` / `.rrect` (`fa == 255`, `radii == 0`)** | Constant-color scanline copy | `cov = 1.0`, `out = baseColor` | **`max Δ = 0` (bit-exact)** |
| **Phase 2 alpha-blended interior, premultiplied `layerPop` (`kind = 7`), & R8/BGRA8 `.glyph` / `.mask`** | Fixed premultiplied source-over `(c*a + d*(255-a) + 127) / 255` | IEEE-754 fp32 premul output `vec4(tex.rgb * modA, tex.a * modA)` -> hardware `UNORM8` round-to-nearest-even | **`max Δ <= 1` LSB** (differs only on exact `.5` half-way tie-breaking; `>= 99.5%` pixels exact) |
| **Phase 2 SDF rounded corners, asymmetric `.rrect` borders & `clipPushRounded`** | `sdfRoundedRect16`: `1/16`-px fixed-point `isqrt`, `cov = ((8 - d16) * 255) / 16` | `sdRoundedBox` with `pInner` & per-corner `innerRadii`: fp32 `length()`, `cov = clamp(0.5 - d, 0.0, 1.0)` | **`max Δ <= 2` LSB** on 1-px AA corner arc (`0` on straight edges/interior) |
| **Phase 2 `.linear` (`kind = 6`)** | Reconciled CSS `angleDeg` projection + `sdfRoundedRect16` | Identical CSS `angleDeg` projection `dot(p, dir)` + `sdRoundedBox` | **`max Δ <= 2` LSB** (`<= 1` LSB in interior) |
| **Phase 2 `.backdropBlur`** | `blurBackdrop`: 3-pass separable box blur `[σ-1, σ-1, σ]`, `(sum + w/2) / w` | Blit to `R8G8B8A8_UNORM` + `blur_box.comp.glsl` exact `uint32` sliding sum `(sum + r) / (2*r + 1)` + blit back | **`max Δ = 0` (bit-exact)** in `uint32` compute shader |
| **Phase 2 `.shadow` (`kind = 2`, compute-mandated)** | 3-pass separable box blur of rounded-rect mask (`sigma = blur / 2`) | **Mandated:** rounded-rect coverage mask + `blur_box.comp.glsl` (`[σ-1, σ-1, σ]`) + `kind = 2` composite (analytical `erf` fast-path dropped due to 4–15 LSB error) | **`max Δ <= 1` LSB** (`0` on straight edges) |
| **Overall GPU-vs-CPU CI Gate (36 goldens + `--rgba` all-prims fixture)** | All 36 screens (`1x` + `2x`, `dark` + `light`) + synthetic translucent fixture | Same scenes via `--gpu-readback` | **`--max-delta 3` (`0` pixels with `Δ > 3`)**, **`--max-above-tol 0.05` (`> tol(2)` < 0.05%)**, **`--min-ssim 0.9995`**, **repeat determinism pixel-identical on same ICD** |

### 4.3 Formal State-Machine Invariants (`LeanUI/Swapchain.lean` + `LeanUI/Spec/SwapchainSpec.lean`)

The executable swapchain & synchronization stepper lives directly in the core library (**`lean/OrbDesktop/LeanUI/Swapchain.lean`** or **`lean/OrbDesktop/LeanUI/Kernel.lean`**, `0 import Lean`, `0 sorryAx`), imported by **both** the runtime (`LeanUI/VulkanSwapchain.lean`) and the proof/mutant shards (`LeanUI/Spec/SwapchainSpec.lean` and `LeanUI/Spec/MutantSuite.lean`). This ensures the production runtime executes the exact proved transition function and cannot drift from the specification. All proof shards are checked by `./scripts/turbo_lean.sh --json audit-spec` + `python3 scripts/check_spec_audit.py` (`vacuous_specs == 0`, `trivial_specs == 0`, `horizontal_packing_warnings == []`, `tight_specs == total_specs_audited`).

To model `imageCount >= 3` (e.g., `MAILBOX` triple buffering) accurately alongside `MAX_FRAMES_IN_FLIGHT = 2`, `SwapchainState` splits CPU/GPU execution-slot ownership, WSI image ownership, and per-image fence tracking into **three orthogonal maps**:

```lean
inductive SwapchainPhase where
  | uninitialized
  | ready (extentW extentH : Nat) (imageCount : Nat)
  | suspendedZeroExtent
  | needsRecreate (extentW extentH : Nat)
  | deviceLostFallbackShm
  | destroyed
  deriving DecidableEq, Repr

/-- CPU/GPU execution state for each of the `MAX_FRAMES_IN_FLIGHT = 2` frame slots,
    retired exclusively by `vkWaitForFences(inFlightFence[slot])`. -/
inductive FrameSlotState (imageCount : Nat) where
  | idle
  | submitted (imgIdx : Fin imageCount)
  deriving DecidableEq, Repr

/-- WSI ownership of each swapchain image (independent of `MAX_FRAMES_IN_FLIGHT`). -/
inductive WsiImageState where
  | withPresentEngine
  | acquired (slot : Fin 2)
  deriving DecidableEq, Repr

structure ReadySwapchain (imageCount : Nat) where
  extentW : Nat
  extentH : Nat
  frameSlots : Fin 2 → FrameSlotState imageCount
  images : Fin imageCount → WsiImageState
  /-- Last frame slot whose GPU submission touched swapchain image `i` and has not yet
      been retired by `vkWaitForFences`. Enables cross-slot `MAILBOX` re-acquire waits. -/
  imageFence : Fin imageCount → Option (Fin 2)
```

Five mandatory invariants proved over `SwapchainState` (with corresponding negative-witness mutants in `LeanUI/Spec/MutantSuite.lean`):

1. **WSI Image Ownership, Frame-Slot Conservation & `MAILBOX` Cross-Slot Fence Guard (`ConservedResource`):**
   - **Serial WSI acquisition bound:** In the single-threaded acquire → submit → present loop, `count (fun i => images i != .withPresentEngine) <= 1` at all times (regardless of whether `imageCount` is `2`, `3`, or `4`).
   - **Bounded in-flight execution:** CPU/GPU execution slots are bounded to `MAX_FRAMES_IN_FLIGHT = 2` by type (`Fin 2 → FrameSlotState imageCount`), retired exclusively by `vkWaitForFences(inFlightFence[slot])` (which transitions `frameSlots[slot] := .idle` and clears `imageFence[i] := none` for any `i` with `imageFence[i] == some slot`).
   - **Acquire/Present pairing:** Every `vkAcquireNextImageKHR` returning `SUCCESS` or `SUBOPTIMAL_KHR` transitions `images[imgIdx]` from `.withPresentEngine -> .acquired slot` and requires either a matching `vkQueuePresentKHR` (transitioning `images[imgIdx] -> .withPresentEngine`, `frameSlots[slot] -> .submitted imgIdx`, and `imageFence[imgIdx] -> some slot`) or `recreate`/`destroy` (`vkDeviceWaitIdle`, resetting all `images` to `.withPresentEngine`, all `frameSlots` to `.idle`, and all `imageFence` to `none`).
   - **Cross-slot `MAILBOX` re-acquire fence guard:** Whenever `vkAcquireNextImageKHR` returns `imgIdx` on `curSlot` and `imageFence[imgIdx] = some prevSlot` with `prevSlot != curSlot`, the stepper **mandates** `vkWaitForFences(inFlightFence[prevSlot])` (retiring `prevSlot` and clearing `imageFence[imgIdx] := none`) before recording/submitting new GPU work to `imgIdx`. Thus `submit` requires `imageFence[imgIdx] = none ∨ imageFence[imgIdx] = some curSlot`.
   - **No-deadlock fence rule:** `vkResetFences(inFlightFence[slot])` is executed **strictly after** `vkAcquireNextImageKHR` succeeds (and after any cross-slot `imageFence` wait) and immediately before `vkQueueSubmit2` — NEVER before `vkAcquireNextImageKHR`. If acquire returns `VK_ERROR_OUT_OF_DATE_KHR`, `inFlightFence[slot]` remains signaled so the next frame's `vkWaitForFences` cannot deadlock.
2. **Semaphore Ownership Disjointness (`ScopedAuthority`):**
   - `imageAvailable[slot]` is indexed by `frameSlot : Fin 2` (protected by `inFlightFence[slot]`).
   - `renderFinished[imgIdx]` is indexed by **`swapchainImageIndex : Fin imageCount`** (NOT `frameSlot`!), preventing the Vulkan spec violation where `vkQueueSubmit2` re-signals a `renderFinished` semaphore still queued in the presentation engine when `imageCount >= 3`.
3. **Resize-in-Flight & Zero-Extent Recovery:**
   - `phase = ready w h n` implies `w > 0 ∧ h > 0 ∧ n >= 2`.
   - Whenever `(bw, bh) != (w, h)` or `OUT_OF_DATE_KHR` occurs, presentation is forbidden until `recreate` completes (`vkDeviceWaitIdle`, pass `oldSwapchain`, destroy `oldSwapchain` unconditionally even if `vkCreateSwapchainKHR` fails, reset `images`/`frameSlots`/`imageFence`).
   - Whenever `bw == 0 ∨ bh == 0`, transition to `suspendedZeroExtent` (no `vkCreateSwapchainKHR` with zero extent, which is invalid Vulkan usage).
4. **Strict Teardown Order & Zero-UAF (`StickyFence`):**
   - Lifecycle ordering invariant (`vkDeviceWaitIdle(device)` is unconditionally the **first** step whenever `device != 0` so no in-flight GPU work can reference destroyed resources):
     $$\text{vkDeviceWaitIdle}(\text{device}) \prec \text{destroy}(\text{pipelines, buffers, images, sync}) \prec \text{vkDestroySwapchainKHR} \prec \text{vkDestroyDevice} \prec \text{vkDestroySurfaceKHR} \prec \text{vkDestroyInstance} \prec \text{wl\_display\_disconnect}$$
   - `lifetime(wl_display) > lifetime(VkSurfaceKHR)` and `lifetime(wl_surface) > lifetime(VkSurfaceKHR)`.
   - `Runtime.shutdownRuntime` (`Runtime.lean:571-581`) already invokes `Vulkan.shutdownVulkan` before `Wayland.closeWindow`; `SwapchainSpec` makes `destroyed` an absorbing state (`StickyFence`) so no GPU call or Wayland present can fire after shutdown.
5. **Quiescence Preservation (`DamageSpec.redraw_iff_dirty`):**
   - When `needsRedraw st.damage = false`, `SwapchainState` is untouched (`acquireCount`, `submitCount`, `presentCount` unchanged; `quiescentSkips` increments by 1).

---

## 5. Measured Benchmark & Rollout Plan

### 5.1 Benchmark Suite (`--bench` + Live-Compositor `--bench-wsi` & `scripts/bench_desktop.sh`)

Because `OrbDesktop/Main.lean:528,539` (`runDesktopBench`) forces `headless := true` (bypassing Wayland and swapchain presentation), retain `--bench <iterations>` for headless CPU/damage non-regression and add a dedicated **live-compositor `--bench-wsi <iterations>`** mode (driving a real `Wayland` window on `$WAYLAND_DISPLAY` — `m2air`, `dgx-spark`, or headless Weston — across actual `wl_surface.frame`, `vkAcquireNextImageKHR`, `vkQueueSubmit2`, and `vkQueuePresentKHR`). Extend `scripts/bench_desktop.sh` with five reproducible `--bench-wsi` scenarios, each emitting structured JSON and verified with `error_count == 0` and `quiescent_redraws == 0`:

| Scenario ID | Viewport & Scale | Workload | Primary Metric | Target Budget (p50 / p99) |
| --- | --- | --- | --- | --- |
| `1080p_1x` | `1920 × 1080` @ `scale120=120` | 20 full + 20 partial transcript frames | Frame time + upload bytes | **p50 < 2.0 ms / p99 < 4.0 ms** |
| `hidpi_2x` | `2940 × 1846` (`1470×923` @ `scale120=240`) | 20 full + 20 partial Retina frames (dark & light) | Frame time + MB/s transfer | **p50 < 4.0 ms / p99 < 8.33 ms** |
| `scroll_burst_120hz` | `2940 × 1846` @ `scale120=240` | 120 consecutive wheel scroll ticks on 500-line diff + markdown transcript | Sustained 120 Hz pacing & dropped frames | **p50 < 3.5 ms / p99 < 8.33 ms** (0 missed vblanks @ 120 Hz) |
| `stream_markdown_turn` | `2940 × 1846` @ `scale120=240` | 60 coalesced streaming markdown deltas (`Orb.Stream.Coalescer`) + syntax code blocks | Partial damage + glyph atlas upload bytes | **p50 < 2.5 ms / p99 < 6.0 ms**, atlas upload < 16 KiB/frame |
| `resize_storm` | `900×600` ↔ `2940×1846`, scales `120, 150, 180, 240` | 60 rapid `xdg_toplevel.configure` + `preferred_scale` transitions | Swapchain recreate time + `RssAnon` delta | **Recreate < 16 ms**, **0 validation errors**, **0 leaked handles**, `RssAnon` delta < 4 MiB |

Global non-regression gates (preserving `scripts/bench_desktop.sh:145-153`):
- **Cold startup (`cold_ms`):** `<= 60 ms` on `wl_shm`; Vulkan device/pipeline init amortized/cached (`VkPipelineCache` persisted in `$XDG_CACHE_HOME/orb-desktop/vk_pipeline.cache`) so warm Vulkan startup stays `<= 80 ms`.
- **Memory & RSS Accounting (Separating Private Heap/GPU Budget from ICD `.so` Mappings):**
  - Hardware Vulkan ICDs (Mesa `libLLVM` on Honeykrisp/Lavapipe or NVIDIA `libnvidia-glcore.so`) map 40–150+ MiB of shared read-only executable/rodata (`RssFile`) into `VmRSS`.
  - **CPU `wl_shm` steady-state `VmRSS`:** `<= 64 MiB` hard ceiling (`<= 45 MiB` target at 1x).
  - **Vulkan modes (`vkPresent` / `vkInstanced`):** Enforce **`RssAnon`** (private anonymous heap, read from `/proc/self/status`) `<= 64 MiB` on Phase 1 (enabled by the `4 MiB × 2` capped chunked staging buffers) and `<= 48 MiB` on Phase 2 (enabled by skipping CPU `framebuffer` and `PaintSnapshot`), plus an explicit **GPU buffer/image allocation budget** (`<= 64 MiB` at 2x across staging + SSBO + 8-layer atlas + 4-layer pool + ping-pong blur targets), tracked independently of read-only ICD `RssFile` mappings.
- **Idle CPU / Quiescence:** `0.0%` CPU and `0` submits when quiescent (`framesRendered` frozen, `quiescentSkips` advancing).

### 5.2 Instrumentation Counters (`RuntimeState` & `VulkanContext`)

Add lightweight monotonic counters (zero allocations on the hot path; dumped in `--bench` / `--bench-wsi` JSON and `ORB_U7_PROFILE=1` stderr lines):

- **`VulkanContext` (`lean/OrbDesktop/LeanUI/Vulkan.lean`):**
  - `backend : RenderBackend` (`cpuShm | vkPresent | vkInstanced`)
  - `icdName : String` and `presentMode : UInt32`
  - `fallbackReason : Option String`
  - `lastUploadedDirtyRect : Option Rect` (authoritative dirty region produced by `renderFrame` / `renderFrameDamage`)
  - `swapchainRecreates : Nat`
  - `gpuAllocatedBytes : Nat` (tracked sum of active Vulkan `VkDeviceMemory` allocations for RSS/GPU budget checks)
  - `lastAcquireNs : UInt64`, `lastUploadNs : UInt64`, `lastSubmitNs : UInt64`, `lastPresentNs : UInt64`
  - `lastUploadBytes : Nat` (Phase 1 dirty-rect staging bytes), `lastAtlasUploadBytes : Nat`, `lastSsboBytes : Nat`
- **`RuntimeState` (`lean/OrbDesktop/LeanUI/Runtime.lean`):**
  - `presentCount : Nat`
  - `frameCallbackSkips : Nat` (frames coalesced while waiting for `wl_callback.done`)
  - `lastFrameTotalNs : UInt64`

### 5.3 Target Hardware & CI Verification Matrix

| Host / Environment | Architecture & OS | Vulkan ICD / Compositor | Role in Rollout |
| --- | --- | --- | --- |
| **`m2air`** | `aarch64` NixOS, Apple M2 (16 GB) | Mesa **Honeykrisp** (Asahi Vulkan 1.3; `vulkan-loader` RUNPATH + `/run/opengl-driver/lib` in `nix/package.nix` & `nix/desktop.nix`), HiDPI `2940×1846` @ 2x Wayland | Primary interactive target: HiDPI 2x latency (`--bench-wsi`), 120 Hz scroll burst, `wp_fractional_scale_v1` + `wp_viewporter`, `RssAnon` + power/idle check |
| **`uruk` / GitHub Actions CI** | `x86_64` Ubuntu 24.04 | Mesa **Lavapipe** (`mesa-vulkan-drivers`, `vulkan-validationlayers`, `libvulkan-dev`, `glslang-tools`) + `VK_LAYER_KHRONOS_validation` + headless Weston | Mandatory PR CI gate: `SwapchainSpec` + `MutantSuite` Lean proof audit (`check_spec_audit.py`), `LeanUISpec` build, `VkStructAbiCheck`, SPIR-V drift check, `<= 220` C LOC in `ci.yml` + `kernel-abi.yml`, zero validation errors, 36-golden + `--rgba` all-primitives `--gpu-readback` differential parity |
| **`dgx-spark`** | `aarch64` Ubuntu (20 cores, 119 GB) | **NVIDIA** proprietary Vulkan 1.3 ICD | Native `aarch64` build host + discrete-GPU validation (`MAILBOX` vs `FIFO`, `VK_KHR_incremental_present`, `--bench-wsi` `resize_storm`, 36-golden + synthetic NVIDIA readback parity) |

### 5.4 Phased Rollout & Kill-Switch Plan

1. **Stage 0 — Foundations, Pacing & CPU/Shader Parity Fixes (Low Risk):**
   - Wire `wl_surface.frame` (`tagFrameCallback = 13`) with `wl_proxy_destroy` (`frameCallbackProxy`, destroyed on `wl_callback.done`, present failure, `xdg_surface.configure` bypass, and `closeWindow`), `Runtime.runWindow` anti-busy-spin `timedWait` while `frameCallbackPending == true`, and `wl_buffer.release` on `wl_shm`.
   - Fix CPU/shader parity bugs: unambiguous premultiplied source-over in CPU `layerPop` and `colored = 1` glyph blit, multi-page `atlasPage` propagation through `Main.shapeDesktopRuns` → `Layout.ShapedGlyph` → `Scene.emitWrappedLineGlyphs` → `Prim.glyph`, reconciled `.linear` `angleDeg` on CPU & GPU, asymmetric `.rrect` border SDF (`pInner` + per-corner `innerRadii`), and `Vulkan.lean:383` `clipPushRounded` using `sdfRoundedRect16` (**regenerating `docs/ui/leanui-parity.md` and `docs/ui/crops/*`** in the same commit).
   - Fix repo-root `shaders/scene_sdf.glsl` ↔ `Vulkan.lean` `PrimInstance` `ivec4`/`uvec4` layout, `sampler2DArray uAtlas` + explicit descriptor bindings `0..4`, add `c/lean_ui_vk_bridge.c` (`<= 120` LOC, `-Wall -Wextra -Werror` across all `lean_ui_*_o`), `VkStructAbiCheck`, `LeanUI/Swapchain.lean` executable stepper + `LeanUI/Spec/SwapchainSpec.lean` + `MutantSuite` witnesses, `scripts/leanui_parity.py` (`--rgba` + `--max-delta`/`--max-above-tol`/`--min-ssim`) + synthetic all-primitives fixture, NixOS `vulkan-loader` RUNPATH (`nix/package.nix`/`nix/desktop.nix`), and CI/domain/audit wiring.
2. **Stage 1 — Phase 1 (`vkPresent`) Opt-In & Validation:**
   - Land `VK_KHR_wayland_surface` + `VK_KHR_swapchain` (`imageUsage` + format feature checks) + `VulkanContext.lastUploadedDirtyRect` + bounded `4 MiB × 2` chunked dirty-rect GPU upload/blit behind `--gpu=present` / `ORB_LEANUI_GPU=present` and live `--bench-wsi`.
   - Gate merge on: `0` validation errors on Lavapipe CI, `0`-LSB bit-exact parity across all 36 goldens + synthetic `--rgba` fixture (`--gpu-readback`), clean `wl_shm` fallback under Weston `--renderer=pixman`, and measured `--bench-wsi` `hidpi_2x` p50/p99 improvement on `m2air` & `dgx-spark`.
3. **Stage 2 — Phase 2 (`vkInstanced`) Opt-In & Differential Parity Gate:**
   - Land precompiled SPIR-V `shaders/scene_sdf.glsl` + `shaders/blur_box.comp.glsl` (`LeanUI/Shaders.lean` + drift check), dynamic SSBO ring, dirty `sampler2DArray` atlas sub-uploads + `vkCmdClearColorImage` on `resetAll`, rounded clip SSBO, clamped `VkRenderingInfo.renderArea` offscreen layers, `backdropBlur` blit-compute-blit path, compute 3-pass box-blur `.shadow`, and zero-CPU-`framebuffer`/`PaintSnapshot` execution behind `--gpu` / `ORB_LEANUI_GPU=1`.
   - Gate merge on: 36-golden + synthetic `--rgba` all-primitives differential parity (`--max-delta 3`, `--max-above-tol 0.05`, `--min-ssim 0.9995`) on Lavapipe CI + `m2air` Honeykrisp + `dgx-spark` NVIDIA, `RssAnon <= 48 MiB`, plus `--bench-wsi` `scroll_burst_120hz` p99 `< 8.33 ms`.
4. **Stage 3 — Default-On for Hardware Vulkan 1.3 ICDs:**
   - Flip default on live Wayland sessions to `vkInstanced` when a hardware Vulkan 1.3 ICD is detected (automatic `wl_shm` fallback for headless, Lavapipe, unsupported surface/swapchain creation, or missing ICD).
   - Retain `ORB_LEANUI_GPU=0` / `--no-gpu` as a permanent instant kill switch and keep `--headless-golden*` and `--gtk-sidebar-host` permanently pinned to the deterministic CPU reference rasterizer.
