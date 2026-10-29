//
//  SLTarget.m
//  声临 · 虚拟摄像头 —— 目标进程判定
//

#import "SLTarget.h"
#import "SLUtil.h"
#import "SLLog.h"

static NSString *const kSLCamTargetsKey = @"SLCamTargets";

@implementation SLTargetRegistry

+ (NSArray<NSString *> *)targetBundleIDs {
    NSArray *v = [[NSUserDefaults standardUserDefaults] arrayForKey:kSLCamTargetsKey];
    return [v isKindOfClass:[NSArray class]] ? v : @[];
}

+ (void)setTargetBundleIDs:(NSArray<NSString *> *)ids {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setObject:(ids ?: @[]) forKey:kSLCamTargetsKey];
    [d synchronize];
}

+ (BOOL)isTargetProcess {
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
    if (!bid.length) return NO;
    // 系统进程不挂：SpringBoard / 设置 / 桌面这些没有摄像头场景，挂了只会碍事。
    // 例外是系统「相机」—— 那是最直观的验证目标，放行。
    if ([bid hasPrefix:@"com.apple."] && ![bid isEqualToString:@"com.apple.camera"]) return NO;

    NSArray<NSString *> *list = [self targetBundleIDs];
    if (list.count == 0) return YES;   // 没配置 = 全域生效
    return [list containsObject:bid];
}

@end
