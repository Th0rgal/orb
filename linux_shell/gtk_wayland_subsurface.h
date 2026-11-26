#pragma once
#include <gtk/gtk.h>
#include <stdint.h>

struct wl_display;
struct wl_registry;
struct wl_compositor;
struct wl_subcompositor;
struct wl_surface;
struct wl_subsurface;

typedef struct {
    struct wl_display *display;
    struct wl_registry *registry;
    struct wl_compositor *compositor;
    struct wl_subcompositor *subcompositor;
    struct wl_surface *surface;
    struct wl_subsurface *subsurface;
    struct wl_surface *parent;
    int x, y, scale;
    gboolean positioned;
    gboolean above; /* stack above the window (an overlay) instead of below it (a pane) */
} OrbWlSubsurface;

/* Ensure a Wayland subsurface below (or, with `above`, over) the GTK window for Vulkan WSI presentation.
 * Sets *moved to TRUE when position/creation requires a parent surface commit. */
gboolean orb_wl_subsurface_ensure(OrbWlSubsurface *sub, GtkWidget *canvas, gboolean *moved);

/* Destroy the Wayland subsurface (call only after Vulkan has destroyed its swapchain/surface). */
void orb_wl_subsurface_detach(OrbWlSubsurface *sub);

/* Punch a transparent hole for the Vulkan subsurface while squaring off inner right corners. */
void orb_wl_subsurface_draw_mask(cairo_t *cr, int width, int height, gboolean light);
