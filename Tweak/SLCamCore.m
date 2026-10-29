//
//  SLCamCore.m
//  声临 · 虚拟摄像头 —— SLCamBridge 的默认实现
//
//  这是外壳和业务之间唯一有代码的接缝。底包里它只做三件事：
//    · 读总开关（默认开）
//    · 把「当前素材」翻译成胶囊上那行字
//    · 点箭头时弹素材列表
//
//  换插件时，想改「就绪」的判定（比如要求同时有视频和解码器就绪），
//  改 SLCamArmed 就行；外壳不用动。
//

#import "SLCamBridge.h"
#import "SLFloatingBall.h"
#import "SLMediaStore.h"
#import "SLCamFeed.h"
#import "SLCamInject.h"
#import "SLUtil.h"
#import "SLLog.h"

NSString *const kSLCamEnabledKey = @"SLCamEnabled";
NSString *const kSLCamLoopKey    = @"SLCamLoop";
NSString *const kSLCamMirrorKey  = @"SLCamMirror";

static BOOL SLCamReadBool(NSString *key, BOOL def) {
    id v = [[NSUserDefaults standardUserDefaults] objectForKey:key];
    return v ? [v boolValue] : def;
}

BOOL SLCamEnabled(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    id v = [d objectForKey:kSLCamEnabledKey];
    return v ? [v boolValue] : YES;   // 没设过 = 开
}

BOOL SLCamArmed(void) {
    return [SLMediaStore currentItem] != nil && [[SLCamFeed shared] isReady];
}

NSString *SLCamCurrentName(void) {
    SLMediaItem *it = [SLMediaStore currentItem];
    if (it.displayName.length) return it.displayName;
    return @"未选素材";
}

NSString *SLCamStatusSummary(void) {
    NSArray<SLMediaItem *> *all = [SLMediaStore allItems];
    SLMediaItem *cur = [SLMediaStore currentItem];
    if (all.count == 0) return @"未导入";
    if (!cur) return [NSString stringWithFormat:@"%lu 个 · 未选", (unsigned long)all.count];
    return [NSString stringWithFormat:@"%lu 个 · %@", (unsigned long)all.count, cur.displayName];
}

void SLCamHandleArrowTap(UIView *anchor) {
    (void)anchor;
    UIViewController *top = SLTopViewController();
    if (!top) return;
    [SLFloatPanelController presentMediaFrom:top];
}

void SLCamReloadAll(void) {
    // 素材换了 → 帧源跟着换，并回到第一帧；没素材就清空，注入层会原样放行
    SLMediaItem *it = [SLMediaStore currentItem];
    SLCamFeed *feed = [SLCamFeed shared];

    feed.loopEnabled   = SLCamReadBool(kSLCamLoopKey, YES);
    feed.mirrorEnabled = SLCamReadBool(kSLCamMirrorKey, NO);

    if (![feed.sourcePath isEqualToString:it.path ?: @""]) {
        feed.sourcePath = it.path;
    } else {
        [feed rewind];
    }

    // 只有「总开关开着 + 有素材文件」才真正替换；否则注入层原样放行真摄像头
    SLCamSetInjecting(SLCamEnabled() && it.path.length > 0);
    SLRefreshFloatButton();
}
