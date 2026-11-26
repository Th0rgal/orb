/* linux_shell/gtk_leanui_palette_rpc.c — Palette singleflight RPC & LeanUI paint bridge (<= 220 LOC). */
#include "gtk_leanui_palette_private.h"
#include <inttypes.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    OrbPalette *p;
    unsigned port;
    char token[128], *body, *resp;
    guint64 gen;
} PaletteRpcJob;

static char *pal_str(JSCValue *obj, const char *key) {
    JSCValue *v = jsc_value_object_get_property(obj, key);
    char *out = (v && jsc_value_is_string(v)) ? jsc_value_to_string(v) : g_strdup("");
    if (v) g_object_unref(v);
    return out;
}

void orb_pal_clear_items(OrbPalette *p) {
    for (int i = 0; i < p->count; ++i) {
        g_free(p->items[i].id); g_free(p->items[i].kind); g_free(p->items[i].title);
        g_free(p->items[i].subtitle); g_free(p->items[i].target); g_free(p->items[i].status);
        g_free(p->items[i].shortcut); g_free(p->items[i].color);
    }
    memset(p->items, 0, sizeof(p->items));
    p->count = 0;
}

/* Release the Vulkan session (the renderer owns the swapchain) before destroying its surface. */
void orb_pal_gpu_detach(OrbPalette *p) {
    if (p->wl.surface) {
        char req[64];
        snprintf(req, sizeof(req), "D\t%" PRIuPTR, (uintptr_t)p->wl.surface);
        orb_leanui_paint(req, NULL, 0, NULL, NULL);
    }
    orb_wl_subsurface_detach(&p->wl);
    if (p->gpu_active) p->surface_fresh = TRUE;
    p->gpu_active = FALSE;
}

void orb_pal_try_free(OrbPalette *p) {
    if (!p->closed || p->inflight > 0) return;
    orb_pal_gpu_detach(p);
    orb_pal_clear_items(p);
    if (p->surface) cairo_surface_destroy(p->surface);
    if (p->query) g_string_free(p->query, TRUE);
    if (p->jsc) g_object_unref(p->jsc);
    g_free(p);
}

static void pal_hits_cb(void *view, const char *regions) {
    OrbPalette *p = view;
    orb_palette_parse_hits(regions, p->hits, ORB_PALETTE_MAX_ITEMS, &p->hit_count, &p->card, &p->has_card);
}

static gboolean pal_paint(gpointer data) {
    OrbPalette *p = data;
    p->idle = 0;
    if (p->closed || !p->open || p->width < 2 || p->height < 2 || !gtk_widget_get_mapped(p->canvas))
        return G_SOURCE_REMOVE;
    int scale = p->scale > 0 ? p->scale : 1, w = p->width * scale, h = p->height * scale;
    GString *req = g_string_sized_new(1024);
    char buf[1024];
    int n = orb_palette_format_header(buf, sizeof(buf), p->width, p->height, scale, p->light, p->selected, p->query->str);
    if (n > 0) g_string_append_len(req, buf, n);
    for (int i = 0; i < p->count; ++i) {
        OrbPaletteItem *it = &p->items[i];
        n = orb_palette_format_item(buf, sizeof(buf), (unsigned)i, it->id, it->kind, it->title,
                                    it->subtitle, it->status, it->shortcut, it->color);
        if (n > 0) g_string_append_len(req, buf, n);
    }
    /* Prefer Vulkan on a subsurface above the window; the renderer answers 2 (presented),
     * 0 (retry) or anything else (no GPU here: detach and paint into the cairo surface). */
    p->wl.above = TRUE;
    if (!p->gpu_disabled && orb_wl_subsurface_ensure(&p->wl, p->canvas, NULL)) {
        char gpu[96];
        int g = snprintf(gpu, sizeof(gpu), "G\t%" PRIuPTR "\t%" PRIuPTR "\n", (uintptr_t)p->wl.display, (uintptr_t)p->wl.surface);
        g_string_prepend(req, gpu);
        int rc = orb_leanui_paint(req->str, NULL, 0, pal_hits_cb, p);
        g_string_erase(req, 0, g);
        if (rc == 2 || rc == 0) {
            if (!p->gpu_active) { p->gpu_active = TRUE; gtk_widget_queue_draw(p->canvas); }
            if (rc == 0) orb_pal_invalidate(p);
            g_string_free(req, TRUE);
            return G_SOURCE_REMOVE;
        }
        p->gpu_disabled = TRUE;
        orb_pal_gpu_detach(p);
    }
    if (!p->surface || cairo_image_surface_get_width(p->surface) != w ||
        cairo_image_surface_get_height(p->surface) != h) {
        if (p->surface) cairo_surface_destroy(p->surface);
        p->surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, w, h);
        p->surface_fresh = TRUE;
    }
    if (cairo_surface_status(p->surface) != CAIRO_STATUS_SUCCESS) { g_string_free(req, TRUE); return G_SOURCE_REMOVE; }
    /* "F": the surface holds no earlier frame, so the renderer must send a whole one. */
    if (p->surface_fresh) g_string_prepend_c(req, 'F');
    cairo_surface_flush(p->surface);
    if (orb_leanui_paint(req->str, cairo_image_surface_get_data(p->surface), (size_t)w * (size_t)h * 4, pal_hits_cb, p)) {
        p->surface_fresh = FALSE;
        cairo_surface_set_device_scale(p->surface, scale, scale);
        cairo_surface_mark_dirty(p->surface);
        gtk_widget_queue_draw(p->canvas);
    }
    g_string_free(req, TRUE);
    return G_SOURCE_REMOVE;
}

void orb_pal_invalidate(OrbPalette *p) {
    if (!p->closed && p->open && !p->idle)
        p->idle = g_idle_add_full(G_PRIORITY_HIGH_IDLE, pal_paint, p, NULL);
}

static void pal_rpc_dispatch(OrbPalette *p);

static gboolean pal_rpc_done(gpointer data) {
    PaletteRpcJob *j = data;
    OrbPalette *p = j->p;
    p->inflight--;
    gboolean activate_now = FALSE;
    if (p->open && !p->closed && j->gen == p->req_gen) {
        gboolean pending = p->pending_enter;
        p->pending_enter = FALSE;
        if (j->resp) {
            JSCValue *root = jsc_value_new_from_json(p->jsc, j->resp);
            JSCValue *res = (root && jsc_value_is_object(root)) ? jsc_value_object_get_property(root, "result") : NULL;
            JSCValue *arr = (res && jsc_value_is_object(res)) ? jsc_value_object_get_property(res, "items") : NULL;
            if (arr && jsc_value_is_array(arr)) {
                JSCValue *lv = jsc_value_object_get_property(arr, "length");
                int len = (lv && jsc_value_is_number(lv)) ? jsc_value_to_int32(lv) : 0;
                if (lv) g_object_unref(lv);
                if (len < 0) len = 0;
                if (len > ORB_PALETTE_MAX_ITEMS) len = ORB_PALETTE_MAX_ITEMS;
                orb_pal_clear_items(p);
                for (int i = 0; i < len; ++i) {
                    JSCValue *it = jsc_value_object_get_property_at_index(arr, (guint)i);
                    if (it && jsc_value_is_object(it)) {
                        OrbPaletteItem *d = &p->items[p->count++];
                        d->id = pal_str(it, "id"); d->kind = pal_str(it, "kind");
                        d->title = pal_str(it, "title"); d->subtitle = pal_str(it, "subtitle");
                        d->target = pal_str(it, "target"); d->status = pal_str(it, "status");
                        d->shortcut = pal_str(it, "shortcut"); d->color = pal_str(it, "color");
                    }
                    if (it) g_object_unref(it);
                }
                p->applied_gen = j->gen;
                p->selected = 0;
                p->scroll_acc = 0.0;
                orb_pal_invalidate(p);
                if (pending && p->count > 0) activate_now = TRUE;
            }
            if (arr) g_object_unref(arr);
            if (res) g_object_unref(res);
            if (root) g_object_unref(root);
        }
    }
    g_free(j->body); g_free(j->resp); g_free(j);
    if (activate_now) {
        orb_pal_activate(p, p->selected);
        return G_SOURCE_REMOVE;
    }
    if (p->open && !p->closed && p->dirty && p->inflight == 0) {
        p->dirty = FALSE;
        pal_rpc_dispatch(p);
    } else if (p->closed) {
        orb_pal_try_free(p);
    }
    return G_SOURCE_REMOVE;
}

static gpointer pal_rpc_worker(gpointer data) {
    PaletteRpcJob *j = data;
    j->resp = orb_locald_rpc_post(j->port, j->token, j->body);
    return g_idle_add(pal_rpc_done, j), NULL;
}

static void pal_rpc_dispatch(OrbPalette *p) {
    if (p->closed || !p->open || p->inflight > 0) return;
    char *q = orb_json_escape_string(p->query->str);
    if (!q) { p->pending_enter = FALSE; p->applied_gen = p->req_gen; return; }
    PaletteRpcJob *j = g_new0(PaletteRpcJob, 1);
    j->p = p; j->port = p->port; j->gen = p->req_gen;
    snprintf(j->token, sizeof(j->token), "%s", p->token);
    j->body = g_strdup_printf("{\"command\":\"native_chrome_palette_query\",\"args\":{\"query\":%s,\"limit\":%d}}",
                              q, ORB_PALETTE_MAX_ITEMS);
    free(q);
    p->inflight = 1;
    GThread *th = g_thread_try_new("orb-pal-rpc", pal_rpc_worker, j, NULL);
    if (!th) {
        p->inflight = 0; p->dirty = FALSE; p->pending_enter = FALSE; p->applied_gen = p->req_gen;
        g_free(j->body); g_free(j);
        return;
    }
    g_thread_unref(th);
}

void orb_pal_query(OrbPalette *p) {
    if (p->closed || !p->open) return;
    p->req_gen++;
    p->pending_enter = FALSE;
    if (p->inflight > 0) { p->dirty = TRUE; return; }
    p->dirty = FALSE;
    pal_rpc_dispatch(p);
}
