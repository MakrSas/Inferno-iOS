// Plays a system sound, which iOS routes itself rather than through the caller's
// audio session. If this reaches the emulated speaker while an audio queue does
// not, the fault is in the session, not in the hardware path.
#import <AudioToolbox/AudioToolbox.h>
#import <Foundation/Foundation.h>
#include <stdio.h>

int main(int argc, char** argv)
{
    const char* path = argc > 1 ? argv[1] : "/System/Library/Audio/UISounds/Tink.caf";

    @autoreleasepool {
        NSURL*        url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:path]];
        SystemSoundID sound = 0;
        OSStatus      st;

        printf("file exists: %d\n", (int)[[NSFileManager defaultManager] fileExistsAtPath:url.path]);
        fflush(stdout);

        st = AudioServicesCreateSystemSoundID((__bridge CFURLRef)url, &sound);
        printf("create: %d id %u\n", (int)st, (unsigned)sound);
        fflush(stdout);
        if (st != noErr) { return 1; }

        for (int i = 0; i < 3; i++) {
            AudioServicesPlaySystemSound(sound);
            printf("played %d\n", i);
            fflush(stdout);
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, 2.0, false);
        }
        printf("done\n");
    }
    return 0;
}
