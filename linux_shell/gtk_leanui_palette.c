/* linux_shell/gtk_leanui_palette.c — Native LeanUI Search / Quick-Jump Palette overlay (<= 220 LOC). */
#include "gtk_leanui_private.h"
#include "gtk_leanui_palette.h"
#include "gtk_chrome.h"
#include <stdlib.h>
#include <string.h>

typedef struct { char *id, *kind, *title, *subtitle, *target, *status, *shortcut; } OrbPaletteItem;
typedef struct {
    GtkWidget *overlay, *canvas, *wv;
    OrbSidebarAction action; gpointer chrome; JSCContext *jsc;
    unsigned port; char token[128]; GString *query;
    OrbPaletteItem items[ORB_PALETTE_MAX_ITEMS];
    OrbPaletteHit hits[ORB_PALETTE_MAX_ITEMS], card;
    size_t hit_count; int count, selected, has_card, width, height, scale, inflight;
    guint64 req_gen, applied_gen; cairo_surface_t *surface; guint idle;
    gboolean open, light, closed;
} OrbPalette;
typedef struct { OrbPalette *p; unsigned port; char token[128], *body, *resp; guint64 gen; } PaletteRpcJob;

static char *pal_str(JSCValue *obj, const char *key) {
    JSCValue *v = jsc_value_object_get_property(obj, key);
    char *out = (v && jsc_value_is_string(v)) ? jsc_value_to_string(v) : g_strdup("");
    if (v) g_object_unref(v);
    return out;
}
static void pal_clear_items(OrbPalette *p) {
    for (int i = 0; i < p->count; ++i) {
        g_free(p->items[i].id); g_free(p->items[i].kind); g_free(p->items[i].title); g_free(p->items[i].subtitle);
        g_free(p->items[i].target); g_free(p->items[i].status); g_free(p->items[i].shortcut);
    }
    memset(p->items, 0, sizeof(p->items)); p->count = 0;
}
static void pal_try_free(OrbPalette *p) {
    if (!p->closed || p->inflight > 0) return;
    pal_clear_items(p);
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
    OrbPalette *p = data; p->idle = 0;
    if (p->closed || !p->open || p->width < 2 || p->height < 2 || !gtk_widget_get_mapped(p->canvas)) return G_SOURCE_REMOVE;
    int scale = p->scale > 0 ? p->scale : 1, w = p->width * scale, h = p->height * scale;
    if (!p->surface || cairo_image_surface_get_width(p->surface) != w || cairo_image_surface_get_height(p->surface) != h) {
        if (p->surface) cairo_surface_destroy(p->surface);
        p->surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, w, h);
    }
    if (cairo_surface_status(p->surface) != CAIRO_STATUS_SUCCESS) return G_SOURCE_REMOVE;
    GString *req = g_string_sized_new(1024); char buf[1024];
    int n = orb_palette_format_header(buf, sizeof(buf), p->width, p->height, scale, p->light, p->selected, p->query->str);
    if (n > 0) g_string_append_len(req, buf, n);
    for (int i = 0; i < p->count; ++i) {
        OrbPaletteItem *it = &p->items[i];
        n = orb_palette_format_item(buf, sizeof(buf), (unsigned)i, it->id, it->kind, it->title, it->subtitle, it->status, it->shortcut);
        if (n > 0) g_string_append_len(req, buf, n);
    }
    cairo_surface_flush(p->surface);
    if (orb_leanui_paint(req->str, cairo_image_surface_get_data(p->surface), (size_t)w * (size_t)h * 4, pal_hits_cb, p)) {
        cairo_surface_set_device_scale(p->surface, scale, scale);
        cairo_surface_mark_dirty(p->surface); gtk_widget_queue_draw(p->canvas);
    }
    g_string_free(req, TRUE);
    return G_SOURCE_REMOVE;
}
static void pal_invalidate(OrbPalette *p) {
    if (!p->closed && p->open && !p->idle) p->idle = g_idle_add_full(G_PRIORITY_HIGH_IDLE, pal_paint, p, NULL);
}
static gboolean pal_rpc_done(gpointer data) {
    PaletteRpcJob *j = data; OrbPalette *p = j->p; p->inflight--;
    if (!p->closed && j->gen >= p->applied_gen && j->resp) {
        JSCValue *root = jsc_value_new_from_json(p->jsc, j->resp);
        JSCValue *res = (root && jsc_value_is_object(root)) ? jsc_value_object_get_property(root, "result") : NULL;
        JSCValue *arr = (res && jsc_value_is_object(res)) ? jsc_value_object_get_property(res, "items") : NULL;
        if (arr && jsc_value_is_array(arr)) {
            JSCValue *lv = jsc_value_object_get_property(arr, "length");
            int len = (lv && jsc_value_is_number(lv)) ? jsc_value_to_int32(lv) : 0;
            if (lv) g_object_unref(lv);
            if (len > ORB_PALETTE_MAX_ITEMS) len = ORB_PALETTE_MAX_ITEMS;
            pal_clear_items(p);
            for (int i = 0; i < len; ++i) {
                JSCValue *it = jsc_value_object_get_property_at_index(arr, (guint)i);
                if (it && jsc_value_is_object(it)) {
                    OrbPaletteItem *d = &p->items[p->count++];
                    d->id = pal_str(it, "id"); d->kind = pal_str(it, "kind"); d->title = pal_str(it, "title");
                    d->subtitle = pal_str(it, "subtitle"); d->target = pal_str(it, "target");
                    d->status = pal_str(it, "status"); d->shortcut = pal_str(it, "shortcut");
                }
                if (it) g_object_unref(it);
            }
            p->applied_gen = j->gen; p->selected = 0; pal_invalidate(p);
        }
        if (arr) g_object_unref(arr);
        if (res) g_object_unref(res);
        if (root) g_object_unref(root);
    }
    g_free(j->body); g_free(j->resp); g_free(j); pal_try_free(p);
    return G_SOURCE_REMOVE;
}
static gpointer pal_rpc_worker(gpointer data) {
    PaletteRpcJob *j = data; j->resp = orb_locald_rpc_post(j->port, j->token, j->body);
    return g_idle_add(pal_rpc_done, j), NULL;
}
static void pal_query(OrbPalette *p) {
    if (p->closed) return;
    char *q = orb_json_escape_string(p->query->str); if (!q) return;
    PaletteRpcJob *j = g_new0(PaletteRpcJob, 1);
    j->p = p; j->port = p->port; j->gen = ++p->req_gen; snprintf(j->token, sizeof(j->token), "%s", p->token);
    j->body = g_strdup_printf("{\"command\":\"native_chrome_palette_query\",\"args\":{\"query\":%s,\"limit\":%d}}", q, ORB_PALETTE_MAX_ITEMS);
    free(q); p->inflight++; g_thread_unref(g_thread_new("orb-pal-rpc", pal_rpc_worker, j));
}
static void pal_close(OrbPalette *p) {
    if (!p->open) return;
    p->open = FALSE; p->hit_count = 0; p->has_card = 0; p->applied_gen = ++p->req_gen; pal_clear_items(p);
    GdkWindow *gw = gtk_widget_get_window(p->canvas); if (gw) gdk_window_set_cursor(gw, NULL);
    gtk_widget_hide(p->canvas);
    if (p->wv) gtk_widget_grab_focus(p->wv);
}
static void pal_activate(OrbPalette *p, int idx) {
    if (idx < 0 || idx >= p->count) return;
    char *kind = g_strdup(p->items[idx].kind), *target = g_strdup(p->items[idx].target);
    pal_close(p);
    if (target && *target && p->action) p->action(p->chrome, kind, target);
    g_free(kind); g_free(target);
}
void orb_leanui_palette_open(GtkWidget *overlay) {
    OrbPalette *p = overlay ? g_object_get_data(G_OBJECT(overlay), "orb-palette") : NULL;
    if (!p || p->closed) return;
    g_string_truncate(p->query, 0); p->selected = 0; p->open = TRUE;
    gtk_widget_show(p->canvas); gtk_widget_grab_focus(p->canvas); pal_query(p); pal_invalidate(p);
}
void orb_leanui_palette_theme(GtkWidget *overlay, gboolean light) {
    OrbPalette *p = overlay ? g_object_get_data(G_OBJECT(overlay), "orb-palette") : NULL;
    if (p && p->light != light) { p->light = light; pal_invalidate(p); }
}
gboolean orb_leanui_palette_key(GtkWidget *overlay, GdkEventKey *ev) {
    OrbPalette *p = overlay ? g_object_get_data(G_OBJECT(overlay), "orb-palette") : NULL;
    if (!p || p->closed) return FALSE;
    guint mod = ev->state & gtk_accelerator_get_default_mod_mask(), key = gdk_keyval_to_lower(ev->keyval);
    gboolean primary = ((mod & (GDK_CONTROL_MASK | GDK_SUPER_MASK | GDK_META_MASK)) != 0) || ((ev->state & GDK_MOD4_MASK) != 0);
    if (primary && !(mod & (GDK_SHIFT_MASK | GDK_MOD1_MASK)) && (key == GDK_KEY_k || key == GDK_KEY_p)) {
        if (p->open) pal_close(p); else orb_leanui_palette_open(overlay);
        return TRUE;
    }
    if (!p->open) return FALSE;
    if (ev->is_modifier) return TRUE;
    if (ev->keyval == GDK_KEY_Escape) return pal_close(p), TRUE;
    if (ev->keyval == GDK_KEY_Return || ev->keyval == GDK_KEY_KP_Enter) return pal_activate(p, p->selected), TRUE;
    if ((ev->keyval == GDK_KEY_Up || ev->keyval == GDK_KEY_KP_Up) && p->count > 0)
        return p->selected = (p->selected + p->count - 1) % p->count, pal_invalidate(p), TRUE;
    if ((ev->keyval == GDK_KEY_Down || ev->keyval == GDK_KEY_KP_Down) && p->count > 0)
        return p->selected = (p->selected + 1) % p->count, pal_invalidate(p), TRUE;
    if (ev->keyval == GDK_KEY_Home && p->count > 0) return p->selected = 0, pal_invalidate(p), TRUE;
    if (ev->keyval == GDK_KEY_End && p->count > 0) return p->selected = p->count - 1, pal_invalidate(p), TRUE;
    if (ev->keyval == GDK_KEY_BackSpace || (primary && key == GDK_KEY_u)) {
        if ((mod & GDK_CONTROL_MASK) || (primary && key == GDK_KEY_u)) g_string_truncate(p->query, 0);
        else if (p->query->len > 0) {
            const char *prev = g_utf8_find_prev_char(p->query->str, p->query->str + p->query->len);
            g_string_truncate(p->query, prev ? (gsize)(prev - p->query->str) : 0);
        }
        return pal_query(p), pal_invalidate(p), TRUE;
    }
    guint32 uc = (!primary && !(mod & GDK_MOD1_MASK)) ? gdk_keyval_to_unicode(ev->keyval) : 0;
    if (uc >= 0x20 && uc != 0x7F && p->query->len < 256) { g_string_append_unichar(p->query, uc); pal_query(p); pal_invalidate(p); }
    return TRUE;
}
static gboolean on_draw(GtkWidget *w, cairo_t *cr, OrbPalette *p) {
    (void)w; if (p->surface) { cairo_set_source_surface(cr, p->surface, 0, 0); cairo_paint(cr); } return TRUE;
}
static void on_alloc(GtkWidget *w, GtkAllocation *a, OrbPalette *p) {
    int sc = gtk_widget_get_scale_factor(w);
    if (p->width == a->width && p->height == a->height && p->scale == sc) return;
    p->width = a->width; p->height = a->height; p->scale = sc; pal_invalidate(p);
}
static void on_scale(GtkWidget *w, GParamSpec *sp, OrbPalette *p) { (void)sp; GtkAllocation a; gtk_widget_get_allocation(w, &a); on_alloc(w, &a, p); }
static gboolean on_motion(GtkWidget *w, GdkEventMotion *ev, OrbPalette *p) {
    int hit = orb_palette_hit_item(p->hits, p->hit_count, (int)ev->x, (int)ev->y);
    GdkWindow *gw = gtk_widget_get_window(w);
    if (gw) {
        GdkCursor *cur = hit >= 0 ? gdk_cursor_new_from_name(gdk_window_get_display(gw), "pointer") : NULL;
        gdk_window_set_cursor(gw, cur); if (cur) g_object_unref(cur);
    }
    if (hit >= 0 && hit < p->count && hit != p->selected) { p->selected = hit; pal_invalidate(p); }
    return TRUE;
}
static gboolean on_press(GtkWidget *w, GdkEventButton *ev, OrbPalette *p) {
    (void)w; if (ev->button != GDK_BUTTON_PRIMARY) return TRUE;
    int hit = orb_palette_hit_item(p->hits, p->hit_count, (int)ev->x, (int)ev->y);
    if (hit >= 0 && hit < p->count) pal_activate(p, hit);
    else if (!p->has_card || !orb_palette_rect_contains(&p->card, (int)ev->x, (int)ev->y)) pal_close(p);
    return TRUE;
}
static void on_destroy(GtkWidget *w, OrbPalette *p) {
    (void)w; if (p->idle) { g_source_remove(p->idle); p->idle = 0; }
    p->closed = TRUE; p->open = FALSE; pal_try_free(p);
}
GtkWidget *orb_leanui_palette_new(GtkWidget *base, GtkWidget *wv, unsigned port, const char *token,
                                  OrbSidebarAction action, gpointer chrome) {
    OrbPalette *p = g_new0(OrbPalette, 1); p->overlay = gtk_overlay_new(); p->canvas = gtk_drawing_area_new();
    p->wv = wv; p->port = port; p->action = action; p->chrome = chrome; p->jsc = jsc_context_new();
    p->query = g_string_sized_new(64); p->scale = 1; snprintf(p->token, sizeof(p->token), "%s", token ? token : "");
    gtk_container_add(GTK_CONTAINER(p->overlay), base); gtk_overlay_add_overlay(GTK_OVERLAY(p->overlay), p->canvas);
    gtk_widget_set_no_show_all(p->canvas, TRUE); gtk_widget_set_can_focus(p->canvas, TRUE);
    gtk_widget_add_events(p->canvas, GDK_BUTTON_PRESS_MASK | GDK_POINTER_MOTION_MASK);
    g_object_set_data(G_OBJECT(p->overlay), "orb-palette", p);
    g_signal_connect(p->canvas, "draw", G_CALLBACK(on_draw), p);
    g_signal_connect(p->canvas, "size-allocate", G_CALLBACK(on_alloc), p);
    g_signal_connect(p->canvas, "notify::scale-factor", G_CALLBACK(on_scale), p);
    g_signal_connect_swapped(p->canvas, "map", G_CALLBACK(pal_invalidate), p);
    g_signal_connect(p->canvas, "motion-notify-event", G_CALLBACK(on_motion), p);
    g_signal_connect(p->canvas, "button-press-event", G_CALLBACK(on_press), p);
    g_signal_connect(p->canvas, "destroy", G_CALLBACK(on_destroy), p);
    return p->overlay;
}
