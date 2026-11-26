/* linux_shell/tests/palette_gpu_harness.c — loaded by `orb-desktop-native --gtk-sidebar-host` in
 * place of the hybrid shell (lean/OrbDesktop/tests/test_palette_gpu_subsurface.py). Opens the real
 * palette over a striped background, injects items, moves the selection and types, and asks the
 * compositor for a screenshot while open and after close. No locald: RPC is stubbed. */
#include "gtk_leanui_palette_private.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static OrbSidebarPaint paint;
static void *renderer;
static GtkWidget *overlay;
static const char *outdir;

int orb_leanui_paint(const char *request, uint8_t *argb, size_t capacity, OrbSidebarHits hits, void *view) {
    return paint ? paint(renderer, request, argb, capacity, hits, view) : 0;
}
char *orb_locald_rpc_post(unsigned port, const char *token, const char *body) {
    (void)port; (void)token; (void)body;
    return NULL;
}
char *orb_json_escape_string(const char *s) { return g_strdup_printf("\"%s\"", s ? s : ""); }
void orb_sidebar_invalidate(OrbSidebar *s) { (void)s; }

static gboolean stripes(GtkWidget *w, cairo_t *cr, gpointer data) {
    (void)data;
    int width = gtk_widget_get_allocated_width(w), height = gtk_widget_get_allocated_height(w);
    const double c[5][3] = {{1, 0, 0}, {0, .8, 0}, {0, 0, 1}, {1, 1, 1}, {0, 0, 0}};
    for (int i = 0; i < 5; i++) {
        cairo_set_source_rgb(cr, c[i][0], c[i][1], c[i][2]);
        cairo_rectangle(cr, i * width / 5.0, 0, width / 5.0 + 1, height);
        cairo_fill(cr);
    }
    return TRUE;
}

static void shot(const char *name) {
    char *argv[] = {(char *)getenv("HARNESS_SCREENSHOOTER"), NULL};
    char *out = NULL, *err = NULL;
    int status = 0;
    gboolean ok = g_spawn_sync(outdir, argv, NULL, 0, NULL, NULL, &out, &err, &status, NULL);
    OrbPalette *p = g_object_get_data(G_OBJECT(overlay), "orb-palette");
    printf("harness: shot %s ok=%d status=%d gpu_active=%d gpu_disabled=%d open=%d out=%s err=%s\n", name, ok, status,
           p ? p->gpu_active : -1, p ? p->gpu_disabled : -1, p ? p->open : -1, out ? out : "", err ? err : "");
    fflush(stdout);
    g_free(out); g_free(err);
}

static gboolean step(gpointer data) {
    int n = GPOINTER_TO_INT(data);
    OrbPalette *p = g_object_get_data(G_OBJECT(overlay), "orb-palette");
    if (n == 0) {
        if (getenv("HARNESS_LIGHT")) orb_leanui_palette_theme(overlay, TRUE);
        orb_leanui_palette_open(overlay);
    } else if (n == 1) {
        orb_pal_clear_items(p);
        const char *titles[] = {"Refactor the sidebar cache", "Fix palette handoff", "Machines", "Project Orchard",
                                "Settings · Models", "Audit Vulkan subsurface"};
        const char *kinds[] = {"mission", "mission", "nav", "project", "settings", "mission"};
        const char *ids[] = {"m:1", "m:2", "nav:machines", "proj:orchard", "settings:models", "m:3"};
        for (int i = 0; i < 6; i++) {
            OrbPaletteItem *it = &p->items[i];
            it->id = g_strdup(ids[i]); it->kind = g_strdup(kinds[i]); it->title = g_strdup(titles[i]);
            it->subtitle = g_strdup(i % 2 ? "orb · running" : "orb · completed"); it->target = g_strdup(ids[i]);
            it->status = g_strdup(i == 0 ? "running" : "completed"); it->shortcut = g_strdup(i == 2 ? "⌘3" : "");
            it->color = g_strdup(i == 3 ? "blue" : "");
        }
        p->count = 6; p->selected = 1; g_string_assign(p->query, "orb");
        orb_pal_invalidate(p);
    } else if (n >= 2 && n < 14) {
        /* Steady-state frames: move the selection, then type. */
        if (n < 8) p->selected = n % 6;
        else g_string_append_c(p->query, 'a' + n);
        orb_pal_invalidate(p);
    } else if (n == 14) {
        shot("open");
    } else if (n == 15) {
        orb_pal_close(p, FALSE);
    } else if (n == 16) {
        shot("closed");
    } else {
        gtk_main_quit();
    }
    return G_SOURCE_REMOVE;
}

int orb_sidebar_host(OrbSidebarPaint callback, void *context) {
    paint = callback; renderer = context;
    outdir = getenv("HARNESS_OUT") ? getenv("HARNESS_OUT") : ".";
    gtk_init(NULL, NULL);
    GtkWidget *win = gtk_window_new(GTK_WINDOW_TOPLEVEL);
    gtk_window_set_decorated(GTK_WINDOW(win), FALSE);
    gtk_window_set_default_size(GTK_WINDOW(win), 1000, 700);
    GtkWidget *base = gtk_drawing_area_new();
    g_signal_connect(base, "draw", G_CALLBACK(stripes), NULL);
    overlay = orb_leanui_palette_new(base, NULL, 0, "", NULL, NULL);
    gtk_container_add(GTK_CONTAINER(win), overlay);
    gtk_widget_show_all(win);
    for (int i = 0; i < 18; i++) g_timeout_add(i < 2 ? 800 + 1000 * i : 2800 + 500 * (i - 2), step, GINT_TO_POINTER(i));
    gtk_main();
    return 0;
}
