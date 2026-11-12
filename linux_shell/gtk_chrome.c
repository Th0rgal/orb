/* linux_shell/gtk_chrome.c — Hybrid Native Chrome GTK3 split view & Ctrl+K palette (<= 220 LOC). */
#define _POSIX_C_SOURCE 200809L
#include "gtk_chrome.h"
#include "gtk_icons.h"
#include "gtk_menu.h"
#include <arpa/inet.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>
#if defined(ORB_HAS_WEBKITGTK)
#include <jsc/jsc.h>
#endif
char *orb_json_escape_string(const char *s) {
    if (!s) { s = ""; }
    size_t len = strlen(s), j = 0; char *out = len <= 4096 ? malloc(len * 6 + 4) : NULL; if (!out) { return NULL; }
    out[j++] = '"'; for (size_t i = 0; i < len; ++i) { unsigned char c = (unsigned char)s[i]; if (c == '"' || c == '\\') { out[j++] = '\\'; out[j++] = (char)c; } else if (c < 0x20 || c == 0x7F) { j += (size_t)snprintf(out + j, 8, "\\u%04x", c); } else { out[j++] = (char)c; } }
    return out[j++] = '"', out[j] = '\0', out;
}
#if defined(ORB_HAS_WEBKITGTK)
typedef struct { GtkWidget *win, *wv, *paned, *sb_box, *sb_list, *back_btn, *fwd_btn, *foot_btn, *foot_badge, *pal_pop, *pal_entry, *pal_list; OrbIconSpinner spin; JSCContext *jsc; GIOChannel *sse_ch; guint sse_src, retry_src; GString *sse_buf; unsigned port; char token[128], *sb_scope; guint64 pal_gen, sb_req_gen, sb_scope_gen, sb_min_gen, sb_rev; int sb_inflight, sb_dirty, closed; } OrbGtkChrome;
typedef struct { OrbGtkChrome *c; unsigned port; char token[128], *body, *resp; int kind; guint64 gen; } RpcJob;
static int accept_sb_resp(char **cur_sc, guint64 *sc_gen, guint64 min_gen, guint64 *cur_rv, guint64 rg, const char *sc, double rv) {
    const char *cs = *cur_sc ? *cur_sc : ""; guint64 gate = *sc_gen > min_gen ? *sc_gen : min_gen;
    if (strcmp(sc, cs) != 0) { if (rg < gate) { return 0; } g_free(*cur_sc); *cur_sc = g_strdup(sc); *sc_gen = rg; *cur_rv = rv >= 0.0 ? (guint64)rv : 0; return 1; }
    if (rv >= 0.0) { if ((guint64)rv < *cur_rv) { return 0; } *cur_rv = (guint64)rv; } if (rg > *sc_gen) { *sc_gen = rg; } return 1;
}
static int connect_loopback(unsigned port, int nonblock) {
    int fd = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC | (nonblock ? SOCK_NONBLOCK : 0), 0); if (fd < 0) { return -1; }
    struct timeval tv = { .tv_sec = 2, .tv_usec = 0 }; if (!nonblock) { setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv)); setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv)); }
    struct sockaddr_in sa = { .sin_family = AF_INET, .sin_port = htons((uint16_t)port) }; sa.sin_addr.s_addr = htonl(INADDR_LOOPBACK); return (connect(fd, (struct sockaddr *)&sa, sizeof(sa)) < 0 && (!nonblock || errno != EINPROGRESS)) ? (close(fd), -1) : fd;
}
static char *jv_str(JSCValue *o, const char *k) { JSCValue *v = jsc_value_object_get_property(o, k); char *s = (v && jsc_value_is_string(v)) ? jsc_value_to_string(v) : g_strdup(""); if (v) { g_object_unref(v); } return s; }
static gint32 jv_int(JSCValue *o, const char *k) { JSCValue *v = jsc_value_object_get_property(o, k); gint32 n = (v && jsc_value_is_number(v)) ? jsc_value_to_int32(v) : 0; if (v) { g_object_unref(v); } return n; }
static double jv_num(JSCValue *o, const char *k) { JSCValue *v = jsc_value_object_get_property(o, k); double n = (v && jsc_value_is_number(v)) ? jsc_value_to_double(v) : -1.0; if (v) { g_object_unref(v); } return n; }
static gboolean jv_bool(JSCValue *o, const char *k) { JSCValue *v = jsc_value_object_get_property(o, k); gboolean b = (v && jsc_value_is_boolean(v)) ? jsc_value_to_boolean(v) : FALSE; if (v) { g_object_unref(v); } return b; }
static char *row_item_sig(JSCValue *it, int pal) {
    char *k = jv_str(it, "kind"), *t = jv_str(it, "title"), *s = jv_str(it, "subtitle"), *st = jv_str(it, "status"), *tg = jv_str(it, "target"), *sc = jv_str(it, "shortcut"), *ic = jv_str(it, "icon"), *co = jv_str(it, "color");
    char *sig = g_strdup_printf("%d|%d|%d|%d|%d|%d|%d|%d|%s|%s|%s|%s|%s|%s|%s|%s", pal, pal ? 0 : (int)jv_int(it, "depth"), pal ? 0 : (int)jv_int(it, "badge"), pal ? 0 : (int)jv_int(it, "child_count"), pal ? 0 : (int)jv_int(it, "live_child_count"), !pal && jv_bool(it, "expandable"), !pal && jv_bool(it, "expanded"), !pal && jv_bool(it, "attention"), k, t, pal ? s : "", st, tg, sc, ic, co);
    return g_free(k), g_free(t), g_free(s), g_free(st), g_free(tg), g_free(sc), g_free(ic), g_free(co), sig;
}
static void set_row_selected(GtkWidget *row, gboolean sel) { GtkStyleContext *ctx = gtk_widget_get_style_context(row); if (sel) { gtk_style_context_add_class(ctx, "orb-selected"); } else { gtk_style_context_remove_class(ctx, "orb-selected"); } }
static void eval_wv_target(OrbGtkChrome *c, const char *kind, const char *target) {
    if (!c->wv || !target || !*target) { return; }
    char *lit = orb_json_escape_string(target); if (!lit) { return; }
    const char *fn = (kind && strcmp(kind, "mission") == 0) ? "__ORB_SELECT_MISSION__" : ((kind && strcmp(kind, "expand") == 0) ? "__ORB_NATIVE_EXPAND__" : "__ORB_NATIVE_NAV__");
    char js[4600]; snprintf(js, sizeof(js), "window.%s&&window.%s(%s);", fn, fn, lit); free(lit); webkit_web_view_evaluate_javascript(WEBKIT_WEB_VIEW(c->wv), js, -1, NULL, NULL, NULL, NULL, NULL);
}
static void refresh_sidebar_rows(OrbGtkChrome *c); static void populate_from_array(OrbGtkChrome *c, GtkWidget *lb, JSCValue *arr, int pal);
static void apply_footer_state(OrbGtkChrome *c, JSCValue *ft) {
    if (!ft || !jsc_value_is_object(ft)) { return; }
    set_row_selected(c->foot_btn, jv_bool(ft, "selected")); gint32 b = jv_int(ft, "badge");
    if (b > 0) { char bs[24]; snprintf(bs, sizeof(bs), "%d", (int)b); gtk_label_set_text(GTK_LABEL(c->foot_badge), bs); gtk_widget_show(c->foot_badge); } else { gtk_widget_hide(c->foot_badge); }
}
static gboolean rpc_done(gpointer p) {
    RpcJob *j = (RpcJob *)p; OrbGtkChrome *c = j->c;
    if (!c->closed) {
        if (j->kind == 0) { c->sb_inflight = 0; }
        JSCValue *root = j->resp ? jsc_value_new_from_json(c->jsc, j->resp) : NULL, *res = (root && jsc_value_is_object(root)) ? jsc_value_object_get_property(root, "result") : NULL;
        if (root) { g_object_unref(root); }
        if (res && jsc_value_is_object(res)) {
            if (j->kind == 1 && j->gen == c->pal_gen) {
                JSCValue *items = jsc_value_object_get_property(res, "items"); populate_from_array(c, c->pal_list, items, 1);
                GtkListBoxRow *first = gtk_list_box_get_row_at_index(GTK_LIST_BOX(c->pal_list), 0); if (first) { gtk_list_box_select_row(GTK_LIST_BOX(c->pal_list), first); }
                if (items) { g_object_unref(items); }
            } else if (j->kind != 1) {
                JSCValue *rows = jsc_value_object_get_property(res, "rows"), *ft = jsc_value_object_get_property(res, "footer"); char *sc = jv_str(res, "scope"); double rv = jv_num(res, "revision");
                if (rows && jsc_value_is_array(rows)) { if (accept_sb_resp(&c->sb_scope, &c->sb_scope_gen, c->sb_min_gen, &c->sb_rev, j->gen, sc, rv)) { populate_from_array(c, c->sb_list, rows, 0); orb_sel_sync(c->sb_list); apply_footer_state(c, ft); } } else if (j->kind == 2) { refresh_sidebar_rows(c); }
                g_free(sc); if (ft) { g_object_unref(ft); } if (rows) { g_object_unref(rows); }
            }
        } else if (j->kind == 2) { refresh_sidebar_rows(c); }
        if (res) { g_object_unref(res); }
        if (j->kind == 0 && c->sb_dirty) { c->sb_dirty = 0; refresh_sidebar_rows(c); }
    }
    return g_free(j->body), g_free(j->resp), g_free(j), FALSE;
}
static gpointer rpc_worker(gpointer p) {
    RpcJob *j = (RpcJob *)p; int fd = connect_loopback(j->port, 0);
    if (fd >= 0) {
        size_t blen = strlen(j->body); char hdr[512]; int hl = snprintf(hdr, sizeof(hdr), "POST /__orb_rpc HTTP/1.1\r\nHost: 127.0.0.1:%u\r\nContent-Type: application/json\r\nConnection: close\r\nX-Orb-Token: %s\r\nContent-Length: %zu\r\n\r\n", j->port, j->token, blen);
        if (hl > 0 && (size_t)hl < sizeof(hdr) && send(fd, hdr, (size_t)hl, MSG_NOSIGNAL) == hl && send(fd, j->body, blen, MSG_NOSIGNAL) == (ssize_t)blen) {
            GString *raw = g_string_sized_new(4096); char buf[4096]; ssize_t n; while ((n = recv(fd, buf, sizeof(buf), 0)) > 0 && raw->len < (4u << 20)) { g_string_append_len(raw, buf, n); }
            const char *sep = strstr(raw->str, "\r\n\r\n"); if (sep && strncmp(raw->str, "HTTP/1.1 200", 12) == 0) { j->resp = g_strdup(sep + 4); }
            g_string_free(raw, TRUE);
        }
        close(fd);
    }
    return g_idle_add(rpc_done, j), NULL;
}
static void rpc_call_async(OrbGtkChrome *c, const char *body, int kind, guint64 gen) { if (c->closed) { return; } RpcJob *j = g_new0(RpcJob, 1); j->c = c; j->port = c->port; snprintf(j->token, sizeof(j->token), "%s", c->token); j->body = g_strdup(body); j->kind = kind; j->gen = gen; g_thread_unref(g_thread_new("orb-rpc", rpc_worker, j)); }
static void toggle_row_expand(OrbGtkChrome *c, const char *rid) { char *lit = rid ? orb_json_escape_string(rid) : NULL; if (!lit) { return; } if (strncmp(rid, "proj:", 5) == 0 || strncmp(rid, "folder:", 7) == 0) { eval_wv_target(c, "expand", rid); } char req[1024]; snprintf(req, sizeof(req), "{\"command\":\"native_chrome_toggle_expand\",\"args\":{\"row_id\":%s}}", lit); free(lit); rpc_call_async(c, req, 2, ++c->sb_req_gen); }
static void on_sub_btn_clicked(GtkButton *b, gpointer ud) { OrbGtkChrome *c = (OrbGtkChrome *)ud; const char *rid = g_object_get_data(G_OBJECT(b), "orb-row-id"); if (rid && *rid) { toggle_row_expand(c, rid); } }
static GtkWidget *make_row_widget(OrbGtkChrome *c, JSCValue *it, int pal, char *sig) {
    char *rid = jv_str(it, pal ? "id" : "row_id"), *kind = jv_str(it, "kind"), *title = jv_str(it, "title"), *sub = jv_str(it, "subtitle"), *st = jv_str(it, "status"), *target = jv_str(it, "target"), *sc = jv_str(it, "shortcut"), *ic = jv_str(it, "icon"), *co = jv_str(it, "color");
    gint32 depth = pal ? 0 : jv_int(it, "depth"), badge = pal ? 0 : jv_int(it, "badge"), cc = pal ? 0 : jv_int(it, "child_count"), lcc = pal ? 0 : jv_int(it, "live_child_count");
    gboolean exp = !pal && jv_bool(it, "expandable"), open = !pal && jv_bool(it, "expanded"), sel = !pal && jv_bool(it, "selected"), attn = !pal && jv_bool(it, "attention"), nonact = !pal && (strcmp(kind, "section") == 0 || strcmp(kind, "note") == 0);
    GtkWidget *row = gtk_list_box_row_new(), *evb = gtk_event_box_new(), *hb = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 7), *lbl = gtk_label_new(title);
    gtk_event_box_set_visible_window(GTK_EVENT_BOX(evb), FALSE);
    if (nonact) { gtk_list_box_row_set_activatable(GTK_LIST_BOX_ROW(row), FALSE); gtk_list_box_row_set_selectable(GTK_LIST_BOX_ROW(row), FALSE); gtk_style_context_add_class(gtk_widget_get_style_context(row), strcmp(kind, "section") == 0 ? "orb-sec" : "orb-note"); } else { orb_gtk_bind_pointer_cursor(evb); } if (!pal && strcmp(kind, "archive") == 0) { gtk_style_context_add_class(gtk_widget_get_style_context(row), "orb-sec"); gtk_style_context_add_class(gtk_widget_get_style_context(row), "orb-sec-toggle"); GtkWidget *chev = gtk_label_new(open ? "\xE2\x8C\x84" : "\xE2\x80\xBA"); gtk_style_context_add_class(gtk_widget_get_style_context(chev), "orb-chev"); gtk_box_pack_end(GTK_BOX(hb), chev, FALSE, FALSE, 0); }
    gtk_widget_set_margin_start(hb, 6 + (depth > 8 ? 8 : depth) * 12); gtk_widget_set_margin_end(hb, 6); set_row_selected(row, sel); if (*ic) { gtk_box_pack_start(GTK_BOX(hb), orb_make_icon_widget(&c->spin, ic, co, st), FALSE, FALSE, 0); }
    gtk_label_set_xalign(GTK_LABEL(lbl), 0.0f); gtk_label_set_ellipsize(GTK_LABEL(lbl), PANGO_ELLIPSIZE_END); if (strcmp(kind, "project") == 0) { gtk_style_context_add_class(gtk_widget_get_style_context(lbl), "orb-proj"); }
    gtk_box_pack_start(GTK_BOX(hb), lbl, TRUE, TRUE, 0);
    if (!pal && exp && strcmp(kind, "mission") == 0) {
        char ct[36]; if (cc > 0 && lcc > 0) { snprintf(ct, sizeof(ct), "%d/%d %s", (int)lcc, (int)cc, open ? "\xE2\x8C\x84" : "\xE2\x80\xBA"); } else if (cc > 0) { snprintf(ct, sizeof(ct), "%d %s", (int)cc, open ? "\xE2\x8C\x84" : "\xE2\x80\xBA"); } else { snprintf(ct, sizeof(ct), "%s", open ? "\xE2\x8C\x84" : "\xE2\x80\xBA"); }
        GtkWidget *sb = gtk_button_new_with_label(ct); gtk_button_set_relief(GTK_BUTTON(sb), GTK_RELIEF_NONE); gtk_widget_set_focus_on_click(sb, FALSE); gtk_widget_set_valign(sb, GTK_ALIGN_CENTER); gtk_style_context_add_class(gtk_widget_get_style_context(sb), lcc > 0 ? "orb-sub-live" : "orb-sub"); orb_gtk_bind_pointer_cursor(sb);
        g_object_set_data_full(G_OBJECT(sb), "orb-row-id", g_strdup(rid), g_free); g_signal_connect(sb, "clicked", G_CALLBACK(on_sub_btn_clicked), c); gtk_box_pack_end(GTK_BOX(hb), sb, FALSE, FALSE, 0);
    }
    if (badge > 0) { char bs[24]; snprintf(bs, sizeof(bs), "%d", (int)badge); GtkWidget *bl = gtk_label_new(bs); gtk_widget_set_valign(bl, GTK_ALIGN_CENTER); gtk_style_context_add_class(gtk_widget_get_style_context(bl), "orb-badge"); gtk_box_pack_end(GTK_BOX(hb), bl, FALSE, FALSE, 0); }
    if (*sc || (pal && *sub) || attn) { GtkWidget *ml = gtk_label_new(*sc ? sc : ((pal && *sub) ? sub : "\xE2\x80\xA2")); gtk_style_context_add_class(gtk_widget_get_style_context(ml), attn && !*sc ? "orb-attn" : "orb-kbd"); gtk_box_pack_end(GTK_BOX(hb), ml, FALSE, FALSE, 0); }
    g_object_set_data_full(G_OBJECT(row), "orb-row-id", rid, g_free); g_object_set_data_full(G_OBJECT(row), "orb-kind", kind, g_free); g_object_set_data_full(G_OBJECT(row), "orb-target", target, g_free); g_object_set_data_full(G_OBJECT(row), "orb-sig", sig, g_free); g_object_set_data(G_OBJECT(row), "orb-exp", GINT_TO_POINTER(exp ? 1 : 0)); if (!pal) { g_object_set_data_full(G_OBJECT(row), "orb-project", jv_str(it, "project"), g_free); }
    return g_object_set_data_full(G_OBJECT(row), "orb-title", title, g_free), g_free(sub), g_object_set_data_full(G_OBJECT(row), "orb-status", st, g_free), g_free(sc), g_free(ic), g_free(co), gtk_container_add(GTK_CONTAINER(evb), hb), gtk_container_add(GTK_CONTAINER(row), evb), gtk_widget_show_all(row), row;
}
static void populate_from_array(OrbGtkChrome *c, GtkWidget *lb, JSCValue *arr, int pal) {
    const char *idk = pal ? "id" : "row_id"; gint32 len = (arr && jsc_value_is_array(arr)) ? jv_int(arr, "length") : 0, out = 0; if (len < 0) { len = 0; }
    GHashTable *keep = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, NULL);
    for (gint32 i = 0; i < len; ++i) { JSCValue *it = jsc_value_object_get_property_at_index(arr, (guint)i); if (it && jsc_value_is_object(it)) { char *id = jv_str(it, idk); if (*id) { g_hash_table_add(keep, id); } else { g_free(id); } } if (it) { g_object_unref(it); } }
    GList *ch = gtk_container_get_children(GTK_CONTAINER(lb)); for (GList *l = ch; l; l = l->next) { const char *id = g_object_get_data(G_OBJECT(l->data), "orb-row-id"); if (!id || !*id || !g_hash_table_contains(keep, id)) { gtk_widget_destroy(GTK_WIDGET(l->data)); } }
    g_list_free(ch); g_hash_table_destroy(keep);
    for (gint32 i = 0; i < len; ++i) {
        JSCValue *it = jsc_value_object_get_property_at_index(arr, (guint)i); if (!it || !jsc_value_is_object(it)) { if (it) { g_object_unref(it); } continue; }
        char *rid = jv_str(it, idk), *sig = row_item_sig(it, pal); GtkListBoxRow *cur = gtk_list_box_get_row_at_index(GTK_LIST_BOX(lb), out), *lat;
        const char *cid = cur ? g_object_get_data(G_OBJECT(cur), "orb-row-id") : NULL, *csig = cur ? g_object_get_data(G_OBJECT(cur), "orb-sig") : NULL;
        if (cur && *rid && cid && strcmp(cid, rid) == 0) {
            if (csig && strcmp(csig, sig) == 0) { set_row_selected(GTK_WIDGET(cur), !pal && jv_bool(it, "selected")); g_free(sig); } else { gtk_widget_destroy(GTK_WIDGET(cur)); gtk_list_box_insert(GTK_LIST_BOX(lb), make_row_widget(c, it, pal, sig), out); }
        } else {
            for (gint32 j = out + 1; *rid && (lat = gtk_list_box_get_row_at_index(GTK_LIST_BOX(lb), j)) != NULL; ++j) { const char *lid = g_object_get_data(G_OBJECT(lat), "orb-row-id"); if (lid && strcmp(lid, rid) == 0) { gtk_widget_destroy(GTK_WIDGET(lat)); break; } }
            gtk_list_box_insert(GTK_LIST_BOX(lb), make_row_widget(c, it, pal, sig), out);
        }
        g_free(rid); g_object_unref(it); ++out;
    }
    GtkListBoxRow *tail; while ((tail = gtk_list_box_get_row_at_index(GTK_LIST_BOX(lb), out)) != NULL) { gtk_widget_destroy(GTK_WIDGET(tail)); }
}
static void refresh_sidebar_rows(OrbGtkChrome *c) { if (c->sb_inflight) { c->sb_dirty = 1; return; } c->sb_inflight = 1; rpc_call_async(c, "{\"command\":\"native_chrome_get_rows\",\"args\":{}}", 0, ++c->sb_req_gen); }
static void refresh_palette_items(OrbGtkChrome *c, const char *q) { char *lit = orb_json_escape_string(q ? q : ""); if (!lit) { return; } char req[1200]; snprintf(req, sizeof(req), "{\"command\":\"native_chrome_palette_query\",\"args\":{\"query\":%s,\"limit\":24}}", lit); free(lit); rpc_call_async(c, req, 1, ++c->pal_gen); }
static void on_sb_row_activated(GtkListBox *lb, GtkListBoxRow *r, gpointer ud) {
    (void)lb; OrbGtkChrome *c = (OrbGtkChrome *)ud; if (!r) { return; }
    const char *t = g_object_get_data(G_OBJECT(r), "orb-target"), *k = g_object_get_data(G_OBJECT(r), "orb-kind"), *rid = g_object_get_data(G_OBJECT(r), "orb-row-id");
    if (k && (strcmp(k, "project") == 0 || strcmp(k, "folder") == 0)) { toggle_row_expand(c, rid); } else if (t && *t && strncmp(t, "folder:", 7) != 0) { eval_wv_target(c, k, t); } else if (GPOINTER_TO_INT(g_object_get_data(G_OBJECT(r), "orb-exp"))) { toggle_row_expand(c, rid); }
}
static gboolean on_sb_button(GtkWidget *w, GdkEventButton *ev, gpointer ud) { GtkWidget *row = ev->type == GDK_BUTTON_PRESS ? gtk_widget_get_ancestor(gtk_get_event_widget((GdkEvent *)ev), GTK_TYPE_LIST_BOX_ROW) : NULL; guint mod = ev->state & gtk_accelerator_get_default_mod_mask(); if (row && ev->button == GDK_BUTTON_PRIMARY) { return (mod & (GDK_CONTROL_MASK | GDK_SUPER_MASK | GDK_META_MASK | GDK_SHIFT_MASK)) ? orb_sel_click(w, row, (mod & GDK_SHIFT_MASK) != 0) : (orb_sel_clear(w), FALSE); } return row && ev->button == GDK_BUTTON_SECONDARY && orb_gtk_row_context_menu(((OrbGtkChrome *)ud)->wv, w, row, (GdkEvent *)ev); }
static void open_palette(OrbGtkChrome *c) { gtk_entry_set_text(GTK_ENTRY(c->pal_entry), ""); refresh_palette_items(c, ""); gtk_popover_popup(GTK_POPOVER(c->pal_pop)); gtk_widget_grab_focus(c->pal_entry); }
static void on_tb_sb_clicked(GtkButton *b, gpointer ud) { (void)b; OrbGtkChrome *c = (OrbGtkChrome *)ud; gtk_widget_set_visible(c->sb_box, FALSE); if (c->wv) { webkit_web_view_evaluate_javascript(WEBKIT_WEB_VIEW(c->wv), "window.__ORB_TOGGLE_NATIVE_SIDEBAR__&&window.__ORB_TOGGLE_NATIVE_SIDEBAR__(false);", -1, NULL, NULL, NULL, NULL, NULL); } }
static void on_tb_search_clicked(GtkButton *b, gpointer ud) { (void)b; open_palette((OrbGtkChrome *)ud); }
static void on_tb_back_clicked(GtkButton *b, gpointer ud) { (void)b; eval_wv_target((OrbGtkChrome *)ud, "nav", "history-back"); }
static void on_tb_fwd_clicked(GtkButton *b, gpointer ud) { (void)b; eval_wv_target((OrbGtkChrome *)ud, "nav", "history-forward"); }
static GtkWidget *make_tb_btn(OrbGtkChrome *c, const char *ic, const char *tip, GCallback cb) {
    GtkWidget *b = gtk_button_new(); gtk_button_set_relief(GTK_BUTTON(b), GTK_RELIEF_NONE); gtk_widget_set_focus_on_click(b, FALSE); gtk_widget_set_valign(b, GTK_ALIGN_CENTER); gtk_widget_set_tooltip_text(b, tip); orb_gtk_bind_pointer_cursor(b);
    gtk_style_context_add_class(gtk_widget_get_style_context(b), "orb-tb-btn"); gtk_container_add(GTK_CONTAINER(b), orb_make_icon_widget(&c->spin, ic, NULL, NULL)); g_signal_connect(b, "clicked", cb, c); return b;
}
static void on_foot_clicked(GtkButton *b, gpointer ud) { (void)b; OrbGtkChrome *c = (OrbGtkChrome *)ud; if (!gtk_style_context_has_class(gtk_widget_get_style_context(c->foot_btn), "orb-selected")) { eval_wv_target(c, "footer", "settings"); } }
static void on_pal_row_activated(GtkListBox *lb, GtkListBoxRow *r, gpointer ud) {
    (void)lb; OrbGtkChrome *c = (OrbGtkChrome *)ud; if (!r) { return; }
    const char *t = g_object_get_data(G_OBJECT(r), "orb-target"), *k = g_object_get_data(G_OBJECT(r), "orb-kind"); if (t && strncmp(t, "folder:", 7) == 0) { toggle_row_expand(c, t); } else { eval_wv_target(c, k, t); } ++c->pal_gen; gtk_popover_popdown(GTK_POPOVER(c->pal_pop));
}
static void on_pal_closed(GtkPopover *p, gpointer ud) { (void)p; ++((OrbGtkChrome *)ud)->pal_gen; }
static void on_win_destroy(GtkWidget *w, gpointer ud) { (void)w; OrbGtkChrome *c = (OrbGtkChrome *)ud; c->closed = 1; orb_spinner_stop(&c->spin); }
static void on_pal_search_changed(GtkSearchEntry *se, gpointer ud) { refresh_palette_items((OrbGtkChrome *)ud, gtk_entry_get_text(GTK_ENTRY(se))); }
static void on_pal_entry_activate(GtkEntry *e, gpointer ud) { (void)e; OrbGtkChrome *c = (OrbGtkChrome *)ud; GtkListBoxRow *sel = gtk_list_box_get_selected_row(GTK_LIST_BOX(c->pal_list)); if (!sel) { sel = gtk_list_box_get_row_at_index(GTK_LIST_BOX(c->pal_list), 0); } if (sel) { on_pal_row_activated(GTK_LIST_BOX(c->pal_list), sel, c); } }
static gboolean on_win_key_press(GtkWidget *w, GdkEventKey *ev, gpointer ud) { (void)w; OrbGtkChrome *c = (OrbGtkChrome *)ud; guint mod = ev->state & gtk_accelerator_get_default_mod_mask(); gboolean prim = (mod & (GDK_CONTROL_MASK | GDK_SUPER_MASK | GDK_META_MASK)) != 0; if (prim && (ev->keyval == GDK_KEY_Delete || ev->keyval == GDK_KEY_KP_Delete) && !gtk_widget_has_focus(c->wv) && !GTK_IS_ENTRY(gtk_window_get_focus(GTK_WINDOW(c->win)))) { return orb_sel_delete(c->wv, c->sb_list, "m:current"); } /* WebView focus: ProjectFiles handles it (never while typing) */ if (ev->keyval == GDK_KEY_Escape && !gtk_widget_has_focus(c->wv) && orb_sel_clear(c->sb_list)) { return TRUE; } return (prim && (ev->keyval == GDK_KEY_k || ev->keyval == GDK_KEY_K)) ? (open_palette(c), TRUE) : FALSE; }
static void on_script_msg(WebKitUserContentManager *ucm, WebKitJavascriptResult *jr, gpointer ud) {
    (void)ucm; OrbGtkChrome *c = (OrbGtkChrome *)ud; JSCValue *v = webkit_javascript_result_get_js_value(jr); if (!v || !jsc_value_is_object(v)) { return; }
    char *cmd = jv_str(v, "command"); JSCValue *args = jsc_value_object_get_property(v, "args");
    if (strcmp(cmd, "open_native_palette") == 0) { open_palette(c); }
    else if (strcmp(cmd, "set_native_sidebar") == 0) { gboolean open = (args && jsc_value_is_object(args)) ? jv_bool(args, "open") : !gtk_widget_get_visible(c->sb_box); gtk_widget_set_visible(c->sb_box, open); }
    else if (strcmp(cmd, "window_drag") == 0) { orb_gtk_begin_window_drag(c->win); }
    else if (strcmp(cmd, "set_native_history") == 0 && args && jsc_value_is_object(args)) { gtk_widget_set_sensitive(c->back_btn, jv_bool(args, "can_back")); gtk_widget_set_sensitive(c->fwd_btn, jv_bool(args, "can_forward")); }
    if (args) { g_object_unref(args); } g_free(cmd);
}
static gboolean start_sse_watch(gpointer ud);
static gboolean on_sse_io(GIOChannel *ch, GIOCondition cond, gpointer ud) {
    OrbGtkChrome *c = (OrbGtkChrome *)ud; int fd = g_io_channel_unix_get_fd(ch); if (cond & (G_IO_HUP | G_IO_ERR | G_IO_NVAL)) { goto drop; }
    char buf[4096]; ssize_t n = recv(fd, buf, sizeof(buf) - 1, 0); if (n <= 0) { if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) { return TRUE; } goto drop; }
    g_string_append_len(c->sse_buf, buf, n); char *p; int hit = 0; while ((p = strstr(c->sse_buf->str, "\n\n")) != NULL) { size_t fl = (size_t)(p - c->sse_buf->str); if (g_strstr_len(c->sse_buf->str, (gssize)fl, "native_chrome_rows_changed")) { hit = 1; } g_string_erase(c->sse_buf, 0, (gssize)(fl + 2)); }
    if (hit) { c->sb_min_gen = c->sb_req_gen + 1; refresh_sidebar_rows(c); } return TRUE;
drop: c->sse_src = 0; g_io_channel_unref(c->sse_ch); c->sse_ch = NULL; close(fd); if (!c->retry_src) { c->retry_src = g_timeout_add(900, start_sse_watch, c); } return FALSE;
}
static gboolean start_sse_watch(gpointer ud) {
    OrbGtkChrome *c = (OrbGtkChrome *)ud; c->retry_src = 0; refresh_sidebar_rows(c); int fd = connect_loopback(c->port, 1); if (fd < 0) { return c->retry_src = g_timeout_add(450, start_sse_watch, c), FALSE; }
    char req[512]; int len = snprintf(req, sizeof(req), "GET /__orb_events HTTP/1.1\r\nHost: 127.0.0.1:%u\r\nAccept: text/event-stream\r\nX-Orb-Token: %s\r\n\r\n", c->port, c->token); if (len > 0) { (void)send(fd, req, (size_t)len, MSG_NOSIGNAL); }
    g_string_truncate(c->sse_buf, 0); c->sse_ch = g_io_channel_unix_new(fd); c->sse_src = g_io_add_watch(c->sse_ch, G_IO_IN | G_IO_HUP | G_IO_ERR, on_sse_io, c); return FALSE;
}
GtkWidget *orb_gtk_chrome_wrap(GtkWidget *win, GtkWidget *wv, WebKitUserContentManager *ucm, unsigned port, const char *token) {
    OrbGtkChrome *c = g_new0(OrbGtkChrome, 1); c->win = win; c->wv = wv; c->port = port; c->jsc = jsc_context_new(); c->sse_buf = g_string_sized_new(1024); snprintf(c->token, sizeof(c->token), "%s", token ? token : "");
    GtkCssProvider *cp = gtk_css_provider_new();
    gtk_css_provider_load_from_data(cp, ".orb-paned,.orb-sb scrolledwindow,.orb-sb viewport,.orb-pal scrolledwindow,.orb-pal viewport{background:transparent;background-image:none;border:none;box-shadow:none;}.orb-sb undershoot,.orb-sb overshoot,.orb-pal undershoot,.orb-pal overshoot,.orb-sb scrollbar,.orb-sb scrollbar contents,.orb-sb scrollbar trough,.orb-sb scrollbar slider,.orb-sb scrollbar button{opacity:0;min-width:0;min-height:0;margin:0;padding:0;background:transparent;background-image:none;border:none;box-shadow:none;}.orb-paned>separator{min-width:1px;min-height:1px;padding:0;margin:0;background-color:#2c2c2c;background-image:none;border:none;box-shadow:none;}.orb-sb{background-color:rgba(18,19,19,0.78);background-image:none;color:#d8d8d7;font-size:13px;}.orb-tb{padding:0 8px;}.orb-tb-btn{min-width:24px;min-height:24px;padding:0;margin:0;border-radius:6px;border:1px solid transparent;background:transparent;background-image:none;color:#8a8a8a;box-shadow:none;outline:none;}.orb-tb-btn:hover:not(:disabled){background-color:rgba(216,216,215,0.075);color:#d8d8d7;}.orb-tb-btn:disabled{opacity:0.42;}.orb-sb list,.orb-pal list{background:transparent;color:#d8d8d7;}.orb-sb row,.orb-pal row{min-height:30px;padding:0;margin:0 6px 1px 6px;border:1px solid transparent;border-radius:6px;background:transparent;color:#d8d8d7;outline:none;box-shadow:none;}.orb-sb row:hover:not(.orb-selected):not(.orb-sec):not(.orb-note),.orb-pal row:hover{background-color:rgba(216,216,215,0.045);}.orb-sb row.orb-selected,.orb-multi,.orb-pal row:selected{background-color:rgba(216,216,215,0.075);color:#e6e6e5;}.orb-sb row.orb-sec{min-height:20px;margin:13px 8px 4px 10px;color:#8a8a8a;font-size:11px;}.orb-sb row.orb-sec-toggle:hover{color:#b1b1b1;}.orb-sb row.orb-sec .orb-chev{color:inherit;font-size:11px;}.orb-sb row.orb-note{min-height:26px;margin:2px 8px 2px 10px;color:#8a8a8a;font-size:12px;}.orb-ico{color:rgba(216,216,215,0.62);}.orb-tb-btn .orb-ico{color:inherit;}.orb-sb row.orb-selected .orb-ico,.orb-foot button.orb-selected .orb-ico{color:#e6e6e5;}.orb-proj{color:#b1b1b1;}.orb-sb row:hover .orb-proj{color:#d8d8d7;}.orb-sub,.orb-sub-live{min-height:20px;min-width:0;padding:0 5px;border-radius:4px;border:1px solid transparent;background:transparent;background-image:none;color:#6c6c6b;font-size:11px;font-family:monospace;box-shadow:none;outline:none;}.orb-sub-live{color:#b1b1b1;}.orb-sub:hover,.orb-sub-live:hover{background-color:rgba(216,216,215,0.09);color:#e6e6e5;}.orb-kbd{color:#5c5c5c;font-size:11px;}.orb-attn{color:#c9a227;font-size:12px;}.orb-badge{min-width:16px;min-height:16px;padding:0 5px;border-radius:999px;background-color:rgba(216,216,215,0.075);color:#8a8a8a;font-size:11px;}.orb-foot{padding:6px;border-top:1px solid #2c2c2c;}.orb-foot button{min-height:32px;padding:0 8px;border-radius:8px;border:1px solid transparent;background:transparent;background-image:none;color:#b1b1b1;box-shadow:none;outline:none;}.orb-foot button:hover:not(.orb-selected){background-color:rgba(216,216,215,0.045);color:#d8d8d7;}.orb-foot button.orb-selected{color:#d8d8d7;font-weight:500;}.orb-pal,.orb-pal contents{background-color:#212121;background-image:none;border-color:#3a3a3a;border-radius:10px;color:#d8d8d7;}.orb-pal entry{background-color:#1e1e1e;background-image:none;color:#d8d8d7;border:1px solid #2f2f2f;border-radius:6px;box-shadow:none;outline:none;}.orb-sb row:focus-visible,.orb-pal row:focus-visible,.orb-tb-btn:focus-visible,.orb-sub:focus-visible,.orb-sub-live:focus-visible,.orb-foot button:focus-visible,.orb-pal entry:focus{border-color:#5b5b5a;outline:none;box-shadow:none;}", -1, NULL);
    gtk_style_context_add_provider_for_screen(gtk_widget_get_screen(win), GTK_STYLE_PROVIDER(cp), GTK_STYLE_PROVIDER_PRIORITY_APPLICATION); g_object_unref(cp);
    c->sb_box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0); gtk_widget_set_size_request(c->sb_box, 220, -1); gtk_style_context_add_class(gtk_widget_get_style_context(c->sb_box), "orb-sb");
    GtkWidget *top = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 2), *tgap = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0), *scw = gtk_scrolled_window_new(NULL, NULL), *foot = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0), *fhb = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8), *fl = gtk_label_new("Settings");
    gtk_widget_set_size_request(top, -1, 35); gtk_style_context_add_class(gtk_widget_get_style_context(top), "orb-tb"); gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(scw), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC); gtk_style_context_add_class(gtk_widget_get_style_context(foot), "orb-foot");
    c->back_btn = make_tb_btn(c, "arrow-left", "Back", G_CALLBACK(on_tb_back_clicked)); c->fwd_btn = make_tb_btn(c, "arrow-right", "Forward", G_CALLBACK(on_tb_fwd_clicked)); gtk_widget_set_sensitive(c->back_btn, FALSE); gtk_widget_set_sensitive(c->fwd_btn, FALSE);
    gtk_box_pack_start(GTK_BOX(top), make_tb_btn(c, "sidebar", "Toggle sidebar", G_CALLBACK(on_tb_sb_clicked)), FALSE, FALSE, 0); gtk_box_pack_start(GTK_BOX(top), make_tb_btn(c, "search", "Search conversations (Ctrl+K)", G_CALLBACK(on_tb_search_clicked)), FALSE, FALSE, 0); gtk_box_pack_start(GTK_BOX(top), tgap, TRUE, TRUE, 0); gtk_box_pack_start(GTK_BOX(top), c->back_btn, FALSE, FALSE, 0); gtk_box_pack_start(GTK_BOX(top), c->fwd_btn, FALSE, FALSE, 0);
    c->sb_list = gtk_list_box_new(); gtk_list_box_set_selection_mode(GTK_LIST_BOX(c->sb_list), GTK_SELECTION_NONE); gtk_list_box_set_activate_on_single_click(GTK_LIST_BOX(c->sb_list), TRUE); g_signal_connect(c->sb_list, "row-activated", G_CALLBACK(on_sb_row_activated), c); g_signal_connect(c->sb_list, "button-press-event", G_CALLBACK(on_sb_button), c); gtk_container_add(GTK_CONTAINER(scw), c->sb_list);
    c->foot_btn = gtk_button_new(); gtk_button_set_relief(GTK_BUTTON(c->foot_btn), GTK_RELIEF_NONE); gtk_widget_set_focus_on_click(c->foot_btn, FALSE); orb_gtk_bind_pointer_cursor(c->foot_btn); gtk_label_set_xalign(GTK_LABEL(fl), 0.0f); c->foot_badge = gtk_label_new(""); gtk_style_context_add_class(gtk_widget_get_style_context(c->foot_badge), "orb-badge"); gtk_widget_set_valign(c->foot_badge, GTK_ALIGN_CENTER); gtk_widget_set_no_show_all(c->foot_badge, TRUE);
    gtk_box_pack_start(GTK_BOX(fhb), orb_make_icon_widget(&c->spin, "gear", NULL, NULL), FALSE, FALSE, 0); gtk_box_pack_start(GTK_BOX(fhb), fl, TRUE, TRUE, 0); gtk_box_pack_end(GTK_BOX(fhb), c->foot_badge, FALSE, FALSE, 0); gtk_container_add(GTK_CONTAINER(c->foot_btn), fhb); g_signal_connect(c->foot_btn, "clicked", G_CALLBACK(on_foot_clicked), c); gtk_box_pack_start(GTK_BOX(foot), c->foot_btn, TRUE, TRUE, 0);
    gtk_box_pack_start(GTK_BOX(c->sb_box), orb_gtk_drag_area(top), FALSE, FALSE, 0); gtk_box_pack_start(GTK_BOX(c->sb_box), scw, TRUE, TRUE, 0); gtk_box_pack_end(GTK_BOX(c->sb_box), foot, FALSE, FALSE, 0);
    c->paned = gtk_paned_new(GTK_ORIENTATION_HORIZONTAL); gtk_style_context_add_class(gtk_widget_get_style_context(c->paned), "orb-paned"); gtk_paned_pack1(GTK_PANED(c->paned), c->sb_box, FALSE, FALSE); gtk_paned_pack2(GTK_PANED(c->paned), wv, TRUE, FALSE); gtk_paned_set_position(GTK_PANED(c->paned), 220);
    c->pal_pop = gtk_popover_new(c->paned); GdkRectangle pr = { .x = 260, .y = 36, .width = 1, .height = 1 }; gtk_popover_set_pointing_to(GTK_POPOVER(c->pal_pop), &pr); gtk_style_context_add_class(gtk_widget_get_style_context(c->pal_pop), "orb-pal"); g_signal_connect(c->pal_pop, "closed", G_CALLBACK(on_pal_closed), c);
    GtkWidget *pb = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6), *pscw = gtk_scrolled_window_new(NULL, NULL); gtk_widget_set_size_request(pb, 440, 320); gtk_container_set_border_width(GTK_CONTAINER(pb), 8);
    c->pal_entry = gtk_search_entry_new(); gtk_entry_set_placeholder_text(GTK_ENTRY(c->pal_entry), "Jump to mission, project, or page\xE2\x80\xA6"); c->pal_list = gtk_list_box_new(); gtk_list_box_set_activate_on_single_click(GTK_LIST_BOX(c->pal_list), TRUE);
    g_signal_connect(c->pal_entry, "search-changed", G_CALLBACK(on_pal_search_changed), c); g_signal_connect(c->pal_entry, "activate", G_CALLBACK(on_pal_entry_activate), c); g_signal_connect(c->pal_list, "row-activated", G_CALLBACK(on_pal_row_activated), c);
    gtk_container_add(GTK_CONTAINER(pscw), c->pal_list); gtk_box_pack_start(GTK_BOX(pb), c->pal_entry, FALSE, FALSE, 0); gtk_box_pack_start(GTK_BOX(pb), pscw, TRUE, TRUE, 0); gtk_widget_show_all(pb); gtk_container_add(GTK_CONTAINER(c->pal_pop), pb);
    g_signal_connect(ucm, "script-message-received::orbNative", G_CALLBACK(on_script_msg), c); webkit_user_content_manager_register_script_message_handler(ucm, "orbNative");
    return g_signal_connect(win, "destroy", G_CALLBACK(on_win_destroy), c), g_signal_connect(win, "key-press-event", G_CALLBACK(on_win_key_press), c), g_idle_add(start_sse_watch, c), c->paned;
}
#endif
int orb_gtk_chrome_self_test(void) {
    char *esc = orb_json_escape_string("m:\"1\""); int ok = orb_gtk_icons_self_test() && orb_gtk_menu_self_test() && esc && strcmp(esc, "\"m:\\\"1\\\"\"") == 0; free(esc);
#if defined(ORB_HAS_WEBKITGTK)
    JSCContext *ctx = jsc_context_new(); char *sc = NULL; guint64 sg = 0, rv = 0;
    JSCValue *a = jsc_value_new_from_json(ctx, "{\"row_id\":\"m:1\",\"kind\":\"mission\",\"title\":\"Agent\",\"status\":\"active\",\"icon\":\"bot\",\"child_count\":2,\"selected\":false}"), *b = jsc_value_new_from_json(ctx, "{\"row_id\":\"m:1\",\"kind\":\"mission\",\"title\":\"Agent\",\"status\":\"active\",\"icon\":\"bot\",\"child_count\":2,\"selected\":true}"), *d = jsc_value_new_from_json(ctx, "{\"row_id\":\"m:1\",\"kind\":\"mission\",\"title\":\"Agent\",\"status\":\"completed\",\"icon\":\"bot\",\"child_count\":2,\"selected\":true}");
    char *sa = a ? row_item_sig(a, 0) : NULL, *sb = b ? row_item_sig(b, 0) : NULL, *sd = d ? row_item_sig(d, 0) : NULL;
    ok = ok && sa && sb && sd && strcmp(sa, sb) == 0 && strcmp(sa, sd) != 0 && accept_sb_resp(&sc, &sg, 0, &rv, 1, "s:a", 50) && !accept_sb_resp(&sc, &sg, 0, &rv, 2, "s:a", 49) && accept_sb_resp(&sc, &sg, 3, &rv, 3, "s:b", 2) && !accept_sb_resp(&sc, &sg, 3, &rv, 2, "s:a", 99);
    g_free(sc); g_free(sa); g_free(sb); g_free(sd); if (a) { g_object_unref(a); } if (b) { g_object_unref(b); } if (d) { g_object_unref(d); } g_object_unref(ctx);
#endif
    return ok;
}
