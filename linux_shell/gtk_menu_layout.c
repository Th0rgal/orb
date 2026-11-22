/* Shared layout for the classic and LeanUI sidebar menus. */
#include "gtk_menu.h"
#include "gtk_chrome.h"
#include "gtk_icons.h"
#include <math.h>
#include <stdlib.h>
#if defined(ORB_HAS_WEBKITGTK)
#include <webkit2/webkit2.h>
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
    GtkAllocation alloc;
    gtk_widget_get_allocation(row, &alloc);
    GdkRectangle point = {alloc.width > 0 ? alloc.width / 2 : 0, alloc.height > 0 ? alloc.height / 2 : 0, 1, 1};
    if (event) {
        gdouble x = 0, y = 0;
        gint rx = 0, ry = 0;
        GtkWidget *src = gtk_get_event_widget((GdkEvent *)event);
        if (gdk_event_get_coords(event, &x, &y) &&
            gtk_widget_translate_coordinates(src ? src : row, row, (gint)round(x), (gint)round(y), &rx, &ry)) {
            point.x = rx;
            point.y = ry;
        }
    }
    gtk_popover_set_pointing_to(pop, &point);
    gtk_popover_set_position(pop, GTK_POS_BOTTOM);
}
typedef struct { GtkWidget *wv; const char *action; char *slug; } ProjAct;
static void free_proj_act(gpointer p, GClosure *cl) { (void)cl; ProjAct *a = p; g_free(a->slug); g_free(a); }
static void on_proj_item(GtkButton *mi, gpointer ud) {
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
    g_signal_connect_data(it, "clicked", G_CALLBACK(on_proj_item), a, free_proj_act, 0);
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
