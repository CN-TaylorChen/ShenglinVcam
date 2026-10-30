//
//  SLMediaStore.m
//  声临 · 虚拟摄像头 —— 素材库
//

#import "SLMediaStore.h"
#import "SLUtil.h"
#import "SLLog.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreVideo/CoreVideo.h>

static NSString *const kSLCurrentMediaKey = @"SLCamCurrentMedia";

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
    NSString *ext = name.pathExtension.lowercaseString;
    return [@[@"mp4", @"mov", @"m4v"] containsObject:ext];
}

+ (NSArray<SLMediaItem *> *)allItems {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *names = [fm contentsOfDirectoryAtPath:[self mediaDir] error:nil];
    NSMutableArray<SLMediaItem *> *out = [NSMutableArray array];
    for (NSString *n in [names sortedArrayUsingSelector:@selector(compare:)]) {
        if (![self sl_isVideoName:n]) continue;
        SLMediaItem *it = [[SLMediaItem alloc] init];
        it.fileName = n;
        it.path = [[self mediaDir] stringByAppendingPathComponent:n];
        it.displayName = n.stringByDeletingPathExtension;
        [out addObject:it];
    }
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

+ (BOOL)importFileAtURL:(NSURL *)url error:(NSError **)error {
    if (!url) return NO;
    NSString *ext = url.pathExtension.lowercaseString;
    if (!ext.length) ext = @"mp4";
    // 时间戳命名：天然按导入顺序排，不会重名
    NSString *name = [NSString stringWithFormat:@"%.0f.%@", [[NSDate date] timeIntervalSince1970], ext];
    NSString *dst = [[self mediaDir] stringByAppendingPathComponent:name];

    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *copyErr = nil;
    BOOL ok = [fm copyItemAtURL:url toURL:[NSURL fileURLWithPath:dst] error:&copyErr];
    if (!ok) {
        SLLog(@"导入: 拷贝失败 %@", copyErr.localizedDescription ?: @"?");
        if (error) *error = copyErr;
        return NO;
    }

    // 拷完先体检：编码不支持的素材留在列表里只会变成一条「点了没反应」的死条目，
    // 不如当场删掉并说清原因。
    if (![self sl_isDecodableVideoAtPath:dst]) {
        [fm removeItemAtPath:dst error:nil];
        SLLog(@"导入: %@ 解码不可用，已删除", name);
        if (error) {
            *error = [NSError errorWithDomain:@"SLCamMedia" code:-2 userInfo:@{
                NSLocalizedDescriptionKey: @"这段视频的编码不支持，换一段试试",
            }];
        }
        return NO;
    }

    SLLog(@"media imported: %@", name);
    // 第一段素材默认选中，省得用户还要再点一次
    if (![self currentItem]) {
        SLMediaItem *it = [[SLMediaItem alloc] init];
        it.fileName = name;
        it.path = dst;
        it.displayName = name.stringByDeletingPathExtension;
        [self setCurrentItem:it];
    }
    return YES;
}

+ (void)removeItem:(SLMediaItem *)item {
    if (!item.path.length) return;
    [[NSFileManager defaultManager] removeItemAtPath:item.path error:nil];
    NSString *cur = [[NSUserDefaults standardUserDefaults] stringForKey:kSLCurrentMediaKey];
    if ([cur isEqualToString:item.fileName]) [self setCurrentItem:nil];
    SLLog(@"media removed: %@", item.fileName);
}

@end
