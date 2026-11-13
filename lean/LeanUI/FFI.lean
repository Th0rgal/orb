/-!
# LeanUI.FFI — Lean 4 `@[extern]` bindings for the three C11 leaf shims (`c/lean_ui.h`)
-/
namespace LeanUI.FFI

/-- Connect to `$WAYLAND_DISPLAY`. Returns `wl_display*` as `USize` (`0` = null). -/
@[extern "lean_ui_wl_connect"]
opaque wlConnect : IO USize

/-- Poll file descriptor of `display` (`wl_display_get_fd`). -/
@[extern "lean_ui_wl_fd"]
opaque wlFd (display : USize) : IO UInt32

/-- Address of a `wl_interface` exported by `libwayland-client` (e.g. `"wl_compositor_interface"`). -/
@[extern "lean_ui_wl_core_interface"]
opaque wlCoreInterface (name : @& String) : IO USize

/-- Build a heap-resident `wl_interface` for an extension protocol from binary descriptor `desc`. -/
@[extern "lean_ui_wl_make_interface"]
opaque wlMakeInterface (desc : @& ByteArray) : IO USize

/-- Marshal a Wayland request via `wl_proxy_marshal_array_flags`. -/
@[extern "lean_ui_wl_marshal"]
opaque wlMarshal (proxy : USize) (opcode : UInt32) (iface : USize) (version : UInt32)
    (flags : UInt32) (tag : UInt64) (sig : @& String) (args : @& ByteArray)
    (blob : @& ByteArray) : IO USize

/-- Flush requests, read/dispatch non-blocking Wayland events, and return recorded event bytes. -/
@[extern "lean_ui_wl_pump"]
opaque wlPump (display : USize) : IO ByteArray

/-- Set the 64-bit user tag on an event-created `wl_proxy`. -/
@[extern "lean_ui_wl_set_tag"]
opaque wlSetTag (proxy : USize) (tag : UInt64) : IO Unit

/-- Load an `xkb_keymap` from `(fd, size)` (consuming `fd`) and initialize `xkb_state` + compose. -/
@[extern "lean_ui_xkb_keymap"]
opaque xkbKeymap (fd : UInt32) (size : UInt32) : IO USize

/-- Free an `xkb` state handle created by `xkbKeymap`. -/
@[extern "lean_ui_xkb_free"]
opaque xkbFree (state : USize) : IO Unit

/-- Update `xkb_state_update_mask` modifier masks. -/
@[extern "lean_ui_xkb_modifiers"]
opaque xkbModifiers (state : USize) (depressed : UInt32) (latched : UInt32)
    (locked : UInt32) (group : UInt32) : IO Unit

/-- Translate an evdev keycode through XKB + compose into `(keysym, mods, consumed, compose, utf8)`. -/
@[extern "lean_ui_xkb_key"]
opaque xkbKey (state : USize) (key : UInt32) : IO ByteArray

/-- Create an anonymous `memfd` of `size` bytes. -/
@[extern "lean_ui_memfd"]
opaque memfd (size : UInt32) : IO UInt32

/-- Resolve symbol `sym` from shared library `lib` via `dlopen`/`dlsym`. -/
@[extern "lean_ui_dl_sym"]
opaque dlSym (lib : @& String) (sym : @& String) : IO USize

/-- Invoke a C function pointer `fn` with 6 `UInt64` integer/pointer arguments (`48` bytes). -/
@[extern "lean_ui_call"]
opaque call (fn : USize) (args : @& ByteArray) : IO UInt64

/-- Allocate zero-filled native memory of `size` bytes (`calloc(1, size)`). -/
@[extern "lean_ui_mem_alloc"]
opaque memAlloc (size : USize) : IO USize

/-- Free native memory allocated by `memAlloc`. -/
@[extern "lean_ui_mem_free"]
opaque memFree (ptr : USize) : IO Unit

/-- Copy `bytes` into native memory at `ptr`. -/
@[extern "lean_ui_mem_write"]
opaque memWrite (ptr : USize) (bytes : @& ByteArray) : IO Unit

/-- Read `size` bytes from native memory at `ptr`. -/
@[extern "lean_ui_mem_read"]
opaque memRead (ptr : USize) (size : USize) : IO ByteArray

/-- Resolve a Fontconfig pattern (`"Inter:weight=500"`) to a FreeType + HarfBuzz face handle. -/
@[extern "lean_ui_font_open"]
opaque fontOpen (pattern : @& String) : IO USize

/-- Close a font face handle opened by `fontOpen`. -/
@[extern "lean_ui_font_close"]
opaque fontClose (face : USize) : IO Unit

/-- Query 20-byte font metrics `(ascender, descender, lineHeight, underlinePosition, underlineThickness)` at `size64`. -/
@[extern "lean_ui_font_metrics"]
opaque fontMetrics (face : USize) (size64 : UInt32) : IO ByteArray

/-- Shape UTF-8 `text` with HarfBuzz features `features` at `size64` (26.6 fractional px). -/
@[extern "lean_ui_shape"]
opaque shape (face : USize) (size64 : UInt32) (text : @& String)
    (features : @& String) : IO ByteArray

/-- Rasterize `glyph` at `size64` and quarter-pixel bin `subpx` (`0..3`). -/
@[extern "lean_ui_rasterize"]
opaque rasterize (face : USize) (size64 : UInt32) (glyph : UInt32)
    (subpx : UInt32) : IO ByteArray

end LeanUI.FFI
