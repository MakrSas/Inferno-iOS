#import "agent.h"
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <spawn.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

extern char **environ;
// libproc is in libSystem on iOS too; only the header is missing from the SDK.
int proc_name(int pid, void *buffer, uint32_t buffersize);

static uint32_t crc_table[256];

void crc_init(void)
{
    for (uint32_t i = 0; i < 256; i++) {
        uint32_t c = i << 24;
        for (int k = 0; k < 8; k++) { c = (c & 0x80000000u) ? (c << 1) ^ 0x04C11DB7u : c << 1; }
        crc_table[i] = c;
    }
}

// The number `cksum` prints: CRC-32/CKSUM with the length folded in. The app
// computes the same (`PosixChecksum`), and so does the guest's own `cksum`.
uint32_t posix_cksum(const uint8_t *bytes, size_t length)
{
    uint32_t c = 0;
    for (size_t i = 0; i < length; i++) { c = (c << 8) ^ crc_table[((c >> 24) ^ bytes[i]) & 0xFF]; }
    for (size_t n = length; n; n >>= 8) { c = (c << 8) ^ crc_table[((c >> 24) ^ (n & 0xFF)) & 0xFF]; }
    return ~c;
}

double now_seconds(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

static pthread_mutex_t log_lock = PTHREAD_MUTEX_INITIALIZER;
static bool log_stdout = false;

void agent_log_to_stdout(bool also) { log_stdout = also; }

// The log is kept small on purpose: the guest's data volume is the phone's own
// storage, and nobody reads more than the last screenful.
#define LOG_LIMIT (256 * 1024)

void agent_log(const char *format, ...)
{
    char line[1536];
    time_t t = time(NULL);
    struct tm tm;
    localtime_r(&t, &tm);
    size_t used = strftime(line, sizeof line, "%m-%d %H:%M:%S ", &tm);
    used += (size_t)snprintf(line + used, sizeof line - used, "[%d] ", getpid());
    size_t stamp = used;

    va_list args;
    va_start(args, format);
    vsnprintf(line + used, sizeof line - used - 2, format, args);
    va_end(args);
    size_t length = strlen(line);
    if (length == 0 || line[length - 1] != '\n') { line[length++] = '\n'; line[length] = 0; }

    pthread_mutex_lock(&log_lock);
    if (log_stdout) {
        fputs(line + stamp, stdout);
        fflush(stdout);
    }
    struct stat st;
    if (stat(AGENT_LOG, &st) == 0 && st.st_size > LOG_LIMIT) { rename(AGENT_LOG, AGENT_LOG ".1"); }
    int fd = open(AGENT_LOG, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0644);
    if (fd >= 0) {
        (void)write(fd, line, length);
        close(fd);
    }
    pthread_mutex_unlock(&log_lock);
}

// Raw devices take nothing but whole blocks at block-aligned addresses.
void *aligned_block(size_t size)
{
    size_t rounded = (size + BLOCK_SIZE - 1) / BLOCK_SIZE * BLOCK_SIZE;
    void *memory = NULL;
    if (posix_memalign(&memory, BLOCK_SIZE, rounded) != 0) { return NULL; }
    memset(memory, 0, rounded);
    return memory;
}

// Command output is whatever bytes a program printed, and JSON wants text.
// Broken sequences become '?', so one stray byte does not cost the whole answer.
NSString *lossy_string(const uint8_t *bytes, size_t length)
{
    NSString *text = [[NSString alloc] initWithBytes:bytes length:length encoding:NSUTF8StringEncoding];
    if (text) { return text; }

    NSMutableData *clean = [NSMutableData dataWithCapacity:length];
    size_t i = 0;
    while (i < length) {
        uint8_t c = bytes[i];
        size_t need = c < 0x80 ? 1 : (c >> 5) == 0x6 ? 2 : (c >> 4) == 0xE ? 3 : (c >> 3) == 0x1E ? 4 : 0;
        bool ok = need > 0 && i + need <= length;
        for (size_t k = 1; ok && k < need; k++) { ok = (bytes[i + k] & 0xC0) == 0x80; }
        if (ok) {
            [clean appendBytes:bytes + i length:need];
            i += need;
        } else {
            [clean appendBytes:"?" length:1];
            i += 1;
        }
    }
    text = [[NSString alloc] initWithData:clean encoding:NSUTF8StringEncoding];
    if (text) { return text; }

    // Overlong forms and surrogates pass the check above; plain ASCII never fails.
    NSMutableData *ascii = [NSMutableData dataWithCapacity:length];
    for (size_t k = 0; k < length; k++) {
        uint8_t c = bytes[k] < 0x80 ? bytes[k] : '?';
        [ascii appendBytes:&c length:1];
    }
    return [[NSString alloc] initWithData:ascii encoding:NSASCIIStringEncoding] ?: @"";
}

NSString *executable_path(void)
{
    char raw[PATH_MAX];
    uint32_t size = sizeof raw;
    if (_NSGetExecutablePath(raw, &size) != 0) { return nil; }
    char resolved[PATH_MAX];
    return realpath(raw, resolved) ? @(resolved) : @(raw);
}

int run_tool(const char *path, const char *const argv[], double timeout, char *output, size_t capacity)
{
    if (output && capacity) { output[0] = 0; }
    int pipefd[2];
    if (pipe(pipefd) != 0) { return -1; }
    fcntl(pipefd[0], F_SETFD, FD_CLOEXEC);
    fcntl(pipefd[1], F_SETFD, FD_CLOEXEC);
    fcntl(pipefd[0], F_SETFL, O_NONBLOCK);

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0);
    posix_spawn_file_actions_adddup2(&actions, pipefd[1], 1);
    posix_spawn_file_actions_adddup2(&actions, pipefd[1], 2);

    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    sigset_t none, defaults;
    sigemptyset(&none);
    sigfillset(&defaults);
    sigdelset(&defaults, SIGKILL);
    sigdelset(&defaults, SIGSTOP);
    posix_spawnattr_setsigmask(&attr, &none);
    posix_spawnattr_setsigdefault(&attr, &defaults);
    posix_spawnattr_setpgroup(&attr, 0);
    // CLOEXEC_DEFAULT: the child gets stdin, stdout and stderr and nothing else —
    // not the raw device, and not another job's pipe, whose end would then never
    // see EOF.
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF
                                        | POSIX_SPAWN_CLOEXEC_DEFAULT);

    pid_t pid = 0;
    int rc = posix_spawn(&pid, path, &actions, &attr, (char *const *)argv, environ);
    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attr);
    close(pipefd[1]);
    if (rc != 0) {
        close(pipefd[0]);
        errno = rc;
        return -1;
    }

    size_t used = 0;
    double deadline = now_seconds() + timeout, kill_at = 0;
    int status = 0, stage = 0;
    for (;;) {
        bool exited = waitpid(pid, &status, WNOHANG) == pid;
        char chunk[4096];
        for (;;) {
            ssize_t n = read(pipefd[0], chunk, sizeof chunk);
            if (n <= 0) { break; }
            if (output && used + 1 < capacity) {
                size_t take = (size_t)n < capacity - 1 - used ? (size_t)n : capacity - 1 - used;
                memcpy(output + used, chunk, take);
                used += take;
                output[used] = 0;
            }
        }
        if (exited) { break; }

        double now = now_seconds();
        if (stage == 0 && now >= deadline) {
            kill(-pid, SIGTERM);
            kill(pid, SIGTERM);
            stage = 1;
            kill_at = now + 3;
        } else if (stage == 1 && now >= kill_at) {
            kill(-pid, SIGKILL);
            kill(pid, SIGKILL);
            stage = 2;
            kill_at = now + 10;
        } else if (stage == 2 && now >= kill_at) {
            // Killed and still there: stuck inside the kernel. Nothing to wait for.
            close(pipefd[0]);
            return -1;
        }
        struct pollfd ready = {pipefd[0], POLLIN, 0};
        poll(&ready, 1, 100);
    }
    close(pipefd[0]);
    if (WIFEXITED(status)) { return WEXITSTATUS(status); }
    if (WIFSIGNALED(status)) { return 128 + WTERMSIG(status); }
    return -1;
}

bool read_pid_file(AgentPid *out)
{
    FILE *file = fopen(AGENT_PID, "r");
    if (!file) { return false; }
    long long pid = 0;
    unsigned long long instance = 0;
    char mode[16] = {0};
    int fields = fscanf(file, "%lld %llx %15s", &pid, &instance, mode);
    fclose(file);
    if (fields < 2 || pid <= 1) { return false; }
    out->pid = (pid_t)pid;
    out->instance = instance;
    strlcpy(out->mode, fields >= 3 ? mode : "?", sizeof out->mode);
    return true;
}

bool process_is_agent(pid_t pid)
{
    if (pid <= 1 || kill(pid, 0) != 0) { return false; }
    char name[64] = {0};
    if (proc_name(pid, name, sizeof name) <= 0) { return false; }
    return strncmp(name, "agent", 5) == 0;
}
