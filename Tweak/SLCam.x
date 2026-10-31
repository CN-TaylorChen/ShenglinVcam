//
//  SLVCam.x
//  声临 · 虚拟摄像头 —— tweak 入口
//
//  底包在这里只做三件事：判定目标进程 → 装注入钩子（当前是空实现）→ 启动挂球监听。
//
//  套用时：
//    · app 专属的 hook 写在这个文件（相机初始化、通话开始/结束的埋点等）；
//    · 别在这里写 UI —— 界面全在 SLVFloatingBall / SLVSettingsPanel / SLVMediaListController。
//
//  版本号要和 control 的 Version:、SLVSettingsPanel.m 里的 SLVVersion 三处一致。
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "SLFloatingBall.h"
#import "SLCamBridge.h"
#import "SLCamInject.h"
#import "SLCamFeed.h"
#import "SLTarget.h"
#import "SLLog.h"

#define SLVVersion @"0.3.11"

/// 设置页「运行日志」那行右侧的钩子状态（SLVLogViewController.h 里声明的）
NSString *SLVHookStatusSummary(void) {
    if (!SLVCamHooksInstalled()) return @"未安装";
    int n = SLVCamHookCount();
    if (n <= 0) return @"未命中";
    if (SLVCamInjecting()) return [NSString stringWithFormat:@"替换中 · %d 个方法", n];
    return [NSString stringWithFormat:@"待命 · %d 个方法", n];
}

/// 日志页状态卡用：直接给数字，不让界面去猜字符串
NSInteger SLVHookCount(void) {
    if (!SLVCamHooksInstalled()) return 0;
    return (NSInteger)SLVCamHookCount();
}

/// 日志页状态卡用：短状态词
NSString *SLVHookStateShort(void) {
    if (!SLVCamHooksInstalled()) return @"未装上";
    if (SLVCamHookCount() <= 0) return @"未命中";
    return SLVCamInjecting() ? @"替换中" : @"待命";
}

%ctor {
    @autoreleasepool {
        if (![SLVTargetRegistry isTargetProcess]) return;

        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
        SLVLog(@"=== ShenglinVcam v%@ · %@ ===", SLVVersion, bid ?: @"?");

        // 注入层先装（底包是空实现，套用时在这里接 AVCapture 的钩子）
        SLVCamInstallHooks();

        // 宿主窗口可能被启动页 / 广告页替换，挂球交给 watcher 反复补，别只挂一次
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            SLVStartEntryWatcher();
            SLVCamReloadAll();
        });
    }
}
