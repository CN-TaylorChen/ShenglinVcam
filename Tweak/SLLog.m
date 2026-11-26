#import "SLLog.h"

#define SLV_LOG_MAX_BYTES  (1024 * 1024)
#define SLV_LOG_KEEP_BYTES (512 * 1024)

/// 目录不存在就建、文件不存在就建，最后**确认真的能写**再返回 YES。
///
/// 0.3.45 及以前，沙盒那条路径是「建完直接用」，没有回验 —— 建得出来不代表写得进去
/// （数据保护、宿主自定义容器权限都会让写入静默失败），表现就是「日志文件是空的」。
static BOOL SLVEnsureWritableFile(NSString *path, NSFileManager *fm) {
    if (!path.length) return NO;
    NSString *dir = [path stringByDeletingLastPathComponent];
    if (![fm fileExistsAtPath:dir]) {
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    }
    if (![fm fileExistsAtPath:path]) [fm createFileAtPath:path contents:nil attributes:nil];
    if (![fm isWritableFileAtPath:path]) return NO;

    // 能不能真的打开写句柄 —— 属性写着可写、实际被数据保护拦下的情况就挡在这里
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!fh) return NO;
    [fh seekToEndOfFile];
    [fh closeFile];
    return YES;
}

static NSString *SLVLogPath(void) {
    static NSString *p = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSFileManager *fm = [NSFileManager defaultManager];

        NSMutableArray<NSString *> *cands = [NSMutableArray arrayWithObjects:
            @"/var/mobile/Documents/ShenglinVcam/slvcam.log",
            @"/var/jb/var/mobile/Documents/ShenglinVcam/slvcam.log", nil];

        // 沙盒 Documents：绝大多数越狱设备上这里才是真正可写的位置
        NSString *doc = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
        if (doc.length) [cands addObject:[doc stringByAppendingPathComponent:@"ShenglinVcam/slvcam.log"]];

        // 临时目录：任何 App 都写得进去，宿主就算把 Documents 锁了也还有这一层
        NSString *tmp = NSTemporaryDirectory();
        if (tmp.length) [cands addObject:[tmp stringByAppendingPathComponent:@"ShenglinVcam/slvcam.log"]];

        for (NSString *c in cands) {
            if (SLVEnsureWritableFile(c, fm)) { p = c; break; }
        }
        if (!p) p = @"/tmp/shenglin_vcam.log";
    });
    return p;
}

NSString *SLVLogCurrentPath(void) {
    return SLVLogPath();
}

static NSString *SLVTimestamp(void) {
    static NSDateFormatter *fmt = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fmt = [[NSDateFormatter alloc] init];
        fmt.dateFormat = @"MM-dd HH:mm:ss";
        fmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    });
    return [fmt stringFromDate:[NSDate date]];
}

void SLVLogWrite(NSString *line) {
    if (!line.length) return;
    static dispatch_queue_t q = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ q = dispatch_queue_create("com.shenglin.momo.log", DISPATCH_QUEUE_SERIAL); });

    NSString *full = [NSString stringWithFormat:@"%@ %@\n", SLVTimestamp(), line];
    dispatch_async(q, ^{
        NSString *path = SLVLogPath();
        if (!path.length) return;
        @try {
            NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
            if (fh) {
                [fh seekToEndOfFile];
                [fh writeData:[full dataUsingEncoding:NSUTF8StringEncoding]];
                unsigned long long end = [fh offsetInFile];
                [fh closeFile];
                if (end > SLV_LOG_MAX_BYTES) {
                    NSData *d = [NSData dataWithContentsOfFile:path];
                    if (d.length > SLV_LOG_MAX_BYTES) {
                        NSData *tail = [d subdataWithRange:NSMakeRange(d.length - SLV_LOG_KEEP_BYTES, SLV_LOG_KEEP_BYTES)];
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

@implementation SLVLog

+ (NSString *)filePath {
    return SLVLogPath();
}

+ (NSString *)tailLines:(NSInteger)lines {
    NSData *d = [NSData dataWithContentsOfFile:SLVLogPath()];
    NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] ?: @"";
    NSArray<NSString *> *all = [s componentsSeparatedByString:@"\n"];
    NSInteger n = all.count;
    NSInteger start = n > lines ? n - lines : 0;
    NSArray<NSString *> *part = [all subarrayWithRange:NSMakeRange(start, n - start)];
    return [part componentsJoinedByString:@"\n"];
}

+ (void)clear {
    [@"" writeToFile:SLVLogPath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

@end
