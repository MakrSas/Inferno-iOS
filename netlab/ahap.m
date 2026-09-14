// Plays the vibration the Sounds pane previews. That preview is what still takes the audio server
// down: it starts the aggregate built around the actuator, whose IO thread has nowhere to send its
// samples. Reproducing it here beats asking someone to tap through Settings.
#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#include <stdio.h>
#include <unistd.h>

int main(int argc, char** argv)
{
    @autoreleasepool {
        SystemSoundID sound = argc > 1 ? (SystemSoundID)atoi(argv[1]) : 4095;    // kSystemSoundID_Vibrate

        printf("playing system sound %u\n", (unsigned)sound);
        fflush(stdout);

        AudioServicesPlaySystemSound(sound);

        for (int i = 0; i < 5; i++) {
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1.0]];
            printf("t=%ds\n", i + 1);
            fflush(stdout);
        }
        printf("done\n");
    }
    return 0;
}
