// See OrbLinuxBridge.h. Kernel calls mirror iSH ARM64's own
// AppDelegate.boot and ISHShellExecutor (app/ at OpenMinis/ish-arm64
// e6521d9), minus the terminal UI: Orb only needs headless guest processes.
#include "OrbLinuxBridge.h"

#include <errno.h>
#include <stdlib.h>
#include <string.h>

#ifndef ORB_WITH_ISH

int orb_linux_linked(void) { return 0; }
int orb_linux_import_rootfs(const char *archive_path, const char *root_dir, char **error) {
    (void) archive_path; (void) root_dir;
    if (error) *error = strdup("This Orb build does not include the on-device Linux runtime");
    return -ENOSYS;
}
int orb_linux_boot(const char *root_dir, const char *workspaces_host) { (void) root_dir; (void) workspaces_host; return -ENOSYS; }
void orb_linux_set_exit_callback(orb_linux_exit_cb callback, void *context) { (void) callback; (void) context; }
int orb_linux_spawn(const char *cwd, const char *const *argv, const char *const *envp, int *stdin_fd, int *stdout_fd, int *stderr_fd) {
    (void) cwd; (void) argv; (void) envp; (void) stdin_fd; (void) stdout_fd; (void) stderr_fd;
    return -ENOSYS;
}
int orb_linux_kill(int pid, int signal) { (void) pid; (void) signal; return -ENOSYS; }

#else

#include <fcntl.h>
#include <pthread.h>
#include <resolv.h>
#include <netdb.h>
#include <arpa/inet.h>
#include <unistd.h>

#include "kernel/init.h"
#include "kernel/calls.h"
#include "kernel/task.h"
#include "kernel/fs.h"
#include "kernel/signal.h"
#include "fs/fd.h"
#include "fs/path.h"
#include "fs/real.h"
#include "fs/dev.h"
#include "fs/devices.h"
#include "fs/sock.h"
#include "tools/fakefs.h"

// fs/fake.h is ISH_INTERNAL-only; this is its public bind-mount entry point.
int fakefs_bind_mount(const char *linux_path, const char *host_path, bool read_only);

static pthread_mutex_t boot_lock = PTHREAD_MUTEX_INITIALIZER;
static int booted = 0;
static orb_linux_exit_cb exit_callback;
static void *exit_context;

int orb_linux_linked(void) { return 1; }

int orb_linux_import_rootfs(const char *archive_path, const char *root_dir, char **error) {
    struct fakefsify_error err = {0};
    struct progress progress = {0};
    if (!fakefs_import(archive_path, root_dir, &err, progress)) {
        if (error) *error = err.message ? err.message : strdup("Rootfs import failed");
        return err.code ? -abs(err.code) : -EIO;
    }
    return 0;
}

void orb_linux_set_exit_callback(orb_linux_exit_cb callback, void *context) {
    exit_callback = callback;
    exit_context = context;
}

// Called by the guest kernel with pids_lock held: only report init's children.
static void orb_exit_hook(struct task *task, int code) {
    if (task->parent == NULL || task->parent->parent != NULL) return;
    if (exit_callback) exit_callback(task->pid, code, exit_context);
}

static struct fd *host_fd(int real_fd) {
    struct fd *fd = adhoc_fd_create(&realfs_fdops);
    if (fd) fd->real_fd = real_fd;
    return fd;
}

static void write_resolv_conf(void) {
#ifdef __APPLE__
    struct __res_state res;
    if (res_ninit(&res) != 0) return;
    char buffer[2048] = {0};
    size_t used = 0;
    union res_sockaddr_union servers[8];
    int found = res_getservers(&res, servers, 8);
    for (int i = 0; i < found; i++) {
        if (servers[i].sin.sin_len == 0) continue;
        char address[NI_MAXHOST];
        if (getnameinfo((struct sockaddr *) &servers[i].sin, servers[i].sin.sin_len, address, sizeof(address), NULL, 0, NI_NUMERICHOST) != 0) continue;
        used += (size_t) snprintf(buffer + used, sizeof(buffer) - used, "nameserver %s\n", address);
        if (used >= sizeof(buffer)) break;
    }
    res_ndestroy(&res);
#else
    char buffer[64];
    size_t used = 0;
#endif
    if (used == 0) used = (size_t) snprintf(buffer, sizeof(buffer), "nameserver 1.1.1.1\n");
    struct fd *fd = generic_open("/etc/resolv.conf", O_WRONLY_ | O_CREAT_ | O_TRUNC_, 0644);
    if (!IS_ERR(fd)) {
        fd->ops->write(fd, buffer, strlen(buffer));
        fd_close(fd);
    }
}

int orb_linux_boot(const char *root_dir, const char *workspaces_host) {
    pthread_mutex_lock(&boot_lock);
    if (booted) { pthread_mutex_unlock(&boot_lock); return 0; }
    char data[4096];
    snprintf(data, sizeof(data), "%s/data", root_dir);
    int err = mount_root(&fakefs, data);
    if (err < 0) goto out;
    err = become_first_process();
    if (err < 0) goto out;

    generic_mknodat(AT_PWD, "/dev/null", S_IFCHR | 0666, dev_make(MEM_MAJOR, DEV_NULL_MINOR));
    generic_mknodat(AT_PWD, "/dev/zero", S_IFCHR | 0666, dev_make(MEM_MAJOR, DEV_ZERO_MINOR));
    generic_mknodat(AT_PWD, "/dev/random", S_IFCHR | 0666, dev_make(MEM_MAJOR, DEV_RANDOM_MINOR));
    generic_mknodat(AT_PWD, "/dev/urandom", S_IFCHR | 0666, dev_make(MEM_MAJOR, DEV_URANDOM_MINOR));
    generic_mknodat(AT_PWD, "/dev/tty", S_IFCHR | 0666, dev_make(TTY_ALTERNATE_MAJOR, DEV_TTY_MINOR));
    generic_mknodat(AT_PWD, "/dev/ptmx", S_IFCHR | 0666, dev_make(TTY_ALTERNATE_MAJOR, DEV_PTMX_MINOR));
    generic_mkdirat(AT_PWD, "/dev/pts", 0755);
    generic_mkdirat(AT_PWD, "/root/work", 0755);
    do_mount(&procfs, "proc", "/proc", "", 0);
    do_mount(&devptsfs, "devpts", "/dev/pts", "", 0);
    if (workspaces_host && *workspaces_host) fakefs_bind_mount("/root/work", workspaces_host, false);
    write_resolv_conf();

    exit_hook = orb_exit_hook;
    char sock_tmp[1024];
    const char *tmp = getenv("TMPDIR");
    snprintf(sock_tmp, sizeof(sock_tmp), "%s/orbsock", tmp ? tmp : "/tmp");
    sock_tmp_prefix = strdup(sock_tmp);

    // pid 1: a quiet init with host /dev/null stdio. Agent processes are its
    // children, so exit notifications are delivered through orb_exit_hook.
    int null_fd = open("/dev/null", O_RDWR);
    struct task *init = current;
    for (int i = 0; i < 3; i++) init->files->files[i] = host_fd(dup(null_fd));
    close(null_fd);
    static const char argv[] = "/bin/sh\0-c\0trap '' HUP INT TERM; while :; do sleep 86400; done\0";
    static const char envp[] = "HOME=/root\0PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\0";
    err = do_execve("/bin/sh", 3, argv, envp);
    if (err < 0) goto out;
    task_start(init);
    booted = 1;
out:
    pthread_mutex_unlock(&boot_lock);
    return err;
}

static int append(char **buf, size_t *len, size_t *cap, const char *s) {
    size_t n = strlen(s) + 1;
    if (*len + n + 1 > *cap) {
        size_t next = (*cap ? *cap * 2 : 4096);
        while (next < *len + n + 1) next *= 2;
        char *grown = realloc(*buf, next);
        if (!grown) return -ENOMEM;
        *buf = grown; *cap = next;
    }
    memcpy(*buf + *len, s, n);
    *len += n;
    return 0;
}

int orb_linux_spawn(const char *cwd, const char *const *argv, const char *const *envp,
                    int *stdin_fd, int *stdout_fd, int *stderr_fd) {
    if (!booted) return -ENODEV;
    int in[2] = {-1, -1}, out[2] = {-1, -1}, errp[2] = {-1, -1};
    char *args = NULL, *env = NULL;
    size_t alen = 0, acap = 0, elen = 0, ecap = 0, argc = 0;
    int result = -ENOMEM;
    if (pipe(in) < 0 || pipe(out) < 0 || pipe(errp) < 0) { result = -errno; goto fail; }

    const char *prefix[] = {"/bin/sh", "-c", "cd \"$1\" && shift && exec \"$@\"", "orb", cwd};
    for (size_t i = 0; i < 5; i++, argc++) if (append(&args, &alen, &acap, prefix[i])) goto fail;
    for (size_t i = 0; argv[i]; i++, argc++) if (append(&args, &alen, &acap, argv[i])) goto fail;
    if (append(&args, &alen, &acap, "")) goto fail;
    const char *defaults[] = {"HOME=/root", "TERM=xterm-256color", "LANG=C.UTF-8",
                              "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin", NULL};
    for (size_t i = 0; defaults[i]; i++) if (append(&env, &elen, &ecap, defaults[i])) goto fail;
    for (size_t i = 0; envp && envp[i]; i++) if (append(&env, &elen, &ecap, envp[i])) goto fail;
    if (append(&env, &elen, &ecap, "")) goto fail;

    struct task *saved = current;
    result = become_new_init_child();
    if (result < 0) { current = saved; goto fail; }
    struct task *task = current;
    task->files->files[0] = host_fd(in[0]);
    task->files->files[1] = host_fd(out[1]);
    task->files->files[2] = host_fd(errp[1]);
    in[0] = out[1] = errp[1] = -1; // now owned by the guest fds
    result = do_execve("/bin/sh", argc, args, env);
    if (result < 0) { current = saved; goto fail; }
    int pid = task->pid;
    task_start(task);
    current = saved;
    free(args); free(env);
    *stdin_fd = in[1];
    *stdout_fd = out[0];
    *stderr_fd = errp[0];
    return pid;
fail:
    for (int i = 0; i < 2; i++) {
        if (in[i] >= 0) close(in[i]);
        if (out[i] >= 0) close(out[i]);
        if (errp[i] >= 0) close(errp[i]);
    }
    free(args); free(env);
    return result;
}

int orb_linux_kill(int pid, int signal) {
    struct siginfo_ info = SIGINFO_NIL;
    lock(&pids_lock);
    struct task *task = pid_get_task((dword_t) pid);
    if (task) send_signal(task, signal, info);
    unlock(&pids_lock);
    return task ? 0 : -ESRCH;
}

#endif
