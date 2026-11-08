#ifndef __APPLE__
#define _GNU_SOURCE
#endif
#include <lean/lean.h>
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/time.h>
#ifdef __APPLE__
#include <util.h>
#else
#include <pty.h>
#endif
#include <openssl/err.h>
#include <openssl/evp.h>
#include <openssl/rand.h>
#include <openssl/ssl.h>
#include <openssl/x509v3.h>
#ifndef SOCK_CLOEXEC
#define SOCK_CLOEXEC 0
#endif
typedef struct { pthread_mutex_t mu; SSL_CTX *ctx; SSL *ssl; int fd; } onl_tls_t;
static void onl_tls_cleanup_locked(onl_tls_t *s) {
    if (s->ssl) { SSL_shutdown(s->ssl); SSL_free(s->ssl); s->ssl = NULL; }
    if (s->ctx) { SSL_CTX_free(s->ctx); s->ctx = NULL; } if (s->fd >= 0) { close(s->fd); s->fd = -1; }
}
static void onl_tls_fin(void *p) {
    onl_tls_t *s = (onl_tls_t *)p; if (!s) return;
    pthread_mutex_lock(&s->mu); onl_tls_cleanup_locked(s); pthread_mutex_unlock(&s->mu); pthread_mutex_destroy(&s->mu); free(s);
}
static void onl_tls_for(void *p, b_lean_obj_arg f) { (void)p; (void)f; }
static pthread_once_t g_onl_tls_once = PTHREAD_ONCE_INIT; static lean_external_class *g_onl_tls_cls = NULL;
static void onl_tls_reg(void) { g_onl_tls_cls = lean_register_external_class(onl_tls_fin, onl_tls_for); }
static inline const char *onl_cstr(b_lean_obj_arg s) { const char *p = lean_string_cstr(s); return strlen(p) == lean_string_size(s) - 1 ? p : NULL; }
static inline lean_obj_res onl_pack(int64_t rc) { return lean_io_result_mk_ok(lean_box_uint64(rc < 0 ? ((1ULL << 63) | ((uint64_t)(uint32_t)errno << 32)) : ((uint64_t)rc & 0x7FFFFFFFFFFFFFFFULL))); }
static int onl_try_sock(struct addrinfo *ai, int pms, struct timeval *tv, int socktype) {
    int fd = socket(ai->ai_family, ai->ai_socktype | SOCK_CLOEXEC, ai->ai_protocol), fl = fd >= 0 ? fcntl(fd, F_GETFL, 0) : -1, one = 1;
    int rc = (fd >= 0 && fl >= 0 && fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 && fcntl(fd, F_SETFL, fl | O_NONBLOCK) == 0) ? connect(fd, ai->ai_addr, ai->ai_addrlen) : -1;
    if (rc < 0 && errno == EINPROGRESS && poll(&(struct pollfd){ .fd = fd, .events = POLLOUT }, 1, pms) == 1) {
        int se = -1; socklen_t sl = sizeof(se); rc = (getsockopt(fd, SOL_SOCKET, SO_ERROR, &se, &sl) == 0 && se == 0) ? 0 : -1;
    }
    if (rc == 0 && fcntl(fd, F_SETFL, fl) == 0 && setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, tv, sizeof(*tv)) == 0 && setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, tv, sizeof(*tv)) == 0) {
        if (socktype == SOCK_STREAM) { (void)setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one)); (void)setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &one, sizeof(one)); }
        return fd;
    }
    return fd >= 0 ? (close(fd), -1) : -1;
}
static int onl_connect_sock(const char *h, uint16_t port, int socktype, uint32_t timeout_ms) {
    if (!h || !*h) return -1;
    char pstr[8]; snprintf(pstr, sizeof(pstr), "%u", (unsigned)port); struct addrinfo hints = { .ai_family = AF_UNSPEC, .ai_socktype = socktype }, *res = NULL;
    if (getaddrinfo(h, pstr, &hints, &res) != 0 || !res) return -1;
    int fd = -1; uint32_t ms = timeout_ms ? timeout_ms : 30000U; int pms = ms > 0x7FFFFFFFU ? 0x7FFFFFFF : (int)ms;
    struct timeval tv = { .tv_sec = (time_t)(ms / 1000U), .tv_usec = (suseconds_t)((ms % 1000U) * 1000U) };
    for (int pass = 0; pass < 2 && fd < 0; ++pass)
        for (struct addrinfo *ai = res; ai && fd < 0; ai = ai->ai_next)
            if ((ai->ai_family == AF_INET) == (pass == 0)) fd = onl_try_sock(ai, ai->ai_next && pms > 2000 ? 2000 : pms, &tv, socktype);
    return freeaddrinfo(res), fd;
}
LEAN_EXPORT lean_obj_res orb_net_leaf_rand_bytes(size_t n) {
    if (n > 0x40000000ULL) return lean_io_result_mk_ok(lean_alloc_sarray(1, 0, 0));
    lean_object *out = lean_alloc_sarray(1, 0, n);
    if (n > 0 && RAND_bytes(lean_sarray_cptr(out), (int)n) != 1)
        return lean_dec_ref(out), lean_io_result_mk_ok(lean_alloc_sarray(1, 0, 0));
    return lean_sarray_set_size(out, n), lean_io_result_mk_ok(out);
}
LEAN_EXPORT lean_obj_res orb_net_leaf_aead(uint8_t alg, uint8_t enc, b_lean_obj_arg key, b_lean_obj_arg nonce, b_lean_obj_arg aad, b_lean_obj_arg buf) {
    const EVP_CIPHER *cip = alg == 0 ? EVP_aes_256_gcm() : (alg == 1 ? EVP_chacha20_poly1305() : (alg == 2 ? EVP_aes_128_gcm() : NULL));
    size_t want_k = (alg == 2) ? 16 : 32, klen = lean_sarray_size(key), nlen = lean_sarray_size(nonce), alen = lean_sarray_size(aad), blen = lean_sarray_size(buf);
    if (!cip || klen != want_k || nlen != 12 || alen > 0x40000000ULL || blen > 0x40000000ULL || (!enc && blen < 16))
        return lean_io_result_mk_ok(lean_alloc_sarray(1, 0, 0));
    size_t pay_len = enc ? blen : (blen - 16), out_cap = enc ? (blen + 16) : pay_len;
    lean_object *out = lean_alloc_sarray(1, 0, out_cap + 1);
    EVP_CIPHER_CTX *ctx = EVP_CIPHER_CTX_new(); int aad_out = 0, pay_out = 0, fin_out = 0, ok = ctx != NULL;
    if (ok) ok = EVP_CipherInit_ex(ctx, cip, NULL, NULL, NULL, enc ? 1 : 0) == 1 && EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_AEAD_SET_IVLEN, 12, NULL) == 1 &&
                 EVP_CipherInit_ex(ctx, NULL, NULL, lean_sarray_cptr(key), lean_sarray_cptr(nonce), enc ? 1 : 0) == 1;
    if (ok && !enc) ok = EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_AEAD_SET_TAG, 16, (void *)(lean_sarray_cptr(buf) + pay_len)) == 1;
    if (ok && alen > 0) ok = EVP_CipherUpdate(ctx, NULL, &aad_out, lean_sarray_cptr(aad), (int)alen) == 1;
    if (ok && pay_len > 0) ok = EVP_CipherUpdate(ctx, lean_sarray_cptr(out), &pay_out, lean_sarray_cptr(buf), (int)pay_len) == 1 && (size_t)pay_out <= out_cap;
    if (ok) ok = EVP_CipherFinal_ex(ctx, lean_sarray_cptr(out) + pay_out, &fin_out) == 1 && fin_out == 0;
    if (ok && enc) ok = EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_AEAD_GET_TAG, 16, lean_sarray_cptr(out) + pay_len) == 1;
    EVP_CIPHER_CTX_free(ctx);
    if (!ok) return lean_dec_ref(out), lean_io_result_mk_ok(lean_alloc_sarray(1, 0, 0));
    if (!enc && pay_len == 0) { lean_sarray_cptr(out)[0] = 1; lean_sarray_set_size(out, 1); } else lean_sarray_set_size(out, out_cap);
    return lean_io_result_mk_ok(out);
}
LEAN_EXPORT lean_obj_res orb_net_leaf_quic_hp_mask(uint8_t hp_alg, b_lean_obj_arg hp_key, b_lean_obj_arg sample16) {
    size_t klen = lean_sarray_size(hp_key), slen = lean_sarray_size(sample16);
    if (slen != 16 || (hp_alg == 0 && klen != 16) || (hp_alg == 1 && klen != 32) || hp_alg > 1)
        return lean_io_result_mk_ok(lean_alloc_sarray(1, 0, 0));
    uint8_t block[16] = {0}, zero5[5] = {0}; EVP_CIPHER_CTX *ctx = EVP_CIPHER_CTX_new(); int len1 = 0, ok = ctx != NULL;
    if (ok && hp_alg == 0) ok = EVP_EncryptInit_ex(ctx, EVP_aes_128_ecb(), NULL, lean_sarray_cptr(hp_key), NULL) == 1 &&
                                EVP_CIPHER_CTX_set_padding(ctx, 0) == 1 && EVP_EncryptUpdate(ctx, block, &len1, lean_sarray_cptr(sample16), 16) == 1;
    else if (ok) ok = EVP_EncryptInit_ex(ctx, EVP_chacha20(), NULL, lean_sarray_cptr(hp_key), lean_sarray_cptr(sample16)) == 1 &&
                      EVP_EncryptUpdate(ctx, block, &len1, zero5, 5) == 1;
    EVP_CIPHER_CTX_free(ctx);
    if (!ok) return lean_io_result_mk_ok(lean_alloc_sarray(1, 0, 0));
    lean_object *out = lean_alloc_sarray(1, 5, 5);
    return memcpy(lean_sarray_cptr(out), block, 5), lean_io_result_mk_ok(out);
}
LEAN_EXPORT lean_obj_res orb_net_leaf_ed_x25519(uint8_t op, b_lean_obj_arg k1, b_lean_obj_arg k2, b_lean_obj_arg msg) {
    size_t n1 = lean_sarray_size(k1), n2 = lean_sarray_size(k2), nm = lean_sarray_size(msg), olen = 0;
    EVP_PKEY *pk1 = NULL, *pk2 = NULL; EVP_MD_CTX *mctx = NULL; EVP_PKEY_CTX *pctx = NULL;
    lean_object *out = lean_alloc_sarray(1, 0, op == 1 ? 64 : (op == 2 ? 1 : 32)); int ok = 0;
    if (op == 0 && n1 == 32 && n2 == 0 && nm == 0) {
        pk1 = EVP_PKEY_new_raw_private_key(EVP_PKEY_ED25519, NULL, lean_sarray_cptr(k1), 32); olen = 32;
        ok = pk1 && EVP_PKEY_get_raw_public_key(pk1, lean_sarray_cptr(out), &olen) == 1 && olen == 32;
    } else if (op == 1 && n1 == 32 && n2 == 0) {
        pk1 = EVP_PKEY_new_raw_private_key(EVP_PKEY_ED25519, NULL, lean_sarray_cptr(k1), 32); mctx = EVP_MD_CTX_new(); olen = 64;
        ok = pk1 && mctx && EVP_DigestSignInit(mctx, NULL, NULL, NULL, pk1) == 1 && EVP_DigestSign(mctx, lean_sarray_cptr(out), &olen, lean_sarray_cptr(msg), nm) == 1 && olen == 64;
    } else if (op == 2 && n1 == 32 && n2 == 64) {
        pk1 = EVP_PKEY_new_raw_public_key(EVP_PKEY_ED25519, NULL, lean_sarray_cptr(k1), 32); mctx = EVP_MD_CTX_new();
        ok = pk1 && mctx && EVP_DigestVerifyInit(mctx, NULL, NULL, NULL, pk1) == 1 && EVP_DigestVerify(mctx, lean_sarray_cptr(k2), 64, lean_sarray_cptr(msg), nm) == 1;
        if (ok) { lean_sarray_cptr(out)[0] = 1; olen = 1; }
    } else if (op == 3 && n1 == 32 && n2 == 0 && nm == 0) {
        pk1 = EVP_PKEY_new_raw_private_key(EVP_PKEY_X25519, NULL, lean_sarray_cptr(k1), 32); olen = 32;
        ok = pk1 && EVP_PKEY_get_raw_public_key(pk1, lean_sarray_cptr(out), &olen) == 1 && olen == 32;
    } else if (op == 4 && n1 == 32 && n2 == 32 && nm == 0) {
        pk1 = EVP_PKEY_new_raw_private_key(EVP_PKEY_X25519, NULL, lean_sarray_cptr(k1), 32);
        pk2 = EVP_PKEY_new_raw_public_key(EVP_PKEY_X25519, NULL, lean_sarray_cptr(k2), 32);
        pctx = pk1 ? EVP_PKEY_CTX_new(pk1, NULL) : NULL; olen = 32;
        ok = pk2 && pctx && EVP_PKEY_derive_init(pctx) == 1 && EVP_PKEY_derive_set_peer(pctx, pk2) == 1 && EVP_PKEY_derive(pctx, lean_sarray_cptr(out), &olen) == 1 && olen == 32;
    }
    EVP_PKEY_CTX_free(pctx); EVP_MD_CTX_free(mctx); EVP_PKEY_free(pk2); EVP_PKEY_free(pk1);
    if (!ok) return lean_dec_ref(out), lean_io_result_mk_ok(lean_alloc_sarray(1, 0, 0));
    return lean_sarray_set_size(out, olen), lean_io_result_mk_ok(out);
}
LEAN_EXPORT lean_obj_res orb_net_leaf_openpty(uint16_t rows, uint16_t cols) {
    int mfd = -1, sfd = -1; struct winsize ws = { .ws_row = rows ? rows : 24, .ws_col = cols ? cols : 80 };
    if (openpty(&mfd, &sfd, NULL, NULL, &ws) < 0) return onl_pack(-1);
    int mfl = fcntl(mfd, F_GETFL, 0);
    if (mfl < 0 || fcntl(mfd, F_SETFL, mfl | O_NONBLOCK) < 0 || fcntl(mfd, F_SETFD, FD_CLOEXEC) < 0 || fcntl(sfd, F_SETFD, FD_CLOEXEC) < 0) {
        int saved = errno ? errno : EIO; close(sfd); close(mfd); errno = saved; return onl_pack(-1);
    }
    return onl_pack(((int64_t)(uint32_t)sfd << 32) | (uint32_t)mfd);
}
LEAN_EXPORT lean_obj_res orb_net_leaf_pty_resize(uint32_t mfd, uint16_t rows, uint16_t cols) {
    struct winsize ws = { .ws_row = rows, .ws_col = cols }; return onl_pack(ioctl((int)mfd, TIOCSWINSZ, &ws));
}
LEAN_EXPORT lean_obj_res orb_net_leaf_touch_excl_0600(b_lean_obj_arg path) {
    const char *p = onl_cstr(path); int fd = p ? open(p, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0600) : (errno = EINVAL, -1);
    return fd < 0 ? onl_pack(-1) : (close(fd), onl_pack(0));
}
static int onl_ssl_write_all(SSL *ssl, b_lean_obj_arg buf) {
    if (!ssl) return 0;
    for (size_t sent = 0, blen = lean_sarray_size(buf); sent < blen; ) {
        int w = SSL_write(ssl, lean_sarray_cptr(buf) + sent, (int)((blen - sent) > 0x40000000ULL ? 0x40000000ULL : (blen - sent)));
        if (w <= 0) return 0; else sent += (size_t)w;
    }
    return 1;
}
LEAN_EXPORT lean_obj_res orb_net_leaf_tls_open(b_lean_obj_arg host, uint16_t port, b_lean_obj_arg req, uint8_t verify_peer, uint8_t alpn_mode, uint32_t timeout_ms) {
    pthread_once(&g_onl_tls_once, onl_tls_reg);
    const char *h = onl_cstr(host); if (!h) return lean_io_result_mk_ok(lean_box(0));
    onl_tls_t *s = (onl_tls_t *)calloc(1, sizeof(onl_tls_t));
    if (!s || pthread_mutex_init(&s->mu, NULL) != 0) return free(s), lean_io_result_mk_ok(lean_box(0));
    int ok = (s->fd = onl_connect_sock(h, port, SOCK_STREAM, timeout_ms)) >= 0 && (s->ctx = SSL_CTX_new(TLS_client_method())) != NULL;
    if (ok && verify_peer) { SSL_CTX_set_verify(s->ctx, SSL_VERIFY_PEER, NULL); ok = SSL_CTX_set_default_verify_paths(s->ctx) == 1; }
    static const unsigned char h2_alpn[] = { 2, 'h', '2' }, h1_alpn[] = { 8, 'h', 't', 't', 'p', '/', '1', '.', '1' };
    if (ok) ok = SSL_CTX_set_alpn_protos(s->ctx, alpn_mode == 1 ? h2_alpn : h1_alpn, alpn_mode == 1 ? 3 : 9) == 0;
    if (ok && (s->ssl = SSL_new(s->ctx)) != NULL) {
        unsigned char ipb[16]; int is_ip = inet_pton(AF_INET, h, ipb) == 1 || inet_pton(AF_INET6, h, ipb) == 1;
        ok = (is_ip ? (!verify_peer || X509_VERIFY_PARAM_set1_ip_asc(SSL_get0_param(s->ssl), h) == 1)
                    : (SSL_set_tlsext_host_name(s->ssl, h) == 1 && (!verify_peer || SSL_set1_host(s->ssl, h) == 1))) &&
             SSL_set_fd(s->ssl, s->fd) == 1 && SSL_connect(s->ssl) == 1;
        if (ok && alpn_mode == 1) {
            const unsigned char *sel = NULL; unsigned int slen = 0; SSL_get0_alpn_selected(s->ssl, &sel, &slen);
            ok = (slen == 2 && sel && sel[0] == 'h' && sel[1] == '2');
            if (!ok) return onl_tls_fin(s), lean_io_result_mk_ok(lean_box(1));
        }
    } else ok = 0;
    if (ok) ok = onl_ssl_write_all(s->ssl, req);
    if (!ok) return onl_tls_fin(s), lean_io_result_mk_ok(lean_box(0));
    lean_object *some = lean_alloc_ctor(2, 1, 0); return lean_ctor_set(some, 0, lean_alloc_external(g_onl_tls_cls, s)), lean_io_result_mk_ok(some);
}
LEAN_EXPORT lean_obj_res orb_net_leaf_tls_write(b_lean_obj_arg h_obj, b_lean_obj_arg buf) {
    onl_tls_t *s = (onl_tls_t *)lean_get_external_data(h_obj); if (!s) return lean_io_result_mk_ok(lean_box(0));
    pthread_mutex_lock(&s->mu); int ok = onl_ssl_write_all(s->ssl, buf); pthread_mutex_unlock(&s->mu);
    return lean_io_result_mk_ok(lean_box(ok ? 1 : 0));
}
LEAN_EXPORT lean_obj_res orb_net_leaf_tls_read(b_lean_obj_arg h_obj, size_t max_chunk, uint32_t rcv_timeout_ms) {
    onl_tls_t *s = (onl_tls_t *)lean_get_external_data(h_obj); size_t cap = max_chunk == 0 ? 1 : (max_chunk > 65536 ? 65536 : max_chunk);
    if (!s) return lean_io_result_mk_ok(lean_alloc_sarray(1, 0, 0));
    pthread_mutex_lock(&s->mu);
    if (!s->ssl) { pthread_mutex_unlock(&s->mu); return lean_io_result_mk_ok(lean_alloc_sarray(1, 0, 0)); }
    if (rcv_timeout_ms != 0 && s->fd >= 0) {
        uint32_t ms = rcv_timeout_ms == 0xFFFFFFFFU ? 0U : rcv_timeout_ms;
        struct timeval tv = { .tv_sec = (time_t)(ms / 1000U), .tv_usec = (suseconds_t)((ms % 1000U) * 1000U) };
        (void)setsockopt(s->fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    }
    lean_object *out = lean_alloc_sarray(1, 0, cap + 1); ERR_clear_error();
    int r = SSL_read(s->ssl, lean_sarray_cptr(out) + 1, (int)cap), se = errno, err = r > 0 ? 0 : SSL_get_error(s->ssl, r);
    unsigned long e = r > 0 ? 0 : ERR_peek_error(); pthread_mutex_unlock(&s->mu);
    if (r > 0) return lean_sarray_cptr(out)[0] = 0, lean_sarray_set_size(out, 1 + (size_t)r), lean_io_result_mk_ok(out);
    uint8_t st = err == SSL_ERROR_ZERO_RETURN ? 1 : ((err == SSL_ERROR_WANT_READ || (err == SSL_ERROR_SYSCALL && (se == EAGAIN || se == EWOULDBLOCK || se == EINTR))) ? 5 :
        (((err == SSL_ERROR_SYSCALL && e == 0 && r == 0) || (err == SSL_ERROR_SSL && ERR_GET_LIB(e) == ERR_LIB_SSL && ERR_GET_REASON(e) == SSL_R_UNEXPECTED_EOF_WHILE_READING)) ? 4 : 0));
    if (!st) return lean_dec_ref(out), lean_io_result_mk_ok(lean_alloc_sarray(1, 0, 0));
    return lean_sarray_cptr(out)[0] = st, lean_sarray_set_size(out, 1), lean_io_result_mk_ok(out);
}
LEAN_EXPORT lean_obj_res orb_net_leaf_tls_close(b_lean_obj_arg h_obj) {
    onl_tls_t *s = (onl_tls_t *)lean_get_external_data(h_obj); if (s) { pthread_mutex_lock(&s->mu); onl_tls_cleanup_locked(s); pthread_mutex_unlock(&s->mu); }
    return lean_io_result_mk_ok(lean_box(0));
}
LEAN_EXPORT lean_obj_res orb_net_leaf_udp_roundtrip(b_lean_obj_arg host, uint16_t port, b_lean_obj_arg dgram, size_t max_resp, uint32_t timeout_ms) {
    const char *h = onl_cstr(host); int fd = (!h || max_resp == 0 || max_resp > 65536) ? -1 : onl_connect_sock(h, port, SOCK_DGRAM, timeout_ms ? timeout_ms : 5000U);
    if (fd < 0) return lean_io_result_mk_ok(lean_alloc_sarray(1, 0, 0));
    lean_object *out = lean_alloc_sarray(1, 0, max_resp);
    ssize_t rd = send(fd, lean_sarray_cptr(dgram), lean_sarray_size(dgram), 0) == (ssize_t)lean_sarray_size(dgram) ? recv(fd, lean_sarray_cptr(out), max_resp, 0) : -1;
    close(fd); if (rd <= 0) return lean_dec_ref(out), lean_io_result_mk_ok(lean_alloc_sarray(1, 0, 0));
    return lean_sarray_set_size(out, (size_t)rd), lean_io_result_mk_ok(out);
}
