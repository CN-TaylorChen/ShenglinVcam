//
//  SLVTarget.m
//  声临 · 虚拟摄像头 —— 目标进程判定
//

#import "SLTarget.h"
#import "SLUtil.h"
#import "SLLog.h"

static NSString *const kSLCamTargetsKey = @"SLVCamTargets";
// 0.3.0 统一加 SLV 前缀前的旧键。只读不写，读到就搬到新键 ——
// 不然升级后读不到旧白名单，空数组等于「全域生效」，用户配过的名单会被静默重置。
static NSString *const kSLCamTargetsKeyOld = @"SLCamTargets";

@implementation SLVTargetRegistry

+ (NSArray<NSString *> *)targetBundleIDs {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSArray *v = [d arrayForKey:kSLCamTargetsKey];
    if (![v isKindOfClass:[NSArray class]]) {
        // 0.3.0 迁移
        v = [d arrayForKey:kSLCamTargetsKeyOld];
        if ([v isKindOfClass:[NSArray class]]) [d setObject:v forKey:kSLCamTargetsKey];
    }
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
