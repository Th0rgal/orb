/*
 * orb_bin_sqlite.c — Shared parameterized libsqlite3 leaf shim (<= 160 LOC).
 * Uses dlopen("libsqlite3.so.0" / ".dylib") so Lake's bundled sysroot linker needs no host -L flags.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <lean/lean.h>
#include <limits.h>
#include <pthread.h>
#include <stddef.h>
#include <stdint.h>

#define SQLITE_OK 0
#define SQLITE_ROW 100
#define SQLITE_DONE 101
#define SQLITE_OPEN_FLAGS (0x00000002 | 0x00000004 | 0x00010000)
#define SQLITE_TRANSIENT ((void (*)(void *)) - 1)

typedef struct sqlite3 sqlite3;
typedef struct sqlite3_stmt sqlite3_stmt;

static struct {
    int loaded;
    int (*open_v2)(const char *, sqlite3 **, int, const char *);
    int (*close_v2)(sqlite3 *);
    int (*busy_timeout)(sqlite3 *, int);
    int (*exec)(sqlite3 *, const char *, int (*)(void *, int, char **, char **), void *, char **);
    void (*free_mem)(void *);
    const char *(*errmsg)(sqlite3 *);
    int (*prepare_v2)(sqlite3 *, const char *, int, sqlite3_stmt **, const char **);
    int (*bind_text)(sqlite3_stmt *, int, const char *, int, void (*)(void *));
    int (*column_count)(sqlite3_stmt *);
    const char *(*column_name)(sqlite3_stmt *, int);
    const unsigned char *(*column_text)(sqlite3_stmt *, int);
    int (*step)(sqlite3_stmt *);
    int (*finalize)(sqlite3_stmt *);
} sq;
static pthread_once_t sq_once = PTHREAD_ONCE_INIT;

static void init_sqlite_once(void) {
    const char *libs[] = {"libsqlite3.so.0", "libsqlite3.so", "/run/current-system/sw/lib/libsqlite3.so.0",
                          "libsqlite3.dylib", "/usr/lib/libsqlite3.dylib"};
    void *h = NULL;
    for (int i = 0; i < 5 && !h; i++) h = dlopen(libs[i], RTLD_LAZY | RTLD_LOCAL);
    if (!h) { sq.loaded = -1; return; }
    #define LOAD_SYM(fld, sym) *(void **)(&sq.fld) = dlsym(h, sym)
    LOAD_SYM(open_v2, "sqlite3_open_v2"); LOAD_SYM(close_v2, "sqlite3_close_v2");
    LOAD_SYM(busy_timeout, "sqlite3_busy_timeout"); LOAD_SYM(exec, "sqlite3_exec");
    LOAD_SYM(free_mem, "sqlite3_free"); LOAD_SYM(errmsg, "sqlite3_errmsg");
    LOAD_SYM(prepare_v2, "sqlite3_prepare_v2"); LOAD_SYM(bind_text, "sqlite3_bind_text");
    LOAD_SYM(column_count, "sqlite3_column_count"); LOAD_SYM(column_name, "sqlite3_column_name");
    LOAD_SYM(column_text, "sqlite3_column_text"); LOAD_SYM(step, "sqlite3_step");
    LOAD_SYM(finalize, "sqlite3_finalize");
    #undef LOAD_SYM
    sq.loaded = (sq.open_v2 && sq.close_v2 && sq.exec && sq.prepare_v2 && sq.bind_text &&
                 sq.column_count && sq.column_name && sq.column_text && sq.step && sq.finalize) ? 1 : -1;
}

static int ensure_sqlite(void) {
    pthread_once(&sq_once, init_sqlite_once);
    return sq.loaded > 0;
}

static lean_object *mk_sql_err(sqlite3 *db, const char *fallback) {
    const char *msg = (db != NULL && sq.errmsg != NULL) ? sq.errmsg(db) : fallback;
    lean_object *ctor = lean_alloc_ctor(0, 1, 0);
    lean_ctor_set(ctor, 0, lean_mk_string(msg != NULL ? msg : "sqlite_error"));
    return lean_io_result_mk_ok(ctor);
}

LEAN_EXPORT lean_obj_res orb_sqlite_open(b_lean_obj_arg path_obj, lean_obj_arg w) {
    (void)w;
    if (!ensure_sqlite()) return lean_io_result_mk_ok(lean_box_uint64(0));
    sqlite3 *db = NULL;
    if (sq.open_v2(lean_string_cstr(path_obj), &db, SQLITE_OPEN_FLAGS, NULL) != SQLITE_OK) {
        if (db != NULL) sq.close_v2(db);
        return lean_io_result_mk_ok(lean_box_uint64(0));
    }
    if (sq.busy_timeout) sq.busy_timeout(db, 5000);
    (void)sq.exec(db, "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA foreign_keys=ON;", NULL, NULL, NULL);
    return lean_io_result_mk_ok(lean_box_uint64((uint64_t)(uintptr_t)db));
}

LEAN_EXPORT lean_obj_res orb_sqlite_close(uint64_t handle, lean_obj_arg w) {
    (void)w;
    sqlite3 *db = (sqlite3 *)(uintptr_t)handle;
    if (db != NULL && ensure_sqlite()) sq.close_v2(db);
    return lean_io_result_mk_ok(lean_box(0));
}

LEAN_EXPORT lean_obj_res orb_sqlite_exec(uint64_t handle, b_lean_obj_arg sql_obj, lean_obj_arg w) {
    (void)w;
    sqlite3 *db = (sqlite3 *)(uintptr_t)handle;
    if (db == NULL || !ensure_sqlite()) return mk_sql_err(NULL, "null_sqlite_handle");
    char *errmsg = NULL;
    if (sq.exec(db, lean_string_cstr(sql_obj), NULL, NULL, &errmsg) != SQLITE_OK) {
        lean_object *ctor = lean_alloc_ctor(0, 1, 0);
        lean_ctor_set(ctor, 0, lean_mk_string(errmsg != NULL ? errmsg : "sqlite_exec_failed"));
        if (errmsg != NULL && sq.free_mem) sq.free_mem(errmsg);
        return lean_io_result_mk_ok(ctor);
    }
    lean_object *ok = lean_alloc_ctor(1, 1, 0);
    lean_ctor_set(ok, 0, lean_box(0));
    return lean_io_result_mk_ok(ok);
}

LEAN_EXPORT lean_obj_res orb_sqlite_query_rows(uint64_t handle, b_lean_obj_arg sql_obj, b_lean_obj_arg params_arr, lean_obj_arg w) {
    (void)w;
    sqlite3 *db = (sqlite3 *)(uintptr_t)handle;
    if (db == NULL || !ensure_sqlite()) return mk_sql_err(NULL, "null_sqlite_handle");
    sqlite3_stmt *stmt = NULL;
    if (sq.prepare_v2(db, lean_string_cstr(sql_obj), -1, &stmt, NULL) != SQLITE_OK) return mk_sql_err(db, "sqlite_prepare_failed");
    if (stmt == NULL) {
        lean_object *ok = lean_alloc_ctor(1, 1, 0);
        lean_ctor_set(ok, 0, lean_mk_empty_array());
        return lean_io_result_mk_ok(ok);
    }
    for (size_t i = 0, n = lean_array_size(params_arr); i < n; i++) {
        b_lean_obj_arg p = lean_array_get_core(params_arr, i);
        size_t slen = lean_string_size(p) > 0 ? lean_string_size(p) - 1 : 0;
        if (slen > (size_t)INT_MAX || sq.bind_text(stmt, (int)(i + 1), lean_string_cstr(p), (int)slen, SQLITE_TRANSIENT) != SQLITE_OK) {
            sq.finalize(stmt); return mk_sql_err(db, "sqlite_bind_failed");
        }
    }
    int ncols = sq.column_count(stmt), rc;
    lean_object *rows = lean_mk_empty_array();
    if (ncols > 0) {
        lean_object *hdr = lean_mk_empty_array_with_capacity(lean_usize_to_nat((size_t)ncols));
        for (int c = 0; c < ncols; c++) { const char *nm = sq.column_name(stmt, c); hdr = lean_array_push(hdr, lean_mk_string(nm ? nm : "")); }
        rows = lean_array_push(rows, hdr);
    }
    while ((rc = sq.step(stmt)) == SQLITE_ROW) {
        lean_object *row = lean_mk_empty_array_with_capacity(lean_usize_to_nat((size_t)ncols));
        for (int c = 0; c < ncols; c++) { const unsigned char *tx = sq.column_text(stmt, c); row = lean_array_push(row, lean_mk_string(tx ? (const char *)tx : "")); }
        rows = lean_array_push(rows, row);
    }
    sq.finalize(stmt);
    if (rc != SQLITE_DONE) { lean_dec(rows); return mk_sql_err(db, "sqlite_step_failed"); }
    lean_object *ok = lean_alloc_ctor(1, 1, 0);
    lean_ctor_set(ok, 0, rows);
    return lean_io_result_mk_ok(ok);
}
