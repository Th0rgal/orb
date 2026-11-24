/* linux_shell/gtk_chrome.h — Hybrid Native Chrome (GTK3 sidebar). */
#ifndef ORB_GTK_CHROME_H
#define ORB_GTK_CHROME_H

char *orb_json_escape_string(const char *s);
int orb_gtk_chrome_self_test(void);

#if defined(ORB_HAS_WEBKITGTK)
#include <gtk/gtk.h>
#include <webkit2/webkit2.h>
char *orb_locald_rpc_post(unsigned port, const char *token, const char *body);
GtkWidget *orb_gtk_chrome_wrap(GtkWidget *win, GtkWidget *wv, WebKitUserContentManager *ucm,
                               unsigned port, const char *token);
#endif

#endif
