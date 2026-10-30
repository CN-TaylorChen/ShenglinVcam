//
//  SLVUtil.m
//  声临 · 虚拟摄像头 —— 底包通用小工具
//

#import "SLUtil.h"

NSString *SLVDocumentsPath(void) {
    static NSString *p = nil;
    if (!p) {
        NSArray *dirs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        p = dirs.firstObject ?: NSTemporaryDirectory();
    }
    return p;
}

NSString *SLVStoreDir(void) {
    NSString *dir = [SLVDocumentsPath() stringByAppendingPathComponent:@"ShenglinVcam"];
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil];
    });
    return dir;
}

NSString *SLVStorePath(NSString *name) {
    return [SLVStoreDir() stringByAppendingPathComponent:name];
}

// 同一时刻只留一条。以前每条 toast 都往窗口上加一个 UILabel，两次连发就叠在一起 ——
// 「正在导入…」还没消失，结果提示就压上去了，两行字糊成一团。
// 现在新 toast 进来先把旧的摘掉（连带取消它的动画，否则旧的那个还会走完淡出再 remove）。
static UILabel *sToastLab = nil;

static void SLVToastDuration(NSString *message, NSTimeInterval dur) {
    if (!message.length) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (sToastLab) {
            [sToastLab.layer removeAllAnimations];
            [sToastLab removeFromSuperview];
            sToastLab = nil;
        }

        UIWindow *win = nil;
        for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
            if (![sc isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)sc).windows) {
                if (w.isKeyWindow) { win = w; break; }
            }
            if (win) break;
        }
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Wdeprecated-declarations"
        if (!win) win = [UIApplication sharedApplication].keyWindow;
        #pragma clang diagnostic pop
        if (!win) return;

        UILabel *lab = [[UILabel alloc] init];
        lab.text = message;
        lab.font = [UIFont systemFontOfSize:14.0];
        lab.textColor = [UIColor whiteColor];
        lab.textAlignment = NSTextAlignmentCenter;
        lab.numberOfLines = 0;
        lab.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.78];
        lab.layer.cornerRadius = 14.0;
        lab.layer.masksToBounds = YES;

        CGFloat maxW = win.bounds.size.width - 80.0;
        CGSize fit = [lab sizeThatFits:CGSizeMake(maxW, CGFLOAT_MAX)];
        CGFloat w = MIN(maxW, fit.width + 32.0);
        CGFloat h = fit.height + 20.0;
        lab.frame = CGRectMake((win.bounds.size.width - w) / 2.0,
                               win.bounds.size.height * 0.72,
                               w, h);
        lab.alpha = 0.0;
        [win addSubview:lab];
        sToastLab = lab;

        [UIView animateWithDuration:0.18 animations:^{
            lab.alpha = 1.0;
        } completion:^(BOOL finished) {
            if (finished == NO) return;
            [UIView animateWithDuration:0.25 delay:dur options:0 animations:^{
                lab.alpha = 0.0;
            } completion:^(BOOL done) {
                [lab removeFromSuperview];
                if (sToastLab == lab) sToastLab = nil;
            }];
        }];
    });
}

void SLVToast(NSString *message) {
    SLVToastDuration(message, 1.2);
}

void SLVToastLong(NSString *message) {
    SLVToastDuration(message, 2.0);
}

UIViewController *SLVTopViewController(void) {
    UIWindow *win = nil;
    for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
        if (![sc isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)sc).windows) {
            if (w.isKeyWindow) { win = w; break; }
        }
        if (win) break;
    }
    #pragma clang diagnostic push
    #pragma clang diagnostic ignored "-Wdeprecated-declarations"
    if (!win) win = [UIApplication sharedApplication].keyWindow;
    #pragma clang diagnostic pop
    UIViewController *vc = win.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    if ([vc isKindOfClass:[UINavigationController class]]) {
        vc = ((UINavigationController *)vc).topViewController;
    } else if ([vc isKindOfClass:[UITabBarController class]]) {
        vc = ((UITabBarController *)vc).selectedViewController;
    }
    return vc;
}

// 屏幕尺寸的唯一出口。
//
// 为什么不能直接读 superview.bounds / self.view.bounds：
// 球挂在 SLVKeyWindow() 挑出来的那个窗口上，而它挑的是 windowLevel 最高的窗口。
// iOS 里 windowLevel 最高的往往不是主窗口 —— QQRTCWindow（通话浮层）、
// UITextEffectsWindow（键盘）、Alert 窗、状态栏窗都排在主窗口前面。
// 这些窗口的 bounds 只是屏幕的一块局部区域，拿它当屏幕量几何，扇就会：
//   ① 半径被安全区夹到下限 74，五个球挤在一起；
//   ② 球心相对位置偏移，看起来「每个 App 位置都不一样」。
// 面板同理 —— self.view.bounds 是呈现容器的 bounds，容器一变尺寸就变。
//
// coordinateSpace.bounds 的 origin 在分屏 / 台前调度下可能不是 0，这里统一归零：
// 我们要的只是「能画多大」，不是「画在屏幕的哪个偏移处」。
CGRect SLVScreenRect(void) {
    if (@available(iOS 13.0, *)) {
        CGRect best = CGRectZero;
        for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
            if (![sc isKindOfClass:[UIWindowScene class]]) continue;
            UIWindowScene *ws = (UIWindowScene *)sc;
            if (ws.activationState == UISceneActivationStateBackground) continue;
            CGRect r = ws.coordinateSpace.bounds;
            if (r.size.width * r.size.height > best.size.width * best.size.height) best = r;
        }
        if (best.size.width > 0 && best.size.height > 0) {
            return CGRectMake(0, 0, best.size.width, best.size.height);
        }
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    CGRect r = [UIScreen mainScreen].bounds;
#pragma clang diagnostic pop
    return CGRectMake(0, 0, r.size.width, r.size.height);
}

CGSize SLVScreenSize(void) {
    return SLVScreenRect().size;
}

UIImage *SLVRoundedImage(UIImage *src, CGFloat side) {
    if (!src || side <= 0) return nil;
    CGSize sz = src.size;
    if (sz.width <= 0 || sz.height <= 0) return nil;
    CGFloat m = MIN(sz.width, sz.height);
    CGRect crop = CGRectMake((sz.width - m) / 2.0, (sz.height - m) / 2.0, m, m);

    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.opaque = NO;
    fmt.scale = 1.0;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(side, side) format:fmt];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGContextRef c = ctx.CGContext;
        CGContextAddEllipseInRect(c, CGRectMake(0, 0, side, side));
        CGContextClip(c);
        // 整图按 side/m 缩放后平移到只剩裁切窗口，圆角交给上面的 clip
        [src drawInRect:CGRectMake(-crop.origin.x * side / m,
                                   -crop.origin.y * side / m,
                                   sz.width * side / m,
                                   sz.height * side / m)];
    }];
}
