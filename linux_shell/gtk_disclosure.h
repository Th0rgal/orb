#ifndef ORB_GTK_DISCLOSURE_H
#define ORB_GTK_DISCLOSURE_H

#include "gtk_icons.h"
#include <jsc/jsc.h>

static inline char *orb_jsc_join_strings(JSCValue *obj, const char *prop) {
    JSCValue *arr = jsc_value_object_get_property(obj, prop);
    if (!arr || !jsc_value_is_array(arr)) { if (arr) g_object_unref(arr); return g_strdup(""); }
    JSCValue *lv = jsc_value_object_get_property(arr, "length");
    gint32 n = (lv && jsc_value_is_number(lv)) ? jsc_value_to_int32(lv) : 0;
    if (lv) g_object_unref(lv);
    GString *s = g_string_new("");
    for (gint32 i = 0; i < n; ++i) {
        JSCValue *it = jsc_value_object_get_property_at_index(arr, (guint)i);
        if (it && jsc_value_is_string(it)) {
            g_autofree char *v = jsc_value_to_string(it);
            if (*v) g_string_append_printf(s, "%s%s", s->len ? "\n" : "", v);
        }
        if (it) g_object_unref(it);
    }
    g_object_unref(arr);
    return g_string_free(s, FALSE);
}

static inline gboolean orb_overlay_child_pos(GtkOverlay *ov, GtkWidget *child, GdkRectangle *rect, gpointer ud) {
    (void)ov; (void)ud;
    GdkRectangle *hit = g_object_get_data(G_OBJECT(child), "orb-hit");
    return hit ? (*rect = *hit, TRUE) : FALSE;
}

static inline GtkWidget *orb_wrap_overlay(GtkWidget *child) {
    GtkWidget *ov = gtk_overlay_new();
    gtk_container_add(GTK_CONTAINER(ov), child);
    g_signal_connect(ov, "get-child-position", G_CALLBACK(orb_overlay_child_pos), NULL);
    return ov;
}

static inline void orb_disclosure_bind(GtkWidget *row, GtkWidget *button) {
    g_object_set_data(G_OBJECT(row), "orb-disclosure", button);
    g_signal_connect(button, "key-press-event", G_CALLBACK(orb_button_enter), NULL);
}

/* The projection may replace a row when its child count or expanded state changes. */
static inline char *orb_disclosure_focused(GtkWidget *window, GtkWidget *list) {
    GtkWidget *focus = gtk_window_get_focus(GTK_WINDOW(window));
    if (!GTK_IS_BUTTON(focus) || !gtk_widget_is_ancestor(focus, list)) return NULL;
    return g_strdup(g_object_get_data(G_OBJECT(focus), "orb-row-id"));
}

static inline void orb_disclosure_refocus(GtkWidget *list, gint index) {
    GtkListBoxRow *row = gtk_list_box_get_row_at_index(GTK_LIST_BOX(list), index);
    GtkWidget *button = g_object_get_data(G_OBJECT(row), "orb-disclosure");
    if (button && !gtk_widget_has_focus(button)) gtk_widget_grab_focus(button);
}

#endif
