//
//  SLMediaStore.m
//  声临 · 虚拟摄像头 —— 素材库
//

#import "SLMediaStore.h"
#import "SLUtil.h"
#import "SLLog.h"

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

+ (BOOL)importFileAtURL:(NSURL *)url error:(NSError **)error {
    if (!url) return NO;
    NSString *ext = url.pathExtension.lowercaseString;
    if (!ext.length) ext = @"mp4";
    // 时间戳命名：天然按导入顺序排，不会重名
    NSString *name = [NSString stringWithFormat:@"%.0f.%@", [[NSDate date] timeIntervalSince1970], ext];
    NSString *dst = [[self mediaDir] stringByAppendingPathComponent:name];

    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL ok = [fm copyItemAtURL:url toURL:[NSURL fileURLWithPath:dst] error:error];
    if (ok) {
        SLLog(@"media imported: %@", name);
        // 第一段素材默认选中，省得用户还要再点一次
        if (![self currentItem]) {
            SLMediaItem *it = [[SLMediaItem alloc] init];
            it.fileName = name;
            it.path = dst;
            it.displayName = name.stringByDeletingPathExtension;
            [self setCurrentItem:it];
        }
    }
    return ok;
}

+ (void)removeItem:(SLMediaItem *)item {
    if (!item.path.length) return;
    [[NSFileManager defaultManager] removeItemAtPath:item.path error:nil];
    NSString *cur = [[NSUserDefaults standardUserDefaults] stringForKey:kSLCurrentMediaKey];
    if ([cur isEqualToString:item.fileName]) [self setCurrentItem:nil];
    SLLog(@"media removed: %@", item.fileName);
}

@end
