#ifndef ORB_NODE_SPAWN_READY_H
#define ORB_NODE_SPAWN_READY_H
#include <pthread.h>

/* Reserve a reaper before fork. On failure the caller never waits for a child
 * stuck in the kernel; this worker retains ownership until waitpid completes.
 * On success Runner owns waitpid and the worker exits without touching it. */
struct orb_spawn_reaper {
    pthread_mutex_t lock;
    pthread_cond_t wake;
    pid_t pid;
    int released;
};
static void *orb_spawn_reap(void *arg) {
    struct orb_spawn_reaper *r = arg;
    pthread_mutex_lock(&r->lock);
    while (!r->released) pthread_cond_wait(&r->wake, &r->lock);
    pid_t pid = r->pid;
    pthread_mutex_unlock(&r->lock);
    if (pid > 0) {
        int status;
        while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
    }
    pthread_cond_destroy(&r->wake);
    pthread_mutex_destroy(&r->lock);
    free(r);
    return NULL;
}
static struct orb_spawn_reaper *orb_spawn_reserve_reaper(void) {
    struct orb_spawn_reaper *r = calloc(1, sizeof(*r));
    if (!r) return NULL;
    int err = pthread_mutex_init(&r->lock, NULL);
    if (err) { free(r); errno = err; return NULL; }
    err = pthread_cond_init(&r->wake, NULL);
    if (err) { pthread_mutex_destroy(&r->lock); free(r); errno = err; return NULL; }
    pthread_attr_t attr;
    err = pthread_attr_init(&attr);
    if (!err) {
        err = pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
        pthread_t thread;
        if (!err) err = pthread_create(&thread, &attr, orb_spawn_reap, r);
        pthread_attr_destroy(&attr);
    }
    if (err) {
        pthread_cond_destroy(&r->wake); pthread_mutex_destroy(&r->lock);
        free(r); errno = err; return NULL;
    }
    return r;
}
static void orb_spawn_release_reaper(struct orb_spawn_reaper *r, pid_t pid) {
    pthread_mutex_lock(&r->lock);
    r->pid = pid;
    r->released = 1;
    pthread_cond_signal(&r->wake);
    pthread_mutex_unlock(&r->lock);
}

/* Session readiness is distinct from PID/start-tick identity. The child must
 * publish successful setsid before the parent exposes its group to Runner.
 * No exec-status handshake: existing command exit codes 126/127 stay intact. */
static int orb_ready_pipe(int fd[2]) {
    if (pipe(fd) < 0) return -1;
    if (fcntl(fd[0], F_SETFD, FD_CLOEXEC) < 0 ||
        fcntl(fd[1], F_SETFD, FD_CLOEXEC) < 0) {
        int err = errno;
        close(fd[0]); close(fd[1]); errno = err;
        return -1;
    }
    return 0;
}

static void orb_child_ready(int fd[2]) {
    close(fd[0]);
    int err = setsid() < 0 ? errno : 0;
    ssize_t n = write(fd[1], &err, sizeof(err));
    close(fd[1]);
    if (err || n != sizeof(err)) _exit(126);
}

static int orb_parent_ready(int fd[2], pid_t pid) {
    close(fd[1]);
    struct pollfd p = { .fd = fd[0], .events = POLLIN };
    /* EINTR is a setup failure, not an unbounded restart of the deadline. */
    int rc = poll(&p, 1, 5000), err = 0;
    if (rc < 0) err = errno;
    else if (rc == 0) err = ETIMEDOUT;
    else if (!(p.revents & POLLIN) || read(fd[0], &err, sizeof(err)) != sizeof(err)) err = EIO;
    close(fd[0]);
    if (!err) return 0;
    /* Our unreaped fork child cannot have been recycled. Never kill its
     * inherited group. The reserved worker owns reaping after failure. */
    kill(pid, SIGKILL);
    return err;
}

static pid_t orb_spawn_session(void) {
    int fd[2];
    if (orb_ready_pipe(fd)) return -1;
    struct orb_spawn_reaper *r = orb_spawn_reserve_reaper();
    if (!r) { int err = errno; close(fd[0]); close(fd[1]); errno = err; return -1; }
    pid_t pid = fork();
    if (pid == 0) { orb_child_ready(fd); return 0; }
    int err = errno;
    if (pid < 0) { close(fd[0]); close(fd[1]); }
    else err = orb_parent_ready(fd, pid);
    orb_spawn_release_reaper(r, pid > 0 && err ? pid : 0);
    if (pid < 0 || err) { errno = err; return -1; }
    return pid;
}

#endif
