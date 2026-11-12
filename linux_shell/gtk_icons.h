/* linux_shell/gtk_icons.h — Cairo vector icons, status badges & 12-step spinner (<= 220 LOC). */
#ifndef ORB_GTK_ICONS_H
#define ORB_GTK_ICONS_H

int orb_status_badge_kind(const char *status);
int orb_gtk_icons_self_test(void);

#if defined(ORB_HAS_WEBKITGTK)
#include <gtk/gtk.h>
typedef struct { GPtrArray *spinning; guint src; int step; } OrbIconSpinner;
void orb_spinner_stop(OrbIconSpinner *sp);
GtkWidget *orb_make_icon_widget(OrbIconSpinner *sp, const char *icon, const char *color, const char *status);
void orb_gtk_bind_pointer_cursor(GtkWidget *w);
/* Starts a compositor-driven move of `w`'s toplevel with the primary button held. */
void orb_gtk_begin_window_drag(GtkWidget *w);
/* Wraps `child` so pressing on its empty space moves the window. */
GtkWidget *orb_gtk_drag_area(GtkWidget *child);
#endif

#endif
