// agent — the app's hands inside the guest.
//
// Everything automatic used to talk to the guest through its one serial
// console, where the bootstrap's bash sits. One command that never gave its
// prompt back took everything down with it: the shell pane, the package
// preparation, the status bar. This program lives apart from the console. launchd
// starts it on every boot, it takes requests over the scratch NVMe namespace
// (`xfer`), runs commands with a timeout and kills the ones that hang, and keeps
// the status bar override applied by itself.
//
// The namespace is a file on the phone and a raw block device in the guest:
//
//   0x000000  request   256 KiB   the app writes, the agent reads
//   0x040000  response  768 KiB   the agent writes, the app reads
//   0x100000  data      the rest  file windows, in either direction
//
// Both control regions start with the same 64-byte header, checked by CRC, and
// carry JSON after it. A request is new when its (session, seq) pair has not been
// answered yet; the answer repeats the pair, so a late answer to an old request
// is never mistaken for a fresh one.
#import <Foundation/Foundation.h>
#include <stdbool.h>
#include <stdint.h>
#include <sys/types.h>

#define AGENT_PROTO 1

// Raw block devices take only block-aligned offsets, lengths and buffers, so
// the 64-byte header sits alone in the first block of each region and the JSON
// body starts a whole block in. Everything read or written is a block-aligned
// span out of a page-aligned buffer.
#define BLOCK_SIZE    4096
#define HEADER_SIZE   64
#define HEADER_BLOCK  BLOCK_SIZE
#define REQ_OFFSET    0
#define REQ_SIZE      (256 * 1024)
#define REQ_BODY      (REQ_OFFSET + HEADER_BLOCK)
#define RSP_OFFSET    (256 * 1024)
#define RSP_SIZE      (768 * 1024)
#define RSP_BODY      (RSP_OFFSET + HEADER_BLOCK)
#define DATA_OFFSET   (1024 * 1024)

#define REQ_MAGIC "INFAGREQ"
#define RSP_MAGIC "INFAGRSP"

typedef struct __attribute__((packed)) {
    char magic[8];
    uint32_t proto;
    uint32_t flags;
    uint64_t session;
    uint64_t seq;
    uint64_t agent;
    uint32_t length;
    uint32_t crc;
    uint32_t headcrc;   // over the 48 bytes before it
    uint8_t pad[12];
} AgentHeader;

// Where the agent keeps itself. On the data volume, next to the other helpers:
// nothing here has to be written to the system volume except launchd's cache.
#define TOOLS_DIR    "/var/mobile/.inferno"
#define AGENT_LINK   TOOLS_DIR "/agent"
#define AGENT_PID    TOOLS_DIR "/agent.pid"
#define AGENT_LOCK   TOOLS_DIR "/agent.lock"
#define AGENT_OFF    TOOLS_DIR "/agent.off"
#define AGENT_LOG    TOOLS_DIR "/agent.log"
#define AGENT_JOB    TOOLS_DIR "/com.inferno.agent.plist"
#define AGENT_LABEL  "com.inferno.agent"
#define LAUNCHD_CACHE "/System/Library/xpc/launchd.plist"
#define CACHE_KEY    "/System/Library/LaunchDaemons/com.inferno.agent.plist"

// util.m
void crc_init(void);
uint32_t posix_cksum(const uint8_t *bytes, size_t length);
double now_seconds(void);
void agent_log(const char *format, ...) __attribute__((format(printf, 1, 2)));
void agent_log_to_stdout(bool also);
void *aligned_block(size_t size);
NSString *lossy_string(const uint8_t *bytes, size_t length);
NSString *executable_path(void);

// Runs a tool and waits for it, killing it when it overstays. Returns the exit
// status, 128 + signal when it was killed, or -1 when it could not be started or
// had to be abandoned. `output` collects up to `capacity - 1` bytes.
int run_tool(const char *path, const char *const argv[], double timeout, char *output, size_t capacity);

// The pid file: "<pid> <instance> <mode>".
typedef struct {
    pid_t pid;
    uint64_t instance;
    char mode[16];
} AgentPid;
bool read_pid_file(AgentPid *out);
bool process_is_agent(pid_t pid);

// jobs.m
void jobs_init(void);
// Waits up to `seconds` for output, exits and deadlines; returns early when
// `until` (a job id, or nil) is done.
void jobs_pump(double seconds, NSString *until);
NSDictionary *jobs_exec(NSDictionary *request);
NSDictionary *jobs_poll(NSDictionary *request);
NSDictionary *jobs_kill(NSDictionary *request);
NSDictionary *jobs_summary(void);
bool jobs_busy(void);

// statusbar.m
void statusbar_start(void);
NSDictionary *statusbar_request(NSDictionary *request);
NSDictionary *statusbar_summary(void);

// install.m
int agent_install(void);
int agent_uninstall(void);
NSDictionary *agent_job_entry(void);

// files.m — small files inline, big ones through the data region
NSDictionary *files_write(NSDictionary *request);
NSDictionary *files_read(NSDictionary *request);
NSDictionary *files_push(NSDictionary *request, int device, uint64_t capacity);
NSDictionary *files_pull(NSDictionary *request, int device, uint64_t capacity);
