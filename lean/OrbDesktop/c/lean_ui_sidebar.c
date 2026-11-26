#include "sidebar_host.h"
#include <lean/lean.h>
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>

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
    const char *hit_str = lean_string_cstr(lean_ctor_get(frame, 0));
    if (capacity == 0 && argb == NULL) {
        int rc = -1;
        if (strncmp(hit_str, "GPU_OK\n", 7) == 0) {
            if (hits) hits(view, hit_str + 7);
            rc = 2;
        } else if (strcmp(hit_str, "GPU_SKIP") == 0) {
            rc = 0;
        } else if (strcmp(hit_str, "GPU_DETACHED") == 0) {
            rc = 1;
        }
        lean_dec(res);
        return rc;
    }
    lean_object *pixels = lean_ctor_get(frame, 1);
    size_t n = lean_sarray_size(pixels);
    /* "\x01<stride> <x> <y> <w> <h>\n<hits>": only that rectangle changed since the last frame. */
    unsigned W, rx, ry, rw, rh;
    if (hit_str[0] == '\x01' && sscanf(hit_str + 1, "%u %u %u %u %u", &W, &rx, &ry, &rw, &rh) == 5) {
        const char *rest = strchr(hit_str, '\n');
        int ok = argb && W > 0 && rx + rw <= W && (size_t)rw * rh * 4 == n &&
                 (size_t)(ry + rh) * W * 4 <= capacity;
        for (size_t y = 0; ok && y < rh; y++) {
            uint8_t *restrict d = argb + ((ry + y) * (size_t)W + rx) * 4;
            const uint8_t *restrict s = lean_sarray_cptr(pixels) + y * (size_t)rw * 4;
            for (size_t i = 0; i < (size_t)rw * 4; i += 4) {
                d[i] = s[i+2]; d[i+1] = s[i+1]; d[i+2] = s[i]; d[i+3] = s[i+3];
            }
        }
        if (ok && hits) hits(view, rest ? rest + 1 : "");
        lean_dec(res);
        return ok;
    }
    if (n == capacity && argb) {
        const uint8_t *rgba = lean_sarray_cptr(pixels);
        for (size_t i = 0; i < n; i += 4) {
            argb[i] = rgba[i+2]; argb[i+1] = rgba[i+1];
            argb[i+2] = rgba[i]; argb[i+3] = rgba[i+3];
        }
        if (hits) hits(view, hit_str);
    }
    lean_dec(res);
    return n == capacity && argb != NULL;
}

lean_obj_res lean_ui_sidebar_host(b_lean_obj_arg path, b_lean_obj_arg renderer) {
    void *module = dlopen(lean_string_cstr(path), RTLD_NOW | RTLD_LOCAL);
    OrbSidebarHost run = module ? (OrbSidebarHost)dlsym(module, "orb_sidebar_host") : NULL;
    if (!run) return lean_io_result_mk_error(lean_mk_io_user_error(lean_mk_string(dlerror())));
    /* GTK installs process-global types and callbacks. Keep the module loaded. */
    return lean_io_result_mk_ok(lean_box_uint32((uint32_t)run(paint, renderer)));
}
