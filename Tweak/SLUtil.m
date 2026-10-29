//
//  SLUtil.m
//  声临 · 虚拟摄像头 —— 底包通用小工具
//

#import "SLUtil.h"

NSString *SLDocumentsPath(void) {
    static NSString *p = nil;
    if (!p) {
        NSArray *dirs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        p = dirs.firstObject ?: NSTemporaryDirectory();
    }
    return p;
}

NSString *SLStoreDir(void) {
    NSString *dir = [SLDocumentsPath() stringByAppendingPathComponent:@"ShenglinVcam"];
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil];
    });
    return dir;
}

NSString *SLStorePath(NSString *name) {
    return [SLStoreDir() stringByAppendingPathComponent:name];
}

static void SLToastDuration(NSString *message, NSTimeInterval dur) {
    if (!message.length) return;
    dispatch_async(dispatch_get_main_queue(), ^{
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

        [UIView animateWithDuration:0.18 animations:^{
            lab.alpha = 1.0;
        } completion:^(BOOL finished) {
            [UIView animateWithDuration:0.25 delay:dur options:0 animations:^{
                lab.alpha = 0.0;
            } completion:^(BOOL done) {
                [lab removeFromSuperview];
            }];
        }];
    });
}

void SLToast(NSString *message) {
    SLToastDuration(message, 1.2);
}

void SLToastLong(NSString *message) {
    SLToastDuration(message, 2.0);
}

UIViewController *SLTopViewController(void) {
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

UIImage *SLRoundedImage(UIImage *src, CGFloat side) {
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
