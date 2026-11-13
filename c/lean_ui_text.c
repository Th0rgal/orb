#include "lean_ui.h"
#include <fontconfig/fontconfig.h>
#include <ft2build.h>
#include FT_FREETYPE_H
#include FT_OUTLINE_H
#include <hb-ft.h>
#include <hb.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
  FT_Face ft;
  hb_font_t *hb;
  uint32_t size64;
} ui_face_t;

static FT_Library g_ft = NULL;
static hb_buffer_t *g_buf = NULL;

static lean_obj_res io_err(const char *msg) {
  return lean_io_result_mk_error(lean_mk_io_user_error(lean_mk_string(msg)));
}

static int set_face_size(ui_face_t *f, uint32_t size64) {
  if (f->size64 == size64)
    return 0;
  if (FT_IS_SCALABLE(f->ft)) {
    FT_Size_RequestRec req = {FT_SIZE_REQUEST_TYPE_NOMINAL, (FT_Long)size64, (FT_Long)size64, 0, 0};
    if (FT_Request_Size(f->ft, &req))
      return -1;
  } else if (f->ft->num_fixed_sizes > 0) {
    int best = 0;
    long target = (long)size64, best_diff = 0x7fffffffL;
    for (int i = 0; i < f->ft->num_fixed_sizes; i++) {
      long d = (long)f->ft->available_sizes[i].y_ppem - target;
      if (d < 0)
        d = -d;
      if (d < best_diff) {
        best_diff = d;
        best = i;
      }
    }
    if (FT_Select_Size(f->ft, best))
      return -1;
  }
  f->size64 = size64;
  hb_ft_font_changed(f->hb);
  return 0;
}

lean_obj_res lean_ui_font_open(b_lean_obj_arg pattern, lean_obj_arg w) {
  (void)w;
  if (!g_ft && FT_Init_FreeType(&g_ft))
    return io_err("FT_Init_FreeType failed");
  FcInit();
  FcPattern *pat = FcNameParse((const FcChar8 *)lean_string_cstr(pattern));
  if (!pat)
    return io_err("FcNameParse failed");
  FcConfigSubstitute(NULL, pat, FcMatchPattern);
  FcDefaultSubstitute(pat);
  FcResult res;
  FcPattern *match = FcFontMatch(NULL, pat, &res);
  FcPatternDestroy(pat);
  if (!match)
    return io_err("FcFontMatch failed");
  FcChar8 *file = NULL;
  int index = 0;
  if (FcPatternGetString(match, FC_FILE, 0, &file) != FcResultMatch) {
    FcPatternDestroy(match);
    return io_err("FcPatternGetString(FC_FILE) failed");
  }
  FcPatternGetInteger(match, FC_INDEX, 0, &index);
  FT_Face ft = NULL;
  FT_Error err = FT_New_Face(g_ft, (const char *)file, index, &ft);
  FcPatternDestroy(match);
  if (err || !ft)
    return io_err("FT_New_Face failed");
  ui_face_t *f = (ui_face_t *)calloc(1, sizeof(ui_face_t));
  if (!f) {
    FT_Done_Face(ft);
    return io_err("calloc failed");
  }
  f->ft = ft;
  f->hb = hb_ft_font_create(ft, NULL);
  hb_ft_font_set_load_flags(f->hb, FT_LOAD_DEFAULT | FT_LOAD_COLOR);
  set_face_size(f, 16 * 64);
  return lean_io_result_mk_ok(lean_box_usize((size_t)f));
}

lean_obj_res lean_ui_font_close(size_t face, lean_obj_arg w) {
  (void)w;
  ui_face_t *f = (ui_face_t *)face;
  if (f) {
    if (f->hb)
      hb_font_destroy(f->hb);
    if (f->ft)
      FT_Done_Face(f->ft);
    free(f);
  }
  return lean_io_result_mk_ok(lean_box(0));
}

lean_obj_res lean_ui_font_metrics(size_t face, uint32_t size64, lean_obj_arg w) {
  (void)w;
  ui_face_t *f = (ui_face_t *)face;
  if (!f || set_face_size(f, size64))
    return io_err("lean_ui_font_metrics: invalid face or size");
  FT_Size_Metrics *m = &f->ft->size->metrics;
  int32_t out[5] = {(int32_t)m->ascender, (int32_t)m->descender, (int32_t)m->height,
                    (int32_t)FT_MulFix(f->ft->underline_position, m->y_scale),
                    (int32_t)FT_MulFix(f->ft->underline_thickness, m->y_scale)};
  lean_obj_res arr = lean_alloc_sarray(1, 20, 20);
  memcpy(lean_sarray_cptr(arr), out, 20);
  return lean_io_result_mk_ok(arr);
}

lean_obj_res lean_ui_shape(size_t face, uint32_t size64, b_lean_obj_arg text,
                           b_lean_obj_arg features, lean_obj_arg w) {
  (void)w;
  ui_face_t *f = (ui_face_t *)face;
  if (!f || set_face_size(f, size64))
    return io_err("lean_ui_shape: invalid face or size");
  if (!g_buf)
    g_buf = hb_buffer_create();
  hb_buffer_reset(g_buf);
  const char *txt = lean_string_cstr(text);
  int tlen = (int)lean_string_size(text) - 1;
  hb_buffer_add_utf8(g_buf, txt, tlen, 0, tlen);
  hb_buffer_guess_segment_properties(g_buf);
  hb_feature_t feats[32];
  unsigned int nfeats = 0;
  const char *p = lean_string_cstr(features);
  while (*p && nfeats < 32) {
    while (*p == ' ' || *p == ',')
      p++;
    if (!*p)
      break;
    const char *e = p;
    while (*e && *e != ',')
      e++;
    if (hb_feature_from_string(p, (int)(e - p), &feats[nfeats]))
      nfeats++;
    p = e;
  }
  hb_shape(f->hb, g_buf, feats, nfeats);
  unsigned int n = 0;
  hb_glyph_info_t *info = hb_buffer_get_glyph_infos(g_buf, &n);
  hb_glyph_position_t *pos = hb_buffer_get_glyph_positions(g_buf, &n);
  lean_obj_res arr = lean_alloc_sarray(1, (size_t)n * 24, (size_t)n * 24);
  uint8_t *dst = lean_sarray_cptr(arr);
  for (unsigned int i = 0; i < n; i++) {
    int32_t rec[6] = {(int32_t)info[i].codepoint, (int32_t)info[i].cluster, pos[i].x_advance,
                      pos[i].y_advance,           pos[i].x_offset,          pos[i].y_offset};
    memcpy(dst + (size_t)i * 24, rec, 24);
  }
  return lean_io_result_mk_ok(arr);
}

lean_obj_res lean_ui_rasterize(size_t face, uint32_t size64, uint32_t glyph, uint32_t subpx,
                               lean_obj_arg w) {
  (void)w;
  ui_face_t *f = (ui_face_t *)face;
  if (!f || set_face_size(f, size64))
    return io_err("lean_ui_rasterize: invalid face or size");
  if (FT_Load_Glyph(f->ft, glyph, FT_LOAD_DEFAULT | FT_LOAD_COLOR))
    return io_err("FT_Load_Glyph failed");
  FT_GlyphSlot slot = f->ft->glyph;
  if (slot->format == FT_GLYPH_FORMAT_OUTLINE) {
    FT_Outline_Translate(&slot->outline, (FT_Pos)((subpx & 3u) * 16u), 0);
    if (FT_Render_Glyph(slot, FT_RENDER_MODE_NORMAL))
      return io_err("FT_Render_Glyph failed");
  } else if (slot->format != FT_GLYPH_FORMAT_BITMAP) {
    if (FT_Render_Glyph(slot, FT_RENDER_MODE_NORMAL))
      return io_err("FT_Render_Glyph failed");
  }
  FT_Bitmap *bm = &slot->bitmap;
  uint32_t bw = bm->width, bh = bm->rows;
  uint8_t is_color = (bm->pixel_mode == FT_PIXEL_MODE_BGRA) ? 1 : 0;
  size_t bpp = is_color ? 4 : 1, pix_sz = (size_t)bw * bh * bpp;
  lean_obj_res arr = lean_alloc_sarray(1, 17 + pix_sz, 17 + pix_sz);
  uint8_t *dst = lean_sarray_cptr(arr);
  int32_t hdr[4] = {(int32_t)bw, (int32_t)bh, (int32_t)slot->bitmap_left, (int32_t)slot->bitmap_top};
  memcpy(dst, hdr, 16);
  dst[16] = is_color;
  uint8_t *out = dst + 17;
  memset(out, 0, pix_sz);
  for (uint32_t r = 0; r < bh; r++) {
    const uint8_t *src = bm->buffer + (bm->pitch >= 0 ? (int)r * bm->pitch : (int)(bh - 1 - r) * (-bm->pitch));
    uint8_t *row = out + (size_t)r * bw * bpp;
    if (bm->pixel_mode == FT_PIXEL_MODE_BGRA || bm->pixel_mode == FT_PIXEL_MODE_GRAY) {
      memcpy(row, src, (size_t)bw * bpp);
    } else if (bm->pixel_mode == FT_PIXEL_MODE_MONO) {
      for (uint32_t c = 0; c < bw; c++)
        row[c] = (src[c >> 3] & (0x80 >> (c & 7))) ? 255 : 0;
    }
  }
  return lean_io_result_mk_ok(arr);
}
