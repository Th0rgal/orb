#define _GNU_SOURCE
#include <lean/lean.h>
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static volatile sig_atomic_t g_node_term = 0, g_node_hup = 0;
static void orb_node_on_term(int sig) { (void)sig; g_node_term = 1; }
static void orb_node_on_hup(int sig) { (void)sig; g_node_hup = 1; }

LEAN_EXPORT lean_obj_res orb_node_install_signals(lean_obj_arg w) {
    (void)w;
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sigemptyset(&sa.sa_mask);
    sa.sa_handler = orb_node_on_term;
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGINT, &sa, NULL);
    sa.sa_handler = orb_node_on_hup;
    sigaction(SIGHUP, &sa, NULL);
    signal(SIGPIPE, SIG_IGN);
    return lean_io_result_mk_ok(lean_box(0));
}
LEAN_EXPORT lean_obj_res orb_node_poll_signals(lean_obj_arg w) {
    (void)w;
    uint32_t flags = (g_node_term ? 1u : 0u) | (g_node_hup ? 2u : 0u);
    g_node_hup = 0;
    return lean_io_result_mk_ok(lean_box_uint32(flags));
}
LEAN_EXPORT lean_obj_res orb_node_geteuid(lean_obj_arg w) {
    (void)w;
    return lean_io_result_mk_ok(lean_box_uint32((uint32_t)geteuid()));
}
LEAN_EXPORT lean_obj_res orb_node_now_epoch(lean_obj_arg w) {
    (void)w;
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    return lean_io_result_mk_ok(lean_box_uint64((uint64_t)ts.tv_sec));
}

static uint64_t orb_parse_u64_dec(const char *p) {
    while (*p == ' ' || *p == '\t') p++;
    uint64_t v = 0;
    while (*p >= '0' && *p <= '9') {
        v = v * 10ULL + (uint64_t)(*p - '0');
        p++;
    }
    return v;
}

/* Returns 40-byte ByteArray: cpu_u32, pad_u32, mem_total_u64, mem_avail_u64, disk_total_u64, disk_avail_u64 */
LEAN_EXPORT lean_obj_res orb_node_host_stats(b_lean_obj_arg work_dir, lean_obj_arg w) {
    (void)w;
    long ncpu = sysconf(_SC_NPROCESSORS_ONLN);
    uint32_t cpus = ncpu > 0 ? (uint32_t)ncpu : 1u, pad = 0u;
    uint64_t mem_tot = 0, mem_avail = 0, disk_tot = 0, disk_avail = 0;
    FILE *fp = fopen("/proc/meminfo", "r");
    if (fp) {
        char line[256];
        while (fgets(line, sizeof(line), fp)) {
            if (strncmp(line, "MemTotal:", 9) == 0) {
                mem_tot = orb_parse_u64_dec(line + 9) * 1024ULL;
            } else if (strncmp(line, "MemAvailable:", 13) == 0) {
                mem_avail = orb_parse_u64_dec(line + 13) * 1024ULL;
            }
        }
        fclose(fp);
    }
    struct statvfs vfs;
    if (statvfs(lean_string_cstr(work_dir), &vfs) == 0) {
        disk_tot = (uint64_t)vfs.f_blocks * (uint64_t)vfs.f_frsize;
        disk_avail = (uint64_t)vfs.f_bavail * (uint64_t)vfs.f_frsize;
    }
    lean_object *ba = lean_alloc_sarray(1, 40, 40);
    uint8_t *p = lean_sarray_cptr(ba);
    memcpy(p + 0, &cpus, 4);
    memcpy(p + 4, &pad, 4);
    memcpy(p + 8, &mem_tot, 8);
    memcpy(p + 16, &mem_avail, 8);
    memcpy(p + 24, &disk_tot, 8);
    memcpy(p + 32, &disk_avail, 8);
    return lean_io_result_mk_ok(ba);
}

LEAN_EXPORT lean_obj_res orb_node_tcp_listen(b_lean_obj_arg host, uint16_t port, lean_obj_arg w) {
    (void)w;
    int fd = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0) return lean_io_result_mk_error(lean_mk_io_user_error(lean_mk_string("socket() failed")));
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    const char *h = lean_string_cstr(host);
    if (strcmp(h, "0.0.0.0") == 0 || strcmp(h, "*") == 0) {
        addr.sin_addr.s_addr = htonl(INADDR_ANY);
    } else if (inet_pton(AF_INET, h, &addr.sin_addr) != 1) {
        close(fd);
        return lean_io_result_mk_error(lean_mk_io_user_error(lean_mk_string("invalid IPv4 bind host")));
    }
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0 || listen(fd, 128) != 0) {
        close(fd);
        return lean_io_result_mk_error(lean_mk_io_user_error(lean_mk_string("bind/listen failed")));
    }
    return lean_io_result_mk_ok(lean_box_uint32((uint32_t)fd));
}

LEAN_EXPORT lean_obj_res orb_node_tcp_accept(uint32_t listen_fd, uint32_t timeout_ms, lean_obj_arg w) {
    (void)w;
    struct pollfd pfd = { .fd = (int)listen_fd, .events = POLLIN, .revents = 0 };
    int pr = poll(&pfd, 1, (int)timeout_ms);
    if (pr <= 0) return lean_io_result_mk_ok(lean_box_uint32(0xFFFFFFFFu));
    int cfd = accept4((int)listen_fd, NULL, NULL, SOCK_CLOEXEC);
    if (cfd < 0) return lean_io_result_mk_ok(lean_box_uint32(0xFFFFFFFFu));
    struct timeval tv = { .tv_sec = 30, .tv_usec = 0 };
    setsockopt(cfd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(cfd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
    return lean_io_result_mk_ok(lean_box_uint32((uint32_t)cfd));
}

LEAN_EXPORT lean_obj_res orb_node_fd_read(uint32_t fd, size_t max_bytes, lean_obj_arg w) {
    (void)w;
    size_t cap = max_bytes == 0 ? 1 : (max_bytes > 65536 ? 65536 : max_bytes);
    lean_object *ba = lean_alloc_sarray(1, 0, cap);
    ssize_t n = read((int)fd, lean_sarray_cptr(ba), cap);
    if (n < 0) {
        lean_dec_ref(ba);
        return lean_io_result_mk_ok(lean_alloc_sarray(1, 0, 0));
    }
    lean_sarray_set_size(ba, (size_t)n);
    return lean_io_result_mk_ok(ba);
}

LEAN_EXPORT lean_obj_res orb_node_fd_write_all(uint32_t fd, b_lean_obj_arg ba, lean_obj_arg w) {
    (void)w;
    const uint8_t *p = lean_sarray_cptr(ba);
    size_t rem = lean_sarray_size(ba);
    while (rem > 0) {
        ssize_t n = write((int)fd, p, rem);
        if (n > 0) { p += (size_t)n; rem -= (size_t)n; continue; }
        if (n < 0 && errno == EINTR) continue;
        return lean_io_result_mk_ok(lean_box_uint32(1u));
    }
    return lean_io_result_mk_ok(lean_box_uint32(0u));
}

LEAN_EXPORT lean_obj_res orb_node_fd_close(uint32_t fd, lean_obj_arg w) {
    (void)w;
    close((int)fd);
    return lean_io_result_mk_ok(lean_box(0));
}

LEAN_EXPORT lean_obj_res orb_node_spawn_job_pgrp(
    b_lean_obj_arg prog, b_lean_obj_arg args_arr, b_lean_obj_arg env_arr,
    b_lean_obj_arg cwd, b_lean_obj_arg log_path, lean_obj_arg w
) {
    (void)w;
    int log_fd = open(lean_string_cstr(log_path), O_CREAT | O_WRONLY | O_APPEND | O_CLOEXEC, 0600);
    if (log_fd < 0) return lean_io_result_mk_error(lean_mk_io_user_error(lean_mk_string("open log_path failed")));
    pid_t pid = fork();
    if (pid < 0) {
        close(log_fd);
        return lean_io_result_mk_error(lean_mk_io_user_error(lean_mk_string("fork() failed")));
    }
    if (pid == 0) {
        setsid();
        int null_fd = open("/dev/null", O_RDONLY);
        if (null_fd >= 0) { dup2(null_fd, STDIN_FILENO); close(null_fd); }
        dup2(log_fd, STDOUT_FILENO);
        dup2(log_fd, STDERR_FILENO);
        close(log_fd);
        if (lean_string_size(cwd) > 1 && chdir(lean_string_cstr(cwd)) != 0) _exit(126);
        clearenv();
        size_t envc = lean_array_size(env_arr);
        for (size_t i = 0; i + 1 < envc; i += 2)
            setenv(lean_string_cstr(lean_array_get_core(env_arr, i)), lean_string_cstr(lean_array_get_core(env_arr, i + 1)), 1);
        size_t argc = lean_array_size(args_arr);
        char **argv = (char **)calloc(argc + 2, sizeof(char *));
        if (!argv) _exit(126);
        argv[0] = (char *)lean_string_cstr(prog);
        for (size_t i = 0; i < argc; i++) argv[i + 1] = (char *)lean_string_cstr(lean_array_get_core(args_arr, i));
        execvp(argv[0], argv);
        _exit(127);
    }
    close(log_fd);
    return lean_io_result_mk_ok(lean_box_uint64((uint64_t)pid));
}

/* Returns (done ? 1 : 0) | ((uint64_t)(uint32_t)exit_code << 32) */
LEAN_EXPORT lean_obj_res orb_node_poll_pid(uint64_t pid, lean_obj_arg w) {
    (void)w;
    int status = 0;
    pid_t rc = waitpid((pid_t)pid, &status, WNOHANG);
    if (rc == 0) return lean_io_result_mk_ok(lean_box_uint64(0ULL));
    if (rc < 0) return lean_io_result_mk_ok(lean_box_uint64(1ULL | (((uint64_t)0xFFFFFFFFu) << 32)));
    int code = WIFEXITED(status) ? WEXITSTATUS(status) : (WIFSIGNALED(status) ? (128 + WTERMSIG(status)) : 1);
    return lean_io_result_mk_ok(lean_box_uint64(1ULL | (((uint64_t)(uint32_t)code) << 32)));
}

LEAN_EXPORT lean_obj_res orb_node_kill_pgrp(uint64_t pid, uint32_t sig, lean_obj_arg w) {
    (void)w;
    if (pid > 1) kill(-(pid_t)pid, (int)sig);
    return lean_io_result_mk_ok(lean_box(0));
}
