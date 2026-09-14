// Plays a tone through the ordinary iOS path: an audio session, a route and an
// AudioQueue. Everything below this has been in place for a while; what was
// missing was a route, so this is the check that the whole chain now carries
// samples from an app to the emulated speaker.
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#include <math.h>
#include <stdio.h>

static double   g_phase;
static double   g_rate = 44100.0;
static UInt32   g_filled;

static void fill(void* user, AudioQueueRef queue, AudioQueueBufferRef buffer)
{
    (void)user;
    SInt16* p      = (SInt16*)buffer->mAudioData;
    UInt32  frames = buffer->mAudioDataBytesCapacity / (sizeof(SInt16) * 2);

    for (UInt32 f = 0; f < frames; f++) {
        SInt16 s = (SInt16)(12000.0 * sin(g_phase));
        g_phase += 2.0 * M_PI * 440.0 / g_rate;
        if (g_phase > 2.0 * M_PI) { g_phase -= 2.0 * M_PI; }
        p[f * 2] = s;
        p[f * 2 + 1] = s;
    }

    buffer->mAudioDataByteSize = frames * sizeof(SInt16) * 2;
    g_filled += frames;
    AudioQueueEnqueueBuffer(queue, buffer, 0, NULL);
}

static void route(const char* when)
{
    AVAudioSession* s = [AVAudioSession sharedInstance];
    printf("[%s] outputs=%lu inputs=%lu\n", when, (unsigned long)s.currentRoute.outputs.count,
           (unsigned long)s.currentRoute.inputs.count);
    for (AVAudioSessionPortDescription* p in s.currentRoute.outputs) {
        printf("    out: type=%s name=%s uid=%s\n", p.portType.UTF8String, p.portName.UTF8String,
               p.UID.UTF8String);
    }
    printf("[%s] outputVolume=%.2f sampleRate=%.0f outputChannels=%ld\n", when, s.outputVolume,
           s.sampleRate, (long)s.outputNumberOfChannels);
}

int main(int argc, char** argv)
{
    @autoreleasepool {
        int    seconds = argc > 1 ? atoi(argv[1]) : 6;
        NSError* err   = nil;

        AVAudioSession* session = [AVAudioSession sharedInstance];
        route("before");

        if (![session setCategory:AVAudioSessionCategoryPlayback error:&err]) {
            printf("setCategory failed: %s\n", err.description.UTF8String);
        }
        if (![session setActive:YES error:&err]) {
            printf("setActive failed: %s\n", err.description.UTF8String);
        }
        route("after");

        g_rate = session.sampleRate > 8000 ? session.sampleRate : 44100.0;

        AudioStreamBasicDescription fmt = { 0 };
        fmt.mSampleRate       = g_rate;
        fmt.mFormatID         = kAudioFormatLinearPCM;
        fmt.mFormatFlags      = kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked;
        fmt.mChannelsPerFrame = 2;
        fmt.mBitsPerChannel   = 16;
        fmt.mFramesPerPacket  = 1;
        fmt.mBytesPerFrame    = 4;
        fmt.mBytesPerPacket   = 4;

        AudioQueueRef queue = NULL;
        OSStatus st = AudioQueueNewOutput(&fmt, fill, NULL, NULL, NULL, 0, &queue);
        printf("AudioQueueNewOutput: %d\n", (int)st);
        if (st != 0) { return 2; }

        for (int i = 0; i < 3; i++) {
            AudioQueueBufferRef buf = NULL;
            st = AudioQueueAllocateBuffer(queue, 8192, &buf);
            if (st != 0) { printf("AllocateBuffer: %d\n", (int)st); return 3; }
            fill(NULL, queue, buf);
        }

        st = AudioQueueStart(queue, NULL);
        printf("AudioQueueStart: %d\n", (int)st);
        if (st != 0) { return 4; }

        for (int i = 0; i < seconds; i++) {
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1.0]];
            printf("t=%ds framesQueued=%u\n", i + 1, g_filled);
            fflush(stdout);
        }

        AudioQueueStop(queue, true);
        printf("done framesQueued=%u\n", g_filled);
    }
    return 0;
}
