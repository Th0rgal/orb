#include <lean/lean.h>
#include <openssl/evp.h>
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
