/* Anchored sidebar menus, folder move submenu, multi-selection & cut/copy/paste. */
#define _POSIX_C_SOURCE 200809L
#include "gtk_menu.h"
#include "gtk_chrome.h"
#include "gtk_icons.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#if defined(ORB_HAS_WEBKITGTK)
#include <webkit2/webkit2.h>
#endif
const char *orb_menu_project_slug(const char *target) { return (!target || strncmp(target, "project:", 8) != 0 || !target[8]) ? NULL : target + 8; }
#if defined(ORB_HAS_WEBKITGTK)
static gboolean sidebar_cut_active;
static GtkWidget *sel_list;
static GHashTable *sel, *cut_set;
static char *sel_anchor, *cut_proj, *cut_fld, *hov_id, *act_id;
void orb_sidebar_mark_cut(gboolean active) { sidebar_cut_active = active; }
gboolean orb_sidebar_has_cut(void) { return sidebar_cut_active; }
void orb_sidebar_hover(const char *rid, gboolean enter) { if (enter && rid && *rid) { g_free(hov_id); hov_id = g_strdup(rid); } else if (!enter && (!rid || !g_strcmp0(hov_id, rid))) g_clear_pointer(&hov_id, g_free); }
void orb_sidebar_set_active(const char *rid) { g_free(act_id); act_id = (rid && *rid) ? g_strdup(rid) : NULL; }
void orb_sidebar_mark_cut_target(const char *ids, const char *proj, const char *fld, gboolean copy) {
    sidebar_cut_active = TRUE; if (!cut_set) cut_set = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, NULL);
    g_hash_table_remove_all(cut_set); g_clear_pointer(&cut_proj, g_free); g_clear_pointer(&cut_fld, g_free);
    if (!copy && ids && *ids) { char **v = g_strsplit(ids, " ", -1); for (char **p = v; *p; ++p) if (**p) g_hash_table_add(cut_set, g_str_has_prefix(*p, "m:") || g_str_has_prefix(*p, "pf:") || g_str_has_prefix(*p, "folder:") ? g_strdup(*p) : g_strdup_printf("m:%s", *p)); g_strfreev(v); }
    if (!copy && proj && *proj && fld && *fld) { cut_proj = g_strdup(proj); cut_fld = g_strdup(fld); g_hash_table_add(cut_set, g_strdup_printf("folder:%s:%s", proj, fld)); }
    if (sel_list) orb_sel_sync(sel_list);
}
void orb_sidebar_clear_cut(GtkWidget *wv) { sidebar_cut_active = FALSE; if (cut_set) g_hash_table_remove_all(cut_set); g_clear_pointer(&cut_proj, g_free); g_clear_pointer(&cut_fld, g_free); if (sel_list) orb_sel_sync(sel_list); if (wv) orb_eval_project_action(wv, "cancel-cut", "_", NULL); }
typedef struct { GtkWidget *wv, *row; const char *action; char *id, *arg; } MenuAct;
static void free_act(gpointer p, GClosure *cl) { (void)cl; MenuAct *a = p; g_free(a->id); g_free(a->arg); g_free(a); }
static void run_action(GtkWidget *wv, const char *action, const char *id, const char *arg) {
    char *a = orb_json_escape_string(action), *i = orb_json_escape_string(id), *g = orb_json_escape_string(arg ? arg : "");
    if (a && i && g) { char *js = g_strdup_printf("window.__ORB_NATIVE_MISSION_ACTION__&&window.__ORB_NATIVE_MISSION_ACTION__(%s,%s,%s);", a, i, g); webkit_web_view_evaluate_javascript(WEBKIT_WEB_VIEW(wv), js, -1, NULL, NULL, NULL, NULL, NULL); g_free(js); }
    free(a); free(i); free(g);
}
static gboolean destroy_later(gpointer w) {
    if (GTK_IS_MENU(w) && gtk_menu_get_attach_widget(GTK_MENU(w))) gtk_menu_detach(GTK_MENU(w));
    return gtk_widget_destroy(GTK_WIDGET(w)), g_object_unref(w), G_SOURCE_REMOVE;
}
static void on_item(GtkMenuItem *mi, gpointer ud) {
    (void)mi; MenuAct *a = ud;
    if (!strcmp(a->action, "rename")) orb_inline_rename(a->wv, a->row, "mission", a->id, a->arg);
    else if (!strcmp(a->action, "clear")) { if (sel_list) orb_sel_clear(sel_list); }
    else if (!strcmp(a->action, "cut")) { orb_sidebar_mark_cut_target(a->id, NULL, NULL, FALSE); run_action(a->wv, "cut", a->id, ""); }
    else if (!strcmp(a->action, "paste")) { orb_sidebar_clear_cut(NULL); orb_eval_project_action(a->wv, "paste", a->arg, NULL); }
    else if (!strcmp(a->action, "delete") || !strcmp(a->action, "move") || !strcmp(a->action, "move-picker")) {
        run_action(a->wv, a->action, a->id, a->arg);
        if (sel_list) orb_sel_clear(sel_list);
    } else {
        char **ids = g_strsplit(a->id, " ", -1);
        for (char **i = ids; *i; ++i) if (**i) run_action(a->wv, a->action, *i, a->arg);
        g_strfreev(ids);
    }
}
static void move_page(GtkWidget *menu, GtkWidget *moves, const char *label) {
    gtk_menu_item_set_submenu(GTK_MENU_ITEM(orb_menu_row(menu, label, "folder-symbolic")), moves);
}
static void add_item(GtkWidget *menu, const char *label, GtkWidget *wv, GtkWidget *row, const char *action, const char *id, const char *arg) {
    GtkWidget *it = orb_menu_row(menu, label, orb_menu_icon_name(action));
    MenuAct *a = g_new0(MenuAct, 1); a->wv = wv; a->row = row; a->action = action; a->id = g_strdup(id); a->arg = g_strdup(arg ? arg : "");
    g_signal_connect_data(it, "activate", G_CALLBACK(on_item), a, free_act, 0);
}
static void closed(GtkMenuShell *menu, gpointer data) { (void)data; g_idle_add(destroy_later, g_object_ref(menu)); }
static GtkWidget *move_submenu(GtkWidget *wv, GtkWidget *list, const char *id, const char *cur_proj, const char *cur_folder) {
    GtkWidget *sub = orb_menu_page(); int n = 0; const char *cf = cur_folder ? cur_folder : "";
    GList *rows = gtk_container_get_children(GTK_CONTAINER(list));
    if (cur_proj && *cur_proj && *cf) { add_item(sub, "Move to project root", wv, NULL, "move", id, cur_proj); orb_menu_separator(sub); ++n; }
    for (GList *l = rows; l; l = l->next) {
        const char *kind = g_object_get_data(G_OBJECT(l->data), "orb-kind"), *slug = orb_menu_project_slug(g_object_get_data(G_OBJECT(l->data), "orb-target"));
        const char *name = g_object_get_data(G_OBJECT(l->data), "orb-title"), *fstr = g_object_get_data(G_OBJECT(l->data), "orb-folders");
        if (!kind || strcmp(kind, "project") != 0 || !slug) continue;
        const char *label = (name && *name) ? name : slug;
        if (fstr && *fstr) {
            GtkWidget *psub = orb_menu_page(); int pn = 0;
            if (g_strcmp0(slug, cur_proj) != 0 || *cf) { g_autofree char *rl = g_strdup_printf("%s (root)", label); add_item(psub, rl, wv, NULL, "move", id, slug); ++pn; }
            char **flist = g_strsplit(fstr, "\n", -1);
            for (char **fp = flist; *fp; ++fp) {
                if (!**fp || (g_strcmp0(slug, cur_proj) == 0 && g_strcmp0(*fp, cf) == 0)) continue;
                if (pn == 1 && (g_strcmp0(slug, cur_proj) != 0 || *cf)) orb_menu_separator(psub);
                g_autofree char *dst = g_strdup_printf("%s:%s", slug, *fp);
                add_item(psub, *fp, wv, NULL, "move", id, dst); ++pn;
            }
            g_strfreev(flist);
            if (pn) { move_page(sub, psub, label); ++n; } else gtk_widget_destroy(psub);
        } else if (g_strcmp0(slug, cur_proj) != 0 || *cf) { add_item(sub, label, wv, NULL, "move", id, slug); ++n; }
    }
    g_list_free(rows);
    if (n) orb_menu_separator(sub);
    add_item(sub, "Move to _folder\xE2\x80\xA6", wv, NULL, "move-picker", id, "");
    return sub;
}
static gboolean selectable(GtkWidget *row) {
    const char *k = g_object_get_data(G_OBJECT(row), "orb-kind");
    return k && (!strcmp(k, "mission") || !strcmp(k, "project") || !strcmp(k, "folder") || !strcmp(k, "file"));
}
static const char *row_id(GtkWidget *row) { return g_object_get_data(G_OBJECT(row), "orb-row-id"); }
void orb_sel_sync(GtkWidget *list) {
    sel_list = list; GList *rows = gtk_container_get_children(GTK_CONTAINER(list)); size_t cfl = cut_fld ? strlen(cut_fld) : 0;
    GHashTable *live = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, NULL);
    for (GList *l = rows; l; l = l->next) {
        const char *id = row_id(l->data), *rp = g_object_get_data(G_OBJECT(l->data), "orb-project"), *rf = g_object_get_data(G_OBJECT(l->data), "orb-folder");
        gboolean on = sel && id && g_hash_table_contains(sel, id), in_cf = cut_proj && cut_fld && !g_strcmp0(rp, cut_proj) && rf && !strncmp(rf, cut_fld, cfl) && (!rf[cfl] || rf[cfl] == '/');
        gboolean cut = in_cf || (cut_set && id && g_hash_table_contains(cut_set, id)); GtkStyleContext *sc = gtk_widget_get_style_context(l->data);
        if (on) { g_hash_table_add(live, g_strdup(id)); gtk_style_context_add_class(sc, "orb-multi"); } else gtk_style_context_remove_class(sc, "orb-multi");
        if (cut) gtk_style_context_add_class(sc, "orb-cut"); else gtk_style_context_remove_class(sc, "orb-cut");
        if (!GTK_IS_OVERLAY(list)) gtk_widget_set_opacity(l->data, cut ? 0.45 : 1.0);
        gtk_widget_queue_draw(l->data);
    }
    g_list_free(rows); if (sel) g_hash_table_destroy(sel); sel = live;
}
GtkWidget *orb_sidebar_target(GtkWindow *win, GtkWidget *list) {
    GtkWidget *f = win ? gtk_window_get_focus(win) : NULL, *h = NULL, *a = NULL; if (f && selectable(f)) return f;
    GList *rows = list ? gtk_container_get_children(GTK_CONTAINER(list)) : NULL;
    for (GList *l = rows; l; l = l->next) { const char *id = row_id(l->data); if (!id || !selectable(l->data)) continue; if (hov_id && !strcmp(id, hov_id)) h = l->data; if (act_id && !strcmp(id, act_id)) a = l->data; }
    return g_list_free(rows), h ? h : a;
}
gboolean orb_sel_clear(GtkWidget *list) {
    gboolean had = sel && g_hash_table_size(sel) > 0;
    if (sel) g_hash_table_remove_all(sel);
    g_clear_pointer(&sel_anchor, g_free); orb_sel_sync(list); return had;
}
gboolean orb_sel_click(GtkWidget *list, GtkWidget *row, gboolean extend) {
    const char *id = row_id(row); if (!id || !selectable(row)) return FALSE;
    if (!sel) sel = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, NULL);
    if (extend && sel_anchor) {
        int in = 0; GList *rows = gtk_container_get_children(GTK_CONTAINER(list));
        for (GList *l = rows; l; l = l->next) {
            const char *rid = row_id(l->data); int edge = rid && (!strcmp(rid, sel_anchor) || !strcmp(rid, id));
            if ((edge || in) && selectable(l->data)) g_hash_table_add(sel, g_strdup(rid));
            if (edge && strcmp(sel_anchor, id) != 0) in = !in;
        }
        g_list_free(rows);
    } else {
        if (!g_hash_table_remove(sel, id)) g_hash_table_add(sel, g_strdup(id));
        g_free(sel_anchor); sel_anchor = g_strdup(id);
    }
    return orb_sel_sync(list), TRUE;
}
static char *sel_missions(int *n, int *others, int *archived) {
    GString *ids = g_string_new(""); *n = *others = *archived = 0;
    GList *rows = sel && sel_list ? gtk_container_get_children(GTK_CONTAINER(sel_list)) : NULL;
    for (GList *l = rows; l; l = l->next) {
        const char *id = row_id(l->data), *st = g_object_get_data(G_OBJECT(l->data), "orb-status");
        if (!id || !g_hash_table_contains(sel, id)) continue;
        if (strncmp(id, "m:", 2) != 0) { ++*others; continue; }
        g_string_append_printf(ids, "%s%s", ids->len ? " " : "", id + 2); ++*n; *archived += !g_strcmp0(st, "acknowledged");
    }
    return g_list_free(rows), g_string_free(ids, *n == 0);
}
gboolean orb_sel_delete(GtkWidget *wv, GtkWidget *list, const char *fallback) {
    int n, others, archived; char *ids = sel_missions(&n, &others, &archived);
    const char *one = fallback && !strncmp(fallback, "m:", 2) ? fallback + 2 : NULL;
    if (!ids && !one) return FALSE;
    return run_action(wv, "delete", ids ? ids : one, ids ? ids : one), g_free(ids), orb_sel_clear(list), TRUE;
}
gboolean orb_sidebar_cut_copy(GtkWidget *wv, GtkWidget *list, GtkWidget *focus, gboolean copy) {
    int n, others, archived; char *ids = sel_missions(&n, &others, &archived);
    if (!copy && ids && !others) return orb_sidebar_mark_cut_target(ids, NULL, NULL, FALSE), run_action(wv, "cut", ids, ""), g_free(ids), orb_sel_clear(list), TRUE;
    g_free(ids); if (!focus) return FALSE;
    const char *k = g_object_get_data(G_OBJECT(focus), "orb-kind"), *rid = row_id(focus), *proj = g_object_get_data(G_OBJECT(focus), "orb-project"), *fld = g_object_get_data(G_OBJECT(focus), "orb-folder");
    if (!k || !rid) return FALSE;
    if (!strcmp(k, "mission") && !strncmp(rid, "m:", 2)) return copy ? run_action(wv, "copy-id", rid + 2, "") : (orb_sidebar_mark_cut_target(rid, NULL, NULL, FALSE), run_action(wv, "cut", rid + 2, "")), TRUE;
    if (!strcmp(k, "folder") && proj && *proj && fld && *fld) { g_autofree char *t = g_strdup_printf("%s:%s", proj, fld); return orb_sidebar_mark_cut_target(NULL, proj, fld, copy), orb_eval_project_action(wv, copy ? "copy" : "cut", t, NULL), TRUE; }
    if (!strcmp(k, "file") && !strncmp(rid, "pf:", 3)) return orb_sidebar_mark_cut_target(rid, NULL, NULL, copy), orb_eval_project_action(wv, copy ? "copy-file" : "cut-file", rid + 3, NULL), TRUE;
    return FALSE;
}
static void bulk_menu(GtkWidget *wv, GtkWidget *list, GtkWidget *menu) {
    int n, others, archived; char *ids = sel_missions(&n, &others, &archived), label[96];
    if (!ids || others) { snprintf(label, sizeof(label), "%u items selected", sel ? g_hash_table_size(sel) : 0); gtk_widget_set_sensitive(orb_menu_row(menu, label, NULL), FALSE); }
    else {
        snprintf(label, sizeof(label), "_Move %d agents to", n); move_page(menu, move_submenu(wv, list, ids, NULL, NULL), label);
        snprintf(label, sizeof(label), "Cu_t %d agents", n); add_item(menu, label, wv, NULL, "cut", ids, NULL);
        if (archived < n) { snprintf(label, sizeof(label), "_Archive %d conversations", n - archived); add_item(menu, label, wv, NULL, "archive", ids, NULL); }
        if (archived > 0) { snprintf(label, sizeof(label), "R_estore %d conversations", archived); add_item(menu, label, wv, NULL, "restore", ids, NULL); }
        orb_menu_separator(menu); snprintf(label, sizeof(label), "_Delete %d agents\xE2\x80\xA6", n); add_item(menu, label, wv, NULL, "delete", ids, ids);
    }
    orb_menu_separator(menu); add_item(menu, "_Clear selection", wv, NULL, "clear", "", NULL); g_free(ids);
}
gboolean orb_gtk_row_context_menu(GtkWidget *wv, GtkWidget *list, GtkWidget *row, const GdkEvent *ev) {
    if (sel && g_hash_table_size(sel) && (!row_id(row) || !g_hash_table_contains(sel, row_id(row)))) orb_sel_clear(list);
    gboolean bulk = wv && sel && g_hash_table_size(sel) > 1;
    const char *kind = g_object_get_data(G_OBJECT(row), "orb-kind"), *target = g_object_get_data(G_OBJECT(row), "orb-target"), *rid = row_id(row);
    const char *slug = orb_menu_project_slug(target), *proj = g_object_get_data(G_OBJECT(row), "orb-project"), *folder = g_object_get_data(G_OBJECT(row), "orb-folder");
    gboolean is_project = !bulk && wv && slug && !g_strcmp0(kind, "project");
    gboolean is_folder = !bulk && wv && proj && *proj && folder && *folder && !g_strcmp0(kind, "folder");
    gboolean is_file = !bulk && wv && proj && *proj && rid && !strncmp(rid, "pf:", 3) && !g_strcmp0(kind, "file");
    gboolean is_mission = !bulk && wv && !g_strcmp0(kind, "mission") && target && !strncmp(target, "m:", 2) && target[2];
    if (!bulk && !is_project && !is_folder && !is_file && !is_mission) return FALSE;
    GtkWidget *menu = orb_menu_page();
    if (bulk) bulk_menu(wv, list, menu);
    else if (is_project) orb_project_menu_populate(wv, menu, row, slug, sidebar_cut_active);
    else if (is_folder) orb_folder_menu_populate(wv, menu, row, proj, folder, sidebar_cut_active);
    else if (is_file) orb_file_menu_populate(wv, menu, row, proj, strchr(rid + 3, ':') ? strchr(rid + 3, ':') + 1 : rid + 3, folder, sidebar_cut_active);
    else {
        const char *id = target + 2, *title = g_object_get_data(G_OBJECT(row), "orb-title"), *status = g_object_get_data(G_OBJECT(row), "orb-status");
        gboolean archived = !g_strcmp0(status, "acknowledged") || !g_strcmp0(status, "archived");
        if (sidebar_cut_active && proj && *proj && !archived) {
            g_autofree char *pt = (folder && *folder) ? g_strdup_printf("%s:%s", proj, folder) : g_strdup(proj);
            add_item(menu, "_Paste", wv, row, "paste", id, pt); orb_menu_separator(menu);
        }
        add_item(menu, "_Rename", wv, row, "rename", id, title);
        add_item(menu, "Cu_t", wv, row, "cut", id, NULL);
        move_page(menu, move_submenu(wv, list, id, proj, folder), "_Move to");
        orb_menu_separator(menu);
        add_item(menu, "_Copy mission ID", wv, row, "copy-id", id, NULL);
        add_item(menu, "Mission _settings", wv, row, "settings", id, NULL);
        orb_menu_separator(menu);
        add_item(menu, archived ? "R_estore" : "_Archive", wv, row, archived ? "restore" : "archive", id, NULL);
        add_item(menu, "_Delete\xE2\x80\xA6", wv, row, "delete", id, id);
    }
    g_signal_connect(menu, "selection-done", G_CALLBACK(closed), NULL);
    return orb_menu_popup(menu, row, ev), TRUE;
}
#endif
int orb_gtk_menu_self_test(void) {
    const char *core = orb_menu_project_slug("project:core");
    return core && strcmp(core, "core") == 0 && !orb_menu_project_slug("project:") && !orb_menu_project_slug("m:1") && !orb_menu_project_slug(NULL);
}
