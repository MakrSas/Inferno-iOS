// Getting the agent to start on every boot, and start now.
//
// launchd on this image takes its daemons from a cache
// (`launchd_unsecure_cache=1`): a plist dropped into /Library/LaunchDaemons
// lasts only until the guest reboots. The one thing that survives is an entry in
// the cache itself, `/System/Library/xpc/launchd.plist` — the same place
// `install-bootstrap.sh` adds the bash-on-console daemon. So `agent install`
// edits that cache to add a KeepAlive daemon for itself, then spawns a running
// copy for the current boot without waiting for the next one.
//
// Two rules keep this from ever wedging the guest (criterion: a bad agent or
// plist must not stop the boot):
//
//   * the cache is rewritten atomically, to a temp file then renamed, and only
//     after it has been parsed and our entry confirmed present — a half-written
//     cache is never left behind;
//   * the daemon points at a stable symlink, `…/agent`, so a new build (whose
//     real file carries a fresh checksum in its name) is adopted by repointing
//     the link, and the kernel never sees a new binary written over an old path.
#import "agent.h"
#import <Foundation/Foundation.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

extern char **environ;

static bool root_is_writable(void)
{
    // A write probe, not the mount table: the point is whether a file can be
    // made on the system volume, which is all the cache edit needs.
    const char *probe = "/System/Library/xpc/.inferno-probe";
    int fd = open(probe, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) { return false; }
    close(fd);
    unlink(probe);
    return true;
}

static bool remount_writable(void)
{
    if (root_is_writable()) { return true; }
    const char *argv[] = {"/sbin/mount", "-uw", "/", NULL};
    char out[256];
    for (int attempt = 0; attempt < 3; attempt++) {
        run_tool("/sbin/mount", argv, 20, out, sizeof out);
        if (root_is_writable()) { return true; }
        sleep(1);
    }
    return false;
}

// The daemon description added to the cache.
//
// launchd starts the agent through bash rather than exec'ing it directly, and
// this is not a style choice: the kernel here refuses to let launchd (or any of
// env/nohup/timeout) exec a binary that carries entitlements — the direct job
// exited 78 and never reached main. A bash launched by launchd *can* exec it,
// exactly as the bootstrap's console bash does, so bash stands in the middle and
// `exec`s the agent in its place. launchd then tracks the agent's own pid.
//
// KeepAlive brings it back if it crashes — and gives a boot where /var was not
// ready yet another try — with a throttle so a binary that dies at once cannot
// spin. Output goes to /dev/console (always openable at spawn time); the agent
// keeps its own log file besides.
static NSDictionary *cache_entry(void)
{
    NSString *command = [NSString stringWithFormat:@"exec %s serve", AGENT_LINK];
    return @{
        @"Label" : @AGENT_LABEL,
        @"ProgramArguments" : @[ @"/bin/bash", @"-c", command ],
        @"RunAtLoad" : @YES,
        @"KeepAlive" : @YES,
        @"ThrottleInterval" : @5,
        @"UserName" : @"root",
        @"EnablePressuredExit" : @NO,
        @"POSIXSpawnType" : @"Interactive",
        @"StandardOutPath" : @"/dev/console",
        @"StandardErrorPath" : @"/dev/console",
    };
}

NSDictionary *agent_job_entry(void) { return cache_entry(); }

// Points the stable link at this very binary, so the daemon and any restart
// reach the build that installed itself.
static bool link_self(NSString **error)
{
    NSString *self = executable_path();
    if (!self) {
        *error = @"cannot find own path";
        return false;
    }
    mkdir(TOOLS_DIR, 0755);
    unlink(AGENT_LINK);
    if (symlink(self.fileSystemRepresentation, AGENT_LINK) != 0 && errno != EEXIST) {
        *error = [NSString stringWithFormat:@"symlink: %s", strerror(errno)];
        return false;
    }
    return true;
}

// Reads the launchd cache, adds our entry, writes it back in the format it came
// in. A backup of the untouched cache is kept the first time, for uninstall.
static bool edit_cache(NSString **error)
{
    NSData *raw = [NSData dataWithContentsOfFile:@LAUNCHD_CACHE];
    if (!raw) {
        *error = @"launchd cache not found";
        return false;
    }
    NSPropertyListFormat format = NSPropertyListBinaryFormat_v1_0;
    NSError *parse = nil;
    id plist = [NSPropertyListSerialization propertyListWithData:raw
                                                         options:NSPropertyListMutableContainersAndLeaves
                                                          format:&format
                                                           error:&parse];
    if (![plist isKindOfClass:[NSDictionary class]]) {
        *error = [NSString stringWithFormat:@"cache not a plist: %@", parse.localizedDescription];
        return false;
    }
    NSMutableDictionary *root = plist;
    NSMutableDictionary *daemons = root[@"LaunchDaemons"];
    if (![daemons isKindOfClass:[NSDictionary class]]) {
        *error = @"cache has no LaunchDaemons";
        return false;
    }
    // A sanity check that this really is an iOS services cache, not something
    // else at that path — the same guard install-bootstrap.sh uses.
    if (!daemons[@"/System/Library/LaunchDaemons/com.apple.SpringBoard.plist"]) {
        *error = @"cache does not look like the guest's";
        return false;
    }

    if (![[NSFileManager defaultManager] fileExistsAtPath:@LAUNCHD_CACHE ".inferno-orig"]) {
        [raw writeToFile:@LAUNCHD_CACHE ".inferno-orig" atomically:YES];
    }

    daemons[@CACHE_KEY] = cache_entry();

    NSError *encode = nil;
    NSData *out = [NSPropertyListSerialization dataWithPropertyList:root format:format options:0 error:&encode];
    if (!out) {
        *error = [NSString stringWithFormat:@"cannot encode cache: %@", encode.localizedDescription];
        return false;
    }
    // Parsed once more before it is put in place: a cache that will not read
    // back is one the guest cannot boot from.
    if (![NSPropertyListSerialization propertyListWithData:out options:0 format:NULL error:NULL]) {
        *error = @"re-encoded cache will not parse";
        return false;
    }

    NSString *temp = @LAUNCHD_CACHE ".inferno-new";
    if (![out writeToFile:temp atomically:NO]) {
        *error = @"cannot write new cache";
        return false;
    }
    if (rename(temp.fileSystemRepresentation, LAUNCHD_CACHE) != 0) {
        *error = [NSString stringWithFormat:@"rename cache: %s", strerror(errno)];
        unlink(temp.fileSystemRepresentation);
        return false;
    }
    sync();
    return true;
}

// Starts a serving copy now, detached, so this boot has the agent without a
// reboot. Only one ever serves: the serve loop holds a lock, and a second copy
// that cannot take it exits at once.
//
// Its stdio is pointed at /dev/null, and this is not tidiness. `agent install`
// is run by the app inside a `$(…)` command substitution; a child that kept the
// inherited stdout open would hold that substitution open forever — the serving
// agent runs for the life of the guest — and the install call would hang until
// it timed out. Detaching the copy's descriptors lets the substitution close.
static void start_now(void)
{
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0);
    posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0);
    posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0);

    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    // A session of its own, so it is not tied to the shell that ran the install.
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETSID);

    const char *argv[] = {AGENT_LINK, "serve", NULL};
    pid_t pid = 0;
    int rc = posix_spawn(&pid, AGENT_LINK, &actions, &attr, (char *const *)argv, environ);
    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attr);
    if (rc == 0) {
        agent_log("install: started a copy now, pid %d", pid);
    } else {
        agent_log("install: could not start now: %s", strerror(rc));
    }
}

int agent_install(void)
{
    agent_log_to_stdout(true);
    NSString *error = nil;
    if (!link_self(&error)) {
        printf("AGENT-INSTALL FAIL %s\n", error.UTF8String);
        return 1;
    }
    if (!remount_writable()) {
        printf("AGENT-INSTALL FAIL root stayed read-only\n");
        return 1;
    }
    if (!edit_cache(&error)) {
        printf("AGENT-INSTALL FAIL %s\n", error.UTF8String);
        return 1;
    }
    unlink(AGENT_OFF);
    start_now();
    printf("AGENT-INSTALL OK %s\n", AGENT_PROTO == 1 ? "proto1" : "proto?");
    return 0;
}

int agent_uninstall(void)
{
    agent_log_to_stdout(true);
    // Stop it serving, and keep it stopped even if the cache entry lingers.
    int fd = open(AGENT_OFF, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd >= 0) { close(fd); }
    AgentPid current;
    if (read_pid_file(&current) && process_is_agent(current.pid)) { kill(current.pid, SIGTERM); }

    if (remount_writable()) {
        NSData *raw = [NSData dataWithContentsOfFile:@LAUNCHD_CACHE];
        NSPropertyListFormat format = NSPropertyListBinaryFormat_v1_0;
        id plist = raw ? [NSPropertyListSerialization propertyListWithData:raw
                                                                   options:NSPropertyListMutableContainersAndLeaves
                                                                    format:&format
                                                                     error:NULL]
                       : nil;
        if ([plist isKindOfClass:[NSDictionary class]]) {
            NSMutableDictionary *daemons = ((NSMutableDictionary *)plist)[@"LaunchDaemons"];
            if (daemons[@CACHE_KEY]) {
                [daemons removeObjectForKey:@CACHE_KEY];
                NSData *out = [NSPropertyListSerialization dataWithPropertyList:plist format:format options:0 error:NULL];
                if (out && [NSPropertyListSerialization propertyListWithData:out options:0 format:NULL error:NULL]) {
                    [out writeToFile:@LAUNCHD_CACHE ".inferno-new" atomically:NO];
                    rename(LAUNCHD_CACHE ".inferno-new", LAUNCHD_CACHE);
                    sync();
                }
            }
        }
    }
    printf("AGENT-UNINSTALL OK\n");
    return 0;
}
