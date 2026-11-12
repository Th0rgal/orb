/* linux_shell/gtk_icons.c — Cairo sidebar/topbar icons & mission status badges (<= 220 LOC). */
#define _POSIX_C_SOURCE 200809L
#include "gtk_icons.h"
#include <cairo/cairo.h>
#include <ctype.h>
#include <math.h>
#include <string.h>

int orb_status_badge_kind(const char *status) {
    if (!status || !*status) { return 0; }
    char s[48]; size_t i = 0; for (; status[i] && i + 1 < sizeof(s); ++i) { s[i] = (char)tolower((unsigned char)status[i]); } s[i] = '\0';
    if (strcmp(s, "active") == 0 || strcmp(s, "running") == 0 || strcmp(s, "starting") == 0 || strcmp(s, "resuming") == 0 ||
        strcmp(s, "working") == 0 || strcmp(s, "in_progress") == 0 || strcmp(s, "processing") == 0 || strcmp(s, "streaming") == 0) { return 1; }
    if (strcmp(s, "waiting_background") == 0) { return 2; }
    if (strcmp(s, "pending") == 0 || strcmp(s, "queued") == 0) { return 3; }
    if (strcmp(s, "completed") == 0 || strcmp(s, "succeeded") == 0) { return 4; }
    if (strcmp(s, "blocked") == 0 || strcmp(s, "failed") == 0 || strcmp(s, "error") == 0 || strcmp(s, "errored") == 0 ||
        strcmp(s, "timed_out") == 0 || strcmp(s, "not_feasible") == 0 || strcmp(s, "waiting_for_approval") == 0) { return 5; }
    if (strcmp(s, "paused") == 0 || strcmp(s, "interrupted") == 0 || strcmp(s, "cancelled") == 0 || strcmp(s, "canceled") == 0) { return 6; }
    return 0;
}

#if defined(ORB_HAS_WEBKITGTK)
static void rounded_rect(cairo_t *cr, double x, double y, double w, double h, double r) {
    cairo_new_sub_path(cr); cairo_arc(cr, x + w - r, y + r, r, -1.5708, 0); cairo_arc(cr, x + w - r, y + h - r, r, 0, 1.5708);
    cairo_arc(cr, x + r, y + h - r, r, 1.5708, 3.1416); cairo_arc(cr, x + r, y + r, r, 3.1416, 4.7124); cairo_close_path(cr);
}
static gboolean on_spin_tick(gpointer ud) {
    OrbIconSpinner *sp = (OrbIconSpinner *)ud;
    if (!sp->spinning || sp->spinning->len == 0) { sp->src = 0; return FALSE; }
    sp->step = (sp->step + 1) % 12;
    for (guint i = 0; i < sp->spinning->len; ++i) { gtk_widget_queue_draw(GTK_WIDGET(g_ptr_array_index(sp->spinning, i))); }
    return TRUE;
}
static void on_spin_widget_destroy(GtkWidget *w, gpointer ud) {
    OrbIconSpinner *sp = (OrbIconSpinner *)ud; if (!sp || !sp->spinning) { return; }
    g_ptr_array_remove_fast(sp->spinning, w);
    if (sp->spinning->len == 0 && sp->src) { g_source_remove(sp->src); sp->src = 0; }
}
void orb_spinner_stop(OrbIconSpinner *sp) {
    if (!sp) { return; }
    if (sp->src) { g_source_remove(sp->src); sp->src = 0; }
    if (sp->spinning) { g_ptr_array_free(sp->spinning, TRUE); sp->spinning = NULL; }
}
static void draw_status_badge(cairo_t *cr, int bk, int step) {
    const double cx = 13.8, cy = 13.8;
    cairo_save(cr); cairo_set_source_rgba(cr, 0.078, 0.078, 0.078, 1.0); cairo_arc(cr, cx, cy, 5.4, 0, 6.2832); cairo_fill(cr);
    if (bk == 1 || bk == 2) { cairo_set_source_rgba(cr, 0.525, 0.682, 0.894, 1.0); }
    else if (bk == 4) { cairo_set_source_rgba(cr, 0.502, 0.698, 0.553, 1.0); }
    else if (bk == 5) { cairo_set_source_rgba(cr, 0.788, 0.635, 0.153, 1.0); }
    else { cairo_set_source_rgba(cr, 0.541, 0.541, 0.541, 1.0); }
    cairo_set_line_width(cr, 1.15); cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND); cairo_set_line_join(cr, CAIRO_LINE_JOIN_ROUND);
    if (bk == 1) { double a0 = (double)step * 0.5235987756 - 1.5708; cairo_arc(cr, cx, cy, 3.7, a0, a0 + 4.45); cairo_stroke(cr); }
    else if (bk == 2 || bk == 3) { cairo_arc(cr, cx, cy, 3.8, 0, 6.2832); cairo_move_to(cr, cx, cy - 2.1); cairo_line_to(cr, cx, cy); cairo_line_to(cr, cx + 1.5, cy + 0.9); cairo_stroke(cr); }
    else if (bk == 4) { cairo_arc(cr, cx, cy, 3.9, 0, 6.2832); cairo_move_to(cr, cx - 1.6, cy + 0.1); cairo_line_to(cr, cx - 0.3, cy + 1.4); cairo_line_to(cr, cx + 1.9, cy - 1.2); cairo_stroke(cr); }
    else if (bk == 5) { cairo_arc(cr, cx, cy, 3.9, 0, 6.2832); cairo_move_to(cr, cx, cy - 1.9); cairo_line_to(cr, cx, cy + 0.3); cairo_stroke(cr); cairo_arc(cr, cx, cy + 2.0, 0.65, 0, 6.2832); cairo_fill(cr); }
    else if (bk == 6) { cairo_move_to(cr, cx - 1.4, cy - 2.2); cairo_line_to(cr, cx - 1.4, cy + 2.2); cairo_move_to(cr, cx + 1.4, cy - 2.2); cairo_line_to(cr, cx + 1.4, cy + 2.2); cairo_stroke(cr); }
    cairo_restore(cr);
}
static gboolean on_draw_icon(GtkWidget *w, cairo_t *cr, gpointer ud) {
    OrbIconSpinner *sp = (OrbIconSpinner *)ud;
    const char *ic = g_object_get_data(G_OBJECT(w), "orb-icon"), *co = g_object_get_data(G_OBJECT(w), "orb-color");
    int bk = GPOINTER_TO_INT(g_object_get_data(G_OBJECT(w), "orb-bk")); GdkRGBA col; if (!ic || !*ic) { return FALSE; }
    if (co && *co && gdk_rgba_parse(&col, co)) { gdk_cairo_set_source_rgba(cr, &col); }
    else { gtk_style_context_get_color(gtk_widget_get_style_context(w), gtk_widget_get_state_flags(w), &col); gdk_cairo_set_source_rgba(cr, &col); }
    cairo_set_line_width(cr, 1.15); cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND); cairo_set_line_join(cr, CAIRO_LINE_JOIN_ROUND);
    if (strcmp(ic, "sidebar") == 0) { rounded_rect(cr, 2.0, 3.0, 12.0, 10.0, 2.0); cairo_move_to(cr, 6.0, 3.0); cairo_line_to(cr, 6.0, 13.0); }
    else if (strcmp(ic, "search") == 0) { cairo_arc(cr, 7.2, 7.2, 4.2, 0, 6.2832); cairo_move_to(cr, 10.4, 10.4); cairo_line_to(cr, 13.5, 13.5); }
    else if (strcmp(ic, "arrow-left") == 0) { cairo_move_to(cr, 13.0, 8.0); cairo_line_to(cr, 3.0, 8.0); cairo_move_to(cr, 7.0, 4.0); cairo_line_to(cr, 3.0, 8.0); cairo_line_to(cr, 7.0, 12.0); }
    else if (strcmp(ic, "arrow-right") == 0) { cairo_move_to(cr, 3.0, 8.0); cairo_line_to(cr, 13.0, 8.0); cairo_move_to(cr, 9.0, 4.0); cairo_line_to(cr, 13.0, 8.0); cairo_line_to(cr, 9.0, 12.0); }
    else if (strcmp(ic, "new-agent") == 0) { cairo_move_to(cr, 2.5, 3.0); cairo_line_to(cr, 13.5, 3.0); cairo_line_to(cr, 9.5, 8.2); cairo_line_to(cr, 9.5, 13.0); cairo_line_to(cr, 6.5, 11.4); cairo_line_to(cr, 6.5, 8.2); cairo_close_path(cr); }
    else if (strcmp(ic, "inbox") == 0) { cairo_move_to(cr, 2.3, 9.3); cairo_line_to(cr, 4.0, 3.2); cairo_line_to(cr, 12.0, 3.2); cairo_line_to(cr, 13.7, 9.3); cairo_line_to(cr, 13.7, 12.7); cairo_line_to(cr, 2.3, 12.7); cairo_close_path(cr); cairo_move_to(cr, 2.4, 9.3); cairo_line_to(cr, 5.7, 9.3); cairo_line_to(cr, 6.6, 10.8); cairo_line_to(cr, 9.4, 10.8); cairo_line_to(cr, 10.3, 9.3); cairo_line_to(cr, 13.6, 9.3); }
    else if (strcmp(ic, "cloud") == 0) { cairo_arc(cr, 4.8, 9.7, 2.6, 1.57, 4.5); cairo_arc(cr, 8.3, 7.6, 3.6, 3.4, 6.15); cairo_arc(cr, 11.5, 10.1, 2.2, 4.71, 1.57); cairo_close_path(cr); }
    else if (strcmp(ic, "machines") == 0) { rounded_rect(cr, 2.0, 2.4, 12.0, 8.2, 1.5); cairo_move_to(cr, 8.0, 10.6); cairo_line_to(cr, 8.0, 13.2); cairo_move_to(cr, 5.2, 13.5); cairo_line_to(cr, 10.8, 13.5); }
    else if (strcmp(ic, "cube") == 0) { cairo_move_to(cr, 8.0, 2.4); cairo_line_to(cr, 13.4, 5.4); cairo_line_to(cr, 13.4, 10.6); cairo_line_to(cr, 8.0, 13.6); cairo_line_to(cr, 2.6, 10.6); cairo_line_to(cr, 2.6, 5.4); cairo_close_path(cr); cairo_move_to(cr, 2.6, 5.4); cairo_line_to(cr, 8.0, 8.4); cairo_line_to(cr, 13.4, 5.4); cairo_move_to(cr, 8.0, 8.4); cairo_line_to(cr, 8.0, 13.6); }
    else if (strcmp(ic, "resources") == 0) { cairo_move_to(cr, 2.4, 4.4); cairo_line_to(cr, 5.2, 4.4); cairo_line_to(cr, 9.2, 8.0); cairo_line_to(cr, 13.6, 8.0); cairo_move_to(cr, 2.4, 11.6); cairo_line_to(cr, 5.2, 11.6); cairo_line_to(cr, 9.2, 8.0); cairo_move_to(cr, 11.4, 5.8); cairo_line_to(cr, 13.8, 8.0); cairo_line_to(cr, 11.4, 10.2); }
    else if (strcmp(ic, "gear") == 0) { cairo_arc(cr, 8.0, 8.0, 2.1, 0, 6.29); cairo_new_sub_path(cr); cairo_arc(cr, 8.0, 8.0, 4.7, 0, 6.29); for (int a = 0; a < 8; ++a) { static const double dx[8] = {1,.71,0,-.71,-1,-.71,0,.71}, dy[8] = {0,.71,1,.71,0,-.71,-1,-.71}; cairo_move_to(cr, 8.0 + dx[a] * 4.7, 8.0 + dy[a] * 4.7); cairo_line_to(cr, 8.0 + dx[a] * 6.1, 8.0 + dy[a] * 6.1); } }
    else if (strcmp(ic, "folder") == 0 || strcmp(ic, "folder-open") == 0) { cairo_move_to(cr, 2.0, 4.2); cairo_line_to(cr, 2.0, 12.6); cairo_line_to(cr, 13.8, 12.6); cairo_line_to(cr, 13.8, 5.2); cairo_line_to(cr, 7.6, 5.2); cairo_line_to(cr, 6.1, 3.4); cairo_line_to(cr, 2.6, 3.4); cairo_close_path(cr); if (ic[6] == '-') { cairo_move_to(cr, 2.2, 8.2); cairo_line_to(cr, 13.8, 8.2); } }
    else if (strcmp(ic, "skills") == 0) { cairo_move_to(cr, 2.5, 5.2); cairo_line_to(cr, 8.0, 2.4); cairo_line_to(cr, 13.5, 5.2); cairo_line_to(cr, 8.0, 8.0); cairo_close_path(cr); cairo_move_to(cr, 2.5, 8.2); cairo_line_to(cr, 8.0, 11.0); cairo_line_to(cr, 13.5, 8.2); cairo_move_to(cr, 2.5, 11.2); cairo_line_to(cr, 8.0, 14.0); cairo_line_to(cr, 13.5, 11.2); }
    else if (strcmp(ic, "key") == 0) { cairo_arc(cr, 5.8, 8.0, 2.4, 0, 6.29); cairo_move_to(cr, 8.2, 8.0); cairo_line_to(cr, 13.4, 8.0); cairo_line_to(cr, 12.1, 9.4); cairo_move_to(cr, 11.0, 8.0); cairo_line_to(cr, 11.0, 9.7); }
    else if (strcmp(ic, "bell") == 0) { cairo_arc(cr, 8.0, 5.8, 3.2, 3.14, 6.28); cairo_line_to(cr, 11.2, 8.2); cairo_line_to(cr, 12.8, 10.6); cairo_line_to(cr, 3.2, 10.6); cairo_line_to(cr, 4.8, 8.2); cairo_close_path(cr); cairo_new_sub_path(cr); cairo_arc(cr, 8.0, 12.2, 1.5, 0, 3.14); }
    else { cairo_set_line_width(cr, 1.25); rounded_rect(cr, 3.0, 6.0, 12.0, 9.0, 1.5); cairo_move_to(cr, 9.0, 6.0); cairo_line_to(cr, 9.0, 3.0); cairo_line_to(cr, 6.0, 3.0); cairo_move_to(cr, 1.5, 10.5); cairo_line_to(cr, 3.0, 10.5); cairo_move_to(cr, 15.0, 10.5); cairo_line_to(cr, 16.5, 10.5); cairo_move_to(cr, 6.8, 9.8); cairo_line_to(cr, 6.8, 11.3); cairo_move_to(cr, 11.2, 9.8); cairo_line_to(cr, 11.2, 11.3); }
    cairo_stroke(cr);
    if (bk > 0) { draw_status_badge(cr, bk, sp ? sp->step : 0); }
    return FALSE;
}
GtkWidget *orb_make_icon_widget(OrbIconSpinner *sp, const char *icon, const char *color, const char *status) {
    int is_bot = icon && strcmp(icon, "bot") == 0, bk = is_bot ? orb_status_badge_kind(status) : 0;
    GtkWidget *da = gtk_drawing_area_new(); gtk_widget_set_size_request(da, is_bot ? 19 : 16, is_bot ? 18 : 16);
    gtk_widget_set_valign(da, GTK_ALIGN_CENTER); gtk_style_context_add_class(gtk_widget_get_style_context(da), "orb-ico");
    g_object_set_data_full(G_OBJECT(da), "orb-icon", g_strdup(icon ? icon : ""), g_free);
    if (color && *color) { g_object_set_data_full(G_OBJECT(da), "orb-color", g_strdup(color), g_free); }
    g_object_set_data(G_OBJECT(da), "orb-bk", GINT_TO_POINTER(bk));
    if (bk == 1 && sp) {
        if (!sp->spinning) { sp->spinning = g_ptr_array_new(); }
        g_ptr_array_add(sp->spinning, da);
        if (!sp->src) { sp->src = g_timeout_add(100, on_spin_tick, sp); }
        g_signal_connect(da, "destroy", G_CALLBACK(on_spin_widget_destroy), sp);
    }
    return g_signal_connect(da, "draw", G_CALLBACK(on_draw_icon), sp), da;
}
#endif

int orb_gtk_icons_self_test(void) {
    return orb_status_badge_kind("active") == 1 && orb_status_badge_kind("RUNNING") == 1 &&
           orb_status_badge_kind("waiting_background") == 2 && orb_status_badge_kind("queued") == 3 &&
           orb_status_badge_kind("completed") == 4 && orb_status_badge_kind("failed") == 5 &&
           orb_status_badge_kind("paused") == 6 && orb_status_badge_kind("awaiting_user") == 0;
}
