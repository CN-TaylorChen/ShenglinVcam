//
//  SLTarget.h
//  声临 · 虚拟摄像头 —— 目标进程判定
//
//  tweak 会被注入到 Filter plist 里列出的每个 app。这个类决定「当前进程要不要挂球」：
//  · 设置里填了 bundle id 列表 → 只在这些 app 里生效；
//  · 没填 → 所有第三方 app 都生效（系统进程一律不挂）。
//
//  套用时几乎不用改这里；要精确到某个 app 的采集路径，改 SLCamInject 里的适配。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface SLTargetRegistry : NSObject

/// 当前进程是否应该挂球
+ (BOOL)isTargetProcess;

/// 用户配置的目标 app（bundle id 数组），空数组 = 全部第三方 app
+ (NSArray<NSString *> *)targetBundleIDs;
+ (void)setTargetBundleIDs:(NSArray<NSString *> *)ids;

@end

NS_ASSUME_NONNULL_END
