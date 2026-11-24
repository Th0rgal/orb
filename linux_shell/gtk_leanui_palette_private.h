/* linux_shell/gtk_leanui_palette_private.h — Internal palette overlay state & helpers. */
#pragma once
#include "gtk_leanui_private.h"
#include "gtk_leanui_palette.h"
#include "gtk_chrome.h"

typedef struct {
    char *id, *kind, *title, *subtitle, *target, *status, *shortcut, *color;
} OrbPaletteItem;

typedef struct {
    GtkWidget *overlay, *canvas, *wv, *prev_focus;
    OrbSidebarAction action;
    gpointer chrome;
    JSCContext *jsc;
    unsigned port;
    char token[128];
    GString *query;
    OrbPaletteItem items[ORB_PALETTE_MAX_ITEMS];
    OrbPaletteHit hits[ORB_PALETTE_MAX_ITEMS], card;
    size_t hit_count;
    int count, selected, has_card, width, height, scale, inflight;
    double scroll_acc;
    guint64 req_gen, applied_gen;
    cairo_surface_t *surface;
    guint idle;
    gboolean open, light, closed, dirty, pending_enter;
} OrbPalette;

void orb_pal_clear_items(OrbPalette *p);
void orb_pal_try_free(OrbPalette *p);
void orb_pal_invalidate(OrbPalette *p);
void orb_pal_query(OrbPalette *p);
void orb_pal_close(OrbPalette *p, gboolean restore_prev);
void orb_pal_activate(OrbPalette *p, int idx);
