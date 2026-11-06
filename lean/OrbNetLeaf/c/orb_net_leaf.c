#ifndef __APPLE__
#define _GNU_SOURCE
#endif
#include <lean/lean.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#ifdef __APPLE__
#include <util.h>
#else
#include <pty.h>
#endif
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
    int len1 = 0, len2 = 0, ok = ctx != NULL;
    if (ok) ok = EVP_CipherInit_ex(ctx, cip, NULL, NULL, NULL, enc ? 1 : 0) == 1;
    if (ok) ok = EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_AEAD_SET_IVLEN, 12, NULL) == 1;
    if (ok) ok = EVP_CipherInit_ex(ctx, NULL, NULL, lean_sarray_cptr(key), lean_sarray_cptr(nonce), enc ? 1 : 0) == 1;
    if (ok && !enc)
        ok = EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_AEAD_SET_TAG, 16, (void *)(lean_sarray_cptr(buf) + pay_len)) == 1;
    if (ok && alen > 0)
        ok = EVP_CipherUpdate(ctx, NULL, &len1, lean_sarray_cptr(aad), (int)alen) == 1;
    if (ok && pay_len > 0)
        ok = EVP_CipherUpdate(ctx, lean_sarray_cptr(out), &len1, lean_sarray_cptr(buf), (int)pay_len) == 1;
    if (ok) ok = EVP_CipherFinal_ex(ctx, lean_sarray_cptr(out) + len1, &len2) == 1;
    if (ok && enc)
        ok = EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_AEAD_GET_TAG, 16, lean_sarray_cptr(out) + pay_len) == 1;
    EVP_CIPHER_CTX_free(ctx);
    if (!ok) return lean_dec_ref(out), lean_io_result_mk_ok(lean_alloc_sarray(1, 0, 0));
    if (!enc && pay_len == 0) { lean_sarray_cptr(out)[0] = 1; lean_sarray_set_size(out, 1); }
    else lean_sarray_set_size(out, out_cap);
    return lean_io_result_mk_ok(out);
}

/* op: 0 = Ed25519 pubkey from 32B seed, 1 = Ed25519 sign (64B sig), 2 = Ed25519 verify (1B {1} if ok else 0B), 3 = X25519 DH/pub */
LEAN_EXPORT lean_obj_res orb_net_leaf_ed_x25519(
    uint8_t op, b_lean_obj_arg k1, b_lean_obj_arg k2, b_lean_obj_arg msg) {
    size_t n1 = lean_sarray_size(k1), n2 = lean_sarray_size(k2), nm = lean_sarray_size(msg);
    EVP_PKEY *pk1 = NULL, *pk2 = NULL;
    EVP_MD_CTX *mctx = NULL;
    EVP_PKEY_CTX *pctx = NULL;
    lean_object *out = lean_alloc_sarray(1, 0, op == 1 ? 64 : (op == 2 ? 1 : 32));
    size_t olen = 0;
    int ok = 0;
    if (op == 0 && n1 == 32) {
        pk1 = EVP_PKEY_new_raw_private_key(EVP_PKEY_ED25519, NULL, lean_sarray_cptr(k1), 32);
        olen = 32;
        ok = pk1 && EVP_PKEY_get_raw_public_key(pk1, lean_sarray_cptr(out), &olen) == 1 && olen == 32;
    } else if (op == 1 && n1 == 32) {
        pk1 = EVP_PKEY_new_raw_private_key(EVP_PKEY_ED25519, NULL, lean_sarray_cptr(k1), 32);
        mctx = EVP_MD_CTX_new();
        olen = 64;
        ok = pk1 && mctx && EVP_DigestSignInit(mctx, NULL, NULL, NULL, pk1) == 1 &&
             EVP_DigestSign(mctx, lean_sarray_cptr(out), &olen, lean_sarray_cptr(msg), nm) == 1 && olen == 64;
    } else if (op == 2 && n1 == 32 && n2 == 64) {
        pk1 = EVP_PKEY_new_raw_public_key(EVP_PKEY_ED25519, NULL, lean_sarray_cptr(k1), 32);
        mctx = EVP_MD_CTX_new();
        ok = pk1 && mctx && EVP_DigestVerifyInit(mctx, NULL, NULL, NULL, pk1) == 1 &&
             EVP_DigestVerify(mctx, lean_sarray_cptr(k2), 64, lean_sarray_cptr(msg), nm) == 1;
        if (ok) { lean_sarray_cptr(out)[0] = 1; olen = 1; }
    } else if (op == 3 && n1 == 32 && (n2 == 0 || n2 == 32)) {
        pk1 = EVP_PKEY_new_raw_private_key(EVP_PKEY_X25519, NULL, lean_sarray_cptr(k1), 32);
        olen = 32;
        if (n2 == 0) {
            ok = pk1 && EVP_PKEY_get_raw_public_key(pk1, lean_sarray_cptr(out), &olen) == 1 && olen == 32;
        } else {
            pk2 = EVP_PKEY_new_raw_public_key(EVP_PKEY_X25519, NULL, lean_sarray_cptr(k2), 32);
            pctx = pk1 ? EVP_PKEY_CTX_new(pk1, NULL) : NULL;
            ok = pk2 && pctx && EVP_PKEY_derive_init(pctx) == 1 &&
                 EVP_PKEY_derive_set_peer(pctx, pk2) == 1 &&
                 EVP_PKEY_derive(pctx, lean_sarray_cptr(out), &olen) == 1 && olen == 32;
        }
    }
    EVP_PKEY_CTX_free(pctx); EVP_MD_CTX_free(mctx); EVP_PKEY_free(pk2); EVP_PKEY_free(pk1);
    if (!ok) return lean_dec_ref(out), lean_io_result_mk_ok(lean_alloc_sarray(1, 0, 0));
    lean_sarray_set_size(out, olen);
    return lean_io_result_mk_ok(out);
}

/* Open a non-blocking CLOEXEC PTY pair: returns packed ((uint64_t)slave_fd << 32) | (uint32_t)master_fd */
LEAN_EXPORT lean_obj_res orb_net_leaf_openpty(uint16_t rows, uint16_t cols) {
    int mfd = -1, sfd = -1;
    struct winsize ws = { .ws_row = rows ? rows : 24, .ws_col = cols ? cols : 80 };
    if (openpty(&mfd, &sfd, NULL, NULL, &ws) < 0) return onl_pack(-1);
    fcntl(mfd, F_SETFD, FD_CLOEXEC);
    fcntl(sfd, F_SETFD, FD_CLOEXEC);
    return onl_pack(((int64_t)(uint32_t)sfd << 32) | (uint32_t)mfd);
}

LEAN_EXPORT lean_obj_res orb_net_leaf_pty_resize(uint32_t mfd, uint16_t rows, uint16_t cols) {
    struct winsize ws = { .ws_row = rows, .ws_col = cols };
    return onl_pack(ioctl((int)mfd, TIOCSWINSZ, &ws));
}

/* Verified WebPKI TLS 1.3/1.2 roundtrip over host:port sending `req` and reading bounded `max_resp` bytes */
LEAN_EXPORT lean_obj_res orb_net_leaf_tls_roundtrip(
    b_lean_obj_arg host, uint16_t port, b_lean_obj_arg req, size_t max_resp, uint8_t verify_peer) {
    const char *h = lean_string_cstr(host);
    char pstr[8];
    snprintf(pstr, sizeof(pstr), "%u", (unsigned)port);
    struct addrinfo hints = { .ai_family = AF_UNSPEC, .ai_socktype = SOCK_STREAM }, *res = NULL;
    if (max_resp == 0 || getaddrinfo(h, pstr, &hints, &res) != 0 || !res)
        return lean_io_result_mk_ok(lean_alloc_sarray(1, 0, 0));
    int fd = socket(res->ai_family, res->ai_socktype, res->ai_protocol);
    if (fd < 0 || connect(fd, res->ai_addr, res->ai_addrlen) < 0) {
        if (fd >= 0) close(fd);
        freeaddrinfo(res);
        return lean_io_result_mk_ok(lean_alloc_sarray(1, 0, 0));
    }
    freeaddrinfo(res);
    SSL_CTX *ctx = SSL_CTX_new(TLS_client_method());
    SSL *ssl = NULL;
    lean_object *out = lean_alloc_sarray(1, 0, max_resp);
    size_t got = 0, rlen = lean_sarray_size(req), sent = 0;
    int ok = ctx != NULL;
    if (ok && verify_peer) {
        SSL_CTX_set_verify(ctx, SSL_VERIFY_PEER, NULL);
        ok = SSL_CTX_set_default_verify_paths(ctx) == 1;
    }
    if (ok) {
        ssl = SSL_new(ctx);
        ok = ssl != NULL && SSL_set_tlsext_host_name(ssl, h) == 1 &&
             (!verify_peer || SSL_set1_host(ssl, h) == 1) &&
             SSL_set_fd(ssl, fd) == 1 && SSL_connect(ssl) == 1;
    }
    while (ok && sent < rlen) {
        size_t chunk = (rlen - sent) > 0x40000000ULL ? 0x40000000ULL : (rlen - sent);
        int w = SSL_write(ssl, lean_sarray_cptr(req) + sent, (int)chunk);
        if (w <= 0) { ok = 0; break; }
        sent += (size_t)w;
    }
    while (ok && got < max_resp) {
        size_t chunk = (max_resp - got) > 0x40000000ULL ? 0x40000000ULL : (max_resp - got);
        int r = SSL_read(ssl, lean_sarray_cptr(out) + got, (int)chunk);
        if (r <= 0) break;
        got += (size_t)r;
    }
    if (ssl) { SSL_shutdown(ssl); SSL_free(ssl); }
    SSL_CTX_free(ctx);
    close(fd);
    if (!ok) return lean_dec_ref(out), lean_io_result_mk_ok(lean_alloc_sarray(1, 0, 0));
    lean_sarray_set_size(out, got);
    return lean_io_result_mk_ok(out);
}
