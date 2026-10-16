#import "WXRLog.h"
#import "WXRCommon.h"
#import "WXRPrefs.h"
#import <os/log.h>
#import <pthread.h>
#import <stdarg.h>

#define WXR_LOG_MAX 1000

static NSMutableArray<NSString *> *gLines = nil;
static NSDateFormatter *gFormatter = nil;
static os_log_t gOSLog = NULL;
static pthread_mutex_t gLock = PTHREAD_MUTEX_INITIALIZER;
static BOOL gFileSinkFailed = NO;

static void WXRLogInit(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gLines = [NSMutableArray arrayWithCapacity:WXR_LOG_MAX];
        gOSLog = os_log_create("com.wxreply.tweak", "log");
        gFormatter = [[NSDateFormatter alloc] init];
        gFormatter.dateFormat = @"HH:mm:ss.SSS";
        gFormatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    });
}

static NSString *WXRLogFilePathUnlocked(void) {
    return [[WXRPrefs configDirectory] stringByAppendingPathComponent:WXR_LOG_FILE];
}

static void WXRLogAppendToFile(NSString *line) {
    if (gFileSinkFailed) {
        return;
    }
    NSString *path = WXRLogFilePathUnlocked();
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:path]) {
        [fm createFileAtPath:path contents:nil attributes:nil];
    }
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!fh) {
        gFileSinkFailed = YES;
        return;
    }
    // 注意：writeData: 要的是 NSData，不是 NSString（这里错过一次，编译器给了 warning）
    NSData *payload = [[(line ?: @"") stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
    if (!payload) {
        gFileSinkFailed = YES;
        return;
    }
    @try {
        [fh seekToEndOfFile];
        [fh writeData:payload];
        [fh closeFile];
    } @catch (NSException *e) {
        gFileSinkFailed = YES;
    }
}

static void WXRLogWrite(BOOL verbose, NSString *fmt, va_list ap) {
    WXRLogInit();
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    if (verbose && ![WXRPrefs shared].boolVerbose) {
        return;
    }
    NSString *proc = [[NSProcessInfo processInfo] processName] ?: @"?";
    NSString *line = nil;
    pthread_mutex_lock(&gLock);
    line = [NSString stringWithFormat:@"[%@] %@", [gFormatter stringFromDate:[NSDate date]], msg];
    [gLines addObject:line];
    while (gLines.count > WXR_LOG_MAX) {
        [gLines removeObjectAtIndex:0];
    }
    NSString *full = [NSString stringWithFormat:@"%@ %@", proc, line];
    WXRLogAppendToFile(full);
    pthread_mutex_unlock(&gLock);

    if (gOSLog) {
        os_log_info(gOSLog, "%{public}s", full.UTF8String);
    }
}

void WXRLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    WXRLogWrite(NO, fmt, ap);
    va_end(ap);
}

void WXRLogVerbose(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    WXRLogWrite(YES, fmt, ap);
    va_end(ap);
}

NSArray<NSString *> *WXRLogSnapshot(void) {
    WXRLogInit();
    pthread_mutex_lock(&gLock);
    NSArray<NSString *> *copy = [gLines copy];
    pthread_mutex_unlock(&gLock);
    return copy;
}

void WXRLogClear(void) {
    WXRLogInit();
    pthread_mutex_lock(&gLock);
    [gLines removeAllObjects];
    pthread_mutex_unlock(&gLock);
}

NSString *WXRLogFilePath(void) {
    WXRLogInit();
    return WXRLogFilePathUnlocked();
}

BOOL WXRLogFlushToFile(void) {
    NSArray<NSString *> *lines = WXRLogSnapshot();
    NSString *body = [[lines componentsJoinedByString:@"\n"] stringByAppendingString:@"\n"];
    BOOL ok = [body writeToFile:WXRLogFilePath() atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    pthread_mutex_lock(&gLock);
    gFileSinkFailed = NO;
    pthread_mutex_unlock(&gLock);
    return ok;
}
