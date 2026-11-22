#pragma once
#include <gtk/gtk.h>
#include <jsc/jsc.h>

typedef void (*OrbSidebarAction)(gpointer chrome, const char *kind, const char *target);
#ifdef ORB_LEANUI_HOST
GtkWidget *orb_leanui_new(GtkWidget *webview, OrbSidebarAction activate, gpointer chrome);
void orb_leanui_rows(GtkWidget *view, JSCValue *rows, JSCValue *footer, const char *scope);
void orb_leanui_theme(GtkWidget *view, gboolean light);
void orb_leanui_history(GtkWidget *view, gboolean back, gboolean forward);
#define ORB_EMBEDDED 1
#else
#define ORB_EMBEDDED 0
#endif

#ifndef ORB_LEANUI_HOST
/* Classic is also built standalone by older packagers. */
#define orb_leanui_new(...) NULL
#define orb_leanui_rows(...) ((void)0)
#define orb_leanui_theme(...) ((void)0)
#define orb_leanui_history(...) ((void)0)
#endif
