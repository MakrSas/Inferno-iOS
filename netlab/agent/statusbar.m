// Draws a network into the guest's status bar, and keeps it drawn.
//
// The machine has neither a modem nor a Wi-Fi chip, so on its own the guest
// shows four grey dots and no Wi-Fi. SpringBoard's status bar server takes an
// override structure and draws from that instead; `simctl status_bar` uses the
// same door. All of this — the structure layout, the entitlement, the item
// numbers — was found on the rig against iOS 14.0 on t8030 and is written up in
// `netlab/sbnet.m`, which this began as.
//
// What is new here is that nobody runs it by hand any more. The app leaves the
// desired look in a request; the agent applies it and, because the override is
// forgotten whenever SpringBoard restarts, reapplies it every few seconds. The
// app no longer has to guess when SpringBoard is up, or ask (`ps` on a busy
// guest was what hung the console in the first place) — the agent just keeps
// painting, and a respring heals itself within seconds.
#import "agent.h"
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <pthread.h>

typedef struct {
    bool itemIsEnabled[43];
    char timeString[64], shortTimeString[64], dateString[256];
    int gsmSignalStrengthRaw, secondaryGsmSignalStrengthRaw;
    int gsmSignalStrengthBars, secondaryGsmSignalStrengthBars;
    char serviceString[100], secondaryServiceString[100];
    char serviceCrossfadeString[100], secondaryServiceCrossfadeString[100];
    char serviceImages[2][100];
    char operatorDirectory[1024];
    unsigned int serviceContentType, secondaryServiceContentType;
    unsigned int cellLowDataMode : 1, secondaryCellLowDataMode : 1;
    int wifiSignalStrengthRaw, wifiSignalStrengthBars;
    unsigned int wifiLowDataMode : 1;
    unsigned int dataNetworkType, secondaryDataNetworkType;
    int batteryCapacity;
    unsigned int batteryState;
    char batteryDetailString[150];
    int bluetoothBatteryCapacity, thermalColor;
    unsigned int x28 : 1, x29 : 1, x30 : 1;
    char activityDisplayId[256];
    unsigned int x32 : 1, x33 : 1, x34 : 1, x35 : 1, x36 : 2, x37 : 1;
    unsigned int x38;
    unsigned int x39 : 1, x40 : 1, x41 : 1;
    char x42[256], x43[256], x44[100];
    unsigned int x45 : 1, x46 : 1, x47 : 1, x48 : 1;
    double x49;
    unsigned int x50 : 1, x51 : 1;
    char x52[100], x53[100];
} StatusBarData;

typedef struct {
    bool overrideItemIsEnabled[43];
    unsigned int time : 1, date : 1, gsmRaw : 1, secondaryGsmRaw : 1, gsmBars : 1, secondaryGsmBars : 1;
    unsigned int service : 1, secondaryService : 1, serviceImages : 2, operatorDirectory : 1;
    unsigned int serviceContentType : 1, secondaryServiceContentType : 1;
    unsigned int wifiRaw : 1, wifiBars : 1, dataNetworkType : 1, secondaryDataNetworkType : 1;
    unsigned int y17 : 1, y18 : 1, y19 : 1, y20 : 1, y21 : 1, y22 : 1, y23 : 1, y24 : 1, y25 : 1, y26 : 1;
    unsigned int y27;
    unsigned int y28 : 1, y29 : 1, y30 : 1, y31 : 1, y32 : 1, y33 : 1, y34 : 1;
    StatusBarData values;
} StatusBarOverrides;

// The desired look, kept between requests so a boot with no request from the app
// yet paints nothing, and a respring after one repaints the last thing asked.
static pthread_mutex_t look_lock = PTHREAD_MUTEX_INITIALIZER;
static StatusBarOverrides desired;
static bool have_desired = false;
static double last_applied = 0;
static int applied_count = 0;
static NSString *last_error = nil;

static Class server_class;
static SEL get_override_sel, post_override_sel;
static bool objc_ready = false;

static bool ensure_objc(void)
{
    if (objc_ready) { return true; }
    static bool tried = false;
    if (tried) { return false; }
    tried = true;

    if (!dlopen("/System/Library/PrivateFrameworks/UIKitCore.framework/UIKitCore", RTLD_NOW)) {
        last_error = @"UIKitCore did not load";
        return false;
    }
    server_class = objc_getClass("UIStatusBarServer");
    get_override_sel = sel_registerName("getStatusBarOverrideData");
    post_override_sel = sel_registerName("postStatusBarOverrideData:");
    if (!server_class || !class_getClassMethod(server_class, get_override_sel)
        || !class_getClassMethod(server_class, post_override_sel)) {
        last_error = @"this iOS has no status bar overrides";
        return false;
    }
    objc_ready = true;
    return true;
}

static void set_items(StatusBarOverrides *o, NSArray *items, bool enabled)
{
    for (id value in items) {
        if (![value isKindOfClass:[NSNumber class]]) { continue; }
        int item = [value intValue];
        if (item >= 0 && item < 43) {
            o->overrideItemIsEnabled[item] = 1;
            o->values.itemIsEnabled[item] = enabled;
        }
    }
}

static void copy_string(char *dst, size_t size, NSString *value)
{
    strlcpy(dst, value.length ? value.UTF8String : "", size);
}

// Builds the override structure from the app's JSON. The shape mirrors
// `GuestStatusBar.Look.arguments`, so the field meanings are the same as the
// old command line: item 4 signal, 6 service, 9 data network; type 5 is Wi-Fi.
static bool build_override(NSDictionary *look, StatusBarOverrides *out, NSString **error)
{
    memset(out, 0, sizeof *out);
    if (![look isKindOfClass:[NSDictionary class]]) {
        *error = @"look is not an object";
        return false;
    }
    if ([look[@"clear"] boolValue]) { return true; }

    // Item 7 is the second SIM's slot. Filling its own half of the bar — the
    // `secondary*` fields for bars, carrier and data network — was tried and
    // does not take: the guest draws the slot as "no service" whatever those
    // say, so only the slot itself is offered.
    NSMutableArray *on = [@[ @4, @6, @9 ] mutableCopy];
    if ([look[@"secondSIM"] boolValue]) { [on addObject:@7]; }
    if ([look[@"vpn"] boolValue]) { [on addObject:@29]; }
    if ([look[@"airplane"] boolValue]) { [on addObject:@3]; }
    set_items(out, on, true);

    // serviceContentType 1 means "no service" and forces the grey dots; 0 lets
    // the bars through.
    out->serviceContentType = 1;
    out->values.serviceContentType = 0;

    out->gsmBars = 1;
    int bars = [look[@"cellularBars"] intValue];
    out->values.gsmSignalStrengthBars = bars < 0 ? 0 : bars > 4 ? 4 : bars;

    NSString *carrier = [look[@"carrier"] isKindOfClass:[NSString class]] ? look[@"carrier"] : @"";
    out->service = 1;
    copy_string(out->values.serviceString, sizeof out->values.serviceString, carrier);

    if ([look[@"wifi"] boolValue]) {
        out->dataNetworkType = 1;
        out->values.dataNetworkType = 5;  // the Wi-Fi glyph
        out->wifiBars = 1;
        int wifi = [look[@"wifiBars"] intValue];
        out->values.wifiSignalStrengthBars = wifi < 0 ? 0 : wifi > 3 ? 3 : wifi;
    } else {
        out->dataNetworkType = 1;
        int type = [look[@"network"] intValue];
        out->values.dataNetworkType = (unsigned)(type < 0 ? 0 : type);
    }
    return true;
}

// Merges onto whatever is already overridden and posts it. Off the main thread
// this still works: the server call is a plain message send.
static bool apply_locked(NSString **error)
{
    if (!ensure_objc()) {
        *error = last_error;
        return false;
    }
    StatusBarOverrides overrides;
    memcpy(&overrides, &desired, sizeof overrides);
    ((void (*)(Class, SEL, const StatusBarOverrides *))objc_msgSend)(server_class, post_override_sel, &overrides);
    return true;
}

NSDictionary *statusbar_request(NSDictionary *request)
{
    NSDictionary *look = request[@"look"];
    StatusBarOverrides built;
    NSString *error = nil;
    if (!build_override(look, &built, &error)) { return @{@"ok" : @NO, @"error" : error ?: @"bad look"}; }

    pthread_mutex_lock(&look_lock);
    memcpy(&desired, &built, sizeof desired);
    have_desired = true;
    bool ok = apply_locked(&error);
    if (ok) {
        last_applied = now_seconds();
        applied_count++;
        last_error = nil;
    } else {
        last_error = error;
    }
    pthread_mutex_unlock(&look_lock);

    agent_log("status bar: %s", ok ? "applied" : [@"failed — " stringByAppendingString:error ?: @"?"].UTF8String);
    return ok ? @{@"ok" : @YES} : @{@"ok" : @NO, @"error" : error ?: @"could not apply"};
}

// The keeper. Runs on its own thread and reasserts the override on a slow beat,
// so a SpringBoard that came up late or restarted gets it back without anyone
// having to notice. Failures here are quiet: SpringBoard is simply not ready
// yet, and the next tick will try again.
static void *keeper(void *unused)
{
    (void)unused;
    for (;;) {
        usleep(3 * 1000 * 1000);
        pthread_mutex_lock(&look_lock);
        if (have_desired) {
            NSString *error = nil;
            if (apply_locked(&error)) {
                last_applied = now_seconds();
                applied_count++;
            }
        }
        pthread_mutex_unlock(&look_lock);
    }
    return NULL;
}

void statusbar_start(void)
{
    pthread_t thread;
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    pthread_create(&thread, &attr, keeper, NULL);
    pthread_attr_destroy(&attr);
}

NSDictionary *statusbar_summary(void)
{
    pthread_mutex_lock(&look_lock);
    NSDictionary *summary = @{
        @"set" : @(have_desired),
        @"applied" : @(applied_count),
        @"ago" : @(last_applied ? now_seconds() - last_applied : -1),
        @"error" : last_error ?: @"",
    };
    pthread_mutex_unlock(&look_lock);
    return summary;
}
