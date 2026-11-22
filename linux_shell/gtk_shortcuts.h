#ifndef ORB_GTK_SHORTCUTS_H
#define ORB_GTK_SHORTCUTS_H

static gboolean orb_gtk_window_shortcut(GtkWindow *window, GdkEventKey *event,
                                        GtkWidget *webview, GtkWidget *sidebar) {
    if (gtk_widget_has_focus(webview)) return FALSE;
    GtkWidget *focus = gtk_window_get_focus(window);
    guint modifiers = event->state & gtk_accelerator_get_default_mod_mask();
    gboolean primary = (modifiers & (GDK_CONTROL_MASK | GDK_SUPER_MASK | GDK_META_MASK)) != 0;
    if (primary && (event->keyval == GDK_KEY_Delete || event->keyval == GDK_KEY_KP_Delete) &&
        !GTK_IS_ENTRY(focus))
        return orb_sel_delete(webview, sidebar, "m:current");
    if (event->keyval == GDK_KEY_Escape && orb_sel_clear(sidebar)) return TRUE;

    gboolean toggle = modifiers == GDK_CONTROL_MASK && gdk_keyval_to_lower(event->keyval) == GDK_KEY_b;
    if (!ORB_EMBEDDED && (!toggle || GTK_IS_EDITABLE(focus) || gtk_grab_get_current())) return FALSE;
    if (!primary || event->is_modifier) return FALSE;
    gtk_widget_grab_focus(webview);
    return gtk_window_propagate_key_event(window, event);
}

#endif
