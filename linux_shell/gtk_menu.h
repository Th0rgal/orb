/* linux_shell/gtk_menu.h — Native Chrome sidebar context menu, inline rename & tree clipboard. */
#ifndef ORB_GTK_MENU_H
#define ORB_GTK_MENU_H

const char *orb_menu_project_slug(const char *target);
int orb_gtk_menu_self_test(void);

#if defined(ORB_HAS_WEBKITGTK)
#include <gtk/gtk.h>
GtkWidget *orb_menu_page(void);
void orb_menu_popup(GtkWidget *menu, GtkWidget *row, const GdkEvent *event);
void orb_inline_rename(GtkWidget *wv, GtkWidget *row, const char *mode, const char *id, const char *title);
void orb_eval_project_action(GtkWidget *wv, const char *action, const char *target, const char *arg);
void orb_project_menu_populate(GtkWidget *wv, GtkWidget *menu, GtkWidget *row, const char *slug, gboolean has_cut);
void orb_folder_menu_populate(GtkWidget *wv, GtkWidget *menu, GtkWidget *row, const char *slug, const char *folder, gboolean has_cut);
void orb_file_menu_populate(GtkWidget *wv, GtkWidget *menu, GtkWidget *row, const char *slug, const char *file_path, const char *parent_folder, gboolean has_cut);
void orb_sidebar_mark_cut(gboolean active);
gboolean orb_sidebar_has_cut(void);
gboolean orb_sidebar_cut_copy(GtkWidget *wv, GtkWidget *list, GtkWidget *focus, gboolean copy);
gboolean orb_sidebar_paste(GtkWidget *wv, GtkWidget *focus);
gboolean orb_sidebar_rename_focused(GtkWidget *wv, GtkWidget *focus);
gboolean orb_gtk_row_context_menu(GtkWidget *wv, GtkWidget *list, GtkWidget *row, const GdkEvent *ev);
void orb_sel_sync(GtkWidget *list);
gboolean orb_sel_click(GtkWidget *list, GtkWidget *row, gboolean extend);
gboolean orb_sel_clear(GtkWidget *list);
gboolean orb_sel_delete(GtkWidget *wv, GtkWidget *list, const char *fallback);
#endif

#endif
