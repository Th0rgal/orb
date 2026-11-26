/* linux_shell/gtk_squircle.h — Analytical Cairo continuous superellipse ("squircle") primitives for GTK3. */
#ifndef ORB_GTK_SQUIRCLE_H
#define ORB_GTK_SQUIRCLE_H

#include <gtk/gtk.h>
#include <cairo/cairo.h>
#include <math.h>

extern int orb_icons_light;

/* Continuous quartic superellipse (|u|^4 + |v|^4 = 1, matching CSS `corner-shape: squircle`). */
static inline void orb_cairo_squircle(cairo_t *cr, double x, double y, double w, double h, double r) {
    if (w <= 0.0 || h <= 0.0) return;
    double mr = 0.5 * (w < h ? w : h);
    if (r > mr) r = mr;
    cairo_new_sub_path(cr);
    if (r <= 1.0) { cairo_rectangle(cr, x, y, w, h); return; }
    static const double cx_k[4] = { 1, 1, 0, 0 }, cy_k[4] = { 0, 1, 1, 0 };
    static const double sx_k[4] = { 1, 1, -1, -1 }, sy_k[4] = { -1, 1, 1, -1 };
    static const double a0_k[4] = { 1.57079632679, 0.0, 1.57079632679, 0.0 };
    static const double da_k[4] = { -1.57079632679, 1.57079632679, -1.57079632679, 1.57079632679 };
    for (int q = 0; q < 4; ++q) {
        double ox = cx_k[q] ? (x + w - r) : (x + r);
        double oy = cy_k[q] ? (y + h - r) : (y + r);
        for (int s = 0; s <= 10; ++s) {
            double t = a0_k[q] + da_k[q] * ((double)s / 10.0);
            double ct = cos(t), st = sin(t);
            double px = ox + sx_k[q] * r * sqrt(ct > 0.0 ? ct : 0.0);
            double py = oy + sy_k[q] * r * sqrt(st > 0.0 ? st : 0.0);
            if (q == 0 && s == 0) cairo_move_to(cr, px, py);
            else cairo_line_to(cr, px, py);
        }
    }
    cairo_close_path(cr);
}

static inline gboolean orb_draw_squircle_menu(GtkWidget *w, cairo_t *cr, gpointer ud) {
    (void)ud;
    double width = (double)gtk_widget_get_allocated_width(w), height = (double)gtk_widget_get_allocated_height(w);
    cairo_save(cr);
    orb_cairo_squircle(cr, 0.5, 0.5, width - 1.0, height - 1.0, 10.0);
    if (orb_icons_light) cairo_set_source_rgba(cr, 1.0, 1.0, 1.0, 1.0);
    else cairo_set_source_rgba(cr, 0.094, 0.094, 0.094, 1.0);
    cairo_fill_preserve(cr);
    cairo_set_line_width(cr, 1.0);
    if (orb_icons_light) cairo_set_source_rgba(cr, 0.078, 0.078, 0.075, 0.13);
    else cairo_set_source_rgba(cr, 0.847, 0.847, 0.843, 0.14);
    cairo_stroke(cr);
    cairo_restore(cr);
    return FALSE;
}

static inline gboolean orb_draw_squircle_item(GtkWidget *w, cairo_t *cr, gpointer ud) {
    (void)ud;
    if (!gtk_widget_get_sensitive(w)) return FALSE;
    GtkStateFlags fl = gtk_widget_get_state_flags(w);
    if (!(fl & (GTK_STATE_FLAG_PRELIGHT | GTK_STATE_FLAG_SELECTED | GTK_STATE_FLAG_FOCUSED))) return FALSE;
    double width = (double)gtk_widget_get_allocated_width(w), height = (double)gtk_widget_get_allocated_height(w);
    gboolean danger = gtk_style_context_has_class(gtk_widget_get_style_context(w), "orb-danger");
    cairo_save(cr);
    orb_cairo_squircle(cr, 0.0, 0.0, width, height, 6.0);
    if (danger) cairo_set_source_rgba(cr, 0.878, 0.365, 0.365, orb_icons_light ? 0.10 : 0.14);
    else if (orb_icons_light) cairo_set_source_rgba(cr, 0.078, 0.078, 0.075, 0.065);
    else cairo_set_source_rgba(cr, 0.847, 0.847, 0.843, 0.09);
    cairo_fill(cr);
    cairo_restore(cr);
    return FALSE;
}

static inline gboolean orb_draw_squircle_entry(GtkWidget *w, cairo_t *cr, gpointer ud) {
    (void)ud;
    double width = (double)gtk_widget_get_allocated_width(w), height = (double)gtk_widget_get_allocated_height(w);
    cairo_save(cr);
    orb_cairo_squircle(cr, 0.5, 0.5, width - 1.0, height - 1.0, 6.0);
    if (orb_icons_light) cairo_set_source_rgba(cr, 1.0, 1.0, 1.0, 1.0);
    else cairo_set_source_rgba(cr, 0.082, 0.082, 0.082, 1.0);
    cairo_fill_preserve(cr);
    cairo_set_line_width(cr, 1.0);
    if (orb_icons_light) cairo_set_source_rgba(cr, 0.325, 0.322, 0.314, 0.65);
    else cairo_set_source_rgba(cr, 0.357, 0.357, 0.353, 1.0);
    cairo_stroke(cr);
    cairo_restore(cr);
    return FALSE;
}

static inline gboolean orb_draw_squircle_btn(GtkWidget *w, cairo_t *cr, gpointer ud) {
    (void)ud;
    GtkStyleContext *sc = gtk_widget_get_style_context(w);
    GtkStateFlags fl = gtk_widget_get_state_flags(w);
    gboolean cut = gtk_style_context_has_class(sc, "orb-cut");
    gboolean multi = gtk_style_context_has_class(sc, "orb-multi");
    gboolean hov = (fl & GTK_STATE_FLAG_PRELIGHT) != 0 && gtk_widget_get_sensitive(w);
    GtkWidget *top = gtk_widget_get_toplevel(w);
    gboolean kfocus = (fl & GTK_STATE_FLAG_FOCUSED) != 0 && GTK_IS_WINDOW(top) &&
                      gtk_style_context_has_class(gtk_widget_get_style_context(top), "orb-keyboard-focus");
    if (!cut && !multi && !hov && !kfocus) return FALSE;
    double width = (double)gtk_widget_get_allocated_width(w), height = (double)gtk_widget_get_allocated_height(w);
    cairo_save(cr);
    if (cut) {
        orb_cairo_squircle(cr, 0.0, 0.0, width, height, 6.0);
        if (orb_icons_light) cairo_set_source_rgba(cr, 246.0 / 255.0, 246.0 / 255.0, 244.0 / 255.0, 0.55);
        else cairo_set_source_rgba(cr, 18.0 / 255.0, 19.0 / 255.0, 19.0 / 255.0, 0.55);
        cairo_fill(cr);
    }
    if (multi || hov || kfocus) {
        orb_cairo_squircle(cr, 0.5, 0.5, width - 1.0, height - 1.0, 6.0);
        if (multi || hov) {
            double a = multi ? (orb_icons_light ? 0.09 : 0.12) : (orb_icons_light ? 0.05 : 0.07);
            if (orb_icons_light) cairo_set_source_rgba(cr, 0.078, 0.078, 0.075, a);
            else cairo_set_source_rgba(cr, 0.847, 0.847, 0.843, a);
            if (kfocus) cairo_fill_preserve(cr); else cairo_fill(cr);
        }
        if (kfocus) {
            cairo_set_line_width(cr, 1.0);
            if (orb_icons_light) cairo_set_source_rgba(cr, 0.325, 0.322, 0.314, 0.55);
            else cairo_set_source_rgba(cr, 0.470, 0.470, 0.455, 0.55);
            cairo_stroke(cr);
        }
    }
    cairo_restore(cr);
    return FALSE;
}

#endif
