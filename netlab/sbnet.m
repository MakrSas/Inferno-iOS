// Draws a network into the guest's status bar.
//
// The machine has neither a modem nor a Wi-Fi chip, so the guest shows no
// service and no Wi-Fi however well the app itself is connected. iOS has a way
// to say otherwise: SpringBoard's status bar server takes an override structure
// and draws from it instead of from the real state. `simctl status_bar` uses the
// same door on the simulator.
//
//   sbnet [-z] [-t time] [-c carrier] [-g bars] [-w bars] [-n type]
//         [-s content] [-e items] [-d items]
//
// Everything below was found on the rig, against iOS 14.0 on t8030:
//
//   * The server refuses anyone without `com.apple.UIKit.status-bar-override-allow`
//     and says so: "Only entitled processes may set status bar override data".
//     ldid signs this binary with it; AMFI in the guest is patched to allow it.
//   * The two structures are declared by UIKitCore itself — class-dump of
//     `+[UIStatusBarServer getStatusBarData]` and `getStatusBarOverrideData`
//     print them in full. They are copied here field for field, which is what
//     keeps the offsets honest; the field names beyond the ones used are the
//     ones class-dump gives, since it has no names to give.
//   * `itemIsEnabled` decides what is drawn at all. The cellular entry is built
//     from three of its flags — item 4 is the signal strength, item 6 the
//     service, item 9 the data network — plus item 7 for a second SIM, item 3
//     for aeroplane mode and item 29 for the VPN badge.
//   * `serviceContentType` of 1 means "no service", and then the bars are drawn
//     as the four grey dots whatever the strength says. Anything else lets the
//     bars through.
//   * `dataNetworkType`: 0 G, 1 E, 2 3G, 3 4G, 4 LTE, 5 the Wi-Fi glyph (whose
//     strength is `wifiSignalStrengthBars`, 0 to 3), 6 tethering, 7 1x, 8 5G E.
//
// The override lives in SpringBoard and is forgotten when it restarts, so
// whoever cares re-applies it after a respring.
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <stddef.h>
#include <unistd.h>

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

static void setItem(StatusBarOverrides *o, const char *list, bool enabled)
{
    for (const char *p = list; p && *p; p = strchr(p, ',') ? strchr(p, ',') + 1 : NULL) {
        int item = atoi(p);
        if (item >= 0 && item < 43) {
            o->overrideItemIsEnabled[item] = 1;
            o->values.itemIsEnabled[item] = enabled;
        }
    }
}

int main(int argc, char **argv)
{
    if (!dlopen("/System/Library/PrivateFrameworks/UIKitCore.framework/UIKitCore", RTLD_NOW)) {
        fprintf(stderr, "sbnet: %s\n", dlerror());
        return 1;
    }

    Class server = objc_getClass("UIStatusBarServer");
    SEL get = sel_registerName("getStatusBarOverrideData");
    SEL post = sel_registerName("postStatusBarOverrideData:");
    if (server == NULL || !class_getClassMethod(server, get) || !class_getClassMethod(server, post)) {
        fprintf(stderr, "sbnet: this iOS has no status bar overrides\n");
        return 1;
    }

    // Start from what is already overridden, so two runs add up rather than
    // one undoing the other. `-z` is how the whole thing is taken back.
    StatusBarOverrides overrides = {0};
    const StatusBarOverrides *current = ((const StatusBarOverrides *(*)(Class, SEL))objc_msgSend)(server, get);
    if (current != NULL) { memcpy(&overrides, current, sizeof(overrides)); }

    int option;
    while ((option = getopt(argc, argv, "zt:c:g:w:n:s:e:d:")) != -1) {
        switch (option) {
            case 'z': memset(&overrides, 0, sizeof(overrides)); break;
            case 't':
                overrides.time = 1;
                strlcpy(overrides.values.timeString, optarg, sizeof(overrides.values.timeString));
                strlcpy(overrides.values.shortTimeString, optarg, sizeof(overrides.values.shortTimeString));
                break;
            case 'c':
                overrides.service = 1;
                strlcpy(overrides.values.serviceString, optarg, sizeof(overrides.values.serviceString));
                break;
            case 'g': overrides.gsmBars = 1; overrides.values.gsmSignalStrengthBars = atoi(optarg); break;
            case 'w': overrides.wifiBars = 1; overrides.values.wifiSignalStrengthBars = atoi(optarg); break;
            case 'n': overrides.dataNetworkType = 1; overrides.values.dataNetworkType = (unsigned)atoi(optarg); break;
            case 's':
                overrides.serviceContentType = 1;
                overrides.values.serviceContentType = (unsigned)atoi(optarg);
                break;
            case 'e': setItem(&overrides, optarg, true); break;
            case 'd': setItem(&overrides, optarg, false); break;
            default:
                fprintf(stderr, "sbnet [-z] [-t time] [-c carrier] [-g bars] [-w bars] [-n type]"
                                " [-s content] [-e items] [-d items]\n");
                return 2;
        }
    }

    ((void (*)(Class, SEL, const StatusBarOverrides *))objc_msgSend)(server, post, &overrides);
    printf("sbnet: cellular %d bars, wifi %d bars, type %u, service '%s'\n",
           overrides.values.gsmSignalStrengthBars, overrides.values.wifiSignalStrengthBars,
           overrides.values.dataNetworkType, overrides.values.serviceString);
    return 0;
}
