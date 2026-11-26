/* Shared layout, squircle menu surface, inline rename & project/folder/file menus. */
#include "gtk_menu.h"
#include "gtk_chrome.h"
#include "gtk_icons.h"
#include <stdlib.h>
#include <string.h>
#if defined(ORB_HAS_WEBKITGTK)
#include "gtk_squircle.h"
#include <webkit2/webkit2.h>

GtkWidget *orb_menu_page(void) {
    GtkWidget *menu = gtk_menu_new();
    gtk_menu_set_reserve_toggle_size(GTK_MENU(menu), FALSE);
    gtk_widget_set_size_request(menu, 196, -1);
    gtk_widget_set_app_paintable(menu, TRUE);
    gtk_style_context_add_class(gtk_widget_get_style_context(menu), "orb-ctx");
    g_signal_connect(menu, "draw", G_CALLBACK(orb_draw_squircle_menu), NULL);
    GtkWidget *top = gtk_widget_get_toplevel(menu);
    if (top && GTK_IS_WINDOW(top)) {
        GdkVisual *rgba = gdk_screen_get_rgba_visual(gtk_widget_get_screen(top));
        if (rgba) gtk_widget_set_visual(top, rgba);
        gtk_widget_set_app_paintable(top, TRUE);
    }
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

void orb_eval_project_action(GtkWidget *wv, const char *action, const char *target, const char *arg) {
    if (!wv || !action || !target) return;
    char *act = orb_json_escape_string(action), *tgt = orb_json_escape_string(target);
    char *a = (arg && *arg) ? orb_json_escape_string(arg) : NULL;
    if (act && tgt) {
        char *js = a ? g_strdup_printf("window.__ORB_NATIVE_PROJECT_ACTION__&&window.__ORB_NATIVE_PROJECT_ACTION__(%s,%s,%s);", act, tgt, a)
                     : g_strdup_printf("window.__ORB_NATIVE_PROJECT_ACTION__&&window.__ORB_NATIVE_PROJECT_ACTION__(%s,%s);", act, tgt);
        webkit_web_view_evaluate_javascript(WEBKIT_WEB_VIEW(wv), js, -1, NULL, NULL, NULL, NULL, NULL);
        g_free(js);
    }
    free(act); free(tgt); free(a);
}

typedef struct {
    GtkWidget *wv, *ov, *row, *entry;
    char *mode, *id, *title;
    gboolean done, cancelled, restore_focus;
} InlineRename;

static gboolean finish_inline_rename(gpointer p) {
    InlineRename *r = p;
    if (r->ov && GTK_IS_WIDGET(r->ov) && g_object_get_data(G_OBJECT(r->ov), "orb-active-rename") == r->entry)
        g_object_set_data(G_OBJECT(r->ov), "orb-active-rename", NULL);
    if (r->entry && GTK_IS_WIDGET(r->entry)) gtk_widget_destroy(r->entry);
    if (r->restore_focus && r->row && GTK_IS_WIDGET(r->row) && gtk_widget_get_mapped(r->row))
        gtk_widget_grab_focus(r->row);
    if (r->ov) g_object_unref(r->ov);
    if (r->row) g_object_unref(r->row);
    g_free(r->mode); g_free(r->id); g_free(r->title); g_free(r);
    return G_SOURCE_REMOVE;
}

static void commit_inline_rename(InlineRename *r, gboolean restore_focus) {
    if (r->done) return;
    r->done = TRUE; r->restore_focus = restore_focus;
    if (!r->cancelled && r->entry && GTK_IS_ENTRY(r->entry)) {
        g_autofree char *next = g_strdup(gtk_entry_get_text(GTK_ENTRY(r->entry)));
        if (*g_strstrip(next) && g_strcmp0(next, r->title) != 0) {
            if (g_strcmp0(r->mode, "mission") == 0) {
                char *i = orb_json_escape_string(r->id), *g = orb_json_escape_string(next);
                if (i && g) {
                    char *js = g_strdup_printf("window.__ORB_NATIVE_MISSION_ACTION__&&window.__ORB_NATIVE_MISSION_ACTION__(\"rename\",%s,%s);", i, g);
                    webkit_web_view_evaluate_javascript(WEBKIT_WEB_VIEW(r->wv), js, -1, NULL, NULL, NULL, NULL, NULL);
                    g_free(js);
                }
                free(i); free(g);
            } else {
                orb_eval_project_action(r->wv, r->mode, r->id, next);
            }
        }
    }
    g_idle_add(finish_inline_rename, r);
}

static void on_inline_activate(GtkEntry *e, gpointer ud) { (void)e; commit_inline_rename(ud, TRUE); }
static gboolean on_inline_focus_out(GtkWidget *w, GdkEventFocus *ev, gpointer ud) { (void)w; (void)ev; commit_inline_rename(ud, FALSE); return FALSE; }
static gboolean on_inline_key(GtkWidget *w, GdkEventKey *ev, gpointer ud) {
    (void)w; InlineRename *r = ud;
    if (ev->keyval == GDK_KEY_Escape) { r->cancelled = TRUE; commit_inline_rename(r, TRUE); return TRUE; }
    return FALSE;
}
void orb_inline_rename(GtkWidget *wv, GtkWidget *row, const char *mode, const char *id, const char *title) {
    GtkWidget *ov = row ? gtk_widget_get_ancestor(row, GTK_TYPE_OVERLAY) : NULL;
    if (!wv || !ov || !id || !*id) return;
    GtkWidget *prev = g_object_get_data(G_OBJECT(ov), "orb-active-rename");
    if (prev && GTK_IS_WIDGET(prev)) gtk_widget_destroy(prev);
    int depth = GPOINTER_TO_INT(g_object_get_data(G_OBJECT(row), "orb-depth"));
    int inset = 26 + (depth > 8 ? 8 : (depth < 0 ? 0 : depth)) * 12;
    GdkRectangle *hit = g_object_get_data(G_OBJECT(row), "orb-hit"), rect;
    if (hit) {
        rect = (GdkRectangle){ hit->x + inset, hit->y + 1, MAX(72, hit->width - inset - 4), MAX(24, hit->height - 2) };
    } else {
        GtkAllocation ra; gtk_widget_get_allocation(row, &ra); int rx = 0, ry = 0;
        gtk_widget_translate_coordinates(row, ov, inset, 1, &rx, &ry);
        rect = (GdkRectangle){ rx, ry, MAX(72, ra.width - inset - 6), MAX(24, ra.height - 2) };
    }
    GtkWidget *entry = gtk_entry_new();
    gtk_entry_set_has_frame(GTK_ENTRY(entry), FALSE);
    gtk_widget_set_app_paintable(entry, TRUE);
    gtk_style_context_add_class(gtk_widget_get_style_context(entry), "orb-inline-rename");
    g_signal_connect(entry, "draw", G_CALLBACK(orb_draw_squircle_entry), NULL);
    gtk_entry_set_text(GTK_ENTRY(entry), title ? title : "");
    gtk_entry_set_max_length(GTK_ENTRY(entry), 200);
    g_object_set_data_full(G_OBJECT(entry), "orb-hit", g_memdup2(&rect, sizeof rect), g_free);
    g_object_set_data(G_OBJECT(ov), "orb-active-rename", entry);
    InlineRename *r = g_new0(InlineRename, 1);
    r->wv = wv; r->ov = g_object_ref(ov); r->row = g_object_ref(row); r->entry = entry;
    r->mode = g_strdup(mode); r->id = g_strdup(id); r->title = g_strdup(title ? title : "");
    g_signal_connect(entry, "activate", G_CALLBACK(on_inline_activate), r);
    g_signal_connect(entry, "key-press-event", G_CALLBACK(on_inline_key), r);
    g_signal_connect(entry, "focus-out-event", G_CALLBACK(on_inline_focus_out), r);
    gtk_overlay_add_overlay(GTK_OVERLAY(ov), entry);
    gtk_overlay_set_overlay_pass_through(GTK_OVERLAY(ov), entry, FALSE);
    gtk_widget_show(entry);
    gtk_widget_grab_focus(entry);
    gtk_editable_select_region(GTK_EDITABLE(entry), 0, -1);
}

typedef struct { GtkWidget *wv, *row; const char *action; char *target, *title; gboolean inline_ren; } ProjAct;
static void free_proj_act(gpointer p, GClosure *cl) { (void)cl; ProjAct *a = p; g_free(a->target); g_free(a->title); g_free(a); }
static void on_proj_item(GtkMenuItem *mi, gpointer ud) {
    (void)mi; ProjAct *a = ud;
    if (!a || !a->wv) return;
    if (a->inline_ren && a->row && gtk_widget_get_ancestor(a->row, GTK_TYPE_OVERLAY)) {
        orb_inline_rename(a->wv, a->row, a->action, a->target, a->title);
        return;
    }
    if (!strcmp(a->action, "cut") || !strcmp(a->action, "copy") || !strcmp(a->action, "cut-file") || !strcmp(a->action, "copy-file"))
        orb_sidebar_mark_cut(TRUE);
    orb_eval_project_action(a->wv, a->action, a->target, NULL);
}
static void add_proj_item(GtkWidget *menu, const char *label, const char *icon, GtkWidget *wv, GtkWidget *row, const char *action, const char *target, const char *inline_title) {
    GtkWidget *it = orb_menu_row(menu, label, icon);
    ProjAct *a = g_new0(ProjAct, 1);
    a->wv = wv; a->row = row; a->action = action; a->target = g_strdup(target);
    a->title = inline_title ? g_strdup(inline_title) : NULL; a->inline_ren = inline_title != NULL;
    g_signal_connect_data(it, "activate", G_CALLBACK(on_proj_item), a, free_proj_act, 0);
}

void orb_project_menu_populate(GtkWidget *wv, GtkWidget *menu, GtkWidget *row, const char *slug, gboolean has_cut) {
    const char *title = row ? g_object_get_data(G_OBJECT(row), "orb-title") : slug;
    add_proj_item(menu, "_New agent", "list-add-symbolic", wv, row, "new-agent", slug, NULL);
    add_proj_item(menu, "_Cloud agent", "weather-overcast-symbolic", wv, row, "new-cloud-agent", slug, NULL);
    orb_menu_separator(menu);
    add_proj_item(menu, "New _folder", "folder-new-symbolic", wv, row, "new-folder", slug, NULL);
    if (has_cut) { orb_menu_separator(menu); add_proj_item(menu, "_Paste", orb_menu_icon_name("paste"), wv, row, "paste", slug, NULL); }
    orb_menu_separator(menu);
    add_proj_item(menu, "Project _settings", orb_menu_icon_name("settings"), wv, row, "settings", slug, NULL);
    add_proj_item(menu, "_Rename", orb_menu_icon_name("rename"), wv, row, "rename", slug, title ? title : slug);
    add_proj_item(menu, "_Archive", orb_menu_icon_name("archive"), wv, row, "archive", slug, NULL);
    add_proj_item(menu, "_Delete project\xE2\x80\xA6", orb_menu_icon_name("delete"), wv, row, "delete", slug, NULL);
}

void orb_folder_menu_populate(GtkWidget *wv, GtkWidget *menu, GtkWidget *row, const char *slug, const char *folder, gboolean has_cut) {
    g_autofree char *tgt = g_strdup_printf("%s:%s", slug, folder);
    const char *title = row ? g_object_get_data(G_OBJECT(row), "orb-title") : folder;
    add_proj_item(menu, "_New agent", "list-add-symbolic", wv, row, "new-agent", tgt, NULL);
    add_proj_item(menu, "_Cloud agent", "weather-overcast-symbolic", wv, row, "new-cloud-agent", tgt, NULL);
    orb_menu_separator(menu);
    add_proj_item(menu, "New _file", "file", wv, row, "new-file", tgt, NULL);
    add_proj_item(menu, "New _folder", "folder-new-symbolic", wv, row, "new-folder", tgt, NULL);
    if (has_cut) { orb_menu_separator(menu); add_proj_item(menu, "_Paste", orb_menu_icon_name("paste"), wv, row, "paste", tgt, NULL); }
    orb_menu_separator(menu);
    add_proj_item(menu, "_Rename", orb_menu_icon_name("rename"), wv, row, "rename", tgt, title ? title : folder);
    add_proj_item(menu, "_Move\xE2\x80\xA6", orb_menu_icon_name("move-picker"), wv, row, "move-picker", tgt, NULL);
    add_proj_item(menu, "Cu_t", orb_menu_icon_name("cut"), wv, row, "cut", tgt, NULL);
    add_proj_item(menu, "_Copy", orb_menu_icon_name("copy"), wv, row, "copy", tgt, NULL);
    orb_menu_separator(menu);
    add_proj_item(menu, "_Delete\xE2\x80\xA6", orb_menu_icon_name("delete"), wv, row, "delete", tgt, NULL);
}

void orb_file_menu_populate(GtkWidget *wv, GtkWidget *menu, GtkWidget *row, const char *slug, const char *file_path, const char *parent_folder, gboolean has_cut) {
    g_autofree char *tgt = g_strdup_printf("%s:%s", slug, file_path);
    g_autofree char *ptgt = (parent_folder && *parent_folder) ? g_strdup_printf("%s:%s", slug, parent_folder) : g_strdup(slug);
    const char *title = row ? g_object_get_data(G_OBJECT(row), "orb-title") : file_path;
    if (has_cut) { add_proj_item(menu, "_Paste", orb_menu_icon_name("paste"), wv, row, "paste", ptgt, NULL); orb_menu_separator(menu); }
    add_proj_item(menu, "_Rename", orb_menu_icon_name("rename-file"), wv, row, "rename-file", tgt, title ? title : file_path);
    add_proj_item(menu, "_Move\xE2\x80\xA6", orb_menu_icon_name("move-file"), wv, row, "move-file", tgt, NULL);
    add_proj_item(menu, "Cu_t", orb_menu_icon_name("cut-file"), wv, row, "cut-file", tgt, NULL);
    add_proj_item(menu, "_Copy", orb_menu_icon_name("copy-file"), wv, row, "copy-file", tgt, NULL);
    orb_menu_separator(menu);
    add_proj_item(menu, "_Delete\xE2\x80\xA6", orb_menu_icon_name("delete-file"), wv, row, "delete-file", tgt, NULL);
}
#endif

#if defined(ORB_HAS_WEBKITGTK)
gboolean orb_sidebar_paste(GtkWidget *wv, GtkWidget *focus) {
    if (!wv || !focus) return FALSE;
    const char *proj = g_object_get_data(G_OBJECT(focus), "orb-project"), *fld = g_object_get_data(G_OBJECT(focus), "orb-folder");
    if (!proj || !*proj) return FALSE;
    g_autofree char *t = (fld && *fld) ? g_strdup_printf("%s:%s", proj, fld) : g_strdup(proj);
    orb_eval_project_action(wv, "paste", t, NULL); return TRUE;
}
gboolean orb_sidebar_rename_focused(GtkWidget *wv, GtkWidget *focus) {
    if (!wv || !focus) return FALSE;
    const char *k = g_object_get_data(G_OBJECT(focus), "orb-kind"), *rid = g_object_get_data(G_OBJECT(focus), "orb-row-id"), *title = g_object_get_data(G_OBJECT(focus), "orb-title");
    const char *proj = g_object_get_data(G_OBJECT(focus), "orb-project"), *fld = g_object_get_data(G_OBJECT(focus), "orb-folder");
    if (!k || !rid) return FALSE;
    if (!strcmp(k, "mission") && !strncmp(rid, "m:", 2)) return orb_inline_rename(wv, focus, "mission", rid + 2, title), TRUE;
    if (!strcmp(k, "project") && proj && *proj) return orb_inline_rename(wv, focus, "rename", proj, title), TRUE;
    if (!strcmp(k, "folder") && proj && *proj && fld && *fld) { g_autofree char *t = g_strdup_printf("%s:%s", proj, fld); return orb_inline_rename(wv, focus, "rename", t, title), TRUE; }
    if (!strcmp(k, "file") && !strncmp(rid, "pf:", 3)) return orb_inline_rename(wv, focus, "rename-file", rid + 3, title), TRUE;
    return FALSE;
}
#endif
