#include <lean/lean.h>
#include <openssl/evp.h>
#include <openssl/rand.h>
#include <openssl/x509.h>
#include <openssl/core_names.h>
#include <string.h>

LEAN_EXPORT lean_obj_res orb_net_leaf_verify_p256(b_lean_obj_arg key,
    b_lean_obj_arg signature, b_lean_obj_arg payload, lean_obj_arg world) {
    (void)world;
    EVP_PKEY *pk = NULL;
    EVP_MD_CTX *ctx = NULL;
    const unsigned char *p = lean_sarray_cptr(key);
    const unsigned char *end = p + lean_sarray_size(key);
    char group[80];
    size_t group_len = 0;
    int valid = 0;
    if (lean_sarray_size(key) == 0 || lean_sarray_size(key) > 256 ||
        lean_sarray_size(signature) > 80) goto done;
    pk = d2i_PUBKEY(NULL, &p, (long)lean_sarray_size(key));
    if (!pk || p != end || !EVP_PKEY_is_a(pk, "EC")) goto done;
    if (!EVP_PKEY_get_utf8_string_param(pk, OSSL_PKEY_PARAM_GROUP_NAME,
            group, sizeof(group), &group_len) || strcmp(group, "prime256v1")) goto done;
    ctx = EVP_MD_CTX_new();
    if (!ctx || EVP_DigestVerifyInit(ctx, NULL, EVP_sha256(), NULL, pk) != 1) goto done;
    valid = EVP_DigestVerify(ctx, lean_sarray_cptr(signature),
        lean_sarray_size(signature), lean_sarray_cptr(payload),
        lean_sarray_size(payload)) == 1;
done:
    EVP_MD_CTX_free(ctx);
    EVP_PKEY_free(pk);
    return lean_io_result_mk_ok(lean_box(valid));
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

LEAN_EXPORT lean_obj_res orb_net_leaf_rand_bytes(size_t n) {
    if (n > 0x40000000ULL) return lean_io_result_mk_ok(lean_alloc_sarray(1, 0, 0));
    lean_object *out = lean_alloc_sarray(1, 0, n);
    if (n > 0 && RAND_bytes(lean_sarray_cptr(out), (int)n) != 1)
        return lean_dec_ref(out), lean_io_result_mk_ok(lean_alloc_sarray(1, 0, 0));
    return lean_sarray_set_size(out, n), lean_io_result_mk_ok(out);
}
