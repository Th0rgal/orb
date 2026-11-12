#define _GNU_SOURCE
#include <lean/lean.h>
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <grp.h>
#include <netinet/in.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static volatile sig_atomic_t g_term_received = 0;
static void orb_bin_sig_handler(int sig) { (void)sig; g_term_received = 1; }

LEAN_EXPORT lean_obj_res orb_bin_chmod(b_lean_obj_arg path, uint32_t mode, lean_obj_arg w) {
    (void)w;
    return lean_io_result_mk_ok(lean_box_uint32(chmod(lean_string_cstr(path), (mode_t)mode) == 0 ? 0u : (uint32_t)errno));
}

LEAN_EXPORT lean_obj_res orb_bin_chown_group(b_lean_obj_arg path, b_lean_obj_arg grp_name, lean_obj_arg w) {
    (void)w;
    struct group *gr = getgrnam(lean_string_cstr(grp_name));
    if (!gr) return lean_io_result_mk_ok(lean_box_uint32(1u));
    return lean_io_result_mk_ok(lean_box_uint32(chown(lean_string_cstr(path), (uid_t)0, gr->gr_gid) == 0 ? 0u : 2u));
}

LEAN_EXPORT lean_obj_res orb_bin_peercred(int32_t fd, lean_obj_arg w) {
    (void)w;
    uint32_t uid = 0xFFFFFFFFu, gid = 0xFFFFFFFFu, pid = 0u;
#ifdef SO_PEERCRED
    struct ucred uc;
    socklen_t len = sizeof(uc);
    if (getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &uc, &len) == 0) {
        uid = (uint32_t)uc.uid; gid = (uint32_t)uc.gid; pid = (uint32_t)uc.pid;
    }
#else
    (void)fd;
#endif
    lean_object *ba = lean_alloc_sarray(1, 12, 12);
    uint8_t *p = lean_sarray_cptr(ba);
    memcpy(p, &uid, 4); memcpy(p + 4, &gid, 4); memcpy(p + 8, &pid, 4);
    return lean_io_result_mk_ok(ba);
}

/* Bits: 0=exists, 1=is_dir, 2=is_reg, 3=is_symlink, 4=owned_by_euid, 5=owned_by_root; bits 8..19 = mode & 07777 */
LEAN_EXPORT lean_obj_res orb_bin_lstat_info(b_lean_obj_arg path, lean_obj_arg w) {
    (void)w; struct stat st;
    if (lstat(lean_string_cstr(path), &st) != 0) return lean_io_result_mk_ok(lean_box_uint32(0u));
    uint32_t flags = 1u | (S_ISDIR(st.st_mode) ? 2u : 0u) | (S_ISREG(st.st_mode) ? 4u : 0u)
        | (S_ISLNK(st.st_mode) ? 8u : 0u) | (st.st_uid == geteuid() ? 16u : 0u)
        | (st.st_uid == 0 ? 32u : 0u) | (((uint32_t)(st.st_mode & 07777)) << 8);
    return lean_io_result_mk_ok(lean_box_uint32(flags));
}

LEAN_EXPORT lean_obj_res orb_bin_stat_identity(b_lean_obj_arg path, uint8_t follow, lean_obj_arg w) {
    (void)w; struct stat st;
    int rc = follow ? stat(lean_string_cstr(path), &st) : lstat(lean_string_cstr(path), &st);
    lean_object *ba = lean_alloc_sarray(1, 44, 44);
    uint8_t *p = lean_sarray_cptr(ba); memset(p, 0, 44);
    if (rc == 0) {
        uint64_t dev = (uint64_t)st.st_dev, ino = (uint64_t)st.st_ino, sz = (uint64_t)st.st_size, mt = (uint64_t)st.st_mtime;
        uint32_t uid = (uint32_t)st.st_uid, gid = (uint32_t)st.st_gid, mode = (uint32_t)st.st_mode;
        memcpy(p, &dev, 8); memcpy(p + 8, &ino, 8); memcpy(p + 16, &sz, 8); memcpy(p + 24, &mt, 8);
        memcpy(p + 32, &uid, 4); memcpy(p + 36, &gid, 4); memcpy(p + 40, &mode, 4);
    }
    return lean_io_result_mk_ok(ba);
}

LEAN_EXPORT lean_obj_res orb_bin_geteuid(lean_obj_arg w) { (void)w; return lean_io_result_mk_ok(lean_box_uint32((uint32_t)geteuid())); }
LEAN_EXPORT lean_obj_res orb_bin_getpid(lean_obj_arg w) { (void)w; return lean_io_result_mk_ok(lean_box_uint32((uint32_t)getpid())); }

LEAN_EXPORT lean_obj_res orb_bin_shutdown_wr(int32_t fd, lean_obj_arg w) { (void)w; return lean_io_result_mk_ok(lean_box_uint32(shutdown(fd, SHUT_WR) == 0 ? 0u : 1u)); }
LEAN_EXPORT lean_obj_res orb_bin_kill_sig(int64_t pid, int32_t sig, lean_obj_arg w) { (void)w; return lean_io_result_mk_ok(lean_box_uint32(kill((pid_t)pid, (int)sig) == 0 ? 0u : (uint32_t)errno)); }
LEAN_EXPORT lean_obj_res orb_bin_now_epoch(lean_obj_arg w) { (void)w; struct timespec ts; clock_gettime(CLOCK_REALTIME, &ts); return lean_io_result_mk_ok(lean_box_uint64((uint64_t)ts.tv_sec)); }
LEAN_EXPORT lean_obj_res orb_bin_hostname(lean_obj_arg w) { (void)w; char buf[256] = {0}; return lean_io_result_mk_ok(lean_mk_string(gethostname(buf, sizeof(buf) - 1) == 0 ? buf : "localhost")); }

LEAN_EXPORT lean_obj_res orb_bin_read_fd_chunk(int32_t fd, size_t max_bytes, lean_obj_arg w) {
    (void)w;
    size_t cap = max_bytes == 0 ? 1 : (max_bytes > 65536 ? 65536 : max_bytes);
    lean_object *ba = lean_alloc_sarray(1, 0, cap);
    uint8_t *p = lean_sarray_cptr(ba);
    for (;;) {
        ssize_t n = read(fd, p, cap);
        if (n >= 0) { lean_sarray_set_size(ba, (size_t)n); return lean_io_result_mk_ok(ba); }
        if (errno == EINTR) continue;
        lean_dec_ref(ba);
        return lean_io_result_mk_error(lean_mk_io_user_error(lean_mk_string("read_fd_chunk failed")));
    }
}

LEAN_EXPORT lean_obj_res orb_bin_write_fd_all(int32_t fd, b_lean_obj_arg ba, lean_obj_arg w) {
    (void)w;
    const uint8_t *p = lean_sarray_cptr(ba);
    size_t rem = lean_sarray_size(ba);
    while (rem > 0) {
        ssize_t n = write(fd, p, rem);
        if (n > 0) { p += (size_t)n; rem -= (size_t)n; continue; }
        if (n < 0 && errno == EINTR) continue;
        return lean_io_result_mk_ok(lean_box_uint32((uint32_t)(n < 0 ? errno : EIO)));
    }
    return lean_io_result_mk_ok(lean_box_uint32(0u));
}

LEAN_EXPORT lean_obj_res orb_bin_close_fd(int32_t fd, lean_obj_arg w) { (void)w; close(fd); return lean_io_result_mk_ok(lean_box(0)); }

LEAN_EXPORT lean_obj_res orb_bin_flock_exclusive_nb(b_lean_obj_arg path, lean_obj_arg w) {
    (void)w;
    int fd = open(lean_string_cstr(path), O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd < 0) return lean_io_result_mk_ok(lean_box_uint32(0xFFFFFFFFu));
    if (flock(fd, LOCK_EX | LOCK_NB) != 0) { close(fd); return lean_io_result_mk_ok(lean_box_uint32(0xFFFFFFFEu)); }
    return lean_io_result_mk_ok(lean_box_uint32((uint32_t)fd));
}

LEAN_EXPORT lean_obj_res orb_bin_install_term_trap(lean_obj_arg w) {
    (void)w; g_term_received = 0; struct sigaction sa; memset(&sa, 0, sizeof(sa));
    sa.sa_handler = orb_bin_sig_handler; sigemptyset(&sa.sa_mask);
    sigaction(SIGTERM, &sa, NULL); sigaction(SIGINT, &sa, NULL); signal(SIGPIPE, SIG_IGN);
    return lean_io_result_mk_ok(lean_box(0));
}
LEAN_EXPORT lean_obj_res orb_bin_poll_term_trap(lean_obj_arg w) { (void)w; return lean_io_result_mk_ok(lean_box_uint32(g_term_received ? 1u : 0u)); }

LEAN_EXPORT lean_obj_res orb_bin_spawn_pgrp(
    b_lean_obj_arg prog, b_lean_obj_arg args_arr, b_lean_obj_arg env_arr, uint8_t pipe_stdin, lean_obj_arg w
) {
    (void)w;
    uint8_t use_pipe = pipe_stdin & 1u, null_out = (pipe_stdin >> 1) & 1u, use_out_pipe = (pipe_stdin >> 2) & 1u;
    int in_pipe[2] = {-1, -1}, out_pipe[2] = {-1, -1};
    if ((use_pipe && pipe(in_pipe) != 0) || (use_out_pipe && pipe(out_pipe) != 0)) {
        if (in_pipe[0] >= 0) { close(in_pipe[0]); close(in_pipe[1]); }
        return lean_io_result_mk_error(lean_mk_io_user_error(lean_mk_string("pipe() failed")));
    }
    if (use_pipe) fcntl(in_pipe[1], F_SETFD, FD_CLOEXEC);
    if (use_out_pipe) fcntl(out_pipe[0], F_SETFD, FD_CLOEXEC);
    size_t argc = lean_array_size(args_arr), envc = lean_array_size(env_arr);
    char **argv = (char **)calloc(argc + 2, sizeof(char *)), **envp = (char **)calloc(envc + 1, sizeof(char *));
    if (!argv || !envp) {
        free(argv); free(envp);
        if (use_pipe) { close(in_pipe[0]); close(in_pipe[1]); }
        if (use_out_pipe) { close(out_pipe[0]); close(out_pipe[1]); }
        return lean_io_result_mk_error(lean_mk_io_user_error(lean_mk_string("calloc failed")));
    }
    argv[0] = (char *)lean_string_cstr(prog);
    for (size_t i = 0; i < argc; i++) argv[i + 1] = (char *)lean_string_cstr(lean_array_get_core(args_arr, i));
    for (size_t i = 0; i < envc; i++) envp[i] = (char *)lean_string_cstr(lean_array_get_core(env_arr, i));
    pid_t pid = fork();
    if (pid < 0) {
        free(argv); free(envp);
        if (use_pipe) { close(in_pipe[0]); close(in_pipe[1]); }
        if (use_out_pipe) { close(out_pipe[0]); close(out_pipe[1]); }
        return lean_io_result_mk_error(lean_mk_io_user_error(lean_mk_string("fork() failed")));
    }
    if (pid == 0) {
        setpgid(0, 0);
        if (!null_out && !use_out_pipe && isatty(0) == 1) {
            void (*prev)(int) = signal(SIGTTOU, SIG_IGN); tcsetpgrp(0, getpgrp()); signal(SIGTTOU, prev);
        }
        if (use_pipe) { close(in_pipe[1]); dup2(in_pipe[0], 0); if (in_pipe[0] != 0) close(in_pipe[0]); }
        if (use_out_pipe) { close(out_pipe[0]); dup2(out_pipe[1], 1); if (out_pipe[1] != 1) close(out_pipe[1]); }
        if (null_out) { int dn = open("/dev/null", O_RDWR); if (dn >= 0) { if (!use_pipe) dup2(dn, 0); if (!use_out_pipe) dup2(dn, 1); dup2(dn, 2); if (dn > 2) close(dn); } }
        signal(SIGTERM, SIG_DFL); signal(SIGINT, SIG_DFL); signal(SIGPIPE, SIG_DFL);
        extern char **environ; environ = envp; execvp(argv[0], argv); _exit(127);
    }
    setpgid(pid, pid); free(argv); free(envp);
    int32_t write_fd = -1, read_fd = -1;
    if (use_pipe) { close(in_pipe[0]); write_fd = (int32_t)in_pipe[1]; }
    if (use_out_pipe) { close(out_pipe[1]); read_fd = (int32_t)out_pipe[0]; }
    lean_object *res = lean_alloc_sarray(1, 16, 16);
    uint8_t *rp = lean_sarray_cptr(res); int64_t pid64 = (int64_t)pid;
    memcpy(rp, &pid64, 8); memcpy(rp + 8, &write_fd, 4); memcpy(rp + 12, &read_fd, 4);
    return lean_io_result_mk_ok(res);
}

LEAN_EXPORT lean_obj_res orb_bin_waitpid_block(int64_t pid, lean_obj_arg w) {
    (void)w; int status = 0; pid_t rc;
    do { rc = waitpid((pid_t)pid, &status, 0); } while (rc < 0 && errno == EINTR);
    if (rc < 0) return lean_io_result_mk_ok(lean_box_uint32(1u));
    return lean_io_result_mk_ok(lean_box_uint32(WIFEXITED(status) ? (uint32_t)WEXITSTATUS(status) : (WIFSIGNALED(status) ? (uint32_t)(128 + WTERMSIG(status)) : 1u)));
}

LEAN_EXPORT lean_obj_res orb_bin_waitpid_wnohang(int64_t pid, lean_obj_arg w) {
    (void)w;
    int status = 0;
    pid_t rc = waitpid((pid_t)pid, &status, WNOHANG);
    if (rc == 0) return lean_io_result_mk_ok(lean_box_uint32(0xFFFFFFFFu));
    if (rc < 0) return lean_io_result_mk_ok(lean_box_uint32(1u));
    if (WIFEXITED(status)) return lean_io_result_mk_ok(lean_box_uint32((uint32_t)WEXITSTATUS(status)));
    if (WIFSIGNALED(status)) return lean_io_result_mk_ok(lean_box_uint32((uint32_t)(128 + WTERMSIG(status))));
    return lean_io_result_mk_ok(lean_box_uint32(1u));
}

LEAN_EXPORT lean_obj_res orb_bin_environ_list(lean_obj_arg w) {
    (void)w;
    extern char **environ;
    size_t cnt = 0;
    if (environ) while (environ[cnt] != NULL) cnt++;
    lean_object *arr = lean_alloc_array(0, cnt);
    for (size_t i = 0; i < cnt; i++) arr = lean_array_push(arr, lean_mk_string(environ[i]));
    return lean_io_result_mk_ok(arr);
}

LEAN_EXPORT lean_obj_res orb_bin_setenv(b_lean_obj_arg key, b_lean_obj_arg val, lean_obj_arg w) { (void)w; setenv(lean_string_cstr(key), lean_string_cstr(val), 1); return lean_io_result_mk_ok(lean_box(0)); }
LEAN_EXPORT lean_obj_res orb_bin_unsetenv(b_lean_obj_arg key, lean_obj_arg w) { (void)w; unsetenv(lean_string_cstr(key)); return lean_io_result_mk_ok(lean_box(0)); }
LEAN_EXPORT lean_obj_res orb_bin_statvfs_bytes(b_lean_obj_arg path, lean_obj_arg w) {
    (void)w; struct statvfs st; uint64_t tot = 0, used = 0;
    if (statvfs(lean_string_cstr(path), &st) == 0) {
        uint64_t fr = st.f_frsize ? (uint64_t)st.f_frsize : (uint64_t)st.f_bsize;
        tot = (uint64_t)st.f_blocks * fr;
        used = st.f_blocks >= st.f_bavail ? (uint64_t)(st.f_blocks - st.f_bavail) * fr : 0;
    }
    lean_object *ba = lean_alloc_sarray(1, 16, 16); uint8_t *p = lean_sarray_cptr(ba);
    memcpy(p, &tot, 8); memcpy(p + 8, &used, 8);
    return lean_io_result_mk_ok(ba);
}

/* --- Non-blocking IPv4 UDP socket helpers & WireGuard mac1 (RFC 7693 BLAKE2s) --- */

LEAN_EXPORT lean_obj_res orb_bin_udp_bind(b_lean_obj_arg host, uint16_t port, lean_obj_arg w) {
    (void)w;
    int fd = socket(AF_INET, SOCK_DGRAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
    if (fd < 0) {
        int32_t err_fd = -(int32_t)(errno ? errno : EIO);
        uint16_t z = 0;
        lean_object *ba = lean_alloc_sarray(1, 8, 8);
        uint8_t *p = lean_sarray_cptr(ba);
        memcpy(p, &err_fd, 4); memcpy(p + 4, &z, 2); memcpy(p + 6, &z, 2);
        return lean_io_result_mk_ok(ba);
    }
    int one = 1;
    (void)setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    int buf_sz = 1048576;
    (void)setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &buf_sz, sizeof(buf_sz));
    (void)setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &buf_sz, sizeof(buf_sz));

    struct sockaddr_in sin;
    memset(&sin, 0, sizeof(sin));
    sin.sin_family = AF_INET;
    sin.sin_port = htons(port);
    const char *hstr = lean_string_cstr(host);
    if (!hstr || hstr[0] == '\0' || strcmp(hstr, "0.0.0.0") == 0) {
        sin.sin_addr.s_addr = htonl(INADDR_ANY);
    } else if (strcmp(hstr, "localhost") == 0) {
        sin.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    } else if (inet_pton(AF_INET, hstr, &sin.sin_addr) != 1) {
        close(fd);
        int32_t err_fd = -(int32_t)EINVAL;
        uint16_t z = 0;
        lean_object *ba = lean_alloc_sarray(1, 8, 8);
        uint8_t *p = lean_sarray_cptr(ba);
        memcpy(p, &err_fd, 4); memcpy(p + 4, &z, 2); memcpy(p + 6, &z, 2);
        return lean_io_result_mk_ok(ba);
    }
    if (bind(fd, (struct sockaddr *)&sin, sizeof(sin)) != 0) {
        int saved = errno ? errno : EIO;
        close(fd);
        int32_t err_fd = -(int32_t)saved;
        uint16_t z = 0;
        lean_object *ba = lean_alloc_sarray(1, 8, 8);
        uint8_t *p = lean_sarray_cptr(ba);
        memcpy(p, &err_fd, 4); memcpy(p + 4, &z, 2); memcpy(p + 6, &z, 2);
        return lean_io_result_mk_ok(ba);
    }
    struct sockaddr_in bound_sin;
    socklen_t blen = sizeof(bound_sin);
    uint16_t bound_port = port;
    if (getsockname(fd, (struct sockaddr *)&bound_sin, &blen) == 0) {
        bound_port = ntohs(bound_sin.sin_port);
    }
    int32_t fd32 = (int32_t)fd;
    uint16_t pad = 0;
    lean_object *ba = lean_alloc_sarray(1, 8, 8);
    uint8_t *p = lean_sarray_cptr(ba);
    memcpy(p, &fd32, 4); memcpy(p + 4, &bound_port, 2); memcpy(p + 6, &pad, 2);
    return lean_io_result_mk_ok(ba);
}

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

LEAN_EXPORT lean_obj_res orb_bin_udp_sendto(int32_t fd, uint32_t dst_ip_host, uint16_t dst_port, b_lean_obj_arg payload, lean_obj_arg w) {
    (void)w;
    struct sockaddr_in sin;
    memset(&sin, 0, sizeof(sin));
    sin.sin_family = AF_INET;
    sin.sin_addr.s_addr = htonl(dst_ip_host);
    sin.sin_port = htons(dst_port);
    const uint8_t *buf = lean_sarray_cptr(payload);
    size_t len = lean_sarray_size(payload);
    ssize_t rc = sendto((int)fd, buf, len, MSG_DONTWAIT, (const struct sockaddr *)&sin, sizeof(sin));
    if (rc < 0) {
        return lean_io_result_mk_ok(lean_box_uint32((uint32_t)(errno ? errno : EIO)));
    }
    return lean_io_result_mk_ok(lean_box_uint32((size_t)rc == len ? 0u : (uint32_t)EMSGSIZE));
}

static inline uint32_t b2s_rotr32(uint32_t x, unsigned n) {
    return (x >> n) | (x << (32u - n));
}

static inline uint32_t b2s_load32_le(const uint8_t *p) {
    uint32_t v;
    memcpy(&v, p, 4);
    return v;
}

static void b2s_compress(uint32_t h[8], const uint8_t block[64], uint64_t t, uint32_t f0) {
    static const uint32_t iv[8] = {
        0x6A09E667u, 0xBB67AE85u, 0x3C6EF372u, 0xA54FF53Au,
        0x510E527Fu, 0x9B05688Cu, 0x1F83D9ABu, 0x5BE0CD19u
    };
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
    for (size_t i = 0; i < 16; i++) m[i] = b2s_load32_le(block + i * 4);
    for (size_t i = 0; i < 8; i++) { v[i] = h[i]; v[i + 8] = iv[i]; }
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

static void blake2s_hash(uint8_t *out, size_t outlen, const uint8_t *key, size_t keylen, const uint8_t *in, size_t inlen) {
    uint32_t h[8] = {
        0x6A09E667u, 0xBB67AE85u, 0x3C6EF372u, 0xA54FF53Au,
        0x510E527Fu, 0x9B05688Cu, 0x1F83D9ABu, 0x5BE0CD19u
    };
    h[0] ^= 0x01010000u ^ ((uint32_t)keylen << 8) ^ (uint32_t)outlen;
    uint8_t buf[64];
    uint64_t t = 0;
    if (keylen > 0) {
        memset(buf, 0, 64);
        memcpy(buf, key, keylen);
        if (inlen == 0) {
            b2s_compress(h, buf, 64u, 0xFFFFFFFFu);
            uint8_t raw[32];
            for (size_t i = 0; i < 8; i++) memcpy(raw + i * 4, &h[i], 4);
            memcpy(out, raw, outlen);
            return;
        }
        t = 64u;
        b2s_compress(h, buf, t, 0u);
    }
    size_t off = 0;
    while (inlen - off > 64) {
        t += 64u;
        b2s_compress(h, in + off, t, 0u);
        off += 64;
    }
    size_t rem = inlen - off;
    memset(buf, 0, 64);
    if (rem > 0) memcpy(buf, in + off, rem);
    t += (uint64_t)rem;
    b2s_compress(h, buf, t, 0xFFFFFFFFu);
    uint8_t raw[32];
    for (size_t i = 0; i < 8; i++) memcpy(raw + i * 4, &h[i], 4);
    memcpy(out, raw, outlen);
}

/* Compute WireGuard 16-byte `mac1` = BLAKE2s-128(key=BLAKE2s-256("mac1----" || pub32), msg=pkt_prefix). */
LEAN_EXPORT lean_obj_res orb_bin_wg_mac1(b_lean_obj_arg pub32, b_lean_obj_arg pkt_prefix, lean_obj_arg w) {
    (void)w;
    if (lean_sarray_size(pub32) != 32) {
        return lean_io_result_mk_ok(lean_alloc_sarray(1, 0, 0));
    }
    uint8_t label_pub[40];
    memcpy(label_pub, "mac1----", 8);
    memcpy(label_pub + 8, lean_sarray_cptr(pub32), 32);
    uint8_t mac1_key[32];
    blake2s_hash(mac1_key, 32, NULL, 0, label_pub, 40);
    lean_object *out = lean_alloc_sarray(1, 16, 16);
    blake2s_hash(lean_sarray_cptr(out), 16, mac1_key, 32, lean_sarray_cptr(pkt_prefix), lean_sarray_size(pkt_prefix));
    return lean_io_result_mk_ok(out);
}
