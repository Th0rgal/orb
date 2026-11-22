#include "sidebar_host.h"
#include <lean/lean.h>
#include <dlfcn.h>
#include <stdio.h>

static int paint(void *renderer, const char *request, uint8_t *argb, size_t capacity,
                 OrbSidebarHits hits, void *view) {
    lean_object *fn = renderer;
    lean_inc(fn);
    lean_object *res = lean_apply_2(fn, lean_mk_string(request), lean_io_mk_world());
    if (lean_io_result_is_error(res)) {
        lean_io_result_show_error(res);
        lean_dec(res);
        return 0;
    }
    lean_object *frame = lean_io_result_get_value(res);
    lean_object *pixels = lean_ctor_get(frame, 1);
    size_t n = lean_sarray_size(pixels);
    if (n == capacity) {
        const uint8_t *rgba = lean_sarray_cptr(pixels);
        for (size_t i = 0; i < n; i += 4) {
            argb[i] = rgba[i+2]; argb[i+1] = rgba[i+1];
            argb[i+2] = rgba[i]; argb[i+3] = rgba[i+3];
        }
        hits(view, lean_string_cstr(lean_ctor_get(frame, 0)));
    }
    lean_dec(res);
    return n == capacity;
}

lean_obj_res lean_ui_sidebar_host(b_lean_obj_arg path, b_lean_obj_arg renderer) {
    void *module = dlopen(lean_string_cstr(path), RTLD_NOW | RTLD_LOCAL);
    OrbSidebarHost run = module ? (OrbSidebarHost)dlsym(module, "orb_sidebar_host") : NULL;
    if (!run) return lean_io_result_mk_error(lean_mk_io_user_error(lean_mk_string(dlerror())));
    /* GTK installs process-global types and callbacks. Keep the module loaded. */
    return lean_io_result_mk_ok(lean_box_uint32((uint32_t)run(paint, renderer)));
}
