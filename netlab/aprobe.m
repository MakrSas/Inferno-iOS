// Asks the kernel what the audio server will not say: which audio services
// exist, whether an ordinary process may open them, and whether the registry
// ever goes quiet. The server holds an AOP audio client yet builds an empty
// route, so the question is which side refuses.
#import <Foundation/Foundation.h>
#include <IOKit/IOKitLib.h>
#include <stdio.h>
#include <math.h>
#include <unistd.h>
#include <dlfcn.h>
#include <sys/sysctl.h>
#include <stdlib.h>
#include <string.h>

static void show(const char* cls)
{
    io_iterator_t it = 0;
    kern_return_t kr = IOServiceGetMatchingServices(MACH_PORT_NULL, IOServiceMatching(cls), &it);
    if (kr != KERN_SUCCESS) {
        printf("%-34s matching failed 0x%x\n", cls, kr);
        return;
    }

    io_object_t obj;
    int seen = 0;
    while ((obj = IOIteratorNext(it))) {
        io_name_t name = { 0 };
        IORegistryEntryGetName(obj, name);

        uint32_t busy = 0;
        IOServiceGetBusyState(obj, &busy);

        io_connect_t conn = 0;
        kern_return_t open = IOServiceOpen(obj, mach_task_self(), 0, &conn);
        printf("%-34s %-36s busy=%u open=0x%x%s\n", seen ? "" : cls, name, busy, open,
               open == KERN_SUCCESS ? " OK" : "");
        if (open == KERN_SUCCESS) { IOServiceClose(conn); }

        IOObjectRelease(obj);
        seen++;
    }
    if (!seen) { printf("%-34s (no such services)\n", cls); }
    IOObjectRelease(it);
}


// The HAL's own view, asked directly. AVAudioSession says the route is empty;
// this says whether the layer underneath sees any hardware at all, which tells
// the two halves of the problem apart.
typedef UInt32 AudioObjectID;
typedef struct {
    UInt32 mSelector;
    UInt32 mScope;
    UInt32 mElement;
} AudioObjectPropertyAddress;

// Looked up at run time: on iOS these live in AudioToolbox but are not offered
// to the linker.
typedef OSStatus (*GetSizeFn)(AudioObjectID, const AudioObjectPropertyAddress*, UInt32, const void*,
                              UInt32*);
typedef OSStatus (*GetDataFn)(AudioObjectID, const AudioObjectPropertyAddress*, UInt32, const void*,
                              UInt32*, void*);
typedef OSStatus (*SetDataFn)(AudioObjectID, const AudioObjectPropertyAddress*, UInt32, const void*, UInt32,
                              const void*);

static void hal(void)
{
    GetSizeFn getSize = (GetSizeFn)dlsym(RTLD_DEFAULT, "AudioObjectGetPropertyDataSize");
    GetDataFn getData = (GetDataFn)dlsym(RTLD_DEFAULT, "AudioObjectGetPropertyData");
    printf("\nHAL: getSize=%p getData=%p\n", (void*)getSize, (void*)getData);
    if (!getSize || !getData) { return; }

    const AudioObjectID system = 1;
    AudioObjectPropertyAddress devices = { 'dev#', 'glob', 0 };
    UInt32 size = 0;
    OSStatus st = getSize(system, &devices, 0, NULL, &size);
    printf("HAL: device list st=%d, %u bytes (%u devices)\n", (int)st, size,
           (unsigned)(size / sizeof(AudioObjectID)));

    AudioObjectPropertyAddress defOutEarly = { 'dOut', 'glob', 0 };
    AudioObjectID early = 0;
    UInt32 earlySize = sizeof(early);
    printf("HAL: default output st=%d id=%u\n",
           (int)getData(system, &defOutEarly, 0, NULL, &earlySize, &early), early);
    if (early != 0) {
        // Ask one thing at a time and trust nothing: a refused property leaves
        // the buffer untouched, and reading it as an object would crash.
        AudioObjectPropertyAddress uidAddr = { 'uid ', 'glob', 0 };
        CFStringRef uid = NULL;
        UInt32 uidLen = sizeof(uid);
        OSStatus uidSt = getData(early, &uidAddr, 0, NULL, &uidLen, &uid);
        if (uidSt == 0 && uidLen == sizeof(uid) && uid != NULL) {
            char text[128] = { 0 };
            CFStringGetCString(uid, text, sizeof(text), kCFStringEncodingUTF8);
            printf("HAL:   UID = %s\n", text);
            CFRelease(uid);
        } else {
            printf("HAL:   UID st=%d len=%u\n", (int)uidSt, uidLen);
        }

        AudioObjectPropertyAddress tranAddr = { 'tran', 'glob', 0 };
        UInt32 tran = 0, tranLen = sizeof(tran);
        OSStatus tranSt = getData(early, &tranAddr, 0, NULL, &tranLen, &tran);
        printf("HAL:   transport st=%d '%c%c%c%c'\n", (int)tranSt,
               (tran >> 24) & 0xFF, (tran >> 16) & 0xFF, (tran >> 8) & 0xFF, tran & 0xFF);

        AudioObjectPropertyAddress rateAddr = { 'nsrt', 'glob', 0 };
        Float64 hz = 0;
        UInt32 hzLen = sizeof(hz);
        OSStatus hzSt = getData(early, &rateAddr, 0, NULL, &hzLen, &hz);
        printf("HAL:   sample rate st=%d %.0f\n", (int)hzSt, hz);
    }
    // The device list is closed to clients, but a lookup by UID is not: this
    // says outright whether the built-in speaker reached the audio server.
    typedef struct {
        void*  inputData;
        UInt32 inputDataSize;
        void*  outputData;
        UInt32 outputDataSize;
    } Translation;
    const char* wanted[] = { "Speaker", "Codec", "USB Audio Output" };
    for (size_t i = 0; i < sizeof(wanted) / sizeof(*wanted); i++) {
        CFStringRef uidText = CFStringCreateWithCString(NULL, wanted[i], kCFStringEncodingUTF8);
        AudioObjectID found = 0;
        Translation ask = { &uidText, sizeof(uidText), &found, sizeof(found) };
        AudioObjectPropertyAddress byUID = { 'duid', 'glob', 0 };
        UInt32 askSize = sizeof(ask);
        OSStatus r = getData(system, &byUID, 0, NULL, &askSize, &ask);
        printf("HAL:   lookup %-18s st=%d id=%u\n", wanted[i], (int)r, found);
        CFRelease(uidText);
    }

    // What the server thinks of each device it knows: a device that is alive and
    // has an output stream is one the session layer could route to.
    const AudioObjectID known[] = { 55, 37, 33 };
    for (size_t i = 0; i < sizeof(known) / sizeof(*known); i++) {
        AudioObjectID dev = known[i];
        UInt32 alive = 0, aliveLen = sizeof(alive);
        AudioObjectPropertyAddress aliveAddr = { 'livn', 'glob', 0 };
        OSStatus aliveSt = getData(dev, &aliveAddr, 0, NULL, &aliveLen, &alive);

        UInt32 canDefault = 0, canLen = sizeof(canDefault);
        AudioObjectPropertyAddress canAddr = { 'dflt', 'outp', 0 };
        OSStatus canSt = getData(dev, &canAddr, 0, NULL, &canLen, &canDefault);

        UInt32 streamBytes = 0;
        AudioObjectPropertyAddress streamAddr = { 'stm#', 'outp', 0 };
        OSStatus streamSt = getSize(dev, &streamAddr, 0, NULL, &streamBytes);

        Float64 hz = 0;
        UInt32 hzLen = sizeof(hz);
        AudioObjectPropertyAddress hzAddr = { 'nsrt', 'glob', 0 };
        OSStatus hzSt = getData(dev, &hzAddr, 0, NULL, &hzLen, &hz);

        printf("HAL:   dev %u alive(st=%d)=%u canBeDefault(st=%d)=%u outStreams(st=%d)=%u rate(st=%d)=%.0f\n",
               dev, (int)aliveSt, alive, (int)canSt, canDefault, (int)streamSt, streamBytes / 4,
               (int)hzSt, hz);
    }

    // The speaker is healthy but the system picked USB. Ask the server to make
    // the speaker the default output and see whether it takes.
    SetDataFn setData = (SetDataFn)dlsym(RTLD_DEFAULT, "AudioObjectSetPropertyData");
    if (setData) {
        // The server picked the speaker as the input device too — it has the
        // amplifier's current-sense streams. The microphones are on the codec,
        // so point each direction at the device that actually has it.
        {
            typedef struct { void* i; UInt32 iz; void* o; UInt32 oz; } ByUID3;
            CFStringRef codecUID = CFSTR("Codec");
            AudioObjectID codec = 0;
            ByUID3 ask3 = { &codecUID, sizeof(codecUID), &codec, sizeof(codec) };
            AudioObjectPropertyAddress byUID3 = { 'duid', 'glob', 0 };
            UInt32 ask3Size = sizeof(ask3);
            getData(system, &byUID3, 0, NULL, &ask3Size, &ask3);
            AudioObjectPropertyAddress defInAddr2 = { 'dIn ', 'glob', 0 };
            OSStatus inSt = setData(system, &defInAddr2, 0, NULL, sizeof(codec), &codec);
            AudioObjectID nowIn = 0;
            UInt32 nowInLen = sizeof(nowIn);
            getData(system, &defInAddr2, 0, NULL, &nowInLen, &nowIn);
            printf("HAL:   set default input -> Codec(%u): st=%d, now id=%u\n", codec, (int)inSt, nowIn);
        }

        AudioObjectPropertyAddress defOutAddr = { 'dOut', 'glob', 0 };
        typedef struct {
            void*  inputData;
            UInt32 inputDataSize;
            void*  outputData;
            UInt32 outputDataSize;
        } Lookup;
        CFStringRef wantUID = CFSTR("Speaker");
        AudioObjectID speaker = 0;
        Lookup ask = { &wantUID, sizeof(wantUID), &speaker, sizeof(speaker) };
        AudioObjectPropertyAddress byUID = { 'duid', 'glob', 0 };
        UInt32 askSize = sizeof(ask);
        getData(system, &byUID, 0, NULL, &askSize, &ask);
        printf("HAL:   Speaker id=%u\n", speaker);
        OSStatus setSt = setData(system, &defOutAddr, 0, NULL, sizeof(speaker), &speaker);
        AudioObjectID now = 0;
        UInt32 nowLen = sizeof(now);
        getData(system, &defOutAddr, 0, NULL, &nowLen, &now);
        printf("HAL:   set default output -> 55: st=%d, now id=%u\n", (int)setSt, now);
    }

    // The session has neither outputs nor inputs. If the server has no input
    // device either, route building may be refusing for that reason.
    AudioObjectPropertyAddress defInAddr = { 'dIn ', 'glob', 0 };
    AudioObjectID defIn = 0;
    UInt32 defInLen = sizeof(defIn);
    printf("HAL:   default input st=%d id=%u\n",
           (int)getData(system, &defInAddr, 0, NULL, &defInLen, &defIn), defIn);

    typedef struct {
        void*  inputData;
        UInt32 inputDataSize;
        void*  outputData;
        UInt32 outputDataSize;
    } ByUID;
    const char* names[] = { "AOP Audio-1", "VirtualAudioDevice_Default",
                            "VirtualAudioDevice_SystemLocal", "VirtualAudioDevice_SystemRemote",
                            "VirtualAudioDevice_SpeakerAlert", "VirtualAudioDevice_Actuator" };
    for (size_t i = 0; i < sizeof(names) / sizeof(*names); i++) {
        CFStringRef want = CFStringCreateWithCString(NULL, names[i], kCFStringEncodingUTF8);
        AudioObjectID got = 0;
        ByUID ask = { &want, sizeof(want), &got, sizeof(got) };
        AudioObjectPropertyAddress byUID = { 'duid', 'glob', 0 };
        UInt32 askSize = sizeof(ask);
        OSStatus r = getData(system, &byUID, 0, NULL, &askSize, &ask);
        printf("HAL:   lookup %-20s st=%d id=%u\n", names[i], (int)r, got);
        CFRelease(want);
    }

    // Ports are named after the device's data sources. If the speaker has none,
    // the session has nothing to call the port.
    {
        AudioObjectID dev = 0;
        typedef struct { void* i; UInt32 iz; void* o; UInt32 oz; } ByUID2;
        const char* who[] = { "Speaker", "Codec" };
      for (size_t w = 0; w < 2; w++) {
        CFStringRef want = CFStringCreateWithCString(NULL, who[w], kCFStringEncodingUTF8);
        ByUID2 ask = { &want, sizeof(want), &dev, sizeof(dev) };
        AudioObjectPropertyAddress byUID = { 'duid', 'glob', 0 };
        UInt32 askSize = sizeof(ask);
        getData(system, &byUID, 0, NULL, &askSize, &ask);

        const UInt32 scopes[] = { 'glob', 'outp', 'inpt' };
        for (size_t sc = 0; sc < 3; sc++) {
            AudioObjectPropertyAddress sources = { 'ssc#', scopes[sc], 0 };
            UInt32 bytes = 0;
            OSStatus r = getSize(dev, &sources, 0, NULL, &bytes);
            UInt32 list[8] = { 0 };
            UInt32 take = bytes > sizeof(list) ? sizeof(list) : bytes;
            if (r == 0 && take) { getData(dev, &sources, 0, NULL, &take, list); }
            printf("HAL:   dev %u scope '%.4s' dataSources st=%d n=%u:", dev, (const char*)&scopes[sc],
                   (int)r, bytes / 4);
            for (UInt32 i = 0; i < take / 4; i++) {
                printf(" '%c%c%c%c'", (list[i] >> 24) & 0xFF, (list[i] >> 16) & 0xFF,
                       (list[i] >> 8) & 0xFF, list[i] & 0xFF);
            }
            printf("\n");
        }
        AudioObjectPropertyAddress cur = { 'ssrc', 'outp', 0 };
        UInt32 curVal = 0, curLen = sizeof(curVal);
        printf("HAL:   dev %u (%s) current source st=%d\n", dev, who[w],
               (int)getData(dev, &cur, 0, NULL, &curLen, &curVal));
        CFRelease(want);
      }
    }

    if (st != 0 || size == 0) { return; }

    AudioObjectPropertyAddress defOut = { 'dOut', 'glob', 0 };
    AudioObjectID out = 0;
    UInt32 outSize = sizeof(out);
    OSStatus one = getData(system, &defOut, 0, NULL, &outSize, &out);
    printf("HAL: default output st=%d id=%u\n", (int)one, out);

    AudioObjectID ids[32] = { 0 };
    if (size > sizeof(ids)) { size = sizeof(ids); }
    st = getData(system, &devices, 0, NULL, &size, ids);
    printf("HAL: device list st=%d\n", (int)st);
    for (UInt32 i = 0; st == 0 && i < size / sizeof(AudioObjectID); i++) {
        AudioObjectPropertyAddress uid = { 'uid ', 'glob', 0 };
        CFStringRef name = NULL;
        UInt32 len = sizeof(name);
        OSStatus one = getData(ids[i], &uid, 0, NULL, &len, &name);
        printf("  device %u: id=%u uid=%s\n", i, ids[i],
               (one == 0 && name) ? [(__bridge NSString*)name UTF8String] : "?");
        if (name) { CFRelease(name); }
    }
}


// Two questions the first probe left open: does the CoreAudio family see these
// devices as its own (matching by IOAudio2Device catches subclasses), and who
// provides them. The HAL finds hardware one of those two ways.
static void lineage(void)
{
    printf("\n=== lineage and family ===\n");
    const char* families[] = { "IOAudio2Device", "IOAudioDevice", "AppleEmbeddedAudioDevice" };
    for (size_t f = 0; f < sizeof(families) / sizeof(*families); f++) {
        io_iterator_t it = 0;
        int n = 0;
        if (IOServiceGetMatchingServices(MACH_PORT_NULL, IOServiceMatching(families[f]), &it) == KERN_SUCCESS) {
            io_object_t o;
            while ((o = IOIteratorNext(it))) { n++; IOObjectRelease(o); }
            IOObjectRelease(it);
        }
        printf("  class %-26s matched %d\n", families[f], n);
    }

    io_iterator_t it = 0;
    if (IOServiceGetMatchingServices(MACH_PORT_NULL, IOServiceMatching("AppleEmbeddedAudioDevice"), &it)
        != KERN_SUCCESS) { return; }
    io_object_t dev;
    while ((dev = IOIteratorNext(it))) {
        io_name_t name = { 0 };
        IORegistryEntryGetName(dev, name);
        printf("  %s <- ", name);
        io_object_t node = dev;
        IOObjectRetain(node);
        for (int up = 0; up < 4; up++) {
            io_object_t parent = 0;
            if (IORegistryEntryGetParentEntry(node, "IOService", &parent) != KERN_SUCCESS) { break; }
            io_name_t pname = { 0 };
            IORegistryEntryGetName(parent, pname);
            printf("%s%s", up ? " <- " : "", pname);
            IOObjectRelease(node);
            node = parent;
        }
        IOObjectRelease(node);
        printf("\n");

        // Which user-client type the device will take, if any.
        for (uint32_t type = 0; type < 4; type++) {
            io_connect_t conn = 0;
            kern_return_t kr = IOServiceOpen(dev, mach_task_self(), type, &conn);
            printf("     open type=%u -> 0x%x%s\n", type, kr, kr == KERN_SUCCESS ? " OK" : "");
            if (kr == KERN_SUCCESS) { IOServiceClose(conn); }
        }
        IOObjectRelease(dev);
    }
    IOObjectRelease(it);
}


// The question the registry cannot answer: would the sandbox let the audio
// server open the device? `sandbox_check` asks on behalf of another process, so
// this settles it without touching a single system file.

// Playing straight through the HAL, with the session layer left out of it. If
// samples reach the emulator this way, the hardware path is whole and the fault
// is upstream, in whatever hands out audio routes.
int main(void)
{
    @autoreleasepool {
        const char* classes[] = {
            "AppleEmbeddedAudioDevice", "AudioKernelClientInterface",
            "AppleEmbeddedAudioResourceManager", "AppleAOPAudioDeviceProvider",
            "AppleAOPAudioPCMAssetManagerDevice", "IOAudioCodecs", "AppleCS42L77Audio",
        };
        for (size_t i = 0; i < sizeof(classes) / sizeof(*classes); i++) { show(classes[i]); }

        // The one structural oddity left: two branches never stop being busy, so
        // the whole tree never quiets. Anything waiting on that waits forever.
        io_service_t root = IOServiceGetMatchingService(MACH_PORT_NULL,
                                                        IOServiceMatching("IOPlatformExpertDevice"));
        uint32_t busy = 0;
        IOServiceGetBusyState(root, &busy);
        printf("\nplatform busy=%u\n", busy);

        mach_timespec_t wait = { .tv_sec = 3, .tv_nsec = 0 };
        kern_return_t quiet = IOServiceWaitQuiet(root, &wait);
        printf("WaitQuiet(3s) = 0x%x %s\n", quiet,
               quiet == KERN_SUCCESS ? "quiet" : "NOT quiet");
        IOObjectRelease(root);

        hal();
        lineage();
    }
    return 0;
}
