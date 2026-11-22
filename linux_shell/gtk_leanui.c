#include "gtk_leanui_private.h"
#include "gtk_icons.h"
#include <math.h>
#include <stdlib.h>

static OrbSidebarPaint paint;
static void *renderer;

extern int orb_gtk_main(int argc, char **argv);
int orb_sidebar_host(OrbSidebarPaint callback, void *context) {
    char name[] = "orb-desktop";
    char *args[] = {name, NULL};
    paint = callback;
    renderer = context;
    return orb_gtk_main(1, args);
}

static gboolean update(gpointer data) {
    OrbSidebar *s = data;
    s->idle = 0;
    if (s->width < 2 || s->height < 2 || !gtk_widget_get_mapped(s->overlay)) return G_SOURCE_REMOVE;
    int w = s->width * s->scale, h = s->height * s->scale;
    if (!s->surface || cairo_image_surface_get_width(s->surface) != w || cairo_image_surface_get_height(s->surface) != h) {
        if (s->surface) cairo_surface_destroy(s->surface);
        s->surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, w, h);
    }
    if (cairo_surface_status(s->surface) != CAIRO_STATUS_SUCCESS) return G_SOURCE_REMOVE;
    guint phase = (guint)(g_get_monotonic_time() / 100000 % 12);
    char *request = g_strdup_printf("%d\t%d\t%d\t%d\t%d\t%u\n%s",
        s->width, s->height, s->scale, s->light, s->scroll, phase, s->rows->str);
    cairo_surface_flush(s->surface);
    if (paint(renderer, request, cairo_image_surface_get_data(s->surface), (size_t)w*h*4, orb_sidebar_hits, s)) {
        cairo_surface_set_device_scale(s->surface, s->scale, s->scale);
        cairo_surface_mark_dirty(s->surface);
        gtk_widget_queue_draw(s->canvas);
    }
    g_free(request);
    return G_SOURCE_REMOVE;
}

void orb_sidebar_invalidate(OrbSidebar *s) {
    if (!s->idle) s->idle = g_idle_add_full(G_PRIORITY_HIGH_IDLE, update, s, NULL);
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
static gboolean draw(GtkWidget *widget, cairo_t *cr, OrbSidebar *s) {
    (void)widget;
    if (s->surface) {
        cairo_set_source_surface(cr, s->surface, 0, 0);
        cairo_paint(cr);
    }
    return TRUE;
}
static gboolean canvas_press(GtkWidget *widget, GdkEventButton *event, gpointer data) {
    (void)data;
    if (event->button != GDK_BUTTON_PRIMARY || event->y >= 35) return FALSE;
    return orb_gtk_begin_window_drag(gtk_widget_get_toplevel(widget)), TRUE;
}
static gboolean scroll(GtkWidget *widget, GdkEventScroll *event, OrbSidebar *s) {
    (void)widget;
    double dx, dy;
    if (!gdk_event_get_scroll_deltas((GdkEvent *)event, &dx, &dy))
        dy = event->direction == GDK_SCROLL_DOWN ? 1 : event->direction == GDK_SCROLL_UP ? -1 : 0;
    int next = CLAMP(s->scroll + (int)round(dy * 34), 0, s->limit);
    if (next == s->scroll) return FALSE;
    s->scroll = next;
    orb_sidebar_invalidate(s);
    return TRUE;
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
    if (s->animation) g_source_remove(s->animation);
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
        ".orb-leanui > button {background:transparent;border:1px solid transparent;"
        "box-shadow:none;outline:none;min-width:0;min-height:0;margin:0;padding:0;}"
        ".orb-leanui > button:hover,.orb-leanui > button.orb-multi {background:rgba(140,140,140,.12);}"
        ".orb-keyboard-focus .orb-leanui > button:focus {border-color:#757575;}", -1, NULL);
    gtk_style_context_add_provider_for_screen(gtk_widget_get_screen(webview), GTK_STYLE_PROVIDER(css),
                                              GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
    g_object_unref(css);
    gtk_widget_add_events(s->canvas, GDK_BUTTON_PRESS_MASK);
    g_signal_connect(s->canvas, "button-press-event", G_CALLBACK(canvas_press), NULL);
    gtk_widget_add_events(s->overlay, GDK_SCROLL_MASK | GDK_SMOOTH_SCROLL_MASK);
    g_signal_connect(s->overlay, "scroll-event", G_CALLBACK(scroll), s);
    g_signal_connect(s->overlay, "get-child-position", G_CALLBACK(position), NULL);
    g_signal_connect(s->overlay, "size-allocate", G_CALLBACK(allocate), s);
    g_signal_connect(s->overlay, "notify::scale-factor", G_CALLBACK(scale_changed), s);
    g_signal_connect(s->overlay, "map", G_CALLBACK(mapped), s);
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
    OrbSidebar *s = g_object_get_data(G_OBJECT(view), "orb-sidebar");
    s->can_back = back; s->can_forward = forward;
    GtkWidget *prev = g_hash_table_lookup(s->buttons, "tool/back");
    GtkWidget *next = g_hash_table_lookup(s->buttons, "tool/forward");
    if (prev) gtk_widget_set_sensitive(prev, back);
    if (next) gtk_widget_set_sensitive(next, forward);
}
