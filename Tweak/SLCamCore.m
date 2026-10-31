//
//  SLVCamCore.m
//  声临 · 虚拟摄像头 —— SLVCamBridge 的默认实现
//
//  这是外壳和业务之间唯一有代码的接缝。底包里它只做三件事：
//    · 读总开关（默认开）
//    · 把「当前素材」翻译成胶囊上那行字
//    · 点箭头时弹素材列表
//
//  换插件时，想改「就绪」的判定（比如要求同时有视频和解码器就绪），
//  改 SLVCamArmed 就行；外壳不用动。
//

#import "SLCamBridge.h"
#import "SLFloatingBall.h"
#import "SLMediaStore.h"
#import "SLCamFeed.h"
#import "SLCamInject.h"
#import "SLUtil.h"
#import "SLLog.h"

NSString *const kSLCamEnabledKey = @"SLVCamEnabled";
NSString *const kSLCamLoopKey    = @"SLVCamLoop";
NSString *const kSLCamMirrorKey  = @"SLVCamMirror";
NSString *const kSLCamRotateKey  = @"SLVCamRotate";
NSString *const kSLCamAudioKey   = @"SLVCamAudio";
NSString *const kSLCamSquareCropKey = @"SLVCamSquareCrop";

NSString *const SLVCamConfigChangedNotification = @"SLVCamConfigChangedNotification";

// 0.3.0 统一加 SLV 前缀前的旧键。只读不写，读到就搬到新键。
static NSString *const kSLCamEnabledKeyOld = @"SLCamEnabled";

static BOOL SLVCamReadBool(NSString *key, BOOL def) {
    id v = [[NSUserDefaults standardUserDefaults] objectForKey:key];
    return v ? [v boolValue] : def;
}

static NSInteger SLVCamReadInt(NSString *key, NSInteger def) {
    id v = [[NSUserDefaults standardUserDefaults] objectForKey:key];
    return v ? [v integerValue] : def;
}

BOOL SLVCamEnabled(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    id v = [d objectForKey:kSLCamEnabledKey];
    if (!v) {
        // 0.3.0 迁移：键名加了 SLV 前缀，旧键里关过的开关不能因为改名又变回「开」。
        v = [d objectForKey:kSLCamEnabledKeyOld];
        if (v) [d setObject:v forKey:kSLCamEnabledKey];
    }
    return v ? [v boolValue] : YES;   // 没设过 = 开
}

BOOL SLVCamArmed(void) {
    return [SLVMediaStore currentItem] != nil && [[SLVCamFeed shared] isReady];
}

NSString *SLVCamCurrentName(void) {
    SLVMediaItem *it = [SLVMediaStore currentItem];
    if (it.displayName.length) return it.displayName;
    return @"未选素材";
}

NSString *SLVCamStatusSummary(void) {
    NSArray<SLVMediaItem *> *all = [SLVMediaStore allItems];
    SLVMediaItem *cur = [SLVMediaStore currentItem];
    if (all.count == 0) return @"未导入";
    if (!cur) return [NSString stringWithFormat:@"%lu 个 · 未选", (unsigned long)all.count];
    return [NSString stringWithFormat:@"%lu 个 · %@%@", (unsigned long)all.count,
            cur.displayName, cur.isImage ? @"（图片）" : @""];
}

void SLVCamHandleArrowTap(UIView *anchor) {
    (void)anchor;
    UIViewController *top = SLVTopViewController();
    if (!top) return;
    [SLVFloatPanelController presentMediaFrom:top];
}

void SLVCamReloadAll(void) {
    // 素材换了 → 帧源跟着换，并回到第一帧；没素材就清空，注入层会原样放行
    SLVMediaItem *it = [SLVMediaStore currentItem];
    SLVCamFeed *feed = [SLVCamFeed shared];

    feed.loopEnabled         = SLVCamReadBool(kSLCamLoopKey, YES);
    feed.mirrorEnabled       = SLVCamReadBool(kSLCamMirrorKey, NO);
    feed.rotation            = SLVCamReadInt(kSLCamRotateKey, 0);
    feed.audioReplaceEnabled = SLVCamReadBool(kSLCamAudioKey, YES);
    // 陌陌实拍时刻：默认关 = 铺满整帧（老行为）。开了才按正方形裁切、不放大。
    feed.squareCropEnabled   = SLVCamReadBool(kSLCamSquareCropKey, NO);

    // 只有路径真的变了才重启解码。切个镜像/旋转开关不该把画面跳回第一帧 ——
    // 那在直播/通话里非常出戏。
    NSString *want = it.path ?: @"";
    NSString *cur  = feed.sourcePath ?: @"";
    if (![cur isEqualToString:want]) {
        feed.sourcePath = it.path;
    }

    // 只有「总开关开着 + 有素材文件」才真正替换；否则注入层原样放行真摄像头
    SLVCamSetInjecting(SLVCamEnabled() && it.path.length > 0);
    SLVRefreshFloatButton();

    // 0.3.3：通知所有打开着的配置界面把控件值同步过来。
    // 长按悬浮球改开关走的是另一条路径（SLVFanCommit），它只写 NSUserDefaults，
    // 设置页的 cell 是创建时读一次值 —— 不发通知的话设置页会一直显示旧状态。
    // 这里统一在 SLVCamReloadAll 里发，所有改配置的入口就都覆盖到了。
    void (^notify)(void) = ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:SLVCamConfigChangedNotification
                                                            object:nil];
    };
    if ([NSThread isMainThread]) notify();
    else dispatch_async(dispatch_get_main_queue(), notify);
}
