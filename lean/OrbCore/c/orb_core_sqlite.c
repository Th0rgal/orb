/*
 * orb_core_sqlite.c — Minimal Core-only POSIX/OpenSSL/systemd leaf shim (<= 80 LOC).
 * Shared SQLite FFI lives in `lean/OrbBin/c/orb_bin_sqlite.c`.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <lean/lean.h>
#include <pthread.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

LEAN_EXPORT lean_obj_res orb_core_epoch_sec(lean_obj_arg w) {
    (void)w;
    time_t now = time(NULL);
    return lean_io_result_mk_ok(lean_box_uint64(now > 0 ? (uint64_t)now : 0));
}

static struct {
    int loaded;
    int (*pbkdf2)(const char *, int, const unsigned char *, int, int, const void *, int, unsigned char *);
    const void *(*sha256)(void);
} cr;
static pthread_once_t cr_once = PTHREAD_ONCE_INIT;

static void init_crypto_once(void) {
    const char *libs[] = {"libcrypto.so.3", "libcrypto.so", "/opt/homebrew/opt/openssl@3/lib/libcrypto.3.dylib",
                          "/usr/local/opt/openssl@3/lib/libcrypto.3.dylib", "libcrypto.3.dylib"};
    void *h = NULL;
    for (int i = 0; i < 5 && !h; i++) h = dlopen(libs[i], RTLD_LAZY | RTLD_LOCAL);
    if (!h) { cr.loaded = -1; return; }
    *(void **)(&cr.pbkdf2) = dlsym(h, "PKCS5_PBKDF2_HMAC");
    *(void **)(&cr.sha256) = dlsym(h, "EVP_sha256");
    cr.loaded = (cr.pbkdf2 && cr.sha256) ? 1 : -1;
}

LEAN_EXPORT lean_obj_res orb_pbkdf2_sha256(b_lean_obj_arg pass_obj, b_lean_obj_arg salt_ba, uint32_t iters, lean_obj_arg w) {
    (void)w;
    pthread_once(&cr_once, init_crypto_once);
    if (cr.loaded <= 0 || iters == 0) return lean_io_result_mk_ok(lean_mk_string(""));
    size_t plen = lean_string_size(pass_obj) > 0 ? lean_string_size(pass_obj) - 1 : 0;
    size_t slen = lean_sarray_size(salt_ba);
    unsigned char dk[32];
    if (cr.pbkdf2(lean_string_cstr(pass_obj), (int)plen, (const unsigned char *)lean_sarray_cptr(salt_ba),
                  (int)slen, (int)iters, cr.sha256(), 32, dk) != 1)
        return lean_io_result_mk_ok(lean_mk_string(""));
    static const char hx[] = "0123456789abcdef";
    char out[65];
    for (int i = 0; i < 32; i++) { out[i * 2] = hx[dk[i] >> 4]; out[i * 2 + 1] = hx[dk[i] & 0x0f]; }
    out[64] = '\0';
    return lean_io_result_mk_ok(lean_mk_string(out));
}

LEAN_EXPORT lean_obj_res orb_sd_notify(b_lean_obj_arg sock_obj, b_lean_obj_arg msg_obj, lean_obj_arg w) {
    (void)w;
    const char *sp = lean_string_cstr(sock_obj), *msg = lean_string_cstr(msg_obj);
    size_t slen = strlen(sp), mlen = strlen(msg);
    struct sockaddr_un addr;
    if (slen == 0 || mlen == 0 || (*sp != '/' && *sp != '@') || slen >= sizeof(addr.sun_path))
        return lean_io_result_mk_ok(lean_box_uint32(0u));
    int fd = socket(AF_UNIX, SOCK_DGRAM, 0);
    if (fd < 0) return lean_io_result_mk_ok(lean_box_uint32(0u));
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    memcpy(addr.sun_path, sp, slen);
    socklen_t alen = (socklen_t)(offsetof(struct sockaddr_un, sun_path) + slen + 1);
    if (addr.sun_path[0] == '@') { addr.sun_path[0] = '\0'; alen--; }
    ssize_t rc = sendto(fd, msg, mlen, 0, (const struct sockaddr *)&addr, alen);
    close(fd);
    return lean_io_result_mk_ok(lean_box_uint32(rc == (ssize_t)mlen ? 1u : 0u));
}
