import LeanUI.Defs
import LeanUI.Text
import LeanUI.Shaders
import LeanUI.VulkanSwapchain
/-!
# LeanUI.VulkanPipeline — Phase 2 Instanced GPU SDF, Glyph Atlas, Offscreen Layers, Blur & Readback

Implements the complete Phase 2 Vulkan 1.3 dynamic-rendering + compute pipeline:
- Embedded SPIR-V `shaders/scene_sdf.glsl` (VS+FS) and `shaders/blur_box.comp.glsl` (CS)
- Persistent `VkPipelineCache` (`$XDG_CACHE_HOME/orb-desktop/vk_pipeline.cache`)
- Dynamic SSBO ring (`1 MiB` initial, 2× growth up to `16 MiB`) + `ClipNode` SSBO (`clipPushRounded`)
- Fixed 8-layer `1024×1024` `VK_IMAGE_VIEW_TYPE_2D_ARRAY` `uAtlas` with dirty sub-uploads and
  `vkCmdClearColorImage` on `GlyphAtlasCache.generation` reset
- Fixed 4-layer `VK_IMAGE_VIEW_TYPE_2D_ARRAY` `uLayers` with clamped `VkRenderingInfo.renderArea`
- Ping-pong `P0`/`P1` (`R8G8B8A8_UNORM`, `STORAGE | TRANSFER_SRC | TRANSFER_DST | COLOR_ATTACHMENT | SAMPLED`)
  for `backdropBlur` (blit -> 6 compute passes -> blit back) and compute `.shadow` (mask -> 6 compute passes -> composite)
- Headless offscreen `--gpu-readback` renderer for both Phase 1 (`vkPresent`) and Phase 2 (`vkInstanced`)
  differential parity testing on Lavapipe / Honeykrisp / NVIDIA.
-/
namespace LeanUI.Vk

open LeanUI

/-- Packed 80-byte GPU primitive record matching `struct PrimInstance` in `shaders/scene_sdf.glsl`. -/
structure GpuPrimRecord where
  dst : Rect
  uv : Rect
  clip : Rect
  radii : Nat × Nat × Nat × Nat
  colorRGBA : Color
  kind : UInt32
  roundedClipIdx : UInt32 := 0
  aux0 : UInt32 := 0
  aux1 : UInt32 := 255
  deriving DecidableEq, Repr, Inhabited

/-- 48-byte rounded clip node matching `struct ClipNode` in `shaders/scene_sdf.glsl`. -/
structure RoundedClipNode where
  rect : Rect
  radii : Nat × Nat × Nat × Nat
  parentIdx : UInt32 := 0
  deriving DecidableEq, Repr, Inhabited

/-- Ordered GPU execution operations produced by lowering a `Scene`. -/
inductive RenderOp where
  | drawBatch (firstInst count : Nat) (scissor : Rect)
  | layerPush (slot : Nat) (clip : Rect)
  | layerPop (slot : Nat) (clip : Rect) (compInstIdx : Nat)
  | backdropBlur (sigma : Nat)
  | shadow (mx my mw mh sigma : Nat) (maskInstIdx : Nat) (compInstIdx : Nat) (scissor : Rect)
  deriving Repr

/-- Pure lowered frame ready for GPU SSBO staging and command recording. -/
structure LoweredFrame where
  instances : Array GpuPrimRecord := #[]
  clips : Array RoundedClipNode := #[]
  ops : Array RenderOp := #[]
  needsLayers : Bool := false
  needsBlur : Bool := false

@[inline] private def intersectRectLocal (a b : Rect) : Rect :=
  let x0 := max a.x b.x
  let y0 := min (max a.y b.y) (max a.bottom b.bottom)
  let x1 := max x0 (min a.right b.right)
  let y1 := max y0 (min a.bottom b.bottom)
  { x := x0, y := y0, w := x1 - x0, h := y1 - y0 }

/-- Purely lower a `Scene` into `GpuPrimRecord`s, `RoundedClipNode`s, and ordered `RenderOp`s. -/
def lowerScene (vw vh : Nat) (scene : Scene) : LoweredFrame := Id.run do
  let vp : Rect := ⟨0, 0, vw, vh⟩
  let mut insts : Array GpuPrimRecord := #[]
  let mut clips : Array RoundedClipNode := #[]
  let mut ops : Array RenderOp := #[]
  let mut clipStack : List Rect := [vp]
  let mut rclipStack : List UInt32 := [0]
  -- Layer stack tracks (slot, opacity, clampedClip, skipped, rounded clips active at the push).
  -- Those clips are set aside while the layer is drawn and applied once, by its composite.
  let mut layerStack : List (Nat × Nat × Rect × Bool × List UInt32) := []
  let mut skipDepth : Nat := 0
  let mut needsLayers := false
  let mut needsBlur := false

  let pushDraw (opsIn : Array RenderOp) (idx : Nat) (scissor : Rect) : Array RenderOp :=
    if scissor.isEmpty then opsIn
    else
      match opsIn.back? with
      | some (.drawBatch first cnt sc) =>
        if sc == scissor && first + cnt == idx then
          opsIn.pop.push (.drawBatch first (cnt + 1) sc)
        else opsIn.push (.drawBatch idx 1 scissor)
      | _ => opsIn.push (.drawBatch idx 1 scissor)

  for prim in scene do
    let curClip := clipStack.head?.getD vp
    let curRClip := rclipStack.head?.getD 0
    match prim with
    | .clipPush r =>
      clipStack := intersectRectLocal curClip r :: clipStack
      rclipStack := curRClip :: rclipStack
    | .clipPushRounded r radii =>
      let nextClip := intersectRectLocal curClip r
      clipStack := nextClip :: clipStack
      let nodeIdx : UInt32 := (clips.size + 1).toUInt32
      clips := clips.push { rect := r, radii, parentIdx := curRClip }
      rclipStack := nodeIdx :: rclipStack
    | .clipPop =>
      if let _ :: tail := clipStack then
        clipStack := if tail.isEmpty then [vp] else tail
      if let _ :: rtail := rclipStack then
        rclipStack := if rtail.isEmpty then [0] else rtail
    | .layerPush opacity =>
      let clamped := intersectRectLocal curClip vp
      let depth := layerStack.length
      if skipDepth > 0 || clamped.isEmpty || depth >= 4 then
        skipDepth := skipDepth + 1
        layerStack := (depth, min opacity 255, clamped, true, rclipStack) :: layerStack
      else
        needsLayers := true
        ops := ops.push (.layerPush depth clamped)
        layerStack := (depth, min opacity 255, clamped, false, rclipStack) :: layerStack
      rclipStack := [0]
    | .layerPop =>
      if let (slot, opacity, clamped, skipped, outerRClips) :: rest := layerStack then
        layerStack := rest
        rclipStack := outerRClips
        let curRClip := outerRClips.head?.getD 0
        if skipped then
          skipDepth := skipDepth - 1
        else
          let compIdx := insts.size
          insts := insts.push {
            dst := clamped, uv := ⟨0, 0, 0, 0⟩, clip := clamped,
            radii := (0, 0, 0, 0), colorRGBA := 0xFFFFFFFF,
            kind := 7, roundedClipIdx := curRClip,
            aux0 := slot.toUInt32, aux1 := opacity.toUInt32
          }
          ops := ops.push (.layerPop slot clamped compIdx)
    | .backdropBlur sigma =>
      if skipDepth == 0 && sigma > 0 then
        needsBlur := true
        ops := ops.push (.backdropBlur sigma)
    | _ =>
      if skipDepth > 0 || curClip.isEmpty || !prim.intersects curClip then continue
      match prim with
      | .quad r fill rad bw border =>
        let radii := (rad, rad, rad, rad)
        if (fill &&& 0xFF) != 0 then
          let i0 := insts.size
          insts := insts.push {
            dst := r, uv := ⟨0, 0, 0, 0⟩, clip := curClip, radii,
            colorRGBA := fill, kind := 0, roundedClipIdx := curRClip
          }
          ops := pushDraw ops i0 curClip
        if bw > 0 && (border &&& 0xFF) != 0 then
          let i1 := insts.size
          insts := insts.push {
            dst := r, uv := ⟨bw, bw, bw, bw⟩, clip := curClip, radii,
            colorRGBA := border, kind := 1, roundedClipIdx := curRClip
          }
          ops := pushDraw ops i1 curClip
      | .rrect r fill radii borders border =>
        let (bt, brW, bbW, blW) := borders
        if (fill &&& 0xFF) != 0 then
          let i0 := insts.size
          insts := insts.push {
            dst := r, uv := ⟨0, 0, 0, 0⟩, clip := curClip, radii,
            colorRGBA := fill, kind := 0, roundedClipIdx := curRClip
          }
          ops := pushDraw ops i0 curClip
        if (bt > 0 || brW > 0 || bbW > 0 || blW > 0) && (border &&& 0xFF) != 0 then
          let i1 := insts.size
          insts := insts.push {
            dst := r, uv := ⟨bt, brW, bbW, blW⟩, clip := curClip, radii,
            colorRGBA := border, kind := 1, roundedClipIdx := curRClip
          }
          ops := pushDraw ops i1 curClip
      | .linear r c0 c1 angleDeg rad =>
        let i0 := insts.size
        let aux1 : UInt32 := (255 : UInt32) ||| ((angleDeg % 360).toUInt32 <<< 8)
        insts := insts.push {
          dst := r, uv := ⟨0, 0, 0, 0⟩, clip := curClip, radii := (rad, rad, rad, rad),
          colorRGBA := c0, kind := 6, roundedClipIdx := curRClip,
          aux0 := c1, aux1
        }
        ops := pushDraw ops i0 curClip
      | .shadow r col rad blur =>
        let sa := col &&& 0xFF
        if sa != 0 then
          let sigma := blur / 2
          let halo : Int := if sigma == 0 then 0 else (sigma + (sigma - 1) * 2 : Nat)
          let support : Rect := ⟨r.x - halo, r.y - halo, r.w + 2 * halo, r.h + 2 * halo⟩
          let clipped := intersectRectLocal curClip (intersectRectLocal vp support)
          if !clipped.isEmpty then
            let mx := max 0 (clipped.x - halo)
            let my := max 0 (clipped.y - halo)
            let mw := (min (vw : Int) (clipped.right + halo) - mx).toNat
            let mh := (min (vh : Int) (clipped.bottom + halo) - my).toNat
            if mw > 0 && mh > 0 then
              needsBlur := true
              let maskIdx := insts.size
              insts := insts.push {
                dst := { r with x := r.x - mx, y := r.y - my }
                uv := ⟨0, 0, 0, 0⟩
                clip := ⟨0, 0, mw, mh⟩
                radii := (rad, rad, rad, rad)
                colorRGBA := 0xFFFFFFFF
                kind := 0
                roundedClipIdx := 0
              }
              let sx := clipped.x - mx
              let sy := clipped.y - my
              let compIdx := insts.size
              insts := insts.push {
                dst := clipped
                uv := ⟨sx, sy, clipped.w, clipped.h⟩
                clip := curClip
                radii := (0, 0, 0, 0)
                colorRGBA := col
                kind := 2
                roundedClipIdx := curRClip
                aux0 := blur.toUInt32
              }
              ops := ops.push (.shadow mx.toNat my.toNat mw mh sigma maskIdx compIdx curClip)
      | .glyph src dst col isColor page =>
        if (col &&& 0xFF) != 0 && !dst.isEmpty && src.w > 0 && src.h > 0 then
          let i0 := insts.size
          insts := insts.push {
            dst, uv := src, clip := curClip, radii := (0, 0, 0, 0),
            colorRGBA := col, kind := if isColor then 4 else 3,
            roundedClipIdx := curRClip, aux0 := page.toUInt32
          }
          ops := pushDraw ops i0 curClip
      | .mask pageIdx src dst col =>
        if (col &&& 0xFF) != 0 && !dst.isEmpty && src.w > 0 && src.h > 0 then
          let i0 := insts.size
          insts := insts.push {
            dst, uv := src, clip := curClip, radii := (0, 0, 0, 0),
            colorRGBA := col, kind := 3,
            roundedClipIdx := curRClip, aux0 := pageIdx.toUInt32
          }
          ops := pushDraw ops i0 curClip
      | .image _tex _src dst rad =>
        if !dst.isEmpty then
          let i0 := insts.size
          insts := insts.push {
            dst, uv := ⟨0, 0, 0, 0⟩, clip := curClip, radii := (rad, rad, rad, rad),
            colorRGBA := 0xC8D2E6FF, kind := 5, roundedClipIdx := curRClip
          }
          ops := pushDraw ops i0 curClip
      | _ => pure ()

  return { instances := insts, clips, ops, needsLayers, needsBlur }

/-- Serialize `Array GpuPrimRecord` into tightly packed 80-byte `std430` records. -/
def packPrimRecords (insts : Array GpuPrimRecord) : ByteArray := Id.run do
  let mut buf := ByteArray.emptyWithCapacity (max 80 (insts.size * 80))
  for inst in insts do
    let (tl, tr, br, bl) := inst.radii
    buf := pushU32 buf inst.dst.x.toInt32.toUInt32
    buf := pushU32 buf inst.dst.y.toInt32.toUInt32
    buf := pushU32 buf inst.dst.w.toInt32.toUInt32
    buf := pushU32 buf inst.dst.h.toInt32.toUInt32
    buf := pushU32 buf inst.uv.x.toInt32.toUInt32
    buf := pushU32 buf inst.uv.y.toInt32.toUInt32
    buf := pushU32 buf inst.uv.w.toInt32.toUInt32
    buf := pushU32 buf inst.uv.h.toInt32.toUInt32
    buf := pushU32 buf inst.clip.x.toInt32.toUInt32
    buf := pushU32 buf inst.clip.y.toInt32.toUInt32
    buf := pushU32 buf inst.clip.w.toInt32.toUInt32
    buf := pushU32 buf inst.clip.h.toInt32.toUInt32
    buf := pushU32 buf tl.toUInt32
    buf := pushU32 buf tr.toUInt32
    buf := pushU32 buf br.toUInt32
    buf := pushU32 buf bl.toUInt32
    buf := pushU32 buf inst.colorRGBA
    buf := pushU32 buf (inst.kind ||| (inst.roundedClipIdx <<< 8))
    buf := pushU32 buf inst.aux0
    buf := pushU32 buf inst.aux1
  if insts.isEmpty then buf := zeroBuf 80
  return buf

/-- Serialize `Array RoundedClipNode` into tightly packed 48-byte `std430` records. -/
def packClipNodes (clips : Array RoundedClipNode) : ByteArray := Id.run do
  let mut buf := ByteArray.emptyWithCapacity (max 48 (clips.size * 48))
  for cn in clips do
    let (tl, tr, br, bl) := cn.radii
    buf := pushU32 buf cn.rect.x.toInt32.toUInt32
    buf := pushU32 buf cn.rect.y.toInt32.toUInt32
    buf := pushU32 buf cn.rect.w.toInt32.toUInt32
    buf := pushU32 buf cn.rect.h.toInt32.toUInt32
    buf := pushU32 buf tl.toUInt32
    buf := pushU32 buf tr.toUInt32
    buf := pushU32 buf br.toUInt32
    buf := pushU32 buf bl.toUInt32
    buf := pushU32 buf cn.parentIdx
    buf := pushU32 buf 0
    buf := pushU32 buf 0
    buf := pushU32 buf 0
  if clips.isEmpty then buf := zeroBuf 48
  return buf

/-- Phase 2 instanced GPU pipeline, descriptor sets, dynamic SSBOs, 8-layer atlas,
4-layer offscreen pool, and ping-pong compute blur targets. -/
structure VkInstancedPipeline where
  targetFormat : UInt32 := VK_FORMAT_B8G8R8A8_UNORM
  sampler : UInt64 := 0
  pipelineCache : UInt64 := 0
  gfxSetLayout : UInt64 := 0
  gfxPipeLayout : UInt64 := 0
  gfxPipeTarget : UInt64 := 0
  gfxPipeRgba : UInt64 := 0
  blurSetLayout : UInt64 := 0
  blurPipeLayout : UInt64 := 0
  blurPipe : UInt64 := 0
  descPool : UInt64 := 0
  gfxDescSets : Array UInt64 := #[] -- 2 sets (one per frame slot)
  blurDescSet01 : UInt64 := 0
  blurDescSet10 : UInt64 := 0
  instanceBufs : Array VkGpuBuffer := #[] -- 2 dynamic SSBOs (start 1 MiB, grow to 16 MiB)
  clipBufs : Array VkGpuBuffer := #[]     -- 2 dynamic ClipNode SSBOs (start 64 KiB)
  atlasImage : VkGpuImage := {}           -- 1024×1024×8 R8G8B8A8_UNORM 2D array
  atlasInitialized : Bool := false
  lastAtlasGen : UInt64 := 0
  layerImage : VkGpuImage := {}           -- vw×vh×4 R8G8B8A8_UNORM 2D array
  layerAttachViews : Array UInt64 := #[]  -- 4 2D attachment views into layerImage
  blurP0 : VkGpuImage := {}               -- vw×vh R8G8B8A8_UNORM (STORAGE | COLOR_ATTACHMENT | TRANSFER | SAMPLED)
  blurP1 : VkGpuImage := {}               -- vw×vh R8G8B8A8_UNORM (STORAGE | TRANSFER | SAMPLED)
  deriving Inhabited

private def pipelineCachePath : IO (Option System.FilePath) := do
  if let some xdg ← IO.getEnv "XDG_CACHE_HOME" then
    if !xdg.isEmpty then return some (System.FilePath.mk xdg / "orb-desktop" / "vk_pipeline.cache")
  if let some home ← IO.getEnv "HOME" then
    if !home.isEmpty then return some (System.FilePath.mk home / ".cache" / "orb-desktop" / "vk_pipeline.cache")
  return none

private def loadPipelineCacheBytes : IO ByteArray := do
  match ← pipelineCachePath with
  | none => return ByteArray.empty
  | some p =>
    try IO.FS.readBinFile p catch _ => return ByteArray.empty

private def savePipelineCache (dev : VkDeviceCtx) (cache : UInt64) : IO Unit := do
  if cache == 0 || dev.fns.getPipelineCacheData == 0 then return
  let some path ← pipelineCachePath | return
  let bytesOpt ← withArena fun a => do
    let szPtr ← a.u64 0
    let r0 ← callRes dev.fns.getPipelineCacheData dev.device cache szPtr.toUInt64 0
    if r0 != VK_SUCCESS then return none
    let sz := (← readU64Ptr szPtr).toNat
    if sz == 0 || sz > 16 * 1024 * 1024 then return none
    let buf ← a.alloc sz
    let r1 ← callRes dev.fns.getPipelineCacheData dev.device cache szPtr.toUInt64 buf.toUInt64
    if r1 != VK_SUCCESS then return none
    return some (← LeanUI.FFI.memRead buf sz.toUSize)
  if let some bytes := bytesOpt then
    try
      if let some parent := path.parent then IO.FS.createDirAll parent
      let tmpPath := System.FilePath.mk (path.toString ++ ".tmp")
      IO.FS.writeBinFile tmpPath bytes
      IO.FS.rename tmpPath path
    catch _ => pure ()

private def createShaderModule (dev : VkDeviceCtx) (spv : ByteArray) : IO (Except String UInt64) :=
  withArena fun a => do
    let codePtr ← a.write spv
    let ci ← a.write (encShaderModuleCreateInfo spv.size.toUInt64 codePtr)
    let out ← a.alloc 8
    let r ← callRes dev.fns.createShaderModule dev.device ci.toUInt64 0 out.toUInt64
    if r != VK_SUCCESS then return .error s!"vkCreateShaderModule failed ({r})"
    return .ok (← readU64Ptr out)

private def createGfxPipelineForFormat (dev : VkDeviceCtx) (cache layout vertMod fragMod : UInt64)
    (fmt : UInt32) : IO (Except String UInt64) :=
  withArena fun a => do
    let entryName ← a.cstr "main"
    let s0 := encPipelineShaderStage VK_SHADER_STAGE_VERTEX_BIT vertMod entryName
    let s1 := encPipelineShaderStage VK_SHADER_STAGE_FRAGMENT_BIT fragMod entryName
    let stagesPtr ← a.write (s0 ++ s1)
    let viPtr ← a.write encPipelineVertexInput
    let iaPtr ← a.write (encPipelineInputAssembly VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP)
    let vpPtr ← a.write encPipelineViewportState
    let rastPtr ← a.write encPipelineRasterization
    let msPtr ← a.write encPipelineMultisample
    let cbAttachPtr ← a.write encColorBlendAttachmentPremul
    let cbPtr ← a.write (encPipelineColorBlend cbAttachPtr)
    let dynStates ← a.write (pushU32 (pushU32 (ByteArray.emptyWithCapacity 8) VK_DYNAMIC_STATE_VIEWPORT) VK_DYNAMIC_STATE_SCISSOR)
    let dynPtr ← a.write (encPipelineDynamicState dynStates)
    let fmtPtr ← a.u32 fmt
    let rendPtr ← a.write (encPipelineRenderingCreateInfo fmtPtr)
    let gpci ← a.write (encGraphicsPipelineCreateInfo rendPtr stagesPtr viPtr iaPtr vpPtr rastPtr msPtr cbPtr dynPtr layout)
    let out ← a.alloc 8
    let r ← callRes dev.fns.createGraphicsPipelines dev.device cache 1 gpci.toUInt64 0 out.toUInt64
    if r != VK_SUCCESS then return .error s!"vkCreateGraphicsPipelines(fmt={fmt}) failed ({r})"
    return .ok (← readU64Ptr out)

def destroyInstancedPipeline (dev : VkDeviceCtx) (p : VkInstancedPipeline) : IO Unit := do
  waitDeviceIdle dev
  savePipelineCache dev p.pipelineCache
  for v in p.layerAttachViews do
    if v != 0 then callVoid dev.fns.destroyImageView dev.device v 0
  destroyGpuImage dev p.layerImage
  destroyGpuImage dev p.blurP0
  destroyGpuImage dev p.blurP1
  destroyGpuImage dev p.atlasImage
  for b in p.instanceBufs do destroyGpuBuffer dev b
  for b in p.clipBufs do destroyGpuBuffer dev b
  if p.descPool != 0 then callVoid dev.fns.destroyDescriptorPool dev.device p.descPool 0
  if p.blurPipe != 0 then callVoid dev.fns.destroyPipeline dev.device p.blurPipe 0
  if p.gfxPipeRgba != 0 && p.gfxPipeRgba != p.gfxPipeTarget then
    callVoid dev.fns.destroyPipeline dev.device p.gfxPipeRgba 0
  if p.gfxPipeTarget != 0 then callVoid dev.fns.destroyPipeline dev.device p.gfxPipeTarget 0
  if p.blurPipeLayout != 0 then callVoid dev.fns.destroyPipelineLayout dev.device p.blurPipeLayout 0
  if p.gfxPipeLayout != 0 then callVoid dev.fns.destroyPipelineLayout dev.device p.gfxPipeLayout 0
  if p.blurSetLayout != 0 then callVoid dev.fns.destroyDescriptorSetLayout dev.device p.blurSetLayout 0
  if p.gfxSetLayout != 0 then callVoid dev.fns.destroyDescriptorSetLayout dev.device p.gfxSetLayout 0
  if p.pipelineCache != 0 then callVoid dev.fns.destroyPipelineCache dev.device p.pipelineCache 0
  if p.sampler != 0 then callVoid dev.fns.destroySampler dev.device p.sampler 0

private def updateGfxDescriptorSet (dev : VkDeviceCtx) (p : VkInstancedPipeline) (slotIdx : Nat) : IO Unit :=
  withArena fun a => do
    let ds := p.gfxDescSets[slotIdx]!
    let ib := p.instanceBufs[slotIdx]!
    let cb := p.clipBufs[slotIdx]!
    let bi0 ← a.write (encDescriptorBufferInfo ib.buffer 0 VK_WHOLE_SIZE)
    let ii1 ← a.write (encDescriptorImageInfo p.sampler p.atlasImage.view VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL)
    let bi2 ← a.write (encDescriptorBufferInfo cb.buffer 0 VK_WHOLE_SIZE)
    let ii3 ← a.write (encDescriptorImageInfo p.sampler p.layerImage.view VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL)
    let ii4 ← a.write (encDescriptorImageInfo p.sampler p.blurP0.view VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL)
    let writes :=
      encWriteDescriptorSetBuffer ds 0 VK_DESCRIPTOR_TYPE_STORAGE_BUFFER bi0 ++
      encWriteDescriptorSetImage ds 1 VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER ii1 ++
      encWriteDescriptorSetBuffer ds 2 VK_DESCRIPTOR_TYPE_STORAGE_BUFFER bi2 ++
      encWriteDescriptorSetImage ds 3 VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER ii3 ++
      encWriteDescriptorSetImage ds 4 VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER ii4
    let wPtr ← a.write writes
    callVoid dev.fns.updateDescriptorSets dev.device 5 wPtr.toUInt64 0 0

private def updateBlurDescriptorSets (dev : VkDeviceCtx) (p : VkInstancedPipeline) : IO Unit :=
  withArena fun a => do
    let i0 ← a.write (encDescriptorImageInfo 0 p.blurP0.view VK_IMAGE_LAYOUT_GENERAL)
    let i1 ← a.write (encDescriptorImageInfo 0 p.blurP1.view VK_IMAGE_LAYOUT_GENERAL)
    let writes :=
      encWriteDescriptorSetImage p.blurDescSet01 0 VK_DESCRIPTOR_TYPE_STORAGE_IMAGE i0 ++
      encWriteDescriptorSetImage p.blurDescSet01 1 VK_DESCRIPTOR_TYPE_STORAGE_IMAGE i1 ++
      encWriteDescriptorSetImage p.blurDescSet10 0 VK_DESCRIPTOR_TYPE_STORAGE_IMAGE i1 ++
      encWriteDescriptorSetImage p.blurDescSet10 1 VK_DESCRIPTOR_TYPE_STORAGE_IMAGE i0
    let wPtr ← a.write writes
    callVoid dev.fns.updateDescriptorSets dev.device 4 wPtr.toUInt64 0 0

/-- Create Phase 2 instanced GPU pipeline targeting `targetFormat`. -/
def createInstancedPipeline (dev : VkDeviceCtx) (targetFormat : UInt32) :
    IO (Except String VkInstancedPipeline) := do
  if !dev.hasDynamicRendering then
    return .error "Vulkan 1.3 dynamicRendering unsupported on device"

  let mut pipe : VkInstancedPipeline := { targetFormat }
  let fail (e : String) (p : VkInstancedPipeline) : IO (Except String VkInstancedPipeline) := do
    destroyInstancedPipeline dev p
    return .error e

  -- Sampler (NEAREST, CLAMP_TO_EDGE)
  let sampRes ← withArena fun a => do
    let sci ← a.write encSamplerCreateInfo
    let out ← a.alloc 8
    let r ← callRes dev.fns.createSampler dev.device sci.toUInt64 0 out.toUInt64
    if r != VK_SUCCESS then return Except.error s!"vkCreateSampler failed ({r})"
    return Except.ok (← readU64Ptr out)
  match sampRes with
  | .error e => return ← fail e pipe
  | .ok s => pipe := { pipe with sampler := s }

  -- Pipeline cache (best-effort load from disk)
  let cacheBytes ← loadPipelineCacheBytes
  let pcRes ← withArena fun a => do
    let dataPtr ← if cacheBytes.isEmpty then pure 0 else a.write cacheBytes
    let ci ← a.write (encPipelineCacheCreateInfo cacheBytes.size.toUInt64 dataPtr)
    let out ← a.alloc 8
    let r ← callRes dev.fns.createPipelineCache dev.device ci.toUInt64 0 out.toUInt64
    if r != VK_SUCCESS then return Except.error s!"vkCreatePipelineCache failed ({r})"
    return Except.ok (← readU64Ptr out)
  match pcRes with
  | .error e => return ← fail e pipe
  | .ok c => pipe := { pipe with pipelineCache := c }

  -- Graphics Descriptor Set Layout (bindings 0..4)
  let gslRes ← withArena fun a => do
    let b0 := encDescriptorSetLayoutBinding 0 VK_DESCRIPTOR_TYPE_STORAGE_BUFFER 1 (VK_SHADER_STAGE_VERTEX_BIT ||| VK_SHADER_STAGE_FRAGMENT_BIT)
    let b1 := encDescriptorSetLayoutBinding 1 VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER 1 VK_SHADER_STAGE_FRAGMENT_BIT
    let b2 := encDescriptorSetLayoutBinding 2 VK_DESCRIPTOR_TYPE_STORAGE_BUFFER 1 VK_SHADER_STAGE_FRAGMENT_BIT
    let b3 := encDescriptorSetLayoutBinding 3 VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER 1 VK_SHADER_STAGE_FRAGMENT_BIT
    let b4 := encDescriptorSetLayoutBinding 4 VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER 1 VK_SHADER_STAGE_FRAGMENT_BIT
    let bp ← a.write (b0 ++ b1 ++ b2 ++ b3 ++ b4)
    let ci ← a.write (encDescriptorSetLayoutCreateInfo 5 bp)
    let out ← a.alloc 8
    let r ← callRes dev.fns.createDescriptorSetLayout dev.device ci.toUInt64 0 out.toUInt64
    if r != VK_SUCCESS then return Except.error s!"vkCreateDescriptorSetLayout(gfx) failed ({r})"
    return Except.ok (← readU64Ptr out)
  match gslRes with
  | .error e => return ← fail e pipe
  | .ok l => pipe := { pipe with gfxSetLayout := l }

  -- Graphics Pipeline Layout (32-byte push constants)
  let gplRes ← withArena fun a => do
    let lp ← a.u64 pipe.gfxSetLayout
    let pcr ← a.write (encPushConstantRange (VK_SHADER_STAGE_VERTEX_BIT ||| VK_SHADER_STAGE_FRAGMENT_BIT) 0 32)
    let ci ← a.write (encPipelineLayoutCreateInfo lp pcr)
    let out ← a.alloc 8
    let r ← callRes dev.fns.createPipelineLayout dev.device ci.toUInt64 0 out.toUInt64
    if r != VK_SUCCESS then return Except.error s!"vkCreatePipelineLayout(gfx) failed ({r})"
    return Except.ok (← readU64Ptr out)
  match gplRes with
  | .error e => return ← fail e pipe
  | .ok l => pipe := { pipe with gfxPipeLayout := l }

  -- Compute Blur Descriptor Set Layout (bindings 0..1) & Pipeline Layout (16-byte push constants)
  let bslRes ← withArena fun a => do
    let b0 := encDescriptorSetLayoutBinding 0 VK_DESCRIPTOR_TYPE_STORAGE_IMAGE 1 VK_SHADER_STAGE_COMPUTE_BIT
    let b1 := encDescriptorSetLayoutBinding 1 VK_DESCRIPTOR_TYPE_STORAGE_IMAGE 1 VK_SHADER_STAGE_COMPUTE_BIT
    let bp ← a.write (b0 ++ b1)
    let ci ← a.write (encDescriptorSetLayoutCreateInfo 2 bp)
    let out ← a.alloc 8
    let r ← callRes dev.fns.createDescriptorSetLayout dev.device ci.toUInt64 0 out.toUInt64
    if r != VK_SUCCESS then return Except.error s!"vkCreateDescriptorSetLayout(blur) failed ({r})"
    return Except.ok (← readU64Ptr out)
  match bslRes with
  | .error e => return ← fail e pipe
  | .ok l => pipe := { pipe with blurSetLayout := l }

  let bplRes ← withArena fun a => do
    let lp ← a.u64 pipe.blurSetLayout
    let pcr ← a.write (encPushConstantRange VK_SHADER_STAGE_COMPUTE_BIT 0 16)
    let ci ← a.write (encPipelineLayoutCreateInfo lp pcr)
    let out ← a.alloc 8
    let r ← callRes dev.fns.createPipelineLayout dev.device ci.toUInt64 0 out.toUInt64
    if r != VK_SUCCESS then return Except.error s!"vkCreatePipelineLayout(blur) failed ({r})"
    return Except.ok (← readU64Ptr out)
  match bplRes with
  | .error e => return ← fail e pipe
  | .ok l => pipe := { pipe with blurPipeLayout := l }

  -- Shader modules + graphics & compute pipelines
  let vertMod ← match ← createShaderModule dev (LeanUI.Shaders.sceneSdfVertSpv ()) with
    | .error e => return ← fail e pipe
    | .ok m => pure m
  let fragMod ← match ← createShaderModule dev (LeanUI.Shaders.sceneSdfFragSpv ()) with
    | .error e => callVoid dev.fns.destroyShaderModule dev.device vertMod 0; return ← fail e pipe
    | .ok m => pure m
  let compMod ← match ← createShaderModule dev (LeanUI.Shaders.blurBoxCompSpv ()) with
    | .error e =>
      callVoid dev.fns.destroyShaderModule dev.device fragMod 0
      callVoid dev.fns.destroyShaderModule dev.device vertMod 0
      return ← fail e pipe
    | .ok m => pure m

  let gpTargetRes ← createGfxPipelineForFormat dev pipe.pipelineCache pipe.gfxPipeLayout vertMod fragMod targetFormat
  let gpRgbaRes ←
    if targetFormat == VK_FORMAT_R8G8B8A8_UNORM then pure gpTargetRes
    else createGfxPipelineForFormat dev pipe.pipelineCache pipe.gfxPipeLayout vertMod fragMod VK_FORMAT_R8G8B8A8_UNORM

  let bpRes ← withArena fun a => do
    let entryName ← a.cstr "main"
    let stage := encPipelineShaderStage VK_SHADER_STAGE_COMPUTE_BIT compMod entryName
    let ci ← a.write (encComputePipelineCreateInfo stage pipe.blurPipeLayout)
    let out ← a.alloc 8
    let r ← callRes dev.fns.createComputePipelines dev.device pipe.pipelineCache 1 ci.toUInt64 0 out.toUInt64
    if r != VK_SUCCESS then return Except.error s!"vkCreateComputePipelines failed ({r})"
    return Except.ok (← readU64Ptr out)

  callVoid dev.fns.destroyShaderModule dev.device compMod 0
  callVoid dev.fns.destroyShaderModule dev.device fragMod 0
  callVoid dev.fns.destroyShaderModule dev.device vertMod 0

  match gpTargetRes, gpRgbaRes, bpRes with
  | .ok gpt, .ok gpr, .ok bp =>
    pipe := { pipe with gfxPipeTarget := gpt, gfxPipeRgba := gpr, blurPipe := bp }
  | .error e, _, _ | _, .error e, _ | _, _, .error e =>
    return ← fail e pipe

  -- Descriptor pool & sets (2 graphics sets + 2 compute blur sets)
  let dpRes ← withArena fun a => do
    let ps :=
      encDescriptorPoolSize VK_DESCRIPTOR_TYPE_STORAGE_BUFFER 4 ++
      encDescriptorPoolSize VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER 6 ++
      encDescriptorPoolSize VK_DESCRIPTOR_TYPE_STORAGE_IMAGE 4
    let psPtr ← a.write ps
    let ci ← a.write (encDescriptorPoolCreateInfo 0 4 3 psPtr)
    let out ← a.alloc 8
    let r ← callRes dev.fns.createDescriptorPool dev.device ci.toUInt64 0 out.toUInt64
    if r != VK_SUCCESS then return Except.error s!"vkCreateDescriptorPool failed ({r})"
    return Except.ok (← readU64Ptr out)
  match dpRes with
  | .error e => return ← fail e pipe
  | .ok dp => pipe := { pipe with descPool := dp }

  let setsRes ← withArena fun a => do
    let layouts := pushU64 (pushU64 (pushU64 (pushU64 (ByteArray.emptyWithCapacity 32)
      pipe.gfxSetLayout) pipe.gfxSetLayout) pipe.blurSetLayout) pipe.blurSetLayout
    let lp ← a.write layouts
    let ai ← a.write (encDescriptorSetAllocateInfo pipe.descPool 4 lp)
    let out ← a.alloc 32
    let r ← callRes dev.fns.allocateDescriptorSets dev.device ai.toUInt64 out.toUInt64
    if r != VK_SUCCESS then return Except.error s!"vkAllocateDescriptorSets failed ({r})"
    let raw ← LeanUI.FFI.memRead out 32
    return Except.ok (getU64 raw 0, getU64 raw 8, getU64 raw 16, getU64 raw 24)
  match setsRes with
  | .error e => return ← fail e pipe
  | .ok (g0, g1, b01, b10) =>
    pipe := { pipe with gfxDescSets := #[g0, g1], blurDescSet01 := b01, blurDescSet10 := b10 }

  -- Dynamic SSBO rings (1 MiB instance SSBOs, 64 KiB clip SSBOs)
  let mut iBufs : Array VkGpuBuffer := #[]
  let mut cBufs : Array VkGpuBuffer := #[]
  for _ in [:2] do
    match ← createGpuBuffer dev (1024 * 1024) VK_BUFFER_USAGE_STORAGE_BUFFER_BIT
        (VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT ||| VK_MEMORY_PROPERTY_HOST_COHERENT_BIT) true with
    | .error e => return ← fail e { pipe with instanceBufs := iBufs, clipBufs := cBufs }
    | .ok b => iBufs := iBufs.push b
    match ← createGpuBuffer dev (64 * 1024) VK_BUFFER_USAGE_STORAGE_BUFFER_BIT
        (VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT ||| VK_MEMORY_PROPERTY_HOST_COHERENT_BIT) true with
    | .error e => return ← fail e { pipe with instanceBufs := iBufs, clipBufs := cBufs }
    | .ok b => cBufs := cBufs.push b
  pipe := { pipe with instanceBufs := iBufs, clipBufs := cBufs }

  -- 8-layer 1024×1024 glyph atlas 2D array
  match ← createGpuImage dev 1024 1024 8 VK_FORMAT_R8G8B8A8_UNORM
      (VK_IMAGE_USAGE_TRANSFER_DST_BIT ||| VK_IMAGE_USAGE_SAMPLED_BIT) VK_IMAGE_VIEW_TYPE_2D_ARRAY with
  | .error e => return ← fail e pipe
  | .ok im => pipe := { pipe with atlasImage := im }

  -- Minimal 1×1 initial placeholder layer & blur targets (lazily grown on first layer/blur frame)
  match ← createGpuImage dev 1 1 4 VK_FORMAT_R8G8B8A8_UNORM
      (VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT ||| VK_IMAGE_USAGE_SAMPLED_BIT ||| VK_IMAGE_USAGE_TRANSFER_SRC_BIT ||| VK_IMAGE_USAGE_TRANSFER_DST_BIT)
      VK_IMAGE_VIEW_TYPE_2D_ARRAY with
  | .error e => return ← fail e pipe
  | .ok im => pipe := { pipe with layerImage := im }

  let blurUsage := VK_IMAGE_USAGE_STORAGE_BIT ||| VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT |||
    VK_IMAGE_USAGE_TRANSFER_SRC_BIT ||| VK_IMAGE_USAGE_TRANSFER_DST_BIT ||| VK_IMAGE_USAGE_SAMPLED_BIT
  match ← createGpuImage dev 1 1 1 VK_FORMAT_R8G8B8A8_UNORM blurUsage VK_IMAGE_VIEW_TYPE_2D with
  | .error e => return ← fail e pipe
  | .ok im => pipe := { pipe with blurP0 := im }
  match ← createGpuImage dev 1 1 1 VK_FORMAT_R8G8B8A8_UNORM blurUsage VK_IMAGE_VIEW_TYPE_2D with
  | .error e => return ← fail e pipe
  | .ok im => pipe := { pipe with blurP1 := im }

  updateGfxDescriptorSet dev pipe 0
  updateGfxDescriptorSet dev pipe 1
  updateBlurDescriptorSets dev pipe
  return .ok pipe

private def ensureAuxTargets (dev : VkDeviceCtx) (p : VkInstancedPipeline)
    (needLayers needBlur : Bool) (vw vh : Nat) : IO (Except String VkInstancedPipeline) := do
  let mut out := p
  let mut changed := false
  if needLayers && (out.layerImage.width != vw || out.layerImage.height != vh || out.layerAttachViews.size != 4) then
    -- Allocate replacement layer image + attachment views BEFORE destroying old ones so
    -- any error leaves `out` valid (zero double-destroy, zero partial handle leaks).
    match ← createGpuImage dev vw vh 4 VK_FORMAT_R8G8B8A8_UNORM
        (VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT ||| VK_IMAGE_USAGE_SAMPLED_BIT ||| VK_IMAGE_USAGE_TRANSFER_SRC_BIT ||| VK_IMAGE_USAGE_TRANSFER_DST_BIT)
        VK_IMAGE_VIEW_TYPE_2D_ARRAY with
    | .error e => return .error e
    | .ok im =>
      let mut views : Array UInt64 := #[]
      for layer in [:4] do
        match ← createImageView dev im.image VK_IMAGE_VIEW_TYPE_2D VK_FORMAT_R8G8B8A8_UNORM layer.toUInt32 1 with
        | .error e =>
          for v in views do
            if v != 0 then callVoid dev.fns.destroyImageView dev.device v 0
          destroyGpuImage dev im
          return .error e
        | .ok v => views := views.push v
      waitDeviceIdle dev
      for v in out.layerAttachViews do
        if v != 0 then callVoid dev.fns.destroyImageView dev.device v 0
      destroyGpuImage dev out.layerImage
      out := { out with layerImage := im, layerAttachViews := views }
      changed := true

  if needBlur && (out.blurP0.width != vw || out.blurP0.height != vh) then
    let blurUsage := VK_IMAGE_USAGE_STORAGE_BIT ||| VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT |||
      VK_IMAGE_USAGE_TRANSFER_SRC_BIT ||| VK_IMAGE_USAGE_TRANSFER_DST_BIT ||| VK_IMAGE_USAGE_SAMPLED_BIT
    match ← createGpuImage dev vw vh 1 VK_FORMAT_R8G8B8A8_UNORM blurUsage VK_IMAGE_VIEW_TYPE_2D with
    | .error e => return .error e
    | .ok p0 =>
      match ← createGpuImage dev vw vh 1 VK_FORMAT_R8G8B8A8_UNORM blurUsage VK_IMAGE_VIEW_TYPE_2D with
      | .error e =>
        destroyGpuImage dev p0
        return .error e
      | .ok p1 =>
        waitDeviceIdle dev
        destroyGpuImage dev out.blurP0
        destroyGpuImage dev out.blurP1
        out := { out with blurP0 := p0, blurP1 := p1 }
        changed := true

  if changed then
    updateGfxDescriptorSet dev out 0
    updateGfxDescriptorSet dev out 1
    updateBlurDescriptorSets dev out
  return .ok out

private def ensureSsboCapacity (dev : VkDeviceCtx) (p : VkInstancedPipeline) (slotIdx : Nat)
    (instBytes clipBytes : Nat) : IO (Except String VkInstancedPipeline) := do
  let mut out := p
  let mut changed := false
  let curI := out.instanceBufs[slotIdx]!
  if instBytes > curI.size then
    let mut nextSz := curI.size
    while nextSz < instBytes && nextSz < 16 * 1024 * 1024 do nextSz := nextSz * 2
    if nextSz < instBytes then nextSz := instBytes
    match ← createGpuBuffer dev nextSz VK_BUFFER_USAGE_STORAGE_BUFFER_BIT
        (VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT ||| VK_MEMORY_PROPERTY_HOST_COHERENT_BIT) true with
    | .error e => return .error e
    | .ok nb =>
      destroyGpuBuffer dev curI
      out := { out with instanceBufs := out.instanceBufs.set! slotIdx nb }
      changed := true

  let curC := out.clipBufs[slotIdx]!
  if clipBytes > curC.size then
    let mut nextSz := curC.size
    while nextSz < clipBytes && nextSz < 4 * 1024 * 1024 do nextSz := nextSz * 2
    if nextSz < clipBytes then nextSz := clipBytes
    match ← createGpuBuffer dev nextSz VK_BUFFER_USAGE_STORAGE_BUFFER_BIT
        (VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT ||| VK_MEMORY_PROPERTY_HOST_COHERENT_BIT) true with
    | .error e => return .error e
    | .ok nb =>
      destroyGpuBuffer dev curC
      out := { out with clipBufs := out.clipBufs.set! slotIdx nb }
      changed := true

  if changed then
    updateGfxDescriptorSet dev out slotIdx
  return .ok out

/-- Upload dirty glyph atlas rectangles (or full populated pages on first use / `resetAll` clear)
into the 8-layer `uAtlas` `VK_IMAGE_VIEW_TYPE_2D_ARRAY`. Chunks uploads across `submitAndWaitSync`
batches if total dirty data exceeds `stag.size` (4 MiB) so glyphs are never dropped. -/
private def recordAtlasSync (dev : VkDeviceCtx) (p : VkInstancedPipeline) (cb fence : UInt64)
    (stag : VkGpuBuffer) (atlas : Text.GlyphAtlasCache) (forceReset : Bool := false) :
    IO (Except String (VkInstancedPipeline × Nat)) := do
  let needReset := forceReset || !p.atlasInitialized || p.lastAtlasGen != atlas.generation
  let mut rectsToUpload : Array (Nat × Rect) := #[]
  if needReset then
    for pageIdx in [:min 8 atlas.pages.size] do
      let page := atlas.pages[pageIdx]!
      let pw := page.atlas.width
      if pw > 0 && page.rgba.size >= pw * 4 then
        let popRows := min (min page.atlas.height 1024) (page.rgba.size / (pw * 4))
        if popRows > 0 then
          rectsToUpload := rectsToUpload.push (pageIdx, ⟨0, 0, min pw 1024, popRows⟩)
  else
    rectsToUpload := atlas.gpuDirtyRects

  if !needReset && rectsToUpload.isEmpty then
    return .ok (p, 0)

  let oldLayout := if p.atlasInitialized then VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL else VK_IMAGE_LAYOUT_UNDEFINED
  let srcAccess := if p.atlasInitialized then VK_ACCESS_2_SHADER_READ_BIT else VK_ACCESS_2_NONE
  cmdTransitionImage dev cb p.atlasImage.image
    VK_PIPELINE_STAGE_2_FRAGMENT_SHADER_BIT srcAccess
    VK_PIPELINE_STAGE_2_TRANSFER_BIT VK_ACCESS_2_TRANSFER_WRITE_BIT
    oldLayout VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL 0 8

  if needReset then
    withArena fun a => do
      let clr ← a.write (encClearColorValue 0.0 0.0 0.0 0.0)
      let rng ← a.write (encSubresourceRange 0 8)
      callVoid dev.fns.cmdClearColorImage cb p.atlasImage.image VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL.toUInt64 clr.toUInt64 1 rng.toUInt64

  -- Pack dirty rects into `stag`, flushing via `submitAndWaitSync` whenever a batch fills `stag.size`.
  let mut stagOff : Nat := 0
  let mut totalBytes : Nat := 0
  let mut copyRegions := ByteArray.empty
  let mut regCount : UInt32 := 0

  let flushBatch (regs : ByteArray) (cnt : UInt32) : IO (Except String Unit) := do
    if cnt > 0 then
      withArena fun a => do
        let regPtr ← a.write regs
        let info ← a.write (encCopyBufferToImageInfo2 stag.buffer p.atlasImage.image VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL cnt regPtr)
        callVoid dev.fns.cmdCopyBufferToImage2 cb info.toUInt64
    let _ ← callRes dev.fns.endCommandBuffer cb
    let sr ← submitAndWaitSync dev cb fence
    if sr != VK_SUCCESS then return .error s!"atlas chunk upload failed ({sr})"
    let _ ← callRes dev.fns.resetCommandBuffer cb 0
    withArena fun a => do
      let bi ← a.write encCommandBufferBeginInfo
      let _ ← callRes dev.fns.beginCommandBuffer cb bi.toUInt64
    cmdTransitionImage dev cb p.atlasImage.image
      VK_PIPELINE_STAGE_2_TRANSFER_BIT VK_ACCESS_2_TRANSFER_WRITE_BIT
      VK_PIPELINE_STAGE_2_TRANSFER_BIT VK_ACCESS_2_TRANSFER_WRITE_BIT
      VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL 0 8
    return .ok ()

  for (pageIdx, rect) in rectsToUpload do
    if pageIdx >= 8 then continue
    let some page := atlas.pages[pageIdx]? | continue
    let pw := page.atlas.width
    let ph := page.atlas.height
    if pw == 0 || ph == 0 || page.rgba.size == 0 then continue
    let rx := max 0 rect.x |>.toNat
    let ry := max 0 rect.y |>.toNat
    let maxRows := page.rgba.size / (pw * 4)
    let rw := min (min pw 1024 - min (min pw 1024) rx) (max 0 rect.w).toNat
    let rh := min (min (min ph 1024) maxRows - min (min (min ph 1024) maxRows) ry) (max 0 rect.h).toNat
    if rw == 0 || rh == 0 then continue
    let rowBytes := rw * 4
    let stripMaxH := max 1 (stag.size / max 4 rowBytes)
    let mut curY := ry
    let endY := ry + rh
    while curY < endY do
      let sh := min stripMaxH (endY - curY)
      let needed := rowBytes * sh
      let alignedOff := ((stagOff + 15) / 16) * 16
      if alignedOff + needed > stag.size then
        match ← flushBatch copyRegions regCount with
        | .error e => return .error e
        | .ok () =>
          stagOff := 0
          copyRegions := ByteArray.empty
          regCount := 0
      let off := ((stagOff + 15) / 16) * 16
      LeanUI.FFI.vkCopyRect (stag.mappedPtr + off.toUSize) (stag.size - off).toUSize
        page.rgba ((curY * pw + rx) * 4).toUSize (pw * 4).toUSize rowBytes.toUSize sh.toUSize
      copyRegions := copyRegions ++ encBufferImageCopy2 off.toUInt64 pageIdx.toUInt32 rx curY rw.toUInt32 sh.toUInt32
      regCount := regCount + 1
      stagOff := off + needed
      totalBytes := totalBytes + needed
      curY := curY + sh

  if regCount > 0 then
    withArena fun a => do
      let regPtr ← a.write copyRegions
      let info ← a.write (encCopyBufferToImageInfo2 stag.buffer p.atlasImage.image VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL regCount regPtr)
      callVoid dev.fns.cmdCopyBufferToImage2 cb info.toUInt64

  cmdTransitionImage dev cb p.atlasImage.image
    VK_PIPELINE_STAGE_2_TRANSFER_BIT VK_ACCESS_2_TRANSFER_WRITE_BIT
    VK_PIPELINE_STAGE_2_FRAGMENT_SHADER_BIT VK_ACCESS_2_SHADER_READ_BIT
    VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL 0 8

  return .ok ({ p with atlasInitialized := true, lastAtlasGen := atlas.generation }, totalBytes)

/-- Record the 6-pass separable exact uint32 compute box blur (`[σ-1, σ-1, σ]`, H+V) on `blurP0`/`blurP1`.
Input MUST be in `blurP0` (`GENERAL`); output ALWAYS lands in `blurP0` (`GENERAL`). -/
private def recordComputeBoxBlur (dev : VkDeviceCtx) (p : VkInstancedPipeline) (cb : UInt64)
    (w h sigma : Nat) : IO Unit := do
  if sigma == 0 || w == 0 || h == 0 then return
  callVoid dev.fns.cmdBindPipeline cb VK_PIPELINE_BIND_POINT_COMPUTE.toUInt64 p.blurPipe
  let gx : UInt64 := ((w + 15) / 16).toUInt64
  let gy : UInt64 := ((h + 15) / 16).toUInt64
  for radius in [sigma - 1, sigma - 1, sigma] do
    if radius == 0 then continue
    -- Horizontal pass: P0 -> P1
    withArena fun a => do
      let dsPtr ← a.u64 p.blurDescSet01
      callVoid dev.fns.cmdBindDescriptorSets cb VK_PIPELINE_BIND_POINT_COMPUTE.toUInt64 p.blurPipeLayout 0 1 dsPtr.toUInt64 0 0
      let pc := pushU32 (pushU32 (pushU32 (pushU32 (ByteArray.emptyWithCapacity 16) w.toUInt32) h.toUInt32) radius.toUInt32) 1
      let pcPtr ← a.write pc
      callVoid dev.fns.cmdPushConstants cb p.blurPipeLayout VK_SHADER_STAGE_COMPUTE_BIT.toUInt64 0 16 pcPtr.toUInt64
      callVoid dev.fns.cmdDispatch cb gx gy 1
    cmdTransitionImage dev cb p.blurP1.image
      VK_PIPELINE_STAGE_2_COMPUTE_SHADER_BIT VK_ACCESS_2_SHADER_STORAGE_WRITE_BIT
      VK_PIPELINE_STAGE_2_COMPUTE_SHADER_BIT VK_ACCESS_2_SHADER_STORAGE_READ_BIT
      VK_IMAGE_LAYOUT_GENERAL VK_IMAGE_LAYOUT_GENERAL
    -- Vertical pass: P1 -> P0
    withArena fun a => do
      let dsPtr ← a.u64 p.blurDescSet10
      callVoid dev.fns.cmdBindDescriptorSets cb VK_PIPELINE_BIND_POINT_COMPUTE.toUInt64 p.blurPipeLayout 0 1 dsPtr.toUInt64 0 0
      let pc := pushU32 (pushU32 (pushU32 (pushU32 (ByteArray.emptyWithCapacity 16) w.toUInt32) h.toUInt32) radius.toUInt32) 0
      let pcPtr ← a.write pc
      callVoid dev.fns.cmdPushConstants cb p.blurPipeLayout VK_SHADER_STAGE_COMPUTE_BIT.toUInt64 0 16 pcPtr.toUInt64
      callVoid dev.fns.cmdDispatch cb gx gy 1
    cmdTransitionImage dev cb p.blurP0.image
      VK_PIPELINE_STAGE_2_COMPUTE_SHADER_BIT VK_ACCESS_2_SHADER_STORAGE_WRITE_BIT
      VK_PIPELINE_STAGE_2_COMPUTE_SHADER_BIT VK_ACCESS_2_SHADER_STORAGE_READ_BIT
      VK_IMAGE_LAYOUT_GENERAL VK_IMAGE_LAYOUT_GENERAL

private def unpackClearFloats (c : Color) : Float × Float × Float × Float :=
  let r := ((c >>> 24) &&& 0xFF).toFloat / 255.0
  let g := ((c >>> 16) &&& 0xFF).toFloat / 255.0
  let b := ((c >>> 8) &&& 0xFF).toFloat / 255.0
  let a := (c &&& 0xFF).toFloat / 255.0
  -- Clear color is stored premultiplied in RGBA8 target
  (r * a, g * a, b * a, a)

/-- Record full Phase 2 instanced rendering commands targeting `(targetImg, targetView)`:
syncs atlas (chunking via `fence` if > 4 MiB), transitions `targetImg` from `UNDEFINED` to
`COLOR_ATTACHMENT_OPTIMAL`, renders all passes, and leaves `targetImg` in `COLOR_ATTACHMENT_OPTIMAL`. -/
def recordInstancedScene (dev : VkDeviceCtx) (p : VkInstancedPipeline) (slotIdx : Nat)
    (cb fence : UInt64) (stag : VkGpuBuffer) (targetImg targetView : UInt64)
    (targetSrcStage : UInt64) (vw vh : Nat) (clearColor : Color)
    (atlas : Text.GlyphAtlasCache) (scene : Scene) (forceAtlasReset : Bool := false) :
    IO (Except String (VkInstancedPipeline × Nat × Nat × Nat)) := do
  let lowered := lowerScene vw vh scene
  let p1 ← match ← ensureAuxTargets dev p lowered.needsLayers lowered.needsBlur vw vh with
    | .error e => return .error e
    | .ok x => pure x
  let instRaw := packPrimRecords lowered.instances
  let clipRaw := packClipNodes lowered.clips
  let p2 ← match ← ensureSsboCapacity dev p1 slotIdx instRaw.size clipRaw.size with
    | .error e => return .error e
    | .ok x => pure x

  LeanUI.FFI.memWrite (p2.instanceBufs[slotIdx]!.mappedPtr) instRaw
  LeanUI.FFI.memWrite (p2.clipBufs[slotIdx]!.mappedPtr) clipRaw

  let (p3, atlasBytes) ← match ← recordAtlasSync dev p2 cb fence stag atlas forceAtlasReset with
    | .error e => return .error e
    | .ok r => pure r

  cmdTransitionImage dev cb targetImg
    targetSrcStage VK_ACCESS_2_NONE
    VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT
    VK_IMAGE_LAYOUT_UNDEFINED VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL

  let ds := p3.gfxDescSets[slotIdx]!
  let bindGfxState (pipeHandle : UInt64) (curW curH : Nat) : IO Unit :=
    withArena fun a => do
      callVoid dev.fns.cmdBindPipeline cb VK_PIPELINE_BIND_POINT_GRAPHICS.toUInt64 pipeHandle
      let dsPtr ← a.u64 ds
      callVoid dev.fns.cmdBindDescriptorSets cb VK_PIPELINE_BIND_POINT_GRAPHICS.toUInt64 p3.gfxPipeLayout 0 1 dsPtr.toUInt64 0 0
      let vp ← a.write (encViewport curW.toFloat curH.toFloat)
      callVoid dev.fns.cmdSetViewport cb 0 1 vp.toUInt64
      let pc :=
        pushF32 (pushF32 (pushF32 (pushF32 (pushF32 (pushF32 (pushF32 (pushF32 (ByteArray.emptyWithCapacity 32)
          curW.toFloat) curH.toFloat) 1024.0) 1024.0)
          p3.layerImage.width.toFloat) p3.layerImage.height.toFloat)
          p3.blurP0.width.toFloat) p3.blurP0.height.toFloat
      let pcPtr ← a.write pc
      callVoid dev.fns.cmdPushConstants cb p3.gfxPipeLayout (VK_SHADER_STAGE_VERTEX_BIT ||| VK_SHADER_STAGE_FRAGMENT_BIT).toUInt64 0 32 pcPtr.toUInt64

  let beginPass (view : UInt64) (rx ry : Int) (rw rh : Nat) (loadOp : UInt32) (cr cg cbC ca : Float) : IO Unit :=
    withArena fun a => do
      let att ← a.write (encRenderingAttachmentInfo view loadOp cr cg cbC ca)
      let ri ← a.write (encRenderingInfo rx ry rw.toUInt32 rh.toUInt32 att)
      callVoid dev.fns.cmdBeginRendering cb ri.toUInt64

  let setScissor (r : Rect) : IO Unit :=
    withArena fun a => do
      let sx := max 0 r.x
      let sy := max 0 r.y
      let sw := max 0 r.w
      let sh := max 0 r.h
      let sc ← a.write (encRect2D sx sy sw.toNat.toUInt32 sh.toNat.toUInt32)
      callVoid dev.fns.cmdSetScissor cb 0 1 sc.toUInt64

  -- Track stack of active render targets: (image, view, isBaseTarget, layerSlotOpt, clip)
  let (cr, cg, cbC, ca) := unpackClearFloats clearColor
  beginPass targetView 0 0 vw vh VK_ATTACHMENT_LOAD_OP_CLEAR cr cg cbC ca
  bindGfxState p3.gfxPipeTarget vw vh

  let mut targetStack : List (UInt64 × UInt64 × Bool × Option UInt32 × Rect) :=
    [(targetImg, targetView, true, none, ⟨0, 0, vw, vh⟩)]

  let resumeTopTarget (stk : List (UInt64 × UInt64 × Bool × Option UInt32 × Rect)) : IO Unit := do
    if let (_, v, isBase, _, cl) :: _ := stk then
      beginPass v cl.x cl.y cl.w.toNat cl.h.toNat VK_ATTACHMENT_LOAD_OP_LOAD 0.0 0.0 0.0 0.0
      bindGfxState (if isBase then p3.gfxPipeTarget else p3.gfxPipeRgba) vw vh

  for op in lowered.ops do
    match op with
    | .drawBatch first cnt sc =>
      setScissor sc
      callVoid dev.fns.cmdDraw cb 4 cnt.toUInt64 0 first.toUInt64
    | .layerPush slot clip =>
      callVoid dev.fns.cmdEndRendering cb
      cmdTransitionImage dev cb p3.layerImage.image
        VK_PIPELINE_STAGE_2_FRAGMENT_SHADER_BIT VK_ACCESS_2_SHADER_READ_BIT
        VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT
        VK_IMAGE_LAYOUT_UNDEFINED VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL slot.toUInt32 1
      let lv := p3.layerAttachViews[slot]!
      beginPass lv clip.x clip.y clip.w.toNat clip.h.toNat VK_ATTACHMENT_LOAD_OP_CLEAR 0.0 0.0 0.0 0.0
      bindGfxState p3.gfxPipeRgba vw vh
      targetStack := (p3.layerImage.image, lv, false, some slot.toUInt32, clip) :: targetStack
    | .layerPop slot clip compIdx =>
      callVoid dev.fns.cmdEndRendering cb
      cmdTransitionImage dev cb p3.layerImage.image
        VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT
        VK_PIPELINE_STAGE_2_FRAGMENT_SHADER_BIT VK_ACCESS_2_SHADER_READ_BIT
        VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL slot.toUInt32 1
      if let _ :: rest := targetStack then
        targetStack := rest
      resumeTopTarget targetStack
      setScissor clip
      callVoid dev.fns.cmdDraw cb 4 1 0 compIdx.toUInt64
    | .backdropBlur sigma =>
      if let (curImg, _, _, layerOpt, cl) :: _ := targetStack then
        let baseL := layerOpt.getD 0
        -- When blurring inside a clipped layer, restrict blit/blur to `cl` so uninitialized
        -- texels outside the cleared `layerPush` region never bleed into the blur kernel.
        let bx0 : Nat := if layerOpt.isSome then min vw (max 0 cl.x).toNat else 0
        let by0 : Nat := if layerOpt.isSome then min vh (max 0 cl.y).toNat else 0
        let bw : Nat := if layerOpt.isSome then min (vw - bx0) (max 0 cl.w).toNat else vw
        let bh : Nat := if layerOpt.isSome then min (vh - by0) (max 0 cl.h).toNat else vh
        if bw > 0 && bh > 0 then
          callVoid dev.fns.cmdEndRendering cb
          cmdTransitionImage dev cb curImg
            VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT
            VK_PIPELINE_STAGE_2_BLIT_BIT VK_ACCESS_2_TRANSFER_READ_BIT
            VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL baseL 1
          cmdTransitionImage dev cb p3.blurP0.image
            VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT VK_ACCESS_2_NONE
            VK_PIPELINE_STAGE_2_BLIT_BIT VK_ACCESS_2_TRANSFER_WRITE_BIT
            VK_IMAGE_LAYOUT_UNDEFINED VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL
          withArena fun a => do
            let reg ← a.write (encImageBlit2 bx0 by0 (bx0 + bw) (by0 + bh) 0 0 bw bh baseL 0)
            let info ← a.write (encBlitImageInfo2 curImg VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL
              p3.blurP0.image VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL 1 reg VK_FILTER_NEAREST)
            callVoid dev.fns.cmdBlitImage2 cb info.toUInt64
          cmdTransitionImage dev cb p3.blurP0.image
            VK_PIPELINE_STAGE_2_BLIT_BIT VK_ACCESS_2_TRANSFER_WRITE_BIT
            VK_PIPELINE_STAGE_2_COMPUTE_SHADER_BIT (VK_ACCESS_2_SHADER_STORAGE_READ_BIT ||| VK_ACCESS_2_SHADER_STORAGE_WRITE_BIT)
            VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL VK_IMAGE_LAYOUT_GENERAL
          cmdTransitionImage dev cb p3.blurP1.image
            VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT VK_ACCESS_2_NONE
            VK_PIPELINE_STAGE_2_COMPUTE_SHADER_BIT (VK_ACCESS_2_SHADER_STORAGE_READ_BIT ||| VK_ACCESS_2_SHADER_STORAGE_WRITE_BIT)
            VK_IMAGE_LAYOUT_UNDEFINED VK_IMAGE_LAYOUT_GENERAL
          recordComputeBoxBlur dev p3 cb bw bh sigma
          cmdTransitionImage dev cb p3.blurP0.image
            VK_PIPELINE_STAGE_2_COMPUTE_SHADER_BIT VK_ACCESS_2_SHADER_STORAGE_WRITE_BIT
            VK_PIPELINE_STAGE_2_BLIT_BIT VK_ACCESS_2_TRANSFER_READ_BIT
            VK_IMAGE_LAYOUT_GENERAL VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL
          cmdTransitionImage dev cb curImg
            VK_PIPELINE_STAGE_2_BLIT_BIT VK_ACCESS_2_TRANSFER_READ_BIT
            VK_PIPELINE_STAGE_2_BLIT_BIT VK_ACCESS_2_TRANSFER_WRITE_BIT
            VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL baseL 1
          withArena fun a => do
            let reg ← a.write (encImageBlit2 0 0 bw bh bx0 by0 (bx0 + bw) (by0 + bh) 0 baseL)
            let info ← a.write (encBlitImageInfo2 p3.blurP0.image VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL
              curImg VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL 1 reg VK_FILTER_NEAREST)
            callVoid dev.fns.cmdBlitImage2 cb info.toUInt64
          cmdTransitionImage dev cb curImg
            VK_PIPELINE_STAGE_2_BLIT_BIT VK_ACCESS_2_TRANSFER_WRITE_BIT
            VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT (VK_ACCESS_2_COLOR_ATTACHMENT_READ_BIT ||| VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT)
            VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL baseL 1
          resumeTopTarget targetStack
    | .shadow _mx _my mw mh sigma maskIdx compIdx sc =>
      callVoid dev.fns.cmdEndRendering cb
      -- Render white rounded-rect mask into blurP0 (0..mw, 0..mh); cover all prior stages (BLIT/COMPUTE/FRAGMENT)
      cmdTransitionImage dev cb p3.blurP0.image
        VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT VK_ACCESS_2_NONE
        VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT
        VK_IMAGE_LAYOUT_UNDEFINED VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL
      beginPass p3.blurP0.view 0 0 mw mh VK_ATTACHMENT_LOAD_OP_CLEAR 0.0 0.0 0.0 0.0
      bindGfxState p3.gfxPipeRgba p3.blurP0.width p3.blurP0.height
      setScissor ⟨0, 0, mw, mh⟩
      callVoid dev.fns.cmdDraw cb 4 1 0 maskIdx.toUInt64
      callVoid dev.fns.cmdEndRendering cb
      if sigma > 0 then
        cmdTransitionImage dev cb p3.blurP0.image
          VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT
          VK_PIPELINE_STAGE_2_COMPUTE_SHADER_BIT (VK_ACCESS_2_SHADER_STORAGE_READ_BIT ||| VK_ACCESS_2_SHADER_STORAGE_WRITE_BIT)
          VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL VK_IMAGE_LAYOUT_GENERAL
        cmdTransitionImage dev cb p3.blurP1.image
          VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT VK_ACCESS_2_NONE
          VK_PIPELINE_STAGE_2_COMPUTE_SHADER_BIT (VK_ACCESS_2_SHADER_STORAGE_READ_BIT ||| VK_ACCESS_2_SHADER_STORAGE_WRITE_BIT)
          VK_IMAGE_LAYOUT_UNDEFINED VK_IMAGE_LAYOUT_GENERAL
        recordComputeBoxBlur dev p3 cb mw mh sigma
        cmdTransitionImage dev cb p3.blurP0.image
          VK_PIPELINE_STAGE_2_COMPUTE_SHADER_BIT VK_ACCESS_2_SHADER_STORAGE_WRITE_BIT
          VK_PIPELINE_STAGE_2_FRAGMENT_SHADER_BIT VK_ACCESS_2_SHADER_READ_BIT
          VK_IMAGE_LAYOUT_GENERAL VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
      else
        cmdTransitionImage dev cb p3.blurP0.image
          VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT
          VK_PIPELINE_STAGE_2_FRAGMENT_SHADER_BIT VK_ACCESS_2_SHADER_READ_BIT
          VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
      resumeTopTarget targetStack
      setScissor sc
      callVoid dev.fns.cmdDraw cb 4 1 0 compIdx.toUInt64

  callVoid dev.fns.cmdEndRendering cb
  return .ok (p3, lowered.instances.size, instRaw.size, atlasBytes)

/-- Execute a Phase 2 (`vkInstanced`) swapchain frame: acquire, record instanced SDF/glyph
passes directly into the swapchain image, submit, and present. -/
def presentInstancedScene (wsi : VkWsiState) (pipe : VkInstancedPipeline)
    (vw vh : Nat) (clearColor : Color) (atlas : Text.GlyphAtlasCache) (scene : Scene)
    (dirtyOpt : Option Rect) (prePresent onPresentAborted : IO Unit) :
    IO (VkWsiState × VkInstancedPipeline × PresentOutcome × Nat × Nat × Nat) := do
  if vw == 0 || vh == 0 then
    let (st0, r) ← recreateSwapchain wsi 0 0
    return match r with
      | .ok () => (st0, pipe, .skipped, 0, 0, 0)
      | .error e => (st0, pipe, .deviceLost e, 0, 0, 0)
  let (st1, acq) ← acquireSwapchainImage wsi vw vh
  let (st2, imgIdx, slot, bundle, acqNs, recreated) ← match acq with
    | .error .needsRecreate =>
      let (stR, rRec) ← recreateSwapchain st1 vw vh
      match rRec with
      | .error e => return (stR, pipe, .deviceLost e, 0, 0, 0)
      | .ok () =>
        let (stR2, acq2) ← acquireSwapchainImage stR vw vh
        match acq2 with
        | .error e2 => return (stR2, pipe, e2, 0, 0, 0)
        | .ok tup => pure (stR2, tup.1, tup.2.1, tup.2.2.1, tup.2.2.2.1, true)
    | .error e => return (st1, pipe, e, 0, 0, 0)
    | .ok tup => pure (st1, tup.1, tup.2.1, tup.2.2.1, tup.2.2.2.1, tup.2.2.2.2)

  let dev := st2.dev
  let slotIdx := slot.val
  let cb := st2.sync.cmdBufs[slotIdx]!
  let fence := st2.sync.inFlightFences[slotIdx]!
  let stag := st2.sync.stagingBufs[slotIdx]!
  let scImg := bundle.images[imgIdx]!
  let scView := bundle.imageViews[imgIdx]!

  let tr0 ← IO.monoNanosNow
  let _ ← callRes dev.fns.resetCommandBuffer cb 0
  withArena fun a => do
    let bi ← a.write encCommandBufferBeginInfo
    let _ ← callRes dev.fns.beginCommandBuffer cb bi.toUInt64

  let recRes ← recordInstancedScene dev pipe slotIdx cb fence stag scImg scView
    VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT bundle.extentW bundle.extentH clearColor atlas scene
  match recRes with
  | .error e =>
    let _ ← callRes dev.fns.endCommandBuffer cb
    return (st2, pipe, .deviceLost e, 0, 0, 0)
  | .ok (pipe', primCount, ssboBytes, atlasBytes) =>
    cmdTransitionImage dev cb scImg
      VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT
      VK_PIPELINE_STAGE_2_NONE VK_ACCESS_2_NONE
      VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL VK_IMAGE_LAYOUT_PRESENT_SRC_KHR
    let _ ← callRes dev.fns.endCommandBuffer cb
    let tr1 ← IO.monoNanosNow

    let presentDirty := if recreated then none else dirtyOpt
    let (st3, subNs, presNs, res) ← submitAndPresentSwapchain st2 slot imgIdx bundle presentDirty prePresent
    match res with
    | .error e =>
      onPresentAborted
      return (st3, pipe', .deviceLost e, primCount, ssboBytes, atlasBytes)
    | .ok committed =>
      if !committed then
        onPresentAborted
        return (st3, pipe', .needsRecreate, primCount, ssboBytes, atlasBytes)
      return (st3, pipe', .presented ssboBytes acqNs (tr1 - tr0).toUInt64 subNs presNs, primCount, ssboBytes, atlasBytes)

/-- Offscreen headless Vulkan 1.3 readback context (no Wayland display required — runs in CI
on Lavapipe / Honeykrisp / NVIDIA for differential parity verification). -/
structure VkOffscreenReadback where
  dev : VkDeviceCtx
  pipe : VkInstancedPipeline
  sync : FrameSync
  targetImg : VkGpuImage := {}
  readbackBuf : VkGpuBuffer := {}
  width : Nat := 0
  height : Nat := 0

def destroyOffscreenReadback (ctx : VkOffscreenReadback) : IO Unit := do
  waitDeviceIdle ctx.dev
  destroyGpuBuffer ctx.dev ctx.readbackBuf
  destroyGpuImage ctx.dev ctx.targetImg
  destroyInstancedPipeline ctx.dev ctx.pipe
  destroyFrameSync ctx.dev ctx.sync
  destroyDevice ctx.dev

def createOffscreenReadback (enableValidation : Bool := false) (allowSoftwareIcd : Bool := true) :
    IO (Except String VkOffscreenReadback) := do
  match ← createDevice 0 0 false allowSoftwareIcd enableValidation with
  | .error e => return .error e
  | .ok dev =>
    match ← createFrameSync dev with
    | .error e => destroyDevice dev; return .error e
    | .ok sync =>
      match ← createInstancedPipeline dev VK_FORMAT_R8G8B8A8_UNORM with
      | .error e => destroyFrameSync dev sync; destroyDevice dev; return .error e
      | .ok pipe => return .ok { dev, pipe, sync }

private def ensureOffscreenTarget (ctx : VkOffscreenReadback) (w h : Nat) :
    IO (Except String VkOffscreenReadback) := do
  if ctx.width == w && ctx.height == h && ctx.targetImg.image != 0 then
    return .ok ctx
  let usage := VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT ||| VK_IMAGE_USAGE_TRANSFER_SRC_BIT ||| VK_IMAGE_USAGE_TRANSFER_DST_BIT
  match ← createGpuImage ctx.dev w h 1 VK_FORMAT_R8G8B8A8_UNORM usage VK_IMAGE_VIEW_TYPE_2D with
  | .error e => return .error e
  | .ok im =>
    let bytes := w * h * 4
    let rbRes ←
      match ← createGpuBuffer ctx.dev bytes VK_BUFFER_USAGE_TRANSFER_DST_BIT
          (VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT ||| VK_MEMORY_PROPERTY_HOST_CACHED_BIT) true with
      | .ok b => pure (Except.ok b)
      | .error _ =>
        createGpuBuffer ctx.dev bytes VK_BUFFER_USAGE_TRANSFER_DST_BIT
          (VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT ||| VK_MEMORY_PROPERTY_HOST_COHERENT_BIT) true
    match rbRes with
    | .error e => destroyGpuImage ctx.dev im; return .error e
    | .ok rb =>
      waitDeviceIdle ctx.dev
      destroyGpuBuffer ctx.dev ctx.readbackBuf
      destroyGpuImage ctx.dev ctx.targetImg
      return .ok { ctx with targetImg := im, readbackBuf := rb, width := w, height := h }

/-- Render a scene offscreen through Phase 2 (`vkInstanced`) and read back RGBA8 pixels. -/
def renderOffscreenInstanced (ctx : VkOffscreenReadback) (w h : Nat) (clearColor : Color)
    (atlas : Text.GlyphAtlasCache) (scene : Scene) (forceAtlasReset : Bool := false) :
    IO (Except String (VkOffscreenReadback × ByteArray)) := do
  let c1 ← match ← ensureOffscreenTarget ctx w h with
    | .error e => return .error e
    | .ok x => pure x
  let dev := c1.dev
  let cb := c1.sync.cmdBufs[0]!
  let fence := c1.sync.inFlightFences[0]!
  let stag := c1.sync.stagingBufs[0]!
  let _ ← callRes dev.fns.resetCommandBuffer cb 0
  withArena fun a => do
    let bi ← a.write encCommandBufferBeginInfo
    let _ ← callRes dev.fns.beginCommandBuffer cb bi.toUInt64
  match ← recordInstancedScene dev c1.pipe 0 cb fence stag c1.targetImg.image c1.targetImg.view
      VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT w h clearColor atlas scene forceAtlasReset with
  | .error e => return .error e
  | .ok (pipe', _, _, _) =>
    cmdTransitionImage dev cb c1.targetImg.image
      VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT
      VK_PIPELINE_STAGE_2_COPY_BIT VK_ACCESS_2_TRANSFER_READ_BIT
      VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL
    withArena fun a => do
      let reg ← a.write (encBufferImageCopy2 0 0 0 0 w.toUInt32 h.toUInt32)
      let info ← a.write (encCopyImageToBufferInfo2 c1.targetImg.image VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL c1.readbackBuf.buffer 1 reg)
      callVoid dev.fns.cmdCopyImageToBuffer2 cb info.toUInt64
    let _ ← callRes dev.fns.endCommandBuffer cb
    let sr ← submitAndWaitSync dev cb fence
    if sr != VK_SUCCESS then return .error s!"offscreen instanced submit failed ({sr})"
    withArena fun a => do
      let mr ← a.write (encMappedMemoryRange c1.readbackBuf.memory 0 VK_WHOLE_SIZE)
      let _ ← callRes dev.fns.invalidateMappedMemoryRanges dev.device 1 mr.toUInt64
    let pixels ← LeanUI.FFI.vkReadRect c1.readbackBuf.mappedPtr (w * 4).toUSize (w * 4).toUSize h.toUSize
    return .ok ({ c1 with pipe := pipe' }, pixels)

/-- Render a CPU RGBA8 framebuffer through Phase 1 (`vkPresent`) chunked upload + blit/copy
and read back RGBA8 pixels (verifies `max Δ = 0` bit-exact parity). -/
def renderOffscreenPresent (ctx : VkOffscreenReadback) (w h : Nat) (cpuRgba : ByteArray) :
    IO (Except String (VkOffscreenReadback × ByteArray)) := do
  let c1 ← match ← ensureOffscreenTarget ctx w h with
    | .error e => return .error e
    | .ok x => pure x
  let dev := c1.dev
  let cb := c1.sync.cmdBufs[0]!
  let fence := c1.sync.inFlightFences[0]!
  let stag := c1.sync.stagingBufs[0]!
  let rowBytes := w * 4
  let stripMaxH := max 1 (stag.size / max 4 rowBytes)
  let mut curY := 0
  let mut layout := VK_IMAGE_LAYOUT_UNDEFINED
  while curY < h do
    let sh := min stripMaxH (h - curY)
    LeanUI.FFI.vkCopyRect stag.mappedPtr stag.size.toUSize cpuRgba
      (curY * rowBytes).toUSize rowBytes.toUSize rowBytes.toUSize sh.toUSize
    let _ ← callRes dev.fns.resetCommandBuffer cb 0
    withArena fun a => do
      let bi ← a.write encCommandBufferBeginInfo
      let _ ← callRes dev.fns.beginCommandBuffer cb bi.toUInt64
      cmdTransitionImage dev cb c1.targetImg.image
        VK_PIPELINE_STAGE_2_TRANSFER_BIT VK_ACCESS_2_TRANSFER_WRITE_BIT
        VK_PIPELINE_STAGE_2_COPY_BIT VK_ACCESS_2_TRANSFER_WRITE_BIT
        layout VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL
      let reg ← a.write (encBufferImageCopy2 0 0 0 curY w.toUInt32 sh.toUInt32)
      let cpy ← a.write (encCopyBufferToImageInfo2 stag.buffer c1.targetImg.image VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL 1 reg)
      callVoid dev.fns.cmdCopyBufferToImage2 cb cpy.toUInt64
      let _ ← callRes dev.fns.endCommandBuffer cb
    let sr ← submitAndWaitSync dev cb fence
    if sr != VK_SUCCESS then return .error s!"offscreen present chunk failed ({sr})"
    layout := VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL
    curY := curY + sh

  let _ ← callRes dev.fns.resetCommandBuffer cb 0
  withArena fun a => do
    let bi ← a.write encCommandBufferBeginInfo
    let _ ← callRes dev.fns.beginCommandBuffer cb bi.toUInt64
    cmdTransitionImage dev cb c1.targetImg.image
      VK_PIPELINE_STAGE_2_COPY_BIT VK_ACCESS_2_TRANSFER_WRITE_BIT
      VK_PIPELINE_STAGE_2_COPY_BIT VK_ACCESS_2_TRANSFER_READ_BIT
      VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL
    let reg ← a.write (encBufferImageCopy2 0 0 0 0 w.toUInt32 h.toUInt32)
    let info ← a.write (encCopyImageToBufferInfo2 c1.targetImg.image VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL c1.readbackBuf.buffer 1 reg)
    callVoid dev.fns.cmdCopyImageToBuffer2 cb info.toUInt64
    let _ ← callRes dev.fns.endCommandBuffer cb
  let sr ← submitAndWaitSync dev cb fence
  if sr != VK_SUCCESS then return .error s!"offscreen present readback failed ({sr})"
  withArena fun a => do
    let mr ← a.write (encMappedMemoryRange c1.readbackBuf.memory 0 VK_WHOLE_SIZE)
    let _ ← callRes dev.fns.invalidateMappedMemoryRanges dev.device 1 mr.toUInt64
  let pixels ← LeanUI.FFI.vkReadRect c1.readbackBuf.mappedPtr rowBytes.toUSize rowBytes.toUSize h.toUSize
  return .ok (c1, pixels)

end LeanUI.Vk
