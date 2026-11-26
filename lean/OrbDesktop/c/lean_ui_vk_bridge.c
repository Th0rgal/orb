/* lean_ui_vk_bridge.c — thin Vulkan 1.3 call & strided transfer bridge (<= 120 LOC).
 *
 * LP64 SysV x86_64 / AAPCS64 sound 0..8 integer/pointer-arg trampolines plus
 * bounds-checked zero-allocation strided rectangle copies for staging & readback.
 * Zero external Vulkan header or link dependencies (libvulkan.so.1 via dlopen).
 */
#include "lean_ui.h"
#include <stdint.h>
#include <string.h>

static lean_obj_res vk_io_err(const char *msg) {
  return lean_io_result_mk_error(lean_mk_io_user_error(lean_mk_string(msg)));
}

static int vk_fits_rows(size_t len, size_t off, size_t stride, size_t row_bytes, size_t rows) {
  if (rows == 0 || row_bytes == 0) return 1;
  return stride >= row_bytes && off <= len && row_bytes <= len - off &&
         rows - 1 <= (len - off - row_bytes) / stride;
}

typedef void (*vk_fn_void8_t)(uint64_t, uint64_t, uint64_t, uint64_t,
                              uint64_t, uint64_t, uint64_t, uint64_t);
typedef int32_t (*vk_fn_res8_t)(uint64_t, uint64_t, uint64_t, uint64_t,
                                uint64_t, uint64_t, uint64_t, uint64_t);

lean_obj_res lean_ui_vk_call_void8(size_t fn, b_lean_obj_arg args, lean_obj_arg w) {
  (void)w;
  if (!fn) return vk_io_err("lean_ui_vk_call_void8: null function pointer");
  if (lean_sarray_size(args) < 64)
    return vk_io_err("lean_ui_vk_call_void8: args requires 64 bytes (8 * u64)");
  uint64_t a[8];
  memcpy(a, lean_sarray_cptr(args), 64);
  vk_fn_void8_t f;
  memcpy(&f, &fn, sizeof(fn));
  f(a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7]);
  return lean_io_result_mk_ok(lean_box(0));
}

lean_obj_res lean_ui_vk_call_res8(size_t fn, b_lean_obj_arg args, lean_obj_arg w) {
  (void)w;
  if (!fn) return vk_io_err("lean_ui_vk_call_res8: null function pointer");
  if (lean_sarray_size(args) < 64)
    return vk_io_err("lean_ui_vk_call_res8: args requires 64 bytes (8 * u64)");
  uint64_t a[8];
  memcpy(a, lean_sarray_cptr(args), 64);
  vk_fn_res8_t f;
  memcpy(&f, &fn, sizeof(fn));
  int32_t res = f(a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7]);
  return lean_io_result_mk_ok(lean_box_uint32((uint32_t)res));
}

lean_obj_res lean_ui_vk_copy_rect(size_t dst_ptr, size_t dst_cap, b_lean_obj_arg src,
                                  size_t src_off, size_t src_stride, size_t row_bytes,
                                  size_t rows, lean_obj_arg w) {
  (void)w;
  if (rows == 0 || row_bytes == 0) return lean_io_result_mk_ok(lean_box(0));
  if (!dst_ptr) return vk_io_err("lean_ui_vk_copy_rect: null destination pointer");
  if (rows > dst_cap / row_bytes)
    return vk_io_err("lean_ui_vk_copy_rect: destination staging buffer overflow");
  if (!vk_fits_rows(lean_sarray_size(src), src_off, src_stride, row_bytes, rows))
    return vk_io_err("lean_ui_vk_copy_rect: source rectangle out of bounds");
  const uint8_t *s = lean_sarray_cptr(src) + src_off;
  uint8_t *d = (uint8_t *)dst_ptr;
  if (src_stride == row_bytes) {
    memcpy(d, s, rows * row_bytes);
  } else {
    for (size_t y = 0; y < rows; ++y)
      memcpy(d + y * row_bytes, s + y * src_stride, row_bytes);
  }
  return lean_io_result_mk_ok(lean_box(0));
}

lean_obj_res lean_ui_vk_read_rect(size_t src_ptr, size_t src_stride, size_t row_bytes,
                                  size_t rows, lean_obj_arg w) {
  (void)w;
  if (rows == 0 || row_bytes == 0)
    return lean_io_result_mk_ok(lean_alloc_sarray(1, 0, 0));
  if (!src_ptr) return vk_io_err("lean_ui_vk_read_rect: null source pointer");
  if (src_stride < row_bytes || rows > SIZE_MAX / row_bytes)
    return vk_io_err("lean_ui_vk_read_rect: invalid stride or size overflow");
  size_t total = rows * row_bytes;
  lean_obj_res out = lean_alloc_sarray(1, total, total);
  uint8_t *d = lean_sarray_cptr(out);
  const uint8_t *s = (const uint8_t *)src_ptr;
  if (src_stride == row_bytes) {
    memcpy(d, s, total);
  } else {
    for (size_t y = 0; y < rows; ++y)
      memcpy(d + y * row_bytes, s + y * src_stride, row_bytes);
  }
  return lean_io_result_mk_ok(out);
}
