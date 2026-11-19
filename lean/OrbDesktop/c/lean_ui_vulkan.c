#include "lean_ui.h"
#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>

static lean_obj_res io_err(const char *msg) {
  return lean_io_result_mk_error(lean_mk_io_user_error(lean_mk_string(msg)));
}

/* Compare a strided rectangle in two RGBA buffers. Out-of-range
 * rectangles cannot establish reuse; the caller then repaints in full. */
uint8_t lean_ui_same_rows(b_lean_obj_arg a, b_lean_obj_arg b, size_t off,
                          size_t stride, size_t bytes, size_t rows) {
  size_t len = lean_sarray_size(a) < lean_sarray_size(b) ? lean_sarray_size(a) : lean_sarray_size(b);
  if (off > len || bytes > len - off) return 0;
  if (rows == 0 || bytes == 0) return 1;
  if (!stride || rows - 1 > (len - off - bytes) / stride) return 0;
  for (size_t i = 0; i < rows; ++i)
    if (memcmp(lean_sarray_cptr(a) + off + i * stride,
               lean_sarray_cptr(b) + off + i * stride, bytes)) return 0;
  return 1;
}

typedef uint64_t (*fn6_t)(uint64_t, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t);

static double icon_coord(const uint8_t *p) { return (int)p[0]+256*(int)p[1]-128; }

/* Match rasterizeIconReference: 16 pixel-center samples, round segment
 * endpoints, and the same floating-point operations (no fused multiply-add). */
lean_obj_res lean_ui_icon_mask(b_lean_obj_arg segments, size_t size) {
#pragma STDC FP_CONTRACT OFF
  if (size > 1024) return lean_alloc_sarray(1,0,0);
  lean_obj_res out = lean_alloc_sarray(1,size*size,size*size);
  const uint8_t *p = lean_sarray_cptr(segments);
  size_t n = lean_sarray_size(segments)/8;
  for (size_t y=0; y<size; ++y) for (size_t x=0; x<size; ++x) {
    unsigned coverage = 0;
    for (unsigned sy=0; sy<4; ++sy) for (unsigned sx=0; sx<4; ++sx) {
      double px=(x+(sx+0.5)/4)*160/size, py=(y+(sy+0.5)/4)*160/size;
      for (size_t j=0; j<n; ++j) {
        const uint8_t *q=p+8*j;
        double ax=icon_coord(q), ay=icon_coord(q+2);
        double dx=icon_coord(q+4)-ax, dy=icon_coord(q+6)-ay;
        double vx=px-ax, vy=py-ay, len=dx*dx+dy*dy;
        double t=len ? (vx*dx+vy*dy)/len : 0;
        t=t<0 ? 0 : t>1 ? 1 : t;
        double ex=vx-t*dx, ey=vy-t*dy;
        if (ex*ex+ey*ey<=30.25) { ++coverage; break; }
      }
    }
    lean_sarray_cptr(out)[y*size+x]=(coverage*255+8)/16;
  }
  return out;
}

/* Separable RGBA8 box pass; the Lean caller checks dimensions and limits
 * radius to 65535 so the exact integer channel sum fits in uint32_t. */
lean_obj_res lean_ui_box_axis(b_lean_obj_arg src, size_t w, size_t h,
                              size_t r, uint8_t horizontal) {
  size_t size = lean_sarray_size(src);
  if (!w || !h || !r || r > 65535 || w > SIZE_MAX / 4 / h || w*h*4 != size) {
    lean_inc(src); return src;
  }
  lean_obj_res out = lean_alloc_sarray(1, size, size);
  uint8_t *dst = lean_sarray_cptr(out);
  const uint8_t *pixels = lean_sarray_cptr(src);
  size_t lines = horizontal ? h : w, len = horizontal ? w : h;
  size_t stride = horizontal ? 4 : w*4;
  uint32_t width = 2*r+1;
  for (size_t line=0; line<lines; ++line) {
    size_t base = line * (horizontal ? w*4 : 4);
    uint32_t sum[4] = {0};
    for (size_t k=0; k<width; ++k) {
      size_t i = k <= r ? 0 : k-r < len ? k-r : len-1;
      for (size_t c=0; c<4; ++c) sum[c] += pixels[base+i*stride+c];
    }
    for (size_t i=0; i<len; ++i) {
      size_t old = i<r ? 0 : i-r, next = i+r+1<len ? i+r+1 : len-1;
      for (size_t c=0; c<4; ++c) {
        dst[base+i*stride+c] = (sum[c]+r)/width;
        sum[c] = sum[c]-pixels[base+old*stride+c]+pixels[base+next*stride+c];
      }
    }
  }
  return out;
}

lean_obj_res lean_ui_dl_sym(b_lean_obj_arg lib, b_lean_obj_arg sym, lean_obj_arg w) {
  (void)w;
  const char *lib_str = lean_string_cstr(lib);
  const char *sym_str = lean_string_cstr(sym);
  void *h = dlopen(lib_str[0] ? lib_str : NULL, RTLD_LAZY | RTLD_LOCAL);
  if (!h)
    return lean_io_result_mk_ok(lean_box_usize(0));
  void *fn = dlsym(h, sym_str);
  return lean_io_result_mk_ok(lean_box_usize((size_t)fn));
}

lean_obj_res lean_ui_call(size_t fn, b_lean_obj_arg args, lean_obj_arg w) {
  (void)w;
  if (!fn)
    return io_err("lean_ui_call: null function pointer");
  if (lean_sarray_size(args) < 48)
    return io_err("lean_ui_call: args requires 48 bytes (6 * u64)");
  uint64_t a[6];
  memcpy(a, lean_sarray_cptr(args), 48);
  fn6_t f;
  memcpy(&f, &fn, sizeof(fn));
  uint64_t res = f(a[0], a[1], a[2], a[3], a[4], a[5]);
  return lean_io_result_mk_ok(lean_box_uint64(res));
}

lean_obj_res lean_ui_mem_alloc(size_t size, lean_obj_arg w) {
  (void)w;
  void *p = calloc(1, size ? size : 1);
  if (!p)
    return io_err("lean_ui_mem_alloc: out of memory");
  return lean_io_result_mk_ok(lean_box_usize((size_t)p));
}

lean_obj_res lean_ui_mem_free(size_t ptr, lean_obj_arg w) {
  (void)w;
  if (ptr)
    free((void *)ptr);
  return lean_io_result_mk_ok(lean_box(0));
}

lean_obj_res lean_ui_mem_write(size_t ptr, b_lean_obj_arg bytes, lean_obj_arg w) {
  (void)w;
  size_t sz = lean_sarray_size(bytes);
  if (sz > 0) {
    if (!ptr)
      return io_err("lean_ui_mem_write: null destination pointer");
    memcpy((void *)ptr, lean_sarray_cptr(bytes), sz);
  }
  return lean_io_result_mk_ok(lean_box(0));
}

lean_obj_res lean_ui_mem_read(size_t ptr, size_t size, lean_obj_arg w) {
  (void)w;
  if (size > 0 && !ptr)
    return io_err("lean_ui_mem_read: null source pointer");
  lean_obj_res arr = lean_alloc_sarray(1, size, size);
  if (size > 0)
    memcpy(lean_sarray_cptr(arr), (const void *)ptr, size);
  return lean_io_result_mk_ok(arr);
}
