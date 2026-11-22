/* Shared layout for the classic and LeanUI sidebar menus. */
#include "gtk_menu.h"
#if defined(ORB_HAS_WEBKITGTK)
GtkWidget *orb_menu_page(void) {
    GtkWidget *page = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_container_set_border_width(GTK_CONTAINER(page), 6);
    return page;
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
