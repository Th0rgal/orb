/* lean_ui.h — frozen C ABI between LeanUI (Lean 4) and its three C11 leaf shims.
 *
 * Rule: the shims hold no protocol, layout or rendering logic. They are call bridges.
 * Lean builds every request (Wayland argument arrays, Vulkan structs, shaping requests)
 * as bytes and decodes every reply from bytes. Each .c file stays <= 220 LOC and builds
 * with -std=gnu11 -O2 -Wall -Wextra -Werror.
 *
 * Conventions
 *  - All functions run in IO (trailing lean_obj_arg world, lean_io_result return).
 *  - `b_lean_obj_arg` = borrowed; the shim never retains a Lean object past the call.
 *  - Native pointers cross as size_t (Lean USize). 0 is null.
 *  - Byte layouts are little-endian, native alignment for x86_64 / aarch64 LP64.
 *  - Failures return an IO error; nothing is partially applied.
 */
#ifndef LEAN_UI_H
#define LEAN_UI_H
#include <lean/lean.h>

/* ---- lean_ui_wayland.c : libwayland-client + libxkbcommon ------------------------ */
/* Threading: exactly one thread calls these. The shim reads with
 * wl_display_prepare_read / read_events so it coexists with Mesa WSI's private queue. */

/* Connect to $WAYLAND_DISPLAY. Returns wl_display* . */
lean_obj_res lean_ui_wl_connect(lean_obj_arg w);
/* Poll fd of the display (for the lean-sys reactor). Returns UInt32. */
lean_obj_res lean_ui_wl_fd(size_t display, lean_obj_arg w);
/* Address of a wl_interface exported by libwayland (e.g. "wl_compositor_interface"). */
lean_obj_res lean_ui_wl_core_interface(b_lean_obj_arg name, lean_obj_arg w);
/* Build a wl_interface for an extension protocol. `desc` is
 *   name\0 version:u32 nMethods:u32 nEvents:u32 then per message:
 *   name\0 signature\0 then one u64 per argument in the signature: the wl_interface* of an
 *   object / new_id argument (from this function or lean_ui_wl_core_interface), else 0.
 * A new_id argument of an EVENT must name its interface: libwayland creates that proxy
 * itself and dereferences the type. The result lives for the process lifetime. */
lean_obj_res lean_ui_wl_make_interface(b_lean_obj_arg desc, lean_obj_arg w);
/* wl_proxy_marshal_array_flags. `sig` holds one type letter per argument
 * ('i','u','f','h','o','n','s','a'); `args` is nArgs * 8 bytes: scalars sign-extended
 * ('f' is wl_fixed), objects as proxy pointers, strings/arrays as a u32 offset into `blob`
 * (0xffffffff = NULL; a string is NUL-terminated, an array is u32 length + bytes).
 * Everything is serialised before the call returns; no Lean buffer is retained.
 * fds ('h') are duplicated by libwayland: the caller keeps and closes its own copy.
 * When iface != 0 the request creates a proxy: it is tagged with `tag` (user data), gets
 * the event recorder, and is returned. flags bit0 = WL_MARSHAL_FLAG_DESTROY. */
lean_obj_res lean_ui_wl_marshal(size_t proxy, uint32_t opcode, size_t iface, uint32_t version,
                                uint32_t flags, uint64_t tag, b_lean_obj_arg sig,
                                b_lean_obj_arg args, b_lean_obj_arg blob, lean_obj_arg w);
/* Flush requests, read and dispatch pending events without blocking, then return and clear
 * the recorded event bytes. The recorder only appends to a C buffer; it never calls Lean.
 * One record:
 *   tag:u64 proxy:u64 opcode:u32 nArgs:u32 then per arg  type:u8 followed by 8 bytes
 *   (scalar, sign-extended / proxy pointer) or len:u32 + bytes (string, array;
 *   len 0xffffffff = NULL string).
 * `tag` is the Lean tag of the receiving proxy, so a reused pointer cannot alias a destroyed
 * object. A proxy created by an event ('n') gets the recorder installed immediately, with
 * tag 0, so events for it in the same batch are not lost; Lean learns its pointer from the
 * record. Incoming fds ('h') are passed as ints; Lean owns and closes them.
 * A protocol error surfaces as an IO error carrying wl_display_get_protocol_error. */
lean_obj_res lean_ui_wl_pump(size_t display, lean_obj_arg w);
/* Re-tag a proxy (used for proxies created by events). */
lean_obj_res lean_ui_wl_set_tag(size_t proxy, uint64_t tag, lean_obj_arg w);
/* xkbcommon. Keymap arrives as (fd, size) from wl_keyboard.keymap; the fd is consumed.
 * Also loads the locale's compose table. Returns state*; free with lean_ui_xkb_free. */
lean_obj_res lean_ui_xkb_keymap(uint32_t fd, uint32_t size, lean_obj_arg w);
lean_obj_res lean_ui_xkb_free(size_t state, lean_obj_arg w);
lean_obj_res lean_ui_xkb_modifiers(size_t state, uint32_t depressed, uint32_t latched,
                                   uint32_t locked, uint32_t group, lean_obj_arg w);
/* Key press (evdev code, not +8), fed through compose. Returns
 *   keysym:u32 mods:u32 consumed:u32 compose:u8 then UTF-8 text
 * mods/consumed use fixed bits (1 Shift, 2 Ctrl, 4 Alt, 8 Super, 16 Caps) independent of
 * the keymap; compose is 0 none, 1 composing (no text yet), 2 composed, 3 cancelled. */
lean_obj_res lean_ui_xkb_key(size_t state, uint32_t key, lean_obj_arg w);
/* Shared-memory file of `size` bytes. Returns fd. pipe / read / write / close / mmap on
 * fds come from lean-sys (`LeanSys.Posix`), not from this shim. */
lean_obj_res lean_ui_memfd(uint32_t size, lean_obj_arg w);

/* ---- lean_ui_vulkan.c : libvulkan.so.1 through a generic call bridge -------------- */

/* dlopen + dlsym. Returns function address or 0. */
lean_obj_res lean_ui_dl_sym(b_lean_obj_arg lib, b_lean_obj_arg sym, lean_obj_arg w);
/* Call fn(a0..a5) with integer/pointer arguments (SysV / AAPCS64 integer class only).
 * `args` is 6 * u64. Returns u64 (VkResult is its low 32 bits).
 * Consequence for the Lean side: only Vulkan entry points with <= 6 integer-class
 * arguments are reachable. Use the Vulkan 1.3 `*2` forms (vkCmdPipelineBarrier2,
 * vkCmdCopyImageToBuffer2, vkCmdBlitImage2), push descriptors instead of
 * vkCmdBindDescriptorSets, and no float-argument commands (line width, depth bias).
 * Resolve instance/device functions through vkGetInstanceProcAddr / vkGetDeviceProcAddr,
 * which are themselves called through this bridge; only vkGetInstanceProcAddr uses dlsym. */
lean_obj_res lean_ui_call(size_t fn, b_lean_obj_arg args, lean_obj_arg w);
/* Native scratch memory for structs that must outlive one call. Zero-filled. */
lean_obj_res lean_ui_mem_alloc(size_t size, lean_obj_arg w);
lean_obj_res lean_ui_mem_free(size_t ptr, lean_obj_arg w);
/* Copy bytes into / out of native memory (also used on mapped VkDeviceMemory). */
lean_obj_res lean_ui_mem_write(size_t ptr, b_lean_obj_arg bytes, lean_obj_arg w);
lean_obj_res lean_ui_mem_read(size_t ptr, size_t size, lean_obj_arg w);

/* ---- lean_ui_text.c : Fontconfig + FreeType 2 + HarfBuzz -------------------------- */
/* Single-threaded: FT_Face is not thread-safe. */

/* Resolve a Fontconfig pattern ("Inter:weight=500") to a face. Returns face handle. */
lean_obj_res lean_ui_font_open(b_lean_obj_arg pattern, lean_obj_arg w);
lean_obj_res lean_ui_font_close(size_t face, lean_obj_arg w);
/* Metrics at `size64` (26.6 px): ascender:i32 descender:i32 lineHeight:i32
 * underlinePosition:i32 underlineThickness:i32. */
lean_obj_res lean_ui_font_metrics(size_t face, uint32_t size64, lean_obj_arg w);
/* Shape UTF-8 `text`. `features` is a comma-separated HarfBuzz feature list ("tnum,-liga",
 * may be empty); direction, script and language are guessed per run by HarfBuzz.
 * Returns nGlyphs records of
 *   glyph:u32 cluster:u32 xAdvance:i32 yAdvance:i32 xOffset:i32 yOffset:i32   (26.6 px)
 * A glyph id of 0 means the face lacks the character (Lean picks a fallback face). */
lean_obj_res lean_ui_shape(size_t face, uint32_t size64, b_lean_obj_arg text,
                           b_lean_obj_arg features, lean_obj_arg w);
/* Rasterise one glyph at subpixel bin `subpx` (0..3 quarters of a pixel). Returns
 *   width:u32 height:u32 left:i32 top:i32 isColor:u8 then width*height bytes of coverage
 *   (or width*height*4 premultiplied BGRA when isColor; colour bitmaps are returned at
 *   their native strike size and scaled by the renderer). */
lean_obj_res lean_ui_rasterize(size_t face, uint32_t size64, uint32_t glyph, uint32_t subpx,
                               lean_obj_arg w);
#endif
