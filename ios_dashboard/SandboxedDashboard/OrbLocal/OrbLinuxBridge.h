// Orb ↔ iSH ARM64 bridge.
//
// iOS forbids fork/exec/posix_spawn for App Store and TestFlight apps, and it
// forbids JIT. OpenMinis' iSH ARM64 fork (https://github.com/OpenMinis/ish-arm64,
// GPLv3 + App Store exception) runs an AArch64 Alpine userland inside the app
// process with a threaded-code interpreter that never emits machine code.
// Guest processes are guest tasks (threads in Orb), guest sockets are host
// sockets, and guest fork/exec/pipes/ptys are emulated by its kernel layer.
//
// This header is the only surface Swift uses. When Orb is built without the
// iSH static libraries (ORB_WITH_ISH undefined), every call reports -ENOSYS
// and the runtime is reported as unavailable instead of faked.
#ifndef ORB_LINUX_BRIDGE_H
#define ORB_LINUX_BRIDGE_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/// 1 when the interpreter is linked into this build.
int orb_linux_linked(void);

/// Import an Alpine aarch64 minirootfs tarball into a fakefs root at
/// `root_dir` (creates `root_dir/data` + `root_dir/meta.db`). Returns 0 or a
/// negative error; `error` receives a message (caller frees with free()).
int orb_linux_import_rootfs(const char *archive_path, const char *root_dir, char **error);

/// Boot the guest kernel on the fakefs root. Idempotent. Writes resolv.conf
/// from the host resolver and binds `workspaces_host` at `/root/work`.
int orb_linux_boot(const char *root_dir, const char *workspaces_host);

/// Exit callback: guest pid and raw wait status (`code << 8`, or signal).
typedef void (*orb_linux_exit_cb)(int pid, int status, void *context);
void orb_linux_set_exit_callback(orb_linux_exit_cb callback, void *context);

/// Start `/bin/sh -c 'cd "$1" && shift && exec "$@"' orb <cwd> <argv...>`
/// inside the guest. `argv`/`envp` are NULL-terminated. On success returns
/// the guest pid and sets host pipe fds: `stdin_fd` (write end), `stdout_fd`
/// and `stderr_fd` (read ends). The caller owns and closes the fds.
int orb_linux_spawn(const char *cwd, const char *const *argv, const char *const *envp,
                    int *stdin_fd, int *stdout_fd, int *stderr_fd);

/// Deliver a guest signal (2 = SIGINT, 9 = SIGKILL, 15 = SIGTERM).
int orb_linux_kill(int pid, int signal);

#ifdef __cplusplus
}
#endif

#endif
