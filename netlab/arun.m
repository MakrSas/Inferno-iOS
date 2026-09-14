// Asks the HAL to start the hardware device itself, with no route and no
// session. Nothing has ever made the guest write an MCA register, so the whole
// lower half of the path — kernel driver, DMA, the emulated MCA — is untested.
// If the device starts, the emulator's audio backend sees frames even if they
// are silence, and the remaining fault is entirely in the route layer above.
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <stdio.h>
#include <unistd.h>

typedef UInt32 AudioObjectID;

typedef struct {
    UInt32 selector;
    UInt32 scope;
    UInt32 element;
} AudioObjectPropertyAddress;

typedef OSStatus (*GetDataFn)(AudioObjectID, const AudioObjectPropertyAddress*, UInt32, const void*, UInt32*, void*);
typedef OSStatus (*SetDataFn)(AudioObjectID, const AudioObjectPropertyAddress*, UInt32, const void*, UInt32, const void*);
typedef OSStatus (*SettableFn)(AudioObjectID, const AudioObjectPropertyAddress*, Boolean*);

static const char* cc(UInt32 v, char b[8])
{
    char c[4] = { (char)(v >> 24), (char)(v >> 16), (char)(v >> 8), (char)v };
    for (int i = 0; i < 4; i++) {
        if (c[i] < 0x20 || c[i] > 0x7E) {
            snprintf(b, 8, "%d", (int)v);
            return b;
        }
    }
    snprintf(b, 8, "%c%c%c%c", c[0], c[1], c[2], c[3]);
    return b;
}

int main(int argc, char** argv)
{
    @autoreleasepool {
        GetDataFn  get      = (GetDataFn)dlsym(RTLD_DEFAULT, "AudioObjectGetPropertyData");
        SetDataFn  set      = (SetDataFn)dlsym(RTLD_DEFAULT, "AudioObjectSetPropertyData");
        SettableFn settable = (SettableFn)dlsym(RTLD_DEFAULT, "AudioObjectIsPropertySettable");
        if (!get || !set) { return 1; }

        AudioObjectID dev     = argc > 1 ? (AudioObjectID)atoi(argv[1]) : 51;
        int           seconds = argc > 2 ? atoi(argv[2]) : 6;
        char          b[8];

        const UInt32 props[] = { 'goin', 'gone', 'prwm' };
        for (int i = 0; i < 3; i++) {
            AudioObjectPropertyAddress addr = { props[i], 'glob', 0 };
            UInt32                     val  = 0;
            UInt32                     size = sizeof(val);
            OSStatus                   st   = get(dev, &addr, 0, NULL, &size, &val);
            Boolean                    can  = false;
            if (settable) { settable(dev, &addr, &can); }
            printf("%s: get st=%s value=%u settable=%d\n", cc(props[i], b), cc((UInt32)st, b), val, can);
        }

        AudioObjectPropertyAddress run = { 'goin', 'glob', 0 };
        UInt32                     one = 1;
        OSStatus st = set(dev, &run, 0, NULL, sizeof(one), &one);
        printf("start device %u: st=%s\n", dev, cc((UInt32)st, b));

        for (int i = 0; i < seconds; i++) {
            sleep(1);
            UInt32 val = 0, size = sizeof(val);
            get(dev, &run, 0, NULL, &size, &val);
            printf("t=%d running=%u\n", i + 1, val);
            fflush(stdout);
        }

        UInt32 zero = 0;
        st = set(dev, &run, 0, NULL, sizeof(zero), &zero);
        printf("stop: st=%s\n", cc((UInt32)st, b));
    }
    return 0;
}
