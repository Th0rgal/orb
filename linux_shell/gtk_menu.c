/* linux_shell/gtk_menu.c — Native Chrome sidebar context menu for mission rows (<= 220 LOC).
 * The menu mirrors the HTML sidebar's mission menu (`missionMenuItems` in orb/src/ProjectFiles.tsx)
 * and runs every action in the WebView through `window.__ORB_NATIVE_MISSION_ACTION__`, so the
 * API calls, optimistic updates and error toasts stay in one place. */
#define _POSIX_C_SOURCE 200809L
#include "gtk_menu.h"
#include "gtk_chrome.h"
#include <stdlib.h>
#include <string.h>
#if defined(ORB_HAS_WEBKITGTK)
#include <webkit2/webkit2.h>
#endif

const char *orb_menu_project_slug(const char *target) {
    if (!target || strncmp(target, "project:", 8) != 0 || !target[8]) {
        return NULL;
    }
    return target + 8;
}

#if defined(ORB_HAS_WEBKITGTK)
typedef struct {
    GtkWidget *wv;
    const char *action;
    char *id, *arg;
} MenuAct;

static void free_act(gpointer p, GClosure *cl) {
    (void)cl;
    MenuAct *a = p;
    g_free(a->id);
    g_free(a->arg);
    g_free(a);
}

static void run_action(GtkWidget *wv, const char *action, const char *id, const char *arg) {
    char *a = orb_json_escape_string(action), *i = orb_json_escape_string(id), *g = orb_json_escape_string(arg ? arg : "");
    if (a && i && g) {
        char *js = g_strdup_printf("window.__ORB_NATIVE_MISSION_ACTION__&&window.__ORB_NATIVE_MISSION_ACTION__(%s,%s,%s);", a, i, g);
        webkit_web_view_evaluate_javascript(WEBKIT_WEB_VIEW(wv), js, -1, NULL, NULL, NULL, NULL, NULL);
        g_free(js);
    }
    free(a);
    free(i);
    free(g);
}

static void prompt_rename(GtkWidget *wv, const char *id, const char *title) {
    GtkWidget *top = gtk_widget_get_toplevel(wv);
    GtkWidget *dlg = gtk_dialog_new_with_buttons("Rename conversation", GTK_IS_WINDOW(top) ? GTK_WINDOW(top) : NULL,
                                                 GTK_DIALOG_MODAL | GTK_DIALOG_DESTROY_WITH_PARENT,
                                                 "_Cancel", GTK_RESPONSE_CANCEL, "_Rename", GTK_RESPONSE_ACCEPT, NULL);
    GtkWidget *entry = gtk_entry_new(), *area = gtk_dialog_get_content_area(GTK_DIALOG(dlg));
    gtk_entry_set_text(GTK_ENTRY(entry), title ? title : "");
    gtk_entry_set_max_length(GTK_ENTRY(entry), 200);
    gtk_entry_set_activates_default(GTK_ENTRY(entry), TRUE);
    gtk_dialog_set_default_response(GTK_DIALOG(dlg), GTK_RESPONSE_ACCEPT);
    gtk_container_set_border_width(GTK_CONTAINER(area), 12);
    gtk_box_pack_start(GTK_BOX(area), entry, TRUE, TRUE, 0);
    gtk_widget_set_size_request(dlg, 380, -1);
    gtk_widget_show_all(dlg);
    if (gtk_dialog_run(GTK_DIALOG(dlg)) == GTK_RESPONSE_ACCEPT) {
        char *next = g_strstrip(g_strdup(gtk_entry_get_text(GTK_ENTRY(entry))));
        if (*next && g_strcmp0(next, title) != 0) {
            run_action(wv, "rename", id, next);
        }
        g_free(next);
    }
    gtk_widget_destroy(dlg);
}

static void on_item(GtkMenuItem *mi, gpointer ud) {
    (void)mi;
    MenuAct *a = ud;
    if (strcmp(a->action, "rename") == 0) {
        /* The dialog spins a nested loop; the menu (and `a`) may be freed meanwhile. */
        char *id = g_strdup(a->id), *title = g_strdup(a->arg);
        prompt_rename(a->wv, id, title);
        g_free(id);
        g_free(title);
    } else {
        run_action(a->wv, a->action, a->id, a->arg);
    }
}

static void add_item(GtkWidget *menu, const char *label, GtkWidget *wv, const char *action, const char *id, const char *arg) {
    GtkWidget *it = gtk_menu_item_new_with_mnemonic(label);
    MenuAct *a = g_new0(MenuAct, 1);
    a->wv = wv;
    a->action = action;
    a->id = g_strdup(id);
    a->arg = g_strdup(arg ? arg : "");
    g_signal_connect_data(it, "activate", G_CALLBACK(on_item), a, free_act, 0);
    gtk_menu_shell_append(GTK_MENU_SHELL(menu), it);
}

static gboolean destroy_later(gpointer w) {
    gtk_widget_destroy(GTK_WIDGET(w));
    return G_SOURCE_REMOVE;
}

/* Activation fires after "deactivate"; destroy on idle so the item's handler runs first. */
static void on_menu_done(GtkMenuShell *m, gpointer ud) {
    (void)ud;
    g_idle_add(destroy_later, m);
}

static GtkWidget *move_submenu(GtkWidget *wv, GtkWidget *list, const char *id, const char *current) {
    GtkWidget *sub = gtk_menu_new();
    int n = 0;
    GList *rows = gtk_container_get_children(GTK_CONTAINER(list));
    for (GList *l = rows; l; l = l->next) {
        const char *kind = g_object_get_data(G_OBJECT(l->data), "orb-kind");
        const char *slug = orb_menu_project_slug(g_object_get_data(G_OBJECT(l->data), "orb-target"));
        const char *name = g_object_get_data(G_OBJECT(l->data), "orb-title");
        if (!kind || strcmp(kind, "project") != 0 || !slug || g_strcmp0(slug, current) == 0) {
            continue;
        }
        add_item(sub, name && *name ? name : slug, wv, "move", id, slug);
        ++n;
    }
    g_list_free(rows);
    if (n == 0) {
        gtk_widget_destroy(sub);
        return NULL;
    }
    return sub;
}

gboolean orb_gtk_row_context_menu(GtkWidget *wv, GtkWidget *list, GtkWidget *row, const GdkEvent *ev) {
    const char *kind = g_object_get_data(G_OBJECT(row), "orb-kind"), *target = g_object_get_data(G_OBJECT(row), "orb-target");
    if (!wv || !kind || strcmp(kind, "mission") != 0 || !target || strncmp(target, "m:", 2) != 0 || !target[2]) {
        return FALSE;
    }
    const char *id = target + 2, *title = g_object_get_data(G_OBJECT(row), "orb-title");
    const char *status = g_object_get_data(G_OBJECT(row), "orb-status"), *project = g_object_get_data(G_OBJECT(row), "orb-project");
    gboolean archived = g_strcmp0(status, "acknowledged") == 0 || g_strcmp0(status, "archived") == 0;
    GtkWidget *menu = gtk_menu_new(), *moves = move_submenu(wv, list, id, project);
    gtk_style_context_add_class(gtk_widget_get_style_context(menu), "orb-ctx");
    add_item(menu, "_Rename\xE2\x80\xA6", wv, "rename", id, title);
    if (moves) {
        GtkWidget *mv = gtk_menu_item_new_with_mnemonic("_Move to");
        gtk_menu_item_set_submenu(GTK_MENU_ITEM(mv), moves);
        gtk_menu_shell_append(GTK_MENU_SHELL(menu), mv);
    }
    add_item(menu, archived ? "R_estore" : "_Archive", wv, archived ? "restore" : "archive", id, NULL);
    gtk_menu_shell_append(GTK_MENU_SHELL(menu), gtk_separator_menu_item_new());
    add_item(menu, "_Copy mission ID", wv, "copy-id", id, NULL);
    add_item(menu, "Mission _settings", wv, "settings", id, NULL);
    gtk_menu_attach_to_widget(GTK_MENU(menu), list, NULL);
    g_signal_connect(menu, "deactivate", G_CALLBACK(on_menu_done), NULL);
    gtk_widget_show_all(menu);
    gtk_menu_popup_at_pointer(GTK_MENU(menu), ev);
    return TRUE;
}
#endif

int orb_gtk_menu_self_test(void) {
    const char *core = orb_menu_project_slug("project:core");
    return core && strcmp(core, "core") == 0 && !orb_menu_project_slug("project:") && !orb_menu_project_slug("m:1") && !orb_menu_project_slug(NULL);
}
