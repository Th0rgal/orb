#define _GNU_SOURCE
#include <assert.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

static int mode;
static int reap_notice[2], notify_reap;
static pid_t test_waitpid(pid_t pid, int *status, int options) {
    pid_t rc = waitpid(pid, status, options);
    if (notify_reap && rc > 0) assert(write(reap_notice[1], &rc, sizeof(rc)) == sizeof(rc));
    return rc;
}
static pid_t test_setsid(void) {
    if (notify_reap && mode == 1) { errno = EPERM; return -1; }
    if (notify_reap && mode == 2) _exit(125);
    return setsid();
}
static int test_poll(struct pollfd *fds, nfds_t n, int ms) {
    if (mode == 3) return 0;
    if (mode == 4) { errno = EINTR; return -1; }
    return poll(fds, n, ms);
}
#define poll test_poll
#define waitpid test_waitpid
#define setsid test_setsid
#include "../c/spawn_ready.h"
#undef poll
#undef waitpid
#undef setsid

static int fd_count(void) {
    DIR *dir = opendir("/proc/self/fd");
    assert(dir);
    int n = 0;
    while (readdir(dir)) n++;
    closedir(dir);
    return n;
}

int main(void) {
    alarm(15);
    int before = fd_count();
    for (mode = 0; mode < 7; mode++) {
        int ready[2];
        assert(orb_ready_pipe(ready) == 0);
        pid_t pid = fork();
        assert(pid >= 0);
        if (pid == 0) {
            if (mode == 1) assert(setpgid(0, 0) == 0); /* setsid must fail */
            if (mode == 2) _exit(125); /* EOF without acknowledgment */
            if (mode == 5) { close(ready[0]); assert(write(ready[1], "x", 1) == 1); _exit(125); }
            if (mode == 6) pause(); /* Real readiness deadline, no injected poll. */
            orb_child_ready(ready);
            pause();
            _exit(0);
        }
        struct timespec start, stop;
        assert(clock_gettime(CLOCK_MONOTONIC, &start) == 0);
        int err = orb_parent_ready(ready, pid), status;
        assert(clock_gettime(CLOCK_MONOTONIC, &stop) == 0);
        if (mode == 0) {
            assert(err == 0 && getpgid(pid) == pid && getsid(pid) == pid);
            assert(kill(-pid, SIGKILL) == 0);
            assert(waitpid(pid, &status, 0) == pid);
        } else {
            int expected = mode == 1 ? EPERM : (mode == 3 || mode == 6) ? ETIMEDOUT : mode == 4 ? EINTR : EIO;
            assert(err == expected);
            assert(waitpid(pid, &status, 0) == pid);
            assert(waitpid(pid, &status, WNOHANG) == -1 && errno == ECHILD);
        }
        assert(fd_count() == before);
        printf("ready case=%d errno=%d reaped=1 fds_stable=1\n", mode, err);
        if (mode == 6) {
            double elapsed = stop.tv_sec - start.tv_sec + (stop.tv_nsec - start.tv_nsec) / 1e9;
            assert(elapsed >= 4.9 && elapsed < 7.0);
            printf("real readiness timeout elapsed=%.3fs\n", elapsed);
        }
    }
    /* Observe the actual reserved worker completing waitpid, without sleeps
     * or polling loops. The pipe event precedes the thread's memory cleanup. */
    assert(pipe(reap_notice) == 0);
    notify_reap = 1;
    for (mode = 1; mode < 5; mode++) {
        assert(orb_spawn_session() == -1);
        struct pollfd event = { .fd = reap_notice[0], .events = POLLIN };
        assert(poll(&event, 1, 2000) == 1);
        pid_t reaped;
        assert(read(reap_notice[0], &reaped, sizeof(reaped)) == sizeof(reaped));
        int status;
        assert(waitpid(reaped, &status, WNOHANG) == -1 && errno == ECHILD);
        printf("reserved-reaper case=%d pid=%d completed=1\n", mode, reaped);
    }
    close(reap_notice[0]); close(reap_notice[1]);
    assert(fd_count() == before);
    notify_reap = 0;
    mode = 0;
    for (int expected = 0; expected <= 127; expected += expected == 0 ? 126 : 1) {
        pid_t pid = orb_spawn_session();
        assert(pid >= 0);
        if (pid == 0) _exit(expected);
        int status;
        assert(waitpid(pid, &status, 0) == pid);
        assert(WIFEXITED(status) && WEXITSTATUS(status) == expected);
        printf("successful handoff preserves exit=%d and parent wait ownership\n", expected);
    }
    assert(fd_count() == before);
    return 0;
}
