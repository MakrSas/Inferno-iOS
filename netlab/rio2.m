// The same question as rio, asked more insistently: the session is told to
// default to the speaker and then to override the route to it outright. Each
// step prints what the session answered, so a refusal is told from silence.
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
        out[i] = (int16_t)(0.5 * 32767.0 * sin(phase));
        phase += 2.0 * M_PI * 440.0 / 48000.0;
        if (phase > 2.0 * M_PI) { phase -= 2.0 * M_PI; }
    }
    return noErr;
}

static void show(AVAudioSession* s, const char* when)
{
    printf("%-22s outputs=%lu inputs=%lu available=%lu rate=%.0f\n", when,
           (unsigned long)s.currentRoute.outputs.count, (unsigned long)s.currentRoute.inputs.count,
           (unsigned long)s.availableInputs.count, s.sampleRate);
    for (AVAudioSessionPortDescription* p in s.currentRoute.outputs) {
        printf("   output: %s (%s)\n", p.portName.UTF8String, p.portType.UTF8String);
    }
    fflush(stdout);
}

int main(void)
{
    @autoreleasepool {
        AVAudioSession* s = [AVAudioSession sharedInstance];
        NSError*        err = nil;

        [s setCategory:AVAudioSessionCategoryPlayAndRecord
           withOptions:AVAudioSessionCategoryOptionDefaultToSpeaker
                 error:&err];
        printf("category PlayAndRecord+DefaultToSpeaker: %s\n",
               err ? err.description.UTF8String : "ok");
        fflush(stdout);

        err = nil;
        [s setActive:YES error:&err];
        printf("active: %s\n", err ? err.description.UTF8String : "ok");
        show(s, "after activation");

        err = nil;
        BOOL over = [s overrideOutputAudioPort:AVAudioSessionPortOverrideSpeaker error:&err];
        printf("override -> speaker: %s (%s)\n", over ? "yes" : "no",
               err ? err.description.UTF8String : "no error");
        show(s, "after override");

        err = nil;
        [s setPreferredSampleRate:48000 error:&err];
        printf("preferred rate: %s\n", err ? err.description.UTF8String : "ok");
        show(s, "after sample rate");

        AudioComponentDescription d = { 0 };
        d.componentType         = kAudioUnitType_Output;
        d.componentSubType      = kAudioUnitSubType_RemoteIO;
        d.componentManufacturer = kAudioUnitManufacturer_Apple;
        AudioComponent comp = AudioComponentFindNext(NULL, &d);
        AudioUnit      unit = NULL;
        printf("new: %d\n", (int)AudioComponentInstanceNew(comp, &unit));

        AudioStreamBasicDescription f = { 0 };
        f.mSampleRate       = 48000;
        f.mFormatID         = kAudioFormatLinearPCM;
        f.mFormatFlags      = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
        f.mChannelsPerFrame = 1;
        f.mBitsPerChannel   = 16;
        f.mFramesPerPacket  = 1;
        f.mBytesPerFrame    = 2;
        f.mBytesPerPacket   = 2;
        printf("format: %d\n", (int)AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat,
                                                         kAudioUnitScope_Input, 0, &f, sizeof(f)));
        AURenderCallbackStruct cb = { render, NULL };
        printf("callback: %d\n", (int)AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback,
                                                           kAudioUnitScope_Input, 0, &cb, sizeof(cb)));
        printf("init: %d\n", (int)AudioUnitInitialize(unit));
        printf("start: %d\n", (int)AudioOutputUnitStart(unit));
        fflush(stdout);
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 6.0, false);
        AudioOutputUnitStop(unit);
        printf("done\n");
    }
    return 0;
}
