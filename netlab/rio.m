// Asks for output the way an app does — a RemoteIO audio unit — and prints the
// status of each step, so a refusal can be told apart from silence.
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#include <math.h>
#include <stdio.h>

static double phase = 0.0;

static OSStatus render(void* ref, AudioUnitRenderActionFlags* flags, const AudioTimeStamp* ts,
                       UInt32 bus, UInt32 frames, AudioBufferList* io)
{
    int16_t* out = (int16_t*)io->mBuffers[0].mData;

    for (UInt32 i = 0; i < frames; i++) {
        int16_t v = (int16_t)(0.5 * 32767.0 * sin(phase));
        phase += 2.0 * M_PI * 440.0 / 48000.0;
        if (phase > 2.0 * M_PI) { phase -= 2.0 * M_PI; }
        out[i] = v;
    }
    return noErr;
}

int main(void)
{
    @autoreleasepool {
        NSError* err = nil;

        printf("step 1: session\n"); fflush(stdout);
        AVAudioSession* s = [AVAudioSession sharedInstance];
        [s setCategory:AVAudioSessionCategoryPlayback error:&err];
        printf("category: %s\n", err ? err.description.UTF8String : "ok"); fflush(stdout);
        err = nil;
        [s setActive:YES error:&err];
        printf("active: %s\n", err ? err.description.UTF8String : "ok"); fflush(stdout);
        printf("outputs: %lu\n", (unsigned long)s.currentRoute.outputs.count); fflush(stdout);

        printf("step 2: unit\n"); fflush(stdout);
        AudioComponentDescription d = { 0 };
        d.componentType         = kAudioUnitType_Output;
        d.componentSubType      = kAudioUnitSubType_RemoteIO;
        d.componentManufacturer = kAudioUnitManufacturer_Apple;

        AudioComponent  comp = AudioComponentFindNext(NULL, &d);
        AudioUnit       unit = NULL;
        OSStatus        st   = AudioComponentInstanceNew(comp, &unit);
        printf("new: %d\n", (int)st); fflush(stdout);

        AudioStreamBasicDescription f = { 0 };
        f.mSampleRate       = 48000;
        f.mFormatID         = kAudioFormatLinearPCM;
        f.mFormatFlags      = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
        f.mChannelsPerFrame = 1;
        f.mBitsPerChannel   = 16;
        f.mFramesPerPacket  = 1;
        f.mBytesPerFrame    = 2;
        f.mBytesPerPacket   = 2;
        st = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
                                  &f, sizeof(f));
        printf("format: %d\n", (int)st); fflush(stdout);

        AURenderCallbackStruct cb = { render, NULL };
        st = AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input,
                                  0, &cb, sizeof(cb));
        printf("callback: %d\n", (int)st); fflush(stdout);

        st = AudioUnitInitialize(unit);
        printf("init: %d\n", (int)st); fflush(stdout);
        st = AudioOutputUnitStart(unit);
        printf("start: %d\n", (int)st); fflush(stdout);

        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 5.0, false);
        AudioOutputUnitStop(unit);
        printf("done\n"); fflush(stdout);
    }
    return 0;
}
