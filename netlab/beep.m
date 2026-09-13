// Plays a sine tone inside the guest through the normal iOS audio path, so the
// emulated speaker can be verified without anyone listening: whatever reaches
// the MCA lands in the host-side wav file.
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>

static const double kRate = 48000.0;
static double       freq  = 440.0;
static double       phase = 0.0;

static void fill(void* opaque, AudioQueueRef queue, AudioQueueBufferRef buf)
{
    int16_t* out    = (int16_t*)buf->mAudioData;
    UInt32   frames = buf->mAudioDataBytesCapacity / 4;

    for (UInt32 i = 0; i < frames; i++) {
        int16_t v = (int16_t)(0.5 * 32767.0 * sin(phase));
        phase += 2.0 * M_PI * freq / kRate;
        if (phase > 2.0 * M_PI) { phase -= 2.0 * M_PI; }
        out[2 * i] = v;
        out[2 * i + 1] = v;
    }
    buf->mAudioDataByteSize = frames * 4;
    AudioQueueEnqueueBuffer(queue, buf, 0, NULL);
}

int main(int argc, char** argv)
{
    double seconds = argc > 1 ? atof(argv[1]) : 5.0;

    @autoreleasepool {
        NSError*        err     = nil;
        AVAudioSession* session = [AVAudioSession sharedInstance];

        [session setCategory:AVAudioSessionCategoryPlayAndRecord
                 withOptions:AVAudioSessionCategoryOptionDefaultToSpeaker
                       error:&err];
        printf("category err: %s\n", err ? err.description.UTF8String : "none");
        err = nil;
        [session setActive:YES error:&err];
        printf("active err: %s\n", err ? err.description.UTF8String : "none");
        err = nil;
        [session overrideOutputAudioPort:AVAudioSessionPortOverrideSpeaker error:&err];
        printf("override err: %s\n", err ? err.description.UTF8String : "none");
        printf("volume %.2f\n", session.outputVolume);
        printf("outputs %s\n", session.currentRoute.outputs.description.UTF8String);
        printf("inputs %s\n", session.currentRoute.inputs.description.UTF8String);
        printf("available inputs %s\n", session.availableInputs.description.UTF8String);
        printf("sample rate %.0f, output channels %ld\n", session.sampleRate,
               (long)session.outputNumberOfChannels);

        AudioStreamBasicDescription fmt = { 0 };
        fmt.mSampleRate       = kRate;
        fmt.mFormatID         = kAudioFormatLinearPCM;
        fmt.mFormatFlags      = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
        fmt.mChannelsPerFrame = 2;
        fmt.mBitsPerChannel   = 16;
        fmt.mFramesPerPacket  = 1;
        fmt.mBytesPerFrame    = 4;
        fmt.mBytesPerPacket   = 4;

        AudioQueueRef queue = NULL;
        OSStatus      st    = AudioQueueNewOutput(&fmt, fill, NULL, NULL, NULL, 0, &queue);
        printf("new output: %d\n", (int)st);
        if (st != noErr) { return 1; }

        for (int i = 0; i < 3; i++) {
            AudioQueueBufferRef buf = NULL;
            AudioQueueAllocateBuffer(queue, 4096 * 4, &buf);
            fill(NULL, queue, buf);
        }
        AudioQueueSetParameter(queue, kAudioQueueParam_Volume, 1.0f);
        st = AudioQueueStart(queue, NULL);
        printf("start: %d\n", (int)st);
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, seconds, false);
        AudioQueueStop(queue, true);
        printf("done\n");
    }
    return 0;
}
