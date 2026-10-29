#import "SLLog.h"

#define SL_LOG_MAX_BYTES  (1024 * 1024)
#define SL_LOG_KEEP_BYTES (512 * 1024)

static NSString *SLLogPath(void) {
    static NSString *p = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        NSArray<NSString *> *cands = @[
            @"/var/mobile/Documents/ShenglinVcam/slvcam.log",
            @"/var/jb/var/mobile/Documents/ShenglinVcam/slvcam.log"
        ];
        for (NSString *c in cands) {
            NSString *dir = [c stringByDeletingLastPathComponent];
            if (![fm fileExistsAtPath:dir]) {
                [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
            }
            if (![fm fileExistsAtPath:c]) [fm createFileAtPath:c contents:nil attributes:nil];
            if ([fm isWritableFileAtPath:c]) { p = c; break; }
        }
        if (!p) {
            NSString *doc = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
            NSString *dir = [doc stringByAppendingPathComponent:@"ShenglinVcam"];
            if (![fm fileExistsAtPath:dir]) {
                [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
            }
            p = [dir stringByAppendingPathComponent:@"slvcam.log"];
            if (![fm fileExistsAtPath:p]) [fm createFileAtPath:p contents:nil attributes:nil];
        }
    });
    return p;
}

static NSString *SLTimestamp(void) {
    static NSDateFormatter *fmt = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fmt = [[NSDateFormatter alloc] init];
        fmt.dateFormat = @"MM-dd HH:mm:ss";
        fmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    });
    return [fmt stringFromDate:[NSDate date]];
}

void SLLogWrite(NSString *line) {
    if (!line.length) return;
    static dispatch_queue_t q = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ q = dispatch_queue_create("com.shenglin.momo.log", DISPATCH_QUEUE_SERIAL); });

    NSString *full = [NSString stringWithFormat:@"%@ %@\n", SLTimestamp(), line];
    dispatch_async(q, ^{
        NSString *path = SLLogPath();
        if (!path.length) return;
        @try {
            NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
            if (fh) {
                [fh seekToEndOfFile];
                [fh writeData:[full dataUsingEncoding:NSUTF8StringEncoding]];
                unsigned long long end = [fh offsetInFile];
                [fh closeFile];
                if (end > SL_LOG_MAX_BYTES) {
                    NSData *d = [NSData dataWithContentsOfFile:path];
                    if (d.length > SL_LOG_MAX_BYTES) {
                        NSData *tail = [d subdataWithRange:NSMakeRange(d.length - SL_LOG_KEEP_BYTES, SL_LOG_KEEP_BYTES)];
                        [tail writeToFile:path atomically:YES];
                    }
                }
            } else {
                NSData *d = [NSData dataWithContentsOfFile:path];
                NSMutableData *md = d ? [d mutableCopy] : [NSMutableData data];
                [md appendData:[full dataUsingEncoding:NSUTF8StringEncoding]];
                [md writeToFile:path atomically:YES];
            }
        } @catch (NSException *e) { }
    });
}

@implementation SLLog

+ (NSString *)filePath {
    return SLLogPath();
}

+ (NSString *)tailLines:(NSInteger)lines {
    NSData *d = [NSData dataWithContentsOfFile:SLLogPath()];
    NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] ?: @"";
    NSArray<NSString *> *all = [s componentsSeparatedByString:@"\n"];
    NSInteger n = all.count;
    NSInteger start = n > lines ? n - lines : 0;
    NSArray<NSString *> *part = [all subarrayWithRange:NSMakeRange(start, n - start)];
    return [part componentsJoinedByString:@"\n"];
}

+ (void)clear {
    [@"" writeToFile:SLLogPath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

@end
