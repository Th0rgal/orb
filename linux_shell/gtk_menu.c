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

const char *orb_menu_project_slug(const char *target) { return (!target || strncmp(target, "project:", 8) != 0 || !target[8]) ? NULL : target + 8; }

#if defined(ORB_HAS_WEBKITGTK)
typedef struct { GtkWidget *wv; const char *action; char *id, *arg; } MenuAct;
static void free_act(gpointer p, GClosure *cl) { (void)cl; MenuAct *a = p; g_free(a->id); g_free(a->arg); g_free(a); }

static void run_action(GtkWidget *wv, const char *action, const char *id, const char *arg) {
    char *a = orb_json_escape_string(action), *i = orb_json_escape_string(id), *g = orb_json_escape_string(arg ? arg : "");
    if (a && i && g) {
        char *js = g_strdup_printf("window.__ORB_NATIVE_MISSION_ACTION__&&window.__ORB_NATIVE_MISSION_ACTION__(%s,%s,%s);", a, i, g);
        webkit_web_view_evaluate_javascript(WEBKIT_WEB_VIEW(wv), js, -1, NULL, NULL, NULL, NULL, NULL);
        g_free(js);
    }
    free(a); free(i); free(g);
}

static void prompt_rename(GtkWidget *wv, const char *id, const char *title) {
    GtkWidget *top = gtk_widget_get_toplevel(wv);
    GtkWidget *dlg = gtk_dialog_new_with_buttons("Rename conversation", GTK_IS_WINDOW(top) ? GTK_WINDOW(top) : NULL,
                                                 GTK_DIALOG_MODAL | GTK_DIALOG_DESTROY_WITH_PARENT,
                                                 "_Cancel", GTK_RESPONSE_CANCEL, "_Rename", GTK_RESPONSE_ACCEPT, NULL);
    GtkWidget *entry = gtk_entry_new(), *area = gtk_dialog_get_content_area(GTK_DIALOG(dlg));
    gtk_entry_set_text(GTK_ENTRY(entry), title ? title : ""); gtk_entry_set_max_length(GTK_ENTRY(entry), 200); gtk_entry_set_activates_default(GTK_ENTRY(entry), TRUE);
    gtk_dialog_set_default_response(GTK_DIALOG(dlg), GTK_RESPONSE_ACCEPT); gtk_container_set_border_width(GTK_CONTAINER(area), 12);
    gtk_box_pack_start(GTK_BOX(area), entry, TRUE, TRUE, 0); gtk_widget_set_size_request(dlg, 380, -1); gtk_widget_show_all(dlg);
    if (gtk_dialog_run(GTK_DIALOG(dlg)) == GTK_RESPONSE_ACCEPT) {
        char *next = g_strstrip(g_strdup(gtk_entry_get_text(GTK_ENTRY(entry))));
        if (*next && g_strcmp0(next, title) != 0) {
            run_action(wv, "rename", id, next);
        }
        g_free(next);
    }
    gtk_widget_destroy(dlg);
}

static GtkWidget *sel_list;
static void on_item(GtkMenuItem *mi, gpointer ud) {
    (void)mi;
    MenuAct *a = ud;
    if (strcmp(a->action, "rename") == 0) {
        /* The dialog spins a nested loop; the menu (and `a`) may be freed meanwhile. */
        char *id = g_strdup(a->id), *title = g_strdup(a->arg);
        prompt_rename(a->wv, id, title);
        g_free(id);
        g_free(title);
    } else if (strcmp(a->action, "clear") == 0) {
        if (sel_list) { orb_sel_clear(sel_list); }
    } else if (strcmp(a->action, "delete") == 0) {
        run_action(a->wv, a->action, a->id, a->arg); /* one confirmation for the whole selection */
        if (sel_list) { orb_sel_clear(sel_list); }
    } else { /* bulk ids are space-separated; each runs the single-mission action */
        char **ids = g_strsplit(a->id, " ", -1);
        for (char **i = ids; *i; ++i) { if (**i) { run_action(a->wv, a->action, *i, a->arg); } }
        g_strfreev(ids);
    }
}

static void add_item(GtkWidget *menu, const char *label, GtkWidget *wv, const char *action, const char *id, const char *arg) {
    GtkWidget *it = gtk_menu_item_new_with_mnemonic(label);
    MenuAct *a = g_new0(MenuAct, 1); a->wv = wv; a->action = action; a->id = g_strdup(id); a->arg = g_strdup(arg ? arg : "");
    g_signal_connect_data(it, "activate", G_CALLBACK(on_item), a, free_act, 0);
    gtk_menu_shell_append(GTK_MENU_SHELL(menu), it);
}

static gboolean destroy_later(gpointer w) { gtk_widget_destroy(GTK_WIDGET(w)); return G_SOURCE_REMOVE; }

/* Activation fires after "deactivate"; destroy on idle so the item's handler runs first. */
static void on_menu_done(GtkMenuShell *m, gpointer ud) { (void)ud; g_idle_add(destroy_later, m); }

static GtkWidget *move_submenu(GtkWidget *wv, GtkWidget *list, const char *id, const char *current) {
    GtkWidget *sub = gtk_menu_new();
    int n = 0;
    GList *rows = gtk_container_get_children(GTK_CONTAINER(list));
    for (GList *l = rows; l; l = l->next) {
        const char *kind = g_object_get_data(G_OBJECT(l->data), "orb-kind");
        const char *slug = orb_menu_project_slug(g_object_get_data(G_OBJECT(l->data), "orb-target"));
        const char *name = g_object_get_data(G_OBJECT(l->data), "orb-title");
        if (kind && !strcmp(kind, "project") && slug && g_strcmp0(slug, current) != 0) { add_item(sub, name && *name ? name : slug, wv, "move", id, slug); ++n; }
    }
    g_list_free(rows);
    return n ? sub : (gtk_widget_destroy(sub), NULL);
}

/* Sidebar multi-selection (Ctrl/Super-click toggles, Shift-click extends from the anchor). */
static GHashTable *sel;
static char *sel_anchor;
static gboolean selectable(GtkWidget *row) {
    const char *k = g_object_get_data(G_OBJECT(row), "orb-kind");
    return k && (!strcmp(k, "mission") || !strcmp(k, "project") || !strcmp(k, "folder") || !strcmp(k, "file"));
}
static const char *row_id(GtkWidget *row) { return g_object_get_data(G_OBJECT(row), "orb-row-id"); }
void orb_sel_sync(GtkWidget *list) {
    sel_list = list;
    GList *rows = gtk_container_get_children(GTK_CONTAINER(list));
    GHashTable *live = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, NULL);
    for (GList *l = rows; l; l = l->next) {
        const char *id = row_id(l->data); gboolean on = sel && id && g_hash_table_contains(sel, id);
        if (on) { g_hash_table_add(live, g_strdup(id)); gtk_style_context_add_class(gtk_widget_get_style_context(l->data), "orb-multi"); }
        else { gtk_style_context_remove_class(gtk_widget_get_style_context(l->data), "orb-multi"); }
    }
    g_list_free(rows); if (sel) { g_hash_table_destroy(sel); } sel = live;
}
gboolean orb_sel_clear(GtkWidget *list) {
    gboolean had = sel && g_hash_table_size(sel) > 0;
    if (sel) { g_hash_table_remove_all(sel); }
    g_clear_pointer(&sel_anchor, g_free); orb_sel_sync(list); return had;
}
gboolean orb_sel_click(GtkWidget *list, GtkWidget *row, gboolean extend) {
    const char *id = row_id(row);
    if (!id || !selectable(row)) { return FALSE; }
    if (!sel) { sel = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, NULL); }
    if (extend && sel_anchor) {
        int in = 0; GList *rows = gtk_container_get_children(GTK_CONTAINER(list));
        for (GList *l = rows; l; l = l->next) {
            const char *rid = row_id(l->data); int edge = rid && (!strcmp(rid, sel_anchor) || !strcmp(rid, id));
            if (edge || in) { if (selectable(l->data)) { g_hash_table_add(sel, g_strdup(rid)); } }
            if (edge && strcmp(sel_anchor, id) != 0) { in = !in; }
        }
        g_list_free(rows);
    } else {
        if (!g_hash_table_remove(sel, id)) { g_hash_table_add(sel, g_strdup(id)); }
        g_free(sel_anchor); sel_anchor = g_strdup(id);
    }
    orb_sel_sync(list); return TRUE;
}
/* Space-separated mission ids of the selection (or NULL); `*others` counts non-mission rows. */
static char *sel_missions(int *n, int *others, int *archived) {
    GString *ids = g_string_new(""); *n = *others = *archived = 0;
    GList *rows = sel && sel_list ? gtk_container_get_children(GTK_CONTAINER(sel_list)) : NULL;
    for (GList *l = rows; l; l = l->next) {
        const char *id = row_id(l->data), *st = g_object_get_data(G_OBJECT(l->data), "orb-status");
        if (!id || !g_hash_table_contains(sel, id)) { continue; }
        if (strncmp(id, "m:", 2) != 0) { ++*others; continue; }
        g_string_append_printf(ids, "%s%s", ids->len ? " " : "", id + 2); ++*n; *archived += !g_strcmp0(st, "acknowledged");
    }
    g_list_free(rows); return g_string_free(ids, *n == 0);
}
gboolean orb_sel_delete(GtkWidget *wv, GtkWidget *list, const char *fallback) {
    int n, others, archived; char *ids = sel_missions(&n, &others, &archived);
    const char *one = fallback && !strncmp(fallback, "m:", 2) ? fallback + 2 : NULL;
    if (!ids && !one) { return FALSE; }
    run_action(wv, "delete", ids ? ids : one, ids ? ids : one); g_free(ids); orb_sel_clear(list); return TRUE;
}
static void bulk_menu(GtkWidget *wv, GtkWidget *list, GtkWidget *menu) {
    int n, others, archived; char *ids = sel_missions(&n, &others, &archived), label[96];
    if (!ids || others) {
        snprintf(label, sizeof(label), "%u items selected \xE2\x80\x94 no shared actions", sel ? g_hash_table_size(sel) : 0);
        GtkWidget *info = gtk_menu_item_new_with_label(label); gtk_widget_set_sensitive(info, FALSE); gtk_menu_shell_append(GTK_MENU_SHELL(menu), info);
    } else {
        GtkWidget *moves = move_submenu(wv, list, ids, NULL);
        if (moves) { snprintf(label, sizeof(label), "_Move %d agents to", n); GtkWidget *mv = gtk_menu_item_new_with_mnemonic(label); gtk_menu_item_set_submenu(GTK_MENU_ITEM(mv), moves); gtk_menu_shell_append(GTK_MENU_SHELL(menu), mv); }
        if (archived < n) { snprintf(label, sizeof(label), "_Archive %d conversations", n - archived); add_item(menu, label, wv, "archive", ids, NULL); }
        if (archived > 0) { snprintf(label, sizeof(label), "R_estore %d conversations", archived); add_item(menu, label, wv, "restore", ids, NULL); }
        gtk_menu_shell_append(GTK_MENU_SHELL(menu), gtk_separator_menu_item_new());
        snprintf(label, sizeof(label), "_Delete %d agents\xE2\x80\xA6", n); add_item(menu, label, wv, "delete", ids, ids);
    }
    gtk_menu_shell_append(GTK_MENU_SHELL(menu), gtk_separator_menu_item_new()); add_item(menu, "_Clear selection", wv, "clear", "", NULL);
    g_free(ids);
}

gboolean orb_gtk_row_context_menu(GtkWidget *wv, GtkWidget *list, GtkWidget *row, const GdkEvent *ev) {
    if (wv && sel && g_hash_table_size(sel) > 1 && row_id(row) && g_hash_table_contains(sel, row_id(row))) {
        GtkWidget *menu = gtk_menu_new(); bulk_menu(wv, list, menu); gtk_menu_attach_to_widget(GTK_MENU(menu), list, NULL);
        g_signal_connect(menu, "deactivate", G_CALLBACK(on_menu_done), NULL); gtk_widget_show_all(menu); gtk_menu_popup_at_pointer(GTK_MENU(menu), ev); return TRUE;
    }
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
