#import "SLLog.h"
#import <fcntl.h>
#import <unistd.h>
#import <errno.h>
#import <sys/stat.h>
#import <os/lock.h>

#define SLV_LOG_MAX_BYTES  (1024 * 1024)
#define SLV_LOG_KEEP_BYTES (512 * 1024)

// 0.3.47：日志层从 NSFileHandle 换成 POSIX open/write。
//
// 换的原因：0.3.46 的「可写校验」是假的 —— 只验证了 fileHandleForWritingAtPath:
// 能不能打开，没真写。某些 App 的沙盒里，文件是别的进程（root）建的，open 能过、
// write 却被 EACCES 拦下，NSFileHandle 抛的异常又被 @catch 吞了，结果就是
// 「路径显示得出来、文件 0 字节」。陌陌那边文件属主正常，所以一直正常。
//
// 现在：探针真的写一个字节再截回去；运行时写失败会记 errno 并自动换下一条候选。

static os_unfair_lock gSLLogLock = OS_UNFAIR_LOCK_INIT;
static NSString *gSLLogPath = nil;
static int gSLLogPathIndex = -1;
static int gSLLogWriteFail = 0;
static int gSLLogLastErrno = 0;

/// 候选路径按「跨 App 共享 → App 沙盒 → 临时目录」排。
/// 共享那条是全设备一份，所有 App 的日志都落在一起，排查时不用逐个容器翻。
static NSArray<NSString *> *SLVLogCandidates(void) {
    NSMutableArray<NSString *> *a = [NSMutableArray arrayWithObjects:
        @"/var/mobile/Documents/ShenglinVcam/slvcam.log",
        @"/var/jb/var/mobile/Documents/ShenglinVcam/slvcam.log", nil];

    // 沙盒 Documents：绝大多数越狱设备上这里才是真正可写的位置
    NSString *doc = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    if (doc.length) [a addObject:[doc stringByAppendingPathComponent:@"ShenglinVcam/slvcam.log"]];

    // 临时目录：任何 App 都写得进去，宿主就算把 Documents 锁了也还有这一层
    NSString *tmp = NSTemporaryDirectory();
    if (tmp.length) [a addObject:[tmp stringByAppendingPathComponent:@"ShenglinVcam/slvcam.log"]];

    [a addObject:@"/tmp/shenglin-vcam.log"];
    return a;
}

/// 真写一个字节，确认「不是只能打开」。
/// 通过就把文件截回原长度，不在日志里留垃圾字符。
static BOOL SLVProbePath(NSString *path, int *errOut) {
    if (!path.length) return NO;
    NSString *dir = [path stringByDeletingLastPathComponent];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:dir]) {
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    }

    const char *p = path.fileSystemRepresentation;
    if (!p) return NO;

    int fd = open(p, O_WRONLY | O_APPEND | O_CREAT, 0644);
    if (fd < 0 && (errno == EACCES || errno == EPERM)) {
        // 可能是别的进程（root）留下的、属主不对的旧文件。
        // 这是插件自己的日志，删掉重建没有副作用。
        if ([fm removeItemAtPath:path error:nil]) {
            fd = open(p, O_WRONLY | O_APPEND | O_CREAT, 0644);
        }
    }
    if (fd < 0) {
        if (errOut) *errOut = errno;
        return NO;
    }

    off_t end = lseek(fd, 0, SEEK_END);
    if (end < 0) end = 0;

    errno = 0;
    ssize_t w = write(fd, "\n", 1);
    int e = errno;
    BOOL ok = (w == 1);
    if (ok && ftruncate(fd, end) != 0) {
        // 截不回去只会在末尾多一个空行，不影响可用性
    }
    close(fd);

    if (!ok && errOut) *errOut = e;
    return ok;
}

/// 调用方必须持有 gSLLogLock。
/// 从 fromIndex 开始环形找第一条「真能写」的路径。
static NSString *SLVLogSelectLocked(int fromIndex) {
    NSArray<NSString *> *cands = SLVLogCandidates();
    NSUInteger n = cands.count;
    if (!n) return nil;

    for (NSUInteger i = 0; i < n; i++) {
        NSUInteger idx = ((NSUInteger)MAX(fromIndex, 0) + i) % n;
        int e = 0;
        if (SLVProbePath(cands[idx], &e)) {
            gSLLogPathIndex = (int)idx;
            gSLLogPath = cands[idx];
            return gSLLogPath;
        }
        gSLLogLastErrno = e;
    }
    // 一条都写不进去：仍然挂最后一条，写入会失败但至少路径可显示
    gSLLogPathIndex = (int)n - 1;
    gSLLogPath = cands.lastObject;
    return gSLLogPath;
}

NSString *SLVLogCurrentPath(void) {
    os_unfair_lock_lock(&gSLLogLock);
    if (!gSLLogPath) SLVLogSelectLocked(0);
    NSString *p = gSLLogPath;
    os_unfair_lock_unlock(&gSLLogLock);
    return p;
}

/// 当前路径写不进去了 → 换下一条
static void SLVLogRotate(void) {
    os_unfair_lock_lock(&gSLLogLock);
    SLVLogSelectLocked(gSLLogPathIndex + 1);
    os_unfair_lock_unlock(&gSLLogLock);
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

static void SLVTruncateIfNeeded(NSString *path) {
    struct stat st;
    if (!path.length) return;
    if (stat(path.fileSystemRepresentation, &st) != 0) return;
    if (st.st_size <= SLV_LOG_MAX_BYTES) return;

    NSData *d = [NSData dataWithContentsOfFile:path];
    if (d.length <= SLV_LOG_MAX_BYTES) return;
    NSData *tail = [d subdataWithRange:NSMakeRange(d.length - SLV_LOG_KEEP_BYTES, SLV_LOG_KEEP_BYTES)];
    [tail writeToFile:path atomically:YES];
}

/// 追加一行。返回 NO 表示这一行最终没落盘。
static BOOL SLVAppendLine(NSString *line) {
    if (!line.length) return NO;
    NSData *d = [line dataUsingEncoding:NSUTF8StringEncoding];
    if (!d.length) return NO;

    for (int attempt = 0; attempt < 4; attempt++) {
        NSString *path = SLVLogCurrentPath();
        if (!path.length) return NO;
        const char *p = path.fileSystemRepresentation;
        if (!p) return NO;

        int fd = open(p, O_WRONLY | O_APPEND | O_CREAT, 0644);
        if (fd < 0) {
            gSLLogWriteFail++;
            gSLLogLastErrno = errno;
            SLVLogRotate();
            continue;
        }

        BOOL ok = YES;
        const uint8_t *bytes = d.bytes;
        size_t total = d.length, off = 0;
        while (off < total) {
            ssize_t n = write(fd, bytes + off, total - off);
            if (n > 0) { off += (size_t)n; continue; }
            if (n < 0 && errno == EINTR) continue;
            ok = NO;
            gSLLogLastErrno = errno;
            break;
        }
        close(fd);

        if (ok) {
            SLVTruncateIfNeeded(path);
            return YES;
        }
        gSLLogWriteFail++;
        SLVLogRotate();
    }
    return NO;
}

void SLVLogWrite(NSString *line) {
    if (!line.length) return;
    static dispatch_queue_t q = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ q = dispatch_queue_create("com.shenglin.vcam.log", DISPATCH_QUEUE_SERIAL); });

    NSString *full = [NSString stringWithFormat:@"%@ %@\n", SLVTimestamp(), line];
    dispatch_async(q, ^{
        if (!SLVAppendLine(full)) {
            // 四条候选全军覆没：至少留在系统日志里，Console 还能捞到
            NSLog(@"SL-VCAM(log fail %d): %@", gSLLogLastErrno, full);
        }
    });
}

NSString *SLVLogDiagnostics(void) {
    NSString *path = SLVLogCurrentPath();
    struct stat st;
    unsigned long long size = 0;
    if (path.length && stat(path.fileSystemRepresentation, &st) == 0) size = (unsigned long long)st.st_size;

    NSString *sizeText = size >= 1024 * 1024
        ? [NSString stringWithFormat:@"%.1f MB", size / 1048576.0]
        : (size >= 1024 ? [NSString stringWithFormat:@"%.1f KB", size / 1024.0]
                        : [NSString stringWithFormat:@"%llu B", size]);

    if (gSLLogWriteFail > 0) {
        return [NSString stringWithFormat:@"写失败 %d 次 · errno %d · %@",
                gSLLogWriteFail, gSLLogLastErrno, sizeText];
    }
    return [NSString stringWithFormat:@"写入正常 · %@", sizeText];
}

@implementation SLVLog

+ (NSString *)filePath {
    return SLVLogCurrentPath();
}

+ (NSString *)diagnostics {
    return SLVLogDiagnostics();
}

+ (NSString *)tailLines:(NSInteger)lines {
    NSData *d = [NSData dataWithContentsOfFile:SLVLogCurrentPath()];
    NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] ?: @"";
    NSArray<NSString *> *all = [s componentsSeparatedByString:@"\n"];
    NSInteger n = all.count;
    NSInteger start = n > lines ? n - lines : 0;
    NSArray<NSString *> *part = [all subarrayWithRange:NSMakeRange(start, n - start)];
    return [part componentsJoinedByString:@"\n"];
}

+ (void)clear {
    NSString *path = SLVLogCurrentPath();
    if (!path.length) return;
    // 直接截断，不重建文件：重建会换 inode 和属主，反而更容易写不进去
    int fd = open(path.fileSystemRepresentation, O_WRONLY | O_TRUNC);
    if (fd >= 0) close(fd);
}

@end
