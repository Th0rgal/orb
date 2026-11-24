import LeanUI.Defs
import LeanUI.Swapchain
import LeanUI.VulkanDevice
/-!
# LeanUI.VulkanSwapchain — Phase 1 Zero-Copy `VK_KHR_wayland_surface` + `VK_KHR_swapchain`

Executes the formally verified `LeanUI.Swapchain.SwapchainState` transitions directly:
- `*_UNORM` format priority (`B8G8R8A8_UNORM` -> `R8G8B8A8_UNORM`, rejecting `*_SRGB`)
- `PRE_MULTIPLIED` -> `OPAQUE` composite alpha selection
- `MAILBOX` -> `FIFO` present mode (`IMMEDIATE` only with `ORB_LEANUI_PRESENT_MODE=immediate`)
- `imageUsage` & `VK_FORMAT_FEATURE_BLIT_DST_BIT` verification
- Per-slot `imageAvailable[Fin 2]` vs per-image `renderFinished[Fin imageCount]` semaphores
- No-deadlock fence rule (`vkResetFences` strictly after acquire succeeds)
- Cross-slot `MAILBOX` re-acquire `imageFence` wait
- Bounded `4 MiB × 2` chunked dirty-rect upload into a persistent `R8G8B8A8_UNORM` backing image
  + hardware GPU `vkCmdBlitImage2` / `vkCmdCopyImage2` into the swapchain image
-/
namespace LeanUI.Vk

open LeanUI.Swapchain

/-- Staging buffer cap per in-flight frame slot (`4 MiB × 2 = 8 MiB` total). -/
def stagingCapBytes : Nat := 4 * 1024 * 1024

/-- Outcome of a single Vulkan present call. -/
inductive PresentOutcome where
  | presented (uploadBytes : Nat) (acquireNs uploadNs submitNs presentNs : UInt64)
  | skipped
  | needsRecreate
  | deviceLost (reason : String)
  deriving Repr, Inhabited

/-- Active `VkSwapchainKHR` and its per-image resources. -/
structure SwapchainBundle where
  swapchain : UInt64 := 0
  extentW : Nat := 0
  extentH : Nat := 0
  format : UInt32 := VK_FORMAT_B8G8R8A8_UNORM
  compositeAlpha : UInt32 := VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR
  presentMode : UInt32 := VK_PRESENT_MODE_FIFO_KHR
  canBlitDst : Bool := true
  canBlitSrc : Bool := true
  canTransferSrc : Bool := true
  images : Array UInt64 := #[]
  imageViews : Array UInt64 := #[]
  /-- Indexed strictly by `imgIdx : Fin imageCount` (Invariant 2: ScopedAuthority). -/
  renderFinishedSems : Array UInt64 := #[]
  /-- Persistent device-local `R8G8B8A8_UNORM` backing image for Phase 1 dirty-rect staging. -/
  backingImage : VkGpuImage := {}
  backingNeedsFullUpload : Bool := true
  backingInitialized : Bool := false
  deriving Inhabited

/-- Per-slot synchronization & staging objects (`MAX_FRAMES_IN_FLIGHT = 2`). -/
structure FrameSync where
  cmdBufs : Array UInt64 := #[]
  imageAvailableSems : Array UInt64 := #[]
  inFlightFences : Array UInt64 := #[]
  stagingBufs : Array VkGpuBuffer := #[]
  deriving Inhabited

/-- Live Vulkan WSI swapchain owner driven by the verified `SwapchainState` stepper. -/
structure VkWsiState where
  dev : VkDeviceCtx
  sm : SwapchainState := {}
  bundle : Option SwapchainBundle := none
  sync : FrameSync := {}
  /-- Last requested buffer extent `(reqW, reqH)` to avoid infinite recreate loops if the
  compositor clamps `surfaceCaps.currentExtent` to a different size. -/
  lastRequestedW : Nat := 0
  lastRequestedH : Nat := 0

private def createFence (dev : VkDeviceCtx) (signaled : Bool) : IO (Except String UInt64) :=
  withArena fun a => do
    let fci ← a.write (encFenceCreateInfo signaled)
    let out ← a.alloc 8
    let r ← callRes dev.fns.createFence dev.device fci.toUInt64 0 out.toUInt64
    if r != VK_SUCCESS then return .error s!"vkCreateFence failed ({r})"
    return .ok (← readU64Ptr out)

private def createSemaphore (dev : VkDeviceCtx) : IO (Except String UInt64) :=
  withArena fun a => do
    let sci ← a.write encSemaphoreCreateInfo
    let out ← a.alloc 8
    let r ← callRes dev.fns.createSemaphore dev.device sci.toUInt64 0 out.toUInt64
    if r != VK_SUCCESS then return .error s!"vkCreateSemaphore failed ({r})"
    return .ok (← readU64Ptr out)

def destroyFrameSync (dev : VkDeviceCtx) (sync : FrameSync) : IO Unit := do
  for f in sync.inFlightFences do
    if f != 0 then callVoid dev.fns.destroyFence dev.device f 0
  for s in sync.imageAvailableSems do
    if s != 0 then callVoid dev.fns.destroySemaphore dev.device s 0
  for b in sync.stagingBufs do
    destroyGpuBuffer dev b

def createFrameSync (dev : VkDeviceCtx) : IO (Except String FrameSync) := do
  let mut cmdBufs : Array UInt64 := #[]
  let cbRes ← withArena fun a => do
    let ai ← a.write (encCommandBufferAllocateInfo dev.cmdPool 2)
    let out ← a.alloc 16
    let r ← callRes dev.fns.allocateCommandBuffers dev.device ai.toUInt64 out.toUInt64
    if r != VK_SUCCESS then return Except.error s!"vkAllocateCommandBuffers failed ({r})"
    let raw ← LeanUI.FFI.memRead out 16
    return Except.ok #[getU64 raw 0, getU64 raw 8]
  match cbRes with
  | .error e => return .error e
  | .ok arr => cmdBufs := arr

  let mut sems : Array UInt64 := #[]
  let mut fences : Array UInt64 := #[]
  let mut stags : Array VkGpuBuffer := #[]
  for _ in [:2] do
    match ← createSemaphore dev with
    | .error e =>
      destroyFrameSync dev { cmdBufs, imageAvailableSems := sems, inFlightFences := fences, stagingBufs := stags }
      return .error e
    | .ok s => sems := sems.push s
    match ← createFence dev true with
    | .error e =>
      destroyFrameSync dev { cmdBufs, imageAvailableSems := sems, inFlightFences := fences, stagingBufs := stags }
      return .error e
    | .ok f => fences := fences.push f
    match ← createGpuBuffer dev stagingCapBytes VK_BUFFER_USAGE_TRANSFER_SRC_BIT
        (VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT ||| VK_MEMORY_PROPERTY_HOST_COHERENT_BIT) true with
    | .error e =>
      destroyFrameSync dev { cmdBufs, imageAvailableSems := sems, inFlightFences := fences, stagingBufs := stags }
      return .error e
    | .ok b => stags := stags.push b

  return .ok { cmdBufs, imageAvailableSems := sems, inFlightFences := fences, stagingBufs := stags }

def destroySwapchainBundle (dev : VkDeviceCtx) (b : SwapchainBundle) (destroySwapchainHandle : Bool := true) : IO Unit := do
  destroyGpuImage dev b.backingImage
  for s in b.renderFinishedSems do
    if s != 0 then callVoid dev.fns.destroySemaphore dev.device s 0
  for v in b.imageViews do
    if v != 0 then callVoid dev.fns.destroyImageView dev.device v 0
  if destroySwapchainHandle && b.swapchain != 0 then
    callVoid dev.fns.destroySwapchainKHR dev.device b.swapchain 0

private def selectSurfaceFormat (dev : VkDeviceCtx) : IO (Except String (UInt32 × UInt32)) :=
  withArena fun a => do
    let cntPtr ← a.u32 0
    let r0 ← callRes dev.fns.getPhysicalDeviceSurfaceFormatsKHR dev.physDevice dev.surface cntPtr.toUInt64 0
    if r0 != VK_SUCCESS then return .error s!"vkGetPhysicalDeviceSurfaceFormatsKHR failed ({r0})"
    let n := (← readU32Ptr cntPtr).toNat
    if n == 0 then return .error "surface advertises zero formats"
    let buf ← a.alloc (n * 8)
    let r1 ← callRes dev.fns.getPhysicalDeviceSurfaceFormatsKHR dev.physDevice dev.surface cntPtr.toUInt64 buf.toUInt64
    if r1 != VK_SUCCESS then return .error s!"vkGetPhysicalDeviceSurfaceFormatsKHR(2) failed ({r1})"
    let raw ← LeanUI.FFI.memRead buf (n * 8).toUSize
    let mut hasBgra : Bool := false
    let mut hasRgba : Bool := false
    for i in [:n] do
      let fmt := getU32 raw (i * 8)
      let cs := getU32 raw (i * 8 + 4)
      if cs == VK_COLOR_SPACE_SRGB_NONLINEAR_KHR then
        if fmt == VK_FORMAT_B8G8R8A8_UNORM then hasBgra := true
        else if fmt == VK_FORMAT_R8G8B8A8_UNORM then hasRgba := true
    if hasBgra then return .ok (VK_FORMAT_B8G8R8A8_UNORM, VK_COLOR_SPACE_SRGB_NONLINEAR_KHR)
    if hasRgba then return .ok (VK_FORMAT_R8G8B8A8_UNORM, VK_COLOR_SPACE_SRGB_NONLINEAR_KHR)
    return .error "surface lacks 8-bit *_UNORM sRGB-nonlinear format (rejecting *_SRGB)"

private def selectPresentMode (dev : VkDeviceCtx) : IO UInt32 :=
  withArena fun a => do
    let wantImmediate := (← IO.getEnv "ORB_LEANUI_PRESENT_MODE") == some "immediate"
    let cntPtr ← a.u32 0
    let r0 ← callRes dev.fns.getPhysicalDeviceSurfacePresentModesKHR dev.physDevice dev.surface cntPtr.toUInt64 0
    if r0 != VK_SUCCESS then return VK_PRESENT_MODE_FIFO_KHR
    let n := (← readU32Ptr cntPtr).toNat
    if n == 0 then return VK_PRESENT_MODE_FIFO_KHR
    let buf ← a.alloc (n * 4)
    let r1 ← callRes dev.fns.getPhysicalDeviceSurfacePresentModesKHR dev.physDevice dev.surface cntPtr.toUInt64 buf.toUInt64
    if r1 != VK_SUCCESS then return VK_PRESENT_MODE_FIFO_KHR
    let raw ← LeanUI.FFI.memRead buf (n * 4).toUSize
    let mut hasMailbox := false
    let mut hasImmediate := false
    for i in [:n] do
      let m := getU32 raw (i * 4)
      if m == VK_PRESENT_MODE_MAILBOX_KHR then hasMailbox := true
      if m == VK_PRESENT_MODE_IMMEDIATE_KHR then hasImmediate := true
    if wantImmediate && hasImmediate then return VK_PRESENT_MODE_IMMEDIATE_KHR
    if hasMailbox then return VK_PRESENT_MODE_MAILBOX_KHR
    return VK_PRESENT_MODE_FIFO_KHR

/-- Create or recreate the swapchain for `(reqW, reqH)`. Unconditionally destroys `oldBundle`
even if `vkCreateSwapchainKHR` fails (Invariant 3), and always returns an updated `VkWsiState`
with `bundle := none` on error so callers can never double-destroy freed handles. -/
def recreateSwapchain (wsi : VkWsiState) (reqW reqH : Nat) : IO (VkWsiState × Except String Unit) := do
  let dev := wsi.dev
  waitDeviceIdle dev
  if reqW == 0 || reqH == 0 then
    if let some old := wsi.bundle then
      destroySwapchainBundle dev old true
    return ({ wsi with bundle := none, sm := wsi.sm.initOrRecreate 0 0 0, lastRequestedW := reqW, lastRequestedH := reqH }, .ok ())

  let oldHandle : UInt64 := wsi.bundle.map (·.swapchain) |>.getD 0
  if let some old := wsi.bundle then
    destroySwapchainBundle dev old false
  let cleared : VkWsiState := { wsi with bundle := none }

  let destroyOldHandle : IO Unit := do
    if oldHandle != 0 then callVoid dev.fns.destroySwapchainKHR dev.device oldHandle 0
  let fail (e : String) : IO (VkWsiState × Except String Unit) := do
    return ({ cleared with sm := cleared.sm.onDeviceLost }, .error e)

  -- Query surface capabilities
  let capsRes ← withArena fun a => do
    let p ← a.alloc 52
    let r ← callRes dev.fns.getPhysicalDeviceSurfaceCapabilitiesKHR dev.physDevice dev.surface p.toUInt64
    if r != VK_SUCCESS then return Except.error s!"vkGetPhysicalDeviceSurfaceCapabilitiesKHR failed ({r})"
    return Except.ok (← LeanUI.FFI.memRead p 52)
  let capsRaw ← match capsRes with
    | .error e => destroyOldHandle; return ← fail e
    | .ok raw => pure raw

  let minCount := getU32 capsRaw 0
  let maxCount := getU32 capsRaw 4
  let curW := getU32 capsRaw 8
  let curH := getU32 capsRaw 12
  let minW := (getU32 capsRaw 16).toNat
  let minH := (getU32 capsRaw 20).toNat
  let maxW := (getU32 capsRaw 24).toNat
  let maxH := (getU32 capsRaw 28).toNat
  let curTransform := getU32 capsRaw 40
  let supAlpha := getU32 capsRaw 44
  let supUsage := getU32 capsRaw 48

  let (fmt, colorSpace) ← match ← selectSurfaceFormat dev with
    | .error e => destroyOldHandle; return ← fail e
    | .ok p => pure p
  let presentMode ← selectPresentMode dev

  let fmtFeats ← queryOptimalFormatFeatures dev fmt
  let hasColorAttach := (supUsage &&& VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT) != 0
  let hasTransferDst := (supUsage &&& VK_IMAGE_USAGE_TRANSFER_DST_BIT) != 0
  let hasTransferSrc := (supUsage &&& VK_IMAGE_USAGE_TRANSFER_SRC_BIT) != 0
  let canBlitDst := (fmtFeats &&& VK_FORMAT_FEATURE_BLIT_DST_BIT) != 0
  let canBlitSrc := (fmtFeats &&& VK_FORMAT_FEATURE_BLIT_SRC_BIT) != 0
  if !hasColorAttach || !hasTransferDst then
    destroyOldHandle
    return ← fail "swapchain lacks required COLOR_ATTACHMENT | TRANSFER_DST usage"
  if fmt != VK_FORMAT_R8G8B8A8_UNORM && !canBlitDst then
    destroyOldHandle
    return ← fail "swapchain format lacks VK_FORMAT_FEATURE_BLIT_DST_BIT for hardware swizzle"

  let usage : UInt32 :=
    VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT ||| VK_IMAGE_USAGE_TRANSFER_DST_BIT |||
    (if hasTransferSrc then VK_IMAGE_USAGE_TRANSFER_SRC_BIT else 0)
  let compositeAlpha : UInt32 :=
    if (supAlpha &&& VK_COMPOSITE_ALPHA_PRE_MULTIPLIED_BIT_KHR) != 0 then
      VK_COMPOSITE_ALPHA_PRE_MULTIPLIED_BIT_KHR
    else VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR

  let extentW : Nat :=
    if curW != 0xFFFFFFFF then curW.toNat else max minW (min maxW reqW)
  let extentH : Nat :=
    if curH != 0xFFFFFFFF then curH.toNat else max minH (min maxH reqH)
  if extentW == 0 || extentH == 0 then
    destroyOldHandle
    return ({ cleared with sm := cleared.sm.initOrRecreate 0 0 0, lastRequestedW := reqW, lastRequestedH := reqH }, .ok ())

  let desiredCount : UInt32 :=
    let base := if presentMode == VK_PRESENT_MODE_MAILBOX_KHR then max 3 minCount else max 2 (minCount + 1)
    if maxCount > 0 && base > maxCount then maxCount else base

  let scRes ← withArena fun a => do
    let sci ← a.write (encSwapchainCreateInfo dev.surface desiredCount fmt colorSpace
      extentW.toUInt32 extentH.toUInt32 usage curTransform compositeAlpha presentMode oldHandle)
    let out ← a.alloc 8
    let r ← callRes dev.fns.createSwapchainKHR dev.device sci.toUInt64 0 out.toUInt64
    if r != VK_SUCCESS then return Except.error s!"vkCreateSwapchainKHR failed ({r})"
    return Except.ok (← readU64Ptr out)

  -- Unconditionally destroy oldSwapchain handle after vkCreateSwapchainKHR returns
  destroyOldHandle

  let swapchain ← match scRes with
    | .error e => return ← fail e
    | .ok h => pure h

  -- Fetch swapchain images
  let imgsRes ← withArena fun a => do
    let cntPtr ← a.u32 0
    let r0 ← callRes dev.fns.getSwapchainImagesKHR dev.device swapchain cntPtr.toUInt64 0
    if r0 != VK_SUCCESS then return Except.error s!"vkGetSwapchainImagesKHR failed ({r0})"
    let n := (← readU32Ptr cntPtr).toNat
    if n < 2 then return Except.error s!"swapchain returned fewer than 2 images ({n})"
    let buf ← a.alloc (n * 8)
    let r1 ← callRes dev.fns.getSwapchainImagesKHR dev.device swapchain cntPtr.toUInt64 buf.toUInt64
    if r1 != VK_SUCCESS then return Except.error s!"vkGetSwapchainImagesKHR(2) failed ({r1})"
    let raw ← LeanUI.FFI.memRead buf (n * 8).toUSize
    let mut arr : Array UInt64 := #[]
    for i in [:n] do arr := arr.push (getU64 raw (i * 8))
    return Except.ok arr

  let images ← match imgsRes with
    | .error e =>
      callVoid dev.fns.destroySwapchainKHR dev.device swapchain 0
      return ← fail e
    | .ok arr => pure arr

  let mut views : Array UInt64 := #[]
  let mut sems : Array UInt64 := #[]
  for img in images do
    match ← createImageView dev img VK_IMAGE_VIEW_TYPE_2D fmt 0 1 with
    | .error e =>
      destroySwapchainBundle dev { swapchain, imageViews := views, renderFinishedSems := sems } true
      return ← fail e
    | .ok v => views := views.push v
    match ← createSemaphore dev with
    | .error e =>
      destroySwapchainBundle dev { swapchain, imageViews := views, renderFinishedSems := sems } true
      return ← fail e
    | .ok s => sems := sems.push s

  -- Allocate persistent Phase 1 backing image (`R8G8B8A8_UNORM`)
  let backing ← match ← createGpuImage dev extentW extentH 1 VK_FORMAT_R8G8B8A8_UNORM
      (VK_IMAGE_USAGE_TRANSFER_DST_BIT ||| VK_IMAGE_USAGE_TRANSFER_SRC_BIT ||| VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT ||| VK_IMAGE_USAGE_SAMPLED_BIT) with
    | .error e =>
      destroySwapchainBundle dev { swapchain, imageViews := views, renderFinishedSems := sems } true
      return ← fail e
    | .ok im => pure im

  let bundle : SwapchainBundle := {
    swapchain, extentW, extentH, format := fmt, compositeAlpha, presentMode
    canBlitDst, canBlitSrc, canTransferSrc := hasTransferSrc
    images, imageViews := views, renderFinishedSems := sems
    backingImage := backing, backingNeedsFullUpload := true, backingInitialized := false
  }
  return ({ cleared with
    bundle := some bundle
    sm := cleared.sm.initOrRecreate extentW extentH images.size
    lastRequestedW := reqW
    lastRequestedH := reqH }, .ok ())

/-- Initialize a `VkWsiState` on `(wlDisplay, wlSurface)` for `(initW, initH)`. -/
def createWsi (wlDisplay wlSurface : USize) (initW initH : Nat)
    (allowSoftwareIcd enableValidation : Bool) : IO (Except String VkWsiState) := do
  match ← createDevice wlDisplay wlSurface true allowSoftwareIcd enableValidation with
  | .error e => return .error e
  | .ok dev =>
    match ← createFrameSync dev with
    | .error e =>
      destroyDevice dev
      return .error e
    | .ok sync =>
      let wsi0 : VkWsiState := { dev, sm := {}, bundle := none, sync }
      let (wsi1, r) ← recreateSwapchain wsi0 initW initH
      match r with
      | .error e =>
        destroyFrameSync dev sync
        destroyDevice dev
        return .error e
      | .ok () => return .ok wsi1

/-- Destroy all WSI swapchain/sync/device resources in strict reverse lifecycle order (Invariant 4). -/
def destroyWsi (wsi : VkWsiState) : IO SwapchainState := do
  let dev := wsi.dev
  waitDeviceIdle dev
  if let some b := wsi.bundle then
    destroySwapchainBundle dev b true
  destroyFrameSync dev wsi.sync
  destroyDevice dev
  return wsi.sm.destroy

/-- Record a single `vkCmdPipelineBarrier2` image layout transition. -/
def cmdTransitionImage (dev : VkDeviceCtx) (cb : UInt64) (image : UInt64)
    (srcStage srcAccess dstStage dstAccess : UInt64) (oldLayout newLayout : UInt32)
    (baseLayer : UInt32 := 0) (layerCount : UInt32 := 1) : IO Unit :=
  withArena fun a => do
    let bar ← a.write (encImageMemoryBarrier2 srcStage srcAccess dstStage dstAccess oldLayout newLayout image baseLayer layerCount)
    let dep ← a.write (encDependencyInfo 1 bar)
    callVoid dev.fns.cmdPipelineBarrier2 cb dep.toUInt64

/-- Wait on a single `VkFence`. -/
def waitFence (dev : VkDeviceCtx) (fence : UInt64) : IO Int :=
  withArena fun a => do
    let p ← a.u64 fence
    callRes dev.fns.waitForFences dev.device 1 p.toUInt64 VK_TRUE.toUInt64 0xFFFFFFFFFFFFFFFF

/-- Reset a single `VkFence`. -/
def resetFence (dev : VkDeviceCtx) (fence : UInt64) : IO Int :=
  withArena fun a => do
    let p ← a.u64 fence
    callRes dev.fns.resetFences dev.device 1 p.toUInt64

/-- Submit a one-shot command buffer (no semaphores) and wait on `fence` to finish. -/
def submitAndWaitSync (dev : VkDeviceCtx) (cb fence : UInt64) : IO Int :=
  withArena fun a => do
    let _ ← resetFence dev fence
    let cbi ← a.write (encCommandBufferSubmitInfo cb)
    let si ← a.write (encSubmitInfo2 0 0 cbi 0 0)
    let r ← callRes dev.fns.queueSubmit2 dev.queue 1 si.toUInt64 fence
    if r != VK_SUCCESS then return r
    waitFence dev fence

/-- Acquire next swapchain image following `SwapchainState` (waits on slot fence,
NEVER resets fence before acquire, enforces cross-slot `MAILBOX` `imageFence` wait).
Returns `(imgIdx, slot, bundle, acqNs, recreated)` on success. -/
def acquireSwapchainImage (wsi : VkWsiState) (reqW reqH : Nat) :
    IO (VkWsiState × Except PresentOutcome (Nat × Fin 2 × SwapchainBundle × UInt64 × Bool)) := do
  let mut st := wsi
  let mut recreated := false
  if reqW == 0 || reqH == 0 then
    let (st', r) ← recreateSwapchain st 0 0
    match r with
    | .ok () => return (st', .error .skipped)
    | .error e => return (st', .error (.deviceLost e))
  let isPhaseReady : Bool := match st.sm.phase with
    | .ready w h n => w > 0 && h > 0 && n ≥ 2
    | _ => false
  let extentChanged : Bool :=
    !st.sm.isReadyForExtent reqW reqH && (st.lastRequestedW != reqW || st.lastRequestedH != reqH)
  if st.bundle.isNone || !isPhaseReady || extentChanged then
    let (st', r) ← recreateSwapchain st reqW reqH
    match r with
    | .ok () => st := st'; recreated := true
    | .error e => return (st', .error (.deviceLost e))
  let some bundle := st.bundle | return (st, .error .skipped)
  let dev := st.dev
  let slot := st.sm.curSlot
  let slotIdx := SwapchainState.imageAvailableSemIndex slot
  let fence := st.sync.inFlightFences[slotIdx]!
  let imgAvail := st.sync.imageAvailableSems[slotIdx]!

  let t0 ← IO.monoNanosNow
  let wr ← waitFence dev fence
  if wr != VK_SUCCESS then
    return ({ st with sm := st.sm.onDeviceLost }, .error (.deviceLost s!"vkWaitForFences failed ({wr})"))
  st := { st with sm := st.sm.waitSlotFence slot }

  let (acqRes, imgIdx) ← withArena fun a => do
    let outIdx ← a.u32 0
    let r ← callRes dev.fns.acquireNextImageKHR dev.device bundle.swapchain 0xFFFFFFFFFFFFFFFF imgAvail 0 outIdx.toUInt64
    let idx := (← readU32Ptr outIdx).toNat
    return (r, idx)
  let t1 ← IO.monoNanosNow

  if acqRes == VK_ERROR_OUT_OF_DATE_KHR || acqRes == VK_ERROR_SURFACE_LOST_KHR then
    st := { st with sm := st.sm.onAcquire .outOfDate 0 }
    return (st, .error .needsRecreate)
  if acqRes == VK_ERROR_DEVICE_LOST || (acqRes != VK_SUCCESS && acqRes != VK_SUBOPTIMAL_KHR) then
    st := { st with sm := st.sm.onAcquire .deviceLost 0 }
    return (st, .error (.deviceLost s!"vkAcquireNextImageKHR failed ({acqRes})"))

  -- Cross-slot MAILBOX re-acquire fence guard (Invariant 1d)
  if let some (some prevSlot) := st.sm.imageFence[imgIdx]? then
    if prevSlot != slot then
      let prevFence := st.sync.inFlightFences[prevSlot.val]!
      let wr2 ← waitFence dev prevFence
      if wr2 != VK_SUCCESS then
        return ({ st with sm := st.sm.onDeviceLost }, .error (.deviceLost s!"cross-slot vkWaitForFences failed ({wr2})"))

  let wsiRes : WsiResult := if acqRes == VK_SUBOPTIMAL_KHR then .suboptimal else .success
  st := { st with sm := st.sm.onAcquire wsiRes imgIdx }
  return (st, .ok (imgIdx, slot, bundle, (t1 - t0).toUInt64, recreated))

/-- Submit the recorded `cb` and call `vkQueuePresentKHR` (calling `prePresent` right before
present so `wp_viewport.set_destination` + `wl_surface.frame` commit atomically). -/
def submitAndPresentSwapchain (wsi : VkWsiState) (slot : Fin 2) (imgIdx : Nat)
    (bundle : SwapchainBundle) (dirtyOpt : Option Rect) (prePresent : IO Unit) :
    IO (VkWsiState × UInt64 × UInt64 × Except String Bool) := do
  let dev := wsi.dev
  let slotIdx := SwapchainState.imageAvailableSemIndex slot
  let cb := wsi.sync.cmdBufs[slotIdx]!
  let fence := wsi.sync.inFlightFences[slotIdx]!
  let imgAvail := wsi.sync.imageAvailableSems[slotIdx]!
  let renderFin := bundle.renderFinishedSems[SwapchainState.renderFinishedSemIndex imgIdx]!

  let ts0 ← IO.monoNanosNow
  -- No-deadlock fence rule: reset strictly AFTER acquire succeeded and right before submit!
  let rr ← resetFence dev fence
  if rr != VK_SUCCESS then
    return ({ wsi with sm := wsi.sm.onDeviceLost }, 0, 0, .error s!"vkResetFences failed ({rr})")

  let sr ← withArena fun a => do
    let wSem ← a.write (encSemaphoreSubmitInfo imgAvail (VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT ||| VK_PIPELINE_STAGE_2_TRANSFER_BIT))
    let cbi ← a.write (encCommandBufferSubmitInfo cb)
    let sSem ← a.write (encSemaphoreSubmitInfo renderFin VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT)
    let si ← a.write (encSubmitInfo2 1 wSem cbi 1 sSem)
    callRes dev.fns.queueSubmit2 dev.queue 1 si.toUInt64 fence
  let ts1 ← IO.monoNanosNow
  if sr != VK_SUCCESS then
    return ({ wsi with sm := wsi.sm.onDeviceLost }, (ts1 - ts0).toUInt64, 0, .error s!"vkQueueSubmit2 failed ({sr})")

  prePresent

  let tp0 ← IO.monoNanosNow
  let pr ← withArena fun a => do
    let waitPtr ← a.u64 renderFin
    let scPtr ← a.u64 bundle.swapchain
    let idxPtr ← a.u32 imgIdx.toUInt32
    let pNext ←
      if dev.hasIncrementalPresent then
        match dirtyOpt with
        | some d =>
          let cx := max 0 d.x
          let cy := max 0 d.y
          let cw := min (bundle.extentW - cx.toNat) (max 0 d.w).toNat
          let ch := min (bundle.extentH - cy.toNat) (max 0 d.h).toNat
          if cw > 0 && ch > 0 then
            let rl ← a.write (encRectLayerKHR cx cy cw.toUInt32 ch.toUInt32)
            let prg ← a.write (encPresentRegionKHR 1 rl)
            a.write (encPresentRegionsKHR prg)
          else pure 0
        | none => pure 0
      else pure 0
    let pi ← a.write (encPresentInfoKHR pNext waitPtr scPtr idxPtr)
    callRes dev.fns.queuePresentKHR dev.queue pi.toUInt64
  let tp1 ← IO.monoNanosNow

  let wsiRes : WsiResult :=
    if pr == VK_SUCCESS then .success
    else if pr == VK_SUBOPTIMAL_KHR then .suboptimal
    else if pr == VK_ERROR_OUT_OF_DATE_KHR then .outOfDate
    else if pr == VK_ERROR_SURFACE_LOST_KHR then .surfaceLost
    else .deviceLost
  let sm' := wsi.sm.onSubmitAndPresent bundle.extentW bundle.extentH imgIdx wsiRes
  if wsiRes == .deviceLost then
    return ({ wsi with sm := sm' }, (ts1 - ts0).toUInt64, (tp1 - tp0).toUInt64, .error s!"vkQueuePresentKHR failed ({pr})")
  let committed := wsiRes == .success || wsiRes == .suboptimal
  return ({ wsi with sm := sm' }, (ts1 - ts0).toUInt64, (tp1 - tp0).toUInt64, .ok committed)

/-- Phase 1 (`vkPresent`): upload ONLY `dirtyOpt` (or full viewport after backing init) via
bounded `4 MiB` chunked row strips into the persistent `R8G8B8A8_UNORM` backing image, then
GPU-blit/copy to the acquired swapchain image and present. -/
def presentCpuDirty (wsi : VkWsiState) (fb : ByteArray) (fbW fbH : Nat)
    (dirtyOpt : Option Rect) (prePresent : IO Unit) (onPresentAborted : IO Unit) :
    IO (VkWsiState × PresentOutcome) := do
  if fbW == 0 || fbH == 0 then
    let (st0, r) ← recreateSwapchain wsi 0 0
    return match r with
      | .ok () => (st0, .skipped)
      | .error e => (st0, .deviceLost e)
  if fb.size != fbW * fbH * 4 then
    return (wsi, .skipped)
  let (st1, acq) ← acquireSwapchainImage wsi fbW fbH
  match acq with
  | .error .needsRecreate =>
    -- Retry once after immediate recreation on OUT_OF_DATE
    let (st2, rRec) ← recreateSwapchain st1 fbW fbH
    match rRec with
    | .error e => return (st2, .deviceLost e)
    | .ok () =>
      let (st3, acq2) ← acquireSwapchainImage st2 fbW fbH
      match acq2 with
      | .error e2 => return (st3, e2)
      | .ok (imgIdx, slot, bundle, acqNs, _) =>
        presentCpuAcquired st3 imgIdx slot bundle fb fbW fbH dirtyOpt acqNs true prePresent onPresentAborted
  | .error e => return (st1, e)
  | .ok (imgIdx, slot, bundle, acqNs, recreated) =>
    presentCpuAcquired st1 imgIdx slot bundle fb fbW fbH dirtyOpt acqNs recreated prePresent onPresentAborted
where
  presentCpuAcquired (st : VkWsiState) (imgIdx : Nat) (slot : Fin 2) (bundle : SwapchainBundle)
      (fb : ByteArray) (fbW fbH : Nat) (dirtyOpt : Option Rect) (acqNs : UInt64) (recreated : Bool)
      (prePresent onPresentAborted : IO Unit) : IO (VkWsiState × PresentOutcome) := do
    let dev := st.dev
    let slotIdx := slot.val
    let cb := st.sync.cmdBufs[slotIdx]!
    let fence := st.sync.inFlightFences[slotIdx]!
    let stag := st.sync.stagingBufs[slotIdx]!
    let maxW := min fbW bundle.extentW
    let maxH := min fbH bundle.extentH
    let fullRect : Rect := ⟨0, 0, maxW, maxH⟩
    let uploadRect : Option Rect :=
      if bundle.backingNeedsFullUpload || recreated then some fullRect else dirtyOpt

    let tu0 ← IO.monoNanosNow
    let mut uploadedBytes : Nat := 0
    let mut backingLayout : UInt32 :=
      if bundle.backingInitialized then VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL else VK_IMAGE_LAYOUT_UNDEFINED

    -- Upload dirty rect (chunked in row strips if > 4 MiB staging cap)
    let mut pendingFinalStrip : Option (Nat × Nat × Nat × Nat) := none
    if let some r := uploadRect then
      let rx := max 0 r.x |>.toNat
      let ry := max 0 r.y |>.toNat
      let rw := min (maxW - min maxW rx) (max 0 r.w).toNat
      let rh := min (maxH - min maxH ry) (max 0 r.h).toNat
      if rw > 0 && rh > 0 then
        let rowBytes := rw * 4
        let stripMaxH := max 1 (stag.size / max 4 rowBytes)
        let mut curY := ry
        let endY := ry + rh
        while curY < endY do
          let sh := min stripMaxH (endY - curY)
          let bytes := rowBytes * sh
          uploadedBytes := uploadedBytes + bytes
          if curY + sh < endY then
            -- Intermediate chunk: upload synchronously into backingImage before overwriting staging
            LeanUI.FFI.vkCopyRect stag.mappedPtr stag.size.toUSize fb
              ((curY * fbW + rx) * 4).toUSize (fbW * 4).toUSize rowBytes.toUSize sh.toUSize
            let _ ← callRes dev.fns.resetCommandBuffer cb 0
            withArena fun a => do
              let bi ← a.write (encCommandBufferBeginInfo)
              let _ ← callRes dev.fns.beginCommandBuffer cb bi.toUInt64
              let srcAcc := if backingLayout == VK_IMAGE_LAYOUT_UNDEFINED then VK_ACCESS_2_NONE
                else (VK_ACCESS_2_TRANSFER_READ_BIT ||| VK_ACCESS_2_TRANSFER_WRITE_BIT)
              cmdTransitionImage dev cb bundle.backingImage.image
                VK_PIPELINE_STAGE_2_TRANSFER_BIT srcAcc
                VK_PIPELINE_STAGE_2_COPY_BIT VK_ACCESS_2_TRANSFER_WRITE_BIT
                backingLayout VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL
              let reg ← a.write (encBufferImageCopy2 0 0 rx curY rw.toUInt32 sh.toUInt32)
              let cpy ← a.write (encCopyBufferToImageInfo2 stag.buffer bundle.backingImage.image VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL 1 reg)
              callVoid dev.fns.cmdCopyBufferToImage2 cb cpy.toUInt64
              let _ ← callRes dev.fns.endCommandBuffer cb
            let sr ← submitAndWaitSync dev cb fence
            if sr != VK_SUCCESS then
              return ({ st with sm := st.sm.onDeviceLost }, .deviceLost s!"chunk upload failed ({sr})")
            backingLayout := VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL
          else
            -- Final chunk (or the only chunk): stage into stag and include in main command buffer
            LeanUI.FFI.vkCopyRect stag.mappedPtr stag.size.toUSize fb
              ((curY * fbW + rx) * 4).toUSize (fbW * 4).toUSize rowBytes.toUSize sh.toUSize
            pendingFinalStrip := some (rx, curY, rw, sh)
          curY := curY + sh
    let tu1 ← IO.monoNanosNow

    -- Record main command buffer: final copy strip -> blit/copy backing -> swapchain -> PRESENT_SRC
    let _ ← callRes dev.fns.resetCommandBuffer cb 0
    withArena fun a => do
      let bi ← a.write (encCommandBufferBeginInfo)
      let _ ← callRes dev.fns.beginCommandBuffer cb bi.toUInt64
      let mut curBL := backingLayout
      if let some (rx, ry, rw, sh) := pendingFinalStrip then
        let srcAcc := if curBL == VK_IMAGE_LAYOUT_UNDEFINED then VK_ACCESS_2_NONE
          else (VK_ACCESS_2_TRANSFER_READ_BIT ||| VK_ACCESS_2_TRANSFER_WRITE_BIT)
        cmdTransitionImage dev cb bundle.backingImage.image
          VK_PIPELINE_STAGE_2_TRANSFER_BIT srcAcc
          VK_PIPELINE_STAGE_2_COPY_BIT VK_ACCESS_2_TRANSFER_WRITE_BIT
          curBL VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL
        let reg ← a.write (encBufferImageCopy2 0 0 rx ry rw.toUInt32 sh.toUInt32)
        let cpy ← a.write (encCopyBufferToImageInfo2 stag.buffer bundle.backingImage.image VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL 1 reg)
        callVoid dev.fns.cmdCopyBufferToImage2 cb cpy.toUInt64
        curBL := VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL

      cmdTransitionImage dev cb bundle.backingImage.image
        VK_PIPELINE_STAGE_2_TRANSFER_BIT VK_ACCESS_2_TRANSFER_WRITE_BIT
        VK_PIPELINE_STAGE_2_TRANSFER_BIT VK_ACCESS_2_TRANSFER_READ_BIT
        curBL VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL

      let scImg := bundle.images[imgIdx]!
      cmdTransitionImage dev cb scImg
        VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT VK_ACCESS_2_NONE
        VK_PIPELINE_STAGE_2_TRANSFER_BIT VK_ACCESS_2_TRANSFER_WRITE_BIT
        VK_IMAGE_LAYOUT_UNDEFINED VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL

      if bundle.format == VK_FORMAT_R8G8B8A8_UNORM then
        let reg ← a.write (encImageCopy2 0 0 0 0 bundle.extentW.toUInt32 bundle.extentH.toUInt32)
        let info ← a.write (encCopyImageInfo2 bundle.backingImage.image VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL
          scImg VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL 1 reg)
        callVoid dev.fns.cmdCopyImage2 cb info.toUInt64
      else
        let reg ← a.write (encImageBlit2 0 0 bundle.extentW bundle.extentH 0 0 bundle.extentW bundle.extentH)
        let info ← a.write (encBlitImageInfo2 bundle.backingImage.image VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL
          scImg VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL 1 reg VK_FILTER_NEAREST)
        callVoid dev.fns.cmdBlitImage2 cb info.toUInt64

      cmdTransitionImage dev cb scImg
        VK_PIPELINE_STAGE_2_TRANSFER_BIT VK_ACCESS_2_TRANSFER_WRITE_BIT
        VK_PIPELINE_STAGE_2_NONE VK_ACCESS_2_NONE
        VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL VK_IMAGE_LAYOUT_PRESENT_SRC_KHR
      let _ ← callRes dev.fns.endCommandBuffer cb

    let bundle' := { bundle with backingNeedsFullUpload := false, backingInitialized := true }
    let stB := { st with bundle := some bundle' }
    let presentDirty := if recreated || bundle.backingNeedsFullUpload then none else uploadRect
    let (st2, subNs, presNs, res) ← submitAndPresentSwapchain stB slot imgIdx bundle' presentDirty prePresent
    match res with
    | .error e =>
      onPresentAborted
      return (st2, .deviceLost e)
    | .ok committed =>
      if !committed then
        onPresentAborted
        let stRetry := { st2 with bundle := some { bundle' with backingNeedsFullUpload := true } }
        return (stRetry, .needsRecreate)
      return (st2, .presented uploadedBytes acqNs (tu1 - tu0).toUInt64 subNs presNs)

end LeanUI.Vk
