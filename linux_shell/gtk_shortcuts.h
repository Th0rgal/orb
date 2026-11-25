#ifndef ORB_GTK_SHORTCUTS_H
#define ORB_GTK_SHORTCUTS_H

static gboolean orb_gtk_window_shortcut(GtkWindow *window, GdkEventKey *event,
                                        GtkWidget *webview, GtkWidget *sidebar) {
    if (gtk_widget_has_focus(webview)) return FALSE;
    GtkWidget *focus = gtk_window_get_focus(window);
    if (GTK_IS_ENTRY(focus)) return FALSE;
    guint modifiers = event->state & gtk_accelerator_get_default_mod_mask();
    guint k = gdk_keyval_to_lower(event->keyval);
    gboolean menu_key = (event->keyval == GDK_KEY_Menu && modifiers == 0) ||
        (event->keyval == GDK_KEY_F10 && modifiers == GDK_SHIFT_MASK);
    const char *kind = focus ? g_object_get_data(G_OBJECT(focus), "orb-kind") : NULL;
    gboolean sb_row = kind && (!g_strcmp0(kind, "mission") || !g_strcmp0(kind, "project") ||
                               !g_strcmp0(kind, "folder") || !g_strcmp0(kind, "file"));
    if (menu_key && sb_row && !gtk_grab_get_current())
        return orb_gtk_row_context_menu(webview, gtk_widget_get_parent(focus), focus, NULL);
    if (modifiers == 0 && event->keyval == GDK_KEY_F2 && sb_row && !gtk_grab_get_current())
        return orb_sidebar_rename_focused(webview, focus);
    gboolean primary = (modifiers & (GDK_CONTROL_MASK | GDK_SUPER_MASK | GDK_META_MASK)) != 0;
    gboolean extra = (modifiers & (GDK_SHIFT_MASK | GDK_MOD1_MASK)) != 0;
    if (primary && !extra && sb_row && !gtk_grab_get_current()) {
        if (k == GDK_KEY_x || k == GDK_KEY_c)
            return orb_sidebar_cut_copy(webview, sidebar, focus, k == GDK_KEY_c);
        if (k == GDK_KEY_v)
            return orb_sidebar_paste(webview, focus);
    }
    if (primary && (event->keyval == GDK_KEY_Delete || event->keyval == GDK_KEY_KP_Delete))
        return orb_sel_delete(webview, sidebar, "m:current");
    if (event->keyval == GDK_KEY_Escape) {
        gboolean had = orb_sel_clear(sidebar) || orb_sidebar_has_cut();
        orb_sidebar_mark_cut(FALSE);
        if (had) return TRUE;
    }

    gboolean toggle = modifiers == GDK_CONTROL_MASK && k == GDK_KEY_b;
    if (!ORB_EMBEDDED && (!toggle || GTK_IS_EDITABLE(focus) || gtk_grab_get_current())) return FALSE;
    if (!primary || event->is_modifier) return FALSE;
    gtk_widget_grab_focus(webview);
    return gtk_window_propagate_key_event(window, event);
}

#endif
