// nsio — read and write an NVMe namespace the shell cannot touch.
//
// The guest's shell is sandboxed: open("/dev/rdisk1") gives EPERM even to root,
// while /sbin/fsck_hfs reads the same device happily. The difference is the
// binary's entitlements, so this carries its own.
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <sys/ioctl.h>

// sys/disk.h is not in the iOS SDK; these are its two ioctls.
#ifndef DKIOCGETBLOCKSIZE
    #define DKIOCGETBLOCKSIZE  _IOR('d', 24, uint32_t)
    #define DKIOCGETBLOCKCOUNT _IOR('d', 25, uint64_t)
#endif
#include <unistd.h>

static int usage(void) {
    fprintf(stderr, "usage: nsio size  <dev>\n"
                    "       nsio read  <dev> <off> <len> <out>\n"
                    "       nsio write <dev> <off> <in>\n");
    return 2;
}

int main(int argc, char **argv) {
    if (argc < 3) return usage();
    const char *cmd = argv[1], *dev = argv[2];
    int writing = strcmp(cmd, "write") == 0;
    int fd = open(dev, writing ? O_RDWR : O_RDONLY);
    if (fd < 0) { fprintf(stderr, "open %s: %s\n", dev, strerror(errno)); return 1; }

    uint32_t bs = 0; uint64_t bc = 0;
    ioctl(fd, DKIOCGETBLOCKSIZE, &bs);
    ioctl(fd, DKIOCGETBLOCKCOUNT, &bc);
    if (!bs) bs = 4096;
    if (!bc) {
        off_t end = lseek(fd, 0, SEEK_END);
        if (end > 0) bc = (uint64_t)end / bs;
    }

    if (!strcmp(cmd, "size")) {
        printf("blocksize=%u blocks=%llu bytes=%llu\n", bs, bc, (unsigned long long)bs * bc);
        return 0;
    }

    // Raw devices demand block-aligned offsets, lengths and buffers. The buffer
    // is a megabyte rather than one block: at one system call per 4096 bytes the
    // channel sat at 2 MB/s, and the emulated processor felt every crossing.
    size_t chunk = 1 << 20;
    if (chunk % bs) chunk = bs;
    void *buf = NULL;
    if (posix_memalign(&buf, 4096, chunk) != 0) { perror("memalign"); return 1; }

    if (!strcmp(cmd, "read")) {
        if (argc < 6) return usage();
        long long off = atoll(argv[3]), len = atoll(argv[4]);
        FILE *out = fopen(argv[5], "wb");
        if (!out) { perror("fopen"); return 1; }
        long long done = 0;
        while (done < len) {
            long long at = off + done;
            long long base = at - (at % bs);
            long long skip = at - base;
            ssize_t n = pread(fd, buf, chunk, base);
            if (n <= 0) { fprintf(stderr, "pread at %lld: %s\n", base, strerror(errno)); return 1; }
            if (n <= skip) { fprintf(stderr, "short read at %lld\n", base); return 1; }
            long long take = (n - skip) < (len - done) ? (n - skip) : (len - done);
            fwrite((char *)buf + skip, 1, take, out);
            done += take;
        }
        fclose(out);
        printf("read %lld\n", done);
        return 0;
    }

    if (!strcmp(cmd, "write")) {
        if (argc < 5) return usage();
        long long off = atoll(argv[3]);
        FILE *in = fopen(argv[4], "rb");
        if (!in) { perror("fopen"); return 1; }
        if (off % bs) { fprintf(stderr, "offset must be a multiple of %u\n", bs); return 1; }
        long long at = off, total = 0;
        for (;;) {
            size_t got = fread(buf, 1, chunk, in);
            if (!got) break;
            // The tail is padded out to a whole block: the device takes nothing
            // smaller, and the reader is told the real length separately.
            size_t span = (got + bs - 1) / bs * bs;
            memset((char *)buf + got, 0, span - got);
            if (pwrite(fd, buf, span, at) != (ssize_t)span) {
                fprintf(stderr, "pwrite at %lld: %s\n", at, strerror(errno)); return 1;
            }
            at += span; total += got;
        }
        fclose(in);
        fsync(fd);
        printf("wrote %lld\n", total);
        return 0;
    }
    return usage();
}
