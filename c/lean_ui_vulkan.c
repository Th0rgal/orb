#include "lean_ui.h"
#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>

static lean_obj_res io_err(const char *msg) {
  return lean_io_result_mk_error(lean_mk_io_user_error(lean_mk_string(msg)));
}

typedef uint64_t (*fn6_t)(uint64_t, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t);

lean_obj_res lean_ui_dl_sym(b_lean_obj_arg lib, b_lean_obj_arg sym, lean_obj_arg w) {
  (void)w;
  const char *lib_str = lean_string_cstr(lib);
  const char *sym_str = lean_string_cstr(sym);
  void *h = dlopen(lib_str[0] ? lib_str : NULL, RTLD_LAZY | RTLD_LOCAL);
  if (!h)
    return lean_io_result_mk_ok(lean_box_usize(0));
  void *fn = dlsym(h, sym_str);
  return lean_io_result_mk_ok(lean_box_usize((size_t)fn));
}

lean_obj_res lean_ui_call(size_t fn, b_lean_obj_arg args, lean_obj_arg w) {
  (void)w;
  if (!fn)
    return io_err("lean_ui_call: null function pointer");
  if (lean_sarray_size(args) < 48)
    return io_err("lean_ui_call: args requires 48 bytes (6 * u64)");
  uint64_t a[6];
  memcpy(a, lean_sarray_cptr(args), 48);
  fn6_t f;
  memcpy(&f, &fn, sizeof(fn));
  uint64_t res = f(a[0], a[1], a[2], a[3], a[4], a[5]);
  return lean_io_result_mk_ok(lean_box_uint64(res));
}

lean_obj_res lean_ui_mem_alloc(size_t size, lean_obj_arg w) {
  (void)w;
  void *p = calloc(1, size ? size : 1);
  if (!p)
    return io_err("lean_ui_mem_alloc: out of memory");
  return lean_io_result_mk_ok(lean_box_usize((size_t)p));
}

lean_obj_res lean_ui_mem_free(size_t ptr, lean_obj_arg w) {
  (void)w;
  if (ptr)
    free((void *)ptr);
  return lean_io_result_mk_ok(lean_box(0));
}

lean_obj_res lean_ui_mem_write(size_t ptr, b_lean_obj_arg bytes, lean_obj_arg w) {
  (void)w;
  size_t sz = lean_sarray_size(bytes);
  if (sz > 0) {
    if (!ptr)
      return io_err("lean_ui_mem_write: null destination pointer");
    memcpy((void *)ptr, lean_sarray_cptr(bytes), sz);
  }
  return lean_io_result_mk_ok(lean_box(0));
}

lean_obj_res lean_ui_mem_read(size_t ptr, size_t size, lean_obj_arg w) {
  (void)w;
  if (size > 0 && !ptr)
    return io_err("lean_ui_mem_read: null source pointer");
  lean_obj_res arr = lean_alloc_sarray(1, size, size);
  if (size > 0)
    memcpy(lean_sarray_cptr(arr), (const void *)ptr, size);
  return lean_io_result_mk_ok(arr);
}
