import LeanUI.Defs
import LeanUI.Kernel
import LeanUI.FFI
/-!
# LeanUI.Wayland — Wayland wire-protocol marshaling, extension descriptors, and event decoding

Wraps `LeanUI.FFI` (`c/lean_ui_wayland.c`) with binary `wl_interface` descriptor builders
for `xdg-shell`, `wp-fractional-scale-v1`, `wp-viewporter`, and `zwp-text-input-v3`,
request marshaling helpers, `wlPump` binary event record decoding, XKB key translation,
IME preedit/commit/surrounding-text batching, and graceful headless fallback when
`$WAYLAND_DISPLAY` is absent or unavailable.
-/
namespace LeanUI.Wayland

/-- Little-endian binary encoding helpers for Wayland descriptors and request blobs. -/
@[inline] def pushU32LE (b : ByteArray) (v : UInt32) : ByteArray :=
  b.push v.toUInt8
   |>.push (v >>> 8).toUInt8
   |>.push (v >>> 16).toUInt8
   |>.push (v >>> 24).toUInt8

@[inline] def pushU64LE (b : ByteArray) (v : UInt64) : ByteArray :=
  pushU32LE (pushU32LE b v.toUInt32) (v >>> 32).toUInt32

@[inline] def pushCString (b : ByteArray) (s : String) : ByteArray :=
  (b ++ s.toUTF8).push 0

@[inline] def readU32LE (b : ByteArray) (off : Nat) : UInt32 :=
  if off + 4 ≤ b.size then
    let b0 := b.get! off |>.toUInt32
    let b1 := b.get! (off + 1) |>.toUInt32
    let b2 := b.get! (off + 2) |>.toUInt32
    let b3 := b.get! (off + 3) |>.toUInt32
    b0 ||| (b1 <<< 8) ||| (b2 <<< 16) ||| (b3 <<< 24)
  else 0

@[inline] def readU64LE (b : ByteArray) (off : Nat) : UInt64 :=
  if off + 8 ≤ b.size then
    let lo := (readU32LE b off).toUInt64
    let hi := (readU32LE b (off + 4)).toUInt64
    lo ||| (hi <<< 32)
  else 0

@[inline] def readI32LE (b : ByteArray) (off : Nat) : Int :=
  let u := readU32LE b off
  if u ≥ 0x80000000 then (u.toNat : Int) - 0x100000000 else (u.toNat : Int)

@[inline] def readI64LE (b : ByteArray) (off : Nat) : Int :=
  let u := readU64LE b off
  if u ≥ 0x8000000000000000 then (u.toNat : Int) - 0x10000000000000000 else (u.toNat : Int)

/-- Convert a Wayland `wl_fixed_t` (`24.8` signed fixed-point) into `LeanUI` `Sub` (`1/64` px). -/
@[inline] def wlFixedToSub (fixed256 : Int) : Int :=
  fixed256 / 4

/-- One Wayland message signature specification (`name`, `signature`, and per-arg `wl_interface*`). -/
structure WlMsgSpec where
  name : String
  signature : String
  types : Array USize := #[]
  deriving Repr

/-- Full binary `wl_interface` specification consumed by `LeanUI.FFI.wlMakeInterface`. -/
structure WlInterfaceSpec where
  name : String
  version : UInt32
  methods : Array WlMsgSpec := #[]
  events : Array WlMsgSpec := #[]
  deriving Repr

private def countSigArgs (sig : String) : Nat :=
  sig.foldl (fun acc c => if c != '?' && (c < '0' || c > '9') then acc + 1 else acc) 0

private def encodeMsgSpec (b : ByteArray) (m : WlMsgSpec) : ByteArray :=
  let b := pushCString (pushCString b m.name) m.signature
  let n := countSigArgs m.signature
  Id.run do
    let mut out := b
    for i in [0:n] do
      let ptr := if h : i < m.types.size then m.types[i] else 0
      out := pushU64LE out ptr.toUInt64
    return out

/-- Encode a `WlInterfaceSpec` into the exact binary format expected by `lean_ui_wl_make_interface`. -/
def encodeInterfaceDesc (spec : WlInterfaceSpec) : ByteArray :=
  let b := pushCString ByteArray.empty spec.name
  let b := pushU32LE (pushU32LE (pushU32LE b spec.version) spec.methods.size.toUInt32) spec.events.size.toUInt32
  let b := spec.methods.foldl encodeMsgSpec b
  spec.events.foldl encodeMsgSpec b

/-- Build a heap-resident `wl_interface*` via `LeanUI.FFI.wlMakeInterface`. -/
def makeInterface (spec : WlInterfaceSpec) : IO USize :=
  FFI.wlMakeInterface (encodeInterfaceDesc spec)

/-- Marshaled request argument value before packing into `(sig, args, blob)`. -/
inductive WlReqArg where
  | int (v : Int)
  | uint (v : UInt32)
  | fixed (v : Int)
  | fd (fd : UInt32)
  | obj (proxy : USize)
  | newId
  | str (s : Option String)
  | bytes (b : Option ByteArray)
  deriving Inhabited

/-- Pack a list of `WlReqArg` into `(sig, args, blob)` and invoke `FFI.wlMarshal`. -/
def marshalRequest (proxy : USize) (opcode : UInt32) (iface : USize) (version : UInt32)
    (flags : UInt32) (tag : UInt64) (reqArgs : Array WlReqArg) : IO USize := do
  let mut sig := ""
  let mut args := ByteArray.empty
  let mut blob := ByteArray.empty
  for a in reqArgs do
    match a with
    | .int v =>
      sig := sig.push 'i'
      let u : UInt64 := if v < 0 then (0x10000000000000000 - ((-v).toNat)).toUInt64 else v.toNat.toUInt64
      args := pushU64LE args u
    | .uint v =>
      sig := sig.push 'u'
      args := pushU64LE args v.toUInt64
    | .fixed v =>
      sig := sig.push 'f'
      let u : UInt64 := if v < 0 then (0x10000000000000000 - ((-v).toNat)).toUInt64 else v.toNat.toUInt64
      args := pushU64LE args u
    | .fd h =>
      sig := sig.push 'h'
      args := pushU64LE args h.toUInt64
    | .obj p =>
      sig := sig.push 'o'
      args := pushU64LE args p.toUInt64
    | .newId =>
      sig := sig.push 'n'
      args := pushU64LE args 0
    | .str none =>
      sig := sig.push 's'
      args := pushU64LE args 0xffffffff
    | .str (some s) =>
      sig := sig.push 's'
      let off := blob.size.toUInt64
      blob := pushCString blob s
      args := pushU64LE args off
    | .bytes none =>
      sig := sig.push 'a'
      args := pushU64LE args 0xffffffff
    | .bytes (some bs) =>
      sig := sig.push 'a'
      let off := blob.size.toUInt64
      blob := pushU32LE blob bs.size.toUInt32 ++ bs
      args := pushU64LE args off
  FFI.wlMarshal proxy opcode iface version flags tag sig args blob

/-- Decoded argument from a `wlPump` event record. -/
inductive WlWireArg where
  | int (v : Int)
  | uint (v : UInt32)
  | fixed (v : Int)
  | fd (fd : UInt32)
  | obj (proxy : USize)
  | newId (proxy : USize)
  | str (s : Option String)
  | array (bytes : ByteArray)
  deriving Inhabited

/-- One raw Wayland event record decoded from `wlPump`. -/
structure WlWireEvent where
  tag : UInt64
  proxy : USize
  opcode : UInt32
  args : Array WlWireArg
  deriving Inhabited

/-- Decode all `WlWireEvent` records from a `ByteArray` returned by `FFI.wlPump`. -/
def decodeWireEvents (buf : ByteArray) : Array WlWireEvent := Id.run do
  let mut out : Array WlWireEvent := #[]
  let mut pos : Nat := 0
  while pos + 24 ≤ buf.size do
    let tag := readU64LE buf pos
    let proxy := (readU64LE buf (pos + 8)).toUSize
    let opcode := readU32LE buf (pos + 16)
    let nArgs := (readU32LE buf (pos + 20)).toNat
    pos := pos + 24
    let mut args : Array WlWireArg := #[]
    for _ in [0:nArgs] do
      if pos < buf.size then
        let kind := Char.ofNat (buf.get! pos).toNat
        pos := pos + 1
        if kind == 'i' || kind == 'f' then
          if pos + 8 ≤ buf.size then
            let v := readI64LE buf pos
            pos := pos + 8
            args := args.push (if kind == 'f' then .fixed v else .int v)
          else pos := buf.size
        else if kind == 'u' then
          if pos + 8 ≤ buf.size then
            let v := (readU64LE buf pos).toUInt32
            pos := pos + 8
            args := args.push (.uint v)
          else pos := buf.size
        else if kind == 'h' then
          if pos + 8 ≤ buf.size then
            let v := (readU64LE buf pos).toUInt32
            pos := pos + 8
            args := args.push (.fd v)
          else pos := buf.size
        else if kind == 'o' || kind == 'n' then
          if pos + 8 ≤ buf.size then
            let p := (readU64LE buf pos).toUSize
            pos := pos + 8
            args := args.push (if kind == 'n' then .newId p else .obj p)
          else pos := buf.size
        else if kind == 's' then
          if pos + 4 ≤ buf.size then
            let len := readU32LE buf pos
            pos := pos + 4
            if len == 0xffffffff then
              args := args.push (.str none)
            else
              let n := len.toNat
              if pos + n ≤ buf.size then
                let slice := buf.extract pos (pos + n)
                pos := pos + n
                args := args.push (.str (some (String.fromUTF8! slice)))
              else pos := buf.size
          else pos := buf.size
        else if kind == 'a' then
          if pos + 4 ≤ buf.size then
            let n := (readU32LE buf pos).toNat
            pos := pos + 4
            if pos + n ≤ buf.size then
              let slice := buf.extract pos (pos + n)
              pos := pos + n
              args := args.push (.array slice)
            else pos := buf.size
          else pos := buf.size
        else
          pos := buf.size
    out := out.push { tag, proxy, opcode, args }
  return out

/-- Proxy tags used to demultiplex `WlWireEvent` records. -/
def tagRegistry : UInt64 := 1
def tagSurface : UInt64 := 2
def tagXdgWmBase : UInt64 := 3
def tagXdgSurface : UInt64 := 4
def tagXdgToplevel : UInt64 := 5
def tagSeat : UInt64 := 6
def tagPointer : UInt64 := 7
def tagKeyboard : UInt64 := 8
def tagFractionalScale : UInt64 := 9
def tagTextInput : UInt64 := 10
def tagDataDevice : UInt64 := 11
def tagDataOffer : UInt64 := 12
def tagFrameCallback : UInt64 := 13

/-- Registered core + extension `wl_interface*` pointers for a Wayland session. -/
structure ProtocolInterfaces where
  wlRegistry : USize := 0
  wlCompositor : USize := 0
  wlSurface : USize := 0
  wlShm : USize := 0
  wlSeat : USize := 0
  wlPointer : USize := 0
  wlKeyboard : USize := 0
  wlCallback : USize := 0
  xdgWmBase : USize := 0
  xdgSurface : USize := 0
  xdgToplevel : USize := 0
  wpFractionalScaleManager : USize := 0
  wpFractionalScale : USize := 0
  wpViewporter : USize := 0
  wpViewport : USize := 0
  zwpTextInputManager : USize := 0
  zwpTextInput : USize := 0
  deriving Repr, Inhabited

/-- Build extension `wl_interface*` descriptors (`xdg-shell`, `wp-fractional-scale-v1`,
`wp-viewporter`, `zwp-text-input-v3`) and resolve core `libwayland-client` interfaces. -/
def initProtocolInterfaces (loadCore : Bool := true) : IO ProtocolInterfaces := do
  let core (sym : String) : IO USize :=
    if loadCore then
      try FFI.wlCoreInterface sym catch _ => pure 0
    else pure 0
  let wlRegistry ← core "wl_registry_interface"
  let wlCompositor ← core "wl_compositor_interface"
  let wlSurface ← core "wl_surface_interface"
  let wlShm ← core "wl_shm_interface"
  let wlSeat ← core "wl_seat_interface"
  let wlPointer ← core "wl_pointer_interface"
  let wlKeyboard ← core "wl_keyboard_interface"
  let wlCallback ← core "wl_callback_interface"
  let xdgToplevel ← makeInterface {
    name := "xdg_toplevel"
    version := 4
    methods := #[
      { name := "destroy", signature := "" },
      { name := "set_parent", signature := "?o", types := #[0] },
      { name := "set_title", signature := "s" },
      { name := "set_app_id", signature := "s" }
    ]
    events := #[
      { name := "configure", signature := "iia" },
      { name := "close", signature := "" },
      { name := "configure_bounds", signature := "ii" },
      { name := "wm_capabilities", signature := "a" }
    ]
  }
  let xdgSurface ← makeInterface {
    name := "xdg_surface"
    version := 4
    methods := #[
      { name := "destroy", signature := "" },
      { name := "get_toplevel", signature := "n", types := #[xdgToplevel] },
      { name := "get_popup", signature := "n?oo", types := #[0, 0, 0] },
      { name := "set_window_geometry", signature := "iiii" },
      { name := "ack_configure", signature := "u" }
    ]
    events := #[
      { name := "configure", signature := "u" }
    ]
  }
  let xdgWmBase ← makeInterface {
    name := "xdg_wm_base"
    version := 4
    methods := #[
      { name := "destroy", signature := "" },
      { name := "create_positioner", signature := "n", types := #[0] },
      { name := "get_xdg_surface", signature := "no", types := #[xdgSurface, wlSurface] },
      { name := "pong", signature := "u" }
    ]
    events := #[
      { name := "ping", signature := "u" }
    ]
  }
  let wpFractionalScale ← makeInterface {
    name := "wp_fractional_scale_v1"
    version := 1
    methods := #[
      { name := "destroy", signature := "" }
    ]
    events := #[
      { name := "preferred_scale", signature := "u" }
    ]
  }
  let wpFractionalScaleManager ← makeInterface {
    name := "wp_fractional_scale_manager_v1"
    version := 1
    methods := #[
      { name := "destroy", signature := "" },
      { name := "get_fractional_scale", signature := "no", types := #[wpFractionalScale, wlSurface] }
    ]
    events := #[]
  }
  let wpViewport ← makeInterface {
    name := "wp_viewport"
    version := 1
    methods := #[
      { name := "destroy", signature := "" },
      { name := "set_source", signature := "ffff" },
      { name := "set_destination", signature := "ii" }
    ]
    events := #[]
  }
  let wpViewporter ← makeInterface {
    name := "wp_viewporter"
    version := 1
    methods := #[
      { name := "destroy", signature := "" },
      { name := "get_viewport", signature := "no", types := #[wpViewport, wlSurface] }
    ]
    events := #[]
  }
  let zwpTextInput ← makeInterface {
    name := "zwp_text_input_v3"
    version := 1
    methods := #[
      { name := "destroy", signature := "" },
      { name := "enable", signature := "" },
      { name := "disable", signature := "" },
      { name := "set_surrounding_text", signature := "sii" },
      { name := "set_text_change_cause", signature := "u" },
      { name := "set_content_type", signature := "uu" },
      { name := "set_cursor_rectangle", signature := "iiii" },
      { name := "commit", signature := "" }
    ]
    events := #[
      { name := "enter", signature := "o", types := #[wlSurface] },
      { name := "leave", signature := "o", types := #[wlSurface] },
      { name := "preedit_string", signature := "?sii" },
      { name := "commit_string", signature := "?s" },
      { name := "delete_surrounding_text", signature := "uu" },
      { name := "done", signature := "u" }
    ]
  }
  let zwpTextInputManager ← makeInterface {
    name := "zwp_text_input_manager_v3"
    version := 1
    methods := #[
      { name := "destroy", signature := "" },
      { name := "get_text_input", signature := "no", types := #[zwpTextInput, wlSeat] }
    ]
    events := #[]
  }
  return {
    wlRegistry, wlCompositor, wlSurface, wlShm, wlSeat, wlPointer, wlKeyboard, wlCallback,
    xdgWmBase, xdgSurface, xdgToplevel, wpFractionalScaleManager, wpFractionalScale,
    wpViewporter, wpViewport, zwpTextInputManager, zwpTextInput
  }

/-- Decoded XKB key translation packet from `FFI.xkbKey` (`13 + utf8_len` bytes). -/
structure XkbKeyPacket where
  keysym : UInt32
  mods : UInt32
  consumed : UInt32
  composeStatus : UInt8
  utf8 : String
  deriving Repr, Inhabited

/-- Decode the byte array returned by `FFI.xkbKey`. -/
def decodeXkbKeyPacket (b : ByteArray) : XkbKeyPacket :=
  if b.size < 13 then
    { keysym := 0, mods := 0, consumed := 0, composeStatus := 0, utf8 := "" }
  else
    let keysym := readU32LE b 0
    let mods := readU32LE b 4
    let consumed := readU32LE b 8
    let composeStatus := b.get! 12
    let utf8Bytes := b.extract 13 b.size
    let trimmed :=
      if utf8Bytes.size > 0 && utf8Bytes.get! (utf8Bytes.size - 1) == 0 then
        utf8Bytes.extract 0 (utf8Bytes.size - 1)
      else utf8Bytes
    { keysym, mods, consumed, composeStatus, utf8 := String.fromUTF8! trimmed }

/-- Pending `zwp_text_input_v3` state accumulated until `done` arrives. -/
structure ImePending where
  delBefore : Nat := 0
  delAfter : Nat := 0
  commit : String := ""
  preedit : String := ""
  cursorBegin : Int := 0
  cursorEnd : Int := 0
  deriving Repr, Inhabited

/-- Mutable state of a Wayland client session (or headless fallback). -/
structure WaylandClient where
  headless : Bool := true
  display : USize := 0
  ifaces : ProtocolInterfaces := {}
  xkbState : USize := 0
  pointerXSub : Int := 0
  pointerYSub : Int := 0
  pendingW : Nat := 1470
  pendingH : Nat := 923
  scale120 : Nat := 120
  ime : ImePending := {}
  deriving Repr, Inhabited

/-- Compute the device buffer dimensions `(bufW, bufH)` using `Kernel.bufferSize`. -/
@[inline] def WaylandClient.deviceBufferSize (c : WaylandClient) : Nat × Nat :=
  (bufferSize c.scale120 c.pendingW, bufferSize c.scale120 c.pendingH)

/-- Compute the logical window size in `Sub` (`1/64` px) using `Kernel.resizeSub`. -/
@[inline] def WaylandClient.logicalSubSize (c : WaylandClient) : Nat × Nat :=
  (resizeSub c.pendingW, resizeSub c.pendingH)

/-- Connect to `$WAYLAND_DISPLAY` if available; otherwise fall back cleanly to headless mode. -/
def connectOrHeadless (forceHeadless : Bool := false) (initW : Nat := 1470) (initH : Nat := 923)
    (initScale120 : Nat := 120) : IO WaylandClient := do
  let ifaces ← initProtocolInterfaces (!forceHeadless)
  if forceHeadless then
    return { headless := true, display := 0, ifaces, pendingW := initW, pendingH := initH, scale120 := initScale120 }
  try
    let disp ← FFI.wlConnect
    if disp == 0 then
      return { headless := true, display := 0, ifaces, pendingW := initW, pendingH := initH, scale120 := initScale120 }
    return { headless := false, display := disp, ifaces, pendingW := initW, pendingH := initH, scale120 := initScale120 }
  catch _ =>
    return { headless := true, display := 0, ifaces, pendingW := initW, pendingH := initH, scale120 := initScale120 }

@[inline] private def WlWireEvent.arg? (ev : WlWireEvent) (i : Nat) : Option WlWireArg :=
  ev.args[i]?

/-- Translate a single `WlWireEvent` into `LeanUI.Event` values and update `WaylandClient`. -/
def stepWireEvent (c : WaylandClient) (ev : WlWireEvent) : IO (WaylandClient × Array Event) := do
  let mut st := c
  let mut out : Array Event := #[]
  if ev.tag == tagXdgSurface && ev.opcode == 0 then
    if let some (WlWireArg.uint serial) := ev.arg? 0 then
      if !st.headless && ev.proxy != 0 then
        let _ ← marshalRequest ev.proxy 4 0 4 0 0 #[.uint serial]
      out := out.push (.resize st.pendingW st.pendingH)
  else if ev.tag == tagXdgToplevel then
    if ev.opcode == 0 then
      if let (some (WlWireArg.int w), some (WlWireArg.int h)) := (ev.arg? 0, ev.arg? 1) then
        let nw := if w > 0 then w.toNat else st.pendingW
        let nh := if h > 0 then h.toNat else st.pendingH
        st := { st with pendingW := nw, pendingH := nh }
    else if ev.opcode == 1 then
      out := out.push .closeRequested
  else if ev.tag == tagFractionalScale && ev.opcode == 0 then
    if let some (WlWireArg.uint s120) := ev.arg? 0 then
      let sc := if s120 > 0 then s120.toNat else 120
      st := { st with scale120 := sc }
      out := out.push (.scale sc)
  else if ev.tag == tagPointer then
    if ev.opcode == 0 then
      if let (some (WlWireArg.fixed sx), some (WlWireArg.fixed sy)) := (ev.arg? 2, ev.arg? 3) then
        let px := wlFixedToSub sx
        let py := wlFixedToSub sy
        st := { st with pointerXSub := px, pointerYSub := py }
        out := out.push (.pointerMove px py)
    else if ev.opcode == 1 then
      out := out.push .pointerLeave
    else if ev.opcode == 2 then
      if let (some (WlWireArg.uint ms), some (WlWireArg.fixed sx), some (WlWireArg.fixed sy)) := (ev.arg? 0, ev.arg? 1, ev.arg? 2) then
        let px := wlFixedToSub sx
        let py := wlFixedToSub sy
        st := { st with pointerXSub := px, pointerYSub := py }
        out := out.push (.time ms)
        out := out.push (.pointerMove px py)
    else if ev.opcode == 3 then
      if let (some (WlWireArg.uint ms), some (WlWireArg.uint btn), some (WlWireArg.uint bst)) := (ev.arg? 1, ev.arg? 2, ev.arg? 3) then
        out := out.push (.time ms)
        out := out.push (.pointerButton st.pointerXSub st.pointerYSub btn.toNat (bst != 0))
    else if ev.opcode == 4 then
      if let (some (WlWireArg.uint ms), some (WlWireArg.uint axis), some (WlWireArg.fixed v)) := (ev.arg? 0, ev.arg? 1, ev.arg? 2) then
        let d := wlFixedToSub v
        let (dx, dy) := if axis == 0 then (0, d) else (d, 0)
        out := out.push (.time ms)
        out := out.push (.scroll st.pointerXSub st.pointerYSub dx dy)
  else if ev.tag == tagKeyboard then
    if ev.opcode == 0 then
      if let (some (WlWireArg.fd fd), some (WlWireArg.uint sz)) := (ev.arg? 1, ev.arg? 2) then
        if st.xkbState != 0 then
          FFI.xkbFree st.xkbState
        let xkb ← try FFI.xkbKeymap fd sz catch _ => pure 0
        st := { st with xkbState := xkb }
    else if ev.opcode == 1 then
      out := out.push (.windowFocus true)
    else if ev.opcode == 2 then
      out := out.push (.windowFocus false)
    else if ev.opcode == 3 then
      if let (some (WlWireArg.uint ms), some (WlWireArg.uint key), some (WlWireArg.uint kst)) := (ev.arg? 1, ev.arg? 2, ev.arg? 3) then
        out := out.push (.time ms)
        let keyState : KeyState :=
          if kst == 0 then .released else if kst == 2 then .repeated else .pressed
        if st.xkbState != 0 && (keyState == .pressed || keyState == .repeated) then
          let raw ← try FFI.xkbKey st.xkbState key catch _ => pure ByteArray.empty
          let pkt := decodeXkbKeyPacket raw
          out := out.push (.key pkt.keysym pkt.mods keyState)
          if !pkt.utf8.isEmpty && pkt.composeStatus != 1 then
            out := out.push (.text pkt.utf8)
        else
          out := out.push (.key key 0 keyState)
    else if ev.opcode == 4 then
      if let (some (WlWireArg.uint dep), some (WlWireArg.uint lat), some (WlWireArg.uint lck), some (WlWireArg.uint grp)) :=
          (ev.arg? 1, ev.arg? 2, ev.arg? 3, ev.arg? 4) then
        if st.xkbState != 0 then
          FFI.xkbModifiers st.xkbState dep lat lck grp
  else if ev.tag == tagTextInput then
    if ev.opcode == 2 then
      let txt := match ev.arg? 0 with | some (WlWireArg.str (some s)) => s | _ => ""
      let cb := match ev.arg? 1 with | some (WlWireArg.int v) => v | _ => 0
      let ce := match ev.arg? 2 with | some (WlWireArg.int v) => v | _ => 0
      st := { st with ime := { st.ime with preedit := txt, cursorBegin := cb, cursorEnd := ce } }
    else if ev.opcode == 3 then
      let txt := match ev.arg? 0 with | some (WlWireArg.str (some s)) => s | _ => ""
      st := { st with ime := { st.ime with commit := txt } }
    else if ev.opcode == 4 then
      let db := match ev.arg? 0 with | some (WlWireArg.uint v) => v.toNat | _ => 0
      let da := match ev.arg? 1 with | some (WlWireArg.uint v) => v.toNat | _ => 0
      st := { st with ime := { st.ime with delBefore := db, delAfter := da } }
    else if ev.opcode == 5 then
      let b := st.ime
      out := out.push (.imeBatch b.delBefore b.delAfter b.commit b.preedit b.cursorBegin b.cursorEnd)
      st := { st with ime := {} }
  return (st, out)

/-- Pump pending Wayland events (non-blocking) and translate them into `Array Event`. -/
def pumpEvents (c : WaylandClient) : IO (WaylandClient × Array Event) := do
  if c.headless || c.display == 0 then
    return (c, #[])
  let raw ← FFI.wlPump c.display
  let wireEvs := decodeWireEvents raw
  let mut st := c
  let mut events : Array Event := #[]
  for wev in wireEvs do
    let (st', evs) ← stepWireEvent st wev
    st := st'
    events := events ++ evs
  return (st, events)

end LeanUI.Wayland
