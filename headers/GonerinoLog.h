#import <Foundation/Foundation.h>

static inline BOOL GonerinoDebugLoggingEnabled(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:@"GonerinoDebugLogging"];
}

#define GonerinoLog(fmt, ...)                                                              \
    do {                                                                                   \
        if (GonerinoDebugLoggingEnabled()) {                                               \
            NSLog(@"[Gonerino] " fmt, ##__VA_ARGS__);                                      \
        }                                                                                  \
    } while (0)

#define GonerinoLogError(fmt, ...) NSLog(@"[Gonerino] " fmt, ##__VA_ARGS__)
