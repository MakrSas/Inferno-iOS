// Plays haptics with known parameters through Core Haptics, so the actuator stream that reaches the
// emulator can be read against what was asked for.
//
//   chap steps       continuous events: sharpness 0, 0.5, 1 against intensity 0.25, 0.5, 1
//   chap transients  the same grid, as transients
//   chap sweep       sharpness 0..1 at full intensity; intensity 0.02..1 at sharpness 0.5 and at 1;
//                    one event whose intensity is ramped up and down by a parameter curve; transients
//
// The schedule is printed before playing. The emulator's log has its own clock, so it is the order
// and the spacing of the events that line the two up, not the absolute times.
#import <CoreHaptics/CoreHaptics.h>
#import <Foundation/Foundation.h>
#include <stdio.h>
#include <string.h>

static NSArray<CHHapticEventParameter*>* parameters(float intensity, float sharpness)
{
    return @[
        [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticIntensity value:intensity],
        [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticSharpness value:sharpness],
    ];
}

static void continuous(NSMutableArray<CHHapticEvent*>* events, double at, double duration, float intensity,
                       float sharpness)
{
    [events addObject:[[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticContinuous
                                                    parameters:parameters(intensity, sharpness)
                                                  relativeTime:at
                                                      duration:duration]];
    printf("%6.2f s  continuous %.2f s  intensity %.2f  sharpness %.2f\n", at, duration, intensity, sharpness);
}

static void transient(NSMutableArray<CHHapticEvent*>* events, double at, float intensity, float sharpness)
{
    [events addObject:[[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticTransient
                                                    parameters:parameters(intensity, sharpness)
                                                  relativeTime:at]];
    printf("%6.2f s  transient  intensity %.2f  sharpness %.2f\n", at, intensity, sharpness);
}

int main(int argc, char** argv)
{
    @autoreleasepool {
        const char*   mode    = argc > 1 ? argv[1] : "steps";
        const float   sharp[] = { 0, 0.5f, 1 };
        const float   level[] = { 0.25f, 0.5f, 1 };
        NSError*      err     = nil;
        double        at      = 0;
        NSMutableArray<CHHapticEvent*>*          events = [NSMutableArray array];
        NSMutableArray<CHHapticParameterCurve*>* curves = [NSMutableArray array];

        id<CHHapticDeviceCapability> caps = [CHHapticEngine capabilitiesForHardware];
        printf("supportsHaptics=%d supportsAudio=%d\n", caps.supportsHaptics, caps.supportsAudio);

        CHHapticEngine* engine = [[CHHapticEngine alloc] initAndReturnError:&err];
        if (engine == nil) {
            printf("engine: %s\n", err.description.UTF8String);
            return 1;
        }
        engine.stoppedHandler = ^(CHHapticEngineStoppedReason reason) {
            printf("engine stopped, reason %ld\n", (long)reason);
            fflush(stdout);
        };
        engine.resetHandler = ^{
            printf("engine reset\n");
            fflush(stdout);
        };
        if (![engine startAndReturnError:&err]) {
            printf("start: %s\n", err.description.UTF8String);
            return 2;
        }

        if (strcmp(mode, "sweep") == 0) {
            for (int i = 0; i <= 10; i++) {
                continuous(events, at, 0.3, 1, i / 10.0f);
                at += 0.6;
            }
            const float half[] = { 0.02f, 0.05f, 0.1f, 0.2f, 0.3f, 0.5f, 0.7f, 0.85f, 1 };
            for (size_t i = 0; i < sizeof(half) / sizeof(half[0]); i++) {
                continuous(events, at, 0.3, half[i], 0.5f);
                at += 0.6;
            }
            const float full[] = { 0.1f, 0.3f, 0.6f, 1 };
            for (size_t i = 0; i < sizeof(full) / sizeof(full[0]); i++) {
                continuous(events, at, 0.3, full[i], 1);
                at += 0.6;
            }
            // The event plays at intensity 1; the curve scales it from 0.1 up to 1 and back over three
            // seconds.
            continuous(events, at, 3.0, 1, 0.5f);
            [curves addObject:[[CHHapticParameterCurve alloc]
                                  initWithParameterID:CHHapticDynamicParameterIDHapticIntensityControl
                                        controlPoints:@[
                                            [[CHHapticParameterCurveControlPoint alloc] initWithRelativeTime:0
                                                                                                        value:0.1f],
                                            [[CHHapticParameterCurveControlPoint alloc] initWithRelativeTime:1.5
                                                                                                        value:1],
                                            [[CHHapticParameterCurveControlPoint alloc] initWithRelativeTime:3.0
                                                                                                        value:0.1f],
                                        ]
                                         relativeTime:at]];
            printf("%6.2f s  intensity curve 0.1 -> 1 -> 0.1 over 3 s on the event above\n", at);
            at += 3.6;
            const float taps[] = { 0.2f, 0.5f, 1 };
            for (size_t i = 0; i < sizeof(taps) / sizeof(taps[0]); i++) {
                transient(events, at, taps[i], 0.5f);
                at += 0.4;
            }
        }
        else if (strcmp(mode, "taps") == 0) {
            const float tapLevel[] = { 0.1f, 0.3f, 0.6f, 1 };
            const float tapSharp[] = { 0, 0.5f, 1 };
            for (size_t s = 0; s < 3; s++) {
                for (size_t l = 0; l < 4; l++) {
                    transient(events, at, tapLevel[l], tapSharp[s]);
                    at += 0.4;
                }
            }
            const double brief[] = { 0.02, 0.05, 0.1 };
            for (size_t i = 0; i < 3; i++) {
                continuous(events, at, brief[i], 1, 0.5f);
                at += 0.4;
            }
            continuous(events, at, 0.3, 0.3f, 0.5f);
            at += 0.6;
            continuous(events, at, 0.3, 1, 0.5f);
            at += 0.6;
        }
        else {
            const bool steps = strcmp(mode, "transients") != 0;

            for (int s = 0; s < 3; s++) {
                for (int l = 0; l < 3; l++) {
                    if (steps) {
                        continuous(events, at, 0.4, level[l], sharp[s]);
                        at += 0.7;
                    }
                    else {
                        transient(events, at, level[l], sharp[s]);
                        at += 0.4;
                    }
                }
            }
        }

        CHHapticPattern* pattern = [[CHHapticPattern alloc] initWithEvents:events parameterCurves:curves error:&err];
        if (pattern == nil) {
            printf("pattern: %s\n", err.description.UTF8String);
            return 3;
        }
        id<CHHapticPatternPlayer> player = [engine createPlayerWithPattern:pattern error:&err];
        if (player == nil) {
            printf("player: %s\n", err.description.UTF8String);
            return 4;
        }
        if (![player startAtTime:CHHapticTimeImmediate error:&err]) {
            printf("play: %s\n", err.description.UTF8String);
            return 5;
        }
        printf("playing, %.1f s\n", at);
        fflush(stdout);

        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:at + 1.5]];
        [engine stopWithCompletionHandler:nil];
        printf("done\n");
    }
    return 0;
}
