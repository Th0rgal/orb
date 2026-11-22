#ifndef ORB_GTK_DISCLOSURE_H
#define ORB_GTK_DISCLOSURE_H

#include "gtk_icons.h"

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
