// agent — see agent.h for the shape of the whole thing.
//
//   agent serve       run the loop (what launchd starts)
//   agent install     add the launchd entry, link self, start a copy now
//   agent uninstall   stop serving and take the launchd entry back out
//   agent ping        say hello and exit (used to prove the binary runs)
#import "agent.h"
#import <Foundation/Foundation.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <unistd.h>

#ifndef DKIOCGETBLOCKSIZE
#define DKIOCGETBLOCKSIZE _IOR('d', 24, uint32_t)
#define DKIOCGETBLOCKCOUNT _IOR('d', 25, uint64_t)
#endif

// The namespace the app hands the machine is 16 MiB (VMConfig.transferBytes).
// The device is found by that size: among the guest's namespaces it is the only
// one this big, and the number of the /dev/rdiskN it lands on depends on how
// many the guest chose to show.
#define EXPECTED_CAPACITY (16 * 1024 * 1024)

static volatile sig_atomic_t stop_requested = 0;
static void on_signal(int sig) { (void)sig; stop_requested = 1; }

static uint64_t g_instance;

// --- the device -----------------------------------------------------------

static uint64_t device_capacity(int fd)
{
    uint32_t bs = 0;
    uint64_t bc = 0;
    ioctl(fd, DKIOCGETBLOCKSIZE, &bs);
    ioctl(fd, DKIOCGETBLOCKCOUNT, &bc);
    if (bs && bc) { return (uint64_t)bs * bc; }
    off_t end = lseek(fd, 0, SEEK_END);
    return end > 0 ? (uint64_t)end : 0;
}

// Opens the scratch namespace, or -1. Never opens anything but a device of
// exactly the expected size, so the root disk and the firmware namespace are
// safe from a stray write however the numbering comes out.
static int open_device(uint64_t *capacity_out)
{
    for (int i = 1; i <= 12; i++) {
        char path[32];
        snprintf(path, sizeof path, "/dev/rdisk%d", i);
        int fd = open(path, O_RDWR);
        if (fd < 0) { continue; }
        uint64_t capacity = device_capacity(fd);
        if (capacity == EXPECTED_CAPACITY && capacity > DATA_OFFSET) {
            *capacity_out = capacity;
            agent_log("device: %s, %llu bytes", path, capacity);
            return fd;
        }
        close(fd);
    }
    return -1;
}

// --- the control regions --------------------------------------------------

static bool header_valid(const AgentHeader *header, const char *magic)
{
    if (memcmp(header->magic, magic, 8) != 0) { return false; }
    uint32_t want = posix_cksum((const uint8_t *)header, offsetof(AgentHeader, headcrc));
    return header->proto == AGENT_PROTO && header->headcrc == want;
}

// Reads the request region: true only when a whole, self-consistent request is
// there — magic, header checksum, and the body's own checksum all agree. A torn
// write (body not yet on disk when the header's new seq is seen) fails the body
// check and is simply read again next tick.
//
// `head` is a page-aligned scratch block, `body` a page-aligned buffer, so every
// read here is block-aligned in offset, length and address — the raw device
// refuses anything else ("disk2: alignment error").
static bool read_request(int fd, uint8_t *head, AgentHeader *header, uint8_t *body, size_t body_capacity)
{
    if (pread(fd, head, HEADER_BLOCK, REQ_OFFSET) != HEADER_BLOCK) { return false; }
    memcpy(header, head, sizeof *header);
    if (!header_valid(header, REQ_MAGIC)) { return false; }
    if (header->length > body_capacity || header->length > REQ_SIZE - HEADER_BLOCK) { return false; }

    size_t span = ((size_t)header->length + BLOCK_SIZE - 1) / BLOCK_SIZE * BLOCK_SIZE;
    if (span == 0) { span = BLOCK_SIZE; }
    if (pread(fd, body, span, REQ_BODY) < (ssize_t)header->length) { return false; }
    return posix_cksum(body, header->length) == header->crc;
}

static void write_response(int fd, uint64_t session, uint64_t seq, NSData *json)
{
    size_t length = json.length;
    size_t span = HEADER_BLOCK + (length + BLOCK_SIZE - 1) / BLOCK_SIZE * BLOCK_SIZE;
    uint8_t *buffer = aligned_block(span);
    if (!buffer) { return; }

    AgentHeader *header = (AgentHeader *)buffer;
    memcpy(header->magic, RSP_MAGIC, 8);
    header->proto = AGENT_PROTO;
    header->session = session;
    header->seq = seq;
    header->agent = g_instance;
    header->length = (uint32_t)length;
    // The body begins a whole block in, so the header stands alone in block zero
    // and both land on aligned boundaries.
    memcpy(buffer + HEADER_BLOCK, json.bytes, length);
    header->crc = posix_cksum(buffer + HEADER_BLOCK, length);
    header->headcrc = posix_cksum((const uint8_t *)header, offsetof(AgentHeader, headcrc));

    if (pwrite(fd, buffer, span, RSP_OFFSET) < 0) { agent_log("response write: %s", strerror(errno)); }
    fsync(fd);
    free(buffer);
}

// Serialises a reply, and if it will not fit the response region, trims its
// output field until it does rather than dropping the whole answer.
static NSData *encode_reply(NSMutableDictionary *reply)
{
    const size_t limit = RSP_SIZE - HEADER_BLOCK;
    for (int attempt = 0; attempt < 24; attempt++) {
        NSData *data = [NSJSONSerialization dataWithJSONObject:reply options:0 error:NULL];
        if (data && data.length <= limit) { return data; }
        NSString *out = reply[@"out"];
        if ([out isKindOfClass:[NSString class]] && out.length > 0) {
            NSUInteger keep = out.length / 2;
            reply[@"out"] = [out substringToIndex:keep];
            reply[@"truncated"] = @YES;
            continue;
        }
        // Nothing left to trim: answer that it did not fit.
        return [NSJSONSerialization dataWithJSONObject:@{@"ok" : @NO, @"error" : @"reply too large"}
                                               options:0
                                                 error:NULL];
    }
    return [NSJSONSerialization dataWithJSONObject:@{@"ok" : @NO, @"error" : @"reply too large"} options:0 error:NULL];
}

// --- dispatch -------------------------------------------------------------

static NSDictionary *handle(NSDictionary *request, int device, uint64_t capacity)
{
    NSString *op = [request[@"op"] isKindOfClass:[NSString class]] ? request[@"op"] : @"";

    if ([op isEqualToString:@"ping"]) {
        return @{@"ok" : @YES, @"proto" : @(AGENT_PROTO), @"agent" : @(g_instance),
                 @"pid" : @(getpid()), @"jobs" : jobs_summary(), @"statusbar" : statusbar_summary()};
    }
    if ([op isEqualToString:@"exec"]) { return jobs_exec(request); }
    if ([op isEqualToString:@"poll"]) { return jobs_poll(request); }
    if ([op isEqualToString:@"kill"]) { return jobs_kill(request); }
    if ([op isEqualToString:@"statusbar"]) { return statusbar_request(request); }
    if ([op isEqualToString:@"stat"]) { return files_write(request); }
    if ([op isEqualToString:@"push"]) { return files_push(request, device, capacity); }
    if ([op isEqualToString:@"pull"]) { return files_pull(request, device, capacity); }
    if ([op isEqualToString:@"off"]) {
        int fd = open(AGENT_OFF, O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (fd >= 0) { close(fd); }
        stop_requested = 1;
        return @{@"ok" : @YES};
    }
    return @{@"ok" : @NO, @"error" : [@"unknown op: " stringByAppendingString:op]};
}

// --- the loop -------------------------------------------------------------

static void write_pid_file(void)
{
    FILE *file = fopen(AGENT_PID, "w");
    if (!file) { return; }
    fprintf(file, "%d %llx serve\n", getpid(), g_instance);
    fclose(file);
}

static int serve(void)
{
    // Only one server at a time. launchd's copy and the one `install` starts
    // both try; whoever gets the lock serves, the other steps aside so two
    // pollers never corrupt each other's view of the device.
    int lock = open(AGENT_LOCK, O_WRONLY | O_CREAT, 0644);
    if (lock < 0) {
        agent_log("serve: cannot open lock: %s", strerror(errno));
        return 1;
    }
    if (flock(lock, LOCK_EX | LOCK_NB) != 0) {
        agent_log("serve: another agent holds the lock, stepping aside");
        return 0;
    }

    signal(SIGTERM, on_signal);
    signal(SIGINT, on_signal);
    signal(SIGPIPE, SIG_IGN);
    g_instance = ((uint64_t)time(NULL) << 16) ^ (uint64_t)getpid();

    write_pid_file();
    jobs_init();
    statusbar_start();
    agent_log("serve: up, instance %llx", g_instance);

    int device = -1;
    uint64_t capacity = 0;
    uint8_t *body = aligned_block(REQ_SIZE);
    uint8_t *head = aligned_block(HEADER_BLOCK);
    if (!body || !head) {
        agent_log("serve: out of memory");
        return 1;
    }

    uint64_t last_session = 0, last_seq = 0;
    bool have_last = false;
    double device_complained = 0;

    while (!stop_requested) {
        if (access(AGENT_OFF, F_OK) == 0) {
            agent_log("serve: told to stop (%s present)", AGENT_OFF);
            break;
        }
        if (device < 0) {
            device = open_device(&capacity);
            if (device < 0) {
                // No device: an emulator without the namespace, or it has not
                // appeared yet. The status bar keeper still runs; the command
                // channel simply waits. Said once a minute, not every tick.
                double now = now_seconds();
                if (now - device_complained > 60) {
                    agent_log("serve: scratch namespace not found; command channel idle");
                    device_complained = now;
                }
                jobs_pump(2, nil);
                continue;
            }
        }

        AgentHeader header;
        if (read_request(device, head, &header, body, REQ_SIZE)) {
            bool fresh = !have_last || header.session != last_session || header.seq != last_seq;
            if (fresh) {
                NSDictionary *request = nil;
                if (header.length > 0) {
                    NSData *data = [NSData dataWithBytes:body length:header.length];
                    request = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
                }
                if (![request isKindOfClass:[NSDictionary class]]) { request = @{@"op" : @"ping"}; }

                @autoreleasepool {
                    NSDictionary *reply = handle(request, device, capacity);
                    NSMutableDictionary *out = [reply mutableCopy];
                    out[@"seq"] = @(header.seq);
                    write_response(device, header.session, header.seq, encode_reply(out));
                }
                last_session = header.session;
                last_seq = header.seq;
                have_last = true;
            }
        }

        // Time given to running jobs is also the poll interval: short, so a new
        // request is picked up quickly, but not a busy-wait.
        jobs_pump(jobs_busy() ? 0.1 : 0.15, nil);
    }

    free(body);
    free(head);
    if (device >= 0) { close(device); }
    unlink(AGENT_PID);
    agent_log("serve: down");
    flock(lock, LOCK_UN);
    close(lock);
    return 0;
}

int main(int argc, char **argv)
{
    @autoreleasepool {
        crc_init();
        NSString *mode = argc > 1 ? @(argv[1]) : @"serve";

        if ([mode isEqualToString:@"install"]) { return agent_install(); }
        if ([mode isEqualToString:@"uninstall"]) { return agent_uninstall(); }
        if ([mode isEqualToString:@"ping"]) {
            printf("AGENT-PING OK proto%d\n", AGENT_PROTO);
            return 0;
        }
        if ([mode isEqualToString:@"serve"]) { return serve(); }

        fprintf(stderr, "usage: agent serve|install|uninstall|ping\n");
        return 2;
    }
}
