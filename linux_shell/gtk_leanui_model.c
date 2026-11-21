#include "gtk_leanui_private.h"
#include "gtk_menu.h"
#include <stdio.h>
#include <string.h>

static char *field(JSCValue *row, const char *name) {
    JSCValue *v = jsc_value_object_get_property(row, name);
    char *out = jsc_value_is_string(v) ? jsc_value_to_string(v) : g_strdup("");
    g_object_unref(v);
    return out;
}
static int number(JSCValue *row, const char *name) {
    JSCValue *v = jsc_value_object_get_property(row, name);
    int n = jsc_value_is_number(v) ? jsc_value_to_int32(v) : jsc_value_is_boolean(v) && jsc_value_to_boolean(v);
    g_object_unref(v);
    return n;
}
static gboolean press(GtkWidget *btn, GdkEventButton *event, OrbSidebar *s) {
    if (event->button == GDK_BUTTON_SECONDARY)
        return orb_gtk_row_context_menu(s->wv, s->overlay, btn, (GdkEvent *)event);
    if (event->button != GDK_BUTTON_PRIMARY) return FALSE;
    if (event->state & (GDK_CONTROL_MASK | GDK_SUPER_MASK | GDK_SHIFT_MASK))
        return orb_sel_click(s->overlay, btn, (event->state & GDK_SHIFT_MASK) != 0);
    orb_sel_clear(s->overlay);
    return FALSE;
}

static void activate(GtkButton *button, OrbSidebar *s) {
    GObject *b = G_OBJECT(button);
    const char *action = g_object_get_data(b, "orb-action");
    const char *rid = g_object_get_data(b, "orb-row-id");
    const char *parent = g_object_get_data(b, "orb-parent-id");
    const char *target = g_object_get_data(b, "orb-target");
    const char *kind = g_object_get_data(b, "orb-kind");
    if (!strcmp(action,"tool")) {
        if (!strcmp(target,"sidebar")) s->action(s->chrome,"hide","");
        else s->action(s->chrome,"nav",!strcmp(target,"back") ? "history-back" :
                       !strcmp(target,"forward") ? "history-forward" : "search");
    } else if (!strcmp(action,"add")) {
        const char *slug = g_str_has_prefix(parent,"proj:") ? parent+5 : parent+7;
        g_autofree char *nav = g_strconcat("new-agent:",slug,NULL);
        s->action(s->chrome,"nav",nav);
    } else if (!strcmp(action,"expand")) s->action(s->chrome,"expand",parent);
    else if (!strcmp(rid,"section:projects")) s->action(s->chrome,"nav","new-project");
    else if (!strcmp(kind,"project") || !strcmp(kind,"folder") || (!*target && g_object_get_data(b,"orb-exp")))
        s->action(s->chrome,"expand",rid);
    else s->action(s->chrome,kind,target);
}
static gboolean key_press(GtkWidget *widget, GdkEventKey *event, gpointer unused) {
    (void)unused;
    if (event->state & gtk_accelerator_get_default_mod_mask()) return FALSE;
    if (event->keyval != GDK_KEY_Return && event->keyval != GDK_KEY_KP_Enter) return FALSE;
    gtk_button_clicked(GTK_BUTTON(widget));
    return TRUE;
}

static GtkWidget *button(OrbSidebar *s, const char *action, const char *rid, const char *label) {
    char *key = g_strdup_printf("%s/%s", action, rid);
    GtkWidget *b = g_hash_table_lookup(s->buttons, key);
    if (!b) {
        b = gtk_button_new();
        gtk_widget_set_no_show_all(b, TRUE);
        g_object_set_data_full(G_OBJECT(b), "orb-action", g_strdup(action), g_free);
        g_signal_connect(b, "clicked", G_CALLBACK(activate), s);
        g_signal_connect(b, "button-press-event", G_CALLBACK(press), s);
        g_signal_connect(b, "key-press-event", G_CALLBACK(key_press), NULL);
        gtk_overlay_add_overlay(GTK_OVERLAY(s->overlay), b);
        g_hash_table_insert(s->buttons, key, b);
    } else g_free(key);
    atk_object_set_name(gtk_widget_get_accessible(b), label);
    g_object_set_data(G_OBJECT(b), "orb-present", GINT_TO_POINTER(1));
    return b;
}

static void add_row(OrbSidebar *s, JSCValue *row) {
    g_autofree char *rid = field(row, "row_id"), *kind = field(row, "kind"), *title = field(row, "title");
    g_autofree char *shortcut = field(row, "shortcut"), *color = field(row, "color"), *status = field(row, "status");
    if (!*rid) return;
    GtkWidget *b = button(s, "row", rid, title);
    g_object_set_data_full(G_OBJECT(b), "orb-row-id", g_strdup(rid), g_free);
    g_object_set_data_full(G_OBJECT(b), "orb-kind", g_strdup(kind), g_free);
    g_object_set_data_full(G_OBJECT(b), "orb-title", g_strdup(title), g_free);
    g_object_set_data_full(G_OBJECT(b), "orb-status", g_strdup(status), g_free);
    g_object_set_data_full(G_OBJECT(b), "orb-project", field(row, "project"), g_free);
    g_object_set_data_full(G_OBJECT(b), "orb-target", field(row, "target"), g_free);
    g_object_set_data(G_OBJECT(b), "orb-exp", GINT_TO_POINTER(number(row, "expandable")));
    guint id = 1000 + s->indices->len;
    int badge = !strcmp(kind, "mission") ? number(row, "child_count") : number(row, "badge");
    g_ptr_array_add(s->indices, b);
    /* Only display fields enter the renderer. Commands retain their original strings. */
    char *fields[] = {rid,kind,title,status,shortcut,color};
    for (guint i = 0; i < G_N_ELEMENTS(fields); i++) g_strdelimit(fields[i], "\t\r\n", ' ');
    g_string_append_printf(s->rows, "%u\t%s\t%s\t%s\t%d\t%s\t%s\t%d\t%d\t%d\t%s\n",
        id, rid, kind, title, number(row,"depth"), status, shortcut, badge, number(row,"selected"),
        number(row,"expanded"), color);
}

static gboolean animate(gpointer data) {
    OrbSidebar *s = data;
    if (gtk_widget_get_mapped(s->overlay)) orb_sidebar_invalidate(s);
    return G_SOURCE_CONTINUE;
}
void orb_leanui_rows(GtkWidget *view, JSCValue *rows, JSCValue *footer, const char *scope) {
    OrbSidebar *s = g_object_get_data(G_OBJECT(view), "orb-sidebar");
    if (g_strcmp0(scope, s->scope)) {
        orb_sel_clear(view);
        s->scroll = 0;
        g_free(s->scope);
        s->scope = g_strdup(scope);
    }
    GHashTableIter iter;
    gpointer b;
    g_hash_table_iter_init(&iter, s->buttons);
    while (g_hash_table_iter_next(&iter, NULL, &b)) g_object_set_data(b, "orb-present", NULL);
    g_ptr_array_set_size(s->indices, 0);
    g_string_truncate(s->rows, 0);
    for (int i = 0, n = number(rows,"length"); i < n; i++) {
        JSCValue *row = jsc_value_object_get_property_at_index(rows, (guint)i);
        if (jsc_value_is_object(row)) add_row(s,row);
        g_object_unref(row);
    }
    if (footer && jsc_value_is_object(footer)) add_row(s,footer);
    /* Only row buttons are canonical model objects. Tool and nested buttons follow layout. */
    g_hash_table_iter_init(&iter, s->buttons);
    while (g_hash_table_iter_next(&iter, NULL, &b)) {
        if (!g_object_get_data(b,"orb-present") && g_object_get_data(b,"orb-row-id")) {
            g_hash_table_iter_remove(&iter);
            gtk_widget_destroy(b);
        }
    }
    orb_sel_sync(view);
    orb_sidebar_invalidate(s);
}

static GtkWidget *hit_button(OrbSidebar *s, unsigned id) {
    const char *tools[] = {"sidebar","search","back","forward"};
    if (id >= 117 && id <= 120) {
        GtkWidget *b = button(s,"tool",tools[id-117],tools[id-117]);
        g_object_set_data_full(G_OBJECT(b),"orb-target",g_strdup(tools[id-117]),g_free);
        gtk_widget_set_sensitive(b, id == 119 ? s->can_back : id == 120 ? s->can_forward : TRUE);
        return b;
    }
    const char *action = "row";
    if (id >= 5000000) { action = "add"; id -= 5000000; }
    else if (id >= 4000000) { action = "expand"; id -= 4000000; }
    if (id < 1000 || id-1000 >= s->indices->len) return NULL;
    GtkWidget *row = g_ptr_array_index(s->indices, id-1000);
    if (!strcmp(action,"row")) return row;
    const char *rid = g_object_get_data(G_OBJECT(row),"orb-row-id");
    GtkWidget *b = button(s,action,rid,!strcmp(action,"add") ? "New agent in project" : "Toggle child missions");
    g_object_set_data_full(G_OBJECT(b),"orb-parent-id",g_strdup(rid),g_free);
    return b;
}

void orb_sidebar_hits(void *view, const char *regions) {
    OrbSidebar *s = view;
    g_auto(GStrv) lines = g_strsplit(regions, "\n", -1);
    s->limit = atoi(lines[0]);
    if (s->scroll > s->limit) { s->scroll = s->limit; orb_sidebar_invalidate(s); }
    GHashTableIter iter;
    gpointer child;
    g_hash_table_iter_init(&iter,s->buttons);
    while (g_hash_table_iter_next(&iter,NULL,&child)) g_object_set_data(child,"orb-visible",NULL);
    gboolean running = FALSE;
    for (char **line = lines+1; *line; line++) {
        unsigned id;
        GdkRectangle r;
        if (sscanf(*line,"%u %d %d %d %d",&id,&r.x,&r.y,&r.width,&r.height) != 5) continue;
        GtkWidget *b = hit_button(s,id);
        if (!b) continue;
        const char *status = g_object_get_data(G_OBJECT(b),"orb-status");
        running |= !g_strcmp0(status,"running") || !g_strcmp0(status,"active");
        GdkRectangle *old = g_object_get_data(G_OBJECT(b),"orb-hit");
        if (!old || !gdk_rectangle_equal(old,&r)) {
            g_object_set_data_full(G_OBJECT(b),"orb-hit",g_memdup2(&r,sizeof r),g_free);
            gtk_widget_queue_resize(b);
        }
        g_object_set_data(G_OBJECT(b),"orb-visible",GINT_TO_POINTER(1));
        gtk_widget_show(b);
    }
    g_hash_table_iter_init(&iter,s->buttons);
    while (g_hash_table_iter_next(&iter,NULL,&child)) {
        if (g_object_get_data(child,"orb-visible")) continue;
        gtk_widget_hide(child);
        if (!g_object_get_data(child,"orb-row-id")) {
            g_hash_table_iter_remove(&iter);
            gtk_widget_destroy(child);
        }
    }
    gboolean animations = TRUE;
    g_object_get(gtk_widget_get_settings(s->overlay),"gtk-enable-animations",&animations,NULL);
    if (running && animations && !s->animation) s->animation = g_timeout_add(100,animate,s);
    if ((!running || !animations) && s->animation) { g_source_remove(s->animation); s->animation = 0; }
}

void orb_sidebar_model_free(OrbSidebar *s) {
    g_hash_table_destroy(s->buttons);
    g_ptr_array_free(s->indices,TRUE);
    g_string_free(s->rows,TRUE);
    g_free(s->scope);
}
