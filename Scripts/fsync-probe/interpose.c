// Counts the flush requests a process makes: fsync(), fcntl(F_FULLFSYNC), and
// fcntl(F_BARRIERFSYNC). Loaded with DYLD_INSERT_LIBRARIES into RelayBench (an
// unsigned, non-hardened command-line binary) by Scripts/fsync-probe.sh. Diagnostic
// only; nothing in the app uses it.
#include <fcntl.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdio.h>
#include <unistd.h>

static atomic_int full_count, barrier_count, fsync_count;

static int counting_fcntl(int fd, int cmd, ...) {
    va_list args;
    va_start(args, cmd);
    void *argument = va_arg(args, void *);
    va_end(args);
    if (cmd == F_FULLFSYNC) atomic_fetch_add(&full_count, 1);
    if (cmd == F_BARRIERFSYNC) atomic_fetch_add(&barrier_count, 1);
    return fcntl(fd, cmd, argument);
}

static int counting_fsync(int fd) {
    atomic_fetch_add(&fsync_count, 1);
    return fsync(fd);
}

__attribute__((destructor)) static void report(void) {
    fprintf(stderr, "fsync-probe: F_FULLFSYNC=%d F_BARRIERFSYNC=%d fsync=%d\n",
            atomic_load(&full_count), atomic_load(&barrier_count), atomic_load(&fsync_count));
}

__attribute__((used)) static struct { const void *replacement; const void *replacee; } interposers[]
    __attribute__((section("__DATA,__interpose"))) = {
        { (const void *)counting_fcntl, (const void *)fcntl },
        { (const void *)counting_fsync, (const void *)fsync },
    };
