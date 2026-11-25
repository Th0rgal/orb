#pragma once
#include "gtk_leanui.h"
#include "gtk_wayland_subsurface.h"
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
    OrbWlSubsurface wl;
    guint idle, tick, animation;
    int width, height, scale, scroll, limit;
    double scroll_pos;
    gboolean light, can_back, can_forward, gpu_active, gpu_disabled;
} OrbSidebar;

void orb_sidebar_invalidate(OrbSidebar *s);
void orb_sidebar_model_free(OrbSidebar *s);
void orb_sidebar_hits(void *view, const char *regions);
int orb_leanui_paint(const char *request, uint8_t *argb, size_t capacity,
                     OrbSidebarHits hits, void *view);
