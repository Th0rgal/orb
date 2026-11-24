import LeanUI.FFI
/-!
# LeanUI.VulkanStructs — Verified LP64 Vulkan 1.3 Constants, Struct Encoders & Arena

Every struct size and field offset is verified against `<vulkan/vulkan.h>` by
`lean/OrbDesktop/tests/VkStructAbiCheck.c` (LP64 little-endian `x86_64` / `aarch64`).
Zero external header or link dependencies at compile or runtime.
-/
namespace LeanUI.Vk

/-- Little-endian binary write helpers into fixed-size zero-initialized `ByteArray`s. -/
@[inline] def zeroBuf (n : Nat) : ByteArray :=
  ByteArray.mk (Array.replicate n 0)

@[inline] def setU32 (b : ByteArray) (off : Nat) (v : UInt32) : ByteArray :=
  b.set! off v.toUInt8
   |>.set! (off + 1) (v >>> 8).toUInt8
   |>.set! (off + 2) (v >>> 16).toUInt8
   |>.set! (off + 3) (v >>> 24).toUInt8

@[inline] def setI32 (b : ByteArray) (off : Nat) (v : Int) : ByteArray :=
  setU32 b off v.toInt32.toUInt32

@[inline] def setU64 (b : ByteArray) (off : Nat) (v : UInt64) : ByteArray :=
  setU32 (setU32 b off v.toUInt32) (off + 4) (v >>> 32).toUInt32

@[inline] def setF32 (b : ByteArray) (off : Nat) (v : Float) : ByteArray :=
  setU32 b off v.toFloat32.toBits

@[inline] def getU32 (b : ByteArray) (off : Nat) : UInt32 :=
  if off + 4 ≤ b.size then
    (b.get! off).toUInt32 |||
    ((b.get! (off + 1)).toUInt32 <<< 8) |||
    ((b.get! (off + 2)).toUInt32 <<< 16) |||
    ((b.get! (off + 3)).toUInt32 <<< 24)
  else 0

@[inline] def getI32 (b : ByteArray) (off : Nat) : Int :=
  let u := getU32 b off
  if u ≥ 0x80000000 then (u.toNat : Int) - 0x100000000 else u.toNat

@[inline] def getU64 (b : ByteArray) (off : Nat) : UInt64 :=
  if off + 8 ≤ b.size then
    (getU32 b off).toUInt64 ||| ((getU32 b (off + 4)).toUInt64 <<< 32)
  else 0

def getCString (b : ByteArray) (off maxLen : Nat) : String := Id.run do
  let limit := min b.size (off + maxLen)
  let mut stop := off
  while stop < limit && b.get! stop != 0 do
    stop := stop + 1
  return String.fromUTF8! (b.extract off stop)

@[inline] def pushU32 (b : ByteArray) (v : UInt32) : ByteArray :=
  b.push v.toUInt8
   |>.push (v >>> 8).toUInt8
   |>.push (v >>> 16).toUInt8
   |>.push (v >>> 24).toUInt8

@[inline] def pushU64 (b : ByteArray) (v : UInt64) : ByteArray :=
  pushU32 (pushU32 b v.toUInt32) (v >>> 32).toUInt32

@[inline] def pushF32 (b : ByteArray) (v : Float) : ByteArray :=
  pushU32 b v.toFloat32.toBits

/-- Pack 8 `UInt64` arguments into a 64-byte buffer for `vkCallVoid8` / `vkCallRes8`. -/
@[inline] def packArgs8 (a0 a1 a2 a3 a4 a5 a6 a7 : UInt64 := 0) : ByteArray :=
  let b := ByteArray.emptyWithCapacity 64
  pushU64 (pushU64 (pushU64 (pushU64 (pushU64 (pushU64 (pushU64 (pushU64 b a0) a1) a2) a3) a4) a5) a6) a7

/-- Pack 6 `UInt64` arguments into a 48-byte buffer for `FFI.call` (64-bit pointer return). -/
@[inline] def packArgs6 (a0 a1 a2 a3 a4 a5 : UInt64 := 0) : ByteArray :=
  let b := ByteArray.emptyWithCapacity 48
  pushU64 (pushU64 (pushU64 (pushU64 (pushU64 (pushU64 b a0) a1) a2) a3) a4) a5

@[inline] def callVoid (fn : USize) (a0 a1 a2 a3 a4 a5 a6 a7 : UInt64 := 0) : IO Unit := do
  if fn == 0 then return
  LeanUI.FFI.vkCallVoid8 fn (packArgs8 a0 a1 a2 a3 a4 a5 a6 a7)

@[inline] def callRes (fn : USize) (a0 a1 a2 a3 a4 a5 a6 a7 : UInt64 := 0) : IO Int := do
  if fn == 0 then return -13 -- VK_ERROR_UNKNOWN
  let u ← LeanUI.FFI.vkCallRes8 fn (packArgs8 a0 a1 a2 a3 a4 a5 a6 a7)
  return if u ≥ 0x80000000 then (u.toNat : Int) - 0x100000000 else u.toNat

/-- 64-bit pointer-returning call (MUST be used for `vkGetInstanceProcAddr` / `vkGetDeviceProcAddr`). -/
@[inline] def callPtr (fn : USize) (a0 a1 : UInt64 := 0) : IO USize := do
  if fn == 0 then return 0
  return (← LeanUI.FFI.call fn (packArgs6 a0 a1)).toUSize

/-- Scoped native allocation arena: frees every temporary struct buffer on exit. -/
structure MemArena where
  ptrs : IO.Ref (Array USize)

def withArena {α : Type} (k : MemArena → IO α) : IO α := do
  let ptrs ← IO.mkRef #[]
  let arena : MemArena := { ptrs }
  try k arena
  finally
    for p in (← ptrs.get) do
      if p != 0 then LeanUI.FFI.memFree p

def MemArena.alloc (a : MemArena) (size : Nat) : IO USize := do
  let p ← LeanUI.FFI.memAlloc (max 1 size).toUSize
  a.ptrs.modify (·.push p)
  return p

def MemArena.write (a : MemArena) (bytes : ByteArray) : IO USize := do
  let p ← a.alloc (max 1 bytes.size)
  if bytes.size > 0 then LeanUI.FFI.memWrite p bytes
  return p

def MemArena.cstr (a : MemArena) (s : String) : IO USize :=
  a.write (s.toUTF8.push 0)

def MemArena.cstrArray (a : MemArena) (ss : Array String) : IO USize := do
  if ss.isEmpty then return 0
  let mut buf := ByteArray.emptyWithCapacity (ss.size * 8)
  for s in ss do
    let sp ← a.cstr s
    buf := pushU64 buf sp.toUInt64
  a.write buf

def MemArena.u64 (a : MemArena) (v : UInt64) : IO USize :=
  a.write (pushU64 (ByteArray.emptyWithCapacity 8) v)

def MemArena.u32 (a : MemArena) (v : UInt32) : IO USize :=
  a.write (pushU32 (ByteArray.emptyWithCapacity 4) v)

def readU64Ptr (p : USize) : IO UInt64 := do
  let b ← LeanUI.FFI.memRead p 8
  return getU64 b 0

def readU32Ptr (p : USize) : IO UInt32 := do
  let b ← LeanUI.FFI.memRead p 4
  return getU32 b 0

/-! ### Vulkan 1.3 Constants & Enums -/

def VK_API_VERSION_1_3 : UInt32 := ((1 : UInt32) <<< 22) ||| ((3 : UInt32) <<< 12)
def VK_TRUE : UInt32 := 1
def VK_FALSE : UInt32 := 0
def VK_WHOLE_SIZE : UInt64 := 0xFFFFFFFFFFFFFFFF
def VK_QUEUE_FAMILY_IGNORED : UInt32 := 0xFFFFFFFF
def VK_REMAINING_MIP_LEVELS : UInt32 := 0xFFFFFFFF
def VK_REMAINING_ARRAY_LAYERS : UInt32 := 0xFFFFFFFF
def VK_SUBPASS_EXTERNAL : UInt32 := 0xFFFFFFFF

-- VkResult
def VK_SUCCESS : Int := 0
def VK_NOT_READY : Int := 1
def VK_TIMEOUT : Int := 2
def VK_SUBOPTIMAL_KHR : Int := 1000001003
def VK_ERROR_OUT_OF_DATE_KHR : Int := -1000001004
def VK_ERROR_SURFACE_LOST_KHR : Int := -1000000000
def VK_ERROR_DEVICE_LOST : Int := -4

-- VkStructureType
def VK_STRUCTURE_TYPE_APPLICATION_INFO : UInt32 := 0
def VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO : UInt32 := 1
def VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO : UInt32 := 2
def VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO : UInt32 := 3
def VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO : UInt32 := 5
def VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE : UInt32 := 6
def VK_STRUCTURE_TYPE_FENCE_CREATE_INFO : UInt32 := 8
def VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO : UInt32 := 9
def VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO : UInt32 := 12
def VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO : UInt32 := 14
def VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO : UInt32 := 15
def VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO : UInt32 := 16
def VK_STRUCTURE_TYPE_PIPELINE_CACHE_CREATE_INFO : UInt32 := 17
def VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO : UInt32 := 18
def VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO : UInt32 := 19
def VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO : UInt32 := 20
def VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO : UInt32 := 22
def VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO : UInt32 := 23
def VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO : UInt32 := 24
def VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO : UInt32 := 26
def VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO : UInt32 := 27
def VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO : UInt32 := 28
def VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO : UInt32 := 29
def VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO : UInt32 := 30
def VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO : UInt32 := 31
def VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO : UInt32 := 32
def VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO : UInt32 := 33
def VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO : UInt32 := 34
def VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET : UInt32 := 35
def VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO : UInt32 := 39
def VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO : UInt32 := 40
def VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO : UInt32 := 42
def VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES : UInt32 := 53
def VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2 : UInt32 := 1000059000
def VK_STRUCTURE_TYPE_WAYLAND_SURFACE_CREATE_INFO_KHR : UInt32 := 1000006000
def VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR : UInt32 := 1000001000
def VK_STRUCTURE_TYPE_PRESENT_INFO_KHR : UInt32 := 1000001001
def VK_STRUCTURE_TYPE_PRESENT_REGIONS_KHR : UInt32 := 1000084000
def VK_STRUCTURE_TYPE_RENDERING_INFO : UInt32 := 1000044000
def VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO : UInt32 := 1000044001
def VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO : UInt32 := 1000044002
def VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2 : UInt32 := 1000314002
def VK_STRUCTURE_TYPE_DEPENDENCY_INFO : UInt32 := 1000314003
def VK_STRUCTURE_TYPE_SUBMIT_INFO_2 : UInt32 := 1000314004
def VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO : UInt32 := 1000314005
def VK_STRUCTURE_TYPE_COMMAND_BUFFER_SUBMIT_INFO : UInt32 := 1000314006
def VK_STRUCTURE_TYPE_COPY_IMAGE_INFO_2 : UInt32 := 1000337001
def VK_STRUCTURE_TYPE_COPY_BUFFER_TO_IMAGE_INFO_2 : UInt32 := 1000337002
def VK_STRUCTURE_TYPE_COPY_IMAGE_TO_BUFFER_INFO_2 : UInt32 := 1000337003
def VK_STRUCTURE_TYPE_BLIT_IMAGE_INFO_2 : UInt32 := 1000337004
def VK_STRUCTURE_TYPE_IMAGE_COPY_2 : UInt32 := 1000337007
def VK_STRUCTURE_TYPE_IMAGE_BLIT_2 : UInt32 := 1000337008
def VK_STRUCTURE_TYPE_BUFFER_IMAGE_COPY_2 : UInt32 := 1000337009

-- Physical device types
def VK_PHYSICAL_DEVICE_TYPE_OTHER : UInt32 := 0
def VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU : UInt32 := 1
def VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU : UInt32 := 2
def VK_PHYSICAL_DEVICE_TYPE_VIRTUAL_GPU : UInt32 := 3
def VK_PHYSICAL_DEVICE_TYPE_CPU : UInt32 := 4

-- Queue flags
def VK_QUEUE_GRAPHICS_BIT : UInt32 := 0x1
def VK_QUEUE_COMPUTE_BIT : UInt32 := 0x2
def VK_QUEUE_TRANSFER_BIT : UInt32 := 0x4

-- Formats & color space
def VK_FORMAT_R8G8B8A8_UNORM : UInt32 := 37
def VK_FORMAT_B8G8R8A8_UNORM : UInt32 := 44
def VK_COLOR_SPACE_SRGB_NONLINEAR_KHR : UInt32 := 0

-- Format features
def VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT : UInt32 := 0x1
def VK_FORMAT_FEATURE_STORAGE_IMAGE_BIT : UInt32 := 0x2
def VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BIT : UInt32 := 0x80
def VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BLEND_BIT : UInt32 := 0x100
def VK_FORMAT_FEATURE_BLIT_SRC_BIT : UInt32 := 0x400
def VK_FORMAT_FEATURE_BLIT_DST_BIT : UInt32 := 0x800

-- Present modes
def VK_PRESENT_MODE_IMMEDIATE_KHR : UInt32 := 0
def VK_PRESENT_MODE_MAILBOX_KHR : UInt32 := 1
def VK_PRESENT_MODE_FIFO_KHR : UInt32 := 2

-- Composite alpha
def VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR : UInt32 := 0x1
def VK_COMPOSITE_ALPHA_PRE_MULTIPLIED_BIT_KHR : UInt32 := 0x2

-- Image usage / type / tiling / view / aspect / layout
def VK_IMAGE_TYPE_2D : UInt32 := 1
def VK_IMAGE_TILING_OPTIMAL : UInt32 := 0
def VK_IMAGE_USAGE_TRANSFER_SRC_BIT : UInt32 := 0x1
def VK_IMAGE_USAGE_TRANSFER_DST_BIT : UInt32 := 0x2
def VK_IMAGE_USAGE_SAMPLED_BIT : UInt32 := 0x4
def VK_IMAGE_USAGE_STORAGE_BIT : UInt32 := 0x8
def VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT : UInt32 := 0x10
def VK_IMAGE_VIEW_TYPE_2D : UInt32 := 1
def VK_IMAGE_VIEW_TYPE_2D_ARRAY : UInt32 := 5
def VK_IMAGE_ASPECT_COLOR_BIT : UInt32 := 0x1
def VK_IMAGE_LAYOUT_UNDEFINED : UInt32 := 0
def VK_IMAGE_LAYOUT_GENERAL : UInt32 := 1
def VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL : UInt32 := 2
def VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL : UInt32 := 5
def VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL : UInt32 := 6
def VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL : UInt32 := 7
def VK_IMAGE_LAYOUT_PRESENT_SRC_KHR : UInt32 := 1000001002

-- Buffer usage
def VK_BUFFER_USAGE_TRANSFER_SRC_BIT : UInt32 := 0x1
def VK_BUFFER_USAGE_TRANSFER_DST_BIT : UInt32 := 0x2
def VK_BUFFER_USAGE_STORAGE_BUFFER_BIT : UInt32 := 0x20

-- Memory properties
def VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT : UInt32 := 0x1
def VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT : UInt32 := 0x2
def VK_MEMORY_PROPERTY_HOST_COHERENT_BIT : UInt32 := 0x4
def VK_MEMORY_PROPERTY_HOST_CACHED_BIT : UInt32 := 0x8

-- Pipeline / shader / descriptors / blend / dynamic state
def VK_SHADER_STAGE_VERTEX_BIT : UInt32 := 0x1
def VK_SHADER_STAGE_FRAGMENT_BIT : UInt32 := 0x10
def VK_SHADER_STAGE_COMPUTE_BIT : UInt32 := 0x20
def VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER : UInt32 := 1
def VK_DESCRIPTOR_TYPE_STORAGE_IMAGE : UInt32 := 3
def VK_DESCRIPTOR_TYPE_STORAGE_BUFFER : UInt32 := 7
def VK_DESCRIPTOR_POOL_CREATE_FREE_DESCRIPTOR_SET_BIT : UInt32 := 0x1
def VK_PIPELINE_BIND_POINT_GRAPHICS : UInt32 := 0
def VK_PIPELINE_BIND_POINT_COMPUTE : UInt32 := 1
def VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP : UInt32 := 4
def VK_POLYGON_MODE_FILL : UInt32 := 0
def VK_CULL_MODE_NONE : UInt32 := 0
def VK_FRONT_FACE_COUNTER_CLOCKWISE : UInt32 := 0
def VK_SAMPLE_COUNT_1_BIT : UInt32 := 1
def VK_BLEND_FACTOR_ONE : UInt32 := 1
def VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA : UInt32 := 7
def VK_BLEND_OP_ADD : UInt32 := 0
def VK_COLOR_COMPONENT_RGBA : UInt32 := 0xF
def VK_DYNAMIC_STATE_VIEWPORT : UInt32 := 0
def VK_DYNAMIC_STATE_SCISSOR : UInt32 := 1
def VK_ATTACHMENT_LOAD_OP_LOAD : UInt32 := 0
def VK_ATTACHMENT_LOAD_OP_CLEAR : UInt32 := 1
def VK_ATTACHMENT_STORE_OP_STORE : UInt32 := 0
def VK_FILTER_NEAREST : UInt32 := 0
def VK_SAMPLER_MIPMAP_MODE_NEAREST : UInt32 := 0
def VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE : UInt32 := 2
def VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT : UInt32 := 0x2
def VK_COMMAND_BUFFER_LEVEL_PRIMARY : UInt32 := 0
def VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT : UInt32 := 0x1
def VK_FENCE_CREATE_SIGNALED_BIT : UInt32 := 0x1

-- Synchronization2 stage & access masks
def VK_PIPELINE_STAGE_2_NONE : UInt64 := 0
def VK_PIPELINE_STAGE_2_FRAGMENT_SHADER_BIT : UInt64 := 0x80
def VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT : UInt64 := 0x400
def VK_PIPELINE_STAGE_2_COMPUTE_SHADER_BIT : UInt64 := 0x800
def VK_PIPELINE_STAGE_2_TRANSFER_BIT : UInt64 := 0x1000
def VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT : UInt64 := 0x10000
def VK_PIPELINE_STAGE_2_COPY_BIT : UInt64 := 0x100000000
def VK_PIPELINE_STAGE_2_BLIT_BIT : UInt64 := 0x400000000
def VK_PIPELINE_STAGE_2_CLEAR_BIT : UInt64 := 0x800000000

def VK_ACCESS_2_NONE : UInt64 := 0
def VK_ACCESS_2_SHADER_READ_BIT : UInt64 := 0x20
def VK_ACCESS_2_COLOR_ATTACHMENT_READ_BIT : UInt64 := 0x80
def VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT : UInt64 := 0x100
def VK_ACCESS_2_TRANSFER_READ_BIT : UInt64 := 0x800
def VK_ACCESS_2_TRANSFER_WRITE_BIT : UInt64 := 0x1000
def VK_ACCESS_2_SHADER_STORAGE_READ_BIT : UInt64 := 0x200000000
def VK_ACCESS_2_SHADER_STORAGE_WRITE_BIT : UInt64 := 0x400000000

/-! ### Exact LP64 Struct Encoders (Verified by `tests/VkStructAbiCheck.c`) -/

def encApplicationInfo (appNamePtr engineNamePtr : USize) (apiVersion : UInt32 := VK_API_VERSION_1_3) : ByteArray :=
  zeroBuf 48
    |> (setU32 · 0 VK_STRUCTURE_TYPE_APPLICATION_INFO)
    |> (setU64 · 16 appNamePtr.toUInt64)
    |> (setU32 · 24 1)
    |> (setU64 · 32 engineNamePtr.toUInt64)
    |> (setU32 · 40 1)
    |> (setU32 · 44 apiVersion)

def encInstanceCreateInfo (appInfoPtr : USize) (layerCount : UInt32) (layersPtr : USize)
    (extCount : UInt32) (extsPtr : USize) : ByteArray :=
  zeroBuf 64
    |> (setU32 · 0 VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO)
    |> (setU64 · 24 appInfoPtr.toUInt64)
    |> (setU32 · 32 layerCount)
    |> (setU64 · 40 layersPtr.toUInt64)
    |> (setU32 · 48 extCount)
    |> (setU64 · 56 extsPtr.toUInt64)

def encWaylandSurfaceCreateInfo (display surface : USize) : ByteArray :=
  zeroBuf 40
    |> (setU32 · 0 VK_STRUCTURE_TYPE_WAYLAND_SURFACE_CREATE_INFO_KHR)
    |> (setU64 · 24 display.toUInt64)
    |> (setU64 · 32 surface.toUInt64)

def encVulkan13Features (sync2 dynRender : Bool) : ByteArray :=
  zeroBuf 80
    |> (setU32 · 0 VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES)
    |> (setU32 · 52 (if sync2 then VK_TRUE else VK_FALSE))
    |> (setU32 · 64 (if dynRender then VK_TRUE else VK_FALSE))

def encPhysicalDeviceFeatures2 (pNext : USize) : ByteArray :=
  zeroBuf 240
    |> (setU32 · 0 VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2)
    |> (setU64 · 8 pNext.toUInt64)

def encDeviceQueueCreateInfo (qfi : UInt32) (prioPtr : USize) : ByteArray :=
  zeroBuf 40
    |> (setU32 · 0 VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO)
    |> (setU32 · 20 qfi)
    |> (setU32 · 24 1)
    |> (setU64 · 32 prioPtr.toUInt64)

def encDeviceCreateInfo (pNext queueInfoPtr : USize) (extCount : UInt32) (extsPtr : USize) : ByteArray :=
  zeroBuf 72
    |> (setU32 · 0 VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO)
    |> (setU64 · 8 pNext.toUInt64)
    |> (setU32 · 20 1)
    |> (setU64 · 24 queueInfoPtr.toUInt64)
    |> (setU32 · 48 extCount)
    |> (setU64 · 56 extsPtr.toUInt64)

def encSwapchainCreateInfo (surface : UInt64) (minImageCount fmt colorSpace w h usage preTransform
    compositeAlpha presentMode : UInt32) (oldSwapchain : UInt64) : ByteArray :=
  zeroBuf 104
    |> (setU32 · 0 VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR)
    |> (setU64 · 24 surface)
    |> (setU32 · 32 minImageCount)
    |> (setU32 · 36 fmt)
    |> (setU32 · 40 colorSpace)
    |> (setU32 · 44 w)
    |> (setU32 · 48 h)
    |> (setU32 · 52 1) -- imageArrayLayers
    |> (setU32 · 56 usage)
    |> (setU32 · 60 0) -- VK_SHARING_MODE_EXCLUSIVE
    |> (setU32 · 80 preTransform)
    |> (setU32 · 84 compositeAlpha)
    |> (setU32 · 88 presentMode)
    |> (setU32 · 92 VK_TRUE) -- clipped
    |> (setU64 · 96 oldSwapchain)

def encCommandPoolCreateInfo (qfi : UInt32) (flags : UInt32 := VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT) : ByteArray :=
  zeroBuf 24
    |> (setU32 · 0 VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO)
    |> (setU32 · 16 flags)
    |> (setU32 · 20 qfi)

def encCommandBufferAllocateInfo (pool : UInt64) (count : UInt32) : ByteArray :=
  zeroBuf 32
    |> (setU32 · 0 VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO)
    |> (setU64 · 16 pool)
    |> (setU32 · 24 VK_COMMAND_BUFFER_LEVEL_PRIMARY)
    |> (setU32 · 28 count)

def encCommandBufferBeginInfo (flags : UInt32 := VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT) : ByteArray :=
  zeroBuf 32
    |> (setU32 · 0 VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO)
    |> (setU32 · 16 flags)

def encFenceCreateInfo (signaled : Bool) : ByteArray :=
  zeroBuf 24
    |> (setU32 · 0 VK_STRUCTURE_TYPE_FENCE_CREATE_INFO)
    |> (setU32 · 16 (if signaled then VK_FENCE_CREATE_SIGNALED_BIT else 0))

def encSemaphoreCreateInfo : ByteArray :=
  zeroBuf 24 |> (setU32 · 0 VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO)

def encBufferCreateInfo (size : UInt64) (usage : UInt32) : ByteArray :=
  zeroBuf 56
    |> (setU32 · 0 VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO)
    |> (setU64 · 24 size)
    |> (setU32 · 32 usage)
    |> (setU32 · 36 0) -- EXCLUSIVE

def encImageCreateInfo (fmt w h layers usage : UInt32) : ByteArray :=
  zeroBuf 88
    |> (setU32 · 0 VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO)
    |> (setU32 · 20 VK_IMAGE_TYPE_2D)
    |> (setU32 · 24 fmt)
    |> (setU32 · 28 w)
    |> (setU32 · 32 h)
    |> (setU32 · 36 1) -- depth
    |> (setU32 · 40 1) -- mipLevels
    |> (setU32 · 44 layers)
    |> (setU32 · 48 VK_SAMPLE_COUNT_1_BIT)
    |> (setU32 · 52 VK_IMAGE_TILING_OPTIMAL)
    |> (setU32 · 56 usage)
    |> (setU32 · 60 0) -- EXCLUSIVE
    |> (setU32 · 80 VK_IMAGE_LAYOUT_UNDEFINED)

def encImageViewCreateInfo (image : UInt64) (viewType fmt baseLayer layerCount : UInt32) : ByteArray :=
  zeroBuf 80
    |> (setU32 · 0 VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO)
    |> (setU64 · 24 image)
    |> (setU32 · 32 viewType)
    |> (setU32 · 36 fmt)
    |> (setU32 · 56 VK_IMAGE_ASPECT_COLOR_BIT) -- subresourceRange.aspectMask
    |> (setU32 · 60 0) -- baseMipLevel
    |> (setU32 · 64 1) -- levelCount
    |> (setU32 · 68 baseLayer)
    |> (setU32 · 72 layerCount)

def encSamplerCreateInfo : ByteArray :=
  zeroBuf 80
    |> (setU32 · 0 VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO)
    |> (setU32 · 20 VK_FILTER_NEAREST)
    |> (setU32 · 24 VK_FILTER_NEAREST)
    |> (setU32 · 28 VK_SAMPLER_MIPMAP_MODE_NEAREST)
    |> (setU32 · 32 VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE)
    |> (setU32 · 36 VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE)
    |> (setU32 · 40 VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE)

def encMemoryAllocateInfo (allocSize : UInt64) (memTypeIdx : UInt32) : ByteArray :=
  zeroBuf 32
    |> (setU32 · 0 VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO)
    |> (setU64 · 16 allocSize)
    |> (setU32 · 24 memTypeIdx)

def encMappedMemoryRange (mem : UInt64) (offset size : UInt64 := VK_WHOLE_SIZE) : ByteArray :=
  zeroBuf 40
    |> (setU32 · 0 VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE)
    |> (setU64 · 16 mem)
    |> (setU64 · 24 offset)
    |> (setU64 · 32 size)

def encImageMemoryBarrier2 (srcStage srcAccess dstStage dstAccess : UInt64)
    (oldLayout newLayout : UInt32) (image : UInt64)
    (baseLayer : UInt32 := 0) (layerCount : UInt32 := 1) : ByteArray :=
  zeroBuf 96
    |> (setU32 · 0 VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2)
    |> (setU64 · 16 srcStage)
    |> (setU64 · 24 srcAccess)
    |> (setU64 · 32 dstStage)
    |> (setU64 · 40 dstAccess)
    |> (setU32 · 48 oldLayout)
    |> (setU32 · 52 newLayout)
    |> (setU32 · 56 VK_QUEUE_FAMILY_IGNORED)
    |> (setU32 · 60 VK_QUEUE_FAMILY_IGNORED)
    |> (setU64 · 64 image)
    |> (setU32 · 72 VK_IMAGE_ASPECT_COLOR_BIT)
    |> (setU32 · 76 0) -- baseMipLevel
    |> (setU32 · 80 1) -- levelCount
    |> (setU32 · 84 baseLayer)
    |> (setU32 · 88 layerCount)

def encDependencyInfo (barrierCount : UInt32) (barriersPtr : USize) : ByteArray :=
  zeroBuf 64
    |> (setU32 · 0 VK_STRUCTURE_TYPE_DEPENDENCY_INFO)
    |> (setU32 · 48 barrierCount)
    |> (setU64 · 56 barriersPtr.toUInt64)

def encBufferImageCopy2 (bufOffset : UInt64) (baseLayer : UInt32) (ox oy : Int) (ew eh : UInt32)
    (rowLen : UInt32 := 0) : ByteArray :=
  zeroBuf 72
    |> (setU32 · 0 VK_STRUCTURE_TYPE_BUFFER_IMAGE_COPY_2)
    |> (setU64 · 16 bufOffset)
    |> (setU32 · 24 rowLen)
    |> (setU32 · 28 0)
    |> (setU32 · 32 VK_IMAGE_ASPECT_COLOR_BIT)
    |> (setU32 · 36 0) -- mipLevel
    |> (setU32 · 40 baseLayer)
    |> (setU32 · 44 1) -- layerCount
    |> (setI32 · 48 ox)
    |> (setI32 · 52 oy)
    |> (setI32 · 56 0)
    |> (setU32 · 60 ew)
    |> (setU32 · 64 eh)
    |> (setU32 · 68 1)

def encCopyBufferToImageInfo2 (srcBuf dstImg : UInt64) (dstLayout regionCount : UInt32)
    (regionsPtr : USize) : ByteArray :=
  zeroBuf 48
    |> (setU32 · 0 VK_STRUCTURE_TYPE_COPY_BUFFER_TO_IMAGE_INFO_2)
    |> (setU64 · 16 srcBuf)
    |> (setU64 · 24 dstImg)
    |> (setU32 · 32 dstLayout)
    |> (setU32 · 36 regionCount)
    |> (setU64 · 40 regionsPtr.toUInt64)

def encCopyImageToBufferInfo2 (srcImg : UInt64) (srcLayout : UInt32) (dstBuf : UInt64)
    (regionCount : UInt32) (regionsPtr : USize) : ByteArray :=
  zeroBuf 56
    |> (setU32 · 0 VK_STRUCTURE_TYPE_COPY_IMAGE_TO_BUFFER_INFO_2)
    |> (setU64 · 16 srcImg)
    |> (setU32 · 24 srcLayout)
    |> (setU64 · 32 dstBuf)
    |> (setU32 · 40 regionCount)
    |> (setU64 · 48 regionsPtr.toUInt64)

def encImageBlit2 (sx0 sy0 sx1 sy1 dx0 dy0 dx1 dy1 : Int)
    (srcLayer dstLayer : UInt32 := 0) : ByteArray :=
  zeroBuf 96
    |> (setU32 · 0 VK_STRUCTURE_TYPE_IMAGE_BLIT_2)
    |> (setU32 · 16 VK_IMAGE_ASPECT_COLOR_BIT)
    |> (setU32 · 20 0) |> (setU32 · 24 srcLayer) |> (setU32 · 28 1)
    |> (setI32 · 32 sx0) |> (setI32 · 36 sy0) |> (setI32 · 40 0)
    |> (setI32 · 44 sx1) |> (setI32 · 48 sy1) |> (setI32 · 52 1)
    |> (setU32 · 56 VK_IMAGE_ASPECT_COLOR_BIT)
    |> (setU32 · 60 0) |> (setU32 · 64 dstLayer) |> (setU32 · 68 1)
    |> (setI32 · 72 dx0) |> (setI32 · 76 dy0) |> (setI32 · 80 0)
    |> (setI32 · 84 dx1) |> (setI32 · 88 dy1) |> (setI32 · 92 1)

def encBlitImageInfo2 (srcImg : UInt64) (srcLayout : UInt32) (dstImg : UInt64)
    (dstLayout regionCount : UInt32) (regionsPtr : USize) (filter : UInt32 := VK_FILTER_NEAREST) : ByteArray :=
  zeroBuf 64
    |> (setU32 · 0 VK_STRUCTURE_TYPE_BLIT_IMAGE_INFO_2)
    |> (setU64 · 16 srcImg)
    |> (setU32 · 24 srcLayout)
    |> (setU64 · 32 dstImg)
    |> (setU32 · 40 dstLayout)
    |> (setU32 · 44 regionCount)
    |> (setU64 · 48 regionsPtr.toUInt64)
    |> (setU32 · 56 filter)

def encImageCopy2 (sx sy dx dy : Int) (w h : UInt32) (srcLayer dstLayer : UInt32 := 0) : ByteArray :=
  zeroBuf 88
    |> (setU32 · 0 VK_STRUCTURE_TYPE_IMAGE_COPY_2)
    |> (setU32 · 16 VK_IMAGE_ASPECT_COLOR_BIT)
    |> (setU32 · 20 0) |> (setU32 · 24 srcLayer) |> (setU32 · 28 1)
    |> (setI32 · 32 sx) |> (setI32 · 36 sy) |> (setI32 · 40 0)
    |> (setU32 · 44 VK_IMAGE_ASPECT_COLOR_BIT)
    |> (setU32 · 48 0) |> (setU32 · 52 dstLayer) |> (setU32 · 56 1)
    |> (setI32 · 60 dx) |> (setI32 · 64 dy) |> (setI32 · 68 0)
    |> (setU32 · 72 w) |> (setU32 · 76 h) |> (setU32 · 80 1)

def encCopyImageInfo2 (srcImg : UInt64) (srcLayout : UInt32) (dstImg : UInt64)
    (dstLayout regionCount : UInt32) (regionsPtr : USize) : ByteArray :=
  zeroBuf 56
    |> (setU32 · 0 VK_STRUCTURE_TYPE_COPY_IMAGE_INFO_2)
    |> (setU64 · 16 srcImg)
    |> (setU32 · 24 srcLayout)
    |> (setU64 · 32 dstImg)
    |> (setU32 · 40 dstLayout)
    |> (setU32 · 44 regionCount)
    |> (setU64 · 48 regionsPtr.toUInt64)

def encSemaphoreSubmitInfo (sem : UInt64) (stageMask : UInt64) : ByteArray :=
  zeroBuf 48
    |> (setU32 · 0 VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO)
    |> (setU64 · 16 sem)
    |> (setU64 · 32 stageMask)

def encCommandBufferSubmitInfo (cb : UInt64) : ByteArray :=
  zeroBuf 32
    |> (setU32 · 0 VK_STRUCTURE_TYPE_COMMAND_BUFFER_SUBMIT_INFO)
    |> (setU64 · 16 cb)

def encSubmitInfo2 (waitCount : UInt32) (waitPtr : USize) (cbPtr : USize)
    (sigCount : UInt32) (sigPtr : USize) : ByteArray :=
  zeroBuf 64
    |> (setU32 · 0 VK_STRUCTURE_TYPE_SUBMIT_INFO_2)
    |> (setU32 · 20 waitCount)
    |> (setU64 · 24 waitPtr.toUInt64)
    |> (setU32 · 32 1)
    |> (setU64 · 40 cbPtr.toUInt64)
    |> (setU32 · 48 sigCount)
    |> (setU64 · 56 sigPtr.toUInt64)

def encPresentInfoKHR (pNext : USize) (waitSemPtr swapchainPtr imgIdxPtr : USize) : ByteArray :=
  zeroBuf 64
    |> (setU32 · 0 VK_STRUCTURE_TYPE_PRESENT_INFO_KHR)
    |> (setU64 · 8 pNext.toUInt64)
    |> (setU32 · 16 1)
    |> (setU64 · 24 waitSemPtr.toUInt64)
    |> (setU32 · 32 1)
    |> (setU64 · 40 swapchainPtr.toUInt64)
    |> (setU64 · 48 imgIdxPtr.toUInt64)

def encRectLayerKHR (x y : Int) (w h : UInt32) : ByteArray :=
  zeroBuf 20
    |> (setI32 · 0 x)
    |> (setI32 · 4 y)
    |> (setU32 · 8 w)
    |> (setU32 · 12 h)
    |> (setU32 · 16 0)

def encPresentRegionKHR (rectCount : UInt32) (rectsPtr : USize) : ByteArray :=
  zeroBuf 16
    |> (setU32 · 0 rectCount)
    |> (setU64 · 8 rectsPtr.toUInt64)

def encPresentRegionsKHR (regionsPtr : USize) : ByteArray :=
  zeroBuf 32
    |> (setU32 · 0 VK_STRUCTURE_TYPE_PRESENT_REGIONS_KHR)
    |> (setU32 · 16 1)
    |> (setU64 · 24 regionsPtr.toUInt64)

def encRenderingAttachmentInfo (view : UInt64) (loadOp : UInt32) (r g b a : Float) : ByteArray :=
  zeroBuf 72
    |> (setU32 · 0 VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO)
    |> (setU64 · 16 view)
    |> (setU32 · 24 VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL)
    |> (setU32 · 44 loadOp)
    |> (setU32 · 48 VK_ATTACHMENT_STORE_OP_STORE)
    |> (setF32 · 52 r)
    |> (setF32 · 56 g)
    |> (setF32 · 60 b)
    |> (setF32 · 64 a)

def encRenderingInfo (rx ry : Int) (rw rh : UInt32) (colorAttachPtr : USize) : ByteArray :=
  zeroBuf 72
    |> (setU32 · 0 VK_STRUCTURE_TYPE_RENDERING_INFO)
    |> (setI32 · 20 rx)
    |> (setI32 · 24 ry)
    |> (setU32 · 28 rw)
    |> (setU32 · 32 rh)
    |> (setU32 · 36 1) -- layerCount
    |> (setU32 · 44 1) -- colorAttachmentCount
    |> (setU64 · 48 colorAttachPtr.toUInt64)

def encViewport (w h : Float) : ByteArray :=
  zeroBuf 24
    |> (setF32 · 8 w)
    |> (setF32 · 12 h)
    |> (setF32 · 20 1.0)

def encRect2D (x y : Int) (w h : UInt32) : ByteArray :=
  zeroBuf 16
    |> (setI32 · 0 x)
    |> (setI32 · 4 y)
    |> (setU32 · 8 w)
    |> (setU32 · 12 h)

def encClearColorValue (r g b a : Float) : ByteArray :=
  zeroBuf 16
    |> (setF32 · 0 r)
    |> (setF32 · 4 g)
    |> (setF32 · 8 b)
    |> (setF32 · 12 a)

def encSubresourceRange (baseLayer layerCount : UInt32) : ByteArray :=
  zeroBuf 20
    |> (setU32 · 0 VK_IMAGE_ASPECT_COLOR_BIT)
    |> (setU32 · 4 0)
    |> (setU32 · 8 1)
    |> (setU32 · 12 baseLayer)
    |> (setU32 · 16 layerCount)

def encShaderModuleCreateInfo (codeSize : UInt64) (codePtr : USize) : ByteArray :=
  zeroBuf 40
    |> (setU32 · 0 VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO)
    |> (setU64 · 24 codeSize)
    |> (setU64 · 32 codePtr.toUInt64)

def encDescriptorSetLayoutBinding (binding descType count stageFlags : UInt32) : ByteArray :=
  zeroBuf 24
    |> (setU32 · 0 binding)
    |> (setU32 · 4 descType)
    |> (setU32 · 8 count)
    |> (setU32 · 12 stageFlags)

def encDescriptorSetLayoutCreateInfo (count : UInt32) (bindingsPtr : USize) : ByteArray :=
  zeroBuf 32
    |> (setU32 · 0 VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO)
    |> (setU32 · 20 count)
    |> (setU64 · 24 bindingsPtr.toUInt64)

def encDescriptorPoolSize (descType count : UInt32) : ByteArray :=
  zeroBuf 8 |> (setU32 · 0 descType) |> (setU32 · 4 count)

def encDescriptorPoolCreateInfo (flags maxSets poolSizeCount : UInt32) (poolSizesPtr : USize) : ByteArray :=
  zeroBuf 40
    |> (setU32 · 0 VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO)
    |> (setU32 · 16 flags)
    |> (setU32 · 20 maxSets)
    |> (setU32 · 24 poolSizeCount)
    |> (setU64 · 32 poolSizesPtr.toUInt64)

def encDescriptorSetAllocateInfo (pool : UInt64) (count : UInt32) (layoutsPtr : USize) : ByteArray :=
  zeroBuf 40
    |> (setU32 · 0 VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO)
    |> (setU64 · 16 pool)
    |> (setU32 · 24 count)
    |> (setU64 · 32 layoutsPtr.toUInt64)

def encDescriptorBufferInfo (buf : UInt64) (offset range : UInt64) : ByteArray :=
  zeroBuf 24
    |> (setU64 · 0 buf)
    |> (setU64 · 8 offset)
    |> (setU64 · 16 range)

def encDescriptorImageInfo (sampler view : UInt64) (layout : UInt32) : ByteArray :=
  zeroBuf 24
    |> (setU64 · 0 sampler)
    |> (setU64 · 8 view)
    |> (setU32 · 16 layout)

def encWriteDescriptorSetBuffer (dstSet : UInt64) (binding descType : UInt32) (bufInfoPtr : USize) : ByteArray :=
  zeroBuf 64
    |> (setU32 · 0 VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET)
    |> (setU64 · 16 dstSet)
    |> (setU32 · 24 binding)
    |> (setU32 · 32 1)
    |> (setU32 · 36 descType)
    |> (setU64 · 48 bufInfoPtr.toUInt64)

def encWriteDescriptorSetImage (dstSet : UInt64) (binding descType : UInt32) (imgInfoPtr : USize) : ByteArray :=
  zeroBuf 64
    |> (setU32 · 0 VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET)
    |> (setU64 · 16 dstSet)
    |> (setU32 · 24 binding)
    |> (setU32 · 32 1)
    |> (setU32 · 36 descType)
    |> (setU64 · 40 imgInfoPtr.toUInt64)

def encPushConstantRange (stageFlags offset size : UInt32) : ByteArray :=
  zeroBuf 12 |> (setU32 · 0 stageFlags) |> (setU32 · 4 offset) |> (setU32 · 8 size)

def encPipelineLayoutCreateInfo (setLayoutPtr : USize) (pushRangePtr : USize) : ByteArray :=
  zeroBuf 48
    |> (setU32 · 0 VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO)
    |> (setU32 · 20 1)
    |> (setU64 · 24 setLayoutPtr.toUInt64)
    |> (setU32 · 32 1)
    |> (setU64 · 40 pushRangePtr.toUInt64)

def encPipelineCacheCreateInfo (size : UInt64) (dataPtr : USize) : ByteArray :=
  zeroBuf 40
    |> (setU32 · 0 VK_STRUCTURE_TYPE_PIPELINE_CACHE_CREATE_INFO)
    |> (setU64 · 24 size)
    |> (setU64 · 32 dataPtr.toUInt64)

def encPipelineShaderStage (stage : UInt32) (mod : UInt64) (namePtr : USize) : ByteArray :=
  zeroBuf 48
    |> (setU32 · 0 VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO)
    |> (setU32 · 20 stage)
    |> (setU64 · 24 mod)
    |> (setU64 · 32 namePtr.toUInt64)

def encPipelineVertexInput : ByteArray :=
  zeroBuf 48 |> (setU32 · 0 VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO)

def encPipelineInputAssembly (topology : UInt32 := VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP) : ByteArray :=
  zeroBuf 32
    |> (setU32 · 0 VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO)
    |> (setU32 · 20 topology)

def encPipelineViewportState : ByteArray :=
  zeroBuf 48
    |> (setU32 · 0 VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO)
    |> (setU32 · 20 1)
    |> (setU32 · 32 1)

def encPipelineRasterization : ByteArray :=
  zeroBuf 64
    |> (setU32 · 0 VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO)
    |> (setU32 · 28 VK_POLYGON_MODE_FILL)
    |> (setU32 · 32 VK_CULL_MODE_NONE)
    |> (setU32 · 36 VK_FRONT_FACE_COUNTER_CLOCKWISE)
    |> (setF32 · 56 1.0)

def encPipelineMultisample : ByteArray :=
  zeroBuf 48
    |> (setU32 · 0 VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO)
    |> (setU32 · 20 VK_SAMPLE_COUNT_1_BIT)

def encColorBlendAttachmentPremul : ByteArray :=
  zeroBuf 32
    |> (setU32 · 0 VK_TRUE) -- blendEnable
    |> (setU32 · 4 VK_BLEND_FACTOR_ONE)
    |> (setU32 · 8 VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA)
    |> (setU32 · 12 VK_BLEND_OP_ADD)
    |> (setU32 · 16 VK_BLEND_FACTOR_ONE)
    |> (setU32 · 20 VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA)
    |> (setU32 · 24 VK_BLEND_OP_ADD)
    |> (setU32 · 28 VK_COLOR_COMPONENT_RGBA)

def encPipelineColorBlend (attachPtr : USize) : ByteArray :=
  zeroBuf 56
    |> (setU32 · 0 VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO)
    |> (setU32 · 28 1)
    |> (setU64 · 32 attachPtr.toUInt64)

def encPipelineDynamicState (statesPtr : USize) : ByteArray :=
  zeroBuf 32
    |> (setU32 · 0 VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO)
    |> (setU32 · 20 2)
    |> (setU64 · 24 statesPtr.toUInt64)

def encPipelineRenderingCreateInfo (fmtPtr : USize) : ByteArray :=
  zeroBuf 40
    |> (setU32 · 0 VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO)
    |> (setU32 · 20 1)
    |> (setU64 · 24 fmtPtr.toUInt64)

def encGraphicsPipelineCreateInfo (pNext stagesPtr viPtr iaPtr vpPtr rastPtr msPtr cbPtr dynPtr : USize)
    (layout : UInt64) : ByteArray :=
  zeroBuf 144
    |> (setU32 · 0 VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO)
    |> (setU64 · 8 pNext.toUInt64)
    |> (setU32 · 20 2)
    |> (setU64 · 24 stagesPtr.toUInt64)
    |> (setU64 · 32 viPtr.toUInt64)
    |> (setU64 · 40 iaPtr.toUInt64)
    |> (setU64 · 56 vpPtr.toUInt64)
    |> (setU64 · 64 rastPtr.toUInt64)
    |> (setU64 · 72 msPtr.toUInt64)
    |> (setU64 · 88 cbPtr.toUInt64)
    |> (setU64 · 96 dynPtr.toUInt64)
    |> (setU64 · 104 layout)
    |> (setI32 · 136 (-1))

def encComputePipelineCreateInfo (stageBytes : ByteArray) (layout : UInt64) : ByteArray :=
  let base := zeroBuf 96
    |> (setU32 · 0 VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO)
    |> (setU64 · 72 layout)
    |> (setI32 · 88 (-1))
  stageBytes.copySlice 0 base 24 48

end LeanUI.Vk
