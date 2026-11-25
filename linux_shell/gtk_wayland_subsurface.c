#include "gtk_wayland_subsurface.h"
#include <stdlib.h>
#include <string.h>

#if defined(ORB_HAS_WAYLAND) && defined(GDK_WINDOWING_WAYLAND)
#include <gdk/gdkwayland.h>
#include <wayland-client.h>

static void reg_global(void *data, struct wl_registry *reg, uint32_t name,
                       const char *iface, uint32_t ver) {
    OrbWlSubsurface *sub = data;
    if (strcmp(iface, wl_compositor_interface.name) == 0 && !sub->compositor)
        sub->compositor = wl_registry_bind(reg, name, &wl_compositor_interface, ver < 4 ? ver : 4);
    else if (strcmp(iface, wl_subcompositor_interface.name) == 0 && !sub->subcompositor)
        sub->subcompositor = wl_registry_bind(reg, name, &wl_subcompositor_interface, 1);
}

static void reg_remove(void *data, struct wl_registry *reg, uint32_t name) {
    (void)data; (void)reg; (void)name;
}

static const struct wl_registry_listener reg_listener = { reg_global, reg_remove };

gboolean orb_wl_subsurface_ensure(OrbWlSubsurface *sub, GtkWidget *canvas, gboolean *moved) {
    if (moved) *moved = FALSE;
    const char *gpu_env = getenv("ORB_LEANUI_GPU");
    if (gpu_env && (!strcmp(gpu_env, "0") || !strcmp(gpu_env, "false"))) return FALSE;
    if (!canvas || !gtk_widget_get_mapped(canvas)) return FALSE;
    GdkDisplay *gd = gtk_widget_get_display(canvas);
    if (!gd || !GDK_IS_WAYLAND_DISPLAY(gd)) return FALSE;
    GtkWidget *top = gtk_widget_get_toplevel(canvas);
    GdkWindow *gw = top ? gtk_widget_get_window(top) : NULL;
    struct wl_display *dpy = gdk_wayland_display_get_wl_display(gd);
    struct wl_surface *parent = gw ? gdk_wayland_window_get_wl_surface(gw) : NULL;
    if (!dpy || !parent) return FALSE;
    if (sub->parent && sub->parent != parent) return FALSE;

    if (!sub->compositor || !sub->subcompositor) {
        sub->display = dpy;
        sub->registry = wl_display_get_registry(dpy);
        if (!sub->registry) return FALSE;
        wl_registry_add_listener(sub->registry, &reg_listener, sub);
        wl_display_roundtrip(dpy);
        if (!sub->compositor || !sub->subcompositor) {
            orb_wl_subsurface_detach(sub);
            return FALSE;
        }
    }

    if (!sub->surface) {
        sub->surface = wl_compositor_create_surface(sub->compositor);
        if (!sub->surface) return FALSE;
        struct wl_region *empty = wl_compositor_create_region(sub->compositor);
        if (empty) {
            wl_surface_set_input_region(sub->surface, empty);
            wl_region_destroy(empty);
        }
        sub->subsurface = wl_subcompositor_get_subsurface(sub->subcompositor, sub->surface, parent);
        if (!sub->subsurface) {
            wl_surface_destroy(sub->surface);
            sub->surface = NULL;
            return FALSE;
        }
        wl_subsurface_set_desync(sub->subsurface);
        wl_subsurface_place_below(sub->subsurface, parent);
        sub->parent = parent;
        if (moved) *moved = TRUE;
    }

    int tx = 0, ty = 0;
    if (gtk_widget_translate_coordinates(canvas, top, 0, 0, &tx, &ty)) {
        if (!sub->positioned || tx != sub->x || ty != sub->y) {
            wl_subsurface_set_position(sub->subsurface, tx, ty);
            sub->x = tx; sub->y = ty; sub->positioned = TRUE;
            if (moved) *moved = TRUE;
        }
    }
    int scale = gtk_widget_get_scale_factor(canvas);
    if (scale < 1) scale = 1;
    if (scale != sub->scale) {
        wl_surface_set_buffer_scale(sub->surface, scale);
        sub->scale = scale;
        if (moved) *moved = TRUE;
    }
    wl_display_flush(dpy);
    return TRUE;
}

void orb_wl_subsurface_detach(OrbWlSubsurface *sub) {
    if (!sub) return;
    if (sub->subsurface) { wl_subsurface_destroy(sub->subsurface); sub->subsurface = NULL; }
    if (sub->surface) { wl_surface_destroy(sub->surface); sub->surface = NULL; }
    if (sub->subcompositor) { wl_subcompositor_destroy(sub->subcompositor); sub->subcompositor = NULL; }
    if (sub->compositor) { wl_compositor_destroy(sub->compositor); sub->compositor = NULL; }
    if (sub->registry) { wl_registry_destroy(sub->registry); sub->registry = NULL; }
    if (sub->display) wl_display_flush(sub->display);
    sub->display = NULL;
    sub->parent = NULL;
    sub->x = sub->y = sub->scale = 0;
    sub->positioned = FALSE;
}

#else

gboolean orb_wl_subsurface_ensure(OrbWlSubsurface *sub, GtkWidget *canvas, gboolean *moved) {
    (void)sub; (void)canvas;
    if (moved) *moved = FALSE;
    return FALSE;
}

void orb_wl_subsurface_detach(OrbWlSubsurface *sub) {
    (void)sub;
}

#endif
