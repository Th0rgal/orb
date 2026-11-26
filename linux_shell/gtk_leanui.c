#include "gtk_leanui_private.h"
#include "gtk_icons.h"
#include <inttypes.h>
#include <math.h>
#include <stdlib.h>

static OrbSidebarPaint paint;
static void *renderer;
static void detach_gpu(OrbSidebar *s) {
    if (s->wl.surface && paint) {
        char req[64];
        snprintf(req, sizeof(req), "D\t%" PRIuPTR, (uintptr_t)s->wl.surface);
        paint(renderer, req, NULL, 0, NULL, NULL);
    }
    orb_wl_subsurface_detach(&s->wl);
    s->gpu_active = FALSE;
}

int orb_leanui_paint(const char *request, uint8_t *argb, size_t capacity,
                     OrbSidebarHits hits, void *view) {
    return paint ? paint(renderer, request, argb, capacity, hits, view) : 0;
}

extern int orb_gtk_main(int argc, char **argv);
int orb_sidebar_host(OrbSidebarPaint callback, void *context) {
    char name[] = "orb-desktop";
    char *args[] = {name, NULL};
    paint = callback;
    renderer = context;
    return orb_gtk_main(1, args);
}

static gboolean render_frame(OrbSidebar *s) {
    if (s->width < 2 || s->height < 2 || !gtk_widget_get_mapped(s->overlay)) return FALSE;
    guint phase = (guint)(g_get_monotonic_time() / 16667 % 60);
    gboolean moved = FALSE;
    if (!s->gpu_disabled && orb_wl_subsurface_ensure(&s->wl, s->canvas, &moved)) {
        char *req = g_strdup_printf("%d\t%d\t%d\t%d\t%d\t%u\t%" PRIuPTR "\t%" PRIuPTR "\n%s",
            s->width, s->height, s->scale, s->light, s->scroll, phase,
            (uintptr_t)s->wl.display, (uintptr_t)s->wl.surface, s->rows->str);
        int rc = paint(renderer, req, NULL, 0, orb_sidebar_hits, s);
        g_free(req);
        if (rc == 2) {
            if (!s->gpu_active || moved) {
                s->gpu_active = TRUE;
                if (s->surface) { cairo_surface_destroy(s->surface); s->surface = NULL; }
                gtk_widget_queue_draw(s->canvas);
            }
            return FALSE;
        }
        if (rc == 0) return TRUE;
        s->gpu_disabled = TRUE;
        detach_gpu(s);
    }
    int w = s->width * s->scale, h = s->height * s->scale;
    if (!s->surface || cairo_image_surface_get_width(s->surface) != w || cairo_image_surface_get_height(s->surface) != h) {
        if (s->surface) cairo_surface_destroy(s->surface);
        s->surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, w, h);
    }
    if (cairo_surface_status(s->surface) != CAIRO_STATUS_SUCCESS) return FALSE;
    char *request = g_strdup_printf("%d\t%d\t%d\t%d\t%d\t%u\n%s",
        s->width, s->height, s->scale, s->light, s->scroll, phase, s->rows->str);
    cairo_surface_flush(s->surface);
    if (paint(renderer, request, cairo_image_surface_get_data(s->surface), (size_t)w*h*4, orb_sidebar_hits, s) > 0) {
        cairo_surface_set_device_scale(s->surface, s->scale, s->scale);
        cairo_surface_mark_dirty(s->surface);
        gtk_widget_queue_draw(s->canvas);
    }
    return g_free(request), FALSE;
}

static gboolean update(gpointer data) {
    OrbSidebar *s = data;
    s->idle = 0;
    if (render_frame(s)) orb_sidebar_invalidate(s);
    return G_SOURCE_REMOVE;
}

static gboolean on_tick(GtkWidget *widget, GdkFrameClock *clock, gpointer data) {
    (void)widget; (void)clock;
    OrbSidebar *s = data;
    gboolean more = orb_sidebar_kinetic_step(s);
    if (render_frame(s) || more) return G_SOURCE_CONTINUE;
    s->tick = 0; s->kinetic_ts = 0;
    return G_SOURCE_REMOVE;
}

void orb_sidebar_invalidate(OrbSidebar *s) {
    if (s->tick || s->idle) return;
    if (gtk_widget_get_mapped(s->canvas) && gtk_widget_get_frame_clock(s->canvas))
        s->tick = gtk_widget_add_tick_callback(s->canvas, on_tick, s, NULL);
    else
        s->idle = g_idle_add_full(G_PRIORITY_DEFAULT_IDLE, update, s, NULL);
}
static void mapped(GtkWidget *widget, OrbSidebar *s) {
    (void)widget;
    orb_sidebar_invalidate(s);
}
static void allocate(GtkWidget *widget, GtkAllocation *a, OrbSidebar *s) {
    int scale = gtk_widget_get_scale_factor(widget);
    if (s->width == a->width && s->height == a->height && s->scale == scale) return;
    s->width = a->width;
    s->height = a->height;
    s->scale = scale;
    orb_sidebar_invalidate(s);
}
static void scale_changed(GtkWidget *widget, GParamSpec *spec, OrbSidebar *s) {
    (void)spec;
    GtkAllocation a;
    gtk_widget_get_allocation(widget, &a);
    allocate(widget, &a, s);
}
static void unmapped(GtkWidget *widget, OrbSidebar *s) {
    (void)widget;
    detach_gpu(s);
}
static gboolean draw(GtkWidget *widget, cairo_t *cr, OrbSidebar *s) {
    (void)widget;
    if (s->gpu_active) return orb_wl_subsurface_draw_mask(cr, s->width, s->height, s->light), TRUE;
    if (s->surface) { cairo_set_source_surface(cr, s->surface, 0, 0); cairo_paint(cr); }
    return TRUE;
}
static gboolean canvas_press(GtkWidget *widget, GdkEventButton *event, gpointer data) {
    (void)data;
    if (event->button != GDK_BUTTON_PRIMARY || event->y >= 35) return FALSE;
    return orb_gtk_begin_window_drag(gtk_widget_get_toplevel(widget)), TRUE;
}
static gboolean position(GtkOverlay *overlay, GtkWidget *child, GdkRectangle *rect, gpointer unused) {
    (void)overlay; (void)unused;
    GdkRectangle *hit = g_object_get_data(G_OBJECT(child), "orb-hit");
    if (!hit) return FALSE;
    *rect = *hit;
    return TRUE;
}
static void destroy(GtkWidget *widget, OrbSidebar *s) {
    (void)widget;
    if (s->idle) g_source_remove(s->idle);
    if (s->tick) gtk_widget_remove_tick_callback(s->canvas, s->tick);
    if (s->animation) g_source_remove(s->animation);
    if (s->fade) g_source_remove(s->fade);
    detach_gpu(s);
    if (s->surface) cairo_surface_destroy(s->surface);
    orb_sidebar_model_free(s);
    g_free(s);
}

GtkWidget *orb_leanui_new(GtkWidget *webview, OrbSidebarAction action, gpointer chrome) {
    OrbSidebar *s = g_new0(OrbSidebar, 1);
    s->overlay = gtk_overlay_new();
    s->canvas = gtk_drawing_area_new();
    s->rows = g_string_new("");
    s->buttons = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, NULL);
    s->indices = g_ptr_array_new();
    s->wv = webview; s->action = action; s->chrome = chrome;
    gtk_container_add(GTK_CONTAINER(s->overlay), s->canvas);
    gtk_style_context_add_class(gtk_widget_get_style_context(s->overlay), "orb-leanui");
    g_object_set_data(G_OBJECT(s->overlay), "orb-sidebar", s);
    /* GTK supplies focus, ATK names and input. Only transient input feedback is painted here. */
    GtkCssProvider *css = gtk_css_provider_new();
    gtk_css_provider_load_from_data(css,
        ".orb-leanui > button {background:transparent;border:none;border-radius:6px;"
        "box-shadow:none;outline:none;min-width:0;min-height:0;margin:0;padding:0;}"
        ".orb-leanui > button:hover,.orb-leanui > button.orb-multi {background:transparent;}"
        ".orb-keyboard-focus .orb-leanui > button:focus {border-color:transparent;}", -1, NULL);
    gtk_style_context_add_provider_for_screen(gtk_widget_get_screen(webview), GTK_STYLE_PROVIDER(css),
                                              GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
    g_object_unref(css);
    gtk_widget_add_events(s->canvas, GDK_BUTTON_PRESS_MASK);
    g_signal_connect(s->canvas, "button-press-event", G_CALLBACK(canvas_press), NULL);
    gtk_widget_add_events(s->overlay, GDK_SCROLL_MASK | GDK_SMOOTH_SCROLL_MASK);
    g_signal_connect(s->overlay, "scroll-event", G_CALLBACK(orb_sidebar_scroll_event), s);
    g_signal_connect(s->overlay, "get-child-position", G_CALLBACK(position), NULL);
    g_signal_connect(s->overlay, "size-allocate", G_CALLBACK(allocate), s);
    g_signal_connect(s->overlay, "notify::scale-factor", G_CALLBACK(scale_changed), s);
    g_signal_connect(s->overlay, "map", G_CALLBACK(mapped), s);
    g_signal_connect(s->overlay, "unmap", G_CALLBACK(unmapped), s);
    g_signal_connect(s->overlay, "destroy", G_CALLBACK(destroy), s);
    g_signal_connect(s->canvas, "draw", G_CALLBACK(draw), s);
    gtk_widget_set_size_request(s->overlay, 160, -1);
    return s->overlay;
}
void orb_leanui_theme(GtkWidget *view, gboolean light) {
    OrbSidebar *s = g_object_get_data(G_OBJECT(view), "orb-sidebar");
    if (s->light != light) { s->light = light; orb_sidebar_invalidate(s); }
}
void orb_leanui_history(GtkWidget *view, gboolean back, gboolean forward) {
    OrbSidebar *s = g_object_get_data(G_OBJECT(view), "orb-sidebar"); s->can_back = back; s->can_forward = forward;
    GtkWidget *prev = g_hash_table_lookup(s->buttons, "tool/back"), *next = g_hash_table_lookup(s->buttons, "tool/forward");
    if (prev) gtk_widget_set_sensitive(prev, back);
    if (next) gtk_widget_set_sensitive(next, forward);
}
void orb_leanui_optimistic(GtkWidget *view, const char *kind, const char *target, const char *ren_title) {
    OrbSidebar *s = view ? g_object_get_data(G_OBJECT(view), "orb-sidebar") : NULL;
    if (!s || !s->rows->len || !target || !*target) return;
    g_autofree char *sel = NULL, *clean = ren_title ? g_strdup(ren_title) : NULL, *ren_id = NULL;
    if (clean) { g_strdelimit(clean, "\t\r\n", ' '); ren_id = g_str_has_prefix(target, "m:") ? g_strdup(target) : g_strdup_printf("m:%s", target); }
    else if (kind && !g_strcmp0(kind, "mission")) sel = g_str_has_prefix(target, "m:") ? g_strdup(target) : g_strdup_printf("m:%s", target);
    else if (kind && !g_strcmp0(kind, "file")) sel = g_strdup(target);
    else if (kind && !g_strcmp0(kind, "footer") && !g_strcmp0(target, "settings")) sel = g_strdup("nav:settings");
    else if (kind && !g_strcmp0(kind, "project")) sel = g_strdup("nav:new-agent");
    else if (kind && !g_strcmp0(kind, "nav")) {
        if (!g_strcmp0(target, "new-agent") || g_str_has_prefix(target, "new-agent:")) sel = g_strdup("nav:new-agent");
        else if (!g_strcmp0(target, "inbox") || !g_strcmp0(target, "cloud-agent") || !g_strcmp0(target, "machines") || !g_strcmp0(target, "providers") || !g_strcmp0(target, "resources")) sel = g_strdup_printf("nav:%s", target);
        else if (!g_strcmp0(target, "settings") || !g_strcmp0(target, "routing") || !g_strcmp0(target, "skills-settings") || !g_strcmp0(target, "security-settings") || !g_strcmp0(target, "inbox-settings"))
            sel = g_strdup(!g_strcmp0(target, "settings") ? "settings:account" : !g_strcmp0(target, "routing") ? "settings:models" : !g_strcmp0(target, "skills-settings") ? "settings:agents" : !g_strcmp0(target, "security-settings") ? "settings:security" : "settings:notifications");
    }
    if (!clean && !sel) return;
    g_auto(GStrv) lines = g_strsplit(s->rows->str, "\n", -1); GString *next = g_string_sized_new(s->rows->len + 64); gboolean changed = FALSE;
    for (char **ln = lines; *ln; ++ln) {
        if (!**ln) continue;
        g_auto(GStrv) c = g_strsplit(*ln, "\t", 11);
        if (g_strv_length(c) == 11) {
            const char *nt = (clean && (!g_strcmp0(c[1], target) || !g_strcmp0(c[1], ren_id))) ? clean : c[3], *ns = sel ? (!g_strcmp0(c[1], sel) ? "1" : "0") : c[8];
            if (g_strcmp0(nt, c[3]) || g_strcmp0(ns, c[8])) changed = TRUE;
            g_string_append_printf(next, "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", c[0], c[1], c[2], nt, c[4], c[5], c[6], c[7], ns, c[9], c[10]);
        } else g_string_append_printf(next, "%s\n", *ln);
    }
    if (changed) { g_string_assign(s->rows, next->str); orb_sidebar_invalidate(s); }
    g_string_free(next, TRUE);
}
