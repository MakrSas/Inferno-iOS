// Renders a tone straight into the HAL's output device, with no AVAudioSession
// and no route involved. The session layer builds an empty route and throws
// `nort`, so nothing has ever asked the kernel to play; this asks it directly.
// If samples reach the emulated MCA the lower half of the path is sound and the
// bug is purely in the route layer above it.
#import <Foundation/Foundation.h>
#include <CoreAudioTypes/CoreAudioTypes.h>
#include <dlfcn.h>
#include <math.h>
#include <stdio.h>
#include <unistd.h>

typedef UInt32 AudioObjectID;
typedef void*  AudioDeviceIOProcID;

typedef struct {
    UInt32 selector;
    UInt32 scope;
    UInt32 element;
} AudioObjectPropertyAddress;

typedef OSStatus (*GetSizeFn)(AudioObjectID, const AudioObjectPropertyAddress*, UInt32, const void*, UInt32*);
typedef OSStatus (*GetDataFn)(AudioObjectID, const AudioObjectPropertyAddress*, UInt32, const void*, UInt32*, void*);
typedef OSStatus (*IOProcFn)(AudioObjectID, const AudioTimeStamp*, const AudioBufferList*, const AudioTimeStamp*,
                             AudioBufferList*, const AudioTimeStamp*, void*);
typedef OSStatus (*CreateIOProcFn)(AudioObjectID, IOProcFn, void*, AudioDeviceIOProcID*);
typedef OSStatus (*DeviceCtlFn)(AudioObjectID, AudioDeviceIOProcID);

static GetSizeFn getSize;
static GetDataFn getData;

// Errors from this layer are four-character codes far more often than numbers.
static const char* fourcc(OSStatus st, char buf[8])
{
    UInt32 v = (UInt32)st;
    char   c[4] = { (char)(v >> 24), (char)(v >> 16), (char)(v >> 8), (char)v };
    for (int i = 0; i < 4; i++) {
        if (c[i] < 0x20 || c[i] > 0x7E) {
            snprintf(buf, 8, "%d", (int)st);
            return buf;
        }
    }
    snprintf(buf, 8, "'%c%c%c%c'", c[0], c[1], c[2], c[3]);
    return buf;
}

static UInt32 g_calls;
static UInt64 g_frames;
static double g_phase;
static UInt32 g_lastBuffers;
static UInt32 g_lastBytes;
static UInt32 g_lastChannels;
static double g_rate = 48000.0;

static OSStatus render(AudioObjectID dev, const AudioTimeStamp* now, const AudioBufferList* in,
                       const AudioTimeStamp* inTime, AudioBufferList* out, const AudioTimeStamp* outTime, void* ctx)
{
    (void)dev; (void)now; (void)in; (void)inTime; (void)outTime; (void)ctx;
    if (out == NULL) { return 0; }

    g_calls++;
    g_lastBuffers = out->mNumberBuffers;

    for (UInt32 b = 0; b < out->mNumberBuffers; b++) {
        AudioBuffer* buf = &out->mBuffers[b];
        if (buf->mData == NULL) { continue; }

        UInt32 channels = buf->mNumberChannels ? buf->mNumberChannels : 1;
        UInt32 frames   = buf->mDataByteSize / (sizeof(float) * channels);
        float* p        = (float*)buf->mData;

        g_lastBytes    = buf->mDataByteSize;
        g_lastChannels = channels;

        for (UInt32 f = 0; f < frames; f++) {
            float s = (float)(0.25 * sin(g_phase));
            g_phase += 2.0 * M_PI * 440.0 / g_rate;
            if (g_phase > 2.0 * M_PI) { g_phase -= 2.0 * M_PI; }
            for (UInt32 c = 0; c < channels; c++) { p[f * channels + c] = s; }
        }
        if (b == 0) { g_frames += frames; }
    }
    return 0;
}

static AudioObjectID byUID(const char* uid)
{
    typedef struct { void* in; UInt32 inSize; void* out; UInt32 outSize; } Translation;

    CFStringRef  name  = CFStringCreateWithCString(NULL, uid, kCFStringEncodingUTF8);
    AudioObjectID found = 0;
    Translation  t     = { &name, sizeof(name), &found, sizeof(found) };
    UInt32       size  = sizeof(t);

    AudioObjectPropertyAddress addr = { 'duid', 'glob', 0 };
    OSStatus st = getData(1, &addr, sizeof(t), &t, &size, &t);
    CFRelease(name);
    return st == 0 ? found : 0;
}

int main(int argc, char** argv)
{
    @autoreleasepool {
        getSize = (GetSizeFn)dlsym(RTLD_DEFAULT, "AudioObjectGetPropertyDataSize");
        getData = (GetDataFn)dlsym(RTLD_DEFAULT, "AudioObjectGetPropertyData");
        CreateIOProcFn createProc = (CreateIOProcFn)dlsym(RTLD_DEFAULT, "AudioDeviceCreateIOProcID");
        DeviceCtlFn    startDev   = (DeviceCtlFn)dlsym(RTLD_DEFAULT, "AudioDeviceStart");
        DeviceCtlFn    stopDev    = (DeviceCtlFn)dlsym(RTLD_DEFAULT, "AudioDeviceStop");

        printf("symbols get=%p create=%p start=%p stop=%p\n", (void*)getData, (void*)createProc, (void*)startDev,
               (void*)stopDev);
        if (!getData || !createProc || !startDev) { return 1; }

        char buf[8];
        int  seconds = argc > 1 ? atoi(argv[1]) : 6;

        AudioObjectID dev = argc > 2 ? byUID(argv[2]) : 0;
        if (dev == 0) {
            AudioObjectPropertyAddress defOut = { 'dOut', 'glob', 0 };
            UInt32                     size   = sizeof(dev);
            OSStatus st = getData(1, &defOut, 0, NULL, &size, &dev);
            printf("default output: dev=%u st=%s\n", dev, fourcc(st, buf));
        }
        else {
            printf("device by uid %s: dev=%u\n", argv[2], dev);
        }
        if (dev == 0) { return 2; }

        AudioObjectPropertyAddress rateAddr = { 'nsrt', 'glob', 0 };
        UInt32                     size     = sizeof(g_rate);
        OSStatus st = getData(dev, &rateAddr, 0, NULL, &size, &g_rate);
        printf("nominal rate: %.0f st=%s\n", g_rate, fourcc(st, buf));
        if (g_rate < 8000.0) { g_rate = 48000.0; }

        AudioObjectPropertyAddress fmtAddr = { 'sfmt', 'outp', 0 };
        AudioStreamBasicDescription asbd   = { 0 };
        size = sizeof(asbd);
        st   = getData(dev, &fmtAddr, 0, NULL, &size, &asbd);
        printf("stream format: st=%s rate=%.0f ch=%u bits=%u flags=0x%x\n", fourcc(st, buf), asbd.mSampleRate,
               (unsigned)asbd.mChannelsPerFrame, (unsigned)asbd.mBitsPerChannel, (unsigned)asbd.mFormatFlags);

        AudioObjectPropertyAddress bufAddr = { 'fsiz', 'outp', 0 };
        UInt32                     bufFrames = 0;
        size = sizeof(bufFrames);
        st   = getData(dev, &bufAddr, 0, NULL, &size, &bufFrames);
        printf("buffer frames: %u st=%s\n", bufFrames, fourcc(st, buf));

        AudioDeviceIOProcID proc = NULL;
        st = createProc(dev, render, NULL, &proc);
        printf("create ioproc: st=%s proc=%p\n", fourcc(st, buf), proc);
        if (st != 0) { return 3; }

        st = startDev(dev, proc);
        printf("start: st=%s\n", fourcc(st, buf));
        if (st != 0) { return 4; }

        for (int i = 0; i < seconds; i++) {
            sleep(1);
            printf("t=%ds calls=%u frames=%llu buffers=%u bytes=%u ch=%u\n", i + 1, g_calls,
                   (unsigned long long)g_frames, g_lastBuffers, g_lastBytes, g_lastChannels);
            fflush(stdout);
        }

        if (stopDev) { stopDev(dev, proc); }
        printf("done calls=%u frames=%llu\n", g_calls, (unsigned long long)g_frames);
    }
    return 0;
}
