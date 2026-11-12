/* linux_shell/gtk_menu.h — Native Chrome sidebar context menu (right-click on a mission row). */
#ifndef ORB_GTK_MENU_H
#define ORB_GTK_MENU_H

/* Slug of a `project:<slug>` row target, or NULL. */
const char *orb_menu_project_slug(const char *target);
int orb_gtk_menu_self_test(void);

#if defined(ORB_HAS_WEBKITGTK)
#include <gtk/gtk.h>
/* Pops up the menu for `row` when it is a mission row; returns TRUE when it did. */
gboolean orb_gtk_row_context_menu(GtkWidget *wv, GtkWidget *list, GtkWidget *row, const GdkEvent *ev);
/* Multi-selection: re-apply after the list is rebuilt, toggle/extend on a modified click, clear,
 * and delete the selected missions (or `fallback`, a `m:<id>` target) with one confirmation. */
void orb_sel_sync(GtkWidget *list);
gboolean orb_sel_click(GtkWidget *list, GtkWidget *row, gboolean extend);
gboolean orb_sel_clear(GtkWidget *list);
gboolean orb_sel_delete(GtkWidget *wv, GtkWidget *list, const char *fallback);
#endif

#endif
