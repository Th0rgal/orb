#pragma once
#include "gtk_leanui.h"
#include "../lean/OrbDesktop/c/sidebar_host.h"

typedef struct {
    GtkWidget *overlay, *canvas, *wv;
    OrbSidebarAction action;
    gpointer chrome;
    GHashTable *buttons; /* stable key -> unowned overlay child */
    GPtrArray *indices;  /* current renderer id -> overlay child */
    GString *rows;
    char *scope;
    cairo_surface_t *surface;
    guint idle, animation;
    int width, height, scale, scroll, limit;
    gboolean light, can_back, can_forward;
} OrbSidebar;

void orb_sidebar_invalidate(OrbSidebar *s);
void orb_sidebar_model_free(OrbSidebar *s);
void orb_sidebar_hits(void *view, const char *regions);
