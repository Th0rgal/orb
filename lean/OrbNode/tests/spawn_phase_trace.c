#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <signal.h>
#include <poll.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

/* Diagnostic only: LD_PRELOAD into the focused executable, never production.
 * A pipe schedules the actual spawn child before setsid until both original
 * group signals have been attempted. No replacement spawn or timed delay. */
static int gate[2];
static pid_t owner, target;
static const char *mode;
__attribute__((constructor)) static void init(void) {
    owner = getpid();
    mode = getenv("ORB_TEST_READY_MODE");
    if (pipe(gate)) abort();
}
pid_t setsid(void) {
    pid_t (*real_setsid)(void) = dlsym(RTLD_NEXT, "setsid");
    if (getppid() == owner) {
        if (mode && !strcmp(mode, "fail")) { errno = EPERM; return -1; }
        if (mode && !strcmp(mode, "eof")) _exit(125);
        char c;
        dprintf(2, "TRACE pre-setsid pid=%d pgid=%d sid=%d\n", getpid(), getpgrp(), getsid(0));
        alarm(5);
        if (read(gate[0], &c, 1) != 1) _exit(125);
        alarm(0);
    }
    pid_t rc = real_setsid();
    dprintf(2, "TRACE post-setsid pid=%d pgid=%d sid=%d rc=%d\n", getpid(), getpgrp(), getsid(0), rc);
    return rc;
}
int poll(struct pollfd *fds, nfds_t count, int ms) {
    int (*real_poll)(struct pollfd *, nfds_t, int) = dlsym(RTLD_NEXT, "poll");
    if (getpid() == owner && mode && count == 1 && ms == 5000) {
        if (!strcmp(mode, "timeout")) return 0;
        if (!strcmp(mode, "eintr")) { errno = EINTR; return -1; }
        if (!strcmp(mode, "ready") && write(gate[1], "r", 1) != 1) abort();
    }
    return real_poll(fds, count, ms);
}
int kill(pid_t pid, int sig) {
    int (*real_kill)(pid_t, int) = dlsym(RTLD_NEXT, "kill");
    int rc = real_kill(pid, sig), err = errno;
    if (getpid() == owner && pid < -1) {
        target = -pid;
        dprintf(2, "TRACE signal target=%d pgid=%d sig=%d rc=%d errno=%d\n", pid, getpgid(-pid), sig, rc, rc ? err : 0);
        if (sig == SIGKILL && write(gate[1], "r", 1) != 1) abort();
    }
    errno = err;
    return rc;
}
__attribute__((destructor)) static void cleanup(void) {
    if (getpid() == owner && target > 1) {
        int (*real_kill)(pid_t, int) = dlsym(RTLD_NEXT, "kill");
        /* Unreaped direct child: PID cannot be reused before waitpid. */
        int status;
        if (waitpid(target, &status, WNOHANG) == 0) {
            real_kill(target, SIGKILL);
            alarm(5);
            waitpid(target, &status, 0);
            alarm(0);
        }
    }
    close(gate[0]); close(gate[1]);
}
