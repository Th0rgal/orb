/* linux_shell/gtk_leanui_palette.c — Native LeanUI Search / Quick-Jump Palette overlay (<= 220 LOC). */
#include "gtk_leanui_palette_private.h"
#include <string.h>

static void pal_clear_prev_focus(OrbPalette *p) {
    if (!p->prev_focus) return;
    g_object_remove_weak_pointer(G_OBJECT(p->prev_focus), (gpointer *)&p->prev_focus);
    p->prev_focus = NULL;
}

void orb_pal_close(OrbPalette *p, gboolean restore_prev) {
    if (!p->open) return;
    p->open = FALSE; p->dirty = FALSE; p->pending_enter = FALSE; p->scroll_acc = 0.0;
    p->hit_count = 0; p->has_card = 0; p->req_gen++; p->applied_gen = p->req_gen;
    orb_pal_clear_items(p);
    GdkWindow *gw = gtk_widget_get_window(p->canvas);
    if (gw) gdk_window_set_cursor(gw, NULL);
    gtk_widget_hide(p->canvas);
    GtkWidget *target = (restore_prev && p->prev_focus && gtk_widget_get_visible(p->prev_focus) &&
                         gtk_widget_get_mapped(p->prev_focus) && gtk_widget_get_can_focus(p->prev_focus))
                            ? p->prev_focus : p->wv;
    pal_clear_prev_focus(p);
    if (target) gtk_widget_grab_focus(target);
}

void orb_pal_activate(OrbPalette *p, int idx) {
    if (idx < 0 || idx >= p->count) return;
    char *kind = g_strdup(p->items[idx].kind), *target = g_strdup(p->items[idx].target);
    orb_pal_close(p, FALSE);
    if (target && *target && p->action) p->action(p->chrome, kind, target);
    g_free(kind); g_free(target);
}

void orb_leanui_palette_open(GtkWidget *overlay) {
    OrbPalette *p = overlay ? g_object_get_data(G_OBJECT(overlay), "orb-palette") : NULL;
    if (!p || p->closed) return;
    if (!p->open) {
        pal_clear_prev_focus(p);
        GtkWidget *top = p->overlay ? gtk_widget_get_toplevel(p->overlay) : NULL;
        GtkWidget *foc = (top && GTK_IS_WINDOW(top)) ? gtk_window_get_focus(GTK_WINDOW(top)) : NULL;
        if (foc && foc != p->canvas) {
            p->prev_focus = foc;
            g_object_add_weak_pointer(G_OBJECT(p->prev_focus), (gpointer *)&p->prev_focus);
        }
    }
    g_string_truncate(p->query, 0); orb_pal_clear_items(p);
    p->selected = 0; p->hit_count = 0; p->has_card = 0; p->scroll_acc = 0.0;
    p->pending_enter = FALSE; p->dirty = FALSE;
    p->req_gen++; p->applied_gen = p->req_gen; p->open = TRUE;
    gtk_widget_show(p->canvas); gtk_widget_grab_focus(p->canvas);
    orb_pal_query(p); orb_pal_invalidate(p);
}

void orb_leanui_palette_theme(GtkWidget *overlay, gboolean light) {
    OrbPalette *p = overlay ? g_object_get_data(G_OBJECT(overlay), "orb-palette") : NULL;
    if (!p || p->closed) return;
    if (p->light != light) { p->light = light; orb_pal_invalidate(p); }
}

static void pal_paste_cb(GtkClipboard *cb, const gchar *text, gpointer ud) {
    (void)cb; GtkWidget *overlay = ud;
    OrbPalette *p = g_object_get_data(G_OBJECT(overlay), "orb-palette");
    if (p && !p->closed && p->open && text && *text && p->query->len < 256) {
        char clean[257];
        orb_palette_sanitize(text, clean, (256 - p->query->len) + 1);
        if (*clean) { g_string_append(p->query, clean); orb_pal_query(p); orb_pal_invalidate(p); }
    }
    g_object_unref(overlay);
}

static void pal_paste(OrbPalette *p) {
    if (!p->overlay) return;
    GtkClipboard *cb = gtk_clipboard_get_for_display(gtk_widget_get_display(p->canvas), GDK_SELECTION_CLIPBOARD);
    if (!cb) return;
    g_object_ref(p->overlay);
    gtk_clipboard_request_text(cb, pal_paste_cb, p->overlay);
}

gboolean orb_leanui_palette_key(GtkWidget *overlay, GdkEventKey *ev) {
    OrbPalette *p = overlay ? g_object_get_data(G_OBJECT(overlay), "orb-palette") : NULL;
    if (!p || p->closed || (!p->open && gtk_grab_get_current() != NULL)) return FALSE;
    guint mod = ev->state & gtk_accelerator_get_default_mod_mask(), key = gdk_keyval_to_lower(ev->keyval);
    gboolean ctrl = (mod & GDK_CONTROL_MASK) != 0;
    gboolean super = ((mod & (GDK_SUPER_MASK | GDK_META_MASK)) != 0) || ((ev->state & GDK_MOD4_MASK) != 0);
    gboolean primary = (ctrl != super) && !(mod & GDK_MOD1_MASK);
    gboolean exclusive_primary = primary && !(mod & GDK_SHIFT_MASK);
    gboolean primary_shift = primary && ((mod & GDK_SHIFT_MASK) != 0);
    if (primary_shift && key == GDK_KEY_f) {
        if (p->open) orb_pal_close(p, TRUE); else orb_leanui_palette_open(overlay);
        return TRUE;
    }
    if (!p->open) return FALSE;
    if (ev->is_modifier) return TRUE;
    if (ev->keyval == GDK_KEY_Escape) return orb_pal_close(p, TRUE), TRUE;
    if (ev->keyval == GDK_KEY_Return || ev->keyval == GDK_KEY_KP_Enter) {
        if (p->applied_gen != p->req_gen) p->pending_enter = TRUE; else orb_pal_activate(p, p->selected);
        return TRUE;
    }
    if (exclusive_primary && key == GDK_KEY_v) return pal_paste(p), TRUE;
    if (ev->keyval == GDK_KEY_Up || ev->keyval == GDK_KEY_KP_Up) {
        p->pending_enter = FALSE;
        if (p->count > 0) { p->selected = (p->selected + p->count - 1) % p->count; orb_pal_invalidate(p); }
        return TRUE;
    }
    if (ev->keyval == GDK_KEY_Down || ev->keyval == GDK_KEY_KP_Down) {
        p->pending_enter = FALSE;
        if (p->count > 0) { p->selected = (p->selected + 1) % p->count; orb_pal_invalidate(p); }
        return TRUE;
    }
    if (ev->keyval == GDK_KEY_Home || ev->keyval == GDK_KEY_End) {
        p->pending_enter = FALSE;
        if (p->count > 0) { p->selected = ev->keyval == GDK_KEY_Home ? 0 : p->count - 1; orb_pal_invalidate(p); }
        return TRUE;
    }
    if (ev->keyval == GDK_KEY_BackSpace || (exclusive_primary && key == GDK_KEY_u)) {
        if (ctrl || super) g_string_truncate(p->query, 0);
        else if (p->query->len > 0) {
            const char *prev = g_utf8_find_prev_char(p->query->str, p->query->str + p->query->len);
            g_string_truncate(p->query, prev ? (gsize)(prev - p->query->str) : 0);
        }
        return orb_pal_query(p), orb_pal_invalidate(p), TRUE;
    }
    guint32 uc = (!(ctrl || super) && !(mod & GDK_MOD1_MASK)) ? gdk_keyval_to_unicode(ev->keyval) : 0;
    if (uc >= 0x20 && uc != 0x7F && p->query->len < 256) {
        g_string_append_unichar(p->query, uc); orb_pal_query(p); orb_pal_invalidate(p);
    }
    return TRUE;
}

static gboolean on_draw(GtkWidget *w, cairo_t *cr, OrbPalette *p) {
    (void)w; if (p->surface) { cairo_set_source_surface(cr, p->surface, 0, 0); cairo_paint(cr); } return TRUE;
}
static void on_alloc(GtkWidget *w, GtkAllocation *a, OrbPalette *p) {
    int sc = gtk_widget_get_scale_factor(w);
    if (p->width == a->width && p->height == a->height && p->scale == sc) return;
    p->width = a->width; p->height = a->height; p->scale = sc; orb_pal_invalidate(p);
}
static void on_scale(GtkWidget *w, GParamSpec *sp, OrbPalette *p) {
    (void)sp; GtkAllocation a; gtk_widget_get_allocation(w, &a); on_alloc(w, &a, p);
}
static gboolean on_motion(GtkWidget *w, GdkEventMotion *ev, OrbPalette *p) {
    int hit = orb_palette_hit_item(p->hits, p->hit_count, (int)ev->x, (int)ev->y);
    GdkWindow *gw = gtk_widget_get_window(w);
    if (gw) {
        GdkCursor *cur = hit >= 0 ? gdk_cursor_new_from_name(gdk_window_get_display(gw), "pointer") : NULL;
        gdk_window_set_cursor(gw, cur); if (cur) g_object_unref(cur);
    }
    if (hit >= 0 && hit < p->count && hit != p->selected) { p->pending_enter = FALSE; p->selected = hit; orb_pal_invalidate(p); }
    return TRUE;
}
static gboolean on_press(GtkWidget *w, GdkEventButton *ev, OrbPalette *p) {
    (void)w; if (ev->button != GDK_BUTTON_PRIMARY) return TRUE;
    int hit = orb_palette_hit_item(p->hits, p->hit_count, (int)ev->x, (int)ev->y);
    if (hit >= 0 && hit < p->count) orb_pal_activate(p, hit);
    else if (!p->has_card || !orb_palette_rect_contains(&p->card, (int)ev->x, (int)ev->y)) orb_pal_close(p, TRUE);
    return TRUE;
}
static gboolean on_scroll(GtkWidget *w, GdkEventScroll *ev, OrbPalette *p) {
    (void)w; if (!p->open || p->closed || p->count <= 0) return TRUE;
    double dx = 0.0, dy = 0.0;
    if (!gdk_event_get_scroll_deltas((GdkEvent *)ev, &dx, &dy))
        dy = ev->direction == GDK_SCROLL_DOWN ? 1.0 : ev->direction == GDK_SCROLL_UP ? -1.0 : 0.0;
    if (dy == 0.0) return TRUE;
    p->scroll_acc += dy;
    int steps = (int)p->scroll_acc;
    if (steps != 0) {
        p->scroll_acc -= (double)steps;
        int next = CLAMP(p->selected + steps, 0, p->count - 1);
        p->pending_enter = FALSE;
        if (next != p->selected) { p->selected = next; orb_pal_invalidate(p); }
    }
    return TRUE;
}
static void on_destroy(GtkWidget *w, OrbPalette *p) {
    (void)w; if (p->closed) return;
    if (p->idle) { g_source_remove(p->idle); p->idle = 0; }
    pal_clear_prev_focus(p);
    if (p->wv) { g_object_remove_weak_pointer(G_OBJECT(p->wv), (gpointer *)&p->wv); p->wv = NULL; }
    if (p->overlay) {
        g_object_set_data(G_OBJECT(p->overlay), "orb-palette", NULL);
        g_object_remove_weak_pointer(G_OBJECT(p->overlay), (gpointer *)&p->overlay);
        p->overlay = NULL;
    }
    p->closed = TRUE; p->open = FALSE; p->dirty = FALSE; p->pending_enter = FALSE;
    orb_pal_try_free(p);
}

GtkWidget *orb_leanui_palette_new(GtkWidget *base, GtkWidget *wv, unsigned port, const char *token,
                                  OrbSidebarAction action, gpointer chrome) {
    OrbPalette *p = g_new0(OrbPalette, 1); p->overlay = gtk_overlay_new(); p->canvas = gtk_drawing_area_new();
    p->wv = wv; p->port = port; p->action = action; p->chrome = chrome; p->jsc = jsc_context_new();
    p->query = g_string_sized_new(64); p->scale = 1; snprintf(p->token, sizeof(p->token), "%s", token ? token : "");
    gtk_container_add(GTK_CONTAINER(p->overlay), base); gtk_overlay_add_overlay(GTK_OVERLAY(p->overlay), p->canvas);
    gtk_widget_set_no_show_all(p->canvas, TRUE); gtk_widget_set_can_focus(p->canvas, TRUE);
    gtk_widget_add_events(p->canvas, GDK_BUTTON_PRESS_MASK | GDK_POINTER_MOTION_MASK | GDK_SCROLL_MASK | GDK_SMOOTH_SCROLL_MASK);
    g_object_set_data(G_OBJECT(p->overlay), "orb-palette", p);
    g_object_add_weak_pointer(G_OBJECT(p->overlay), (gpointer *)&p->overlay);
    if (p->wv) g_object_add_weak_pointer(G_OBJECT(p->wv), (gpointer *)&p->wv);
    g_signal_connect(p->canvas, "draw", G_CALLBACK(on_draw), p);
    g_signal_connect(p->canvas, "size-allocate", G_CALLBACK(on_alloc), p);
    g_signal_connect(p->canvas, "notify::scale-factor", G_CALLBACK(on_scale), p);
    g_signal_connect_swapped(p->canvas, "map", G_CALLBACK(orb_pal_invalidate), p);
    g_signal_connect(p->canvas, "motion-notify-event", G_CALLBACK(on_motion), p);
    g_signal_connect(p->canvas, "button-press-event", G_CALLBACK(on_press), p);
    g_signal_connect(p->canvas, "scroll-event", G_CALLBACK(on_scroll), p);
    g_signal_connect(p->canvas, "destroy", G_CALLBACK(on_destroy), p);
    return p->overlay;
}
