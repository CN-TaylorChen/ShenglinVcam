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

// 0.3.48：切点必须落在「行首」，而且必须是合法 UTF-8 的起点。
//
// 老实现直接从 end-512KB 硬切，碰上中文（3 字节）就会把一个字切成两半，
// 于是整个文件的第一行就是非法 UTF-8 —— 之后不管写进去多少行，
// 整份文件都解不出来：initWithData:NSUTF8StringEncoding 返回 nil，
// 日志页一个字都显示不了，但诊断行照样报「写入正常 · 940.8 KB」。
// 陌陌那边日志没长到 1MB、从没触发过截断，所以一直正常。
static void SLVTruncateIfNeeded(NSString *path) {
    struct stat st;
    if (!path.length) return;
    const char *p = path.fileSystemRepresentation;
    if (!p || stat(p, &st) != 0) return;
    if (st.st_size <= SLV_LOG_MAX_BYTES) return;

    off_t from = st.st_size - SLV_LOG_KEEP_BYTES;
    if (from < 0) from = 0;

    int fd = open(p, O_RDONLY);
    if (fd < 0) return;

    // 从 from 往后找第一个换行 —— 行首对齐，半截 UTF-8 自然被甩掉。
    // 最多往后找 64KB；找不到就不截这一轮（宁可文件大一点，也别把可读性搞坏）。
    off_t cut = -1;
    char buf[4096];
    off_t probe = from;
    while (probe < st.st_size && (probe - from) <= 64 * 1024) {
        ssize_t g = pread(fd, buf, sizeof(buf), probe);
        if (g <= 0) break;
        for (ssize_t i = 0; i < g; i++) {
            if (buf[i] == '\n') { cut = probe + i + 1; break; }
        }
        if (cut >= 0) break;
        probe += g;
    }
    if (cut < 0 || cut >= st.st_size) { close(fd); return; }

    size_t keep = (size_t)(st.st_size - cut);
    NSMutableData *tail = [NSMutableData dataWithLength:keep];
    ssize_t r = pread(fd, tail.mutableBytes, keep, cut);
    close(fd);
    if (r <= 0) return;
    tail.length = (NSUInteger)r;

    // 还是走 POSIX 截断写，不用 writeToFile:atomically: —— 后者是「临时文件 + rename」，
    // 会换掉 inode，正在往里 append 的线程会继续写进已删除的旧 inode，那几行就凭空消失了。
    int wfd = open(p, O_WRONLY | O_TRUNC);
    if (wfd < 0) return;
    const uint8_t *bytes = tail.bytes;
    size_t total = tail.length, off = 0;
    while (off < total) {
        ssize_t n = write(wfd, bytes + off, total - off);
        if (n > 0) { off += (size_t)n; continue; }
        if (n < 0 && errno == EINTR) continue;
        break;
    }
    close(wfd);
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

static BOOL SLVIsUTF8Cont(uint8_t c) { return (c & 0xC0) == 0x80; }

/// 宽松解码：UTF-8 解不出来时把非法字节换成 '?'，而不是整段返回 nil。
///
/// 老代码是 `initWithData:encoding:NSUTF8StringEncoding ?: @""` —— 只要文件里有
/// 一个坏字节，整份日志就变成空字符串，页面上就是一片白，且没有任何提示。
/// 日志这种「出问题时才看的文件」绝对不能出现「有问题时反而看不到」。
static NSString *SLVDecodeUTF8(NSData *d) {
    if (!d.length) return @"";
    NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
    if (s) return s;

    const uint8_t *b = d.bytes;
    NSUInteger n = d.length, i = 0;
    NSMutableData *out = [NSMutableData dataWithCapacity:n];
    while (i < n) {
        uint8_t c = b[i];
        NSUInteger need = 0;
        if (c < 0x80) need = 0;
        else if ((c & 0xE0) == 0xC0) need = 1;
        else if ((c & 0xF0) == 0xE0) need = 2;
        else if ((c & 0xF8) == 0xF0) need = 3;
        else { [out appendBytes:"?" length:1]; i++; continue; }

        BOOL ok = (need == 0) || (i + need < n);
        if (ok && need > 0) {
            for (NSUInteger k = 1; k <= need; k++) {
                if (!SLVIsUTF8Cont(b[i + k])) { ok = NO; break; }
            }
        }
        if (ok) {
            [out appendBytes:(b + i) length:need + 1];
            i += need + 1;
        } else {
            [out appendBytes:"?" length:1];
            i++;
        }
    }
    return [[NSString alloc] initWithData:out encoding:NSUTF8StringEncoding] ?: @"";
}

@implementation SLVLog

+ (NSString *)filePath {
    return SLVLogCurrentPath();
}

+ (NSString *)diagnostics {
    return SLVLogDiagnostics();
}

+ (unsigned long long)fileSize {
    NSString *path = SLVLogCurrentPath();
    struct stat st;
    if (!path.length) return 0;
    if (stat(path.fileSystemRepresentation, &st) != 0) return 0;
    return (unsigned long long)st.st_size;
}

// 只读文件尾部，不把整份日志读进内存，也不整份解码。
//
// 两个作用：
// 1. 940KB 的文件读 400 行没必要整份加载；
// 2. 更关键的是容错 —— 从尾部往前读、再跳到第一个换行之后，
//    文件开头就算是坏掉的半截 UTF-8 也完全不碍事（0.3.48 的空白就是它导致的）。
+ (NSString *)tailLines:(NSInteger)lines {
    NSString *path = SLVLogCurrentPath();
    if (!path.length) return @"";
    const char *p = path.fileSystemRepresentation;
    if (!p) return @"";

    int fd = open(p, O_RDONLY);
    if (fd < 0) return @"";

    struct stat st;
    if (fstat(fd, &st) != 0 || st.st_size <= 0) { close(fd); return @""; }

    const off_t window = 256 * 1024;
    off_t size = st.st_size;
    off_t off = size > window ? size - window : 0;
    size_t len = (size_t)(size - off);

    NSMutableData *buf = [NSMutableData dataWithLength:len];
    if (!buf.mutableBytes) { close(fd); return @""; }
    ssize_t got = pread(fd, buf.mutableBytes, len, off);
    close(fd);
    if (got <= 0) return @"";
    buf.length = (NSUInteger)got;

    NSData *body = buf;
    if (off > 0) {
        const uint8_t *b = buf.bytes;
        NSUInteger i = 0;
        while (i < buf.length && b[i] != '\n') i++;
        if (i >= buf.length) return @"";
        body = [buf subdataWithRange:NSMakeRange(i + 1, buf.length - i - 1)];
    }

    NSString *s = SLVDecodeUTF8(body);
    if (!s.length) return @"";

    NSArray<NSString *> *all = [s componentsSeparatedByString:@"\n"];
    NSInteger n = (NSInteger)all.count;
    NSInteger start = (lines > 0 && n > lines) ? n - lines : 0;
    return [all subarrayWithRange:NSMakeRange((NSUInteger)start, (NSUInteger)(n - start)) componentsJoinedByString:@"\n"];
}

+ (void)clear {
    NSString *path = SLVLogCurrentPath();
    if (!path.length) return;
    // 直接截断，不重建文件：重建会换 inode 和属主，反而更容易写不进去
    int fd = open(path.fileSystemRepresentation, O_WRONLY | O_TRUNC);
    if (fd >= 0) close(fd);
}

@end
