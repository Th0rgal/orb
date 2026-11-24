import LeanUI.VulkanStructs
/-!
# LeanUI.VulkanDevice — Dynamic `libvulkan.so.1` Loader, Device Selection & Resource Helpers

Loads `libvulkan.so.1` strictly via `dlopen` / `dlsym` (`LeanUI.FFI.dlSym`), resolves all
Vulkan 1.3 instance/device entry points through `vkGetInstanceProcAddr` / `vkGetDeviceProcAddr`,
enforces the Software ICD policy (automatically falling back to `wl_shm` on CPU/Lavapipe ICDs
unless `allowSoftwareIcd := true` is explicitly requested), and tracks total active
`VkDeviceMemory` allocations (`gpuAllocatedBytes`).
-/
namespace LeanUI.Vk

/-- Resolved Vulkan 1.3 instance and device function pointer table. -/
structure VkFns where
  getInstanceProcAddr : USize := 0
  createInstance : USize := 0
  destroyInstance : USize := 0
  enumeratePhysicalDevices : USize := 0
  getPhysicalDeviceProperties : USize := 0
  getPhysicalDeviceFeatures2 : USize := 0
  getPhysicalDeviceQueueFamilyProperties : USize := 0
  getPhysicalDeviceMemoryProperties : USize := 0
  getPhysicalDeviceFormatProperties : USize := 0
  enumerateDeviceExtensionProperties : USize := 0
  getPhysicalDeviceWaylandPresentationSupportKHR : USize := 0
  getPhysicalDeviceSurfaceSupportKHR : USize := 0
  getPhysicalDeviceSurfaceCapabilitiesKHR : USize := 0
  getPhysicalDeviceSurfaceFormatsKHR : USize := 0
  getPhysicalDeviceSurfacePresentModesKHR : USize := 0
  createWaylandSurfaceKHR : USize := 0
  destroySurfaceKHR : USize := 0
  createDevice : USize := 0
  getDeviceProcAddr : USize := 0
  destroyDevice : USize := 0
  getDeviceQueue : USize := 0
  deviceWaitIdle : USize := 0
  createSwapchainKHR : USize := 0
  destroySwapchainKHR : USize := 0
  getSwapchainImagesKHR : USize := 0
  acquireNextImageKHR : USize := 0
  queuePresentKHR : USize := 0
  createCommandPool : USize := 0
  destroyCommandPool : USize := 0
  allocateCommandBuffers : USize := 0
  beginCommandBuffer : USize := 0
  endCommandBuffer : USize := 0
  resetCommandBuffer : USize := 0
  createFence : USize := 0
  destroyFence : USize := 0
  waitForFences : USize := 0
  resetFences : USize := 0
  createSemaphore : USize := 0
  destroySemaphore : USize := 0
  queueSubmit2 : USize := 0
  createBuffer : USize := 0
  destroyBuffer : USize := 0
  getBufferMemoryRequirements : USize := 0
  bindBufferMemory : USize := 0
  createImage : USize := 0
  destroyImage : USize := 0
  getImageMemoryRequirements : USize := 0
  bindImageMemory : USize := 0
  createImageView : USize := 0
  destroyImageView : USize := 0
  createSampler : USize := 0
  destroySampler : USize := 0
  allocateMemory : USize := 0
  freeMemory : USize := 0
  mapMemory : USize := 0
  unmapMemory : USize := 0
  invalidateMappedMemoryRanges : USize := 0
  createShaderModule : USize := 0
  destroyShaderModule : USize := 0
  createDescriptorSetLayout : USize := 0
  destroyDescriptorSetLayout : USize := 0
  createDescriptorPool : USize := 0
  destroyDescriptorPool : USize := 0
  allocateDescriptorSets : USize := 0
  updateDescriptorSets : USize := 0
  createPipelineLayout : USize := 0
  destroyPipelineLayout : USize := 0
  createPipelineCache : USize := 0
  destroyPipelineCache : USize := 0
  getPipelineCacheData : USize := 0
  createGraphicsPipelines : USize := 0
  createComputePipelines : USize := 0
  destroyPipeline : USize := 0
  cmdPipelineBarrier2 : USize := 0
  cmdCopyBufferToImage2 : USize := 0
  cmdCopyImageToBuffer2 : USize := 0
  cmdBlitImage2 : USize := 0
  cmdCopyImage2 : USize := 0
  cmdClearColorImage : USize := 0
  cmdBeginRendering : USize := 0
  cmdEndRendering : USize := 0
  cmdBindPipeline : USize := 0
  cmdBindDescriptorSets : USize := 0
  cmdSetViewport : USize := 0
  cmdSetScissor : USize := 0
  cmdPushConstants : USize := 0
  cmdDraw : USize := 0
  cmdDispatch : USize := 0
  deriving Inhabited

/-- Allocated GPU buffer with optional persistently mapped CPU pointer. -/
structure VkGpuBuffer where
  buffer : UInt64 := 0
  memory : UInt64 := 0
  size : Nat := 0
  mappedPtr : USize := 0
  deriving Inhabited

/-- Allocated GPU image + view + tracked layout. -/
structure VkGpuImage where
  image : UInt64 := 0
  memory : UInt64 := 0
  view : UInt64 := 0
  width : Nat := 0
  height : Nat := 0
  layers : Nat := 1
  format : UInt32 := VK_FORMAT_R8G8B8A8_UNORM
  allocBytes : Nat := 0
  deriving Inhabited

/-- Live Vulkan 1.3 instance, physical/logical device, queue, and memory properties. -/
structure VkDeviceCtx where
  fns : VkFns := {}
  vkInstance : UInt64 := 0
  surface : UInt64 := 0
  physDevice : UInt64 := 0
  device : UInt64 := 0
  queue : UInt64 := 0
  queueFamily : UInt32 := 0
  cmdPool : UInt64 := 0
  deviceName : String := ""
  deviceType : UInt32 := 0
  hasIncrementalPresent : Bool := false
  hasDynamicRendering : Bool := false
  memPropsRaw : ByteArray := ByteArray.empty
  allocatedBytes : IO.Ref Nat

private def resolveInstProc (getProc : USize) (inst : UInt64) (name : String) : IO USize :=
  withArena fun a => do
    let namePtr ← a.cstr name
    callPtr getProc inst namePtr.toUInt64

private def resolveDevProc (getDevProc : USize) (dev : UInt64) (name : String) : IO USize :=
  withArena fun a => do
    let namePtr ← a.cstr name
    callPtr getDevProc dev namePtr.toUInt64

private def deviceTypeScore (dt : UInt32) : Nat :=
  if dt == VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU then 400
  else if dt == VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU then 380
  else if dt == VK_PHYSICAL_DEVICE_TYPE_VIRTUAL_GPU then 200
  else if dt == VK_PHYSICAL_DEVICE_TYPE_CPU then 50
  else 10

private def hasExtension (exts : Array String) (target : String) : Bool :=
  exts.any (· == target)

private def queryDeviceExtensions (fnEnum : USize) (phys : UInt64) : IO (Array String) :=
  withArena fun a => do
    let cntPtr ← a.u32 0
    let r0 ← callRes fnEnum phys 0 cntPtr.toUInt64 0
    if r0 != VK_SUCCESS then return #[]
    let count := (← readU32Ptr cntPtr).toNat
    if count == 0 then return #[]
    let bufPtr ← a.alloc (count * 260)
    let r1 ← callRes fnEnum phys 0 cntPtr.toUInt64 bufPtr.toUInt64
    if r1 != VK_SUCCESS then return #[]
    let raw ← LeanUI.FFI.memRead bufPtr (count * 260).toUSize
    let mut out : Array String := #[]
    for i in [:count] do
      out := out.push (getCString raw (i * 260) 256)
    return out

/-- Find a Vulkan memory type index matching `typeBits` and `requiredProps`. -/
def findMemoryType (memPropsRaw : ByteArray) (typeBits : UInt32) (requiredProps : UInt32) : Option UInt32 := Id.run do
  if memPropsRaw.size < 264 then return none
  let count := min 32 (getU32 memPropsRaw 0).toNat
  for i in [:count] do
    let bit : UInt32 := (1 : UInt32) <<< i.toUInt32
    if (typeBits &&& bit) != 0 then
      let props := getU32 memPropsRaw (4 + i * 8)
      if (props &&& requiredProps) == requiredProps then
        return some i.toUInt32
  return none

/-- Create a Vulkan 1.3 instance, optional Wayland surface, and logical device.
Returns `Except.error reason` cleanly (never leaks partial handles) if unavailable. -/
def createDevice (wlDisplay wlSurface : USize) (needSwapchain allowSoftwareIcd enableValidation : Bool) :
    IO (Except String VkDeviceCtx) := do
  let getProc ← try LeanUI.FFI.dlSym "libvulkan.so.1" "vkGetInstanceProcAddr" catch _ => pure 0
  if getProc == 0 then
    return .error "libvulkan.so.1 unavailable"
  let fnCreateInst ← resolveInstProc getProc 0 "vkCreateInstance"
  if fnCreateInst == 0 then
    return .error "vkCreateInstance unavailable"

  let mut instExts : Array String := #[]
  if needSwapchain then
    instExts := #["VK_KHR_surface", "VK_KHR_wayland_surface"]
  let layers : Array String := if enableValidation then #["VK_LAYER_KHRONOS_validation"] else #[]

  let tryCreateInstance (useLayers : Array String) : IO (Except Int UInt64) :=
    withArena fun a => do
      let appName ← a.cstr "orb-desktop"
      let engName ← a.cstr "LeanUI"
      let appInfo ← a.write (encApplicationInfo appName engName VK_API_VERSION_1_3)
      let layersPtr ← a.cstrArray useLayers
      let extsPtr ← a.cstrArray instExts
      let ci ← a.write (encInstanceCreateInfo appInfo useLayers.size.toUInt32 layersPtr instExts.size.toUInt32 extsPtr)
      let outPtr ← a.alloc 8
      let res ← callRes fnCreateInst ci.toUInt64 0 outPtr.toUInt64
      if res != VK_SUCCESS then return .error res
      return .ok (← readU64Ptr outPtr)

  let inst ← match ← tryCreateInstance layers with
    | .ok h => pure h
    | .error res =>
      if !layers.isEmpty then
        match ← tryCreateInstance #[] with
        | .ok h2 => pure h2
        | .error res2 => return .error s!"vkCreateInstance failed ({res2})"
      else
        return .error s!"vkCreateInstance failed ({res})"

  let rI (name : String) := resolveInstProc getProc inst name
  let fnDestroyInst ← rI "vkDestroyInstance"
  let fnEnumPhys ← rI "vkEnumeratePhysicalDevices"
  let fnPhysProps ← rI "vkGetPhysicalDeviceProperties"
  let fnPhysFeat2 ← rI "vkGetPhysicalDeviceFeatures2"
  let fnPhysQfp ← rI "vkGetPhysicalDeviceQueueFamilyProperties"
  let fnPhysMem ← rI "vkGetPhysicalDeviceMemoryProperties"
  let fnPhysFmt ← rI "vkGetPhysicalDeviceFormatProperties"
  let fnEnumDevExt ← rI "vkEnumerateDeviceExtensionProperties"
  let fnWlSupport ← rI "vkGetPhysicalDeviceWaylandPresentationSupportKHR"
  let fnSurfSupport ← rI "vkGetPhysicalDeviceSurfaceSupportKHR"
  let fnSurfCaps ← rI "vkGetPhysicalDeviceSurfaceCapabilitiesKHR"
  let fnSurfFmts ← rI "vkGetPhysicalDeviceSurfaceFormatsKHR"
  let fnSurfModes ← rI "vkGetPhysicalDeviceSurfacePresentModesKHR"
  let fnCreateWlSurf ← rI "vkCreateWaylandSurfaceKHR"
  let fnDestroySurf ← rI "vkDestroySurfaceKHR"
  let fnCreateDev ← rI "vkCreateDevice"
  let fnGetDevProc ← rI "vkGetDeviceProcAddr"

  let cleanupInst (surf : UInt64) : IO Unit := do
    if surf != 0 && fnDestroySurf != 0 then callVoid fnDestroySurf inst surf 0
    if fnDestroyInst != 0 then callVoid fnDestroyInst inst 0

  let surface : UInt64 ←
    if needSwapchain then
      if wlDisplay == 0 || wlSurface == 0 || fnCreateWlSurf == 0 then
        cleanupInst 0
        return .error "VK_KHR_wayland_surface unavailable or null Wayland handles"
      let sRes ← withArena fun a => do
        let sci ← a.write (encWaylandSurfaceCreateInfo wlDisplay wlSurface)
        let outPtr ← a.alloc 8
        let r ← callRes fnCreateWlSurf inst sci.toUInt64 0 outPtr.toUInt64
        if r != VK_SUCCESS then return Except.error r
        return Except.ok (← readU64Ptr outPtr)
      match sRes with
      | .ok s => pure s
      | .error r =>
        cleanupInst 0
        return .error s!"vkCreateWaylandSurfaceKHR failed ({r})"
    else pure 0

  -- Enumerate physical devices
  let physDevs : Array UInt64 ← withArena fun a => do
    let cntPtr ← a.u32 0
    let r0 ← callRes fnEnumPhys inst cntPtr.toUInt64 0
    if r0 != VK_SUCCESS then return #[]
    let n := (← readU32Ptr cntPtr).toNat
    if n == 0 then return #[]
    let bufPtr ← a.alloc (n * 8)
    let r1 ← callRes fnEnumPhys inst cntPtr.toUInt64 bufPtr.toUInt64
    if r1 != VK_SUCCESS then return #[]
    let raw ← LeanUI.FFI.memRead bufPtr (n * 8).toUSize
    let mut arr : Array UInt64 := #[]
    for i in [:n] do arr := arr.push (getU64 raw (i * 8))
    return arr

  if physDevs.isEmpty then
    cleanupInst surface
    return .error "no Vulkan physical devices found"

  -- Score candidate physical devices
  let mut bestScore : Nat := 0
  let mut bestPhys : UInt64 := 0
  let mut bestQfi : UInt32 := 0
  let mut bestName : String := ""
  let mut bestType : UInt32 := 0
  let mut bestHasIncPresent : Bool := false
  let mut bestHasDynRender : Bool := false
  let mut sawOnlySoftware : Bool := false

  for phys in physDevs do
    let (apiVer, devType, devName) ← withArena fun a => do
      let p ← a.alloc 824
      callVoid fnPhysProps phys p.toUInt64
      let raw ← LeanUI.FFI.memRead p 280
      return (getU32 raw 0, getU32 raw 16, getCString raw 20 256)
    if apiVer < VK_API_VERSION_1_3 then continue
    if devType == VK_PHYSICAL_DEVICE_TYPE_CPU && !allowSoftwareIcd then
      sawOnlySoftware := true
      continue
    -- Verify Vulkan 1.3 synchronization2 & dynamicRendering
    let (hasSync2, hasDyn) ← withArena fun a => do
      let f13 ← a.write (encVulkan13Features false false)
      let f2 ← a.write (encPhysicalDeviceFeatures2 f13)
      callVoid fnPhysFeat2 phys f2.toUInt64
      let raw13 ← LeanUI.FFI.memRead f13 80
      return (getU32 raw13 52 != 0, getU32 raw13 64 != 0)
    if !hasSync2 then continue
    let exts ← queryDeviceExtensions fnEnumDevExt phys
    if needSwapchain && !hasExtension exts "VK_KHR_swapchain" then continue
    -- Find graphics + compute + transfer (+ Wayland present) queue family
    let qfiOpt ← withArena fun a => do
      let cntPtr ← a.u32 0
      callVoid fnPhysQfp phys cntPtr.toUInt64 0
      let n := (← readU32Ptr cntPtr).toNat
      if n == 0 then return none
      let qPtr ← a.alloc (n * 24)
      callVoid fnPhysQfp phys cntPtr.toUInt64 qPtr.toUInt64
      let raw ← LeanUI.FFI.memRead qPtr (n * 24).toUSize
      for i in [:n] do
        let flags := getU32 raw (i * 24)
        let qcnt := getU32 raw (i * 24 + 4)
        -- Per Vulkan 1.x spec, GRAPHICS and COMPUTE queues implicitly support transfer.
        let req := VK_QUEUE_GRAPHICS_BIT ||| VK_QUEUE_COMPUTE_BIT
        if qcnt > 0 && (flags &&& req) == req then
          if !needSwapchain then
            return some i.toUInt32
          else
            let wlOk ← if fnWlSupport != 0 then callRes fnWlSupport phys i.toUInt64 wlDisplay.toUInt64 else pure 1
            let supPtr ← a.u32 0
            let sr ← callRes fnSurfSupport phys i.toUInt64 surface supPtr.toUInt64
            let surfOk := sr == VK_SUCCESS && (← readU32Ptr supPtr) != 0
            if wlOk != 0 && surfOk then
              return some i.toUInt32
      return none
    let some qfi := qfiOpt | continue
    let score := deviceTypeScore devType + (if hasDyn then 20 else 0)
    if score > bestScore then
      bestScore := score
      bestPhys := phys
      bestQfi := qfi
      bestName := devName
      bestType := devType
      bestHasIncPresent := hasExtension exts "VK_KHR_incremental_present"
      bestHasDynRender := hasDyn

  if bestPhys == 0 then
    cleanupInst surface
    if sawOnlySoftware then
      return .error "only software Vulkan CPU ICD (Lavapipe) available; falling back to wl_shm"
    return .error "no Vulkan 1.3 device with graphics+compute+present support"

  -- Create logical device
  let mut devExts : Array String := #[]
  if needSwapchain then
    devExts := devExts.push "VK_KHR_swapchain"
    if bestHasIncPresent then
      devExts := devExts.push "VK_KHR_incremental_present"

  let devRes ← withArena fun a => do
    let prioPtr ← a.write (pushF32 (ByteArray.emptyWithCapacity 4) 1.0)
    let qciPtr ← a.write (encDeviceQueueCreateInfo bestQfi prioPtr)
    let f13Ptr ← a.write (encVulkan13Features true bestHasDynRender)
    let extsPtr ← a.cstrArray devExts
    let dciPtr ← a.write (encDeviceCreateInfo f13Ptr qciPtr devExts.size.toUInt32 extsPtr)
    let outPtr ← a.alloc 8
    let r ← callRes fnCreateDev bestPhys dciPtr.toUInt64 0 outPtr.toUInt64
    if r != VK_SUCCESS then return Except.error r
    return Except.ok (← readU64Ptr outPtr)

  let device ← match devRes with
    | .ok d => pure d
    | .error r =>
      cleanupInst surface
      return .error s!"vkCreateDevice failed ({r})"

  let rD (name : String) := resolveDevProc fnGetDevProc device name
  let fns : VkFns := {
    getInstanceProcAddr := getProc
    createInstance := fnCreateInst
    destroyInstance := fnDestroyInst
    enumeratePhysicalDevices := fnEnumPhys
    getPhysicalDeviceProperties := fnPhysProps
    getPhysicalDeviceFeatures2 := fnPhysFeat2
    getPhysicalDeviceQueueFamilyProperties := fnPhysQfp
    getPhysicalDeviceMemoryProperties := fnPhysMem
    getPhysicalDeviceFormatProperties := fnPhysFmt
    enumerateDeviceExtensionProperties := fnEnumDevExt
    getPhysicalDeviceWaylandPresentationSupportKHR := fnWlSupport
    getPhysicalDeviceSurfaceSupportKHR := fnSurfSupport
    getPhysicalDeviceSurfaceCapabilitiesKHR := fnSurfCaps
    getPhysicalDeviceSurfaceFormatsKHR := fnSurfFmts
    getPhysicalDeviceSurfacePresentModesKHR := fnSurfModes
    createWaylandSurfaceKHR := fnCreateWlSurf
    destroySurfaceKHR := fnDestroySurf
    createDevice := fnCreateDev
    getDeviceProcAddr := fnGetDevProc
    destroyDevice := ← rD "vkDestroyDevice"
    getDeviceQueue := ← rD "vkGetDeviceQueue"
    deviceWaitIdle := ← rD "vkDeviceWaitIdle"
    createSwapchainKHR := ← rD "vkCreateSwapchainKHR"
    destroySwapchainKHR := ← rD "vkDestroySwapchainKHR"
    getSwapchainImagesKHR := ← rD "vkGetSwapchainImagesKHR"
    acquireNextImageKHR := ← rD "vkAcquireNextImageKHR"
    queuePresentKHR := ← rD "vkQueuePresentKHR"
    createCommandPool := ← rD "vkCreateCommandPool"
    destroyCommandPool := ← rD "vkDestroyCommandPool"
    allocateCommandBuffers := ← rD "vkAllocateCommandBuffers"
    beginCommandBuffer := ← rD "vkBeginCommandBuffer"
    endCommandBuffer := ← rD "vkEndCommandBuffer"
    resetCommandBuffer := ← rD "vkResetCommandBuffer"
    createFence := ← rD "vkCreateFence"
    destroyFence := ← rD "vkDestroyFence"
    waitForFences := ← rD "vkWaitForFences"
    resetFences := ← rD "vkResetFences"
    createSemaphore := ← rD "vkCreateSemaphore"
    destroySemaphore := ← rD "vkDestroySemaphore"
    queueSubmit2 := ← rD "vkQueueSubmit2"
    createBuffer := ← rD "vkCreateBuffer"
    destroyBuffer := ← rD "vkDestroyBuffer"
    getBufferMemoryRequirements := ← rD "vkGetBufferMemoryRequirements"
    bindBufferMemory := ← rD "vkBindBufferMemory"
    createImage := ← rD "vkCreateImage"
    destroyImage := ← rD "vkDestroyImage"
    getImageMemoryRequirements := ← rD "vkGetImageMemoryRequirements"
    bindImageMemory := ← rD "vkBindImageMemory"
    createImageView := ← rD "vkCreateImageView"
    destroyImageView := ← rD "vkDestroyImageView"
    createSampler := ← rD "vkCreateSampler"
    destroySampler := ← rD "vkDestroySampler"
    allocateMemory := ← rD "vkAllocateMemory"
    freeMemory := ← rD "vkFreeMemory"
    mapMemory := ← rD "vkMapMemory"
    unmapMemory := ← rD "vkUnmapMemory"
    invalidateMappedMemoryRanges := ← rD "vkInvalidateMappedMemoryRanges"
    createShaderModule := ← rD "vkCreateShaderModule"
    destroyShaderModule := ← rD "vkDestroyShaderModule"
    createDescriptorSetLayout := ← rD "vkCreateDescriptorSetLayout"
    destroyDescriptorSetLayout := ← rD "vkDestroyDescriptorSetLayout"
    createDescriptorPool := ← rD "vkCreateDescriptorPool"
    destroyDescriptorPool := ← rD "vkDestroyDescriptorPool"
    allocateDescriptorSets := ← rD "vkAllocateDescriptorSets"
    updateDescriptorSets := ← rD "vkUpdateDescriptorSets"
    createPipelineLayout := ← rD "vkCreatePipelineLayout"
    destroyPipelineLayout := ← rD "vkDestroyPipelineLayout"
    createPipelineCache := ← rD "vkCreatePipelineCache"
    destroyPipelineCache := ← rD "vkDestroyPipelineCache"
    getPipelineCacheData := ← rD "vkGetPipelineCacheData"
    createGraphicsPipelines := ← rD "vkCreateGraphicsPipelines"
    createComputePipelines := ← rD "vkCreateComputePipelines"
    destroyPipeline := ← rD "vkDestroyPipeline"
    cmdPipelineBarrier2 := ← rD "vkCmdPipelineBarrier2"
    cmdCopyBufferToImage2 := ← rD "vkCmdCopyBufferToImage2"
    cmdCopyImageToBuffer2 := ← rD "vkCmdCopyImageToBuffer2"
    cmdBlitImage2 := ← rD "vkCmdBlitImage2"
    cmdCopyImage2 := ← rD "vkCmdCopyImage2"
    cmdClearColorImage := ← rD "vkCmdClearColorImage"
    cmdBeginRendering := ← rD "vkCmdBeginRendering"
    cmdEndRendering := ← rD "vkCmdEndRendering"
    cmdBindPipeline := ← rD "vkCmdBindPipeline"
    cmdBindDescriptorSets := ← rD "vkCmdBindDescriptorSets"
    cmdSetViewport := ← rD "vkCmdSetViewport"
    cmdSetScissor := ← rD "vkCmdSetScissor"
    cmdPushConstants := ← rD "vkCmdPushConstants"
    cmdDraw := ← rD "vkCmdDraw"
    cmdDispatch := ← rD "vkCmdDispatch"
  }

  let requiredCoreOk : Bool :=
    fns.destroyDevice != 0 && fns.getDeviceQueue != 0 && fns.deviceWaitIdle != 0 &&
    fns.createCommandPool != 0 && fns.destroyCommandPool != 0 && fns.allocateCommandBuffers != 0 &&
    fns.beginCommandBuffer != 0 && fns.endCommandBuffer != 0 && fns.resetCommandBuffer != 0 &&
    fns.createFence != 0 && fns.destroyFence != 0 && fns.waitForFences != 0 && fns.resetFences != 0 &&
    fns.createSemaphore != 0 && fns.destroySemaphore != 0 && fns.queueSubmit2 != 0 &&
    fns.createBuffer != 0 && fns.destroyBuffer != 0 && fns.getBufferMemoryRequirements != 0 && fns.bindBufferMemory != 0 &&
    fns.createImage != 0 && fns.destroyImage != 0 && fns.getImageMemoryRequirements != 0 && fns.bindImageMemory != 0 &&
    fns.createImageView != 0 && fns.destroyImageView != 0 && fns.createSampler != 0 && fns.destroySampler != 0 &&
    fns.allocateMemory != 0 && fns.freeMemory != 0 && fns.mapMemory != 0 && fns.unmapMemory != 0 &&
    fns.invalidateMappedMemoryRanges != 0 &&
    fns.cmdPipelineBarrier2 != 0 && fns.cmdCopyBufferToImage2 != 0 && fns.cmdCopyImageToBuffer2 != 0 &&
    fns.cmdBlitImage2 != 0 && fns.cmdCopyImage2 != 0 && fns.cmdClearColorImage != 0
  let requiredWsiOk : Bool :=
    !needSwapchain ||
    (fns.createSwapchainKHR != 0 && fns.destroySwapchainKHR != 0 && fns.getSwapchainImagesKHR != 0 &&
     fns.acquireNextImageKHR != 0 && fns.queuePresentKHR != 0)
  if !requiredCoreOk || !requiredWsiOk then
    if fns.destroyDevice != 0 then callVoid fns.destroyDevice device 0
    cleanupInst surface
    return .error "missing required Vulkan 1.3 or VK_KHR_swapchain device entry points"

  let (queue, cmdPool, memPropsRaw) ← withArena fun a => do
    let qPtr ← a.alloc 8
    callVoid fns.getDeviceQueue device bestQfi.toUInt64 0 qPtr.toUInt64
    let q ← readU64Ptr qPtr
    let cpCi ← a.write (encCommandPoolCreateInfo bestQfi)
    let cpOut ← a.alloc 8
    let cr ← callRes fns.createCommandPool device cpCi.toUInt64 0 cpOut.toUInt64
    let cp ← if cr == VK_SUCCESS then readU64Ptr cpOut else pure 0
    let mpPtr ← a.alloc 520
    callVoid fns.getPhysicalDeviceMemoryProperties bestPhys mpPtr.toUInt64
    let mpRaw ← LeanUI.FFI.memRead mpPtr 520
    return (q, cp, mpRaw)

  if cmdPool == 0 then
    if fns.destroyDevice != 0 then callVoid fns.destroyDevice device 0
    cleanupInst surface
    return .error "vkCreateCommandPool failed"

  let allocatedBytes ← IO.mkRef 0
  return .ok {
    fns, vkInstance := inst, surface, physDevice := bestPhys, device, queue
    queueFamily := bestQfi, cmdPool, deviceName := bestName, deviceType := bestType
    hasIncrementalPresent := bestHasIncPresent, hasDynamicRendering := bestHasDynRender
    memPropsRaw, allocatedBytes
  }

/-- Allocate a `VkBuffer` + `VkDeviceMemory` (and map it when `mapPersistent` is true). -/
def createGpuBuffer (dev : VkDeviceCtx) (size : Nat) (usage memProps : UInt32)
    (mapPersistent : Bool := false) : IO (Except String VkGpuBuffer) :=
  withArena fun a => do
    let sz := max 64 size
    let bci ← a.write (encBufferCreateInfo sz.toUInt64 usage)
    let outB ← a.alloc 8
    let r0 ← callRes dev.fns.createBuffer dev.device bci.toUInt64 0 outB.toUInt64
    if r0 != VK_SUCCESS then return .error s!"vkCreateBuffer failed ({r0})"
    let buf ← readU64Ptr outB
    let reqPtr ← a.alloc 24
    callVoid dev.fns.getBufferMemoryRequirements dev.device buf reqPtr.toUInt64
    let reqRaw ← LeanUI.FFI.memRead reqPtr 24
    let allocSz := getU64 reqRaw 0
    let typeBits := getU32 reqRaw 16
    let some memIdx := findMemoryType dev.memPropsRaw typeBits memProps
      | do callVoid dev.fns.destroyBuffer dev.device buf 0; return .error "no matching buffer memory type"
    let mai ← a.write (encMemoryAllocateInfo allocSz memIdx)
    let outM ← a.alloc 8
    let r1 ← callRes dev.fns.allocateMemory dev.device mai.toUInt64 0 outM.toUInt64
    if r1 != VK_SUCCESS then
      callVoid dev.fns.destroyBuffer dev.device buf 0
      return .error s!"vkAllocateMemory(buffer) failed ({r1})"
    let mem ← readU64Ptr outM
    let r2 ← callRes dev.fns.bindBufferMemory dev.device buf mem 0
    if r2 != VK_SUCCESS then
      callVoid dev.fns.freeMemory dev.device mem 0
      callVoid dev.fns.destroyBuffer dev.device buf 0
      return .error s!"vkBindBufferMemory failed ({r2})"
    let mut mapped : USize := 0
    if mapPersistent then
      let outP ← a.alloc 8
      let r3 ← callRes dev.fns.mapMemory dev.device mem 0 allocSz 0 outP.toUInt64
      if r3 != VK_SUCCESS then
        callVoid dev.fns.freeMemory dev.device mem 0
        callVoid dev.fns.destroyBuffer dev.device buf 0
        return .error s!"vkMapMemory failed ({r3})"
      mapped := (← readU64Ptr outP).toUSize
    dev.allocatedBytes.modify (· + allocSz.toNat)
    return .ok { buffer := buf, memory := mem, size := allocSz.toNat, mappedPtr := mapped }

def destroyGpuBuffer (dev : VkDeviceCtx) (b : VkGpuBuffer) : IO Unit := do
  if b.buffer == 0 && b.memory == 0 then return
  if b.mappedPtr != 0 && b.memory != 0 then
    callVoid dev.fns.unmapMemory dev.device b.memory
  if b.buffer != 0 then callVoid dev.fns.destroyBuffer dev.device b.buffer 0
  if b.memory != 0 then
    callVoid dev.fns.freeMemory dev.device b.memory 0
    dev.allocatedBytes.modify (fun cur => cur - min cur b.size)

/-- Create a `VkImageView` for an existing `VkImage`. -/
def createImageView (dev : VkDeviceCtx) (image : UInt64) (viewType fmt baseLayer layerCount : UInt32) :
    IO (Except String UInt64) :=
  withArena fun a => do
    let ivci ← a.write (encImageViewCreateInfo image viewType fmt baseLayer layerCount)
    let outV ← a.alloc 8
    let r ← callRes dev.fns.createImageView dev.device ivci.toUInt64 0 outV.toUInt64
    if r != VK_SUCCESS then return .error s!"vkCreateImageView failed ({r})"
    return .ok (← readU64Ptr outV)

/-- Allocate a device-local `VkImage` + `VkDeviceMemory` + `VkImageView`. -/
def createGpuImage (dev : VkDeviceCtx) (w h layers : Nat) (fmt usage : UInt32)
    (viewType : UInt32 := VK_IMAGE_VIEW_TYPE_2D) : IO (Except String VkGpuImage) :=
  withArena fun a => do
    let iw := max 1 w
    let ih := max 1 h
    let il := max 1 layers
    let ici ← a.write (encImageCreateInfo fmt iw.toUInt32 ih.toUInt32 il.toUInt32 usage)
    let outI ← a.alloc 8
    let r0 ← callRes dev.fns.createImage dev.device ici.toUInt64 0 outI.toUInt64
    if r0 != VK_SUCCESS then return .error s!"vkCreateImage failed ({r0})"
    let img ← readU64Ptr outI
    let reqPtr ← a.alloc 24
    callVoid dev.fns.getImageMemoryRequirements dev.device img reqPtr.toUInt64
    let reqRaw ← LeanUI.FFI.memRead reqPtr 24
    let allocSz := getU64 reqRaw 0
    let typeBits := getU32 reqRaw 16
    let memIdxOpt :=
      match findMemoryType dev.memPropsRaw typeBits VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT with
      | some idx => some idx
      | none => findMemoryType dev.memPropsRaw typeBits 0
    let some memIdx := memIdxOpt
      | do callVoid dev.fns.destroyImage dev.device img 0; return .error "no matching image memory type"
    let mai ← a.write (encMemoryAllocateInfo allocSz memIdx)
    let outM ← a.alloc 8
    let r1 ← callRes dev.fns.allocateMemory dev.device mai.toUInt64 0 outM.toUInt64
    if r1 != VK_SUCCESS then
      callVoid dev.fns.destroyImage dev.device img 0
      return .error s!"vkAllocateMemory(image) failed ({r1})"
    let mem ← readU64Ptr outM
    let r2 ← callRes dev.fns.bindImageMemory dev.device img mem 0
    if r2 != VK_SUCCESS then
      callVoid dev.fns.freeMemory dev.device mem 0
      callVoid dev.fns.destroyImage dev.device img 0
      return .error s!"vkBindImageMemory failed ({r2})"
    match ← createImageView dev img viewType fmt 0 il.toUInt32 with
    | .error e =>
      callVoid dev.fns.freeMemory dev.device mem 0
      callVoid dev.fns.destroyImage dev.device img 0
      return .error e
    | .ok view =>
      dev.allocatedBytes.modify (· + allocSz.toNat)
      return .ok { image := img, memory := mem, view, width := iw, height := ih, layers := il, format := fmt, allocBytes := allocSz.toNat }

def destroyGpuImage (dev : VkDeviceCtx) (im : VkGpuImage) : IO Unit := do
  if im.view != 0 then callVoid dev.fns.destroyImageView dev.device im.view 0
  if im.image != 0 then callVoid dev.fns.destroyImage dev.device im.image 0
  if im.memory != 0 then
    callVoid dev.fns.freeMemory dev.device im.memory 0
    dev.allocatedBytes.modify (fun cur => cur - min cur im.allocBytes)

/-- Query `optimalTilingFeatures` for `fmt` on `dev.physDevice`. -/
def queryOptimalFormatFeatures (dev : VkDeviceCtx) (fmt : UInt32) : IO UInt32 :=
  withArena fun a => do
    let p ← a.alloc 12
    callVoid dev.fns.getPhysicalDeviceFormatProperties dev.physDevice fmt.toUInt64 p.toUInt64
    let raw ← LeanUI.FFI.memRead p 12
    return getU32 raw 4

/-- Wait for device idle (`vkDeviceWaitIdle`) unconditionally when `device ≠ 0`. -/
def waitDeviceIdle (dev : VkDeviceCtx) : IO Unit := do
  if dev.device != 0 && dev.fns.deviceWaitIdle != 0 then
    discard <| callRes dev.fns.deviceWaitIdle dev.device

/-- Tear down command pool, logical device, Wayland surface, and Vulkan instance in strict
reverse lifecycle order (Invariant 4: `vkDeviceWaitIdle` first). -/
def destroyDevice (dev : VkDeviceCtx) : IO Unit := do
  waitDeviceIdle dev
  if dev.device != 0 then
    if dev.cmdPool != 0 then callVoid dev.fns.destroyCommandPool dev.device dev.cmdPool 0
    callVoid dev.fns.destroyDevice dev.device 0
  if dev.vkInstance != 0 then
    if dev.surface != 0 then callVoid dev.fns.destroySurfaceKHR dev.vkInstance dev.surface 0
    callVoid dev.fns.destroyInstance dev.vkInstance 0

end LeanUI.Vk
