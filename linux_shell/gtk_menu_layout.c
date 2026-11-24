/* Shared layout for the classic and LeanUI sidebar menus. */
#include "gtk_menu.h"
#include "gtk_chrome.h"
#include "gtk_icons.h"
#include <math.h>
#include <stdlib.h>
#if defined(ORB_HAS_WEBKITGTK)
#include <webkit2/webkit2.h>
GtkWidget *orb_menu_page(void) {
    GtkWidget *menu = gtk_menu_new();
    gtk_style_context_add_class(gtk_widget_get_style_context(menu), "orb-ctx");
    return menu;
}
void orb_menu_popup(GtkWidget *menu, GtkWidget *row, const GdkEvent *event) {
    GtkWidget *top = gtk_widget_get_toplevel(row);
    if (GTK_IS_WINDOW(top)) gtk_window_set_focus_visible(GTK_WINDOW(top), event == NULL);
    gtk_menu_attach_to_widget(GTK_MENU(menu), row, NULL);
    gtk_widget_show_all(menu);
    if (event) gtk_menu_popup_at_pointer(GTK_MENU(menu), event);
    else gtk_menu_popup_at_widget(GTK_MENU(menu), row, GDK_GRAVITY_SOUTH_WEST, GDK_GRAVITY_NORTH_WEST, NULL);
}
typedef struct { GtkWidget *wv; const char *action; char *slug; } ProjAct;
static void free_proj_act(gpointer p, GClosure *cl) { (void)cl; ProjAct *a = p; g_free(a->slug); g_free(a); }
static void on_proj_item(GtkMenuItem *mi, gpointer ud) {
    (void)mi;
    ProjAct *a = ud;
    if (!a || !a->wv) return;
    char *act = orb_json_escape_string(a->action), *slug = orb_json_escape_string(a->slug);
    if (act && slug) {
        char *js = g_strdup_printf(
            "window.__ORB_NATIVE_PROJECT_ACTION__&&window.__ORB_NATIVE_PROJECT_ACTION__(%s,%s);", act, slug);
        webkit_web_view_evaluate_javascript(WEBKIT_WEB_VIEW(a->wv), js, -1, NULL, NULL, NULL, NULL, NULL);
        g_free(js);
    }
    free(act);
    free(slug);
}
static void add_proj_item(GtkWidget *menu, const char *label, const char *icon, GtkWidget *wv, const char *action, const char *slug) {
    GtkWidget *it = orb_menu_row(menu, label, icon);
    ProjAct *a = g_new0(ProjAct, 1);
    a->wv = wv;
    a->action = action;
    a->slug = g_strdup(slug);
    g_signal_connect_data(it, "activate", G_CALLBACK(on_proj_item), a, free_proj_act, 0);
}
void orb_project_menu_populate(GtkWidget *wv, GtkWidget *menu, const char *slug) {
    add_proj_item(menu, "_New agent", "list-add-symbolic", wv, "new-agent", slug);
    add_proj_item(menu, "_Cloud agent", "weather-overcast-symbolic", wv, "new-cloud-agent", slug);
    orb_menu_separator(menu);
    add_proj_item(menu, "New _folder", "folder-new-symbolic", wv, "new-folder", slug);
    orb_menu_separator(menu);
    add_proj_item(menu, "Project _settings", orb_menu_icon_name("settings"), wv, "settings", slug);
    add_proj_item(menu, "_Rename", orb_menu_icon_name("rename"), wv, "rename", slug);
    add_proj_item(menu, "_Archive", orb_menu_icon_name("archive"), wv, "archive", slug);
    add_proj_item(menu, "_Delete project\xE2\x80\xA6", orb_menu_icon_name("delete"), wv, "delete", slug);
}
#endif
