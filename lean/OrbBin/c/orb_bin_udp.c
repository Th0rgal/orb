/*
 * orb_bin_udp.c — Non-blocking IPv4 UDP socket leaf shim and WireGuard `mac1`
 * (RFC 7693 keyed BLAKE2s) for the blind tether relay (<= 220 LOC).
 */
#define _GNU_SOURCE
#include <lean/lean.h>
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <poll.h>
#include <stdint.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>

/* `[fd_or_negative_errno : i32][bound_port : u16][pad : u16]` */
static lean_obj_res udp_bind_result(int32_t fd_or_err, uint16_t port) {
    uint16_t pad = 0;
    lean_object *ba = lean_alloc_sarray(1, 8, 8);
    uint8_t *p = lean_sarray_cptr(ba);
    memcpy(p, &fd_or_err, 4); memcpy(p + 4, &port, 2); memcpy(p + 6, &pad, 2);
    return lean_io_result_mk_ok(ba);
}

/* No SO_REUSEADDR: a second Core on the same host must fail to bind instead of sharing the port. */
LEAN_EXPORT lean_obj_res orb_bin_udp_bind(b_lean_obj_arg host, uint16_t port, lean_obj_arg w) {
    (void)w;
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) return udp_bind_result(-(int32_t)(errno ? errno : EIO), 0);
    (void)fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK);
    (void)fcntl(fd, F_SETFD, FD_CLOEXEC);
    int buf_sz = 1048576;
    (void)setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &buf_sz, sizeof(buf_sz));
    (void)setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &buf_sz, sizeof(buf_sz));
    struct sockaddr_in sin;
    memset(&sin, 0, sizeof(sin));
    sin.sin_family = AF_INET;
    sin.sin_port = htons(port);
    const char *hstr = lean_string_cstr(host);
    if (hstr[0] == '\0' || strcmp(hstr, "0.0.0.0") == 0) {
        sin.sin_addr.s_addr = htonl(INADDR_ANY);
    } else if (strcmp(hstr, "localhost") == 0) {
        sin.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    } else if (inet_pton(AF_INET, hstr, &sin.sin_addr) != 1) {
        close(fd);
        return udp_bind_result(-(int32_t)EINVAL, 0);
    }
    if (bind(fd, (struct sockaddr *)&sin, sizeof(sin)) != 0) {
        int saved = errno ? errno : EIO;
        close(fd);
        return udp_bind_result(-(int32_t)saved, 0);
    }
    struct sockaddr_in bound;
    socklen_t blen = sizeof(bound);
    uint16_t bound_port = port;
    if (getsockname(fd, (struct sockaddr *)&bound, &blen) == 0) bound_port = ntohs(bound.sin_port);
    return udp_bind_result((int32_t)fd, bound_port);
}

/* `[src_ip_host_order : u32][src_port : u16][tag = 1 : u16][payload...]`, or empty on timeout/error. */
LEAN_EXPORT lean_obj_res orb_bin_udp_recvfrom_poll(int32_t fd, uint32_t timeout_ms, size_t max_bytes, lean_obj_arg w) {
    (void)w;
    struct pollfd pfd;
    pfd.fd = (int)fd;
    pfd.events = POLLIN;
    pfd.revents = 0;
    int prc = poll(&pfd, 1, (int)(timeout_ms > 60000u ? 60000u : timeout_ms));
    if (prc <= 0 || (pfd.revents & POLLIN) == 0) {
        return lean_io_result_mk_ok(lean_alloc_sarray(1, 0, 0));
    }
    size_t cap = max_bytes == 0 ? 1 : (max_bytes > 65535 ? 65535 : max_bytes);
    lean_object *ba = lean_alloc_sarray(1, 0, 8 + cap);
    uint8_t *p = lean_sarray_cptr(ba);
    struct sockaddr_in sin;
    socklen_t slen = sizeof(sin);
    memset(&sin, 0, sizeof(sin));
    ssize_t n = recvfrom((int)fd, p + 8, cap, MSG_DONTWAIT, (struct sockaddr *)&sin, &slen);
    if (n < 0) {
        lean_dec_ref(ba);
        return lean_io_result_mk_ok(lean_alloc_sarray(1, 0, 0));
    }
    uint32_t src_ip = ntohl(sin.sin_addr.s_addr);
    uint16_t src_port = ntohs(sin.sin_port);
    uint16_t tag = 1u;
    memcpy(p, &src_ip, 4);
    memcpy(p + 4, &src_port, 2);
    memcpy(p + 6, &tag, 2);
    lean_sarray_set_size(ba, 8 + (size_t)n);
    return lean_io_result_mk_ok(ba);
}

/* Returns 0 on success, otherwise an errno value. */
LEAN_EXPORT lean_obj_res orb_bin_udp_sendto(int32_t fd, uint32_t dst_ip_host, uint16_t dst_port, b_lean_obj_arg payload, lean_obj_arg w) {
    (void)w;
    struct sockaddr_in sin;
    memset(&sin, 0, sizeof(sin));
    sin.sin_family = AF_INET;
    sin.sin_addr.s_addr = htonl(dst_ip_host);
    sin.sin_port = htons(dst_port);
    size_t len = lean_sarray_size(payload);
    ssize_t rc = sendto((int)fd, lean_sarray_cptr(payload), len, MSG_DONTWAIT, (const struct sockaddr *)&sin, sizeof(sin));
    if (rc < 0) return lean_io_result_mk_ok(lean_box_uint32((uint32_t)(errno ? errno : EIO)));
    return lean_io_result_mk_ok(lean_box_uint32((size_t)rc == len ? 0u : (uint32_t)EMSGSIZE));
}

static const uint32_t b2s_iv[8] = {
    0x6A09E667u, 0xBB67AE85u, 0x3C6EF372u, 0xA54FF53Au,
    0x510E527Fu, 0x9B05688Cu, 0x1F83D9ABu, 0x5BE0CD19u
};

static inline uint32_t b2s_rotr32(uint32_t x, unsigned n) {
    return (x >> n) | (x << (32u - n));
}

static void b2s_compress(uint32_t h[8], const uint8_t block[64], uint64_t t, uint32_t f0) {
    static const uint8_t sigma[10][16] = {
        { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9,10,11,12,13,14,15 },
        {14,10, 4, 8, 9,15,13, 6, 1,12, 0, 2,11, 7, 5, 3 },
        {11, 8,12, 0, 5, 2,15,13,10,14, 3, 6, 7, 1, 9, 4 },
        { 7, 9, 3, 1,13,12,11,14, 2, 6, 5,10, 4, 0,15, 8 },
        { 9, 0, 5, 7, 2, 4,10,15,14, 1,11,12, 6, 8, 3,13 },
        { 2,12, 6,10, 0,11, 8, 3, 4,13, 7, 5,15,14, 1, 9 },
        {12, 5, 1,15,14,13, 4,10, 0, 7, 6, 3, 9, 2, 8,11 },
        {13,11, 7,14,12, 1, 3, 9, 5, 0,15, 4, 8, 6, 2,10 },
        { 6,15,14, 9,11, 3, 0, 8,12, 2,13, 7, 1, 4,10, 5 },
        {10, 2, 8, 4, 7, 6, 1, 5,15,11, 9,14, 3,12,13, 0 }
    };
    uint32_t m[16], v[16];
    for (size_t i = 0; i < 16; i++) memcpy(&m[i], block + i * 4, 4);
    for (size_t i = 0; i < 8; i++) { v[i] = h[i]; v[i + 8] = b2s_iv[i]; }
    v[12] ^= (uint32_t)(t & 0xFFFFFFFFu);
    v[13] ^= (uint32_t)(t >> 32);
    v[14] ^= f0;

#define B2S_G(a, b, c, d, x, y) do { \
    v[a] = v[a] + v[b] + (x); v[d] = b2s_rotr32(v[d] ^ v[a], 16); \
    v[c] = v[c] + v[d];       v[b] = b2s_rotr32(v[b] ^ v[c], 12); \
    v[a] = v[a] + v[b] + (y); v[d] = b2s_rotr32(v[d] ^ v[a], 8);  \
    v[c] = v[c] + v[d];       v[b] = b2s_rotr32(v[b] ^ v[c], 7);  \
} while (0)

    for (size_t r = 0; r < 10; r++) {
        const uint8_t *s = sigma[r];
        B2S_G(0, 4,  8, 12, m[s[0]],  m[s[1]]);
        B2S_G(1, 5,  9, 13, m[s[2]],  m[s[3]]);
        B2S_G(2, 6, 10, 14, m[s[4]],  m[s[5]]);
        B2S_G(3, 7, 11, 15, m[s[6]],  m[s[7]]);
        B2S_G(0, 5, 10, 15, m[s[8]],  m[s[9]]);
        B2S_G(1, 6, 11, 12, m[s[10]], m[s[11]]);
        B2S_G(2, 7,  8, 13, m[s[12]], m[s[13]]);
        B2S_G(3, 4,  9, 14, m[s[14]], m[s[15]]);
    }
#undef B2S_G
    for (size_t i = 0; i < 8; i++) h[i] ^= v[i] ^ v[i + 8];
}

/* Keyed BLAKE2s (`outlen`, `keylen` <= 32). Little-endian hosts only, like the rest of the shims. */
static void blake2s_hash(uint8_t *out, size_t outlen, const uint8_t *key, size_t keylen, const uint8_t *in, size_t inlen) {
    uint32_t h[8];
    memcpy(h, b2s_iv, sizeof(h));
    h[0] ^= 0x01010000u ^ ((uint32_t)keylen << 8) ^ (uint32_t)outlen;
    uint8_t buf[64];
    uint64_t t = 0;
    size_t off = 0;
    if (keylen > 0) {
        memset(buf, 0, 64);
        memcpy(buf, key, keylen);
        if (inlen > 0) { t = 64u; b2s_compress(h, buf, t, 0u); }
    }
    if (keylen == 0 || inlen > 0) {
        while (inlen - off > 64) {
            t += 64u;
            b2s_compress(h, in + off, t, 0u);
            off += 64;
        }
        size_t rem = inlen - off;
        memset(buf, 0, 64);
        if (rem > 0) memcpy(buf, in + off, rem);
        t += (uint64_t)rem;
    } else {
        t = 64u; /* key block is the only (final) block */
    }
    b2s_compress(h, buf, t, 0xFFFFFFFFu);
    memcpy(out, h, outlen);
}

/* General keyed BLAKE2s, exposed so the self-test can check RFC 7693 vectors. */
LEAN_EXPORT lean_obj_res orb_bin_blake2s(b_lean_obj_arg key, b_lean_obj_arg msg, size_t outlen, lean_obj_arg w) {
    (void)w;
    if (outlen == 0 || outlen > 32 || lean_sarray_size(key) > 32) {
        return lean_io_result_mk_ok(lean_alloc_sarray(1, 0, 0));
    }
    lean_object *out = lean_alloc_sarray(1, outlen, outlen);
    blake2s_hash(lean_sarray_cptr(out), outlen, lean_sarray_cptr(key), lean_sarray_size(key),
                 lean_sarray_cptr(msg), lean_sarray_size(msg));
    return lean_io_result_mk_ok(out);
}
