/* linux_shell/gtk_chrome.c — Hybrid Native Chrome GTK3 split view & Ctrl+K palette (<= 220 LOC). */
#define _POSIX_C_SOURCE 200809L
#include "gtk_chrome.h"
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
    out[j++] = '"';
    for (size_t i = 0; i < len; ++i) { unsigned char c = (unsigned char)s[i]; if (c == '"' || c == '\\') { out[j++] = '\\'; out[j++] = (char)c; } else if (c < 0x20 || c == 0x7F) { j += (size_t)snprintf(out + j, 8, "\\u%04x", c); } else { out[j++] = (char)c; } }
    return out[j++] = '"', out[j] = '\0', out;
}
#if defined(ORB_HAS_WEBKITGTK)
typedef struct {
    GtkWidget *win, *wv, *paned, *sb_box, *sb_list, *pal_pop, *pal_entry, *pal_list;
    JSCContext *jsc; GIOChannel *sse_ch; guint sse_src, retry_src; GString *sse_buf;
    unsigned port; char token[128], *sb_scope; guint64 pal_gen, sb_req_gen, sb_scope_gen, sb_min_gen, sb_rev; int sb_inflight, sb_dirty, closed;
} OrbGtkChrome;
typedef struct { OrbGtkChrome *c; unsigned port; char token[128], *body, *resp; int kind; guint64 gen; } RpcJob;
static int accept_sb_resp(char **cur_sc, guint64 *sc_gen, guint64 min_gen, guint64 *cur_rv, guint64 rg, const char *sc, double rv) {
    const char *cs = *cur_sc ? *cur_sc : ""; guint64 gate = *sc_gen > min_gen ? *sc_gen : min_gen;
    if (strcmp(sc, cs) != 0) { if (rg < gate) { return 0; } g_free(*cur_sc); *cur_sc = g_strdup(sc); *sc_gen = rg; *cur_rv = rv >= 0.0 ? (guint64)rv : 0; return 1; }
    if (rv >= 0.0) { if ((guint64)rv < *cur_rv) { return 0; } *cur_rv = (guint64)rv; } if (rg > *sc_gen) { *sc_gen = rg; } return 1;
}
static int connect_loopback(unsigned port, int nonblock) {
    int fd = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC | (nonblock ? SOCK_NONBLOCK : 0), 0); if (fd < 0) { return -1; }
    struct timeval tv = { .tv_sec = 0, .tv_usec = 350000 }; if (!nonblock) { setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv)); setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv)); }
    struct sockaddr_in sa = { .sin_family = AF_INET, .sin_port = htons((uint16_t)port) }; sa.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    return (connect(fd, (struct sockaddr *)&sa, sizeof(sa)) < 0 && (!nonblock || errno != EINPROGRESS)) ? (close(fd), -1) : fd;
}
static char *jv_str(JSCValue *o, const char *k) { JSCValue *v = jsc_value_object_get_property(o, k); char *s = (v && jsc_value_is_string(v)) ? jsc_value_to_string(v) : g_strdup(""); if (v) { g_object_unref(v); } return s; }
static gint32 jv_int(JSCValue *o, const char *k) { JSCValue *v = jsc_value_object_get_property(o, k); gint32 n = (v && jsc_value_is_number(v)) ? jsc_value_to_int32(v) : 0; if (v) { g_object_unref(v); } return n; }
static double jv_num(JSCValue *o, const char *k) { JSCValue *v = jsc_value_object_get_property(o, k); double n = (v && jsc_value_is_number(v)) ? jsc_value_to_double(v) : -1.0; if (v) { g_object_unref(v); } return n; }
static gboolean jv_bool(JSCValue *o, const char *k) { JSCValue *v = jsc_value_object_get_property(o, k); gboolean b = (v && jsc_value_is_boolean(v)) ? jsc_value_to_boolean(v) : FALSE; if (v) { g_object_unref(v); } return b; }
static char *row_item_sig(JSCValue *it, int pal) {
    char *k = jv_str(it, "kind"), *t = jv_str(it, "title"), *s = jv_str(it, "subtitle"), *tg = jv_str(it, "target"), *sc = jv_str(it, "shortcut");
    char *sig = g_strdup_printf("%d|%d|%d|%d|%d|%d|%s|%s|%s|%s|%s", pal, pal ? 0 : (int)jv_int(it, "depth"), pal ? 0 : (int)jv_int(it, "badge"), !pal && jv_bool(it, "expandable"), !pal && jv_bool(it, "expanded"), !pal && jv_bool(it, "attention"), k, t, pal ? s : "", tg, sc);
    g_free(k); g_free(t); g_free(s); g_free(tg); g_free(sc); return sig;
}
static void set_row_selected(GtkWidget *row, gboolean sel) { GtkStyleContext *ctx = gtk_widget_get_style_context(row); if (sel) { gtk_style_context_add_class(ctx, "orb-selected"); } else { gtk_style_context_remove_class(ctx, "orb-selected"); } }
static void eval_wv_target(OrbGtkChrome *c, const char *kind, const char *target) {
    if (!c->wv || !target || !*target) { return; }
    char *lit = orb_json_escape_string(target); if (!lit) { return; }
    const char *fn = (kind && strcmp(kind, "mission") == 0) ? "__ORB_SELECT_MISSION__" : "__ORB_NATIVE_NAV__";
    char js[4600]; snprintf(js, sizeof(js), "window.%s&&window.%s(%s);", fn, fn, lit); free(lit); webkit_web_view_evaluate_javascript(WEBKIT_WEB_VIEW(c->wv), js, -1, NULL, NULL, NULL, NULL, NULL);
}
static void refresh_sidebar_rows(OrbGtkChrome *c); static void populate_from_array(OrbGtkChrome *c, GtkWidget *lb, JSCValue *arr, int pal);
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
                JSCValue *rows = jsc_value_object_get_property(res, "rows"); char *sc = jv_str(res, "scope"); double rv = jv_num(res, "revision");
                if (rows && jsc_value_is_array(rows)) { if (accept_sb_resp(&c->sb_scope, &c->sb_scope_gen, c->sb_min_gen, &c->sb_rev, j->gen, sc, rv)) { populate_from_array(c, c->sb_list, rows, 0); } }
                else if (j->kind == 2) { refresh_sidebar_rows(c); }
                g_free(sc); if (rows) { g_object_unref(rows); }
            }
        } else if (j->kind == 2) { refresh_sidebar_rows(c); }
        if (res) { g_object_unref(res); }
        if (j->kind == 0 && c->sb_dirty) { c->sb_dirty = 0; refresh_sidebar_rows(c); }
    }
    g_free(j->body); g_free(j->resp); g_free(j); return FALSE;
}
static gpointer rpc_worker(gpointer p) {
    RpcJob *j = (RpcJob *)p; int fd = connect_loopback(j->port, 0);
    if (fd >= 0) {
        size_t blen = strlen(j->body); char hdr[512];
        int hl = snprintf(hdr, sizeof(hdr), "POST /__orb_rpc HTTP/1.1\r\nHost: 127.0.0.1:%u\r\nContent-Type: application/json\r\nConnection: close\r\nX-Orb-Token: %s\r\nContent-Length: %zu\r\n\r\n", j->port, j->token, blen);
        if (hl > 0 && (size_t)hl < sizeof(hdr) && send(fd, hdr, (size_t)hl, MSG_NOSIGNAL) == hl && send(fd, j->body, blen, MSG_NOSIGNAL) == (ssize_t)blen) {
            GString *raw = g_string_sized_new(4096); char buf[4096]; ssize_t n;
            while ((n = recv(fd, buf, sizeof(buf), 0)) > 0 && raw->len < (4u << 20)) { g_string_append_len(raw, buf, n); }
            const char *sep = strstr(raw->str, "\r\n\r\n"); if (sep && strncmp(raw->str, "HTTP/1.1 200", 12) == 0) { j->resp = g_strdup(sep + 4); }
            g_string_free(raw, TRUE);
        }
        close(fd);
    }
    g_idle_add(rpc_done, j); return NULL;
}
static void rpc_call_async(OrbGtkChrome *c, const char *body, int kind, guint64 gen) {
    if (c->closed) { return; }
    RpcJob *j = g_new0(RpcJob, 1); j->c = c; j->port = c->port; snprintf(j->token, sizeof(j->token), "%s", c->token); j->body = g_strdup(body); j->kind = kind; j->gen = gen;
    g_thread_unref(g_thread_new("orb-rpc", rpc_worker, j));
}
static void toggle_row_expand(OrbGtkChrome *c, const char *rid) { char *lit = rid ? orb_json_escape_string(rid) : NULL; if (!lit) { return; } char req[1024]; snprintf(req, sizeof(req), "{\"command\":\"native_chrome_toggle_expand\",\"args\":{\"row_id\":%s}}", lit); free(lit); rpc_call_async(c, req, 2, ++c->sb_req_gen); }
static void on_chevron_clicked(GtkButton *b, gpointer ud) { toggle_row_expand((OrbGtkChrome *)ud, g_object_get_data(G_OBJECT(b), "orb-row-id")); }
static GtkWidget *make_row_widget(OrbGtkChrome *c, JSCValue *it, int pal, char *sig) {
    char *rid = jv_str(it, pal ? "id" : "row_id"), *kind = jv_str(it, "kind"), *title = jv_str(it, "title"), *sub = jv_str(it, "subtitle"), *target = jv_str(it, "target"), *sc = jv_str(it, "shortcut");
    gint32 depth = pal ? 0 : jv_int(it, "depth"), badge = pal ? 0 : jv_int(it, "badge");
    gboolean exp = !pal && jv_bool(it, "expandable"), open = !pal && jv_bool(it, "expanded"), sel = !pal && jv_bool(it, "selected"), attn = !pal && jv_bool(it, "attention");
    GtkWidget *row = gtk_list_box_row_new(), *hb = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
    gtk_widget_set_margin_start(hb, 8 + (depth > 8 ? 8 : depth) * 12); gtk_widget_set_margin_end(hb, 8); gtk_widget_set_margin_top(hb, 4); gtk_widget_set_margin_bottom(hb, 4); set_row_selected(row, sel);
    if (exp) {
        GtkWidget *cb = gtk_button_new_with_label(open ? "\xE2\x96\xBE" : "\xE2\x96\xB8"); gtk_button_set_relief(GTK_BUTTON(cb), GTK_RELIEF_NONE); gtk_widget_set_focus_on_click(cb, FALSE);
        gtk_style_context_add_class(gtk_widget_get_style_context(cb), "orb-chev"); g_object_set_data_full(G_OBJECT(cb), "orb-row-id", g_strdup(rid), g_free);
        g_signal_connect(cb, "clicked", G_CALLBACK(on_chevron_clicked), c); gtk_box_pack_start(GTK_BOX(hb), cb, FALSE, FALSE, 0);
    }
    GtkWidget *lbl = gtk_label_new(title); gtk_label_set_xalign(GTK_LABEL(lbl), 0.0f); gtk_label_set_ellipsize(GTK_LABEL(lbl), PANGO_ELLIPSIZE_END);
    if (strcmp(kind, "project") == 0) { gtk_style_context_add_class(gtk_widget_get_style_context(lbl), "orb-proj"); }
    gtk_box_pack_start(GTK_BOX(hb), lbl, TRUE, TRUE, 0);
    if (attn || badge > 0 || (pal && *sub) || *sc) {
        char meta[96];
        if (badge > 0) { snprintf(meta, sizeof(meta), "%d", (int)badge); } else if (*sc) { snprintf(meta, sizeof(meta), "%s", sc); } else if (pal && *sub) { snprintf(meta, sizeof(meta), "%s", sub); } else { snprintf(meta, sizeof(meta), "\xE2\x80\xA2"); }
        GtkWidget *ml = gtk_label_new(meta); gtk_style_context_add_class(gtk_widget_get_style_context(ml), "orb-dim"); gtk_box_pack_end(GTK_BOX(hb), ml, FALSE, FALSE, 0);
    }
    g_object_set_data_full(G_OBJECT(row), "orb-row-id", rid, g_free); g_object_set_data_full(G_OBJECT(row), "orb-kind", kind, g_free);
    g_object_set_data_full(G_OBJECT(row), "orb-target", target, g_free); g_object_set_data_full(G_OBJECT(row), "orb-sig", sig, g_free); g_object_set_data(G_OBJECT(row), "orb-exp", GINT_TO_POINTER(exp ? 1 : 0));
    g_free(title); g_free(sub); g_free(sc); gtk_container_add(GTK_CONTAINER(row), hb); gtk_widget_show_all(row); return row;
}
static void populate_from_array(OrbGtkChrome *c, GtkWidget *lb, JSCValue *arr, int pal) {
    const char *idk = pal ? "id" : "row_id"; gint32 len = (arr && jsc_value_is_array(arr)) ? jv_int(arr, "length") : 0, out = 0; if (len < 0) { len = 0; }
    GHashTable *keep = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, NULL);
    for (gint32 i = 0; i < len; ++i) { JSCValue *it = jsc_value_object_get_property_at_index(arr, (guint)i); if (it && jsc_value_is_object(it)) { char *id = jv_str(it, idk); if (*id) { g_hash_table_add(keep, id); } else { g_free(id); } } if (it) { g_object_unref(it); } }
    GList *ch = gtk_container_get_children(GTK_CONTAINER(lb));
    for (GList *l = ch; l; l = l->next) { const char *id = g_object_get_data(G_OBJECT(l->data), "orb-row-id"); if (!id || !*id || !g_hash_table_contains(keep, id)) { gtk_widget_destroy(GTK_WIDGET(l->data)); } }
    g_list_free(ch); g_hash_table_destroy(keep);
    for (gint32 i = 0; i < len; ++i) {
        JSCValue *it = jsc_value_object_get_property_at_index(arr, (guint)i); if (!it || !jsc_value_is_object(it)) { if (it) { g_object_unref(it); } continue; }
        char *rid = jv_str(it, idk), *sig = row_item_sig(it, pal);
        GtkListBoxRow *cur = gtk_list_box_get_row_at_index(GTK_LIST_BOX(lb), out), *lat;
        const char *cid = cur ? g_object_get_data(G_OBJECT(cur), "orb-row-id") : NULL, *csig = cur ? g_object_get_data(G_OBJECT(cur), "orb-sig") : NULL;
        if (cur && *rid && cid && strcmp(cid, rid) == 0) {
            if (csig && strcmp(csig, sig) == 0) { set_row_selected(GTK_WIDGET(cur), !pal && jv_bool(it, "selected")); g_free(sig); }
            else { gtk_widget_destroy(GTK_WIDGET(cur)); gtk_list_box_insert(GTK_LIST_BOX(lb), make_row_widget(c, it, pal, sig), out); }
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
    const char *t = g_object_get_data(G_OBJECT(r), "orb-target"), *k = g_object_get_data(G_OBJECT(r), "orb-kind");
    if (t && *t && (!k || strcmp(k, "folder") != 0) && strncmp(t, "folder:", 7) != 0) { eval_wv_target(c, k, t); }
    else if (GPOINTER_TO_INT(g_object_get_data(G_OBJECT(r), "orb-exp"))) { toggle_row_expand(c, g_object_get_data(G_OBJECT(r), "orb-row-id")); }
}
static void on_pal_row_activated(GtkListBox *lb, GtkListBoxRow *r, gpointer ud) {
    (void)lb; OrbGtkChrome *c = (OrbGtkChrome *)ud; if (!r) { return; }
    const char *t = g_object_get_data(G_OBJECT(r), "orb-target"), *k = g_object_get_data(G_OBJECT(r), "orb-kind");
    if (t && strncmp(t, "folder:", 7) == 0) { toggle_row_expand(c, t); } else { eval_wv_target(c, k, t); }
    ++c->pal_gen; gtk_popover_popdown(GTK_POPOVER(c->pal_pop));
}
static void on_pal_closed(GtkPopover *p, gpointer ud) { (void)p; ++((OrbGtkChrome *)ud)->pal_gen; }
static void on_win_destroy(GtkWidget *w, gpointer ud) { (void)w; ((OrbGtkChrome *)ud)->closed = 1; }
static void on_pal_search_changed(GtkSearchEntry *se, gpointer ud) { refresh_palette_items((OrbGtkChrome *)ud, gtk_entry_get_text(GTK_ENTRY(se))); }
static void on_pal_entry_activate(GtkEntry *e, gpointer ud) { (void)e; OrbGtkChrome *c = (OrbGtkChrome *)ud; GtkListBoxRow *sel = gtk_list_box_get_selected_row(GTK_LIST_BOX(c->pal_list)); if (!sel) { sel = gtk_list_box_get_row_at_index(GTK_LIST_BOX(c->pal_list), 0); } if (sel) { on_pal_row_activated(GTK_LIST_BOX(c->pal_list), sel, c); } }
static void open_palette(OrbGtkChrome *c) { gtk_entry_set_text(GTK_ENTRY(c->pal_entry), ""); refresh_palette_items(c, ""); gtk_popover_popup(GTK_POPOVER(c->pal_pop)); gtk_widget_grab_focus(c->pal_entry); }
static gboolean on_win_key_press(GtkWidget *w, GdkEventKey *ev, gpointer ud) { (void)w; guint mod = ev->state & gtk_accelerator_get_default_mod_mask(); return ((mod & (GDK_CONTROL_MASK | GDK_SUPER_MASK | GDK_META_MASK)) && (ev->keyval == GDK_KEY_k || ev->keyval == GDK_KEY_K)) ? (open_palette((OrbGtkChrome *)ud), TRUE) : FALSE; }
static void on_script_msg(WebKitUserContentManager *ucm, WebKitJavascriptResult *jr, gpointer ud) {
    (void)ucm; OrbGtkChrome *c = (OrbGtkChrome *)ud; JSCValue *v = webkit_javascript_result_get_js_value(jr); if (!v || !jsc_value_is_object(v)) { return; }
    char *cmd = jv_str(v, "command"); if (strcmp(cmd, "open_native_palette") == 0) { open_palette(c); } else if (strcmp(cmd, "set_native_sidebar") == 0) { JSCValue *args = jsc_value_object_get_property(v, "args"); gboolean open = (args && jsc_value_is_object(args)) ? jv_bool(args, "open") : !gtk_widget_get_visible(c->sb_box); if (args) { g_object_unref(args); } gtk_widget_set_visible(c->sb_box, open); } g_free(cmd);
}
static gboolean start_sse_watch(gpointer ud);
static gboolean on_sse_io(GIOChannel *ch, GIOCondition cond, gpointer ud) {
    OrbGtkChrome *c = (OrbGtkChrome *)ud; int fd = g_io_channel_unix_get_fd(ch); if (cond & (G_IO_HUP | G_IO_ERR | G_IO_NVAL)) { goto drop; }
    char buf[4096]; ssize_t n = recv(fd, buf, sizeof(buf) - 1, 0); if (n <= 0) { if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) { return TRUE; } goto drop; }
    g_string_append_len(c->sse_buf, buf, n); char *p; int hit = 0;
    while ((p = strstr(c->sse_buf->str, "\n\n")) != NULL) { size_t fl = (size_t)(p - c->sse_buf->str); if (g_strstr_len(c->sse_buf->str, (gssize)fl, "native_chrome_rows_changed")) { hit = 1; } g_string_erase(c->sse_buf, 0, (gssize)(fl + 2)); }
    if (hit) { c->sb_min_gen = c->sb_req_gen + 1; refresh_sidebar_rows(c); } return TRUE;
drop: c->sse_src = 0; g_io_channel_unref(c->sse_ch); c->sse_ch = NULL; close(fd); if (!c->retry_src) { c->retry_src = g_timeout_add(900, start_sse_watch, c); } return FALSE;
}
static gboolean start_sse_watch(gpointer ud) {
    OrbGtkChrome *c = (OrbGtkChrome *)ud; c->retry_src = 0; refresh_sidebar_rows(c);
    int fd = connect_loopback(c->port, 1); if (fd < 0) { return c->retry_src = g_timeout_add(450, start_sse_watch, c), FALSE; }
    char req[512]; int len = snprintf(req, sizeof(req), "GET /__orb_events HTTP/1.1\r\nHost: 127.0.0.1:%u\r\nAccept: text/event-stream\r\nX-Orb-Token: %s\r\n\r\n", c->port, c->token); if (len > 0) { (void)send(fd, req, (size_t)len, MSG_NOSIGNAL); }
    g_string_truncate(c->sse_buf, 0); c->sse_ch = g_io_channel_unix_new(fd); c->sse_src = g_io_add_watch(c->sse_ch, G_IO_IN | G_IO_HUP | G_IO_ERR, on_sse_io, c); return FALSE;
}
GtkWidget *orb_gtk_chrome_wrap(GtkWidget *win, GtkWidget *wv, WebKitUserContentManager *ucm, unsigned port, const char *token) {
    OrbGtkChrome *c = g_new0(OrbGtkChrome, 1); c->win = win; c->wv = wv; c->port = port; c->jsc = jsc_context_new(); c->sse_buf = g_string_sized_new(1024); snprintf(c->token, sizeof(c->token), "%s", token ? token : "");
    GtkCssProvider *cp = gtk_css_provider_new();
    gtk_css_provider_load_from_data(cp, ".orb-sb{background:#151517;color:#e4e4e7;border-right:1px solid #27272a;}.orb-sb list,.orb-pal list{background:transparent;color:#e4e4e7;}.orb-sb row,.orb-pal row{border:1px solid transparent;border-radius:6px;margin:1px 6px;outline:none;box-shadow:none;}.orb-sb row:hover,.orb-pal row:hover{background:rgba(255,255,255,0.05);}.orb-sb row.orb-selected,.orb-pal row:selected{background:rgba(255,255,255,0.09);}.orb-sb row:focus-visible,.orb-pal row:focus-visible,.orb-pal entry:focus{border-color:#52525b;outline:none;box-shadow:none;}.orb-proj{font-weight:600;color:#fafafa;}.orb-dim{color:#a1a1aa;font-size:11px;}.orb-chev{padding:0 2px;min-width:16px;min-height:16px;color:#a1a1aa;}", -1, NULL);
    gtk_style_context_add_provider_for_screen(gtk_widget_get_screen(win), GTK_STYLE_PROVIDER(cp), GTK_STYLE_PROVIDER_PRIORITY_APPLICATION); g_object_unref(cp);
    c->sb_box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0); gtk_widget_set_size_request(c->sb_box, 220, -1); gtk_style_context_add_class(gtk_widget_get_style_context(c->sb_box), "orb-sb");
    GtkWidget *top = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6), *kb = gtk_button_new_with_label("Search  Ctrl+K"), *scw = gtk_scrolled_window_new(NULL, NULL);
    gtk_widget_set_margin_start(top, 8); gtk_widget_set_margin_end(top, 8); gtk_widget_set_margin_top(top, 8); gtk_widget_set_margin_bottom(top, 6);
    g_signal_connect_swapped(kb, "clicked", G_CALLBACK(open_palette), c); gtk_box_pack_start(GTK_BOX(top), kb, TRUE, TRUE, 0); gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(scw), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
    c->sb_list = gtk_list_box_new(); gtk_list_box_set_selection_mode(GTK_LIST_BOX(c->sb_list), GTK_SELECTION_NONE); gtk_list_box_set_activate_on_single_click(GTK_LIST_BOX(c->sb_list), TRUE);
    g_signal_connect(c->sb_list, "row-activated", G_CALLBACK(on_sb_row_activated), c); gtk_container_add(GTK_CONTAINER(scw), c->sb_list); gtk_box_pack_start(GTK_BOX(c->sb_box), top, FALSE, FALSE, 0); gtk_box_pack_start(GTK_BOX(c->sb_box), scw, TRUE, TRUE, 0);
    c->pal_pop = gtk_popover_new(kb); gtk_style_context_add_class(gtk_widget_get_style_context(c->pal_pop), "orb-pal"); g_signal_connect(c->pal_pop, "closed", G_CALLBACK(on_pal_closed), c);
    GtkWidget *pb = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6), *pscw = gtk_scrolled_window_new(NULL, NULL); gtk_widget_set_size_request(pb, 420, 320); gtk_container_set_border_width(GTK_CONTAINER(pb), 8);
    c->pal_entry = gtk_search_entry_new(); c->pal_list = gtk_list_box_new(); gtk_list_box_set_activate_on_single_click(GTK_LIST_BOX(c->pal_list), TRUE);
    g_signal_connect(c->pal_entry, "search-changed", G_CALLBACK(on_pal_search_changed), c); g_signal_connect(c->pal_entry, "activate", G_CALLBACK(on_pal_entry_activate), c); g_signal_connect(c->pal_list, "row-activated", G_CALLBACK(on_pal_row_activated), c);
    gtk_container_add(GTK_CONTAINER(pscw), c->pal_list); gtk_box_pack_start(GTK_BOX(pb), c->pal_entry, FALSE, FALSE, 0); gtk_box_pack_start(GTK_BOX(pb), pscw, TRUE, TRUE, 0); gtk_widget_show_all(pb); gtk_container_add(GTK_CONTAINER(c->pal_pop), pb);
    c->paned = gtk_paned_new(GTK_ORIENTATION_HORIZONTAL); gtk_paned_pack1(GTK_PANED(c->paned), c->sb_box, FALSE, FALSE); gtk_paned_pack2(GTK_PANED(c->paned), wv, TRUE, FALSE); gtk_paned_set_position(GTK_PANED(c->paned), 220);
    g_signal_connect(ucm, "script-message-received::orbNative", G_CALLBACK(on_script_msg), c); webkit_user_content_manager_register_script_message_handler(ucm, "orbNative");
    g_signal_connect(win, "destroy", G_CALLBACK(on_win_destroy), c); g_signal_connect(win, "key-press-event", G_CALLBACK(on_win_key_press), c); g_idle_add(start_sse_watch, c); return c->paned;
}
#endif
int orb_gtk_chrome_self_test(void) {
    char *esc = orb_json_escape_string("m:\"1\""); int ok = esc && strcmp(esc, "\"m:\\\"1\\\"\"") == 0; free(esc);
#if defined(ORB_HAS_WEBKITGTK)
    JSCContext *ctx = jsc_context_new(); char *sc = NULL; guint64 sg = 0, rv = 0;
    JSCValue *a = jsc_value_new_from_json(ctx, "{\"row_id\":\"nav:inbox\",\"kind\":\"nav\",\"title\":\"Inbox\",\"selected\":false,\"badge\":1}");
    JSCValue *b = jsc_value_new_from_json(ctx, "{\"row_id\":\"nav:inbox\",\"kind\":\"nav\",\"title\":\"Inbox\",\"selected\":true,\"badge\":1}");
    JSCValue *d = jsc_value_new_from_json(ctx, "{\"row_id\":\"nav:inbox\",\"kind\":\"nav\",\"title\":\"Inbox\",\"selected\":true,\"badge\":2}");
    char *sa = a ? row_item_sig(a, 0) : NULL, *sb = b ? row_item_sig(b, 0) : NULL, *sd = d ? row_item_sig(d, 0) : NULL;
    ok = ok && sa && sb && sd && strcmp(sa, sb) == 0 && strcmp(sa, sd) != 0 && accept_sb_resp(&sc, &sg, 0, &rv, 1, "s:a", 50) && !accept_sb_resp(&sc, &sg, 0, &rv, 2, "s:a", 49) && accept_sb_resp(&sc, &sg, 3, &rv, 3, "s:b", 2) && !accept_sb_resp(&sc, &sg, 3, &rv, 2, "s:a", 99);
    g_free(sc); g_free(sa); g_free(sb); g_free(sd); if (a) { g_object_unref(a); } if (b) { g_object_unref(b); } if (d) { g_object_unref(d); } g_object_unref(ctx);
#endif
    return ok;
}
