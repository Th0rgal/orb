#ifndef __APPLE__
#define _GNU_SOURCE
#endif
#include <lean/lean.h>
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <stdio.h>
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

static inline lean_obj_res onl_pack(int64_t rc) {
    return lean_io_result_mk_ok(lean_box_uint64(
        rc < 0 ? ((1ULL << 63) | ((uint64_t)(uint32_t)errno << 32))
               : ((uint64_t)rc & 0x7FFFFFFFFFFFFFFFULL)));
}

LEAN_EXPORT lean_obj_res orb_net_leaf_rand_bytes(size_t n) {
    if (n > 0x40000000ULL) return lean_io_result_mk_ok(lean_alloc_sarray(1, 0, 0));
    lean_object *out = lean_alloc_sarray(1, 0, n);
    if (n > 0 && RAND_bytes(lean_sarray_cptr(out), (int)n) != 1)
        return lean_dec_ref(out), lean_io_result_mk_ok(lean_alloc_sarray(1, 0, 0));
    lean_sarray_set_size(out, n);
    return lean_io_result_mk_ok(out);
}

/* alg: 0 = AES-256-GCM, 1 = ChaCha20-Poly1305; enc: 1 = seal (pt -> ct||tag16), 0 = open (ct||tag16 -> pt) */
LEAN_EXPORT lean_obj_res orb_net_leaf_aead(
    uint8_t alg, uint8_t enc, b_lean_obj_arg key, b_lean_obj_arg nonce,
    b_lean_obj_arg aad, b_lean_obj_arg buf) {
    const EVP_CIPHER *cip = (alg == 0) ? EVP_aes_256_gcm() : ((alg == 1) ? EVP_chacha20_poly1305() : NULL);
    size_t klen = lean_sarray_size(key), nlen = lean_sarray_size(nonce);
    size_t alen = lean_sarray_size(aad), blen = lean_sarray_size(buf);
    if (!cip || klen != 32 || nlen != 12 || alen > 0x40000000ULL || blen > 0x40000000ULL || (!enc && blen < 16))
        return lean_io_result_mk_ok(lean_alloc_sarray(1, 0, 0));
    size_t pay_len = enc ? blen : (blen - 16), out_cap = enc ? (blen + 16) : pay_len;
    lean_object *out = lean_alloc_sarray(1, 0, out_cap + 1);
    EVP_CIPHER_CTX *ctx = EVP_CIPHER_CTX_new();
    int aad_out = 0, pay_out = 0, fin_out = 0, ok = ctx != NULL;
    if (ok) ok = EVP_CipherInit_ex(ctx, cip, NULL, NULL, NULL, enc ? 1 : 0) == 1;
    if (ok) ok = EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_AEAD_SET_IVLEN, 12, NULL) == 1;
    if (ok) ok = EVP_CipherInit_ex(ctx, NULL, NULL, lean_sarray_cptr(key), lean_sarray_cptr(nonce), enc ? 1 : 0) == 1;
    if (ok && !enc)
        ok = EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_AEAD_SET_TAG, 16, (void *)(lean_sarray_cptr(buf) + pay_len)) == 1;
    if (ok && alen > 0)
        ok = EVP_CipherUpdate(ctx, NULL, &aad_out, lean_sarray_cptr(aad), (int)alen) == 1;
    if (ok && pay_len > 0)
        ok = EVP_CipherUpdate(ctx, lean_sarray_cptr(out), &pay_out, lean_sarray_cptr(buf), (int)pay_len) == 1 &&
             (size_t)pay_out <= out_cap;
    if (ok) ok = EVP_CipherFinal_ex(ctx, lean_sarray_cptr(out) + pay_out, &fin_out) == 1 && fin_out == 0;
    if (ok && enc)
        ok = EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_AEAD_GET_TAG, 16, lean_sarray_cptr(out) + pay_len) == 1;
    EVP_CIPHER_CTX_free(ctx);
    if (!ok) return lean_dec_ref(out), lean_io_result_mk_ok(lean_alloc_sarray(1, 0, 0));
    if (!enc && pay_len == 0) { lean_sarray_cptr(out)[0] = 1; lean_sarray_set_size(out, 1); }
    else lean_sarray_set_size(out, out_cap);
    return lean_io_result_mk_ok(out);
}

/* op: 0 = Ed25519 pubkey, 1 = Ed25519 sign, 2 = Ed25519 verify, 3 = X25519 pubkey, 4 = X25519 ECDH */
LEAN_EXPORT lean_obj_res orb_net_leaf_ed_x25519(
    uint8_t op, b_lean_obj_arg k1, b_lean_obj_arg k2, b_lean_obj_arg msg) {
    size_t n1 = lean_sarray_size(k1), n2 = lean_sarray_size(k2), nm = lean_sarray_size(msg), olen = 0;
    EVP_PKEY *pk1 = NULL, *pk2 = NULL; EVP_MD_CTX *mctx = NULL; EVP_PKEY_CTX *pctx = NULL;
    lean_object *out = lean_alloc_sarray(1, 0, op == 1 ? 64 : (op == 2 ? 1 : 32));
    int ok = 0;
    if (op == 0 && n1 == 32 && n2 == 0 && nm == 0) {
        pk1 = EVP_PKEY_new_raw_private_key(EVP_PKEY_ED25519, NULL, lean_sarray_cptr(k1), 32);
        olen = 32; ok = pk1 && EVP_PKEY_get_raw_public_key(pk1, lean_sarray_cptr(out), &olen) == 1 && olen == 32;
    } else if (op == 1 && n1 == 32 && n2 == 0) {
        pk1 = EVP_PKEY_new_raw_private_key(EVP_PKEY_ED25519, NULL, lean_sarray_cptr(k1), 32);
        mctx = EVP_MD_CTX_new(); olen = 64;
        ok = pk1 && mctx && EVP_DigestSignInit(mctx, NULL, NULL, NULL, pk1) == 1 &&
             EVP_DigestSign(mctx, lean_sarray_cptr(out), &olen, lean_sarray_cptr(msg), nm) == 1 && olen == 64;
    } else if (op == 2 && n1 == 32 && n2 == 64) {
        pk1 = EVP_PKEY_new_raw_public_key(EVP_PKEY_ED25519, NULL, lean_sarray_cptr(k1), 32);
        mctx = EVP_MD_CTX_new();
        ok = pk1 && mctx && EVP_DigestVerifyInit(mctx, NULL, NULL, NULL, pk1) == 1 &&
             EVP_DigestVerify(mctx, lean_sarray_cptr(k2), 64, lean_sarray_cptr(msg), nm) == 1;
        if (ok) { lean_sarray_cptr(out)[0] = 1; olen = 1; }
    } else if (op == 3 && n1 == 32 && n2 == 0 && nm == 0) {
        pk1 = EVP_PKEY_new_raw_private_key(EVP_PKEY_X25519, NULL, lean_sarray_cptr(k1), 32);
        olen = 32; ok = pk1 && EVP_PKEY_get_raw_public_key(pk1, lean_sarray_cptr(out), &olen) == 1 && olen == 32;
    } else if (op == 4 && n1 == 32 && n2 == 32 && nm == 0) {
        pk1 = EVP_PKEY_new_raw_private_key(EVP_PKEY_X25519, NULL, lean_sarray_cptr(k1), 32);
        pk2 = EVP_PKEY_new_raw_public_key(EVP_PKEY_X25519, NULL, lean_sarray_cptr(k2), 32);
        pctx = pk1 ? EVP_PKEY_CTX_new(pk1, NULL) : NULL; olen = 32;
        ok = pk2 && pctx && EVP_PKEY_derive_init(pctx) == 1 &&
             EVP_PKEY_derive_set_peer(pctx, pk2) == 1 &&
             EVP_PKEY_derive(pctx, lean_sarray_cptr(out), &olen) == 1 && olen == 32;
    }
    EVP_PKEY_CTX_free(pctx); EVP_MD_CTX_free(mctx); EVP_PKEY_free(pk2); EVP_PKEY_free(pk1);
    if (!ok) return lean_dec_ref(out), lean_io_result_mk_ok(lean_alloc_sarray(1, 0, 0));
    lean_sarray_set_size(out, olen);
    return lean_io_result_mk_ok(out);
}

/* Open a CLOEXEC PTY pair with O_NONBLOCK master: returns packed ((uint64_t)slave_fd << 32) | (uint32_t)master_fd */
LEAN_EXPORT lean_obj_res orb_net_leaf_openpty(uint16_t rows, uint16_t cols) {
    int mfd = -1, sfd = -1;
    struct winsize ws = { .ws_row = rows ? rows : 24, .ws_col = cols ? cols : 80 };
    if (openpty(&mfd, &sfd, NULL, NULL, &ws) < 0) return onl_pack(-1);
    int mfl = fcntl(mfd, F_GETFL, 0);
    if (mfl < 0 || fcntl(mfd, F_SETFL, mfl | O_NONBLOCK) < 0 ||
        fcntl(mfd, F_SETFD, FD_CLOEXEC) < 0 || fcntl(sfd, F_SETFD, FD_CLOEXEC) < 0) {
        int saved = errno ? errno : EIO;
        close(sfd); close(mfd); errno = saved;
        return onl_pack(-1);
    }
    return onl_pack(((int64_t)(uint32_t)sfd << 32) | (uint32_t)mfd);
}

LEAN_EXPORT lean_obj_res orb_net_leaf_pty_resize(uint32_t mfd, uint16_t rows, uint16_t cols) {
    struct winsize ws = { .ws_row = rows, .ws_col = cols };
    return onl_pack(ioctl((int)mfd, TIOCSWINSZ, &ws));
}

/* Verified WebPKI TLS 1.3/1.2 roundtrip with socket deadlines & strict truncation/EOF/error status byte */
LEAN_EXPORT lean_obj_res orb_net_leaf_tls_roundtrip(
    b_lean_obj_arg host, uint16_t port, b_lean_obj_arg req,
    size_t max_resp, uint8_t verify_peer, uint32_t timeout_ms) {
    const char *h = lean_string_cstr(host);
    char pstr[8]; snprintf(pstr, sizeof(pstr), "%u", (unsigned)port);
    struct addrinfo hints = { .ai_family = AF_UNSPEC, .ai_socktype = SOCK_STREAM }, *res = NULL;
    if (max_resp == 0 || max_resp > 0x08000000ULL || getaddrinfo(h, pstr, &hints, &res) != 0 || !res)
        return lean_io_result_mk_ok(lean_alloc_sarray(1, 0, 0));
    int fd = -1;
    uint32_t eff_ms = timeout_ms ? timeout_ms : 30000U;
    struct timeval tv = { .tv_sec = (time_t)(eff_ms / 1000U), .tv_usec = (suseconds_t)((eff_ms % 1000U) * 1000U) };
    for (struct addrinfo *ai = res; ai; ai = ai->ai_next) {
        fd = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
        if (fd < 0) continue;
        if (setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv)) == 0 &&
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv)) == 0 &&
            connect(fd, ai->ai_addr, ai->ai_addrlen) == 0) break;
        close(fd); fd = -1;
    }
    freeaddrinfo(res);
    if (fd < 0) return lean_io_result_mk_ok(lean_alloc_sarray(1, 0, 0));
    SSL_CTX *ctx = SSL_CTX_new(TLS_client_method()); SSL *ssl = NULL;
    size_t cap = max_resp + 1, got = 0, rlen = lean_sarray_size(req), sent = 0;
    lean_object *out = lean_alloc_sarray(1, 0, cap + 1);
    int ok = ctx != NULL; uint8_t status = 3;
    if (ok && verify_peer) {
        SSL_CTX_set_verify(ctx, SSL_VERIFY_PEER, NULL);
        ok = SSL_CTX_set_default_verify_paths(ctx) == 1;
    }
    if (ok) {
        ssl = SSL_new(ctx);
        ok = ssl && SSL_set_tlsext_host_name(ssl, h) == 1 && (!verify_peer || SSL_set1_host(ssl, h) == 1) &&
             SSL_set_fd(ssl, fd) == 1 && SSL_connect(ssl) == 1;
    }
    while (ok && sent < rlen) {
        int w = SSL_write(ssl, lean_sarray_cptr(req) + sent, (int)((rlen - sent) > 0x40000000ULL ? 0x40000000ULL : (rlen - sent)));
        if (w <= 0) { ok = 0; break; }
        sent += (size_t)w;
    }
    while (ok) {
        if (got >= cap) { status = 2; break; }
        ERR_clear_error();
        size_t rem = (cap - got) > 0x40000000ULL ? 0x40000000ULL : (cap - got);
        int r = SSL_read(ssl, lean_sarray_cptr(out) + 1 + got, (int)rem);
        if (r > 0) { got += (size_t)r; continue; }
        int err = SSL_get_error(ssl, r);
        if (err == SSL_ERROR_ZERO_RETURN) status = 1;
        else if (err == SSL_ERROR_SYSCALL && ERR_peek_error() == 0 && r == 0) status = 4;
        else ok = 0;
        break;
    }
    if (ssl) { SSL_shutdown(ssl); SSL_free(ssl); }
    SSL_CTX_free(ctx); close(fd);
    if (!ok) return lean_dec_ref(out), lean_io_result_mk_ok(lean_alloc_sarray(1, 0, 0));
    lean_sarray_cptr(out)[0] = status;
    lean_sarray_set_size(out, 1 + got);
    return lean_io_result_mk_ok(out);
}
