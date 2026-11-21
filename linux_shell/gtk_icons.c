/* linux_shell/gtk_icons.c — Cairo sidebar/topbar icons & mission status badges (<= 220 LOC). */
#define _POSIX_C_SOURCE 200809L
#include "gtk_icons.h"
#include <cairo/cairo.h>
#include <ctype.h>
#include <math.h>
#include <string.h>

const char *orb_menu_icon_name(const char *action) {
    return !strcmp(action, "rename") ? "document-edit-symbolic" :
        !strcmp(action, "archive") ? "package-x-generic-symbolic" : !strcmp(action, "restore") ? "edit-undo-symbolic" :
        !strcmp(action, "settings") ? "preferences-system-symbolic" : !strcmp(action, "clear") ? "edit-clear-symbolic" :
        !strcmp(action, "delete") ? "user-trash-symbolic" : !strcmp(action, "move") ? "folder-symbolic" : "edit-copy-symbolic";
}

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
int orb_icons_light = 0;
static const char ORB_CHROME_CSS[] = ".orb-paned,.orb-sb scrolledwindow,.orb-sb viewport{background:transparent;background-image:none;border:none;box-shadow:none;}.orb-sb undershoot,.orb-sb overshoot,.orb-sb scrollbar,.orb-sb scrollbar contents,.orb-sb scrollbar trough,.orb-sb scrollbar slider,.orb-sb scrollbar button{opacity:0;min-width:0;min-height:0;margin:0;padding:0;background:transparent;background-image:none;border:none;box-shadow:none;}.orb-paned>separator{min-width:1px;min-height:1px;padding:0;margin:0;background-color:#2c2c2c;background-image:none;border:none;box-shadow:none;}.orb-sb{background-color:rgba(18,19,19,0.78);background-image:none;color:#d8d8d7;font-size:13px;}.orb-tb{padding:0 8px;}.orb-tb-btn{min-width:24px;min-height:24px;padding:0;margin:0;border-radius:6px;border:1px solid transparent;background:transparent;background-image:none;color:#8a8a8a;box-shadow:none;outline:none;}.orb-tb-btn:hover:not(:disabled){background-color:rgba(216,216,215,0.075);color:#d8d8d7;}.orb-tb-btn:disabled{opacity:0.42;}.orb-sb list{background:transparent;color:#d8d8d7;}.orb-sb row{min-height:30px;padding:0;margin:0 6px 1px 6px;border:1px solid transparent;border-radius:6px;background:transparent;color:#d8d8d7;outline:none;box-shadow:none;}.orb-sb row:hover:not(.orb-selected):not(.orb-sec):not(.orb-note){background-color:rgba(216,216,215,0.045);}.orb-sb row.orb-selected,.orb-multi{background-color:rgba(216,216,215,0.075);color:#e6e6e5;}.orb-sb row.orb-sec{min-height:20px;margin:13px 8px 4px 10px;color:#8a8a8a;font-size:11px;}.orb-sb row.orb-sec-toggle:hover{color:#b1b1b1;}.orb-sb row.orb-sec .orb-chev{color:inherit;font-size:11px;}.orb-sb row.orb-note{min-height:26px;margin:2px 8px 2px 10px;color:#8a8a8a;font-size:12px;}.orb-ico{color:rgba(216,216,215,0.62);}.orb-tb-btn .orb-ico{color:inherit;}.orb-sb row.orb-selected .orb-ico,.orb-foot button.orb-selected .orb-ico{color:#e6e6e5;}.orb-proj{color:#b1b1b1;}.orb-sb row:hover .orb-proj{color:#d8d8d7;}.orb-sub,.orb-sub-live{min-height:20px;min-width:0;padding:0 5px;border-radius:4px;border:1px solid transparent;background:transparent;background-image:none;color:#6c6c6b;font-size:11px;font-family:monospace;box-shadow:none;outline:none;}.orb-sub-live{color:#b1b1b1;}.orb-sub:hover,.orb-sub-live:hover{background-color:rgba(216,216,215,0.09);color:#e6e6e5;}.orb-add{min-width:18px;min-height:18px;border-radius:4px;}.orb-sb row.orb-sec .orb-add{color:#5c5c5c;}.orb-sb row:not(.orb-sec) .orb-add{opacity:0;}.orb-sb row:hover .orb-add,.orb-sb row:focus .orb-add,.orb-sb row .orb-add:focus{opacity:1;}.orb-sb row .orb-add:hover{color:#d8d8d7;}.orb-kbd{color:#5c5c5c;font-size:11px;}.orb-attn{color:#c9a227;font-size:12px;}.orb-badge{min-width:16px;min-height:16px;padding:0 5px;border-radius:999px;background-color:rgba(216,216,215,0.075);color:#8a8a8a;font-size:11px;}.orb-foot{padding:6px;border-top:1px solid #2c2c2c;}.orb-foot button{min-height:32px;padding:0 8px;border-radius:8px;border:1px solid transparent;background:transparent;background-image:none;color:#b1b1b1;box-shadow:none;outline:none;}.orb-foot button:hover:not(.orb-selected){background-color:rgba(216,216,215,0.045);color:#d8d8d7;}.orb-foot button.orb-selected{color:#d8d8d7;font-weight:500;}.orb-sb row:focus-visible,.orb-tb-btn:focus-visible,.orb-sub:focus-visible,.orb-sub-live:focus-visible,.orb-foot button:focus-visible{border-color:#5b5b5a;outline:none;box-shadow:none;}";
/* Light theme: the same sheet with each dark token swapped for its `styles.css` light value. */
void orb_gtk_apply_theme(GtkCssProvider *css, gboolean light) {
    static const char *m[][2] = { {"#d8d8d7", "#242423"}, {"#e6e6e5", "#101010"}, {"#b1b1b1", "#535250"}, {"#8a8a8a", "#7b7a76"}, {"#6c6c6b", "#939290"}, {"#5c5c5c", "#a9a8a2"}, {"#5b5b5a", "#a9a8a2"}, {"#2c2c2c", "#e8e7e2"}, {"rgba(18,19,19,0.78)", "rgba(246,246,244,0.72)"}, {"216,216,215", "36,36,35"} };
    char *s = g_strdup(ORB_CHROME_CSS); for (size_t i = 0; light && i < G_N_ELEMENTS(m); i++) { char **parts = g_strsplit(s, m[i][0], -1); g_free(s); s = g_strjoinv(m[i][1], parts); g_strfreev(parts); }
    gtk_css_provider_load_from_data(css, s, -1, NULL); g_free(s); orb_icons_light = light;
}
static void draw_status_badge(cairo_t *cr, int bk, int step) {
    const double cx = 13.8, cy = 13.8;
    cairo_save(cr); if (orb_icons_light) { cairo_set_source_rgba(cr, 0.965, 0.965, 0.957, 1.0); } else { cairo_set_source_rgba(cr, 0.078, 0.078, 0.078, 1.0); } cairo_arc(cr, cx, cy, 5.4, 0, 6.2832); cairo_fill(cr);
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
    else if (strcmp(ic, "plus") == 0) { cairo_move_to(cr, 8.0, 3.5); cairo_line_to(cr, 8.0, 12.5); cairo_move_to(cr, 3.5, 8.0); cairo_line_to(cr, 12.5, 8.0); }
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
    else if (strcmp(ic, "file") == 0) { cairo_move_to(cr, 3.5, 2.0); cairo_line_to(cr, 9.2, 2.0); cairo_line_to(cr, 12.2, 5.0); cairo_line_to(cr, 12.2, 13.8); cairo_line_to(cr, 3.5, 13.8); cairo_close_path(cr); cairo_move_to(cr, 9.0, 2.0); cairo_line_to(cr, 9.0, 5.2); cairo_line_to(cr, 12.2, 5.2); }
    else if (strcmp(ic, "skills") == 0) { cairo_move_to(cr, 2.5, 5.2); cairo_line_to(cr, 8.0, 2.4); cairo_line_to(cr, 13.5, 5.2); cairo_line_to(cr, 8.0, 8.0); cairo_close_path(cr); cairo_move_to(cr, 2.5, 8.2); cairo_line_to(cr, 8.0, 11.0); cairo_line_to(cr, 13.5, 8.2); cairo_move_to(cr, 2.5, 11.2); cairo_line_to(cr, 8.0, 14.0); cairo_line_to(cr, 13.5, 11.2); }
    else if (strcmp(ic, "key") == 0) { cairo_arc(cr, 5.8, 8.0, 2.4, 0, 6.29); cairo_move_to(cr, 8.2, 8.0); cairo_line_to(cr, 13.4, 8.0); cairo_line_to(cr, 12.1, 9.4); cairo_move_to(cr, 11.0, 8.0); cairo_line_to(cr, 11.0, 9.7); }
    else if (strcmp(ic, "bell") == 0) { cairo_arc(cr, 8.0, 5.8, 3.2, 3.14, 6.28); cairo_line_to(cr, 11.2, 8.2); cairo_line_to(cr, 12.8, 10.6); cairo_line_to(cr, 3.2, 10.6); cairo_line_to(cr, 4.8, 8.2); cairo_close_path(cr); cairo_new_sub_path(cr); cairo_arc(cr, 8.0, 12.2, 1.5, 0, 3.14); }
    else { cairo_set_line_width(cr, 1.25); rounded_rect(cr, 3.0, 6.0, 12.0, 9.0, 1.5); cairo_move_to(cr, 9.0, 6.0); cairo_line_to(cr, 9.0, 3.0); cairo_line_to(cr, 6.0, 3.0); cairo_move_to(cr, 1.5, 10.5); cairo_line_to(cr, 3.0, 10.5); cairo_move_to(cr, 15.0, 10.5); cairo_line_to(cr, 16.5, 10.5); cairo_move_to(cr, 6.8, 9.8); cairo_line_to(cr, 6.8, 11.3); cairo_move_to(cr, 11.2, 9.8); cairo_line_to(cr, 11.2, 11.3); }
    cairo_stroke(cr);
    if (bk > 0) { draw_status_badge(cr, bk, sp ? sp->step : 0); }
    return FALSE;
}
/* A model button normally chooses between its text and icon. Keep the
 * native submenu indicator and add the leading glyph beside its label. */
GtkWidget *orb_menu_row(GtkWidget *page, const char *label, const char *icon) {
    GtkWidget *button = gtk_model_button_new();
    g_object_set(button, "text", label, NULL);
    if (icon) { orb_add_menu_icon(button, icon); }
    gtk_box_pack_start(GTK_BOX(page), button, FALSE, FALSE, 0);
    return button;
}
void orb_menu_separator(GtkWidget *page) {
    gtk_box_pack_start(GTK_BOX(page), gtk_separator_new(GTK_ORIENTATION_HORIZONTAL), FALSE, FALSE, 3);
}
void orb_add_menu_icon(GtkWidget *button, const char *icon) {
    GtkBox *content = GTK_BOX(gtk_bin_get_child(GTK_BIN(button)));
    GtkWidget *image = gtk_image_new_from_icon_name(icon, GTK_ICON_SIZE_MENU);
    gtk_widget_set_margin_end(image, 7);
    gtk_box_pack_start(content, image, FALSE, FALSE, 0);
    gtk_box_reorder_child(content, image, 0);
}

GtkWidget *orb_make_icon_widget(OrbIconSpinner *sp, const char *icon, const char *color, const char *status) {
    int is_bot = icon && strcmp(icon, "bot") == 0, bk = is_bot ? orb_status_badge_kind(status) : 0;
    GtkWidget *da = gtk_drawing_area_new(); gtk_widget_set_size_request(da, is_bot ? 20 : 16, is_bot ? 20 : 16);
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
static gboolean on_ptr_enter(GtkWidget *w, GdkEventCrossing *ev, gpointer ud) {
    (void)ud;
    GdkWindow *gw = ev ? ev->window : gtk_widget_get_window(w);
    if (gw && gtk_widget_get_sensitive(w)) {
        GdkCursor *cur = gdk_cursor_new_from_name(gdk_window_get_display(gw), "pointer");
        gdk_window_set_cursor(gw, cur);
        if (cur) { g_object_unref(cur); }
    }
    return FALSE;
}
static gboolean on_ptr_leave(GtkWidget *w, GdkEventCrossing *ev, gpointer ud) {
    (void)ud;
    GdkWindow *gw = ev ? ev->window : gtk_widget_get_window(w);
    if (gw) { gdk_window_set_cursor(gw, NULL); }
    return FALSE;
}
void orb_gtk_begin_window_drag(GtkWidget *w) {
    GtkWidget *top = w ? gtk_widget_get_toplevel(w) : NULL; GdkSeat *seat = gdk_display_get_default_seat(gdk_display_get_default()); gint x = 0, y = 0;
    if (!GTK_IS_WINDOW(top) || !seat) { return; }
    gdk_device_get_position(gdk_seat_get_pointer(seat), NULL, &x, &y); gtk_window_begin_move_drag(GTK_WINDOW(top), GDK_BUTTON_PRIMARY, x, y, gtk_get_current_event_time());
}
static gboolean on_drag_press(GtkWidget *w, GdkEventButton *ev, gpointer ud) {
    (void)ud; if (ev->type != GDK_BUTTON_PRESS || ev->button != GDK_BUTTON_PRIMARY) { return FALSE; }
    GtkWidget *top = gtk_widget_get_toplevel(w); if (GTK_IS_WINDOW(top)) { gtk_window_begin_move_drag(GTK_WINDOW(top), ev->button, (gint)ev->x_root, (gint)ev->y_root, ev->time); }
    return TRUE;
}
GtkWidget *orb_gtk_drag_area(GtkWidget *child) {
    GtkWidget *eb = gtk_event_box_new(); gtk_event_box_set_visible_window(GTK_EVENT_BOX(eb), FALSE);
    gtk_widget_add_events(eb, GDK_BUTTON_PRESS_MASK); g_signal_connect(eb, "button-press-event", G_CALLBACK(on_drag_press), NULL);
    return gtk_container_add(GTK_CONTAINER(eb), child), eb;
}
void orb_gtk_bind_pointer_cursor(GtkWidget *w) {
    if (!w) { return; }
    gtk_widget_add_events(w, GDK_ENTER_NOTIFY_MASK | GDK_LEAVE_NOTIFY_MASK);
    g_signal_connect(w, "enter-notify-event", G_CALLBACK(on_ptr_enter), NULL);
    g_signal_connect(w, "leave-notify-event", G_CALLBACK(on_ptr_leave), NULL);
}
#endif

int orb_gtk_icons_self_test(void) {
    return orb_status_badge_kind("active") == 1 && orb_status_badge_kind("RUNNING") == 1 &&
           orb_status_badge_kind("waiting_background") == 2 && orb_status_badge_kind("queued") == 3 &&
           orb_status_badge_kind("completed") == 4 && orb_status_badge_kind("failed") == 5 &&
           orb_status_badge_kind("paused") == 6 && orb_status_badge_kind("awaiting_user") == 0;
}
