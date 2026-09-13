// Commands the app asks for, each in its own process group and each with a
// deadline.
//
// Nothing here ever waits for a command in a way the rest cannot get past: a
// command that hangs is sent SIGTERM at its deadline, SIGKILL three seconds
// later, and if it is still there after that — stuck inside the kernel, the way
// `ps` got stuck on a busy guest — it is written off and the channel goes on.
#import "agent.h"
#include <errno.h>
#include <fcntl.h>
#include <float.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

#define MAX_JOBS 64
#define MAX_STUCK 64
// A finished job waits this long for the app to collect it.
#define RETAIN_SECONDS 600
#define RETAIN_BYTES (8 * 1024 * 1024)
#define MAX_OUTPUT (512 * 1024)

typedef struct {
    char id[80];
    pid_t pid;
    int fd;
    uint8_t *out;
    size_t used, capacity, limit;
    bool truncated;
    double started, deadline, kill_at, finished;
    int stage;  // 0 running, 1 SIGTERM sent, 2 SIGKILL sent
    bool done, exited, timed_out, stuck;
    int status, signal_number;
} Job;

static Job *jobs[MAX_JOBS];
static pid_t stuck[MAX_STUCK];

static char *const job_environment[] = {
    "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
    "HOME=/var/root",
    "USER=root",
    "LOGNAME=root",
    "SHELL=/bin/bash",
    "TMPDIR=/tmp",
    "TERM=dumb",
    NULL,
};

void jobs_init(void) {}

static NSString *string_field(id value) { return [value isKindOfClass:[NSString class]] ? value : nil; }

static double number_field(id value, double fallback)
{
    return [value isKindOfClass:[NSNumber class]] ? [value doubleValue] : fallback;
}

static Job *find_job(NSString *identifier)
{
    const char *wanted = identifier.UTF8String;
    for (int i = 0; i < MAX_JOBS; i++) {
        if (jobs[i] && strcmp(jobs[i]->id, wanted) == 0) { return jobs[i]; }
    }
    return NULL;
}

static void free_job(int slot)
{
    Job *job = jobs[slot];
    if (!job) { return; }
    if (job->fd >= 0) { close(job->fd); }
    free(job->out);
    free(job);
    jobs[slot] = NULL;
}

// Old results go first when there is no room, then any result past its time.
static void evict(bool need_slot)
{
    double now = now_seconds();
    size_t bytes = 0;
    int oldest = -1;
    for (int i = 0; i < MAX_JOBS; i++) {
        Job *job = jobs[i];
        if (!job) { continue; }
        if (job->done && now - job->finished > RETAIN_SECONDS) {
            free_job(i);
            continue;
        }
        bytes += job->capacity;
        if (job->done && (oldest < 0 || job->finished < jobs[oldest]->finished)) { oldest = i; }
    }
    if (oldest >= 0 && (need_slot || bytes > RETAIN_BYTES)) { free_job(oldest); }
}

static Job *spawn_job(NSString *identifier, NSString *command, double timeout, size_t limit, NSString **error)
{
    int slot = -1;
    for (int attempt = 0; attempt < 2 && slot < 0; attempt++) {
        for (int i = 0; i < MAX_JOBS; i++) {
            if (!jobs[i]) {
                slot = i;
                break;
            }
        }
        if (slot < 0) { evict(true); }
    }
    if (slot < 0) {
        *error = @"too many jobs";
        return NULL;
    }

    int fds[2];
    if (pipe(fds) != 0) {
        *error = [NSString stringWithFormat:@"pipe: %s", strerror(errno)];
        return NULL;
    }
    fcntl(fds[0], F_SETFD, FD_CLOEXEC);
    fcntl(fds[1], F_SETFD, FD_CLOEXEC);
    fcntl(fds[0], F_SETFL, O_NONBLOCK);

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0);
    posix_spawn_file_actions_adddup2(&actions, fds[1], 1);
    posix_spawn_file_actions_adddup2(&actions, fds[1], 2);

    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    sigset_t none, defaults;
    sigemptyset(&none);
    sigfillset(&defaults);
    sigdelset(&defaults, SIGKILL);
    sigdelset(&defaults, SIGSTOP);
    posix_spawnattr_setsigmask(&attr, &none);
    posix_spawnattr_setsigdefault(&attr, &defaults);
    // A group of its own, so that the deadline takes the command's children too.
    posix_spawnattr_setpgroup(&attr, 0);
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF
                                        | POSIX_SPAWN_CLOEXEC_DEFAULT);

    const char *shell = access("/bin/bash", X_OK) == 0 ? "/bin/bash" : "/bin/sh";
    const char *argv[] = {shell, "-c", command.UTF8String, NULL};
    pid_t pid = 0;
    int rc = posix_spawn(&pid, shell, &actions, &attr, (char *const *)argv, job_environment);
    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attr);
    close(fds[1]);
    if (rc != 0) {
        close(fds[0]);
        *error = [NSString stringWithFormat:@"spawn: %s", strerror(rc)];
        return NULL;
    }

    Job *job = calloc(1, sizeof *job);
    strlcpy(job->id, identifier.UTF8String, sizeof job->id);
    job->pid = pid;
    job->fd = fds[0];
    job->limit = limit;
    job->started = now_seconds();
    job->deadline = timeout > 0 ? job->started + timeout : DBL_MAX;
    jobs[slot] = job;
    return job;
}

static void read_output(Job *job)
{
    if (job->fd < 0) { return; }
    uint8_t chunk[16384];
    for (;;) {
        ssize_t n = read(job->fd, chunk, sizeof chunk);
        if (n == 0) {
            close(job->fd);
            job->fd = -1;
            return;
        }
        if (n < 0) {
            if (errno == EINTR) { continue; }
            return;
        }
        size_t room = job->limit > job->used ? job->limit - job->used : 0;
        size_t take = (size_t)n < room ? (size_t)n : room;
        if (take < (size_t)n) { job->truncated = true; }
        if (take == 0) { continue; }
        if (job->used + take > job->capacity) {
            size_t grown = job->capacity ? job->capacity : 4096;
            while (grown < job->used + take) { grown *= 2; }
            if (grown > job->limit) { grown = job->limit; }
            uint8_t *bigger = realloc(job->out, grown);
            if (!bigger) {
                job->truncated = true;
                continue;
            }
            job->out = bigger;
            job->capacity = grown;
        }
        memcpy(job->out + job->used, chunk, take);
        job->used += take;
    }
}

static void remember_stuck(pid_t pid)
{
    for (int i = 0; i < MAX_STUCK; i++) {
        if (stuck[i] == 0) {
            stuck[i] = pid;
            return;
        }
    }
}

static void check_job(Job *job, double now)
{
    if (job->done) { return; }
    int status = 0;
    pid_t reaped = waitpid(job->pid, &status, WNOHANG);
    if (reaped == job->pid) {
        job->exited = true;
        if (WIFEXITED(status)) {
            job->status = WEXITSTATUS(status);
        } else if (WIFSIGNALED(status)) {
            job->signal_number = WTERMSIG(status);
            job->status = 128 + job->signal_number;
        }
    } else if (reaped < 0 && errno == ECHILD) {
        job->exited = true;
        job->status = -1;
    }

    if (job->exited) {
        // What it printed before exiting is still in the pipe. A child it left
        // running in the background may hold the other end open for ever, so the
        // pipe is drained and closed rather than waited on.
        read_output(job);
        if (job->fd >= 0) {
            close(job->fd);
            job->fd = -1;
        }
        job->done = true;
        job->finished = now;
        return;
    }

    if (job->stage == 0 && now >= job->deadline) {
        job->timed_out = true;
        kill(-job->pid, SIGTERM);
        kill(job->pid, SIGTERM);
        job->stage = 1;
        job->kill_at = now + 3;
        agent_log("job %s: past its deadline after %.0f s, terminating", job->id, now - job->started);
    } else if (job->stage == 1 && now >= job->kill_at) {
        kill(-job->pid, SIGKILL);
        kill(job->pid, SIGKILL);
        job->stage = 2;
        job->kill_at = now + 15;
    } else if (job->stage == 2 && now >= job->kill_at) {
        agent_log("job %s: pid %d survives SIGKILL, written off", job->id, job->pid);
        job->stuck = true;
        job->done = true;
        job->finished = now;
        job->status = -1;
        if (job->fd >= 0) {
            close(job->fd);
            job->fd = -1;
        }
        remember_stuck(job->pid);
    }
}

void jobs_pump(double seconds, NSString *until)
{
    double end = now_seconds() + seconds;
    const char *target = until.UTF8String;
    for (;;) {
        double now = now_seconds();
        struct pollfd fds[MAX_JOBS];
        int count = 0;
        bool running = false, target_done = false;
        for (int i = 0; i < MAX_JOBS; i++) {
            Job *job = jobs[i];
            if (!job) { continue; }
            check_job(job, now);
            if (!job->done) {
                running = true;
                if (job->fd >= 0) { fds[count++] = (struct pollfd){job->fd, POLLIN, 0}; }
            } else if (target && strcmp(job->id, target) == 0) {
                target_done = true;
            }
        }
        for (int i = 0; i < MAX_STUCK; i++) {
            if (stuck[i] && waitpid(stuck[i], NULL, WNOHANG) != 0) { stuck[i] = 0; }
        }
        evict(false);

        if (target_done || now >= end) { return; }
        // Exits are found by asking, so with anything running the wait is short.
        double wait = end - now;
        if (running && wait > 0.1) { wait = 0.1; }
        if (count > 0) {
            poll(fds, (nfds_t)count, (int)(wait * 1000));
            for (int i = 0; i < MAX_JOBS; i++) {
                if (jobs[i] && !jobs[i]->done) { read_output(jobs[i]); }
            }
        } else {
            usleep((useconds_t)(wait * 1e6));
        }
    }
}

static NSDictionary *describe(Job *job)
{
    double end = job->done ? job->finished : now_seconds();
    NSMutableDictionary *answer = [@{
        @"ok" : @YES,
        @"id" : @(job->id),
        @"state" : job->done ? @"done" : @"running",
        @"elapsed" : @(end - job->started),
    } mutableCopy];
    if (job->done) {
        answer[@"status"] = @(job->status);
        answer[@"signal"] = @(job->signal_number);
        answer[@"timedOut"] = @(job->timed_out);
        answer[@"stuck"] = @(job->stuck);
        answer[@"truncated"] = @(job->truncated);
        answer[@"out"] = lossy_string(job->out, job->used);
    }
    return answer;
}

static NSDictionary *failure(NSString *why) { return @{@"ok" : @NO, @"error" : why}; }

NSDictionary *jobs_exec(NSDictionary *request)
{
    NSString *identifier = string_field(request[@"id"]);
    NSString *command = string_field(request[@"cmd"]);
    if (identifier.length == 0 || identifier.length > 64 || !command) { return failure(@"exec needs id and cmd"); }

    // The same id twice is the app asking again after an answer went missing,
    // not a second command: the first one is not run again.
    Job *job = find_job(identifier);
    if (!job) {
        double timeout = number_field(request[@"timeout"], 60);
        double limit = number_field(request[@"max"], 65536);
        if (limit < 0) { limit = 0; }
        if (limit > MAX_OUTPUT) { limit = MAX_OUTPUT; }
        NSString *error = nil;
        job = spawn_job(identifier, command, timeout, (size_t)limit, &error);
        if (!job) { return failure(error); }
        agent_log("job %s: pid %d, %.0f s: %.160s", job->id, job->pid, timeout, command.UTF8String);
    }

    double wait = number_field(request[@"wait"], 0);
    if (wait > 10) { wait = 10; }
    if (wait > 0) { jobs_pump(wait, identifier); }
    job = find_job(identifier);
    return job ? describe(job) : failure(@"job vanished");
}

NSDictionary *jobs_poll(NSDictionary *request)
{
    NSString *identifier = string_field(request[@"id"]);
    if (identifier.length == 0) { return failure(@"poll needs id"); }
    Job *job = find_job(identifier);
    if (!job) { return @{@"ok" : @NO, @"error" : @"unknown job", @"unknown" : @YES}; }

    double wait = number_field(request[@"wait"], 0);
    if (wait > 10) { wait = 10; }
    if (wait > 0 && !job->done) { jobs_pump(wait, identifier); }
    job = find_job(identifier);
    if (!job) { return @{@"ok" : @NO, @"error" : @"unknown job", @"unknown" : @YES}; }

    NSDictionary *answer = describe(job);
    if (job->done && [request[@"forget"] boolValue]) {
        for (int i = 0; i < MAX_JOBS; i++) {
            if (jobs[i] == job) { free_job(i); }
        }
    }
    return answer;
}

NSDictionary *jobs_kill(NSDictionary *request)
{
    NSString *identifier = string_field(request[@"id"]);
    Job *job = identifier ? find_job(identifier) : NULL;
    if (!job) { return @{@"ok" : @NO, @"error" : @"unknown job", @"unknown" : @YES}; }
    if (!job->done && job->stage == 0) {
        job->deadline = now_seconds();
        check_job(job, now_seconds());
    }
    return describe(job);
}

NSDictionary *jobs_summary(void)
{
    int running = 0, done = 0;
    for (int i = 0; i < MAX_JOBS; i++) {
        if (!jobs[i]) { continue; }
        if (jobs[i]->done) {
            done++;
        } else {
            running++;
        }
    }
    return @{@"running" : @(running), @"done" : @(done)};
}

bool jobs_busy(void)
{
    for (int i = 0; i < MAX_JOBS; i++) {
        if (jobs[i] && !jobs[i]->done) { return true; }
    }
    return false;
}
