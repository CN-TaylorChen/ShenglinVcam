//
//  SLMediaStore.m
//  声临 · 虚拟摄像头 —— 素材库
//

#import "SLMediaStore.h"
#import "SLUtil.h"
#import "SLLog.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreVideo/CoreVideo.h>
#import <ImageIO/ImageIO.h>
#import <CommonCrypto/CommonDigest.h>

static NSString *const kSLCurrentMediaKey = @"SLCamCurrentMedia";

/// 去重用的内容指纹。放在素材目录里但用隐藏名 + .plist 后缀，
/// 所以 allItems 的扩展名过滤天然看不到它。
static NSString *const kSLHashManifestName = @".hashes.plist";

@implementation SLMediaItem
@end

@implementation SLMediaStore

+ (NSString *)mediaDir {
    NSString *dir = [SLStoreDir() stringByAppendingPathComponent:@"media"];
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

+ (NSArray<SLMediaItem *> *)allItems {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = [self mediaDir];
    NSArray<NSString *> *names = [fm contentsOfDirectoryAtPath:dir error:nil];
    NSMutableArray<SLMediaItem *> *out = [NSMutableArray array];
    for (NSString *n in names) {
        BOOL vid = [self sl_isVideoName:n];
        BOOL img = [self isImageFileName:n];
        if (!vid && !img) continue;

        NSString *path = [dir stringByAppendingPathComponent:n];
        SLMediaItem *it = [[SLMediaItem alloc] init];
        it.fileName = n;
        it.path = path;
        it.displayName = n.stringByDeletingPathExtension;
        it.isImage = img;
        NSDictionary *attrs = [fm attributesOfItemAtPath:path error:nil];
        it.addedAt = attrs[NSFileModificationDate] ?: [NSDate dateWithTimeIntervalSince1970:0];
        [out addObject:it];
    }
    // 最新的排最上面；时间戳撞车时用文件名兜底，保证顺序稳定
    [out sortUsingComparator:^NSComparisonResult(SLMediaItem *a, SLMediaItem *b) {
        NSComparisonResult r = [b.addedAt compare:a.addedAt];
        if (r != NSOrderedSame) return r;
        return [b.fileName compare:a.fileName];
    }];
    return out;
}

+ (SLMediaItem *)currentItem {
    NSString *want = [[NSUserDefaults standardUserDefaults] stringForKey:kSLCurrentMediaKey];
    if (!want.length) return nil;
    for (SLMediaItem *it in [self allItems]) {
        if ([it.fileName isEqualToString:want]) return it;
    }
    return nil;
}

+ (void)setCurrentItem:(SLMediaItem *)item {
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
/// 判据和 SLCamFeed 建 reader 时完全一致：有视频轨，且能挂上 420f（退 BGRA）输出。
/// 用同一套条件才不会出现「体检通过、真跑起来却黑屏」。
+ (BOOL)sl_isDecodableVideoAtPath:(NSString *)path {
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path] options:nil];
    AVAssetTrack *vt = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
    if (!vt) return NO;

    NSError *err = nil;
    AVAssetReader *reader = [AVAssetReader assetReaderWithAsset:asset error:&err];
    if (!reader) {
        SLLog(@"导入: 建 reader 失败 %@", err.localizedDescription ?: @"?");
        return NO;
    }

    OSType kinds[2] = { kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_32BGRA };
    for (int i = 0; i < 2; i++) {
        NSDictionary *settings = @{ (id)kCVPixelBufferPixelFormatTypeKey : @(kinds[i]) };
        AVAssetReaderTrackOutput *o = [[AVAssetReaderTrackOutput alloc] initWithTrack:vt outputSettings:settings];
        if ([reader canAddOutput:o]) return YES;
    }
    SLLog(@"导入: 视频轨解不出 420f/BGRA（%@）", vt.formatDescriptions.firstObject ? @"有格式描述" : @"无格式描述");
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

+ (SLMediaItem *)importItemAtURL:(NSURL *)url
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
    for (SLMediaItem *it in [self allItems]) {
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
                SLMediaItem *it = [[SLMediaItem alloc] init];
                it.fileName = hit;
                it.path = p;
                it.displayName = hit.stringByDeletingPathExtension;
                it.isImage = [self isImageFileName:hit];
                it.addedAt = [fm attributesOfItemAtPath:p error:nil][NSFileModificationDate]
                              ?: [NSDate date];
                [self setCurrentItem:it];
                [self sl_saveHashes:hashes];
                if (duplicate) *duplicate = YES;
                SLLog(@"导入: %@ 内容重复，复用已有素材 %@", url.lastPathComponent, hit);
                return it;
            }
            // 记录还在但文件没了，清掉这条脏数据
            [hashes removeObjectForKey:hit];
        }
    }

    // ---- 2. 复制进来 ----
    // 时间戳命名：天然按导入顺序排，不会重名；同一秒导两次加个后缀
    NSString *name = [NSString stringWithFormat:@"%.0f.%@", [[NSDate date] timeIntervalSince1970], ext];
    NSString *dst = [[self mediaDir] stringByAppendingPathComponent:name];
    for (int i = 2; [fm fileExistsAtPath:dst] && i < 100; i++) {
        name = [NSString stringWithFormat:@"%.0f-%d.%@",
                [[NSDate date] timeIntervalSince1970], i, ext];
        dst = [[self mediaDir] stringByAppendingPathComponent:name];
    }

    NSError *copyErr = nil;
    if (![fm copyItemAtURL:url toURL:[NSURL fileURLWithPath:dst] error:&copyErr]) {
        SLLog(@"导入: 拷贝失败 %@", copyErr.localizedDescription ?: @"?");
        if (error) *error = copyErr;
        return nil;
    }

    // ---- 3. 拷完体检：解不了的素材留在列表里只会变成一条「点了没反应」的死条目 ----
    BOOL ok = isImage ? [self sl_isDecodableImageAtPath:dst] : [self sl_isDecodableVideoAtPath:dst];
    if (!ok) {
        [fm removeItemAtPath:dst error:nil];
        SLLog(@"导入: %@ 解码不可用，已删除", name);
        if (error) {
            *error = [NSError errorWithDomain:@"SLCamMedia" code:-2 userInfo:@{
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

    SLMediaItem *it = [[SLMediaItem alloc] init];
    it.fileName = name;
    it.path = dst;
    it.displayName = name.stringByDeletingPathExtension;
    it.isImage = isImage;
    it.addedAt = [NSDate date];
    // 0.2.20 起：每次导入都自动选中（以前只有库里空着才选，加第二个素材还得再点一次）
    [self setCurrentItem:it];

    SLLog(@"media imported: %@（%@）", name, isImage ? @"图片" : @"视频");
    return it;
}

+ (BOOL)importFileAtURL:(NSURL *)url error:(NSError **)error {
    return [self importItemAtURL:url error:error duplicate:NULL] != nil;
}

+ (void)removeItem:(SLMediaItem *)item {
    if (!item.path.length) return;
    [[NSFileManager defaultManager] removeItemAtPath:item.path error:nil];

    NSMutableDictionary<NSString *, NSString *> *hashes = [self sl_loadHashes];
    if (hashes[item.fileName]) {
        [hashes removeObjectForKey:item.fileName];
        [self sl_saveHashes:hashes];
    }

    NSString *cur = [[NSUserDefaults standardUserDefaults] stringForKey:kSLCurrentMediaKey];
    if ([cur isEqualToString:item.fileName]) [self setCurrentItem:nil];
    SLLog(@"media removed: %@", item.fileName);
}

@end
