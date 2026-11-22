/* linux_shell/gtk_icons.h — Cairo vector icons, status badges & 12-step spinner (<= 220 LOC). */
#ifndef ORB_GTK_ICONS_H
#define ORB_GTK_ICONS_H

const char *orb_menu_icon_name(const char *action);
int orb_status_badge_kind(const char *status);
extern int orb_icons_light; /* status badge disc follows the light theme */
int orb_gtk_icons_self_test(void);

#if defined(ORB_HAS_WEBKITGTK)
#include <gtk/gtk.h>
void orb_gtk_bind_keyboard_focus(GtkWidget *window);
void orb_gtk_apply_theme(GtkCssProvider *css, gboolean light);
typedef struct { GPtrArray *spinning; guint src; int step; } OrbIconSpinner;
void orb_spinner_stop(OrbIconSpinner *sp);
GtkWidget *orb_menu_row(GtkWidget *page, const char *label, const char *icon);
gboolean orb_button_enter(GtkWidget *button, GdkEventKey *event, gpointer data);
void orb_menu_separator(GtkWidget *page);
void orb_add_menu_icon(GtkWidget *button, const char *icon);
GtkWidget *orb_make_icon_widget(OrbIconSpinner *sp, const char *icon, const char *color, const char *status);
void orb_gtk_bind_pointer_cursor(GtkWidget *w);
/* Starts a compositor-driven move of `w`'s toplevel with the primary button held. */
void orb_gtk_begin_window_drag(GtkWidget *w);
/* Wraps `child` so pressing on its empty space moves the window. */
GtkWidget *orb_gtk_drag_area(GtkWidget *child);
#endif

#endif
