// Lists every HAL audio device with the facts the VirtualAudio plug-in matches
// against its transducer database: UID, transport, data sources and streams.
// The plug-in found no real transducer and fell back to Null_Device, so the
// question is what our devices fail to report.
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

static void sources(AudioObjectID dev, UInt32 scope, const char* label)
{
    AudioObjectPropertyAddress addr = { 'ssc#', scope, 0 };
    UInt32                     size = 0;
    char                       b[8];

    OSStatus st = getSize(dev, &addr, 0, NULL, &size);
    if (st != 0 || size == 0) {
        printf("    %s sources: none (st=%s size=%u)\n", label, cc((UInt32)st, b), size);
        return;
    }

    UInt32 ids[64] = { 0 };
    if (size > sizeof(ids)) { size = sizeof(ids); }
    st = getData(dev, &addr, 0, NULL, &size, ids);

    printf("    %s sources:", label);
    for (UInt32 i = 0; st == 0 && i < size / sizeof(UInt32); i++) { printf(" %s", cc(ids[i], b)); }
    printf("\n");

    AudioObjectPropertyAddress cur = { 'ssrc', scope, 0 };
    UInt32                     one = 0;
    size = sizeof(one);
    st   = getData(dev, &cur, 0, NULL, &size, &one);
    if (st == 0) { printf("    %s current source: %s\n", label, cc(one, b)); }
}

int main(void)
{
    @autoreleasepool {
        getSize = (GetSizeFn)dlsym(RTLD_DEFAULT, "AudioObjectGetPropertyDataSize");
        getData = (GetDataFn)dlsym(RTLD_DEFAULT, "AudioObjectGetPropertyData");
        if (!getData) { return 1; }

        char   b[8];
        UInt32 size = 0;

        // A client sees no device list on this guest — the HAL answers
        // kAudioHardwarePropertyDevices with nothing — so walk the object ids
        // and keep the ones that name themselves.
        AudioObjectID ids[64] = { 0 };
        UInt32        count   = 0;

        for (AudioObjectID probe = 2; probe < 400 && count < 64; probe++) {
            CFStringRef                uid  = NULL;
            AudioObjectPropertyAddress addr = { 'uid ', 'glob', 0 };
            UInt32                     sz   = sizeof(uid);
            if (getData(probe, &addr, 0, NULL, &sz, &uid) == 0 && uid != NULL) { ids[count++] = probe; }
        }

        printf("devices: %u\n", count);

        for (UInt32 i = 0; i < count; i++) {
            AudioObjectID dev = ids[i];

            CFStringRef                uid  = NULL;
            AudioObjectPropertyAddress addr = { 'uid ', 'glob', 0 };
            UInt32                     sz   = sizeof(uid);
            OSStatus                   st   = getData(dev, &addr, 0, NULL, &sz, &uid);

            char uidBuf[128] = "?";
            if (st == 0 && uid) { CFStringGetCString(uid, uidBuf, sizeof(uidBuf), kCFStringEncodingUTF8); }

            CFStringRef name  = NULL;
            addr.selector     = 'lnam';
            sz                = sizeof(name);
            st                = getData(dev, &addr, 0, NULL, &sz, &name);
            char nameBuf[128] = "?";
            if (st == 0 && name) { CFStringGetCString(name, nameBuf, sizeof(nameBuf), kCFStringEncodingUTF8); }

            UInt32 tran = 0;
            addr.selector = 'tran';
            sz            = sizeof(tran);
            getData(dev, &addr, 0, NULL, &sz, &tran);

            printf("\n[%u] uid=%s name=%s transport=%s\n", dev, uidBuf, nameBuf, cc(tran, b));

            for (int s = 0; s < 2; s++) {
                UInt32 scope = s == 0 ? 'outp' : 'inpt';
                AudioObjectPropertyAddress st_addr = { 'stm#', scope, 0 };
                UInt32 ssz = 0;
                getSize(dev, &st_addr, 0, NULL, &ssz);
                printf("    %s streams: %u\n", s == 0 ? "out" : "in", (unsigned)(ssz / sizeof(AudioObjectID)));
                sources(dev, scope, s == 0 ? "out" : "in");
            }
        }
    }
    return 0;
}
