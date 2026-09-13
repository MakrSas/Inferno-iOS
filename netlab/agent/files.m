// Carrying files, now that the agent owns the namespace.
//
// The old way had the app drive a separate helper (`nsio`) over the console:
// the app wrote a window into the backing file and told the guest, in a console
// command, to read the raw device and append it. That cannot share the device
// with an agent that is polling it. So when the agent is present it carries
// files itself, over the same namespace, out of a data region kept clear of the
// control headers.
//
//   push: the app writes a window into the data region and asks to append it to
//         a path; the agent reads its own block device and writes the file.
//   pull: the agent reads the file, lays a window in the data region, and the
//         app reads the same place back.
//
// Everything is checked with the same `cksum` the app computes, so a wrong byte
// anywhere shows up at the end.
#import "agent.h"
#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static NSDictionary *fail(NSString *why) { return @{@"ok" : @NO, @"error" : why}; }

static NSString *string_field(id value) { return [value isKindOfClass:[NSString class]] ? value : nil; }

// The window available for file bytes: everything past the control regions.
static uint64_t data_capacity(uint64_t device_capacity)
{
    return device_capacity > DATA_OFFSET ? device_capacity - DATA_OFFSET : 0;
}

// Reads the file's size and, for `stat`, whether it is there at all.
static bool file_size(NSString *path, long long *size)
{
    struct stat st;
    if (stat(path.fileSystemRepresentation, &st) != 0) { return false; }
    *size = st.st_size;
    return true;
}

// One window from the data region into the open file, appended.
NSDictionary *files_push(NSDictionary *request, int device, uint64_t capacity)
{
    NSString *path = string_field(request[@"path"]);
    long long length = [request[@"len"] longLongValue];
    long long offset = [request[@"at"] longLongValue];
    bool truncate_first = [request[@"first"] boolValue];
    uint32_t want_crc = (uint32_t)[request[@"crc"] unsignedLongLongValue];
    uint64_t window = data_capacity(capacity);
    if (!path || length < 0 || (uint64_t)length > window) { return fail(@"push: bad length"); }

    size_t span = ((size_t)length + BLOCK_SIZE - 1) / BLOCK_SIZE * BLOCK_SIZE;
    uint8_t *buffer = aligned_block(span ?: BLOCK_SIZE);
    if (!buffer) { return fail(@"push: out of memory"); }

    ssize_t got = pread(device, buffer, span ?: BLOCK_SIZE, DATA_OFFSET);
    if (got < length) {
        free(buffer);
        return fail([NSString stringWithFormat:@"push: short device read (%zd)", got]);
    }
    if (posix_cksum(buffer, (size_t)length) != want_crc) {
        free(buffer);
        return fail(@"push: window checksum");
    }

    int flags = O_WRONLY | O_CREAT | (truncate_first ? O_TRUNC : O_APPEND);
    int fd = open(path.fileSystemRepresentation, flags, 0644);
    if (fd < 0) {
        free(buffer);
        return fail([NSString stringWithFormat:@"push: open %s: %s", path.UTF8String, strerror(errno)]);
    }
    if (truncate_first && offset > 0) { lseek(fd, offset, SEEK_SET); }
    ssize_t written = 0;
    while (written < length) {
        ssize_t n = write(fd, buffer + written, (size_t)(length - written));
        if (n <= 0) {
            int e = errno;
            close(fd);
            free(buffer);
            return fail([NSString stringWithFormat:@"push: write: %s", strerror(e)]);
        }
        written += n;
    }
    close(fd);
    free(buffer);

    long long total = -1;
    file_size(path, &total);
    return @{@"ok" : @YES, @"total" : @(total)};
}

// One window out of the file into the data region.
NSDictionary *files_pull(NSDictionary *request, int device, uint64_t capacity)
{
    NSString *path = string_field(request[@"path"]);
    long long offset = [request[@"at"] longLongValue];
    long long length = [request[@"len"] longLongValue];
    uint64_t window = data_capacity(capacity);
    if (!path || length < 0 || (uint64_t)length > window) { return fail(@"pull: bad length"); }

    int fd = open(path.fileSystemRepresentation, O_RDONLY);
    if (fd < 0) { return fail([NSString stringWithFormat:@"pull: open %s: %s", path.UTF8String, strerror(errno)]); }

    size_t span = ((size_t)length + BLOCK_SIZE - 1) / BLOCK_SIZE * BLOCK_SIZE;
    uint8_t *buffer = aligned_block(span ?: BLOCK_SIZE);
    if (!buffer) {
        close(fd);
        return fail(@"pull: out of memory");
    }
    ssize_t got = pread(fd, buffer, (size_t)length, offset);
    close(fd);
    if (got < 0) {
        free(buffer);
        return fail([NSString stringWithFormat:@"pull: read: %s", strerror(errno)]);
    }
    // A short read at the end is fine; the rest of the block is already zero.
    uint32_t crc = posix_cksum(buffer, (size_t)got);
    if (pwrite(device, buffer, span ?: BLOCK_SIZE, DATA_OFFSET) < 0) {
        free(buffer);
        return fail([NSString stringWithFormat:@"pull: device write: %s", strerror(errno)]);
    }
    fsync(device);
    free(buffer);
    return @{@"ok" : @YES, @"len" : @(got), @"crc" : @(crc)};
}

// `stat`: the size and whether it exists, for the app to size a transfer.
NSDictionary *files_write(NSDictionary *request)
{
    NSString *path = string_field(request[@"path"]);
    if (!path) { return fail(@"stat: no path"); }
    long long size = 0;
    bool there = file_size(path, &size);
    return @{@"ok" : @YES, @"exists" : @(there), @"size" : @(size)};
}

NSDictionary *files_read(NSDictionary *request) { return files_write(request); }
