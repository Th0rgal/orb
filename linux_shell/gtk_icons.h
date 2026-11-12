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
#endif

#endif
