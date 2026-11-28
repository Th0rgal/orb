#include "lean_ui.h"
#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>

static lean_obj_res io_err(const char *msg) {
  return lean_io_result_mk_error(lean_mk_io_user_error(lean_mk_string(msg)));
}

/* Offsets, widths and pitches in pixels. Validate without overflowing. */
static int fits_rows(size_t len, size_t off, size_t pitch, size_t w, size_t h) {
  return h && w && pitch >= w && off <= len && w <= len-off && h-1 <= (len-off-w)/pitch;
}
lean_obj_res lean_ui_blit_glyph(lean_obj_arg fb, b_lean_obj_arg atlas, size_t dst, size_t src,
    size_t stride, size_t pitch, size_t w, size_t h, uint32_t color, uint8_t colored) {
  if (!fits_rows(lean_sarray_size(fb)/4,dst,stride,w,h) ||
      !fits_rows(lean_sarray_size(atlas)/4,src,pitch,w,h)) return fb;
  fb = lean_sarray_ensure_exclusive(fb);
  for (size_t y=0; y<h; ++y) {
    uint8_t *d = lean_sarray_cptr(fb) + 4*(dst+y*stride);
    const uint8_t *s = lean_sarray_cptr(atlas) + 4*(src+y*pitch);
    for (size_t x=0; x<w; ++x,d+=4,s+=4) {
      unsigned a = (s[3]*(color & 255)+127)/255;
      if (!a) continue;
      for (unsigned i=0; i<3; ++i) {
        unsigned v = colored ? ((s[i]*(color & 255)+127)/255 + (d[i]*(255-a)+127)/255)
                             : ((((color >> (24-8*i)) & 255)*a + d[i]*(255-a)+127)/255);
        d[i] = v > 255 ? 255 : v;
      }
      unsigned oa = a + (d[3]*(255-a)+127)/255; d[3] = oa > 255 ? 255 : oa;
    }
  }
  return fb;
}

/* Full-coverage interior of a clipped box. Edges still use signed distance coverage. */
lean_obj_res lean_ui_blend_rect(lean_obj_arg fb, size_t off, size_t pitch, size_t w, size_t h, uint32_t color) {
  unsigned alpha = color & 255, inv = 255-alpha;
  if (!alpha || !fits_rows(lean_sarray_size(fb)/4,off,pitch,w,h)) return fb;
  unsigned red = (color>>24)*alpha, green = ((color>>16)&255)*alpha, blue = ((color>>8)&255)*alpha;
  fb = lean_sarray_ensure_exclusive(fb);
  for (size_t y=0; y<h; ++y) {
    uint8_t *d = lean_sarray_cptr(fb) + 4*(off+y*pitch);
    for (size_t x=0; x<w; ++x,d+=4) {
      d[0]=(red+d[0]*inv+127)/255; d[1]=(green+d[1]*inv+127)/255;
      d[2]=(blue+d[2]*inv+127)/255; d[3]=alpha+(d[3]*inv+127)/255;
    }
  }
  return fb;
}

lean_obj_res lean_ui_scroll_rows(lean_obj_arg fb, size_t off, size_t stride, size_t w,
                                size_t h, size_t shift) {
  size_t len = lean_sarray_size(fb);
  if (!stride || off > len || shift > (len-off)/stride ||
      !fits_rows(len,off+shift*stride,stride,w,h)) return fb;
  fb = lean_sarray_ensure_exclusive(fb);
  uint8_t *p = lean_sarray_cptr(fb) + off;
  for (size_t y=0; y<h; ++y) memmove(p+y*stride,p+(y+shift)*stride,w);
  return fb;
}

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
static int seg_near(const uint8_t *q, double xlo, double xhi, double lo, double hi, double c) {
  double ax=icon_coord(q), ay=icon_coord(q+2), bx=icon_coord(q+4), by=icon_coord(q+6);
  return (ax<bx?ax:bx)-c<=xhi && (ax>bx?ax:bx)+c>=xlo && (ay<by?ay:by)-c<=hi && (ay>by?ay:by)+c>=lo;
}
/* Match rasterizeIconReference: 16 pixel-center samples, arbitrary stroke_tenths, bounded w*h. */
lean_obj_res lean_ui_icon_mask(b_lean_obj_arg segments, size_t w, size_t h, uint32_t st) {
#ifdef __clang__
#pragma STDC FP_CONTRACT OFF
#endif
  if (!w || !h || w > 1024 || h > w || st > 10000) return lean_alloc_sarray(1,0,0);
  lean_obj_res out = lean_alloc_sarray(1,w*h,w*h);
  uint8_t *dst = lean_sarray_cptr(out); memset(dst, 0, w*h);
  const uint8_t *p = lean_sarray_cptr(segments); size_t n = lean_sarray_size(segments)/8;
  double rad = (double)st / 10.0, r2 = rad*rad, c = rad + 0.5, dw = (double)w;
  for (size_t y=0; y<h; ++y) {
    double lo = (double)y*160.0/dw, hi = (double)(y+1)*160.0/dw;
    int any = 0; for (size_t j=0; j<n && !any; ++j) any = seg_near(p+8*j, -1e9, 1e9, lo, hi, c);
    if (!any) continue;
    for (size_t x=0; x<w; ++x) {
      double xlo = (double)x*160.0/dw, xhi = (double)(x+1)*160.0/dw;
      unsigned cov = 0; for (size_t j=0; j<n && !cov; ++j) cov = seg_near(p+8*j, xlo, xhi, lo, hi, c);
      if (!cov) continue; else cov = 0;
      for (unsigned sy=0; sy<4; ++sy) for (unsigned sx=0; sx<4; ++sx) {
        double px=(x+(sx+0.5)/4)*160/dw, py=(y+(sy+0.5)/4)*160/dw;
        for (size_t j=0; j<n; ++j) {
          const uint8_t *q=p+8*j; double ax=icon_coord(q), ay=icon_coord(q+2);
          double dx=icon_coord(q+4)-ax, dy=icon_coord(q+6)-ay, vx=px-ax, vy=py-ay, len=dx*dx+dy*dy;
          double t=len ? (vx*dx+vy*dy)/len : 0; t=t<0 ? 0 : t>1 ? 1 : t;
          double ex=vx-t*dx, ey=vy-t*dy; if (ex*ex+ey*ey<=r2) { ++cov; break; }
        }
      }
      dst[y*w+x]=(cov*255+8)/16;
    }
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
  const char *lib_str = lean_string_cstr(lib), *sym_str = lean_string_cstr(sym);
  void *h = dlopen(lib_str[0] ? lib_str : NULL, RTLD_LAZY | RTLD_LOCAL);
  if (!h) return lean_io_result_mk_ok(lean_box_usize(0));
  return lean_io_result_mk_ok(lean_box_usize((size_t)dlsym(h, sym_str)));
}

lean_obj_res lean_ui_call(size_t fn, b_lean_obj_arg args, lean_obj_arg w) {
  (void)w;
  if (!fn) return io_err("lean_ui_call: null function pointer");
  if (lean_sarray_size(args) < 48) return io_err("lean_ui_call: args requires 48 bytes (6 * u64)");
  uint64_t a[6]; memcpy(a, lean_sarray_cptr(args), 48);
  fn6_t f; memcpy(&f, &fn, sizeof(fn));
  return lean_io_result_mk_ok(lean_box_uint64(f(a[0], a[1], a[2], a[3], a[4], a[5])));
}

lean_obj_res lean_ui_mem_alloc(size_t size, lean_obj_arg w) {
  (void)w; void *p = calloc(1, size ? size : 1);
  return p ? lean_io_result_mk_ok(lean_box_usize((size_t)p)) : io_err("lean_ui_mem_alloc: out of memory");
}

lean_obj_res lean_ui_mem_free(size_t ptr, lean_obj_arg w) {
  (void)w; if (ptr) free((void *)ptr);
  return lean_io_result_mk_ok(lean_box(0));
}

/* Convert directly into the compositor's back buffer, without cloning the frame. */
lean_obj_res lean_ui_present_argb(size_t ptr, b_lean_obj_arg bytes, lean_obj_arg w) {
  (void)w;
  if (!ptr) return io_err("null presentation buffer");
  const uint8_t *restrict src = lean_sarray_cptr(bytes);
  uint8_t *restrict dst = (uint8_t *)ptr;
  size_t n = lean_sarray_size(bytes);
  if (n % 4) return io_err("invalid RGBA frame size");
  for (size_t i = 0; i < n; i += 4) {
    /* Raster source-over already produced premultiplied RGBA. */
    dst[i]   = src[i+2];
    dst[i+1] = src[i+1];
    dst[i+2] = src[i];
    dst[i+3] = src[i+3];
  }
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
