#define _GNU_SOURCE
#include <lean/lean.h>
#include <errno.h>
#include <fcntl.h>
#include <grp.h>
#include <signal.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/socket.h>
#include <sys/stat.h>
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

/* Bits: 0=exists, 1=is_dir, 2=is_reg, 3=is_symlink, 4=owned_by_euid; bits 8..19 = mode & 07777 */
LEAN_EXPORT lean_obj_res orb_bin_lstat_info(b_lean_obj_arg path, lean_obj_arg w) {
    (void)w;
    struct stat st;
    if (lstat(lean_string_cstr(path), &st) != 0) return lean_io_result_mk_ok(lean_box_uint32(0u));
    uint32_t flags = 1u | (S_ISDIR(st.st_mode) ? 2u : 0u) | (S_ISREG(st.st_mode) ? 4u : 0u)
                   | (S_ISLNK(st.st_mode) ? 8u : 0u) | (st.st_uid == geteuid() ? 16u : 0u)
                   | (((uint32_t)(st.st_mode & 07777)) << 8);
    return lean_io_result_mk_ok(lean_box_uint32(flags));
}

LEAN_EXPORT lean_obj_res orb_bin_geteuid(lean_obj_arg w) { (void)w; return lean_io_result_mk_ok(lean_box_uint32((uint32_t)geteuid())); }
LEAN_EXPORT lean_obj_res orb_bin_getpid(lean_obj_arg w) { (void)w; return lean_io_result_mk_ok(lean_box_uint32((uint32_t)getpid())); }

LEAN_EXPORT lean_obj_res orb_bin_shutdown_wr(int32_t fd, lean_obj_arg w) {
    (void)w;
    return lean_io_result_mk_ok(lean_box_uint32(shutdown(fd, SHUT_WR) == 0 ? 0u : 1u));
}

LEAN_EXPORT lean_obj_res orb_bin_kill_sig(int64_t pid, int32_t sig, lean_obj_arg w) {
    (void)w;
    return lean_io_result_mk_ok(lean_box_uint32(kill((pid_t)pid, (int)sig) == 0 ? 0u : (uint32_t)errno));
}

LEAN_EXPORT lean_obj_res orb_bin_now_epoch(lean_obj_arg w) {
    (void)w;
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    return lean_io_result_mk_ok(lean_box_uint64((uint64_t)ts.tv_sec));
}

LEAN_EXPORT lean_obj_res orb_bin_hostname(lean_obj_arg w) {
    (void)w;
    char buf[256] = {0};
    return lean_io_result_mk_ok(lean_mk_string(gethostname(buf, sizeof(buf) - 1) == 0 ? buf : "localhost"));
}

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
    (void)w;
    g_term_received = 0;
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = orb_bin_sig_handler;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGINT, &sa, NULL);
    signal(SIGPIPE, SIG_IGN);
    return lean_io_result_mk_ok(lean_box(0));
}

LEAN_EXPORT lean_obj_res orb_bin_poll_term_trap(lean_obj_arg w) {
    (void)w;
    return lean_io_result_mk_ok(lean_box_uint32(g_term_received ? 1u : 0u));
}

LEAN_EXPORT lean_obj_res orb_bin_spawn_pgrp(
    b_lean_obj_arg prog, b_lean_obj_arg args_arr, b_lean_obj_arg env_arr, uint8_t pipe_stdin, lean_obj_arg w
) {
    (void)w;
    int in_pipe[2] = {-1, -1};
    if (pipe_stdin && pipe(in_pipe) != 0)
        return lean_io_result_mk_error(lean_mk_io_user_error(lean_mk_string("pipe() failed")));
    if (pipe_stdin) fcntl(in_pipe[1], F_SETFD, FD_CLOEXEC);
    size_t argc = lean_array_size(args_arr), envc = lean_array_size(env_arr);
    char **argv = (char **)calloc(argc + 2, sizeof(char *));
    char **envp = (char **)calloc(envc + 1, sizeof(char *));
    if (!argv || !envp) {
        free(argv); free(envp);
        if (pipe_stdin) { close(in_pipe[0]); close(in_pipe[1]); }
        return lean_io_result_mk_error(lean_mk_io_user_error(lean_mk_string("calloc failed")));
    }
    argv[0] = (char *)lean_string_cstr(prog);
    for (size_t i = 0; i < argc; i++) argv[i + 1] = (char *)lean_string_cstr(lean_array_get_core(args_arr, i));
    for (size_t i = 0; i < envc; i++) envp[i] = (char *)lean_string_cstr(lean_array_get_core(env_arr, i));

    pid_t pid = fork();
    if (pid < 0) {
        free(argv); free(envp);
        if (pipe_stdin) { close(in_pipe[0]); close(in_pipe[1]); }
        return lean_io_result_mk_error(lean_mk_io_user_error(lean_mk_string("fork() failed")));
    }
    if (pid == 0) {
        setpgid(0, 0);
        if (isatty(0) == 1) {
            void (*prev)(int) = signal(SIGTTOU, SIG_IGN);
            tcsetpgrp(0, getpgrp());
            signal(SIGTTOU, prev);
        }
        if (pipe_stdin) { close(in_pipe[1]); dup2(in_pipe[0], 0); if (in_pipe[0] != 0) close(in_pipe[0]); }
        signal(SIGTERM, SIG_DFL); signal(SIGINT, SIG_DFL); signal(SIGPIPE, SIG_DFL);
        extern char **environ;
        environ = envp;
        execvp(argv[0], argv);
        _exit(127);
    }
    setpgid(pid, pid);
    free(argv); free(envp);
    int32_t write_fd = -1;
    if (pipe_stdin) { close(in_pipe[0]); write_fd = (int32_t)in_pipe[1]; }
    lean_object *res = lean_alloc_sarray(1, 12, 12);
    uint8_t *rp = lean_sarray_cptr(res);
    int64_t pid64 = (int64_t)pid;
    memcpy(rp, &pid64, 8); memcpy(rp + 8, &write_fd, 4);
    return lean_io_result_mk_ok(res);
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
