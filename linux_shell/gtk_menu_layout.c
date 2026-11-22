/* Shared layout for the classic and LeanUI sidebar menus. */
#include "gtk_menu.h"
#include "gtk_icons.h"
#if defined(ORB_HAS_WEBKITGTK)
GtkWidget *orb_menu_page(void) {
    GtkWidget *page = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_container_set_border_width(GTK_CONTAINER(page), 6);
    return page;
}
/* GtkPopoverMenu's stock key bindings expect a GtkMenuSectionBox. Orb
 * supplies its own page for leading icons and destination rows. */
gboolean orb_menu_key(GtkWidget *row, GdkEventKey *event, gpointer data) {
    guint mods = event->state & gtk_accelerator_get_default_mod_mask();
    gboolean back_tab = event->keyval == GDK_KEY_ISO_Left_Tab ||
        (event->keyval == GDK_KEY_Tab && mods == GDK_SHIFT_MASK);
    gboolean prev = event->keyval == GDK_KEY_Up || back_tab;
    gboolean first = event->keyval == GDK_KEY_Home, last = event->keyval == GDK_KEY_End;
    if (mods && !(back_tab && mods == GDK_SHIFT_MASK)) return FALSE;
    if (!prev && !first && !last && event->keyval != GDK_KEY_Tab && event->keyval != GDK_KEY_Down)
        return orb_button_enter(row, event, data);

    g_autoptr(GList) rows = gtk_container_get_children(GTK_CONTAINER(gtk_widget_get_parent(row)));
    g_autoptr(GPtrArray) enabled = g_ptr_array_new();
    guint index = 0;
    for (GList *item = rows; item; item = item->next) {
        GtkWidget *button = GTK_WIDGET(item->data);
        if (!GTK_IS_MODEL_BUTTON(button) || !gtk_widget_get_visible(button) || !gtk_widget_is_sensitive(button))
            continue;
        if (button == row) index = enabled->len;
        g_ptr_array_add(enabled, button);
    }
    guint n = enabled->len;
    if (!n) return FALSE;
    if (first) index = 0;
    else if (last) index = n - 1;
    else index = (index + (prev ? n - 1 : 1)) % n;
    gtk_widget_grab_focus(g_ptr_array_index(enabled, index));
    return TRUE;
}
void orb_menu_anchor(GtkPopover *pop, GtkWidget *row, const GdkEvent *event) {
    gtk_popover_set_relative_to(pop, row);
    gtk_popover_set_constrain_to(pop, GTK_POPOVER_CONSTRAINT_WINDOW);
    GtkWidget *top = gtk_widget_get_toplevel(row);
    if (!GTK_IS_WINDOW(top)) return;
    gtk_widget_grab_focus(row);
    gtk_window_set_focus_visible(GTK_WINDOW(top), event == NULL);
    if (!event) return;
    gdouble x, y;
    gint root_x, root_y, row_x, row_y;
    if (!gdk_event_get_root_coords(event, &x, &y) ||
        !gtk_widget_translate_coordinates(row, top, 0, 0, &row_x, &row_y)) return;
    gdk_window_get_origin(gtk_widget_get_window(top), &root_x, &root_y);
    GdkRectangle point = {(gint)x - root_x - row_x, (gint)y - root_y - row_y, 1, 1};
    gtk_popover_set_pointing_to(pop, &point);
    gtk_popover_set_position(pop, GTK_POS_BOTTOM);
}
#endif
