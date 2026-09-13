// Stands in for Cydia's setuid helper on a guest where setuid cannot work.
//
// Cydia asks for root by running /usr/libexec/cydia/cydo, which is setuid. In
// this guest every volume is mounted nosuid and /usr/lib/libjailbreak.dylib —
// how a real jailbreak hands out root instead — is missing, so the original
// helper runs dpkg as mobile and dpkg exits 2.
//
// This one hands the arguments to a script launchd runs as root, plays back
// what it printed and exits with its status. Built as a binary rather than
// written as a shell script because Cydia spawns this path expecting one.
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define QUEUE "/var/tmp/inferno-cydo"

int main(int argc, char** argv)
{
    char  req[256], tmp[256], out[256], rc[256];
    FILE* f;
    int   i;
    int   waited;

    snprintf(tmp, sizeof(tmp), QUEUE "/%d.tmp", getpid());
    snprintf(req, sizeof(req), QUEUE "/%d.req", getpid());
    snprintf(out, sizeof(out), QUEUE "/%d.out", getpid());
    snprintf(rc, sizeof(rc), QUEUE "/%d.rc", getpid());

    f = fopen(tmp, "w");
    if (f == NULL) {
        fprintf(stderr, "cydo: cannot reach the helper (%s)\n", strerror(errno));
        return 2;
    }
    for (i = 1; i < argc; i++) { fprintf(f, "%s\n", argv[i]); }
    fclose(f);

    // The output file exists before the request does, so the reader below never
    // races the root side into creating it.
    close(open(out, O_WRONLY | O_CREAT, 0666));
    if (rename(tmp, req) != 0) {
        fprintf(stderr, "cydo: cannot post the request (%s)\n", strerror(errno));
        return 2;
    }

    // Played back as it grows: Cydia puts dpkg's lines on screen while it works.
    long shown = 0;
    for (waited = 0; waited < 3600; waited++) {
        char  buf[4096];
        FILE* o = fopen(out, "r");

        if (o != NULL) {
            size_t n;

            fseek(o, shown, SEEK_SET);
            while ((n = fread(buf, 1, sizeof(buf), o)) > 0) {
                fwrite(buf, 1, n, stdout);
                shown += (long)n;
            }
            fflush(stdout);
            fclose(o);
        }
        if (access(rc, F_OK) == 0) { break; }
        usleep(200 * 1000);
    }

    int status = 2;
    f = fopen(rc, "r");
    if (f != NULL) {
        if (fscanf(f, "%d", &status) != 1) { status = 2; }
        fclose(f);
    }
    unlink(out);
    unlink(rc);
    return status;
}
