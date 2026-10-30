//
//  SLVMediaStore.m
//  声临 · 虚拟摄像头 —— 素材库
//

#import "SLMediaStore.h"
#import "SLUtil.h"
#import "SLLog.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreVideo/CoreVideo.h>
#import <ImageIO/ImageIO.h>
#import <CommonCrypto/CommonDigest.h>

static NSString *const kSLCurrentMediaKey = @"SLVCamCurrentMedia";

/// 去重用的内容指纹。放在素材目录里但用隐藏名 + .plist 后缀，
/// 所以 allItems 的扩展名过滤天然看不到它。
static NSString *const kSLHashManifestName = @".hashes.plist";

@implementation SLVMediaItem
@end

#pragma mark - 文件名

// iOS 只禁 "/" 和 NUL，但冒号、引号、控制字符在别的地方会出事，一并换掉。
static NSString *SLVCleanBaseName(NSString *raw, NSUInteger maxLen) {
    if (!raw.length) return nil;
    NSCharacterSet *bad = [NSCharacterSet characterSetWithCharactersInString:@"/\\:*?\"<>|\r\n\t"];
    NSString *s = [[raw componentsSeparatedByCharactersInSet:bad] componentsJoinedByString:@"_"];
    s = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    // 开头的点会让文件变成隐藏文件，allItems 按扩展名过滤时就看不到它了
    while ([s hasPrefix:@"."]) s = [s substringFromIndex:1];
    if (s.length > maxLen) s = [s substringToIndex:maxLen];
    s = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return s.length ? s : nil;
}

// 相册偶尔给的是纯数字或 UUID 的临时名。这种名字拿来当显示名，跟时间戳一样没法看，
// 所以判定成「机器名」，退回时间戳命名。
static BOOL SLVLooksMachineName(NSString *s) {
    if (!s.length) return YES;
    NSCharacterSet *digits = [NSCharacterSet decimalDigitCharacterSet];
    if ([s stringByTrimmingCharactersInSet:digits].length == 0) return YES;
    if (s.length >= 32) {
        NSString *bare = [s stringByReplacingOccurrencesOfString:@"-" withString:@""];
        NSCharacterSet *hex = [NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF"];
        if ([bare stringByTrimmingCharactersInSet:hex].length == 0) return YES;
    }
    return NO;
}

static NSString *SLVBaseNameForURL(NSURL *url) {
    NSString *raw = url.lastPathComponent.stringByDeletingPathExtension;
    NSString *s = SLVCleanBaseName(raw, 60);
    if (SLVLooksMachineName(s)) {
        NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
        fmt.dateFormat = @"yyyyMMdd-HHmmss";
        s = [fmt stringFromDate:[NSDate date]];
    }
    return s.length ? s : @"素材";
}

// 老版本用 Unix 秒当文件名（1793354943），显示成一串数字完全看不出是哪段。
// 这里把 10 位时间戳翻译成「2026-10-30 19:20」。只影响显示，文件名不动 ——
// 改名会连带去重指纹表、当前选中项一起失效。
static NSDateFormatter *SLVStampFormatter(void) {
    static NSDateFormatter *f = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        f = [[NSDateFormatter alloc] init];
        f.dateFormat = @"yyyy-MM-dd HH:mm";
    });
    return f;
}

static NSString *SLVDisplayNameForFile(NSString *fileName) {
    NSString *base = fileName.stringByDeletingPathExtension;
    if (base.length == 10 && SLVLooksMachineName(base)) {
        double t = base.doubleValue;
        if (t > 1500000000.0 && t < 4000000000.0) {
            NSDateFormatter *f = SLVStampFormatter();
            NSString *s = nil;
            @synchronized (f) {   // NSDateFormatter 不是线程安全的
                s = [f stringFromDate:[NSDate dateWithTimeIntervalSince1970:t]];
            }
            if (s.length) return s;
        }
    }
    return base;
}

@implementation SLVMediaStore

+ (NSString *)mediaDir {
    NSString *dir = [SLVStoreDir() stringByAppendingPathComponent:@"media"];
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil];
    });
    return dir;
}

+ (BOOL)sl_isVideoName:(NSString *)name {
    if (!name.length) return NO;
    NSString *ext = name.pathExtension.lowercaseString;
    return [@[@"mp4", @"mov", @"m4v"] containsObject:ext];
}

+ (BOOL)sl_isImageExt:(NSString *)ext {
    if (!ext.length) return NO;
    return [@[@"png", @"jpg", @"jpeg", @"heic", @"heif", @"webp", @"bmp", @"tif", @"tiff"]
            containsObject:ext.lowercaseString];
}

+ (BOOL)isImageFileName:(NSString *)name {
    if (!name.length) return NO;
    return [self sl_isImageExt:name.pathExtension];
}

+ (NSArray<SLVMediaItem *> *)allItems {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = [self mediaDir];
    NSArray<NSString *> *names = [fm contentsOfDirectoryAtPath:dir error:nil];
    NSMutableArray<SLVMediaItem *> *out = [NSMutableArray array];
    for (NSString *n in names) {
        BOOL vid = [self sl_isVideoName:n];
        BOOL img = [self isImageFileName:n];
        if (!vid && !img) continue;

        NSString *path = [dir stringByAppendingPathComponent:n];
        SLVMediaItem *it = [[SLVMediaItem alloc] init];
        it.fileName = n;
        it.path = path;
        it.displayName = SLVDisplayNameForFile(n);
        it.isImage = img;
        NSDictionary *attrs = [fm attributesOfItemAtPath:path error:nil];
        it.addedAt = attrs[NSFileModificationDate] ?: [NSDate dateWithTimeIntervalSince1970:0];
        [out addObject:it];
    }
    // 最新的排最上面；时间戳撞车时用文件名兜底，保证顺序稳定
    [out sortUsingComparator:^NSComparisonResult(SLVMediaItem *a, SLVMediaItem *b) {
        NSComparisonResult r = [b.addedAt compare:a.addedAt];
        if (r != NSOrderedSame) return r;
        return [b.fileName compare:a.fileName];
    }];
    return out;
}

+ (SLVMediaItem *)currentItem {
    NSString *want = [[NSUserDefaults standardUserDefaults] stringForKey:kSLCurrentMediaKey];
    if (!want.length) return nil;
    for (SLVMediaItem *it in [self allItems]) {
        if ([it.fileName isEqualToString:want]) return it;
    }
    return nil;
}

+ (void)setCurrentItem:(SLVMediaItem *)item {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if (item.fileName.length) [d setObject:item.fileName forKey:kSLCurrentMediaKey];
    else [d removeObjectForKey:kSLCurrentMediaKey];
    [d synchronize];
}

#pragma mark - 去重指纹

+ (NSString *)sl_hashOfFileAtPath:(NSString *)path {
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!fh) return nil;

    CC_SHA256_CTX ctx;
    CC_SHA256_Init(&ctx);
    while (YES) {
        @autoreleasepool {
            // 分块读：4K 素材动辄上百 MB，一次读进内存会直接吃掉几百 MB
            NSData *chunk = [fh readDataOfLength:1 << 20];
            if (!chunk.length) break;
            CC_SHA256_Update(&ctx, chunk.bytes, (CC_LONG)chunk.length);
        }
    }
    [fh closeFile];

    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &ctx);
    NSMutableString *s = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [s appendFormat:@"%02x", digest[i]];
    return s;
}

+ (NSString *)sl_manifestPath {
    return [[self mediaDir] stringByAppendingPathComponent:kSLHashManifestName];
}

+ (NSMutableDictionary<NSString *, NSString *> *)sl_loadHashes {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:[self sl_manifestPath]];
    return d ? [d mutableCopy] : [NSMutableDictionary dictionary];
}

+ (void)sl_saveHashes:(NSDictionary<NSString *, NSString *> *)d {
    [d writeToFile:[self sl_manifestPath] atomically:YES];
}

#pragma mark - 体检

/// 这段视频我们到底能不能解？
/// 判据和 SLVCamFeed 建 reader 时完全一致：有视频轨，且能挂上 420f（退 BGRA）输出。
/// 用同一套条件才不会出现「体检通过、真跑起来却黑屏」。
+ (BOOL)sl_isDecodableVideoAtPath:(NSString *)path {
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path] options:nil];
    AVAssetTrack *vt = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
    if (!vt) return NO;

    NSError *err = nil;
    AVAssetReader *reader = [AVAssetReader assetReaderWithAsset:asset error:&err];
    if (!reader) {
        SLVLog(@"导入: 建 reader 失败 %@", err.localizedDescription ?: @"?");
        return NO;
    }

    OSType kinds[2] = { kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_32BGRA };
    for (int i = 0; i < 2; i++) {
        NSDictionary *settings = @{ (id)kCVPixelBufferPixelFormatTypeKey : @(kinds[i]) };
        AVAssetReaderTrackOutput *o = [[AVAssetReaderTrackOutput alloc] initWithTrack:vt outputSettings:settings];
        if ([reader canAddOutput:o]) return YES;
    }
    SLVLog(@"导入: 视频轨解不出 420f/BGRA（%@）", vt.formatDescriptions.firstObject ? @"有格式描述" : @"无格式描述");
    return NO;
}

/// 这张图能不能解？只读文件头拿尺寸，不整张解到内存。
+ (BOOL)sl_isDecodableImageAtPath:(NSString *)path {
    CGImageSourceRef src = CGImageSourceCreateWithURL(
        (__bridge CFURLRef)[NSURL fileURLWithPath:path], NULL);
    if (!src) return NO;
    BOOL ok = CGImageSourceGetCount(src) > 0;
    if (ok) {
        CFDictionaryRef props = CGImageSourceCopyPropertiesAtIndex(src, 0, NULL);
        NSDictionary *p = (__bridge_transfer NSDictionary *)props;
        ok = (p[(NSString *)kCGImagePropertyPixelWidth] != nil);
    }
    CFRelease(src);
    return ok;
}

#pragma mark - 导入

+ (SLVMediaItem *)importItemAtURL:(NSURL *)url
                           error:(NSError **)error
                       duplicate:(BOOL *)duplicate {
    if (duplicate) *duplicate = NO;
    if (!url) return nil;

    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *ext = url.pathExtension.lowercaseString;
    // 这里手里是裸扩展名（"png"），不能喂给吃文件名的 isImageFileName: ——
    // "png".pathExtension 是空串，会导致所有图片都被当成视频。
    BOOL isImage = [self sl_isImageExt:ext];
    if (!ext.length) {
        // 文件 App 偶尔给没扩展名的临时文件，按内容猜一次
        isImage = [self sl_isDecodableImageAtPath:url.path];
        ext = isImage ? @"png" : @"mp4";
    }

    // ---- 1. 先算内容指纹，跟库里已有的比 ----
    NSString *hash = [self sl_hashOfFileAtPath:url.path];
    NSMutableDictionary<NSString *, NSString *> *hashes = [self sl_loadHashes];

    // 0.2.20 之前导入的素材没有指纹记录，这里补算一次（一次性开销，之后走缓存）
    for (SLVMediaItem *it in [self allItems]) {
        if (hashes[it.fileName]) continue;
        NSString *h = [self sl_hashOfFileAtPath:it.path];
        if (h) hashes[it.fileName] = h;
    }

    if (hash.length) {
        NSString *hit = nil;
        for (NSString *name in hashes) {
            if ([hashes[name] isEqualToString:hash]) { hit = name; break; }
        }
        if (hit) {
            NSString *p = [[self mediaDir] stringByAppendingPathComponent:hit];
            if ([fm fileExistsAtPath:p]) {
                // 库里已经有同样内容 —— 不复制，直接选中它
                SLVMediaItem *it = [[SLVMediaItem alloc] init];
                it.fileName = hit;
                it.path = p;
                it.displayName = SLVDisplayNameForFile(hit);
                it.isImage = [self isImageFileName:hit];
                it.addedAt = [fm attributesOfItemAtPath:p error:nil][NSFileModificationDate]
                              ?: [NSDate date];
                [self setCurrentItem:it];
                [self sl_saveHashes:hashes];
                if (duplicate) *duplicate = YES;
                SLVLog(@"导入: %@ 内容重复，复用已有素材 %@", url.lastPathComponent, hit);
                return it;
            }
            // 记录还在但文件没了，清掉这条脏数据
            [hashes removeObjectForKey:hit];
        }
    }

    // ---- 2. 复制进来 ----
    // 0.2.24：保留原始文件名。以前一律用时间戳命名，素材页里全是 1793354943 这种数字，
    // 完全看不出哪段是哪段。只有拿到机器名（纯数字 / UUID）才退回时间戳。
    NSString *base = SLVBaseNameForURL(url);
    NSString *name = [NSString stringWithFormat:@"%@.%@", base, ext];
    NSString *dst = [[self mediaDir] stringByAppendingPathComponent:name];
    for (int i = 2; [fm fileExistsAtPath:dst] && i < 1000; i++) {
        name = [NSString stringWithFormat:@"%@-%d.%@", base, i, ext];
        dst = [[self mediaDir] stringByAppendingPathComponent:name];
    }

    NSError *copyErr = nil;
    if (![fm copyItemAtURL:url toURL:[NSURL fileURLWithPath:dst] error:&copyErr]) {
        SLVLog(@"导入: 拷贝失败 %@", copyErr.localizedDescription ?: @"?");
        if (error) *error = copyErr;
        return nil;
    }

    // copyItemAtURL 会连源文件的修改时间一起搬过来，而列表是按修改时间排「最新在前」的 ——
    // 不重置的话，刚导入的一段老视频会沉到列表最底下，看起来像「没导入成功」。
    [fm setAttributes:@{ NSFileModificationDate : [NSDate date] }
          ofItemAtPath:dst
                 error:nil];

    // ---- 3. 拷完体检：解不了的素材留在列表里只会变成一条「点了没反应」的死条目 ----
    BOOL ok = isImage ? [self sl_isDecodableImageAtPath:dst] : [self sl_isDecodableVideoAtPath:dst];
    if (!ok) {
        [fm removeItemAtPath:dst error:nil];
        SLVLog(@"导入: %@ 解码不可用，已删除", name);
        if (error) {
            *error = [NSError errorWithDomain:@"SLVCamMedia" code:-2 userInfo:@{
                NSLocalizedDescriptionKey: isImage
                    ? @"这张图片读不出来，换一张试试"
                    : @"这段视频的编码不支持，换一段试试",
            }];
        }
        return nil;
    }

    if (hash.length) {
        hashes[name] = hash;
        [self sl_saveHashes:hashes];
    }

    SLVMediaItem *it = [[SLVMediaItem alloc] init];
    it.fileName = name;
    it.path = dst;
    it.displayName = SLVDisplayNameForFile(name);
    it.isImage = isImage;
    it.addedAt = [NSDate date];
    // 0.2.20 起：每次导入都自动选中（以前只有库里空着才选，加第二个素材还得再点一次）
    [self setCurrentItem:it];

    SLVLog(@"media imported: %@（%@）", name, isImage ? @"图片" : @"视频");
    return it;
}

+ (BOOL)importFileAtURL:(NSURL *)url error:(NSError **)error {
    return [self importItemAtURL:url error:error duplicate:NULL] != nil;
}

+ (void)removeItem:(SLVMediaItem *)item {
    if (!item.path.length) return;
    [[NSFileManager defaultManager] removeItemAtPath:item.path error:nil];

    NSMutableDictionary<NSString *, NSString *> *hashes = [self sl_loadHashes];
    if (hashes[item.fileName]) {
        [hashes removeObjectForKey:item.fileName];
        [self sl_saveHashes:hashes];
    }

    NSString *cur = [[NSUserDefaults standardUserDefaults] stringForKey:kSLCurrentMediaKey];
    if ([cur isEqualToString:item.fileName]) [self setCurrentItem:nil];
    SLVLog(@"media removed: %@", item.fileName);
}

@end
