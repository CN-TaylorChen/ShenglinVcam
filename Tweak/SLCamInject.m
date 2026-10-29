//
//  SLCamInject.m
//  声临 · 虚拟摄像头 —— 注入层（底包空实现）
//

#import "SLCamInject.h"
#import "SLCamFeed.h"
#import "SLLog.h"

static BOOL sSLCamInjecting = NO;
static BOOL sSLCamHooksInstalled = NO;

void SLCamInstallHooks(void) {
    if (sSLCamHooksInstalled) return;
    sSLCamHooksInstalled = YES;
    // TODO(套用): 按头文件里的四步装 hook
    SLLog(@"inject hooks: skeleton, nothing installed");
}

void SLCamSetInjecting(BOOL injecting) {
    sSLCamInjecting = injecting;
    SLLog(@"injecting = %@", injecting ? @"YES" : @"NO");
}

BOOL SLCamInjecting(void) {
    return sSLCamInjecting;
}
