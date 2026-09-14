// Walks the HAL object graph as the plug-ins see it. The VirtualAudio plug-in
// enumerates devices when it activates and found exactly one — Null_Device —
// so the question is whether the hardware devices are in the system object's
// lists at all, or only "activated" somewhere the enumeration does not look.
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <stdio.h>

typedef UInt32 AudioObjectID;

typedef struct {
    UInt32 selector;
    UInt32 scope;
    UInt32 element;
} AudioObjectPropertyAddress;

typedef OSStatus (*GetSizeFn)(AudioObjectID, const AudioObjectPropertyAddress*, UInt32, const void*, UInt32*);
typedef OSStatus (*GetDataFn)(AudioObjectID, const AudioObjectPropertyAddress*, UInt32, const void*, UInt32*, void*);

static GetSizeFn getSize;
static GetDataFn getData;

static const char* cc(UInt32 v, char b[8])
{
    char c[4] = { (char)(v >> 24), (char)(v >> 16), (char)(v >> 8), (char)v };
    for (int i = 0; i < 4; i++) {
        if (c[i] < 0x20 || c[i] > 0x7E) {
            snprintf(b, 8, "%u", (unsigned)v);
            return b;
        }
    }
    snprintf(b, 8, "%c%c%c%c", c[0], c[1], c[2], c[3]);
    return b;
}

static void list(AudioObjectID obj, UInt32 sel, const char* label)
{
    AudioObjectPropertyAddress addr = { sel, 'glob', 0 };
    UInt32                     size = 0;
    char                       b[8];

    OSStatus st = getSize(obj, &addr, 0, NULL, &size);
    AudioObjectID ids[128] = { 0 };
    UInt32        ask      = size ? size : sizeof(ids);
    if (ask > sizeof(ids)) { ask = sizeof(ids); }
    OSStatus st2 = getData(obj, &addr, 0, NULL, &ask, ids);

    printf("obj %u %-6s (%s): sizeSt=%s size=%u getSt=%s n=%u:", obj, cc(sel, b), label, cc((UInt32)st, b), size,
           cc((UInt32)st2, b), (unsigned)(ask / sizeof(AudioObjectID)));
    char b2[8];
    for (UInt32 i = 0; st2 == 0 && i < ask / sizeof(AudioObjectID) && i < 32; i++) { printf(" %u", ids[i]); }
    printf("\n");
    (void)b2;
}

int main(void)
{
    @autoreleasepool {
        getSize = (GetSizeFn)dlsym(RTLD_DEFAULT, "AudioObjectGetPropertyDataSize");
        getData = (GetDataFn)dlsym(RTLD_DEFAULT, "AudioObjectGetPropertyData");
        if (!getData) { return 1; }

        char b[8];

        list(1, 'ownd', "owned objects");
        list(1, 'dev#', "devices");
        list(1, 'plg#', "plug-ins");
        list(1, 'box#', "boxes");
        list(1, 'clk#', "clock devices");
        // The VirtualAudio plug-in walks this list, not kAudioHardwarePropertyDevices,
        // and gives up without a word when it comes back empty.
        list(1, 'rdv#', "real devices");

        // A client may only be seeing a filtered system list; ask each plug-in
        // what it published, and what bundle it is, to tell the two apart.
        const AudioObjectID plugins[] = { 102, 101, 82, 89, 96, 95, 88, 108, 94, 93, 32, 81, 92 };
        for (unsigned i = 0; i < sizeof(plugins) / sizeof(plugins[0]); i++) {
            AudioObjectPropertyAddress bid = { 'piid', 'glob', 0 };
            CFStringRef                name = NULL;
            UInt32                     sz   = sizeof(name);
            char                       nb[128] = "?";
            if (getData(plugins[i], &bid, 0, NULL, &sz, &name) == 0 && name) {
                CFStringGetCString(name, nb, sizeof(nb), kCFStringEncodingUTF8);
            }
            printf("plug-in %u bundle=%s\n", plugins[i], nb);
            list(plugins[i], 'dev#', "its devices");
        }

        for (AudioObjectID probe = 2; probe < 400; probe++) {
            AudioObjectPropertyAddress addr = { 'clas', 'glob', 0 };
            UInt32                     cls  = 0;
            UInt32                     sz   = sizeof(cls);
            if (getData(probe, &addr, 0, NULL, &sz, &cls) != 0) { continue; }

            addr.selector = 'bcls';
            UInt32 base   = 0;
            sz            = sizeof(base);
            getData(probe, &addr, 0, NULL, &sz, &base);

            addr.selector = 'stdv';
            UInt32 owner  = 0;
            sz            = sizeof(owner);
            OSStatus ost  = getData(probe, &addr, 0, NULL, &sz, &owner);

            CFStringRef uid = NULL;
            addr.selector   = 'uid ';
            sz              = sizeof(uid);
            char uidBuf[96] = "-";
            if (getData(probe, &addr, 0, NULL, &sz, &uid) == 0 && uid) {
                CFStringGetCString(uid, uidBuf, sizeof(uidBuf), kCFStringEncodingUTF8);
            }

            char b2[8], b3[8];
            printf("[%3u] class=%s base=%s owner=%u(st=%s) uid=%s\n", probe, cc(cls, b), cc(base, b2), owner,
                   cc((UInt32)ost, b3), uidBuf);
        }
    }
    return 0;
}
