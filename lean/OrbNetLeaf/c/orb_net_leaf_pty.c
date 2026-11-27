/*
  orb_net_leaf_pty.c: Spawn an interactive shell child attached to an allocated
  PTY slave descriptor (setsid + TIOCSCTTY + dup2 0/1/2 + chdir + exec).
  Kept strictly under the 220-LOC C shim ceiling.
*/
#ifndef __APPLE__
#define _GNU_SOURCE
#endif
#include <lean/lean.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

static inline const char *pty_cstr(b_lean_obj_arg s) {
  const char *p = lean_string_cstr(s);
  return strlen(p) == lean_string_size(s) - 1 ? p : NULL;
}

static inline lean_obj_res pty_pack(int64_t rc) {
  uint64_t word = rc < 0
    ? ((1ULL << 63) | ((uint64_t)(uint32_t)(errno ? errno : EIO) << 32))
    : ((uint64_t)rc & 0x7FFFFFFFFFFFFFFFULL);
  return lean_io_result_mk_ok(lean_box_uint64(word));
}

LEAN_EXPORT lean_obj_res orb_net_leaf_pty_spawn(uint32_t slave_fd, b_lean_obj_arg cwd_obj, b_lean_obj_arg shell_obj) {
  const char *cwd = pty_cstr(cwd_obj);
  const char *shell = pty_cstr(shell_obj);
  if (!cwd || !shell) {
    errno = EINVAL;
    return pty_pack(-1);
  }
  if (shell[0] == '\0') {
    shell = "/bin/sh";
  }
  pid_t pid = fork();
  if (pid < 0) {
    return pty_pack(-1);
  }
  if (pid == 0) {
    (void)signal(SIGPIPE, SIG_DFL);
    (void)signal(SIGINT, SIG_DFL);
    (void)signal(SIGTERM, SIG_DFL);
    (void)setsid();
    (void)ioctl((int)slave_fd, TIOCSCTTY, 0);
    int flags = fcntl((int)slave_fd, F_GETFL, 0);
    if (flags >= 0) {
      (void)fcntl((int)slave_fd, F_SETFL, flags & ~O_NONBLOCK);
    }
    if ((int)slave_fd != 0) (void)dup2((int)slave_fd, 0);
    if ((int)slave_fd != 1) (void)dup2((int)slave_fd, 1);
    if ((int)slave_fd != 2) (void)dup2((int)slave_fd, 2);
    if ((int)slave_fd > 2) (void)close((int)slave_fd);
    if (cwd[0] != '\0') {
      if (chdir(cwd) != 0) {}
    }
    (void)setenv("TERM", "xterm-256color", 0);
    execl(shell, shell, "-i", (char *)NULL);
    execl("/bin/sh", "sh", "-i", (char *)NULL);
    _exit(127);
  }
  return pty_pack((int64_t)(uint32_t)pid);
}
