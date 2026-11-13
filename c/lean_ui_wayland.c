#define _GNU_SOURCE
#include "lean_ui.h"
#include <dlfcn.h>
#include <errno.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include <wayland-client-core.h>
#include <xkbcommon/xkbcommon-compose.h>
#include <xkbcommon/xkbcommon-names.h>
#include <xkbcommon/xkbcommon.h>

static uint8_t *g_ev_buf = NULL;
static size_t g_ev_len = 0, g_ev_cap = 0;

static void ev_put(const void *p, size_t n) {
  if (g_ev_len + n > g_ev_cap) {
    for (g_ev_cap = g_ev_cap ? g_ev_cap * 2 : 4096; g_ev_cap < g_ev_len + n; g_ev_cap *= 2) {}
    g_ev_buf = (uint8_t *)realloc(g_ev_buf, g_ev_cap);
  }
  if (n) memcpy(g_ev_buf + g_ev_len, p, n);
  g_ev_len += n;
}
static void ev_u32(uint32_t v) { ev_put(&v, 4); }
static void ev_u64(uint64_t v) { ev_put(&v, 8); }
static lean_obj_res io_err(const char *m) { return lean_io_result_mk_error(lean_mk_io_user_error(lean_mk_string(m))); }
static int is_arg(char c) { return c != '?' && (c < '0' || c > '9'); }
static const char *rd_cstr(const uint8_t **p, const uint8_t *end) {
  const uint8_t *z = (*p < end) ? (const uint8_t *)memchr(*p, 0, (size_t)(end - *p)) : NULL;
  const char *s = z ? (const char *)*p : NULL; if (z) *p = z + 1; return s;
}
static int wl_disp(const void *impl, void *target, uint32_t opcode, const struct wl_message *msg, union wl_argument *args) {
  (void)impl; struct wl_proxy *p = (struct wl_proxy *)target;
  ev_u64((uint64_t)(uintptr_t)wl_proxy_get_user_data(p)); ev_u64((uint64_t)(uintptr_t)p);
  uint32_t na = 0, i = 0; for (const char *s = msg->signature; *s; s++) if (is_arg(*s)) na++;
  ev_u32(opcode); ev_u32(na);
  for (const char *s = msg->signature; *s; s++) {
    char c = *s; if (!is_arg(c)) continue;
    ev_put(&c, 1);
    if (c == 'i' || c == 'f' || c == 'h') ev_u64((uint64_t)(int64_t)args[i].i);
    else if (c == 'u') ev_u64((uint64_t)args[i].u);
    else if (c == 'o' || c == 'n') {
      struct wl_proxy *np = (struct wl_proxy *)args[i].o;
      if (c == 'n' && np) wl_proxy_add_dispatcher(np, wl_disp, NULL, NULL);
      ev_u64((uint64_t)(uintptr_t)np);
    } else if (c == 's') {
      uint32_t l = args[i].s ? (uint32_t)strlen(args[i].s) : 0xffffffffu;
      ev_u32(l); if (args[i].s) ev_put(args[i].s, l);
    } else if (c == 'a') {
      uint32_t l = args[i].a ? (uint32_t)args[i].a->size : 0;
      ev_u32(l); if (l) ev_put(args[i].a->data, l);
    }
    i++;
  }
  return 0;
}
lean_obj_res lean_ui_wl_connect(lean_obj_arg w) {
  (void)w; struct wl_display *d = wl_display_connect(NULL);
  return d ? lean_io_result_mk_ok(lean_box_usize((size_t)d)) : io_err("wl_display_connect failed");
}
lean_obj_res lean_ui_wl_fd(size_t display, lean_obj_arg w) {
  (void)w; return display ? lean_io_result_mk_ok(lean_box_uint32((uint32_t)wl_display_get_fd((struct wl_display *)display))) : io_err("null display");
}
lean_obj_res lean_ui_wl_core_interface(b_lean_obj_arg name, lean_obj_arg w) {
  (void)w; void *p = dlsym(RTLD_DEFAULT, lean_string_cstr(name));
  if (!p) { void *h = dlopen("libwayland-client.so.0", RTLD_LAZY | RTLD_GLOBAL); if (h) p = dlsym(h, lean_string_cstr(name)); }
  return p ? lean_io_result_mk_ok(lean_box_usize((size_t)p)) : io_err("wl_interface not found");
}
static int parse_msgs(const uint8_t **p, const uint8_t *end, uint32_t n, const struct wl_message **out) {
  *out = NULL; if (!n) return 1;
  struct wl_message *ms = (struct wl_message *)calloc(n, sizeof(struct wl_message));
  for (uint32_t i = 0; i < n; i++) {
    const char *nm = rd_cstr(p, end), *sg = nm ? rd_cstr(p, end) : NULL;
    if (!nm || !sg) { free(ms); return 0; }
    size_t ac = 0; for (const char *s = sg; *s; s++) if (is_arg(*s)) ac++;
    if (ac > (size_t)(end - *p) / 8) { free(ms); return 0; }
    ms[i].name = strdup(nm); ms[i].signature = strdup(sg);
    const struct wl_interface **ts = (const struct wl_interface **)calloc(ac ? ac : 1, sizeof(void *));
    for (size_t j = 0; j < ac; j++, *p += 8) { uint64_t v; memcpy(&v, *p, 8); ts[j] = (const struct wl_interface *)(uintptr_t)v; }
    ms[i].types = ts;
  }
  *out = ms; return 1;
}
lean_obj_res lean_ui_wl_make_interface(b_lean_obj_arg desc, lean_obj_arg w) {
  (void)w; const uint8_t *p = lean_sarray_cptr(desc), *end = p + lean_sarray_size(desc);
  const char *nm = rd_cstr(&p, end); if (!nm || (size_t)(end - p) < 12) return io_err("invalid wl_interface descriptor");
  uint32_t hdr[3]; memcpy(hdr, p, 12); p += 12; const struct wl_message *ms = NULL, *evs = NULL;
  if (!parse_msgs(&p, end, hdr[1], &ms) || !parse_msgs(&p, end, hdr[2], &evs)) return io_err("truncated wl_interface messages");
  struct wl_interface *it = (struct wl_interface *)calloc(1, sizeof(struct wl_interface));
  it->name = strdup(nm); it->version = (int)hdr[0]; it->method_count = (int)hdr[1]; it->event_count = (int)hdr[2];
  it->methods = ms; it->events = evs; return lean_io_result_mk_ok(lean_box_usize((size_t)it));
}
lean_obj_res lean_ui_wl_marshal(size_t proxy, uint32_t opcode, size_t iface, uint32_t version, uint32_t flags,
                                uint64_t tag, b_lean_obj_arg sig, b_lean_obj_arg args, b_lean_obj_arg blob, lean_obj_arg w) {
  (void)w; const char *s = lean_string_cstr(sig); size_t na = strlen(s), bsz = lean_sarray_size(blob);
  if (!proxy || na > 20 || lean_sarray_size(args) < na * 8) return io_err("invalid marshal args");
  const uint8_t *ap = lean_sarray_cptr(args), *bp = lean_sarray_cptr(blob);
  union wl_argument wa[20]; struct wl_array arrs[20]; memset(wa, 0, sizeof(wa));
  for (size_t i = 0; i < na; i++) {
    uint64_t v; memcpy(&v, ap + i * 8, 8); uint32_t off = (uint32_t)v, l = 0;
    if (s[i] == 's') {
      if (off != 0xffffffffu && (off >= bsz || !memchr(bp + off, 0, bsz - off))) return io_err("bad string offset");
      wa[i].s = (off == 0xffffffffu) ? NULL : (const char *)(bp + off);
    } else if (s[i] == 'a') {
      if (off != 0xffffffffu) {
        if (off > bsz || bsz - off < 4) return io_err("bad array offset");
        memcpy(&l, bp + off, 4); if (l > bsz - off - 4) return io_err("bad array length");
        arrs[i] = (struct wl_array){l, l, (void *)(bp + off + 4)};
      }
      wa[i].a = (off == 0xffffffffu) ? NULL : &arrs[i];
    } else if (s[i] == 'o') wa[i].o = (struct wl_object *)(uintptr_t)v;
    else if (s[i] == 'n') wa[i].n = 0;
    else wa[i].i = (int32_t)v;
  }
  struct wl_proxy *np = wl_proxy_marshal_array_flags((struct wl_proxy *)proxy, opcode, (const struct wl_interface *)iface, version, flags, wa);
  if (iface && np) wl_proxy_add_dispatcher(np, wl_disp, NULL, (void *)(uintptr_t)tag);
  return lean_io_result_mk_ok(lean_box_usize((size_t)np));
}
lean_obj_res lean_ui_wl_pump(size_t display, lean_obj_arg w) {
  (void)w; struct wl_display *d = (struct wl_display *)display;
  if (!d) return io_err("null display");
  wl_display_flush(d); int prep = 1;
  while (wl_display_prepare_read(d) != 0) if (wl_display_dispatch_pending(d) < 0) { prep = 0; break; }
  if (prep) {
    struct pollfd pfd = {wl_display_get_fd(d), POLLIN, 0};
    if (poll(&pfd, 1, 0) > 0 && (pfd.revents & (POLLIN | POLLERR | POLLHUP))) wl_display_read_events(d);
    else wl_display_cancel_read(d);
    wl_display_dispatch_pending(d);
  }
  int err = wl_display_get_error(d);
  if (err) {
    char msg[128]; const struct wl_interface *it = NULL; uint32_t id = 0;
    if (err == EPROTO) {
      uint32_t code = wl_display_get_protocol_error(d, &it, &id);
      snprintf(msg, sizeof(msg), "wayland protocol error %u on %s#%u", code, it ? it->name : "?", id);
    } else snprintf(msg, sizeof(msg), "wayland error %d", err);
    g_ev_len = 0; return io_err(msg);
  }
  lean_obj_res r = lean_alloc_sarray(1, g_ev_len, g_ev_len);
  if (g_ev_len) memcpy(lean_sarray_cptr(r), g_ev_buf, g_ev_len);
  g_ev_len = 0; return lean_io_result_mk_ok(r);
}
lean_obj_res lean_ui_wl_set_tag(size_t proxy, uint64_t tag, lean_obj_arg w) {
  (void)w; if (proxy) wl_proxy_set_user_data((struct wl_proxy *)proxy, (void *)(uintptr_t)tag);
  return lean_io_result_mk_ok(lean_box(0));
}
typedef struct {
  struct xkb_context *ctx; struct xkb_keymap *km; struct xkb_state *st;
  struct xkb_compose_table *ct; struct xkb_compose_state *cs; xkb_mod_index_t m[5];
} ui_xkb_t;
lean_obj_res lean_ui_xkb_keymap(uint32_t fd, uint32_t size, lean_obj_arg w) {
  (void)w; if (!size) { close((int)fd); return io_err("xkb zero size"); }
  char *map = (char *)mmap(NULL, size, PROT_READ, MAP_PRIVATE, (int)fd, 0); close((int)fd);
  if (map == MAP_FAILED) return io_err("xkb mmap failed");
  ui_xkb_t *x = (ui_xkb_t *)calloc(1, sizeof(ui_xkb_t));
  x->ctx = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
  x->km = xkb_keymap_new_from_buffer(x->ctx, map, strnlen(map, size), XKB_KEYMAP_FORMAT_TEXT_V1, XKB_KEYMAP_COMPILE_NO_FLAGS);
  munmap(map, size);
  if (!x->km) { xkb_context_unref(x->ctx); free(x); return io_err("xkb_keymap_new failed"); }
  x->st = xkb_state_new(x->km);
  const char *loc = getenv("LC_ALL");
  if (!loc || !*loc) loc = getenv("LC_CTYPE");
  if (!loc || !*loc) loc = getenv("LANG");
  if (!loc || !*loc) loc = "en_US.UTF-8";
  x->ct = xkb_compose_table_new_from_locale(x->ctx, loc, XKB_COMPOSE_COMPILE_NO_FLAGS);
  if (x->ct) x->cs = xkb_compose_state_new(x->ct, XKB_COMPOSE_STATE_NO_FLAGS);
  const char *ns[5] = {XKB_MOD_NAME_SHIFT, XKB_MOD_NAME_CTRL, XKB_MOD_NAME_ALT, XKB_MOD_NAME_LOGO, XKB_MOD_NAME_CAPS};
  for (int i = 0; i < 5; i++) x->m[i] = xkb_keymap_mod_get_index(x->km, ns[i]);
  return lean_io_result_mk_ok(lean_box_usize((size_t)x));
}
lean_obj_res lean_ui_xkb_free(size_t state, lean_obj_arg w) {
  (void)w; ui_xkb_t *x = (ui_xkb_t *)state;
  if (x) {
    if (x->cs) xkb_compose_state_unref(x->cs);
    if (x->ct) xkb_compose_table_unref(x->ct);
    if (x->st) xkb_state_unref(x->st);
    if (x->km) xkb_keymap_unref(x->km);
    if (x->ctx) xkb_context_unref(x->ctx);
    free(x);
  }
  return lean_io_result_mk_ok(lean_box(0));
}
lean_obj_res lean_ui_xkb_modifiers(size_t state, uint32_t dep, uint32_t lat, uint32_t lck, uint32_t grp, lean_obj_arg w) {
  (void)w; ui_xkb_t *x = (ui_xkb_t *)state; if (x && x->st) xkb_state_update_mask(x->st, dep, lat, lck, 0, 0, grp);
  return lean_io_result_mk_ok(lean_box(0));
}
lean_obj_res lean_ui_xkb_key(size_t state, uint32_t key, lean_obj_arg w) {
  (void)w; ui_xkb_t *x = (ui_xkb_t *)state; if (!x || !x->st) return io_err("null xkb state");
  xkb_keycode_t kc = key + 8; xkb_keysym_t sym = xkb_state_key_get_one_sym(x->st, kc);
  uint32_t mods = 0, cons = 0;
  for (int i = 0; i < 5; i++) if (x->m[i] != XKB_MOD_INVALID) {
    if (xkb_state_mod_index_is_active(x->st, x->m[i], XKB_STATE_MODS_EFFECTIVE) > 0) mods |= (1u << i);
    if (xkb_state_mod_index_is_consumed2(x->st, kc, x->m[i], XKB_CONSUMED_MODE_GTK) > 0) cons |= (1u << i);
  }
  uint8_t comp = 0; char utf8[64] = {0}; int ulen = 0;
  if (x->cs && xkb_compose_state_feed(x->cs, sym) == XKB_COMPOSE_FEED_ACCEPTED) {
    comp = (uint8_t)xkb_compose_state_get_status(x->cs);
    if (comp == XKB_COMPOSE_COMPOSED) {
      xkb_keysym_t csym = xkb_compose_state_get_one_sym(x->cs);
      if (csym != XKB_KEY_NoSymbol) sym = csym;
      ulen = xkb_compose_state_get_utf8(x->cs, utf8, sizeof(utf8)); xkb_compose_state_reset(x->cs);
    } else if (comp == XKB_COMPOSE_CANCELLED) xkb_compose_state_reset(x->cs);
  }
  if (comp == 0) ulen = xkb_state_key_get_utf8(x->st, kc, utf8, sizeof(utf8));
  if (ulen < 0) ulen = 0;
  lean_obj_res r = lean_alloc_sarray(1, 13 + (size_t)ulen, 13 + (size_t)ulen);
  uint8_t *dst = lean_sarray_cptr(r); uint32_t hdr[3] = {sym, mods, cons};
  memcpy(dst, hdr, 12); dst[12] = comp; if (ulen > 0) memcpy(dst + 13, utf8, (size_t)ulen);
  return lean_io_result_mk_ok(r);
}
lean_obj_res lean_ui_memfd(uint32_t size, lean_obj_arg w) {
  (void)w; int fd = memfd_create("lean-ui", MFD_CLOEXEC);
  if (fd < 0 || ftruncate(fd, (off_t)size) < 0) { if (fd >= 0) close(fd); return io_err("memfd failed"); }
  return lean_io_result_mk_ok(lean_box_uint32((uint32_t)fd));
}
